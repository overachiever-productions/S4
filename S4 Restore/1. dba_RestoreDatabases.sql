

/*
	WARNINGS:
		- Used INCORRECTLY, this sproc CAN drop/overwrite production databases. 
			This was DESIGNED to be hard to do. 
			To do this, you HAVE both leave the @RestoredDbNameSuffix empty/blank AND specify 'REPLACE' as the value for @AllowReplace. 
				Typically, because these are 2x explicit operations - it'll be HARD to 'hose yourself'. 
				HOWEVER, if you copy/paste + tweak a set of previously defined parameters to create a new set of parameters
					you COULD accidentally leave BOTH of the above conditions true AND specify the name of a DB that you do NOT want to overwrite. 

		- NOT supported (i.e., won't even work) on Express editions (due to alerting options).


	DEPENDENCIES:
		- Requires dbo.dba_DatabaseRestore_Log - to log information about restore operations AND failures. 
		- Requires dba_LoadDatabaseNames - sproc used to 'parse' or determine which dbs to target based upon inputs.
		- Requires dbo.dba_CheckPaths - to facilitate validation of specified AND created database backup file paths. 
		- Requires dbo.dba_ExecuteAndFilterNonCatchableCommand - to address problems with TRY/CATCH error handling within SQL Server. 
		- Requires that xp_cmdshell be enabled - to address issue with TRY/CATCH. 
		- Requires a configured Database Mail Profile + SQL Server Agent Operator. 

		- DEPENDS very heavily upon the conventions defined in dbo.dba_BackupDatabases - i.e., in terms of file-names (primarily for FULL vs DIFF) backups. 
			(or, in other words, this sproc does NOT interrogate .BAK files to see which might/might-not apply when restoring all possible files
			available for a restore operation - instead it uses FILE-names (and their time-stamps) to restore the most recent FULL + most-recent DIFF (if 
				present) + all T-LOGs since the most-recent FULL or DIFF applied/used. 

	NOTES:
		- There's a serious bug/problem with T-SQL and how it handles TRY/CATCH (or other error-handling) operations:
			https://connect.microsoft.com/SQLServer/feedback/details/746979/try-catch-construct-catches-last-error-only
			This sproc gets around that limitation via the logic defined in dbo.dba_ExecuteAndFilterNonCatchableCommand;


	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple


	TODO:
		- Look at implementing MINIMAL 'retry' logic - as per dba_BackupDatabases. Or... maybe don't... 
		- POSSIBLY look at an option where @DatabasesToRestore can be set to [QUERY_FILE_SYSTEM] and... we then do a query against @BackupsRootPath for 
			all FOLDER names (not file names) and then execute restore operations against any (non-system-named) folders to get a list of DBs to restore. 
			that ... wouldn't suck at all.

		- Possible issue where TIMING isn't the right way to determine which LOG backups to use. i.e., suppose we start a FULL _OR_ DIFF backup at 6PM - and it takes 20 minutes to exeucte. 
			then... suppose we're doing T-LOG backups every 5 minutes - i.e., 5 after the hour. 
				I'm _PRETTY_ sure that we'd want the 6:25 backup as our next T-LOG backup... 
					BUT there are two other possibilities:
						the 6:20 log backup MIGHT have just barely 'beat' the full/diff backup
						MAYBE we want the 6:05 backup (pretty sure we don't). 
				IF this ends up being a case of needing the 6:05 or the 6:20 log backup
					the only thing I can think to do would be:
						try to 
							a) do a RESTORE FILELIST ONLY from the last full/diff we're applying
							b) grab SOME timestamp out of that (or... sadly, an LSN)
							c) figure out some way to use that timestamp/LSN agains the LIST of files we've already pulled back from the OS/file-system
								i.e., right now I delete * < Max(LastFullBackup)... then do the same with Logs vs LAST(FULL|DIFF)... 
										so I might need to HOLD off on deleting log files until i get the LSN or some time-stamp... then read from the t-logs themselves and try that... (sigh).

			FODDER: 
				https://www.sqlskills.com/blogs/paul/sqlskills-sql101-why-is-restore-slower-than-backup/

*/

USE master;
GO


IF OBJECT_ID('dba_RestoreDatabases','P') IS NOT NULL
	DROP PROC dba_RestoreDatabases;
GO

CREATE PROC dbo.dba_RestoreDatabases 
	@DatabasesToRestore				nvarchar(MAX),
	@DatabasesToExclude				nvarchar(MAX) = NULL,
	@Priorities						nvarchar(MAX) = NULL,
	@BackupsRootPath				nvarchar(MAX),
	@RestoredRootDataPath			nvarchar(MAX),
	@RestoredRootLogPath			nvarchar(MAX),
	@RestoredDbNamePattern			nvarchar(40) = N'{0}_test',
	@AllowReplace					nchar(7) = NULL,		-- NULL or the exact term: N'REPLACE'...
	@SkipLogBackups					bit = 0,
	@CheckConsistency				bit = 1,
	@DropDatabasesAfterRestore		bit = 0,				-- Only works if set to 1, and if we've RESTORED the db in question. 
	@MaxNumberOfFailedDrops			int = 1,				-- number of failed DROP operations we'll tolerate before early termination.
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[RESTORE TEST] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )
	-- To determine current/deployed version, execute the following: SELECT CAST([value] AS sysname) [Version] FROM master.sys.extended_properties WHERE major_id = OBJECT_ID('dbo.dba_DatabaseBackups_Log') AND [name] = 'Version';	

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dba_DatabaseRestore_Log', 'U') IS NULL BEGIN
		RAISERROR('Table dbo.dba_DatabaseRestore_Log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;
	
	IF OBJECT_ID('dba_LoadDatabaseNames', 'P') IS NULL BEGIN
		RAISERROR('Stored Procedure dbo.dba_LoadDatabaseNames not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dba_CheckPaths', 'P') IS NULL BEGIN
		RAISERROR('Stored Procedure dbo.dba_CheckPaths not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dba_ExecuteAndFilterNonCatchableCommand','P') IS NULL BEGIN
		RAISERROR('Stored Procedure dbo.dba_ExecuteAndFilterNonCatchableCommand not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16, 1);
		RETURN -1;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -2;
		 END;
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -2;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -2;
		END; 
	END;

	IF @MaxNumberOfFailedDrops <= 0 BEGIN
		RAISERROR('@MaxNumberOfFailedDrops must be set to a value of 1 or higher.', 16, 1);
		RETURN -6;
	END;

	IF NULLIF(@AllowReplace, '') IS NOT NULL AND UPPER(@AllowReplace) != N'REPLACE' BEGIN
		RAISERROR('The @AllowReplace switch must be set to NULL or the exact term N''REPLACE''.', 16, 1);
		RETURN -4;
	END;

	IF @AllowReplace IS NOT NULL AND @DropDatabasesAfterRestore = 1 BEGIN
		RAISERROR('Databases cannot be explicitly REPLACED and DROPPED after being replaced. If you wish DBs to be restored (on a different server for testing) with SAME names as PROD, simply leave suffix empty (but not NULL) and leave @AllowReplace NULL.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@DatabasesToRestore) IN (N'[SYSTEM]', N'[USER]') BEGIN
		RAISERROR('The tokens [SYSTEM] and [USER] cannot be used to specify which databases to restore via dba_RestoreDatabases. Use either [READ_FROM_FILESYSTEM] (plus any exclusions via @DatabasesToExclude), or specify a comma-delimited list of databases to restore.', 16, 1);
		RETURN -10;
	END;

	IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
		SET @DatabasesToExclude = NULL;

	IF (@DatabasesToExclude IS NOT NULL) AND (UPPER(@DatabasesToRestore) != N'[READ_FROM_FILESYSTEM]') BEGIN
		RAISERROR('@DatabasesToExclude can ONLY be specified when @DatabasesToRestore is defined as the [READ_FROM_FILESYSTEM] token. Otherwise, if you don''t want a database restored, don''t specify it in the @DatabasesToRestore ''list''.', 16, 1);
		RETURN -20;
	END;

	IF (NULLIF(@RestoredDbNamePattern,'')) IS NULL BEGIN
		RAISERROR('@RestoredDbNamePattern can NOT be NULL or empty. It MAY also contain the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname'').', 16, 1);
		RETURN -22;
	END;

	-- 'Global' Variables:
	DECLARE @isValid bit;
	DECLARE @earlyTermination nvarchar(MAX) = N'';
	DECLARE @emailErrorMessage nvarchar(MAX);
	DECLARE @emailSubject nvarchar(300);
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @restoreSucceeded bit;
	DECLARE @failedDrops int = 0;

	-- Verify Paths: 
	EXEC dbo.dba_CheckPaths @BackupsRootPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END
	
	EXEC dbo.dba_CheckPaths @RestoredRootDataPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@RestoredRootDataPath (' + @RestoredRootDataPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END

	EXEC dbo.dba_CheckPaths @RestoredRootLogPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@RestoredRootLogPath (' + @RestoredRootLogPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END

	-----------------------------------------------------------------------------
	-- Construct list of databases to restore:
	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.dba_LoadDatabaseNames
	    @Input = @DatabasesToRestore,         
	    @Exclusions = @DatabasesToExclude,		-- only works if [READ_FROM_FILESYSTEM] is specified for @Input... 
		@Priorities = @Priorities,
	    @Mode = N'RESTORE',
	    @TargetDirectory = @BackupsRootPath, 
		@Output = @serialized OUTPUT;

	DECLARE @dbsToRestore table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @dbsToRestore ([database_name])
	SELECT [result] FROM dbo.dba_SplitString(@serialized, N',');

	IF NOT EXISTS (SELECT NULL FROM @dbsToRestore) BEGIN;
		RAISERROR('No Databases Specified to Restore. Please Check inputs for @DatabasesToRestore + @DatabasesToExclude and retry.', 16, 1);
		RETURN -20;
	END

	IF @PrintOnly = 1 BEGIN;
		PRINT '-- Databases To Attempt Restore Against: ' + @serialized;
	END

	DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@dbsToRestore
	WHERE
		LEN([database_name]) > 0
	ORDER BY 
		entry_id;

	DECLARE @databaseToRestore sysname;
	DECLARE @restoredName sysname;

	DECLARE @fullRestoreTemplate nvarchar(MAX) = N'RESTORE DATABASE [{0}] FROM DISK = N''{1}'' WITH {move},{replace} NORECOVERY;'; 
	DECLARE @move nvarchar(MAX);
	DECLARE @restoreLogId int;
	DECLARE @sourcePath nvarchar(500);
	DECLARE @statusDetail nvarchar(500);
	DECLARE @pathToDatabaseBackup nvarchar(600);
	DECLARE @outcome varchar(4000);

	DECLARE @temp TABLE (
		[id] int IDENTITY(1,1), 
		[output] varchar(500)
	);

	-- Assemble a list of dbs (if any) that were NOT dropped during the last execution (only) - so that we can drop them before proceeding. 
	DECLARE @NonDroppedFromPreviousExecution table( 
		[Database] sysname NOT NULL, 
		RestoredAs sysname NOT NULL
	);

	DECLARE @LatestBatch uniqueidentifier;
	SELECT @LatestBatch = (SELECT TOP 1 ExecutionId FROM dbo.dba_DatabaseRestore_Log ORDER BY RestorationTestId DESC);

	INSERT INTO @NonDroppedFromPreviousExecution ([Database], RestoredAs)
	SELECT [Database], RestoredAs 
	FROM dbo.dba_DatabaseRestore_Log 
	WHERE ExecutionId = @LatestBatch
		AND Dropped = 'NOT-DROPPED'
		AND RestoredAs IN (SELECT name FROM sys.databases WHERE UPPER(state_desc) = 'RESTORING');  -- make sure we're only targeting DBs in the 'restoring' state too. 

	IF @CheckConsistency = 1 BEGIN
		IF OBJECT_ID('tempdb..##DBCC_OUTPUT') IS NOT NULL 
			DROP TABLE ##DBCC_OUTPUT;

		CREATE TABLE ##DBCC_OUTPUT(
				RowID int IDENTITY(1,1) NOT NULL, 
				Error int NULL,
				[Level] int NULL,
				[State] int NULL,
				MessageText nvarchar(2048) NULL,
				RepairLevel nvarchar(22) NULL,
				[Status] int NULL,
				[DbId] int NULL, -- was smallint in SQL2005
				DbFragId int NULL,      -- new in SQL2012
				ObjectId int NULL,
				IndexId int NULL,
				PartitionId bigint NULL,
				AllocUnitId bigint NULL,
				RidDbId smallint NULL,  -- new in SQL2012
				RidPruId smallint NULL, -- new in SQL2012
				[File] smallint NULL,
				[Page] int NULL,
				Slot int NULL,
				RefDbId smallint NULL,  -- new in SQL2012
				RefPruId smallint NULL, -- new in SQL2012
				RefFile smallint NULL,
				RefPage int NULL,
				RefSlot int NULL,
				Allocation smallint NULL
		);
	END

	CREATE TABLE #FileList (
		LogicalName nvarchar(128) NOT NULL, 
		PhysicalName nvarchar(260) NOT NULL,
		[Type] CHAR(1) NOT NULL, 
		FileGroupName nvarchar(128) NULL, 
		Size numeric(20,0) NOT NULL, 
		MaxSize numeric(20,0) NOT NULL, 
		FileID bigint NOT NULL, 
		CreateLSN numeric(25,0) NOT NULL, 
		DropLSN numeric(25,0) NULL, 
		UniqueId uniqueidentifier NOT NULL, 
		ReadOnlyLSN numeric(25,0) NULL, 
		ReadWriteLSN numeric(25,0) NULL, 
		BackupSizeInBytes bigint NOT NULL, 
		SourceBlockSize int NOT NULL, 
		FileGroupId int NOT NULL, 
		LogGroupGUID uniqueidentifier NULL, 
		DifferentialBaseLSN numeric(25,0) NULL, 
		DifferentialBaseGUID uniqueidentifier NOT NULL, 
		IsReadOnly bit NOT NULL, 
		IsPresent bit NOT NULL, 
		TDEThumbprint varbinary(32) NULL
	);

	-- SQL Server 2016 adds SnapshotURL of nvarchar(360) for azure stuff:
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE x.ProductMajorVersion = '13') BEGIN;
		ALTER TABLE #FileList ADD SnapshotURL nvarchar(360) NULL;
	END

	DECLARE @command nvarchar(2000);

	OPEN restorer;

	FETCH NEXT FROM restorer INTO @databaseToRestore;
	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @statusDetail = NULL; -- reset every 'loop' through... 
		SET @restoredName = REPLACE(@RestoredDbNamePattern, N'{0}', @databaseToRestore);
		IF (@restoredName = @databaseToRestore) AND (@RestoredDbNamePattern != '{0}') -- then there wasn't a {0} token - so set @restoredName to @RestoredDbNamePattern
			SET @restoredName = @RestoredDbNamePattern;  -- which seems odd, but if they specified @RestoredDbNamePattern = 'Production2', then that's THE name they want...

		IF @PrintOnly = 0 BEGIN;
			INSERT INTO dbo.dba_DatabaseRestore_Log (ExecutionId, [Database], RestoredAs, [RestoreStart], ErrorDetails)
			VALUES (@executionID, @databaseToRestore, @restoredName, GETUTCDATE(), '#UNKNOWN ERROR#');

			SELECT @restoreLogId = SCOPE_IDENTITY();
		END

		-- Verify Path to Source db's backups:
		SET @sourcePath = @BackupsRootPath + N'\' + @databaseToRestore;
		EXEC dbo.dba_CheckPaths @sourcePath, @isValid OUTPUT;
		IF @isValid = 0 BEGIN 
			SET @statusDetail = N'The backup path: ' + @sourcePath + ' is invalid;';
			GOTO NextDatabase;
		END

		-- Determine how to respond to an attempt to overwrite an existing database (i.e., is it explicitly confirmed or... should we throw an exception).
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN;
			
			-- if this is a 'failure' from a previous execution, drop the DB and move on, otherwise, make sure we are explicitly configured to REPLACE. 
			IF EXISTS (SELECT NULL FROM @NonDroppedFromPreviousExecution WHERE [Database] = @databaseToRestore AND RestoredAs = @restoredName) BEGIN;
				SET @command = N'DROP DATABASE [' + @restoredName + N'];';
				
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'DROP', @result = @outcome OUTPUT;
				SET @statusDetail = @outcome;

				IF @statusDetail IS NOT NULL BEGIN;
					GOTO NextDatabase;
				END
			  END
			ELSE BEGIN;
				IF ISNULL(@AllowReplace, '') != N'REPLACE' BEGIN;
					SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
					GOTO NextDatabase;
				END
			END
		END

		-- Enumerate the files and ensure we've got backups:
		SET @command = N'dir "' + @sourcePath + N'\" /B /A-D /OD';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- xp_cmdshell ''' + @command + ''';';
		END
		
		INSERT INTO @temp ([output])
		EXEC master..xp_cmdshell @command;
		DELETE FROM @temp WHERE [output] IS NULL AND [output] NOT LIKE '%' + @databaseToRestore + '%';  -- remove 'empty' entries and any backups for databases OTHER than target.

		IF NOT EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'FULL%') BEGIN 
			IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE '%access%denied%') 
				SET @statusDetail = N'Access to path "' + @sourcePath + N'" is denied.';
			ELSE 
				SET @statusDetail = N'No FULL backups found for database [' + @databaseToRestore + N'] found in "' + @sourcePath + N'".';
			
			GOTO NextDatabase;	
		END

		-- Find the most recent FULL to 'seed' the restore;
		DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE 'FULL%');
		SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'FULL%';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- FULL Backup found at: ' + @pathToDatabaseBackup;
		END

		-- Query file destinations:
		SET @move = N'';
		SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- ' + @command;
		END

		BEGIN TRY 
			DELETE FROM #FileList;
			INSERT INTO #FileList -- shorthand syntax is usually bad, but... whatever. 
			EXEC sys.sp_executesql @command;
		END TRY
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Error Restoring FileList: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			
			GOTO NextDatabase;
		END CATCH
	
		-- Make sure we got some files (i.e. RESTORE FILELIST doesn't always throw exceptions if the path you send it sucks:
		IF ((SELECT COUNT(*) FROM #FileList) < 2) BEGIN;
			SET @statusDetail = N'The backup located at "' + @pathToDatabaseBackup + N'" is invalid, corrupt, or does not contain a viable FULL backup.';
			
			GOTO NextDatabase;
		END 
		
		-- Map File Destinations:
		DECLARE @LogicalFileName sysname, @FileId bigint, @Type char(1);
		DECLARE mover CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			LogicalName, FileID, [Type]
		FROM 
			#FileList
		ORDER BY 
			FileID;

		OPEN mover; 
		FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;

		WHILE @@FETCH_STATUS = 0 BEGIN 

			SET @move = @move + N'MOVE ''' + @LogicalFileName + N''' TO ''' + CASE WHEN @FileId = 2 THEN @RestoredRootLogPath ELSE @RestoredRootDataPath END + N'\' + @restoredName + '.';
			IF @FileId = 1
				SET @move = @move + N'mdf';
			IF @FileId = 2
				SET @move = @move + N'ldf';
			IF @FileId NOT IN (1, 2)
				SET @move = @move + N'ndf';

			SET @move = @move + N''', '

			FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;
		END

		CLOSE mover;
		DEALLOCATE mover;

		SET @move = LEFT(@move, LEN(@move) - 1); -- remove the trailing ", "... 

		-- IF we're going to allow an explicit REPLACE, start by putting the target DB into SINGLE_USER mode: 
		IF @AllowReplace = N'REPLACE' BEGIN;
			
			-- only attempt to set to single-user mode if ONLINE (i.e., if somehow stuck in restoring... don't bother, just replace):
			IF EXISTS(SELECT NULL FROM sys.databases WHERE name = @restoredName AND state_desc = 'ONLINE') BEGIN;

				BEGIN TRY 
					SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName, N'[]') + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';

					IF @PrintOnly = 1 BEGIN;
						PRINT @command;
					  END
					ELSE BEGIN
						SET @outcome = NULL;
						EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'ALTER', @result = @outcome OUTPUT;
						SET @statusDetail = @outcome;
					END

					-- give things just a second to 'die down':
					WAITFOR DELAY '00:00:02';

				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while setting target database: "' + @restoredName + N'" into SINGLE_USER mode to allow explicit REPLACE operation. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH

				IF @statusDetail IS NOT NULL
				GOTO NextDatabase;
			END
		END

		-- Set up the Restore Command and Execute:
		SET @command = REPLACE(@fullRestoreTemplate, N'{0}', @restoredName);
		SET @command = REPLACE(@command, N'{1}', @pathToDatabaseBackup);
		SET @command = REPLACE(@command, N'{move}', @move);

		-- Otherwise, address the REPLACE command in our RESTORE @command: 
		IF @AllowReplace = N'REPLACE'
			SET @command = REPLACE(@command, N'{replace}', N' REPLACE, ');
		ELSE 
			SET @command = REPLACE(@command, N'{replace}',  N'');

		BEGIN TRY 
			IF @PrintOnly = 1 BEGIN;
				PRINT @command;
			  END
			ELSE BEGIN;
				SET @outcome = NULL;
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END
		END TRY 
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
		END CATCH

		IF @statusDetail IS NOT NULL BEGIN;
			GOTO NextDatabase;
		END

		-- Restore any DIFF backups as needed:
		IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'DIFF%') BEGIN;
			DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE N'DIFF%');

			SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'DIFF%';

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			BEGIN TRY
				IF @PrintOnly = 1 BEGIN;
					PRINT @command;
				  END
				ELSE BEGIN;
					SET @outcome = NULL;
					EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END
			END TRY
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH

			IF @statusDetail IS NOT NULL BEGIN;
				GOTO NextDatabase;
			END
		END

		-- Restore any LOG backups if specified and if present:
		IF @SkipLogBackups = 0 BEGIN;
			DECLARE logger CURSOR LOCAL FAST_FORWARD FOR 
			SELECT [output] FROM @temp WHERE [output] LIKE 'LOG%' ORDER BY id ASC;			

			OPEN logger;
			FETCH NEXT FROM logger INTO @pathToDatabaseBackup;

			WHILE @@FETCH_STATUS = 0 BEGIN;
				SET @command = N'RESTORE LOG ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @sourcePath + N'\' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';
				
				BEGIN TRY 
					IF @PrintOnly = 1 BEGIN;
						PRINT @command;
					  END
					ELSE BEGIN;
						SET @outcome = NULL;
						EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

						SET @statusDetail = @outcome;
					END
				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					-- this has to be closed/deallocated - or we'll run into it on the 'next' database/pass.
					IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
						CLOSE logger;
						DEALLOCATE logger;
					END
					
				END CATCH

				IF @statusDetail IS NOT NULL BEGIN;
					GOTO NextDatabase;
				END

				FETCH NEXT FROM logger INTO @pathToDatabaseBackup;
			END

			CLOSE logger;
			DEALLOCATE logger;
		END

		-- Recover the database:
		SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' WITH RECOVERY;';

		BEGIN TRY
			IF @PrintOnly = 1 BEGIN;
				PRINT @command;
			  END
			ELSE BEGIN
				SET @outcome = NULL;
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END;
		END TRY	
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
		END CATCH

		IF @statusDetail IS NOT NULL BEGIN;
			GOTO NextDatabase;
		END

		-- If we've made it here, then we need to update logging/meta-data:
		IF @PrintOnly = 0 BEGIN;
			UPDATE dbo.dba_DatabaseRestore_Log 
			SET 
				RestoreSucceeded = 1, 
				RestoreEnd = GETUTCDATE(), 
				ErrorDetails = NULL
			WHERE 
				RestorationTestId = @restoreLogId;
		END

		-- Run consistency checks if specified:
		IF @CheckConsistency = 1 BEGIN;

			SET @command = N'DBCC CHECKDB([' + @restoredName + N']) WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;'; -- outputting data for review/analysis. 

			IF @PrintOnly = 0 BEGIN 
				UPDATE dbo.dba_DatabaseRestore_Log
				SET 
					ConsistencyCheckStart = GETUTCDATE(),
					ConsistencyCheckSucceeded = 0, 
					ErrorDetails = '#UNKNOWN ERROR CHECKING CONSISTENCY#'
				WHERE
					RestorationTestId = @restoreLogId;
			END

			BEGIN TRY 
				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN 
					DELETE FROM ##DBCC_OUTPUT;
					INSERT INTO ##DBCC_OUTPUT (Error, [Level], [State], MessageText, RepairLevel, [Status], [DbId], DbFragId, ObjectId, IndexId, PartitionId, AllocUnitId, RidDbId, RidPruId, [File], [Page], Slot, RefDbId, RefPruId, RefFile, RefPage, RefSlot, Allocation)
					EXEC sp_executesql @command; 

					IF EXISTS (SELECT NULL FROM ##DBCC_OUTPUT) BEGIN; -- consistency errors: 
						SET @statusDetail = N'CONSISTENCY ERRORS DETECTED against database ' + QUOTENAME(@restoredName, N'[]') + N'. Details: ' + @crlf;
						SELECT @statusDetail = @statusDetail + MessageText + @crlf FROM ##DBCC_OUTPUT ORDER BY RowID;

						UPDATE dbo.dba_DatabaseRestore_Log
						SET 
							ConsistencyCheckEnd = GETUTCDATE(),
							ConsistencyCheckSucceeded = 0,
							ErrorDetails = @statusDetail
						WHERE 
							RestorationTestId = @restoreLogId;

					  END
					ELSE BEGIN; -- there were NO errors:
						UPDATE dbo.dba_DatabaseRestore_Log
						SET
							ConsistencyCheckEnd = GETUTCDATE(),
							ConsistencyCheckSucceeded = 1, 
							ErrorDetails = NULL
						WHERE 
							RestorationTestId = @restoreLogId;

					END
				END

			END TRY	
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while running consistency checks. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				GOTO NextDatabase;
			END CATCH

		END

		-- Drop the database if specified and if all SAFE drop precautions apply:
		IF @DropDatabasesAfterRestore = 1 BEGIN;
			
			-- Make sure we can/will ONLY restore databases that we've restored in this session. 
			SELECT @restoreSucceeded = RestoreSucceeded FROM dbo.dba_DatabaseRestore_Log WHERE RestoredAs = @restoredName AND ExecutionId = @executionID;

			IF @PrintOnly = 1 AND @DropDatabasesAfterRestore = 1
				SET @restoreSucceeded = 1; 
			
			IF ISNULL(@restoreSucceeded, 0) = 0 BEGIN 
				-- We can't drop this database.
				SET @failedDrops = @failedDrops + 1;

				UPDATE dbo.dba_DatabaseRestore_Log
				SET 
					Dropped = 'ERROR', 
					ErrorDetails = ErrorDetails + @crlf + '(NOTE: DROP was configured but SKIPPED due to ERROR state.)'
				WHERE 
					RestorationTestId = @restoreLogId;

				GOTO NextDatabase;
			END

			IF @restoreSucceeded = 1 BEGIN; -- this is a db we restored in this 'session' - so we can drop it:
				SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName, N'[]') + N';';

				BEGIN TRY 
					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN;
						UPDATE dbo.dba_DatabaseRestore_Log 
						SET 
							Dropped = N'ATTEMPTED'
						WHERE 
							RestorationTestId = @restoreLogId;

						EXEC sys.sp_executesql @command;

						IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN;
							SET @failedDrops = @failedDrops;
							SET @statusDetail = N'Executed command to DROP database [' + @restoredName + N']. No exceptions encountered, but database still in place POST-DROP.';

							GOTO NextDatabase;
						  END
						ELSE 
							UPDATE dbo.dba_DatabaseRestore_Log
							SET 
								Dropped = 'DROPPED'
							WHERE 
								RestorationTestId = @restoreLogId;
					END

				END TRY 
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while attempting to DROP database [' + @restoredName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					SET @failedDrops = @failedDrops + 1;

					UPDATE dbo.dba_DatabaseRestore_Log
					SET 
						Dropped = 'ERROR'
					WHERE 
						RestorationTestId = @restoredName;

					GOTO NextDatabase;
				END CATCH
			END

		  END
		ELSE BEGIN;
			UPDATE dbo.dba_DatabaseRestore_Log 
			SET 
				Dropped = 'NOT-DROPPED'
			WHERE
				RestorationTestId = @restoreLogId;
		END

		PRINT N'-- Operations for database [' + @restoredName + N'] completed successfully.' + @crlf + @crlf;

		-- If we made this this far, there have been no errors... and we can drop through into processing the next database... 
NextDatabase:

		DELETE FROM @temp; -- always make sure to clear the list of files handled for the previous database... 

		-- Record any status details as needed:
		IF @statusDetail IS NOT NULL BEGIN;

			IF @PrintOnly = 1 BEGIN;
				PRINT N'ERROR: ' + @statusDetail;
			  END
			ELSE BEGIN;
				UPDATE dbo.dba_DatabaseRestore_Log
				SET 
					[RestoreEnd] = GETUTCDATE(),
					ErrorDetails = @statusDetail
				WHERE 
					RestorationTestId = @restoreLogId;
			END

			PRINT N'-- Operations for database [' + @restoredName + N'] failed.' + @crlf + @crlf;
		END

		-- Check-up on total number of 'failed drops':
		IF @failedDrops >= @MaxNumberOfFailedDrops BEGIN;
			-- we're done - no more processing (don't want to risk running out of space with too many restore operations.
			SET @earlyTermination = N'Max number of databases that could NOT be dropped after restore/testing was reached. Early terminatation forced to reduce risk of causing storage problems.';
			GOTO FINALIZE;
		END

		FETCH NEXT FROM restorer INTO @databaseToRestore;
	END

	-----------------------------------------------------------------------------
FINALIZE:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN;
		CLOSE restorer;
		DEALLOCATE restorer;
	END

	IF (SELECT CURSOR_STATUS('local','mover')) > -1 BEGIN;
		CLOSE mover;
		DEALLOCATE mover;
	END

	IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
		CLOSE logger;
		DEALLOCATE logger;
	END

	-- Assemble details on errors - if there were any (i.e., logged errors OR any reason for early termination... 
	IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.dba_DatabaseRestore_Log WHERE ExecutionId = @executionID AND ErrorDetails IS NOT NULL)) BEGIN;

		SET @emailErrorMessage = N'The following Errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Source Database: [' + [Database] + N']. Attempted to Restore As: [' + RestoredAs + N']. Error: ' + ErrorDetails + @crlf + @crlf
		FROM 
			dbo.dba_DatabaseRestore_Log
		WHERE 
			ExecutionId = @executionID
			AND ErrorDetails IS NOT NULL
		ORDER BY 
			RestorationTestId;

		-- notify too that we stopped execution due to early termination:
		IF NULLIF(@earlyTermination, '') IS NOT NULL BEGIN;
			SET @emailErrorMessage = @emailErrorMessage + @tab + N'- ' + @earlyTermination;
		END
	END
	
	IF @emailErrorMessage IS NOT NULL BEGIN;

		IF @PrintOnly = 1
			PRINT N'ERROR: ' + @emailErrorMessage;
		ELSE BEGIN;
			SET @emailSubject = @emailSubjectPrefix + N' - ERROR';

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END
	END 

	RETURN 0;
GO