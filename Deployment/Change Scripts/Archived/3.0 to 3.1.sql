

USE [master];
GO


-- Change Script:

-- Remove dba_DatabaseRestore_CheckPaths (it's now 'just' dba_CheckPaths)

IF OBJECT_ID('dbo.dba_DatabaseRestore_CheckPaths','P') IS NOT NULL
	DROP PROC dbo.dba_DatabaseRestore_CheckPaths;
GO


-- Add/Execute the following:
--  dba_CheckPaths
--  dba_ExecuteAndFilterNonCatchableCommand
--  dba_RestoreDatabases (has references to checkPaths that are now changed)
--  dba_RemoveBackupFiles
--  dba_BackupDatabases... 



USE master;
GO

IF OBJECT_ID('dbo.dba_CheckPaths','P') IS NOT NULL
	DROP PROC dbo.dba_CheckPaths;
GO

CREATE PROC dbo.dba_CheckPaths 
	@Path				nvarchar(MAX),
	@Exists				bit					OUTPUT
AS
	SET NOCOUNT ON;

	-- Version 3.1.2.16561	
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	SET @Exists = 0;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @commdand nvarchar(2000) = N'IF EXIST "' + @Path + N'" ECHO EXISTS';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @commdand;

	IF EXISTS (SELECT NULL FROM @results WHERE [output] = 'EXISTS')
		SET @Exists = 1;

	RETURN 0;
GO



USE master;
GO

IF OBJECT_ID('dbo.dba_ExecuteAndFilterNonCatchableCommand','P') IS NOT NULL
	DROP PROC dbo.dba_ExecuteAndFilterNonCatchableCommand;
GO

CREATE PROC dbo.dba_ExecuteAndFilterNonCatchableCommand
	@statement				varchar(4000), 
	@filterType				varchar(20), 
	@result					varchar(4000)			OUTPUT	
AS
	SET NOCOUNT ON;

	-- Version 3.1.2.16561
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	IF @filterType NOT IN ('BACKUP','RESTORE','CREATEDIR','ALTER','DELETEFILE') BEGIN;
		RAISERROR('Configuration Problem: Non-Supported @filterType value specified.', 16, 1);
		SET @result = 'Configuration Problem with dba_ExecuteAndFilterNonCatchableCommand.';
		RETURN -1;
	END 

	DECLARE @filters table (
		filter_text varchar(200) NOT NULL, 
		filter_type varchar(20) NOT NULL
	);

	INSERT INTO @filters (filter_text, filter_type)
	VALUES 
	-- BACKUP:
	('Processed % pages for database %', 'BACKUP'),
	('BACKUP DATABASE successfully processed % pages in %','BACKUP'),
	('BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %', 'BACKUP'),
	('BACKUP LOG successfully processed % pages in %', 'BACKUP'),
	('The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %', 'BACKUP'),  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 

	-- RESTORE:
	('RESTORE DATABASE successfully processed % pages in %', 'RESTORE'),
	('RESTORE LOG successfully processed % pages in %', 'RESTORE'),
	('Processed % pages for database %', 'RESTORE'),
		-- whenever there's a patch or upgrade...
	('Converting database % from version % to the current version %', 'RESTORE'), 
	('Database % running the upgrade step from version % to version %.', 'RESTORE'),

	-- CREATEDIR:
	('Command(s) completed successfully.', 'CREATEDIR'), 

	-- ALTER:
	('Command(s) completed successfully.', 'ALTER'),
	('Nonqualified transactions are being rolled back. Estimated rollback completion%', 'ALTER'), 

	-- DELETEFILE:
	('Command(s) completed successfully.','DELETEFILE')

	-- add other filters here as needed... 
	;

	DECLARE @delimiter nchar(4) = N' -> ';

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @command varchar(2000) = 'sqlcmd {0} -q "' + REPLACE(@statement, @crlf, ' ') + '"';

	-- Account for named instances:
	DECLARE @serverName sysname = '';
	IF @@SERVICENAME != N'MSSQLSERVER'
		SET @serverName = N' -S .\' + @@SERVICENAME;
		
	SET @command = REPLACE(@command, '{0}', @serverName);

	--PRINT @command;

	INSERT INTO #Results (result)
	EXEC master..xp_cmdshell @command;

	DELETE r
	FROM 
		#Results r 
		INNER JOIN @filters x ON x.filter_type = @filterType AND r.RESULT LIKE x.filter_text;

	IF EXISTS (SELECT NULL FROM #Results WHERE result IS NOT NULL) BEGIN;
		SET @result = '';
		SELECT @result = @result + result + @delimiter FROM #Results WHERE result IS NOT NULL ORDER BY result_id;
		SET @result = LEFT(@result, LEN(@result) - LEN(@delimiter));
	END

	RETURN 0;
GO



USE master;
GO


IF OBJECT_ID('dba_RestoreDatabases','P') IS NOT NULL
	DROP PROC dba_RestoreDatabases;
GO

CREATE PROC dbo.dba_RestoreDatabases 
	@DatabasesToRestore				nvarchar(MAX),
	@BackupsRootPath				nvarchar(MAX),
	@RestoredRootDataPath			nvarchar(MAX),
	@RestoredRootLogPath			nvarchar(MAX),
	@RestoredDbNameSuffix			nvarchar(20),
	@AllowReplace					nchar(7) = NULL,		-- NULL or the exact term: N'REPLACE'...
	@SkipLogBackups					bit = 0,
	@CheckConsistency				bit = 1,
	@DropDatabasesAfterRestore		bit = 0,		-- Only works if set to 1, and if we've RESTORED the db in question. 
	@MaxNumberOfFailedDrops			int = 1,		-- number of failed DROP operations we'll tolerate before early termination.
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[RESTORE TEST] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- Version 3.1.2.16561	
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dba_DatabaseRestore_Log', 'U') IS NULL BEGIN;
		THROW 510000, N'Table dbo.dba_DatabaseRestore_Log not defined - unable to continue.', 1;
		RETURN -1;
	END

	IF OBJECT_ID('dba_CheckPaths', 'P') IS NULL BEGIN;
		THROW 510000, N'Stored Procedure dbo.dba_CheckPaths not defined - unable to continue.', 1;
		RETURN -1;
	END

	IF OBJECT_ID('dba_ExecuteAndFilterNonCatchableCommand','P') IS NULL BEGIN;
		THROW 510000, N'Stored Procedure dbo.dba_ExecuteAndFilterNonCatchableCommand not defined - unable to continue.', 1;
		RETURN -1;
	END

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN;
		THROW 510000, N'xp_cmdshell is not currently enabled.', 1;
		RETURN -1;
	END

	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			THROW 510000, N'An Operator is not specified - error details can''t be sent if/when encountered.', 1;
			RETURN -2;
		 END
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				THROW 510000, N'Invalild Operator Name Specified.', 1;
				RETURN -2;
			END
		END

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN;
			THROW 510000, N'Specified Mail Profile is invalid or Database Mail is not enabled.', 1;
			RETURN -2;
		END 
	END

	IF NULLIF(@AllowReplace, '') IS NOT NULL AND UPPER(@AllowReplace) != N'REPLACE' BEGIN;
		THROW 510000, N'The @AllowReplace switch must be set to NULL or the exact term N''REPLACE''.', 1;
		RETURN -4;
	END

	IF @AllowReplace IS NOT NULL AND @DropDatabasesAfterRestore = 1 BEGIN;
		THROW 510000, N'Databases cannot be explicitly REPLACED and DROPPED after being replaced. If you wish DBs to be restored (on a different server for testing) with SAME names as PROD, simply leave suffix empty (but not NULL) and leave @AllowReplace NULL.', 1;
		RETURN -6;
	END

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
	IF OBJECT_ID('tempdb..#DatabasesToRestore') IS NOT NULL 
		DROP TABLE #DatabasesToRestore;

	CREATE TABLE #DatabasesToRestore (
		id int IDENTITY(1,1) NOT NULL, 
		database_name sysname NOT NULL
	);

	-- Create a tally table for string-split operations and 'split' strings into #DatabasesToRestore:
	IF OBJECT_ID('tempdb..#Tally') IS NOT NULL 
		DROP TABLE #Tally; 

	SET @DatabasesToRestore = ',' + @DatabasesToRestore + ',';
	SELECT TOP 400 IDENTITY(int, 1, 1) as N INTO #Tally FROM sys.columns;

	INSERT INTO #DatabasesToRestore (database_name)
	SELECT RTRIM(LTRIM(SUBSTRING(@DatabasesToRestore, N+1, CHARINDEX(',', @DatabasesToRestore, N+1)-N-1))) FROM #Tally WHERE N < LEN(@DatabasesToRestore) AND SUBSTRING(@DatabasesToRestore, N, 1) = ',';

	DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		#DatabasesToRestore
	WHERE
		LEN([database_name]) > 0
	ORDER BY 
		id;

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
		SET @restoredName = @databaseToRestore + ISNULL(@RestoredDbNameSuffix, '');

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
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN ;
			IF ISNULL(@AllowReplace, '') != N'REPLACE' BEGIN;
				SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
				GOTO NextDatabase;
			END
		END

		-- Enumerate the files and ensure we've got backups:
		SET @command = N'dir "' + @sourcePath + N'\" /B /A-D /OD';

		IF @PrintOnly = 1
			PRINT N'-- xp_cmdshell ''' + @command + ''';';
		
		DELETE FROM @temp;  -- clean previous results from last 'pass'...
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

		IF @PrintOnly = 1 
			PRINT N'-- FULL Backup found at: ' + @pathToDatabaseBackup;

		-- Query file destinations:
		SET @move = N'';
		SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

		IF @PrintOnly = 1 
			PRINT N'-- ' + @command;

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

					IF @PrintOnly = 1
						PRINT @command;
					ELSE BEGIN
						--EXEC sys.sp_executesql @command; 
						SET @outcome = NULL;
						EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'ALTER', @result = @outcome OUTPUT;
						SET @statusDetail = @outcome;

						-- give things just a second to 'die down':
						WAITFOR DELAY '00:00:02';
					END
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
			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN;
				--EXEC sys.sp_executesql @command;  
				SET @outcome = NULL;
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END
		END TRY 
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
		END CATCH

		IF @statusDetail IS NOT NULL
			GOTO NextDatabase;

		-- Restore any DIFF backups as needed:
		IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'DIFF%') BEGIN;
			DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE N'DIFF%');

			SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'DIFF%';

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			BEGIN TRY
				IF @PrintOnly = 1
					PRINT @command;
				ELSE BEGIN;
					--EXEC sys.sp_executesql @command;
					SET @outcome = NULL;
					EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END
			END TRY
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH

			IF @statusDetail IS NOT NULL
				GOTO NextDatabase;
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
					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN;
						--EXEC sys.sp_executesql @command;
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

				IF @statusDetail IS NOT NULL
					GOTO NextDatabase;

				FETCH NEXT FROM logger INTO @pathToDatabaseBackup;
			END

			CLOSE logger;
			DEALLOCATE logger;
		END

		-- Recover the database:
		SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' WITH RECOVERY;';

		BEGIN TRY
			IF @PrintOnly = 1
				PRINT @command;
			ELSE BEGIN
				--EXEC sys.sp_executesql @command
				SET @outcome = NULL;
				EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END;
		END TRY	
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
		END CATCH

		IF @statusDetail IS NOT NULL
			GOTO NextDatabase;

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

		-- Record any status details as needed:
		IF @statusDetail IS NOT NULL BEGIN;

			IF @PrintOnly = 1 
				PRINT N'ERROR: ' + @statusDetail;
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


USE [master];
GO

IF OBJECT_ID('[dbo].[dba_RemoveBackupFiles]','P') IS NOT NULL
	DROP PROC [dbo].[dba_RemoveBackupFiles];
GO

CREATE PROC [dbo].[dba_RemoveBackupFiles] 
	@BackupType							sysname,						-- { ALL | FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),					-- { [READ_FROM_FILESYSTEM] | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,			-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000),					-- { path_to_backups }
	@RetentionMinutes					int,							-- Anything > this many minutes old (for @BackupType specified) will be removed.
	@Output								nvarchar(MAX) = NULL OUTPUT,	-- When set to non-null value, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@SendNotifications					bit	= 0,						-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
	@PrintOnly							bit = 0 						-- { 0 | 1 }
AS
	SET NOCOUNT ON; 

	-- Version 3.1.2.16561	
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
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
	IF ((@PrintOnly = 0) OR (@Output IS NULL)) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

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

	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG', 'ALL') BEGIN;
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	-- translate the retention settings:
	DECLARE @RetentionCutoffTime datetime = DATEADD(MINUTE, 0 - @RetentionMinutes, GETDATE());

	IF @RetentionCutoffTime >= GETDATE() BEGIN; 
		 RAISERROR('Invalid @RetentionCutoffTime - greater than or equal to NOW.', 16, 1);
		 RETURN -10;
	END;

	-- normalize paths: 
	IF(RIGHT(@TargetDirectory, 1) = '\')
		SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

	-- verify that path exists:
	DECLARE @isValid bit;
	EXEC dbo.dba_CheckPaths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		RAISERROR('Invalid @TargetDirectory specified - either the path does not exist, or SQL Server''s Service Account does not have permissions to access the specified directory.', 16, 1);

		RETURN -10;
	END

	-----------------------------------------------------------------------------
	DECLARE @routeInfoAsOutput bit = 0;
	IF @Output IS NOT NULL 
		SET @routeInfoAsOutput = 1; 

	SET @Output = NULL;

	-- Determine which folders to process:
	SELECT TOP 400 IDENTITY(int, 1, 1) as N 
	INTO #Tally
	FROM sys.columns;

	DECLARE @targetDirectories TABLE ( 
		[entry_id] int IDENTITY(1,1) NOT NULL,
		[directory_name] sysname NOT NULL
	); 

	IF UPPER(@DatabasesToProcess) = '[READ_FROM_FILESYSTEM]' BEGIN;

		DECLARE @directories table (
			row_id int IDENTITY(1,1) NOT NULL, 
			subdirectory sysname NOT NULL, 
			depth int NOT NULL
		);

		INSERT INTO @directories (subdirectory, depth)
		EXEC master.sys.xp_dirtree @TargetDirectory, 1, 0;

		INSERT INTO @targetDirectories (directory_name)
		SELECT subdirectory FROM @directories ORDER BY row_id;

	  END; 
	ELSE BEGIN;

		DECLARE @SerializedDbs nvarchar(1200);
		SET @SerializedDbs = ',' + REPLACE(@DatabasesToProcess, ' ', '') + ',';

		INSERT INTO @targetDirectories ([directory_name])
		SELECT SUBSTRING(@SerializedDbs, N + 1, CHARINDEX(',', @SerializedDbs, N + 1) - N - 1)
		FROM #Tally
		WHERE N < LEN(@SerializedDbs) 
			AND SUBSTRING(@SerializedDbs, N, 1) = ','
		ORDER BY #Tally.N;
	END;

	-- Exclude any databases specified for exclusion:
	IF ISNULL(@DatabasesToExclude, '') != '' BEGIN;
		DECLARE @removedDbs nvarchar(1200);
		SET @removedDbs = ',' + REPLACE(@DatabasesToExclude, ' ', '') + ',';

		DELETE FROM @targetDirectories
		WHERE [directory_name] IN (
			SELECT SUBSTRING(@removedDbs, N + 1, CHARINDEX(',', @removedDbs, N + 1) - N - 1)
			FROM #Tally
			WHERE N < LEN(@removedDbs)
				AND SUBSTRING(@removedDbs, N, 1) = ','
		);
	END;

	-----------------------------------------------------------------------------
	-- Process files for removal:

	DECLARE @currentDirectory sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @targetPath nvarchar(512);
	DECLARE @outcome varchar(4000);
	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @file nvarchar(512);

	DECLARE @files table (
		id int IDENTITY(1,1),
		subdirectory nvarchar(512), 
		depth int, 
		isfile bit
	);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL
	);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		directory_name
	FROM 
		@targetDirectories
	ORDER BY 
		[entry_id];

	OPEN processor;

	FETCH NEXT FROM processor INTO @currentDirectory;

	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @targetPath = @TargetDirectory + N'\' + @currentDirectory;

		SET @errorMessage = NULL;
		SET @outcome = NULL;

		IF @BackupType IN ('LOG', 'ALL') BEGIN;
			-- Process any/all log files en-masse:
			
			SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + ''', N''trn'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 1;';

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN 
				BEGIN TRY
					EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'DELETEFILE', @result = @outcome OUTPUT;

					IF @outcome IS NOT NULL 
						SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

				END TRY 
				BEGIN CATCH
					SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting older LOG backups from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

				END CATCH;				
			END

			IF @errorMessage IS NOT NULL BEGIN;
				SET @errorMessage = ISNULL(@errorMessage, '') + N' [Command: ' + @command + N']';

				INSERT INTO @errors ([error_message])
				VALUES (@errorMessage);
			END
		END

		IF @BackupType IN ('FULL', 'DIFF', 'ALL') BEGIN;

			-- start by clearing any previous values:
			DELETE FROM @files;
			SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

			IF @PrintOnly = 1
				PRINT N'--' + @command;

			INSERT INTO @files (subdirectory, depth, isfile)
			EXEC sys.sp_executesql @command;

			DELETE FROM @files WHERE isfile = 0; -- remove directories.
			DELETE FROM @files WHERE subdirectory NOT LIKE '%.bak'; -- remove (from processing) any files that don't use the .bak extension. 

			-- If a specific backup type is specified ONLY target that backup type:
			IF @BackupType != N'ALL' BEGIN;
				
				IF @BackupType = N'FULL'
					DELETE FROM @files WHERE subdirectory NOT LIKE N'FULL%';

				IF @BackupType = N'DIFF'
					DELETE FROM @files WHERE subdirectory NOT LIKE N'DIFF%';
			END

			DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT subdirectory FROM @files WHERE isfile = 1 AND subdirectory NOT LIKE '%.trn' ORDER BY id;

			OPEN nuker;
			FETCH NEXT FROM nuker INTO @file;

			WHILE @@FETCH_STATUS = 0 BEGIN;

				-- reset per each 'grab':
				SET @errorMessage = NULL;
				SET @outcome = NULL

				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 0;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN; 

					BEGIN TRY
						EXEC dbo.dba_ExecuteAndFilterNonCatchableCommand @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') +  N'Error deleting DIFF/FULL Backup with command: [' + ISNULL(@command, '##NOT SET YET##') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
					END CATCH

				END;

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END

				FETCH NEXT FROM nuker INTO @file;
			END;

			CLOSE nuker;
			DEALLOCATE nuker;

		END

		FETCH NEXT FROM processor INTO @currentDirectory;
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

	IF EXISTS (SELECT NULL FROM @errors) BEGIN;
		
		-- format based on output type (output variable or email/error-message), then 'raise, return, or send'... 
		IF @routeInfoAsOutput = 1 BEGIN;
			SELECT @errorInfo = @errorInfo + [error_message] + N', ' FROM @errors ORDER BY error_id;
			SET @errorInfo = LEFT(@errorInfo, LEN(@errorInfo) - 2);

			SET @output = @errorInfo;
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


USE master;
GO

IF OBJECT_ID('dbo.dba_BackupDatabases','P') IS NOT NULL
	DROP PROC dbo.dba_BackupDatabases;
GO

CREATE PROC dbo.dba_BackupDatabases 
	@BackupType							sysname,					-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(1000),				-- { [SYSTEM]|[USER]|name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,		-- { NULL | name1,name2 }  
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

	-- Version 3.1.2.16561	
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dba_DatabaseBackups_Log', 'U') IS NULL BEGIN;
		RAISERROR('Table dbo.dba_DatabaseBackups_Log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dba_CheckPaths', 'P') IS NULL BEGIN;
		THROW 510000, N'Stored Procedure dbo.dba_CheckPaths not defined - unable to continue.', 1;
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

	SELECT TOP 400 IDENTITY(int, 1, 1) as N 
	INTO #Tally
	FROM sys.columns;

	DECLARE @targetDatabases TABLE ( 
		[entry_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 

	IF UPPER(@DatabasesToBackup) = '[SYSTEM]' BEGIN;
		SET @executingSystemDbBackups = 1;

		INSERT INTO @targetDatabases ([database_name])
		SELECT 'master' UNION SELECT 'msdb' UNION SELECT 'model';
	END; 

	IF UPPER(@DatabasesToBackup) = '[USER]' BEGIN; 

		IF @BackupType = 'LOG'
			INSERT INTO @targetDatabases ([database_name])
			SELECT name FROM sys.databases 
			WHERE recovery_model_desc = 'FULL' 
				AND name NOT IN ('master', 'model', 'msdb', 'tempdb') 
			ORDER BY name;
		ELSE 
			INSERT INTO @targetDatabases ([database_name])
			SELECT name FROM sys.databases 
			WHERE name NOT IN ('master', 'model', 'msdb','tempdb') 
			ORDER BY name;
	END; 

	IF (SELECT COUNT(*) FROM @targetDatabases) <= 0 BEGIN;

		DECLARE @SerializedDbs nvarchar(1200);
		SET @SerializedDbs = ',' + REPLACE(@DatabasesToBackup, ' ', '') + ',';

		INSERT INTO @targetDatabases ([database_name])
		SELECT SUBSTRING(@SerializedDbs, N + 1, CHARINDEX(',', @SerializedDbs, N + 1) - N - 1)
		FROM #Tally
		WHERE N < LEN(@SerializedDbs) 
			AND SUBSTRING(@SerializedDbs, N, 1) = ','
		ORDER BY #Tally.N;

		IF @BackupType = 'LOG' BEGIN
			DELETE FROM @targetDatabases 
			WHERE [database_name] NOT IN (
				SELECT name FROM sys.databases WHERE recovery_model_desc = 'FULL'
			);
		  END;
		ELSE 
			DELETE FROM @targetDatabases
			WHERE [database_name] NOT IN (SELECT name FROM sys.databases);
	END;

	-- Exclude any databases that aren't operational:
	DELETE FROM @targetDatabases 
	WHERE [database_name] IN (SELECT name FROM sys.databases WHERE state_desc != 'ONLINE')  -- this gets any dbs that are NOT online - INCLUDING those that are listed as 'RESTORING' because of mirroring. 
		OR [database_name] IN (
			SELECT d.name 
			FROM sys.databases d 
			INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
			WHERE hars.role_desc != 'PRIMARY'
		); -- grab any dbs that are in an AG where the current role != PRIMARY. 

	-- Exclude any databases specified for exclusion:
	IF ISNULL(@DatabasesToExclude, '') != '' BEGIN;
		DECLARE @removedDbs nvarchar(1200);
		SET @removedDbs = ',' + REPLACE(@DatabasesToExclude, ' ', '') + ',';

		DELETE FROM @targetDatabases
		WHERE [database_name] IN (
			SELECT SUBSTRING(@removedDbs, N + 1, CHARINDEX(',', @removedDbs, N + 1) - N - 1)
			FROM #Tally
			WHERE N < LEN(@removedDbs)
				AND SUBSTRING(@removedDbs, N, 1) = ','
		);
	END;

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

				IF ISNULL(@CopyToBackupDirectory,'') IS NOT NULL BEGIN;
				
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