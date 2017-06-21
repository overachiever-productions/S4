

/*

	DEPENDENCIES:
		- Requires dba_DatabaseBackups_Log (logging table to keep details about errors (and successful executions if @LogSuccessfulOutcomes = 1). 
		- Requires dba_SplitString - to parse results from dba_LoadDatabases.
		- Requires dba_LoadDatabaseNames - sproc used to 'parse' or determine which dbs to target based upon inputs.
		- Requires dba_ExecuteAndFilterNonCatchableCommand - sproc used to execute backup and other compands in order to be able to CAPTURE exception
			details and error details (due to bug/problem with TRY/CATCH in T-SQL). 
		- Requires that xp_cmdshell is ENABLED before execution can/will complete (but the sproc CAN be created without xp_cmdshell enabled).
		- Requires a configured Database Mail Profile + SQL Server Agent Operator. 

	NOTES:
		- There's a serious bug/problem with T-SQL and how it handles TRY/CATCH (or other error-handling) operations:
			https://connect.microsoft.com/SQLServer/feedback/details/746979/try-catch-construct-catches-last-error-only
			This sproc gets around that limitation via the logic defined in dbo.dba_ExecuteAndFilterNonCatchableCommand;

		- A good way to simulate (er, well, create) errors and issues while executing backups is to:
			a) start executing a backup of, say, databaseN FROM a query/session in, say, databaseX (where databaseX is NOT the database you want to backup). 
			b) once the process (working in databaseX) is running, switch to another session/window and DROP databaseX WITH ROLLBACK IMMEDIATE... 
			and you'll get a whole host of errors/problems. 

		- This sproc explicitly uses RAISERROR instead of THROW for 'backwards compat' down to SQL Server 2008. 

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple

	TODO:
		- test/validate (and clean-up) on case-sensitive server (as much as those suck).
		- Review and potentially integrate any details defined here: 
			http://vickyharp.com/2013/12/killing-sessions-with-external-wait-types/

		-- Better Error Handling. 
			Right now... many of the operations that UPDATE a row in ... dba_BackupDatabases_Log... are NOT doing ErrorMessage = ErrorMessage + @ErrorMessage - meaning code is overwriting previous details... 

		- Add in simplified 'retry' logic for both backups and copy-to operations (i.e., something along the lines of adding a column to the 'list' of 
			dbs being backed up and if there's a failure... just add a counter/increment-counter for number of failures into @targetDatabases along
			with some meta-data about what the failure was (i.e., if we can't copy a file, don't re-backup the entire db) and then drop this into the 
			'bottom' of @targetDatabases... and when done with other dbs... retry  up to N times on/against certain types of operations. 
				that'll make things a wee bit more resilient (and, arguably... should throw in a WAITFOR DELAY once we start 'reprocessing') without
				hitting a point where a failed backup and/or copy operation could, say, retry 10x times with 30 seconds lag between each try because... 
					ALLOWING that much 'retry' typically means there's a huge problem and... we're hurting ourselves rather than failing and reporting 
					the error. I could/should also keep tabs on the AMOUNT of time spent ... and log it into a 'notes' column in .. dbo_DatabaseBackups_Log.

		- vNEXT: Additional integration with AGs (simple 2-node AGs first via preferred replica UDF), then on to multi-node configurations. 
			And, in the process, figure out how to address DIFFs as... they're not supported on secondaries: 
				http://dba.stackexchange.com/questions/152622/differential-backups-are-not-supported-on-secondary-replicas

		- vNEXT: Potentially look at an @NumberOfFiles option - for striping backups across multiple files
			Note that this would also require changes to dbo.dba_RestoreDatabases (i.e., to allow multiple files per 'logical' file) and
			there aren't THAT many benefits (in most cases) to having multiple files (though I have seen some perf benefits in the past on SOME systems)

	Scalable:
		22+
*/



USE master;
GO

IF OBJECT_ID('dbo.dba_BackupDatabases','P') IS NOT NULL
	DROP PROC dbo.dba_BackupDatabases;
GO

CREATE PROC dbo.dba_BackupDatabases 
	@BackupType							sysname,					-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(MAX),				-- { [SYSTEM]|[USER]|name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX) = NULL,		-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX) = NULL,		-- { higher,priority,dbs,*,lower,priority,dbs } - where * represents dbs not specifically specified (which will then be sorted alphabetically
	@BackupDirectory					nvarchar(2000),				-- { path_to_backups }
	@CopyToBackupDirectory				nvarchar(2000) = NULL,		-- { NULL | path_for_backup_copies } 
	@BackupRetentionHours				int,						-- Anything > this many hours will be DELETED. 
	@CopyToRetentionHours				int = NULL,					-- As above, but allows for diff retention settings to be configured for copied/secondary backups.
	@RemoveFilesBeforeBackup			bit = 0,					-- { 0 | 1 } - when true, then older backups will be removed BEFORE backups are executed.
	@EncryptionCertName					sysname = NULL,				-- Ignored if not specified. 
	@EncryptionAlgorithm				sysname = NULL,				-- Required if @EncryptionCertName is specified. AES_256 is best option in most cases.
	@AddServerNameToSystemBackupPath	bit	= 0,					-- If set to 1, backup path is: @BackupDirectory\<db_name>\<server_name>\
	@AllowNonAccessibleSecondaries		bit = 0,					-- If review of @DatabasesToBackup yields no dbs (in a viable state) for backups, exception thrown - unless this value is set to 1 (for AGs, Mirrored DBs) and then execution terminates gracefully with: 'No ONLINE dbs to backup'.
	@LogSuccessfulOutcomes				bit = 0,					-- By default, exceptions/errors are ALWAYS logged. If set to true, successful outcomes are logged to dba_DatabaseBackup_logs as well.
	@OperatorName						sysname = N'Alerts',
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Database Backups ] ',
	@PrintOnly							bit = 0						-- Instead of EXECUTING commands, they're printed to the console only. 	
AS
	SET NOCOUNT ON;

	-- Version Version 3.4.0.16590
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dba_DatabaseBackups_Log', 'U') IS NULL BEGIN;
		RAISERROR('Table dbo.dba_DatabaseBackups_Log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dba_SplitString', 'TF') IS NULL BEGIN;
		RAISERROR('Table-Valued Function dbo.dba_SplitString not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dba_LoadDatabaseNames', 'P') IS NULL BEGIN;
		RAISERROR('Stored Procedure dbo.dba_LoadDatabaseNames not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dba_CheckPaths', 'P') IS NULL BEGIN;
		RAISERROR('Stored Procedure dbo.dba_CheckPaths not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dba_ExecuteAndFilterNonCatchableCommand', 'P') IS NULL BEGIN;
		RAISERROR('Stored Procedure dbo.dba_ExecuteAndFilterNonCatchableCommand not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN;
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN;
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN;
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF (@PrintOnly = 0) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN; 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN;
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NULLIF(@BackupDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG') BEGIN;
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	IF UPPER(@DatabasesToBackup) = N'[READ_FROM_FILESYSTEM]' BEGIN;
		RAISERROR('@DatabasesToBackup may NOT be set to the token [READ_FROM_FILESYSTEM] when processing backups.', 16, 1);
		RETURN -9;
	END

	-- translate the hours settings:
	DECLARE @fileRetentionMinutes int = @BackupRetentionHours * 60;
	DECLARE @copyToFileRetentionMinutes int = @CopyToRetentionHours * 60;

	IF (DATEADD(MINUTE, 0 - @fileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN; 
		 RAISERROR('Invalid @BackupRetentionHours - greater than or equal to NOW.', 16, 1);
		 RETURN -10;
	END;

	IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN;
		IF (DATEADD(MINUTE, 0 - @copyToFileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN;
			RAISERROR('Invalid @CopyToBackupRetentionHours - greater than or equal to NOW.', 16, 1);
			RETURN -11;
		END;
	END;

	IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN;
		-- make sure the cert name is legit and that an encryption algorithm was specified:
		IF NOT EXISTS (SELECT NULL FROM master.sys.certificates WHERE name = @EncryptionCertName) BEGIN;
			RAISERROR('Certificate name specified by @EncryptionCertName is not a valid certificate (not found in sys.certificates).', 16, 1);
			RETURN -15;
		END

		IF NULLIF(@EncryptionAlgorithm, '') IS NULL BEGIN;
			RAISERROR('@EncryptionAlgorithm must be specified when @EncryptionCertName is specified.', 16, 1);
			RETURN -15;
		END;
	END;

	-----------------------------------------------------------------------------
	-- Determine which databases to backup:
	DECLARE @executingSystemDbBackups bit = 0;

	IF UPPER(@DatabasesToBackup) = '[SYSTEM]' BEGIN;
		SET @executingSystemDbBackups = 1;
	END; 

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.dba_LoadDatabaseNames
	    @Input = @DatabasesToBackup,
	    @Exclusions = @DatabasesToExclude,
		@Priorities = @Priorities,
	    @Mode = N'BACKUP',
	    @BackupType = @BackupType, 
		@Output = @serialized OUTPUT;

	DECLARE @targetDatabases table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDatabases ([database_name])
	SELECT [result] FROM dbo.dba_SplitString(@serialized, N',');

	-- verify that we've got something: 
	IF (SELECT COUNT(*) FROM @targetDatabases) <= 0 BEGIN;
		IF @AllowNonAccessibleSecondaries = 1 BEGIN;
			-- Because we're dealing with Mirrored DBs, we won't fail or throw an error here. Instead, we'll just report success (with no DBs to backup).
			PRINT 'No ONLINE databases available for backup. BACKUP terminating with success.';
			RETURN 0;

		   END; 
		ELSE BEGIN;
			PRINT 'Usage: @DatabasesToBackup = [SYSTEM]|[USER]|dbname1,dbname2,dbname3,etc';
			RAISERROR('No databases specified for backup.', 16, 1);
			RETURN -20;
		END;
	END;

	IF @BackupDirectory = @CopyToBackupDirectory BEGIN;
		RAISERROR('@BackupDirectory and @CopyToBackupDirectory can NOT be the same directory.', 16, 1);
		RETURN - 50;
	END;

	-- normalize paths: 
	IF(RIGHT(@BackupDirectory, 1) = '\')
		SET @BackupDirectory = LEFT(@BackupDirectory, LEN(@BackupDirectory) - 1);

	IF(RIGHT(@CopyToBackupDirectory, 1) = '\')
		SET @CopyToBackupDirectory = LEFT(@CopyToBackupDirectory, LEN(@CopyToBackupDirectory) - 1);

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- meta-data:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @operationStart datetime;
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @currentOperationID int;

	DECLARE @currentDatabase sysname;
	DECLARE @backupPath nvarchar(2000);
	DECLARE @copyToBackupPath nvarchar(2000);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @serverName sysname;
	DECLARE @extension sysname;
	DECLARE @now datetime;
	DECLARE @timestamp sysname;
	DECLARE @offset sysname;
	DECLARE @backupName sysname;
	DECLARE @encryptionClause nvarchar(2000);
	DECLARE @copyStart datetime;
	DECLARE @outcome varchar(4000);

	DECLARE @command nvarchar(MAX);
	
	-- Begin the backups:
	DECLARE backups CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name] 
	FROM 
		@targetDatabases
	ORDER BY 
		[entry_id];

	OPEN backups;

	FETCH NEXT FROM backups INTO @currentDatabase;
	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @errorMessage = NULL;
		SET @outcome = NULL;

		-- start by making sure the current DB (which we grabbed during initialization) is STILL online/accessible (and hasn't failed over/etc.): 
		IF @currentDatabase IN (SELECT [name] FROM 
				(SELECT [name] FROM sys.databases WHERE UPPER(state_desc) != N'ONLINE' 
				 UNION SELECT [name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE UPPER(hars.role_desc) != 'PRIMARY') x
		) BEGIN; 
			PRINT 'Skipping database: ' + @currentDatabase + ' because it is no longer available, online, or accessible.';
			GOTO NextDatabase;  -- just 'continue' - i.e., short-circuit processing of this 'loop'... 
		END 

		-- specify and verify path info:
		IF @executingSystemDbBackups = 1 AND @AddServerNameToSystemBackupPath = 1
			SET @serverName = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 
		ELSE 
			SET @serverName = N'';

		SET @backupPath = @BackupDirectory + N'\' + @currentDatabase + @serverName;
		SET @copyToBackupPath = REPLACE(@backupPath, @BackupDirectory, @CopyToBackupDirectory); 

		SET @operationStart = GETDATE();
		IF (@LogSuccessfulOutcomes = 1) AND (@PrintOnly = 0)  BEGIN;
			INSERT INTO dbo.dba_DatabaseBackups_Log (ExecutionId,BackupDate,[Database],BackupType,BackupPath,CopyToPath,BackupStart)
			VALUES(@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart);
			
			SELECT @currentOperationID = SCOPE_IDENTITY();
		END;

		IF @RemoveFilesBeforeBackup = 1 BEGIN;
			GOTO RemoveOlderFiles;  -- zip down into the logic for removing files, then... once that's done... we'll get sent back up here (to DoneRemovingFilesBeforeBackup) to execute the backup... 

DoneRemovingFilesBeforeBackup:
		END

		SET @command = 'EXECUTE master.dbo.xp_create_subdir N''' + @backupPath + ''';';

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN;
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'CREATEDIR', @result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

			END TRY
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception attempting to validate file path for backup: [' + @backupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH;
		END;

		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN;
			
			SET @command = 'EXECUTE master.dbo.xp_create_subdir N''' + @copyToBackupPath + ''';';

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN;
				BEGIN TRY 
					SET @outcome = NULL;
					EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'CREATEDIR', @result = @outcome OUTPUT;
					
					IF @outcome IS NOT NULL
						SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
				END TRY
				BEGIN CATCH
					SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception attempting to validate COPY_TO file path for backup: [' + @copyToBackupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
				END CATCH;
			END;

			IF @errorMessage IS NOT NULL
				GOTO NextDatabase;
		END;

		-- Create a Backup Name: 
		SET @extension = N'.bak';
		IF @BackupType = N'LOG'
			SET @extension = N'.trn';

		SET @now = GETDATE();
		SET @timestamp = REPLACE(REPLACE(REPLACE(CONVERT(sysname, @now, 120), '-','_'), ':',''), ' ', '_');
		SET @offset = RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),7);

		SET @backupName = @BackupType + N'_' + @currentDatabase + '_backup_' + @timestamp + '_' + @offset + @extension;

		SET @command = N'BACKUP {type} ' + QUOTENAME(@currentDatabase, N'[]') + N' TO DISK = N''' + @backupPath + N'\' + @backupName + ''' {MIRROR_TO}
	WITH 
		{COMPRESSION}{DIFFERENTIAL}{ENCRYPTION}{FORMAT}, NAME = N''' + @backupName + ''', SKIP, REWIND, NOUNLOAD, CHECKSUM;
	
	';

		IF @BackupType IN (N'FULL', N'DIFF')
			SET @command = REPLACE(@command, N'{type}', N'DATABASE');
		ELSE 
			SET @command = REPLACE(@command, N'{type}', N'LOG');

		IF @Edition IN (N'EXPRESS',N'WEB')
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'');
		ELSE 
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'COMPRESSION, ');

		IF @BackupType = N'DIFF'
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'DIFFERENTIAL, ');
		ELSE 
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'');

		IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN;
			SET @encryptionClause = ' ENCRYPTION (ALGORITHM = ' + ISNULL(@EncryptionAlgorithm, N'AES_256') + N', SERVER CERTIFICATE = ' + ISNULL(@EncryptionCertName, '') + N'), ';
			SET @command = REPLACE(@command, N'{ENCRYPTION}', @encryptionClause);
		  END;
		ELSE 
			SET @command = REPLACE(@command, N'{ENCRYPTION}','');

		-- NOTE: we only need to use FORMAT, INIT if a) we're on enteprise ed, and b) we're doing a MIRROR TO backup - otherwise, it's NOT needed. 
		IF @Edition = N'ENTERPRISE' AND NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN;
			SET @command = REPLACE(@command, N'{MIRROR_TO}', N'MIRROR TO DISK = N''' + @copyToBackupPath + N'\' + @backupName + N'''' + @crlf + @tab);
			SET @command = REPLACE(@command, N'{FORMAT}', N'FORMAT, INIT');
		  END;
		ELSE BEGIN;
			SET @command = REPLACE(@command, N'{MIRROR_TO}', N'');
			SET @command = REPLACE(@command, N'{FORMAT}', N'NOFORMAT, NOINIT');
		END;

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN;
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'BACKUP', @result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception executing backup with the following command: [' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH;
		END;

		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		IF @LogSuccessfulOutcomes = 1 BEGIN;
			UPDATE dbo.dba_DatabaseBackups_Log 
			SET 
				BackupEnd = GETDATE(),
				BackupSucceeded = 1, 
				VerificationCheckStart = GETDATE()
			WHERE 
				BackupId = @currentOperationID;
		END;

		-----------------------------------------------------------------------------
		-- Kick off the verification:
		SET @command = N'RESTORE VERIFYONLY FROM DISK = N''' + @backupPath + N'\' + @backupName + N''' WITH NOUNLOAD, NOREWIND;';

		IF @PrintOnly = 1 
			PRINT @command;
		ELSE BEGIN;
			BEGIN TRY
				EXEC sys.sp_executesql @command;

				IF @LogSuccessfulOutcomes = 1 BEGIN;
					UPDATE dbo.dba_DatabaseBackups_Log
					SET 
						VerificationCheckEnd = GETDATE(),
						VerificationCheckSucceeded = 1
					WHERE
						BackupId = @currentOperationID;
				END;
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception during backup verification for backup of database: ' + @currentDatabase + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';

					UPDATE dbo.dba_DatabaseBackups_Log
					SET 
						VerificationCheckEnd = GETDATE(),
						VerificationCheckSucceeded = 0,
						ErrorDetails = @errorMessage
					WHERE
						BackupId = @currentOperationID;

				GOTO NextDatabase;
			END CATCH;
		END;

		-----------------------------------------------------------------------------
		-- Execute Copy if a copy was specified and we're NOT on Enterprise Edition:
		IF @CopyToBackupDirectory IS NOT NULL BEGIN;

			IF @Edition = 'ENTERPRISE' BEGIN;
				IF @LogSuccessfulOutcomes = 1 BEGIN;
					UPDATE dbo.dba_DatabaseBackups_Log
					SET 
						CopyDetails = N'COPIED TO DESTINATION via Enterprise Edition''s MIRROR TO clause.'
					WHERE 
						BackupId = @currentOperationID;
				END;
			  END;
			ELSE BEGIN 
				DECLARE @copyOutput TABLE ([output] nvarchar(2000));
				DELETE FROM @copyOutput;

				SET @command = 'EXEC xp_cmdshell ''COPY "' + @backupPath + N'\' + @backupName + '" "' + @copyToBackupPath + '\"''';
				SET @copyStart = GETDATE();

				IF @PrintOnly = 1
					PRINT @command;
				ELSE BEGIN;
					BEGIN TRY

						INSERT INTO @copyOutput ([output])
						EXEC sys.sp_executesql @command;

						IF NOT EXISTS(SELECT NULL FROM @copyOutput WHERE [output] LIKE '%1 file(s) copied%') BEGIN; -- there was an error, and we didn't copy the file.
							SET @errorMessage = ISNULL(@errorMessage, '') + (SELECT TOP 1 [output] FROM @copyOutput WHERE [output] IS NOT NULL AND [output] NOT LIKE '%0 file(s) copied%') + N' ';
						END;

						IF @LogSuccessfulOutcomes = 1 BEGIN 
							UPDATE dbo.dba_DatabaseBackups_Log
							SET 
								CopyDetails = N'Started at {' + CONVERT(nvarchar(20), @copyStart, 120) + N'}, completed at {' + CONVERT(nvarchar(20), GETDATE(), 120) + '}. Outcome: SUCCESS.'
							WHERE
								BackupId = @currentOperationID;
						END;
					END TRY
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error copying backup to [' + @copyToBackupPath + @serverName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
					END CATCH;

					IF @errorMessage IS NOT NULL BEGIN;
						UPDATE dbo.dba_DatabaseBackups_Log
						SET 
							CopyDetails = N'Started at {' + CONVERT(nvarchar(20), @copyStart, 120) + N'}, completed at {' + CONVERT(nvarchar(20), GETDATE(), 120) + '}. Outcome: FAILURE. Details: ' + @errorMessage + N' '
						WHERE 
							BackupId = @currentOperationID;

						GOTO NextDatabase;
					END;
				END;				
			END;
		END;

		-----------------------------------------------------------------------------
		-- Remove backups:
		-- Branch into this logic either by means of a GOTO (called from above) or by means of evaluating @RemoveFilesBeforeBackup.... 
		IF @RemoveFilesBeforeBackup = 0 BEGIN;
			
RemoveOlderFiles:
			BEGIN TRY

				IF @PrintOnly = 1 BEGIN;
					PRINT '-- EXEC dbo.dba_RemoveBackupFiles @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @CopyToBackupDirectory + ''', @RetentionMinutes = ' + CAST(@copyToFileRetentionMinutes AS varchar(30)) + ', @PrintOnly = 1;';
					
					EXEC dbo.dba_RemoveBackupFiles
						@BackupType= @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@TargetDirectory = @BackupDirectory,
						@RetentionMinutes = @fileRetentionMinutes, 
						@PrintOnly = 1;

				  END;
				ELSE BEGIN;
					SET @outcome = 'OUTPUT';
					DECLARE @Output nvarchar(MAX);
					EXEC dbo.dba_RemoveBackupFiles
						@BackupType= @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@TargetDirectory = @BackupDirectory,
						@RetentionMinutes = @fileRetentionMinutes, 
						@Output = @outcome OUTPUT;

					IF @outcome IS NOT NULL 
						SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + ' ';

				END

				IF NULLIF(@CopyToBackupDirectory,'') IS NOT NULL BEGIN;
				
					IF @PrintOnly = 1 BEGIN;
						PRINT '-- EXEC dbo.dba_RemoveBackupFiles @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @CopyToBackupDirectory + ''', @RetentionMinutes = ' + CAST(@copyToFileRetentionMinutes AS varchar(30)) + ', @PrintOnly = 1;';
						
						EXEC dbo.dba_RemoveBackupFiles
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@RetentionMinutes = @copyToFileRetentionMinutes,
							@PrintOnly = 1;

					  END;
					ELSE BEGIN;
						SET @outcome = 'OUTPUT';
					
						EXEC dbo.dba_RemoveBackupFiles
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@RetentionMinutes = @copyToFileRetentionMinutes,
							@Output = @outcome OUTPUT;					
					
						IF @outcome IS NOT NULL
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
					END
				END
			END TRY 
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + 'Unexpected Error removing backups. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH

			IF @RemoveFilesBeforeBackup = 1 BEGIN;
				IF @errorMessage IS NULL -- there weren't any problems/issues - so keep processing.
					GOTO DoneRemovingFilesBeforeBackup;

				-- otherwise, the remove operations failed, they were set to run FIRST, which means we now might not have enough disk - so we need to 'fail' this operation and move on to the next db... 
				GOTO NextDatabase;
			END
		END

NextDatabase:
		IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
			CLOSE nuker;
			DEALLOCATE nuker;
		END;

		IF NULLIF(@errorMessage,'') IS NOT NULL BEGIN;
			IF @PrintOnly = 1 
				PRINT @errorMessage;
			ELSE BEGIN;
				IF @currentOperationId IS NULL BEGIN;
					INSERT INTO dbo.dba_DatabaseBackups_Log (ExecutionId,BackupDate,[Database],BackupType,BackupPath,CopyToPath,BackupStart,BackupEnd,BackupSucceeded,ErrorDetails)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(), 0, @errorMessage);
				  END;
				ELSE BEGIN;
					UPDATE dbo.dba_DatabaseBackups_Log
					SET 
						ErrorDetails = @errorMessage
					WHERE 
						BackupId = @currentOperationID;
				END;
			END;
		END; 

		PRINT '
';

		FETCH NEXT FROM backups INTO @currentDatabase;
	END;

	CLOSE backups;
	DEALLOCATE backups;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- Cleanup:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','backups')) > -1 BEGIN;
		CLOSE backups;
		DEALLOCATE backups;
	END;

	DECLARE @emailErrorMessage nvarchar(MAX);

	IF EXISTS (SELECT NULL FROM dbo.dba_DatabaseBackups_Log WHERE ExecutionId = @executionID AND ErrorDetails IS NOT NULL) BEGIN;
		SET @emailErrorMessage = N'The following errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Target Database: [' + [Database] + N']. Error: ' + ErrorDetails + @crlf + @crlf
		FROM 
			dbo.dba_DatabaseBackups_Log
		WHERE 
			ExecutionId = @executionID
			AND ErrorDetails IS NOT NULL 
		ORDER BY 
			BackupId;

	END;

	DECLARE @emailSubject nvarchar(2000);
	IF @emailErrorMessage IS NOT NULL BEGIN;
		
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
		
		IF @Edition != 'EXPRESS' BEGIN;
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;

		-- make sure the sproc FAILS at this point (especially if this is a job). 
		SET @errorMessage = N'One or more operations failed. Execute [ SELECT * FROM master.dbo.dba_DatabaseBackups_Log WHERE ExecutionID = ''' + CAST(@executionID AS nvarchar(36)) + N'''; ] for details.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -100;
	END;

	RETURN 0;
GO