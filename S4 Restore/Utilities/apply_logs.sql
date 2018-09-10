

/*



	TODO: 
		- this piglet needs a MAJOR refactor... i wrote it over a period of days (calendar-wise) so ideas/concepts are 'all over the place' and i've got lots of REDUNDANCIES in error checking, evaluation/logic, etc. 
		

	vNEXT: 
		- implement @RestoreBufferDelay	... 

	FODDER: 
		Info on .tuf files (in short, they're to keep any 'in flight' transactions that would NORMALLY have to be rolled-back IF we were recovering (whereas, if we specify NORECOVERY, there's no worry about these TXs until WITH RECOVERY is fired). 
			- https://sqlserver-help.com/2014/07/24/sql-server-internals-what-is-tuf-file-in-sql-server/
			- https://support.microsoft.com/en-us/help/962008/fix-error-message-when-you-use-log-shipping-in-sql-server-2008-during



	EXEC admindb.dbo.apply_logs
		@SourceDatabases = N'Billing', 
		@TargetDbMappingPattern = N'{0}_test';




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.apply_logs','P') IS NOT NULL
	DROP PROC dbo.apply_logs;
GO

CREATE PROC dbo.apply_logs 
	@SourceDatabases					nvarchar(MAX)		= NULL,						-- explicitly named dbs - e.g., N'db1, db7, db28' ... and, only works, obviously, if dbs specified are in non-recovered mode (or standby).
	@Priorities							nvarchar(MAX)		= NULL, 
	@BackupsRootPath					nvarchar(MAX)		= N'[DEFAULT]',
	@TargetDbMappingPattern				sysname				= N'{0}',					-- MAY not use/allow... 
	@RecoveryType						sysname				= N'NORECOVERY',			-- options are: NORECOVERY | STANDBY | RECOVERY
	@StaleAlertThreshold				nvarchar(10)		= NULL,						-- NULL means... don't bother... otherwise, if the restoring_db is > @threshold... raise an alert... 
	@AlertOnStaleOnly					bit					= 0,						-- when true, then failures won't trigger alerts - only if/when stale-threshold is exceeded is an alert sent.
	@OperatorName						sysname				= N'Alerts', 
    @MailProfileName					sysname				= N'General', 
    @EmailSubjectPrefix					sysname				= N'[APPLY LOGS] - ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON; 

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
    IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN
        RAISERROR('S4 Table dbo.restore_log not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;
    
	IF OBJECT_ID('dbo.load_backup_files', 'P') IS NULL BEGIN 
		RAISERROR('S4 Stored Procedure dbo.load_backup_files not defined - unable to continue.', 16, 1);
        RETURN -1;
	END; 

	IF OBJECT_ID('dbo.load_header_details', 'P') IS NULL BEGIN 
		RAISERROR('S4 Stored Procedure dbo.load_header_details not defined - unable to continue.', 16, 1);
        RETURN -1;
	END; 

    IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
        RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;

    IF OBJECT_ID('dbo.check_paths', 'P') IS NULL BEGIN
        RAISERROR('S4 Stored Procedure dbo.check_paths not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;

    IF OBJECT_ID('dbo.get_time_vector','P') IS NULL BEGIN
        RAISERROR('S4 Stored Procedure dbo.get_time_vector not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;

    IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NULL BEGIN
        RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
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
 
        IF @DatabaseMailProfile <> @MailProfileName BEGIN
            RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
            RETURN -2;
        END; 
    END;

    IF UPPER(@SourceDatabases) IN (N'[SYSTEM]', N'[USER]') BEGIN
        RAISERROR('The tokens [SYSTEM] and [USER] cannot be used to specify which databases to restore via dbo.apply_logs. Only explicitly defined/named databases can be targetted - e.g., N''myDB, anotherDB, andYetAnotherDbName''.', 16, 1);
        RETURN -10;
    END;

    IF (NULLIF(@TargetDbMappingPattern,'')) IS NULL BEGIN
        RAISERROR('@TargetDbMappingPattern can NOT be NULL or empty. Use the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname'').', 16, 1);
        RETURN -22;
    END;

	DECLARE @rpoCutoff datetime; 
	DECLARE @vectorReturn int; 
	DECLARE @vectorError nvarchar(MAX);
	DECLARE @vector int;  -- represents # of MS that something is allowed to be stale
	DECLARE @latestApplied datetime;

	IF NULLIF(@StaleAlertThreshold, N'') IS NOT NULL BEGIN

		EXEC @vectorReturn = dbo.get_time_vector
			@Vector = @StaleAlertThreshold, 
			@ParameterName = N'@StaleAlertThreshold',
			@AllowedIntervals = N's, m, h, d', 
			@Mode = N'SUBTRACT', 
			@Output = @rpoCutoff OUTPUT, 
			@Error = @vectorError OUTPUT;

		IF @vectorReturn <> 0 BEGIN
			RAISERROR(@vectorError, 16, 1); 
			RETURN @vectorReturn;
		END;

		SET @vector = DATEDIFF(MILLISECOND, @rpoCutoff, GETDATE());
	END;

	-----------------------------------------------------------------------------
    -- Allow for default paths:
    IF UPPER(@BackupsRootPath) = N'[DEFAULT]' BEGIN
        SELECT @BackupsRootPath = dbo.load_default_path('BACKUP');
    END;

    -- 'Global' Variables:
    DECLARE @isValid bit;
	DECLARE @earlyTermination nvarchar(MAX) = N'';

	-- normalize paths: 
	IF(RIGHT(@BackupsRootPath, 1) = '\')
		SET @BackupsRootPath = LEFT(@BackupsRootPath, LEN(@BackupsRootPath) - 1);
    
	-- Verify Paths: 
    EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    -----------------------------------------------------------------------------
    -- Construct list of databases to process:
	DECLARE @applicableDatabases table (
		entry_id int IDENTITY(1,1) NOT NULL, 
		source_database_name sysname NOT NULL,
		target_database_name sysname NOT NULL
	);

	INSERT INTO @applicableDatabases ([source_database_name], [target_database_name])
	SELECT [result], REPLACE(@TargetDbMappingPattern, N'{0}', [result]) [target] FROM [dbo].[split_string](@SourceDatabases, N',');

	-- now, remove any dbs for which we a) don't have backups and/or b) there isn't a viable db in non-recovered (non-standby) mode for application:
	DECLARE @serialized nvarchar(MAX);

    EXEC dbo.load_database_names
        @Input = @SourceDatabases,         
        @Exclusions = NULL,		
        @Priorities = @Priorities,
        @Mode = N'RESTORE',
        @TargetDirectory = @BackupsRootPath, 
        @Output = @serialized OUTPUT;

	DELETE FROM @applicableDatabases WHERE [source_database_name] NOT IN (SELECT [result] FROM dbo.[split_string](@serialized, N','));

	-- now, remove any dbs where we don't have a corresponding db being restored.... 
	DECLARE @renamedDBs nvarchar(MAX) = @SourceDatabases;
	IF @TargetDbMappingPattern <> N'{0}' BEGIN
		SET @renamedDBs = N'';
		SELECT @renamedDBs = @renamedDBs + target_database_name + N',' FROM @applicableDatabases ORDER BY [entry_id];
		SET @renamedDBs = LEFT(@renamedDBs, LEN(@renamedDBs) - 1);
	END;

    EXEC dbo.load_database_names
        @Input = @renamedDBs,         
        @Exclusions = NULL,		
        @Priorities = @Priorities,
        @Mode = N'NON_RECOVERED',		-- STANDBY and NORECOVERY only (excluding mirrored or AG'd databases).
        @TargetDirectory = @BackupsRootPath, 
        @Output = @serialized OUTPUT;

	DELETE FROM @applicableDatabases WHERE [target_database_name] NOT IN (SELECT [result] FROM dbo.[split_string](@serialized, N','));

    IF NOT EXISTS (SELECT NULL FROM @applicableDatabases) BEGIN
        SET @earlyTermination = N'Databases specified for apply_logs operation: [' + @SourceDatabases + ']. However, none of the databases specified can have T-LOGs applied - as there are no databases in STANDBY or NORECOVERY mode.';
        GOTO FINALIZE;
    END;

    PRINT '-- Databases To Attempt Log Application Against: ' + @serialized;

    -----------------------------------------------------------------------------
	-- start processing:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @sourceDbName sysname;
	DECLARE @targetDbName sysname;
	DECLARE @fileList xml;
	DECLARE @latestPreviousFileRestored sysname;
	DECLARE @sourcePath sysname; 
	DECLARE @backupFilesList nvarchar(MAX);
	DECLARE @currentLogFileID int;
	DECLARE @backupName sysname;
	DECLARE @pathToTLogBackup sysname;
	DECLARE @command nvarchar(2000);
	DECLARE @outcome varchar(4000);
	DECLARE @statusDetail nvarchar(500);
	DECLARE @appliedFileList nvarchar(MAX);
	DECLARE @restoreStart datetime;
	DECLARE @logsWereApplied bit = 0;
	DECLARE @operationSuccess bit;
	DECLARE @noFilesApplied bit = 0;

	DECLARE @offset sysname;
	DECLARE @tufPath sysname;
	DECLARE @restoredFiles xml;

	-- meta-data variables:
	DECLARE @backupDate datetime, @backupSize bigint, @compressed bit, @encrypted bit;

	DECLARE @logFilesToRestore table ( 
		id int IDENTITY(1,1) NOT NULL, 
		log_file sysname NOT NULL
	);

	DECLARE @appliedFiles table (
		ID int IDENTITY(1,1) NOT NULL, 
		[FileName] nvarchar(400) NOT NULL, 
		Detected datetime NOT NULL, 
		BackupCreated datetime NULL, 
		Applied datetime NULL, 
		BackupSize bigint NULL, 
		Compressed bit NULL, 
		[Encrypted] bit NULL
	); 

	DECLARE @warnings table (
		warning_id int IDENTITY(1,1) NOT NULL, 
		warning nvarchar(MAX) NOT NULL 
	);

    DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
    SELECT 
        [source_database_name],
		[target_database_name]
    FROM 
        @applicableDatabases
    ORDER BY 
        entry_id;

	OPEN [restorer]; 

	FETCH NEXT FROM [restorer] INTO @sourceDbName, @targetDbName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		SET @restoreStart = GETDATE();
		SET @noFilesApplied = 0;  

		-- determine last successfully applied t-log:
		SELECT @fileList = [restored_files] FROM dbo.[restore_log] WHERE [restore_id] = (SELECT MAX(restore_id) FROM [dbo].[restore_log] WHERE [database] = @sourceDbName AND [restored_as] = @targetDbName AND [restore_succeeded] = 1);

		IF @fileList IS NULL BEGIN 
			SET @statusDetail = N'Attempt to apply logs from ' + QUOTENAME(@sourceDbName) + N' to ' + QUOTENAME(@targetDbName) + N' could not be completed. No details in dbo.restore_log for last backup-file used during restore/application process. Please use dbo.restore_databases to ''seed'' databases.';
			GOTO NextDatabase;
		END; 

		SELECT @latestPreviousFileRestored = @fileList.value('(/files/file[@id = max(/files/file/@id)]/name)[1]', 'sysname');

		IF @latestPreviousFileRestored IS NULL BEGIN 
			SET @statusDetail = N'Attempt to apply logs from ' + QUOTENAME(@sourceDbName) + N' to ' + QUOTENAME(@targetDbName) + N' could not be completed. The column: restored_files in dbo.restore_log is missing data on the last file applied to ' + QUOTENAME(@targetDbName) + N'. Please use dbo.restore_databases to ''seed'' databases.';
			GOTO NextDatabase;
		END; 

		SET @sourcePath = @BackupsRootPath + N'\' + @sourceDbName;
		EXEC dbo.load_backup_files 
			@DatabaseToRestore = @sourceDbName, 
			@SourcePath = @sourcePath, 
			@Mode = N'LOG', 
			@LastAppliedFile = @latestPreviousFileRestored, 
			@Output = @backupFilesList OUTPUT;

		-- reset values per every 'loop' of main processing body:
		DELETE FROM @logFilesToRestore;

		INSERT INTO @logFilesToRestore ([log_file])
		SELECT [result] FROM dbo.[split_string](@backupFilesList, N',') ORDER BY row_id;

		SET @logsWereApplied = 0;

		IF EXISTS(SELECT NULL FROM @logFilesToRestore) BEGIN

			-- switch any dbs in STANDBY back to NORECOVERY.
			IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @targetDbName AND [is_in_standby] = 1) BEGIN

				SET @command = N'ALTER DATABASE ' + QUOTENAME(@targetDbName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; 
RESTORE DATABASE ' + QUOTENAME(@targetDbName) + N' WITH NORECOVERY;';

				IF @PrintOnly = 1 BEGIN 
					PRINT @command;
				  END; 
				ELSE BEGIN 

					BEGIN TRY 
						SET @outcome = NULL; 
						DECLARE @result varchar(4000);
						EXEC dbo.[execute_uncatchable_command] @command, N'UN-STANDBY', @Result = @outcome OUTPUT;

						SET @statusDetail = @outcome;

					END TRY	
					BEGIN CATCH
						SELECT @statusDetail = N'Unexpected Exception while attempting to remove database ' + QUOTENAME(@targetDbName) + N' from STANDBY mode. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
						GOTO NextDatabase;
					END CATCH

					-- give it a second, and verify the state: 
					WAITFOR DELAY '00:00:05';

					IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @targetDbName AND [is_in_standby] = 1) BEGIN
						SET @statusDetail = N'Database ' + QUOTENAME(@targetDbName) + N' was set to RESTORING but, 05 seconds later, is still in STANDBY mode.';
					END;
				END;

				-- if there were ANY problems with the operations above, we can't apply logs: 
				IF @statusDetail IS NOT NULL 
					GOTO NextDatabase;
			END;

			-- re-update the counter: 
			SET @currentLogFileID = ISNULL((SELECT MIN(id) FROM @logFilesToRestore), @currentLogFileID + 1);

			WHILE EXISTS (SELECT NULL FROM @logFilesToRestore WHERE [id] = @currentLogFileID) BEGIN

				SELECT @backupName = log_file FROM @logFilesToRestore WHERE id = @currentLogFileID;
				SET @pathToTLogBackup = @sourcePath + N'\' + @backupName;

				INSERT INTO @appliedFiles ([FileName], [Detected])
				SELECT @backupName, GETDATE();

				SET @command = N'RESTORE LOG ' + QUOTENAME(@targetDbName) + N' FROM DISK = N''' + @pathToTLogBackup + N''' WITH NORECOVERY;';
                
				BEGIN TRY 
					IF @PrintOnly = 1 BEGIN
						PRINT @command;
					  END;
					ELSE BEGIN
						SET @outcome = NULL;
						EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;
						SET @statusDetail = @outcome;
					END;
				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @backupName + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					-- don't go to NextDatabase - we need to record meta data FIRST... 
				END CATCH

				-- Update MetaData: 
				EXEC dbo.load_header_details @BackupPath = @pathToTLogBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

				UPDATE @appliedFiles 
				SET 
					[Applied] = GETDATE(), 
					[BackupCreated] = @backupDate, 
					[BackupSize] = @backupSize, 
					[Compressed] = @compressed, 
					[Encrypted] = @encrypted
				WHERE 
					[FileName] = @backupName;

				IF @statusDetail IS NOT NULL BEGIN
					GOTO NextDatabase;
				END;

				-- Check for any new files if we're now 'out' of files to process: 
				IF @currentLogFileID = (SELECT MAX(id) FROM @logFilesToRestore) BEGIN

					-- if there are any new log files, we'll get those... and they'll be added to the list of files to process (along with newer (higher) ids)... 
					EXEC dbo.load_backup_files @DatabaseToRestore = @sourceDbName, @SourcePath = @sourcePath, @Mode = N'LOG', @LastAppliedFile = @backupName, @Output = @backupFilesList OUTPUT;
					INSERT INTO @logFilesToRestore ([log_file])
					SELECT [result] FROM dbo.[split_string](@backupFilesList, N',') WHERE [result] NOT IN (SELECT [log_file] FROM @logFilesToRestore)
					ORDER BY row_id;
				END;

				-- signify files applied: 
				SET @logsWereApplied = 1;

				-- increment: 
				SET @currentLogFileID = @currentLogFileID + 1;
			END;
		  END;
		ELSE BEGIN 
			-- No Log Files found/available for application (either it's too early or something ugly has happened and backups aren't pushing files). 
			SET @noFilesApplied = 1; -- which will SKIP inserting a row for this db/operation BUT @StaleAlertThreshold will still get checked (to alert if something ugly is going on.

		END;

		IF UPPER(@RecoveryType) = N'STANDBY' AND @logsWereApplied = 1 BEGIN 
						
			SET @offset = RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),7);
			SELECT @tufPath = [physical_name] FROM sys.[master_files]  WHERE database_id = DB_ID(@targetDbName) AND [file_id] = 1;

			SET @tufPath = LEFT(@tufPath, LEN(@tufPath) - (CHARINDEX(N'\', REVERSE(@tufPath)) - 1)); -- strip the filename... 

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@targetDbName) + N' WITH STANDBY = N''' + @tufPath + @targetDbName + N'_' + @offset + N'.tuf'';
ALTER DATABASE ' + QUOTENAME(@targetDbName) + N' SET MULTI_USER;';

			IF @PrintOnly = 1 BEGIN 
				PRINT @command;
			  END;
			ELSE BEGIN
				BEGIN TRY
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END TRY
				BEGIN CATCH
					SET @statusDetail = N'Exception when attempting to put database ' + QUOTENAME(@targetDbName) + N' into STANDBY mode. [Command: ' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH
			END;
		END; 

		IF UPPER(@RecoveryType) = N'RECOVERY' AND @logsWereApplied = 1 BEGIN

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@targetDbName) + N' WITH RECCOVERY;';

			IF @PrintOnly = 1 BEGIN 
				PRINT @command;
			  END;
			ELSE BEGIN
				BEGIN TRY
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END TRY
				BEGIN CATCH
					SET @statusDetail = N'Exception when attempting to RECOVER database ' + QUOTENAME(@targetDbName) + N'. [Command: ' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH
			END;
		END;

NextDatabase:

		-- Execute Stale Checks if configured/defined: 
		IF NULLIF(@StaleAlertThreshold, N'') IS NOT NULL BEGIN

			IF @logsWereApplied = 1 BEGIN 
				SELECT @latestApplied = MAX([BackupCreated]) FROM @appliedFiles;  -- REFACTOR: call this variable @mostRecentBackup instead of @latestApplied... 
			  END;
			ELSE BEGIN -- grab it from the LAST successful operation 

				SELECT @restoredFiles = [restored_files] FROM dbo.[restore_log] WHERE [restore_id] = (SELECT MAX(restore_id) FROM [dbo].[restore_log] WHERE [database] = @sourceDbName AND [restored_as] = @targetDbName AND [restore_succeeded] = 1);

				IF @restoredFiles IS NULL BEGIN 
					
					PRINT 'warning ... could not get previous file details for stale check....';
				END; 

				SELECT @latestApplied = @restoredFiles.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime')
			END;

			IF DATEDIFF(MILLISECOND, @latestApplied, GETDATE()) > @vector BEGIN 
				INSERT INTO @warnings ([warning])
				VALUES ('Database ' + QUOTENAME(@targetDbName) + N' has exceeded the amount of time allowed since successfully restoring live data to the applied/target database. Specified threshold: ' + @StaleAlertThreshold + N', CreationTime of Last live backup: ' + CONVERT(sysname, @latestApplied, 121) + N'.');
			END;

		END;

		-- serialize restored file details and push into dbo.restore_log
		SELECT @appliedFileList = (
			SELECT 
				ROW_NUMBER() OVER (ORDER BY ID) [@id],
				[FileName] [name], 
				BackupCreated [created],
				Detected [detected], 
				Applied [applied], 
				BackupSize [size], 
				Compressed [compressed], 
				[Encrypted] [encrypted]
			FROM 
				@appliedFiles 
			ORDER BY 
				ID
			FOR XML PATH('file'), ROOT('files')
		);

		IF @PrintOnly = 1
			PRINT @appliedFileList; 
		ELSE BEGIN
			
			IF @logsWereApplied = 0
				SET @operationSuccess = 0 
			ELSE 
				SET @operationSuccess =  CASE WHEN NULLIF(@statusDetail,'') IS NULL THEN 1 ELSE 0 END;

			IF @noFilesApplied = 0 BEGIN
				INSERT INTO dbo.[restore_log] ([execution_id], [operation_date], [operation_type], [database], [restored_as], [restore_start], [restore_end], [restore_succeeded], [restored_files], [recovery], [dropped], [error_details])
				VALUES (@executionID, GETDATE(), 'APPLY-LOGS', @sourceDbName, @targetDbName, @restoreStart, GETDATE(), @operationSuccess, @appliedFileList, @RecoveryType, 'LEFT-ONLINE', NULLIF(@statusDetail, ''));
			END;
		END;

		FETCH NEXT FROM [restorer] INTO @sourceDbName, @targetDbName;
	END; 

	CLOSE [restorer];
	DEALLOCATE [restorer];

FINALIZE:

	-- check for and close cursor (if open/etc.)
	IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN;
		CLOSE [restorer];
		DEALLOCATE [restorer];
	END;

	DECLARE @messageSeverity sysname = N'';
	DECLARE @message nvarchar(MAX); 
    DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
    DECLARE @tab char(1) = CHAR(9);

	IF EXISTS (SELECT NULL FROM @warnings) BEGIN 
		SET @messageSeverity = N'WARNING';

		SET @message = N'The following WARNINGS were raised: ' + @crlf;

		SELECT 
			@message = @message + @crlf
			+ @tab + N'- ' + [warning]
		FROM 
			@warnings 
		ORDER BY [warning_id];

		SET @message = @message + @crlf + @crlf;
	END;

	IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN

		IF @messageSeverity <> '' 
			SET @messageSeverity = N'ERROR & WARNING';
		ELSE 
			SET @messageSeverity = N'ERRROR';

		SET @message = @message + N'The following ERRORs were encountered: ' + @crlf 

		SELECT 
			@message  = @message + @crlf
			+ @tab + N'- Database: ' + QUOTENAME([database]) + CASE WHEN [restored_as] <> [database] THEN N' (being restored as ' + QUOTENAME([restored_as]) + N') ' ELSE N' ' END + ': ' + [error_details]
		FROM 
			dbo.restore_log 
		WHERE 
			[execution_id] = @executionID AND error_details IS NOT NULL
		ORDER BY 
			[restore_id];
	END; 

	IF @message IS NOT NULL BEGIN 

		IF @AlertOnStaleOnly = 1 BEGIN
			IF @messageSeverity NOT LIKE '%WARNING%' BEGIN
				PRINT 'Apply Errors Detected - but not raised because @AlertOnStaleOnly is set to true.';
				RETURN 0; -- early termination... 
			END;
		END;

		DECLARE @subject nvarchar(2000) = ISNULL(@EmailSubjectPrefix, N'') + @messageSeverity;

		IF @PrintOnly = 1 BEGIN 
			PRINT @subject;
			PRINT @message;
		  END;
		ELSE BEGIN 
            EXEC msdb..sp_notify_operator
                @profile_name = @MailProfileName,
                @name = @OperatorName,
                @subject = @subject, 
                @body = @message;
		END;
	END;

	RETURN 0;
GO