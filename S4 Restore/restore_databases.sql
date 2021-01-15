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

    TODO:
        - Look at implementing MINIMAL 'retry' logic - as per dba_BackupDatabases. Or... maybe don't... 

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


    DOCS (to add). 

here's an EXAMPLE of how to do nightly restore tests on ONLY the primary: 
        (nothing too complex ... just wrap execution in an is_primary_server() check... )

            IF (SELECT admindb.dbo.is_primary_server()) = 1 BEGIN
	            EXEC [admindb].[dbo].[restore_databases]
		            @DatabasesToRestore = N'{READ_FROM_FILESYSTEM}', 
		            @DatabasesToExclude = N'{SYSTEM}, __certs', 
		            @Priorities = N'Motion4', 
		            @BackupsRootPath = N'\\10.100.213.13\SQLBackups', 
		            @RestoredRootDataPath = N'C:\SQLData',  
		            @RestoredRootLogPath = N'C:\SQLData',  
		            @RestoredDbNamePattern = N'{0}_s4test',  
		            @SkipLogBackups = 0,  
		            @ExecuteRecovery = 1,  
		            @CheckConsistency = 1,  
		            @DropDatabasesAfterRestore = 1,  
		            @MaxNumberOfFailedDrops = 3, 
		            @PrintOnly = 0;
            END;



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.restore_databases','P') IS NOT NULL
    DROP PROC dbo.restore_databases;
GO

CREATE PROC dbo.restore_databases 
    @DatabasesToRestore				nvarchar(MAX),
    @DatabasesToExclude				nvarchar(MAX)	= NULL,
    @Priorities						nvarchar(MAX)	= NULL,
    @BackupsRootPath				nvarchar(MAX)	= N'{DEFAULT}',
    @RestoredRootDataPath			nvarchar(MAX)	= N'{DEFAULT}',
    @RestoredRootLogPath			nvarchar(MAX)	= N'{DEFAULT}',
    @RestoredDbNamePattern			nvarchar(40)	= N'{0}_s4test',
    @AllowReplace					nchar(7)		= NULL,				-- NULL or the exact term: N'REPLACE'...
    @SkipLogBackups					bit				= 0,
	@ExecuteRecovery				bit				= 1,
    @CheckConsistency				bit				= 1,
	@RpoWarningThreshold			nvarchar(10)	= N'24 hours',		-- Only evaluated if non-NULL. 
    @DropDatabasesAfterRestore		bit				= 0,				-- Only works if set to 1, and if we've RESTORED the db in question. 
    @MaxNumberOfFailedDrops			int				= 1,				-- number of failed DROP operations we'll tolerate before early termination.
    @Directives						nvarchar(400)	= NULL,				-- { RESTRICTED_USER | KEEP_REPLICATION | KEEP_CDC | [ ENABLE_BROKER | ERROR_BROKER_CONVERSATIONS | NEW_BROKER ] }
	@OperatorName					sysname			= N'Alerts',
    @MailProfileName				sysname			= N'General',
    @EmailSubjectPrefix				nvarchar(50)	= N'[RESTORE TEST] ',
    @PrintOnly						bit				= 0
AS
    SET NOCOUNT ON;

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	-----------------------------------------------------------------------------
    -- Set Defaults:
    IF UPPER(@BackupsRootPath) = N'{DEFAULT}' BEGIN
        SELECT @BackupsRootPath = dbo.load_default_path('BACKUP');
    END;

    IF UPPER(@RestoredRootDataPath) = N'{DEFAULT}' BEGIN
        SELECT @RestoredRootDataPath = dbo.load_default_path('DATA');
    END;

    IF UPPER(@RestoredRootLogPath) = N'{DEFAULT}' BEGIN
        SELECT @RestoredRootLogPath = dbo.load_default_path('LOG');
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
 
        IF @DatabaseMailProfile <> @MailProfileName BEGIN
            RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
            RETURN -2;
        END; 
    END;

	IF @ExecuteRecovery = 0 AND @DropDatabasesAfterRestore = 1 BEGIN
		RAISERROR(N'@ExecuteRecovery cannot be set to false (0) when @DropDatabasesAfterRestore is set to true (1).', 16, 1);
		RETURN -5;
	END;

    IF @MaxNumberOfFailedDrops <= 0 BEGIN
        RAISERROR('@MaxNumberOfFailedDrops must be set to a value of 1 or higher.', 16, 1);
        RETURN -6;
    END;

    IF NULLIF(@AllowReplace, N'') IS NOT NULL AND UPPER(@AllowReplace) <> N'REPLACE' BEGIN
        RAISERROR('The @AllowReplace switch must be set to NULL or the exact term N''REPLACE''.', 16, 1);
        RETURN -4;
    END;

    IF NULLIF(@AllowReplace, N'') IS NOT NULL AND @DropDatabasesAfterRestore = 1 BEGIN
        RAISERROR('Databases cannot be explicitly REPLACED and DROPPED after being replaced. If you wish DBs to be restored (on a different server for testing) with SAME names as PROD, simply leave suffix empty (but not NULL) and leave @AllowReplace NULL.', 16, 1);
        RETURN -6;
    END;

    IF UPPER(@DatabasesToRestore) IN (N'{SYSTEM}', N'{USER}') BEGIN
        RAISERROR('The tokens {SYSTEM} and {USER} cannot be used to specify which databases to restore via dbo.restore_databases. Use either {READ_FROM_FILESYSTEM} (plus any exclusions via @DatabasesToExclude), or specify a comma-delimited list of databases to restore.', 16, 1);
        RETURN -10;
    END;

    IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
        SET @DatabasesToExclude = NULL;

    IF (@DatabasesToExclude IS NOT NULL) AND (UPPER(@DatabasesToRestore) <> N'{READ_FROM_FILESYSTEM}') BEGIN
        RAISERROR('@DatabasesToExclude can ONLY be specified when @DatabasesToRestore is defined as the {READ_FROM_FILESYSTEM} token. Otherwise, if you don''t want a database restored, don''t specify it in the @DatabasesToRestore ''list''.', 16, 1);
        RETURN -20;
    END;

    IF (NULLIF(@RestoredDbNamePattern,'')) IS NULL BEGIN
        RAISERROR('@RestoredDbNamePattern can NOT be NULL or empty. Use the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname - whereas ''{0}'' would simply be restored as the name of the db to restore per database).', 16, 1);
        RETURN -22;
    END;

	DECLARE @vector bigint;  -- 'global'
	DECLARE @vectorError nvarchar(MAX);
	
	IF NULLIF(@RpoWarningThreshold, N'') IS NOT NULL BEGIN 
		EXEC [dbo].[translate_vector]
		    @Vector = @RpoWarningThreshold, 
		    @ValidationParameterName = N'@RpoWarningThreshold', 
		    @TranslationDatePart = N'SECOND', 
		    @Output = @vector OUTPUT, 
		    @Error = @vectorError OUTPUT;

		IF @vectorError IS NOT NULL BEGIN 
			RAISERROR(@vectorError, 16, 1);
			RETURN -20;
		END;
	END;

	DECLARE @directivesText nvarchar(200) = N'';
	IF NULLIF(@Directives, N'') IS NOT NULL BEGIN
		SET @Directives = LTRIM(RTRIM(@Directives));
		
		DECLARE @allDirectives table ( 
			row_id int NOT NULL, 
			directive sysname NOT NULL
		);

		INSERT INTO @allDirectives ([row_id], [directive])
		SELECT * FROM dbo.[split_string](@Directives, N',', 1);

		-- verify that only supported directives are defined: 
		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] NOT IN (N'RESTRICTED_USER', N'KEEP_REPLICATION', N'KEEP_CDC', N'ENABLE_BROKER', N'ERROR_BROKER_CONVERSATIONS' , N'NEW_BROKER')) BEGIN
			RAISERROR(N'Invalid @Directives value specified. Permitted values are { RESTRICTED_USER | KEEP_REPLICATION | KEEP_CDC | [ ENABLE_BROKER | ERROR_BROKER_CONVERSATIONS | NEW_BROKER ] }.', 16, 1);
			RETURN -20;
		END;

		-- make sure we're ONLY specifying a single BROKER directive (i.e., all three options are supported, but they're (obviously) mutually exclusive).
		IF (SELECT COUNT(*) FROM @allDirectives WHERE [directive] LIKE '%BROKER%') > 1 BEGIN 
			RAISERROR(N'Invalid @Directives values specified. ENABLE_BROKER, ERROR_BROKER_CONVERSATIONS, and NEW_BROKER directives are ALLOWED - but only one can be specified as part of a restore operation. Consult Books Online for more info.', 16, 1);
			RETURN -21;
		END;

		SELECT @directivesText = @directivesText + [directive] + N', ' FROM @allDirectives ORDER BY [row_id];
	END;

	-----------------------------------------------------------------------------
    -- 'Global' Variables:
    DECLARE @isValid bit;
    DECLARE @earlyTermination nvarchar(MAX) = N'';
    DECLARE @emailErrorMessage nvarchar(MAX);
    DECLARE @emailSubject nvarchar(300);
    DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
    DECLARE @tab char(1) = CHAR(9);
    DECLARE @executionID uniqueidentifier = NEWID();
    DECLARE @executeDropAllowed bit;
    DECLARE @failedDropCount int = 0;
	DECLARE @isPartialRestore bit = 0;

	-- normalize paths: 
	SET @BackupsRootPath = dbo.[normalize_file_path](@BackupsRootPath)

    -- Verify Paths: 
    EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;
    
    EXEC dbo.check_paths @RestoredRootDataPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@RestoredRootDataPath (' + @RestoredRootDataPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    EXEC dbo.check_paths @RestoredRootLogPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@RestoredRootLogPath (' + @RestoredRootLogPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    -----------------------------------------------------------------------------
    -- Construct list of databases to restore:
    DECLARE @dbsToRestore table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	-- If the {READ_FROM_FILESYSTEM} token is specified, replace {READ_FROM_FILESYSTEM} in @DatabasesToRestore with a serialized list of db-names pulled from @BackupRootPath:
	IF ((SELECT dbo.[count_matches](@DatabasesToRestore, N'{READ_FROM_FILESYSTEM}')) > 0) BEGIN
		DECLARE @databases xml = NULL;
		DECLARE @serialized nvarchar(MAX) = '';

		EXEC dbo.[load_backup_database_names]
		    @TargetDirectory = @BackupsRootPath,
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

		IF @serialized = N'' BEGIN
			RAISERROR(N'No sub-folders (potential database backups) found at path specified by @BackupsRootPath. Please double-check your input.', 16, 1);
			RETURN -30;
		  END;
		ELSE
			SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);

		SET @DatabasesToRestore = REPLACE(@DatabasesToRestore, N'{READ_FROM_FILESYSTEM}', @serialized); 
	END;
    
    INSERT INTO @dbsToRestore ([database_name])
    EXEC dbo.list_databases
        @Targets = @DatabasesToRestore,         
        @Exclusions = @DatabasesToExclude,		-- only works if {READ_FROM_FILESYSTEM} is specified for @Input... 
        @Priorities = @Priorities,

		-- ALLOW these to be included ... they'll throw exceptions if REPLACE isn't specified. But if it is SPECIFIED, then someone is trying to EXPLICTLY overwrite 'bunk' databases with a restore... 
		@ExcludeSecondaries = 0,
		@ExcludeRestoring = 0,
		@ExcludeRecovering = 0,	
		@ExcludeOffline = 0;

    IF NOT EXISTS (SELECT NULL FROM @dbsToRestore) BEGIN
        RAISERROR('No Databases Specified to Restore. Please Check inputs for @DatabasesToRestore + @DatabasesToExclude and retry.', 16, 1);
        RETURN -20;
    END;

    DECLARE @databaseToRestore sysname;
    DECLARE @restoredName sysname;
	DECLARE @restoreStart datetime;

    DECLARE @fullRestoreTemplate nvarchar(MAX) = N'RESTORE DATABASE [{0}] FROM DISK = N''{1}''' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'WITH {partial}' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + '{move}, ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'NORECOVERY;'; 
    DECLARE @move nvarchar(MAX);
    DECLARE @restoreLogId int;
    DECLARE @sourcePath nvarchar(500);
    DECLARE @statusDetail nvarchar(MAX);
    DECLARE @pathToDatabaseBackup nvarchar(600);
    DECLARE @outcome varchar(4000);
	DECLARE @serializedFileList xml = NULL; 
	DECLARE @backupName sysname;
	DECLARE @fileListXml nvarchar(MAX);

	DECLARE @restoredFileName nvarchar(MAX);
	DECLARE @ndfCount int = 0;

	-- dbo.execute_command variables: 
	DECLARE @execOutcome bit;
	DECLARE @execResults xml;

	DECLARE @ignoredLogFiles int = 0;

	DECLARE @logFilesToRestore table ( 
		id int IDENTITY(1,1) NOT NULL, 
		log_file sysname NOT NULL
	);
	DECLARE @currentLogFileID int = 0;

	DECLARE @restoredFiles table (
		ID int IDENTITY(1,1) NOT NULL, 
		[FileName] nvarchar(400) NOT NULL, 
		Detected datetime NOT NULL, 
		BackupCreated datetime NULL, 
		Applied datetime NULL, 
		BackupSize bigint NULL, 
		Compressed bit NULL, 
		[Encrypted] bit NULL, 
		[Comment] nvarchar(MAX) NULL
	); 

	DECLARE @backupDate datetime, @backupSize bigint, @compressed bit, @encrypted bit;

    IF @CheckConsistency = 1 BEGIN
        IF OBJECT_ID('tempdb..#DBCC_OUTPUT') IS NOT NULL 
            DROP TABLE #DBCC_OUTPUT;

        CREATE TABLE #DBCC_OUTPUT(
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
    END;

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
	IF (SELECT dbo.get_engine_version()) >= 13.0 BEGIN
        ALTER TABLE #FileList ADD SnapshotURL nvarchar(360) NULL;
    END;

    DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
    SELECT 
        [database_name]
    FROM 
        @dbsToRestore
    WHERE
        LEN([database_name]) > 0
    ORDER BY 
        entry_id;

    DECLARE @command nvarchar(2000);

    OPEN restorer;

    FETCH NEXT FROM restorer INTO @databaseToRestore;
    WHILE @@FETCH_STATUS = 0 BEGIN
        
		-- reset every 'loop' through... 
		SET @ignoredLogFiles = 0;
        SET @statusDetail = NULL; 
		SET @isPartialRestore = 0;
		SET @serializedFileList = NULL;
        DELETE FROM @restoredFiles;
		
		SET @restoredName = REPLACE(@RestoredDbNamePattern, N'{0}', @databaseToRestore);
        IF (@restoredName = @databaseToRestore) AND (@RestoredDbNamePattern <> '{0}') -- then there wasn't a {0} token - so set @restoredName to @RestoredDbNamePattern
            SET @restoredName = @RestoredDbNamePattern;  -- which seems odd, but if they specified @RestoredDbNamePattern = 'Production2', then that's THE name they want...

        IF @PrintOnly = 0 BEGIN
            INSERT INTO dbo.restore_log (execution_id, [database], restored_as, restore_start, error_details)
            VALUES (@executionID, @databaseToRestore, @restoredName, GETDATE(), '#UNKNOWN ERROR#');

            SELECT @restoreLogId = SCOPE_IDENTITY();
        END;

        -- Verify Path to Source db's backups:
        SET @sourcePath = @BackupsRootPath + N'\' + @databaseToRestore;
        EXEC dbo.check_paths @sourcePath, @isValid OUTPUT;
        IF @isValid = 0 BEGIN 
			SET @statusDetail = N'The backup path: ' + @sourcePath + ' is invalid.';
			GOTO NextDatabase;
        END;
        
		-- Process attempt to overwrite an existing database: 
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN

			-- IF we're going to allow an explicit REPLACE, start by putting the target DB into SINGLE_USER mode: 
			IF @AllowReplace = N'REPLACE' BEGIN
				
				BEGIN TRY 

					IF EXISTS(SELECT NULL FROM sys.databases WHERE [name] = @restoredName AND state_desc = 'ONLINE') BEGIN

						SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName) + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + @crlf
							+ N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';' + @crlf + @crlf;
							
						IF @PrintOnly = 1 BEGIN
							PRINT @command;
							END;
						ELSE BEGIN
							
							EXEC @execOutcome = dbo.[execute_command]
								@Command = @command, 
								@DelayBetweenAttempts = N'8 seconds',
								@IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS],[SINGLE_USER]', 
								@Results = @execResults OUTPUT;

							IF @execOutcome <> 0 
								SET @statusDetail = N'Error with SINGLE_USER > DROP operations: ' + CAST(@execResults AS nvarchar(MAX));
						END;

					  END;
					ELSE BEGIN -- at this point, the targetDB exists ... and it's NOT 'ONLINE' so... it's restoring, suspect, whatever, and we've been given explicit instructions to replace it:
						
						SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';' + @crlf + @crlf;

						IF @PrintOnly = 1 BEGIN 
							PRINT @command;
						  END;
						ELSE BEGIN 
							
							EXEC @execOutcome = dbo.[execute_command]
								@Command = @command, 
								@DelayBetweenAttempts = N'8 seconds',
								@IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS],[SINGLE_USER]', 
								@Results = @execResults OUTPUT;
							
							IF @execOutcome <> 0 
								SET @statusDetail = N'Error with DROP DATABASE: ' + CAST(@execResults AS nvarchar(MAX));

						END;

					END;

				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while setting target database: [' + @restoredName + N'] into SINGLE_USER mode and/or attempting to DROP target database for explicit REPLACE operation. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH

				IF @statusDetail IS NOT NULL
					GOTO NextDatabase;

			  END;
			ELSE BEGIN
				SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
				GOTO NextDatabase;
			END;
        END;

		-- Check for a FULL backup: 
		--			NOTE: If dbo.load_backup_files does NOT return any results and if @databaseToRestore is a {SYSTEM} database, then dbo.load_backup_files ...
		--				will check @SourcePath + @ServerName as well - i.e., it accounts for @AppendServerNameToSystemDbs 
		EXEC dbo.load_backup_files 
            @DatabaseToRestore = @databaseToRestore, 
            @SourcePath = @sourcePath, 
            @Mode = N'FULL', 
            @Output = @serializedFileList OUTPUT;
		
		IF(SELECT dbo.[is_xml_empty](@serializedFileList)) = 1 BEGIN
			SET @statusDetail = N'No FULL backups found for database [' + @databaseToRestore + N'] in "' + @sourcePath + N'".';
			GOTO NextDatabase;	
		END;

        -- Load Backup details/etc. 
		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@file_name', 'nvarchar(max)') [file_name]
			FROM 
				@serializedFileList.nodes('//file') [data]([row])
		) 
		SELECT @backupName = (SELECT TOP 1 [file_name] FROM [shredded]);
		
		SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName;

		-- define the list of files to be processed:
		INSERT INTO @restoredFiles ([FileName], [Detected])
		SELECT 
			@backupName, 
			GETDATE(); -- detected (i.e., when this file was 'found' and 'added' for processing).  

        -- Query file destinations:
        SET @move = N'';
        SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

        IF @PrintOnly = 1 BEGIN
            PRINT N'-- ' + @command;
        END;

        BEGIN TRY 
            DELETE FROM #FileList;
            INSERT INTO #FileList -- shorthand syntax is usually bad, but... whatever. 
            EXEC sys.sp_executesql @command;
        END TRY
        BEGIN CATCH
            SELECT @statusDetail = N'Unexpected Error Restoring FileList: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            
            GOTO NextDatabase;
        END CATCH;
    
        -- Make sure we got some files (i.e. RESTORE FILELIST doesn't always throw exceptions if the path you send it sucks):
        IF ((SELECT COUNT(*) FROM #FileList) < 2) BEGIN
            SET @statusDetail = N'The backup located at [' + @pathToDatabaseBackup + N'] is invalid, corrupt, or does not contain a viable FULL backup.';
            GOTO NextDatabase;
        END;

		IF EXISTS (SELECT NULL FROM [#FileList] WHERE [IsPresent] = 0) BEGIN
			SET @isPartialRestore = 1;
		END;
        
        -- Map File Destinations:
		DECLARE @logicalFileName sysname, @fileId bigint, @type char(1), @fileName sysname;
        DECLARE mover CURSOR LOCAL FAST_FORWARD FOR 
        SELECT 
			LogicalName, 
			FileID, 
			[Type], 
			(SELECT TOP 1 (result) FROM dbo.split_string([name], N'.', 1) ORDER BY [row_id]) [FileName]
        FROM 
            (
				SELECT 
					LogicalName, 
					FileID, 
					[Type], 
					(SELECT TOP 1 (result) FROM dbo.split_string(PhysicalName, N'\', 1) ORDER BY [row_id] DESC) [name]
				FROM 
					#FileList 
				WHERE 
					[IsPresent] = 1 -- allow for partial restores
			) translated
        ORDER BY 
            FileID;

        OPEN mover; 
        FETCH NEXT FROM mover INTO @logicalFileName, @fileId, @type, @fileName;

        WHILE @@FETCH_STATUS = 0 BEGIN 

			-- NOTE: FULL filename (path + name) can NOT be > 260 (259?) chars long. 
			SET @restoredFileName = @fileName;
			IF @databaseToRestore <> @restoredName
				SET @restoredFileName = @restoredName;

			IF @ndfCount > 0 
				SET @restoredFileName = @restoredFileName + CAST((@ndfCount + 1) AS sysname);

            SET @move = @move + N'MOVE ''' + @logicalFileName + N''' TO ''' + CASE WHEN @fileId = 2 THEN @RestoredRootLogPath ELSE @RestoredRootDataPath END + N'\' + @restoredFileName + '.';
            IF @fileId = 1
                SET @move = @move + N'mdf';
            IF @fileId = 2
                SET @move = @move + N'ldf';

            IF @fileId NOT IN (1, 2) BEGIN
                SET @move = @move + N'ndf';
				SET @ndfCount = @ndfCount + 1;
			END;

            SET @move = @move + N''', '

            FETCH NEXT FROM mover INTO @logicalFileName, @fileId, @type, @fileName;
        END;

        CLOSE mover;
        DEALLOCATE mover;

        SET @move = LEFT(@move, LEN(@move) - 1); -- remove the trailing ", "... 

        -- Set up the Restore Command and Execute:
        SET @command = REPLACE(@fullRestoreTemplate, N'{0}', @restoredName);
        SET @command = REPLACE(@command, N'{1}', @pathToDatabaseBackup);
        SET @command = REPLACE(@command, N'{move}', @move);
		SET @command = REPLACE(@command, N'{partial}', (CASE WHEN @isPartialRestore = 1 THEN N'PARTIAL, ' ELSE N'' END));
		
        BEGIN TRY 
            IF @PrintOnly = 1 BEGIN
                PRINT @command;
              END;
            ELSE BEGIN
                SET @outcome = NULL;
                EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

                SET @statusDetail = @outcome;
            END;
        END TRY 
        BEGIN CATCH
            SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
        END CATCH

		-- Update MetaData: 
		BEGIN TRY
			EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

			UPDATE @restoredFiles 
			SET 
				[Applied] = GETDATE(), 
				[BackupCreated] = @backupDate, 
				[BackupSize] = @backupSize, 
				[Compressed] = @compressed, 
				[Encrypted] = @encrypted
			WHERE 
				[FileName] = @backupName;
		END TRY 
		BEGIN CATCH 
			SELECT @statusDetail = ISNULL(@statusDetail, N'') + N'Error updating list of restored files after FULL. Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
		END CATCH;

        IF @statusDetail IS NOT NULL BEGIN
            GOTO NextDatabase;
        END;
        
		-- Restore any DIFF backups if present:
        SET @serializedFileList = NULL;
		EXEC dbo.load_backup_files 
            @DatabaseToRestore = @databaseToRestore, 
            @SourcePath = @sourcePath, 
            @Mode = N'DIFF', 
			@LastAppliedFinishTime = @backupDate, 
            @Output = @serializedFileList OUTPUT;
		
		IF (SELECT dbo.[is_xml_empty](@serializedFileList)) = 0 BEGIN 

			WITH shredded AS ( 
				SELECT 
					[data].[row].value('@file_name', 'nvarchar(max)') [file_name]
				FROM 
					@serializedFileList.nodes('//file') [data]([row])
			) 
			SELECT @backupName = (SELECT TOP 1 [file_name] FROM [shredded]);

			SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName

            SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName) + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			INSERT INTO @restoredFiles ([FileName], [Detected])
			SELECT @backupName, GETDATE();

            BEGIN TRY
                IF @PrintOnly = 1 BEGIN
                    PRINT @command;
                  END;
                ELSE BEGIN
                    SET @outcome = NULL;
                    EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

                    SET @statusDetail = @outcome;
                END;
            END TRY
            BEGIN CATCH
                SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            END CATCH
				
			BEGIN TRY
				-- Update MetaData: 
				EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

				UPDATE @restoredFiles 
				SET 
					[Applied] = GETDATE(), 
					[BackupCreated] = @backupDate, 
					[BackupSize] = @backupSize, 
					[Compressed] = @compressed, 
					[Encrypted] = @encrypted
				WHERE 
					[FileName] = @backupName;
			END TRY
			BEGIN CATCH 
				SELECT @statusDetail = ISNULL(@statusDetail, N'') + N'Error updating list of restored files after DIFF. Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
			END CATCH;

            IF @statusDetail IS NOT NULL BEGIN
                GOTO NextDatabase;
            END;
		END;

        -- Restore any LOG backups if specified and if present:
        IF @SkipLogBackups = 0 BEGIN
			
			-- reset values per every 'loop' of main processing body:
			DELETE FROM @logFilesToRestore;

            SET @serializedFileList = NULL;
			EXEC dbo.load_backup_files 
                @DatabaseToRestore = @databaseToRestore, 
                @SourcePath = @sourcePath, 
                @Mode = N'LOG', 
				@LastAppliedFinishTime = @backupDate,
                @Output = @serializedFileList OUTPUT;

			WITH shredded AS ( 
				SELECT 
					[data].[row].value('@id[1]', 'int') [id], 
					[data].[row].value('@file_name', 'nvarchar(max)') [file_name]
				FROM 
					@serializedFileList.nodes('//file') [data]([row])
			) 

			INSERT INTO @logFilesToRestore ([log_file])
			SELECT [file_name] FROM [shredded] ORDER BY [id];
			
			-- re-update the counter: 
			SET @currentLogFileID = ISNULL((SELECT MIN(id) FROM @logFilesToRestore), @currentLogFileID + 1);

			-- start a loop to process files while they're still available: 
			WHILE EXISTS (SELECT NULL FROM @logFilesToRestore WHERE [id] = @currentLogFileID) BEGIN

				SELECT @backupName = log_file FROM @logFilesToRestore WHERE id = @currentLogFileID;
				SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName;

				INSERT INTO @restoredFiles ([FileName], [Detected])
				SELECT @backupName, GETDATE();

                SET @command = N'RESTORE LOG ' + QUOTENAME(@restoredName) + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';
                
                BEGIN TRY 
                    IF @PrintOnly = 1 BEGIN
                        PRINT @command;
                      END;
                    ELSE BEGIN
                        SET @outcome = NULL;
                        EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

                        SET @statusDetail = @outcome;
                    END;
                END TRY
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @backupName + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
                END CATCH

				BEGIN TRY
					-- Update MetaData: 
					EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

					UPDATE @restoredFiles 
					SET 
						[Applied] = GETDATE(), 
						[BackupCreated] = @backupDate, 
						[BackupSize] = @backupSize, 
						[Compressed] = @compressed, 
						[Encrypted] = @encrypted, 
						[Comment] = @statusDetail
					WHERE 
						[FileName] = @backupName;

				END TRY 
				BEGIN CATCH 
					SELECT @statusDetail = ISNULL(@statusDetail, N'') + N'Error updating list of restored files after LOG. Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
				END CATCH;

                IF @statusDetail IS NOT NULL BEGIN
                    GOTO NextDatabase;
                END;

				-- Check for any new files if we're now 'out' of files to process: 
				IF @currentLogFileID = (SELECT MAX(id) FROM @logFilesToRestore) BEGIN

					-- if there are any new log files, we'll get those... and they'll be added to the list of files to process (along with newer (higher) ids)... 
                    SET @serializedFileList = NULL;
					EXEC dbo.load_backup_files 
                        @DatabaseToRestore = @databaseToRestore, 
                        @SourcePath = @sourcePath, 
                        @Mode = N'LOG', 
						@LastAppliedFinishTime = @backupDate,
                        @Output = @serializedFileList OUTPUT;

					WITH shredded AS ( 
						SELECT 
							[data].[row].value('@id[1]', 'int') [id], 
							[data].[row].value('@file_name', 'nvarchar(max)') [file_name]
						FROM 
							@serializedFileList.nodes('//file') [data]([row])
					) 

					INSERT INTO @logFilesToRestore ([log_file])
					SELECT [file_name] FROM [shredded] WHERE [file_name] NOT IN (SELECT [log_file] FROM @logFilesToRestore)
					ORDER BY [id];
				END;

				-- increment: 
				SET @currentLogFileID = @currentLogFileID + 1;
			END;
        END;

        -- Recover the database if instructed: 
		IF @ExecuteRecovery = 1 BEGIN
			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName) + N' WITH {directives}RECOVERY;';
			SET @command = REPLACE(@command, N'{directives}', @directivesText);

			BEGIN TRY
				IF @PrintOnly = 1 BEGIN
					PRINT @command;
				  END;
				ELSE BEGIN
					SET @outcome = NULL;

                    -- TODO: do I want to specify a DIFFERENT (subset/set) of 'filters' for RESTORE and RECOVERY? (don't really think so, unless there are ever problems with 'overlap' and/or confusion.
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END;
			END TRY	
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				
				UPDATE dbo.[restore_log]
				SET 
					[recovery] = 'FAILED'
				WHERE 
					restore_id = @restoreLogId;

			END CATCH

			IF @statusDetail IS NOT NULL BEGIN
				GOTO NextDatabase;
			END;
		END;

        -- If we've made it here, then we need to update logging/meta-data:
        IF @PrintOnly = 0 BEGIN
            UPDATE dbo.restore_log 
            SET 
                restore_succeeded = 1,
				[recovery] = CASE WHEN @ExecuteRecovery = 0 THEN 'NORECOVERY' ELSE 'RECOVERED' END, 
                restore_end = GETDATE(), 
                error_details = NULL
            WHERE 
                restore_id = @restoreLogId;
        END;

        -- Run consistency checks if specified:
        IF @CheckConsistency = 1 BEGIN

            SET @command = N'DBCC CHECKDB([' + @restoredName + N']) WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;'; -- outputting data for review/analysis. 

            IF @PrintOnly = 0 BEGIN 
                UPDATE dbo.restore_log
                SET 
                    consistency_start = GETDATE(),
                    consistency_succeeded = 0, 
                    error_details = '#UNKNOWN ERROR CHECKING CONSISTENCY#'
                WHERE
                    restore_id = @restoreLogId;
            END;

            BEGIN TRY 
                IF @PrintOnly = 1 
                    PRINT @command;
                ELSE BEGIN 
                    DELETE FROM #DBCC_OUTPUT;
                    INSERT INTO #DBCC_OUTPUT (Error, [Level], [State], MessageText, RepairLevel, [Status], [DbId], DbFragId, ObjectId, IndexId, PartitionId, AllocUnitId, RidDbId, RidPruId, [File], [Page], Slot, RefDbId, RefPruId, RefFile, RefPage, RefSlot, Allocation)
                    EXEC sp_executesql @command; 

                    IF EXISTS (SELECT NULL FROM #DBCC_OUTPUT) BEGIN -- consistency errors: 
                        SET @statusDetail = N'CONSISTENCY ERRORS DETECTED against database ' + QUOTENAME(@restoredName) + N'. Details: ' + @crlf;
                        SELECT @statusDetail = @statusDetail + MessageText + @crlf FROM #DBCC_OUTPUT ORDER BY RowID;

                        UPDATE dbo.restore_log
                        SET 
                            consistency_end = GETDATE(),
                            consistency_succeeded = 0,
                            error_details = @statusDetail
                        WHERE 
                            restore_id = @restoreLogId;

                      END;
                    ELSE BEGIN -- there were NO errors:
                        UPDATE dbo.restore_log
                        SET
                            consistency_end = GETDATE(),
                            consistency_succeeded = 1, 
                            error_details = NULL
                        WHERE 
                            restore_id = @restoreLogId;

                    END;
                END;

            END TRY	
            BEGIN CATCH
                SELECT @statusDetail = N'Unexpected Exception while running consistency checks. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
                GOTO NextDatabase;
            END CATCH

        END;

-- Primary Restore/Restore-Testing complete - log file lists, and cleanup/prep for next db to process... 
NextDatabase:

        -- Record any error details as needed:
        IF @statusDetail IS NOT NULL BEGIN

            IF @PrintOnly = 1 BEGIN
                PRINT N'ERROR: ' + @statusDetail;
              END;
            ELSE BEGIN
                UPDATE dbo.restore_log
                SET 
                    error_details = @statusDetail
                WHERE 
                    restore_id = @restoreLogId;
            END;

          END;
		ELSE BEGIN 
			PRINT N'-- Operations for database [' + @restoredName + N'] completed successfully.' + @crlf + @crlf;
		END; 

		-- serialize restored file details and push into dbo.restore_log
		SELECT @fileListXml = (
			SELECT 
				ROW_NUMBER() OVER (ORDER BY ID) [@id],
				[FileName] [name], 
				BackupCreated [created],
				Detected [detected], 
				Applied [applied], 
				BackupSize [size], 
				Compressed [compressed], 
				[Encrypted] [encrypted], 
				[Comment] [comments]
			FROM 
				@restoredFiles 
			ORDER BY 
				ID
			FOR XML PATH('file'), ROOT('files')
		);

		IF @PrintOnly = 1
			PRINT N'-- ' + @fileListXml; 
		ELSE BEGIN
			UPDATE dbo.[restore_log] 
			SET 
				restored_files = @fileListXml  -- may be null in some cases (i.e., no FULL backup found or db backups not found/etc.) but... meh. 
			WHERE 
				[restore_id] = @restoreLogId;
		END;

        -- Drop the database if specified and if all SAFE drop precautions apply:
        IF @DropDatabasesAfterRestore = 1 BEGIN
            
            -- Make sure we can/will ONLY restore databases that we've restored in this session:
			SELECT @restoreStart = restore_start 
			FROM dbo.[restore_log] 
			WHERE [database] = @databaseToRestore AND [restored_as] = @restoredName AND [execution_id] = @executionID;
			
			SET @executeDropAllowed = 0;
			IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @restoredName AND [create_date] >= @restoreStart)
				SET @executeDropAllowed = 1;

            IF @PrintOnly = 1 AND @DropDatabasesAfterRestore = 1
                SET @executeDropAllowed = 1; 
            
            IF (@executeDropAllowed = 1) AND EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @restoredName) BEGIN -- this is a db we restored (or tried to restore) in this 'session' - so we can drop it:
                
				SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';';

				IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @restoredName AND [state_desc] = N'ONLINE') BEGIN
					SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName) + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + @crlf
						+ N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';' + @crlf + @crlf;
				END;

                BEGIN TRY 
                    IF @PrintOnly = 1 
                        PRINT @command;
                    ELSE BEGIN
                        UPDATE dbo.restore_log 
                        SET 
                            [dropped] = N'ATTEMPTED'
                        WHERE 
                            restore_id = @restoreLogId;

						EXEC @execOutcome = dbo.[execute_command]
							@Command = @command, 
							@DelayBetweenAttempts = N'8 seconds',
							@IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS],[SINGLE_USER]', 
							@Results = @execResults OUTPUT;

						IF @execOutcome <> 0 
							SET @statusDetail = N'Error with CLEANUP / DROP operations: ' + CAST(@execResults AS nvarchar(MAX));

                        IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN
                            SET @statusDetail = @statusDetail + @crlf + N'Executed command to DROP database [' + @restoredName + N']. No exceptions encountered, but database still in place POST-DROP.';

                            SET @failedDropCount = @failedDropCount +1;
                          END;
                        ELSE -- happy / expected outcome:
                            UPDATE dbo.restore_log
                            SET 
                                dropped = 'DROPPED'
                            WHERE 
                                restore_id = @restoreLogId;
                    END;

                END TRY 
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while attempting to DROP database [' + @restoredName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

                    UPDATE dbo.restore_log
                    SET 
                        dropped = 'ERROR', 
						[error_details] = ISNULL(error_details, N'') + @statusDetail
                    WHERE 
                        restore_id = @restoreLogId;

                    SET @failedDropCount = @failedDropCount +1;
                END CATCH
            END;

          END;
        ELSE BEGIN
            UPDATE dbo.restore_log 
            SET 
                dropped = 'LEFT ONLINE' -- same as 'NOT DROPPED' but shows explicit intention.
            WHERE
                restore_id = @restoreLogId;
        END;

        -- Check-up on total number of 'failed drops':
		IF @DropDatabasesAfterRestore = 1 BEGIN 
			SELECT @failedDropCount = COUNT(*) FROM dbo.[restore_log] WHERE [execution_id] = @executionID AND [dropped] IN ('ATTEMPTED', 'ERROR');

			IF @failedDropCount >= @MaxNumberOfFailedDrops BEGIN 
				-- we're done - no more processing (don't want to risk running out of space with too many restore operations.
				SET @earlyTermination = N'Max number of databases that could NOT be dropped after restore/testing was reached. Early terminatation forced to reduce risk of causing storage problems.';
				GOTO FINALIZE;
			END;
		END;

        FETCH NEXT FROM restorer INTO @databaseToRestore;
    END

    -----------------------------------------------------------------------------
FINALIZE:

    -- close/deallocate any cursors left open:
    IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN
        CLOSE restorer;
        DEALLOCATE restorer;
    END;

    IF (SELECT CURSOR_STATUS('local','mover')) > -1 BEGIN
        CLOSE mover;
        DEALLOCATE mover;
    END;

    IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN
        CLOSE logger;
        DEALLOCATE logger;
    END;

	-- Process RPO Warnings: 
	DECLARE @rpoWarnings nvarchar(MAX) = NULL;
	IF NULLIF(@RpoWarningThreshold, N'') IS NOT NULL BEGIN 
		
		DECLARE @rpo sysname = (SELECT dbo.[format_timespan](@vector * 1000));
		DECLARE @rpoMessage nvarchar(MAX) = N'';

		SELECT 
			[database], 
			[restored_files],
			[restore_end]
		INTO #subset
		FROM 
			dbo.[restore_log] 
		WHERE 
			[execution_id] = @executionID
		ORDER BY
			[restore_id];

		WITH core AS ( 
			SELECT 
				s.[database], 
				s.restored_files.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime') [most_recent_backup],
				s.[restore_end]
			FROM 
				#subset s
		)

		SELECT 
			IDENTITY(int, 1, 1) [id],
			c.[database], 
			c.[most_recent_backup], 
			c.[restore_end], 
			CASE WHEN ((DATEDIFF(DAY, [c].[most_recent_backup], [c].[restore_end])) < 20) THEN -1 ELSE (DATEDIFF(DAY, [c].[most_recent_backup], [c].[restore_end])) END [days_old], 
			CASE WHEN ((DATEDIFF(DAY, [c].[most_recent_backup], [c].[restore_end])) > 20) THEN -1 ELSE (DATEDIFF(MILLISECOND, [c].[most_recent_backup], [c].[restore_end])) END [vector]
		INTO 
			#stale 
		FROM 
			[core] c;

		SELECT 
			@rpoMessage = @rpoMessage 
			+ @crlf + N'  WARNING: database ' + QUOTENAME([x].[database]) + N' exceeded recovery point objectives: '
			+ @crlf + @tab + N'- recovery_point_objective  : ' + @RpoWarningThreshold --  @rpo
			+ @crlf + @tab + @tab + N'- most_recent_backup: ' + CONVERT(sysname, [x].[most_recent_backup], 120) 
			+ @crlf + @tab + @tab + N'- restore_completion: ' + CONVERT(sysname, [x].[restore_end], 120)
			+  CASE WHEN [x].[vector] = -1 THEN 
					+ @crlf + @tab + @tab + @tab + N'- recovery point exceeded by: ' + CAST([x].[days_old] AS sysname) + N' days'
				ELSE 
					+ @crlf + @tab + @tab + @tab + N'- actual recovery point     : ' + dbo.[format_timespan]([x].vector)
					+ @crlf + @tab + @tab + @tab + N'- recovery point exceeded by: ' + dbo.[format_timespan]([x].vector - (@vector))
				END + @crlf
		FROM 
			[#stale] x
		WHERE  
			(x.[vector] > (@vector * 1000)) OR [x].[days_old] > 20 
		ORDER BY 
			CASE WHEN [x].[days_old] > 20 THEN [x].[days_old] ELSE 0 END DESC, 
			[x].[vector];

		IF LEN(@rpoMessage) > 2
			SET @rpoWarnings = N'WARNINGS: ' 
				+ @crlf + @rpoMessage + @crlf + @crlf;

	END;

    -- Assemble details on errors - if there were any (i.e., logged errors OR any reason for early termination... 
    IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN

        SET @emailErrorMessage = N'ERRORS: ' + @crlf;

        SELECT 
			@emailErrorMessage = @emailErrorMessage 
			+ @crlf + N'   ERROR: problem with database ' + QUOTENAME([database]) + N'.' 
			+ @crlf + @tab + N'- source_database:' + QUOTENAME([database])
			+ @crlf + @tab + N'- restored_as: ' + QUOTENAME([restored_as]) + CASE WHEN [restore_succeeded] = 1 THEN N'' ELSE ' (attempted - but failed) ' END 
			+ @crlf
			+ @crlf + @tab + N'   - error_detail: ' + [error_details] 
			+ @crlf + @crlf
        FROM 
            dbo.restore_log
        WHERE 
            execution_id = @executionID
            AND error_details IS NOT NULL
        ORDER BY 
            restore_id;

        -- notify too that we stopped execution due to early termination:
        IF NULLIF(@earlyTermination, '') IS NOT NULL BEGIN
            SET @emailErrorMessage = @emailErrorMessage + @tab + N'- ' + @earlyTermination;
        END;
    END;
    
    IF @emailErrorMessage IS NOT NULL OR @rpoWarnings IS NOT NULL BEGIN

		SET @emailErrorMessage = ISNULL(@rpoWarnings, '') + ISNULL(@emailErrorMessage, '');

        IF @PrintOnly = 1
            PRINT N'ERROR: ' + @emailErrorMessage;
        ELSE BEGIN
            SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

            EXEC msdb..sp_notify_operator
                @profile_name = @MailProfileName,
                @name = @OperatorName,
                @subject = @emailSubject, 
                @body = @emailErrorMessage;
        END;
    END;

    RETURN 0;
GO