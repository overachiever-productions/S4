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
	@Exclusions							nvarchar(MAX)		= NULL,
	@Priorities							nvarchar(MAX)		= NULL, 
	@BackupsRootPath					nvarchar(MAX)		= N'{DEFAULT}',
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
    EXEC dbo.verify_advanced_capabilities;;

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

    IF UPPER(@SourceDatabases) IN (N'{SYSTEM}', N'{USER}') BEGIN
        RAISERROR('The tokens {SYSTEM} and {USER} cannot be used to specify which databases to restore via dbo.apply_logs. Only explicitly defined/named databases can be targetted - e.g., N''myDB, anotherDB, andYetAnotherDbName''.', 16, 1);
        RETURN -10;
    END;

    IF (NULLIF(@TargetDbMappingPattern,'')) IS NULL BEGIN
        RAISERROR('@TargetDbMappingPattern can NOT be NULL or empty. Use the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname'').', 16, 1);
        RETURN -22;
    END;

	IF UPPER(@RecoveryType) = N'RECOVER' SET @RecoveryType = N'RECOVERY';
	IF(@RecoveryType) NOT IN (N'NORECOVERY', N'RECOVERY', N'STANDBY') BEGIN 
		RAISERROR(N'Allowable @RecoveryType options are { NORECOVERY | RECOVERY | STANDBY }. The value [%s] is not supported.', 16, 1, @RecoveryType);
		RETURN -32;
	END;

	DECLARE @vectorError nvarchar(MAX);
	DECLARE @vector bigint;  -- represents # of MILLISECONDS that a 'restore' operation is allowed to be stale

	IF NULLIF(@StaleAlertThreshold, N'') IS NOT NULL BEGIN

		EXEC [dbo].[translate_vector]
			@Vector = @StaleAlertThreshold, 
			@ValidationParameterName = N'@StaleAlertThreshold', 
			@ProhibitedIntervals = NULL, 
			@TranslationDatePart = N'SECOND', 
			@Output = @vector OUTPUT, 
			@Error = @vectorError OUTPUT;

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1); 
			RETURN -30;
		END;
	END;

	-----------------------------------------------------------------------------
    -- Allow for default paths:
    IF UPPER(@BackupsRootPath) = N'{DEFAULT}' BEGIN
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
	-- If the {READ_FROM_FILESYSTEM} token is specified, replace {READ_FROM_FILESYSTEM} in @DatabasesToRestore with a serialized list of db-names pulled from @BackupRootPath:
	IF ((SELECT dbo.[count_matches](@SourceDatabases, N'{READ_FROM_FILESYSTEM}')) > 0) BEGIN
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

		SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);

        SET @databases = NULL;
		EXEC dbo.load_backup_database_names
			@TargetDirectory = @BackupsRootPath, 
			@SerializedOutput = @databases OUTPUT;

		SET @SourceDatabases = REPLACE(@SourceDatabases, N'{READ_FROM_FILESYSTEM}', @serialized); 
	END;

    -----------------------------------------------------------------------------
	-- start processing:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @sourceDbName sysname;
	DECLARE @targetDbName sysname;
	DECLARE @fileList xml;
	DECLARE @latestPreviousFileRestored sysname;
	DECLARE @sourcePath sysname; 
	DECLARE @backupFilesList xml = NULL;
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

	DECLARE @outputSummary nvarchar(MAX);
    DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
    DECLARE @tab char(1) = CHAR(9);

	DECLARE @offset sysname;
	DECLARE @tufPath sysname;
	DECLARE @restoredFiles xml;

	-- meta-data variables:
	DECLARE @backupDate datetime, @backupSize bigint, @compressed bit, @encrypted bit;

    -- Construct list of databases to process:
	DECLARE @applicableDatabases table (
		entry_id int IDENTITY(1,1) NOT NULL, 
		source_database_name sysname NOT NULL,
		target_database_name sysname NOT NULL
	);

	DECLARE @possibleDatabases table ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 

	INSERT INTO @possibleDatabases ([database_name])
	EXEC dbo.list_databases 
        @Targets = @SourceDatabases,         
        @Exclusions = @Exclusions,		
        @Priorities = @Priorities,

		@ExcludeSimpleRecovery = 1, 
		@ExcludeRestoring = 0, -- we're explicitly targetting just these in fact... 
		@ExcludeRecovering = 1; -- we don't want these... (they're 'too far gone')

	INSERT INTO @applicableDatabases ([source_database_name], [target_database_name])
	SELECT [database_name] [source_database_name], REPLACE(@TargetDbMappingPattern, N'{0}', [database_name]) [target_database_name] FROM @possibleDatabases ORDER BY [row_id];

	-- exclude online DBs - as we, obviously, can't apply logs to them:
	DELETE FROM @applicableDatabases WHERE [target_database_name] IN (SELECT [name] FROM sys.databases WHERE [state_desc] = N'ONLINE');

	-- also exclude DBs where target isn't online or doesn't exist: 
	DELETE FROM @applicableDatabases WHERE [target_database_name] NOT IN (SELECT [name] FROM sys.databases);

    IF NOT EXISTS (SELECT NULL FROM @applicableDatabases) BEGIN
        SET @earlyTermination = N'Databases specified for apply_logs operation: [' + @SourceDatabases + ']. However, none of the databases specified can have T-LOGs applied - as there are no databases in STANDBY or NORECOVERY mode.';
        GOTO FINALIZE;
    END;
	
	-- Begin application of logs:
    PRINT '-- Databases To Attempt Log Application Against: ' + @serialized;

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
		DELETE FROM @appliedFiles;

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

		SET @backupFilesList = NULL;
		EXEC dbo.load_backup_files 
			@DatabaseToRestore = @sourceDbName, 
			@SourcePath = @sourcePath, 
			@Mode = N'LOG', 
			@LastAppliedFile = @latestPreviousFileRestored, 
			@Output = @backupFilesList OUTPUT;
		
		-- reset values per every 'loop' of main processing body:
		DELETE FROM @logFilesToRestore;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [id], 
				[data].[row].value('@file_name', 'nvarchar(max)') [file_name]
			FROM 
				@backupFilesList.nodes('//file') [data]([row])
		) 

		INSERT INTO @logFilesToRestore ([log_file])
		SELECT [file_name] FROM [shredded] ORDER BY [id];
		
		SET @logsWereApplied = 0;

		IF EXISTS(SELECT NULL FROM @logFilesToRestore) BEGIN

			-- switch any dbs in STANDBY back to NORECOVERY.
			IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @targetDbName AND [is_in_standby] = 1) BEGIN

				SET @command = N'ALTER DATABASE ' + QUOTENAME(@targetDbName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; 
GO
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

                    SET @backupFilesList = NULL;
					-- if there are any new log files, we'll get those... and they'll be added to the list of files to process (along with newer (higher) ids)... 
					EXEC dbo.load_backup_files 
                        @DatabaseToRestore = @sourceDbName, 
                        @SourcePath = @sourcePath, 
                        @Mode = N'LOG', 
						@LastAppliedFinishTime = @backupDate,
                        @Output = @backupFilesList OUTPUT;

					WITH shredded AS ( 
						SELECT 
							[data].[row].value('@id[1]', 'int') [id], 
							[data].[row].value('@file_name', 'nvarchar(max)') [file_name]
						FROM 
							@backupFilesList.nodes('//file') [data]([row])
					) 

					INSERT INTO @logFilesToRestore ([log_file])
					SELECT [file_name] FROM [shredded] WHERE [file_name] NOT IN (SELECT [log_file] FROM @logFilesToRestore)
					ORDER BY [id];

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
		DECLARE @latestApplied datetime;
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

			IF DATEDIFF(SECOND, @latestApplied, GETDATE()) > @vector BEGIN 
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

		-- Report on outcome for manual operations/interactions: 
		IF @logsWereApplied = 1 BEGIN
			SET @outputSummary = N'Applied the following Logs: ' + @crlf;

			SELECT 
				@outputSummary = @outputSummary + @tab + [FileName] + @crlf
			FROM 
				@appliedFiles 
			ORDER BY 
				ID;

			EXEC [dbo].[print_long_string] @outputSummary;
		END; ELSE BEGIN
			IF NULLIF(@statusDetail,'') IS NULL
				PRINT N'Success. No new/applicable logs found.';
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
	DECLARE @message nvarchar(MAX) = N'';

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
			SET @messageSeverity = N'ERROR';

		SET @message = @message + N'The following ERRORs were encountered: ' + @crlf;

		IF NULLIF(@earlyTermination, N'') IS NOT NULL 
			SET @message = @message + @earlyTermination;

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

	IF NULLIF(@message, N'') IS NOT NULL BEGIN 

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