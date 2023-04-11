/*
	NOTES:
        - WARNING: This script does what it says - it'll remove files exactly as specified. 
		
		- This sproc adheres to the PROJECT/REPLY usage convention.
			   
		- Not yet documented. 


	vNEXT: 
		- Set up a defaulted 'safety' where script/logic will NEVER delte the most recent FULL backup for any database. 
			i.e., something along the lines of @AlwaysKeepLastFullBackup bit = 1 (by default). 
				such that it has to be explicitly overridden to remove the last FULL. 
				Then again? maybe NOT... 


	SAMPLE SIGNATURE:

		EXEC dbo.remove_backup_files 
			@BackupType = 'FULL', -- sysname
			@DatabasesToProcess = N'{READ_FROM_FILESYSTEM}', -- nvarchar(1000)
			@DatabasesToExclude = N'', -- nvarchar(600)
			@TargetDirectory = N'D:\SQLBackups', -- nvarchar(2000)
			@Retention = '12m', -- int
			@PrintOnly = 1 -- bit

*/

USE [admindb];
GO

IF OBJECT_ID('[dbo].[remove_backup_files]','P') IS NOT NULL
	DROP PROC [dbo].[remove_backup_files];
GO

CREATE PROC [dbo].[remove_backup_files] 
	@BackupType							sysname,									-- { {ALL} | FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),								-- { {READ_FROM_FILESYSTEM} | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,						-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000) = N'{DEFAULT}',				-- { path_to_backups }
	@Retention							nvarchar(10),								-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@ServerNameInSystemBackupPath		bit = 0,									-- for mirrored servers/etc.
	@SendNotifications					bit	= 0,									-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
    @Output								nvarchar(MAX) = N'default' OUTPUT,			-- When explicitly set to NULL, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@PrintOnly							bit = 0 									-- { 0 | 1 }
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
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
	
	IF ((@PrintOnly = 0) OR (NULLIF(@Output, N'default') IS NULL)) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN; 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
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

	IF UPPER(@TargetDirectory) = N'{DEFAULT}' BEGIN
		SELECT @TargetDirectory = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG', '{ALL}') BEGIN;
		RAISERROR('Invalid @BackupType Specified. Allowable values are { {ALL} |  FULL | DIFF | LOG }.', 16, 1);

		RETURN -7;
	END;

	SET @Retention = LTRIM(RTRIM(REPLACE(@Retention, N' ', N'')));

	DECLARE @retentionType char(1);
	DECLARE @retentionValue bigint;
	DECLARE @retentionError nvarchar(MAX);
	DECLARE @retentionCutoffTime datetime; 

	IF UPPER(@Retention) = N'INFINITE' BEGIN 
		PRINT N'-- INFINITE retention detected. Terminating cleanup process.';
		RETURN 0;
	END;

	IF UPPER(@Retention) LIKE '%B%' OR UPPER(@Retention) LIKE '%BACKUP%' BEGIN 
		
		DECLARE @boundary int = PATINDEX(N'%[^0-9]%', @Retention)- 1;

		IF @boundary < 1 BEGIN 
			SET @retentionError = N'Invalid Vector format specified for parameter @Retention. Format must be in ''XX nn'' or ''XXnn'' format - where XX is an ''integer'' duration (e.g., 72) and nn is an interval-specifier (e.g., HOUR, HOURS, H, or h).';
			RAISERROR(@retentionError, 16, 1);
			RETURN -1;
		END;

		BEGIN TRY

			SET @retentionValue = CAST((LEFT(@Retention, @boundary)) AS int);
		END TRY
		BEGIN CATCH
			SET @retentionValue = -1;
		END CATCH

		IF @retentionValue < 0 BEGIN 
			RAISERROR('Invalid @Retention value specified. Number of Backups specified was formatted incorrectly or < 0.', 16, 1);
			RETURN -25;
		END;

		SET @retentionType = 'b';
	  END;
	ELSE BEGIN 

		EXEC dbo.[translate_vector_datetime]
		    @Vector = @Retention, 
		    @Operation = N'SUBTRACT', 
		    @ValidationParameterName = N'@Retention', 
		    @ProhibitedIntervals = N'BACKUP', 
		    @Output = @retentionCutoffTime OUTPUT, 
		    @Error = @retentionError OUTPUT;

		IF @retentionError IS NOT NULL BEGIN 
			RAISERROR(@retentionError, 16, 1);
			RETURN -26;
		END;
	END;

	IF @PrintOnly = 1 BEGIN 
		IF @retentionType = 'b'
			PRINT '-- Retention specification is to keep the last ' + CAST(@retentionValue AS sysname) + ' backup(s).';
		ELSE 
			PRINT '-- Retention specification is to remove backups created before [' + CONVERT(sysname, @retentionCutoffTime, 120) + N'].';
	END;

	SET @TargetDirectory = dbo.[normalize_file_path](@TargetDirectory);

	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		RAISERROR('Invalid @TargetDirectory specified - either the path does not exist, or SQL Server''s Service Account does not have permissions to access the specified directory.', 16, 1);
		RETURN -10;
	END;

	-----------------------------------------------------------------------------
	SET @Output = NULL;

	DECLARE @excludeSimple bit = 0;

	IF @BackupType = N'LOG'
		SET @excludeSimple = 1;

	IF ((SELECT dbo.[count_matches](@DatabasesToProcess, N'{READ_FROM_FILESYSTEM}')) > 0) BEGIN
		
		SET @excludeSimple = 0; /* DBs that might now/currently be SIMPLE might have T-LOGs that need to be cleaned up.... */

		DECLARE @databases xml = NULL;
		DECLARE @serialized nvarchar(MAX) = '';

		EXEC dbo.[load_backup_database_names]
		    @TargetDirectory = @TargetDirectory,
		    @SerializedOutput = @databases OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@databases.nodes('//database') [data]([row])
		) 

		SELECT 
			@serialized = @serialized + [database_name] + N','
		FROM 
			shredded 
		ORDER BY 
			row_id;

		IF LEN(@serialized) > 1
			SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);

		IF NULLIF(@serialized, N'') IS NULL BEGIN 
			RAISERROR(N'@TargetDatabases was set to {READ_FROM_FILESYSTEM} but the path ''%s'' specified by @TargetDirectory contained no sub-directories (that could be treated as locations for database backups).', 16, 1, @TargetDirectory);
			RETURN -20;
		END;

		SET @DatabasesToProcess = REPLACE(@DatabasesToProcess, N'{READ_FROM_FILESYSTEM}', @serialized); 
	END;

	DECLARE @targetDirectories table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL,
        [directory_name] sysname NULL
    ); 

	INSERT INTO @targetDirectories ([database_name])
	EXEC dbo.list_databases
	    @Targets = @DatabasesToProcess,
	    @Exclusions = @DatabasesToExclude,
		@ExcludeSimpleRecovery = @excludeSimple;

	UPDATE @targetDirectories SET [directory_name] = [database_name] WHERE [directory_name] IS NULL;

	-----------------------------------------------------------------------------
	-- Account for backups of system databases with the server-name in the path:  
	IF @ServerNameInSystemBackupPath = 1 BEGIN
		
		-- simply add additional/'duplicate-ish' directories to check for anything that's a system database:
		DECLARE @serverName sysname = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 

		-- and, note that IF we hand off the name of an invalid directory (i.e., say admindb backups are NOT being treated as system - so that D:\SQLBackups\admindb\SERVERNAME\ was invalid, then xp_dirtree (which is what's used to query for files) will simply return 'empty' results and NOT throw errors.
		INSERT INTO @targetDirectories ([database_name], [directory_name])
		SELECT 
			[database_name],
			[directory_name] + @serverName 
		FROM 
			@targetDirectories
		WHERE 
			[directory_name] IN (N'master', N'msdb', N'model', N'admindb'); 
	END;

	-----------------------------------------------------------------------------
	-- Process files for removal:
	DECLARE @currentDb sysname;
	DECLARE @currentDirectory sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @targetPath nvarchar(512);
	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @file nvarchar(512);
	DECLARE @outcome xml;

	DECLARE @serializedFiles xml; 

	DECLARE @files table (
		[id] int IDENTITY(1,1) NOT NULL, 
		[file_name] nvarchar(MAX) NOT NULL, 
		[timestamp] datetime NOT NULL
	);

	DECLARE @lastN table ( 
		id int IDENTITY(1,1) NOT NULL, 
		original_id int NOT NULL, 
		backup_name nvarchar(512), 
		backup_type sysname
	);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL
	);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name], [directory_name]
	FROM 
		@targetDirectories
	ORDER BY 
		[entry_id];

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDb, @currentDirectory;

	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @targetPath = @TargetDirectory + N'\' + @currentDirectory;

		-- cleanup from previous passes
		SET @errorMessage = NULL;
		
		DELETE FROM @files;
		SET @serializedFiles = NULL;

		IF @PrintOnly = 1 BEGIN
			PRINT N'-- EXEC admindb.dbo.load_backup_files @DatabaseToRestore = N''' + @currentDb + N''', @SourcePath = N''' + @targetPath + N''', @Mode = N''LIST''; ';
		END;

		EXEC dbo.load_backup_files 
			@DatabaseToRestore = @currentDb, 
			@SourcePath = @targetPath, 
			@Mode = N'LIST', 
			@Output = @serializedFiles OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [id], 
				[data].[row].value('@file_name', 'nvarchar(max)') [file_name],
				[data].[row].value('@timestamp', 'datetime') [timestamp]
			FROM 
				@serializedFiles.nodes('//file') [data]([row])
		) 
		INSERT INTO @files (
			[file_name],
			[timestamp]
		)
		SELECT 
			[file_name],
			[timestamp]	
		FROM 
			shredded 
		ORDER BY 
			id;

		IF @retentionType = 'b' BEGIN -- Remove all backups of target type except the most recent N (where N is @retentionValue).
			
			-- clear out any state from previous iterations:
			DELETE FROM @lastN;

			IF @BackupType IN ('LOG', '{ALL}') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					[file_name], 
					'LOG'
				FROM 
					@files
				WHERE 
					[file_name] LIKE 'LOG%.trn'
				ORDER BY 
					id DESC;

				IF @BackupType != '{ALL}' BEGIN
					DELETE FROM @files WHERE [file_name] NOT LIKE '%.trn';  -- if we're NOT doing {ALL}, then remove DIFF and FULL backups... 
				END;
			END;

			IF @BackupType IN ('FULL', '{ALL}') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					[file_name], 
					'FULL'
				FROM 
					@files
				WHERE 
					[file_name] LIKE 'FULL%.bak'
				ORDER BY 
					id DESC;

				IF @BackupType != '{ALL}' BEGIN 
					DELETE FROM @files WHERE [file_name] NOT LIKE 'FULL%.bak'; -- if we're NOT doing all, then remove all non-FULL backups...  
				END
			END;

			IF @BackupType IN ('DIFF', '{ALL}') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					[file_name], 
					'DIFF'
				FROM 
					@files
				WHERE 
					[file_name] LIKE 'DIFF%.bak'
				ORDER BY 
					id DESC;

					IF @BackupType != '{ALL}' BEGIN 
						DELETE FROM @files WHERE [file_name] NOT LIKE 'DIFF%.bak'; -- if we're NOT doing all, the remove non-DIFFs so they won't be nuked.
					END
			END;
			
			-- prune any/all files we're supposed to keep: 
			DELETE x 
			FROM 
				@files x 
				INNER JOIN @lastN l ON x.id = l.original_id AND x.[file_name] = l.backup_name;

		  END;
		ELSE BEGIN -- Any backups older than @RetentionCutoffTime are removed. 

			IF @BackupType IN ('LOG', '{ALL}') BEGIN;
			
				DELETE FROM @files WHERE [timestamp] >= @retentionCutoffTime; -- Remove any files we should keep.
				
				IF @BackupType != '{ALL}' BEGIN
					DELETE FROM @files WHERE [file_name] NOT LIKE '%.trn';  -- if we're NOT doing {ALL}, then remove DIFF and FULL backups... 
				END;
			END

			IF @BackupType IN ('FULL', 'DIFF', '{ALL}') BEGIN;

				DELETE FROM @files WHERE [file_name] NOT LIKE '%.bak'; -- remove (from processing) any files that don't use the .bak extension. 

				-- If a specific backup type is specified ONLY target that backup type:
				IF @BackupType != N'ALL' BEGIN;
				
					IF @BackupType = N'FULL'
						DELETE FROM @files WHERE [file_name] NOT LIKE N'FULL%';

					IF @BackupType = N'DIFF'
						DELETE FROM @files WHERE [file_name] NOT LIKE N'DIFF%';
				END

				DELETE FROM @files WHERE [timestamp] >= @retentionCutoffTime;
		    END
		END;

		-- whatever is left is what we now need to nuke/remove:
		DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
		SELECT [file_name] FROM @files 
		ORDER BY id;

		OPEN nuker;
		FETCH NEXT FROM nuker INTO @file;

		WHILE @@FETCH_STATUS = 0 BEGIN;

			-- reset per each 'grab':
			SET @errorMessage = NULL;
			SET @command = N'del /q /f "' + @targetPath + N'\' + @file + N'"';

			BEGIN TRY
					
				EXEC dbo.[execute_command]
					@Command = @command,
					@ExecutionType = N'SHELL',
					@ExecutionAttemptsCount = 1,
					@IgnoredResults = N'{DELETEFILE}',
					@PrintOnly = @PrintOnly,
					@Outcome = @outcome OUTPUT, 
					@ErrorMessage = @errorMessage OUTPUT;

			END TRY 
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') +  N'Error deleting Backup File with command: [' + ISNULL(@command, '##NOT SET YET##') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH


			IF @errorMessage IS NOT NULL BEGIN;
				SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

				INSERT INTO @errors ([error_message])
				VALUES (@errorMessage);
			END

			FETCH NEXT FROM nuker INTO @file;
		END;

		CLOSE nuker;
		DEALLOCATE nuker;

		FETCH NEXT FROM processor INTO @currentDb, @currentDirectory;
	END

	CLOSE processor;
	DEALLOCATE processor;

	-----------------------------------------------------------------------------
	-- Cleanup:

	IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
		CLOSE nuker;
		DEALLOCATE nuker;
	END;

	-----------------------------------------------------------------------------
	-- Error Reporting:
	DECLARE @errorInfo nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	DECLARE @routeInfoAsOutput bit = 0;
	IF @Output IS NULL
		SET @routeInfoAsOutput = 1; 

	IF EXISTS (SELECT NULL FROM @errors) BEGIN;
		
		-- format based on output type (output variable or email/error-message), then 'raise, return, or send'... 
		IF @routeInfoAsOutput = 1 BEGIN;
			SELECT @errorInfo = @errorInfo + [error_message] + N', ' FROM @errors ORDER BY error_id;
			SET @errorInfo = LEFT(@errorInfo, LEN(@errorInfo) - 2);

			SET @Output = @errorInfo;
		  END
		ELSE BEGIN;

			SELECT @errorInfo = @errorInfo + @tab + N'- ' + [error_message] + @crlf + @crlf
			FROM 
				@errors
			ORDER BY 
				error_id;

			IF (@SendNotifications = 1) AND (@Edition != 'EXPRESS') BEGIN;
				DECLARE @emailSubject nvarchar(2000);
				SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

				SET @errorInfo = N'The following errors were encountered: ' + @crlf + @errorInfo;

				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @errorInfo;				
			END

			-- this is being executed as a stand-alone job (most likely) so... throw the output into the job's history... 
			PRINT @errorInfo;  
			
			RAISERROR(@errorMessage, 16, 1);
			RETURN -100;
		END
	END;

	RETURN 0;
GO