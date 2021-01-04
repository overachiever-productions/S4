/*
		vNEXT: Need an option to UPDATE Existing Job 
			i.e., keep the same name/schedule... but... add in any new job steps and/or updated directives that make sense. 
				Except, that's sort of hard cuz... logic for @Overwrite Existing job now is: drop job, create again from scratch (with same name)

				So. arguably, might need a whole, secondary sproc for this - update_managed_server_history (lol. that name is out of control).

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.manage_server_history','P') IS NOT NULL
	DROP PROC dbo.[manage_server_history];
GO

CREATE PROC dbo.[manage_server_history]
	@HistoryCleanupJobName				sysname			= N'Regular History Cleanup', 
	@JobCategoryName					sysname			= N'Server Maintenance', 
	@JobOperatorToAlertOnErrors			sysname			= N'Alerts',
	@NumberOfServerLogsToKeep			int				= 24, 
	@StartDayOfWeekForCleanupJob		sysname			= N'Sunday',
	@StartTimeForCleanupJob				time			= N'09:45',				-- AM/24-hour time (i.e. defaults to morning)
	@TimeZoneForUtcOffset				sysname			= NULL,					-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@AgentJobHistoryRetention			sysname			= N'4 weeks', 
	@BackupHistoryRetention				sysname			= N'4 weeks', 
	@EmailHistoryRetention				sysname			= N'', 
	@CycleFTCrawlLogsInDatabases		nvarchar(MAX)	= NULL,
	@CleanupS4History					sysname			= N'', 
	@OverWriteExistingJob				bit				= 0						-- Exactly as it sounds. Used for cases where we want to force an exiting job into a 'new' shap.e... 
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	-- TODO: validate inputs... 

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		IF (SELECT [dbo].[get_engine_version]()) >= 13.0 BEGIN 

			DECLARE @utc datetime = GETUTCDATE();
			DECLARE @atTimeZone datetime;
			DECLARE @offsetSQL nvarchar(MAX) = N'SELECT @atTimeZone = @utc AT TIME ZONE ''UTC'' AT TIME ZONE @TimeZoneForUtcOffset; ';
			
			EXEC sys.[sp_executesql]
				@offsetSQL, 
				N'@atTimeZone datetime OUTPUT, @utc datetime, @TimeZoneForUtcOffset sysname', 
				@atTimeZone = @atTimeZone OUTPUT, 
				@utc = @utc, 
				@TimeZoneForUtcOffset = @TimeZoneForUtcOffset;

			SET @StartTimeForCleanupJob = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @StartTimeForCleanupJob);

		  END; 
		ELSE BEGIN 
			RAISERROR('@TimeZoneForUtcOffset is NOT supported on SQL Server versions prior to SQL Server 2016. Set value to NULL.', 16, 1); 
			RETURN -100;
		END;
	END;

	DECLARE @outcome int;
	DECLARE @error nvarchar(MAX);

	-- Set the Error Log Retention value: 
	EXEC xp_instance_regwrite 
		N'HKEY_LOCAL_MACHINE', 
		N'Software\Microsoft\MSSQLServer\MSSQLServer', 
		N'NumErrorLogs', 
		REG_DWORD, 
		@NumberOfServerLogsToKeep;

	-- Toggle Agent History Retention (i.e., get rid of 'silly' 1000/100 limits): 
	EXEC [msdb].[dbo].[sp_set_sqlagent_properties]			-- undocumented, but... pretty 'solid'/obvious: EXEC msdb.dbo.sp_helptext 'sp_set_sqlagent_properties';
		@jobhistory_max_rows = -1, 
		@jobhistory_max_rows_per_job = -1;

	DECLARE @historyDaysBack int; 
	EXEC @outcome = dbo.[translate_vector]
		@Vector = @AgentJobHistoryRetention,
		@ValidationParameterName = N'@AgentJobHistoryRetention',
		@ProhibitedIntervals = 'MILLISECOND, SECOND, MINUTE, HOUR',
		@TranslationDatePart = 'DAY',
		@Output = @historyDaysBack OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN
		RAISERROR(@error, 16, 1);
		RETURN - 20;
	END;

	DECLARE @backupDaysBack int;
	EXEC @outcome = dbo.[translate_vector]
		@Vector = @BackupHistoryRetention, 
		@ValidationParameterName = N'@BackupHistoryRetention', 
		@ProhibitedIntervals = 'MILLISECOND, SECOND, MINUTE, HOUR',
		@TranslationDatePart = 'DAY',
		@Output = @backupDaysBack OUTPUT, 
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN
		RAISERROR(@error, 16, 1);
		RETURN - 21;
	END;

	DECLARE @emailDaysBack int; 
	IF NULLIF(@EmailHistoryRetention, N'') IS NOT NULL BEGIN
		EXEC @outcome = dbo.[translate_vector]
			@Vector = @EmailHistoryRetention, 
			@ValidationParameterName = N'@EmailHistoryRetention', 
			@ProhibitedIntervals = 'MILLISECOND, SECOND, MINUTE, HOUR',
			@TranslationDatePart = 'DAY',
			@Output = @emailDaysBack OUTPUT, 
			@Error = @error OUTPUT;

		IF @outcome <> 0 BEGIN
			RAISERROR(@error, 16, 1);
			RETURN - 22;
		END;
	END;

	DECLARE @dayNames TABLE (
		day_map int NOT NULL, 
		day_name sysname NOT NULL
	);
	INSERT INTO @dayNames
	(
		day_map,
		day_name
	)
	SELECT id, val FROM (VALUES (1, N'Sunday'), (2, N'Monday'), (4, N'Tuesday'), (8, N'Wednesday'), (16, N'Thursday'), (32, N'Friday'), (64, N'Saturday')) d(id, val);

	IF NOT EXISTS(SELECT NULL FROM @dayNames WHERE UPPER([day_name]) = UPPER(@StartDayOfWeekForCleanupJob)) BEGIN
		RAISERROR(N'Specified value of ''%s'' for @StartDayOfWeekForCleanupJob is invalid.', 16, 1);
		RETURN -2;
	END;
	   	 
	DECLARE @jobId uniqueidentifier;
	EXEC [dbo].[create_agent_job]
		@TargetJobName = @HistoryCleanupJobName,
		@JobCategoryName = @JobCategoryName,
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJob,
		@JobID = @jobId OUTPUT;

	-- create a schedule:
	DECLARE @dayMap int;
	SELECT @dayMap = [day_map] FROM @dayNames WHERE UPPER([day_name]) = UPPER(@StartDayOfWeekForCleanupJob);

	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @StartTimeForCleanupJob, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = N'Schedule: ' + @HistoryCleanupJobName;

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_name = @HistoryCleanupJobName,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 8,	
		@freq_interval = @dayMap,
		@freq_subday_type = 1,
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 1, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- Start adding job-steps:
	DECLARE @currentStepName sysname;
	DECLARE @currentCommand nvarchar(MAX);
	DECLARE @currentStepId int = 2;		-- job step ID 1 is the placeholder... 

	-- Remove Job History
	SET @currentStepName = N'Truncate Job History';
	SET @currentCommand = N'DECLARE @cutoff datetime; 
SET @cutoff = DATEADD(DAY, 0 - {daysBack}, GETDATE());

EXEC msdb.dbo.sp_purge_jobhistory  
	@oldest_date = @cutoff; ';

	SET @currentCommand = REPLACE(@currentCommand, N'{daysBack}', @historyDaysBack);

	EXEC msdb..sp_add_jobstep 
		@job_id = @jobId,               
	    @step_id = @currentStepId,		
	    @step_name = @currentStepName,	
	    @subsystem = N'TSQL',			
	    @command = @currentCommand,		
	    @on_success_action = 3,			
	    @on_fail_action = 3, 
	    @database_name = N'msdb',
	    @retry_attempts = 2,
	    @retry_interval = 1;			
	
	SET @currentStepId += 1;


	-- Remove stale Jobs Activity: 
	SET @currentStepName = N'Remove Stale Jobs Activity';
	SET @currentCommand = N'EXEC admindb.dbo.clear_stale_jobsactivity; ';

	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,               
	    @step_id = @currentStepId,		
	    @step_name = @currentStepName,	
	    @subsystem = N'TSQL',			
	    @command = @currentCommand,		
	    @on_success_action = 3,			
	    @on_fail_action = 3, 
	    @database_name = N'admindb',
	    @retry_attempts = 2,
	    @retry_interval = 1;	

	SET @currentStepId += 1;

	-- Remove Backup History:
	SET @currentStepName = N'Truncate Backup History';
	SET @currentCommand = N'DECLARE @cutoff datetime; 
SET @cutoff = DATEADD(DAY, 0 - {daysBack}, GETDATE());

EXEC msdb.dbo.sp_delete_backuphistory  
	@oldest_date = @cutoff; ';

	SET @currentCommand = REPLACE(@currentCommand, N'{daysBack}', @backupDaysBack);

	EXEC msdb..sp_add_jobstep 
		@job_id = @jobId,               
	    @step_id = @currentStepId,		
	    @step_name = @currentStepName,	
	    @subsystem = N'TSQL',			
	    @command = @currentCommand,		
	    @on_success_action = 3,			
	    @on_fail_action = 3, 
	    @database_name = N'msdb',
	    @retry_attempts = 2,
	    @retry_interval = 1;			
	
	SET @currentStepId += 1;
	
	-- Remove Email History:
	IF NULLIF(@EmailHistoryRetention, N'') IS NOT NULL BEGIN 

		SET @currentStepName = N'Truncate Email History';
		SET @currentCommand = N'DECLARE @cutoff datetime; 
SET @cutoff = DATEADD(DAY, 0 - {daysBack}, GETDATE());

EXEC msdb.dbo.sysmail_delete_mailitems_sp  
	@sent_before = @cutoff, 
	@sent_status = ''sent''; ';

		SET @currentCommand = REPLACE(@currentCommand, N'{daysBack}', @emailDaysBack);

		EXEC msdb..sp_add_jobstep 
			@job_id = @jobId,               
			@step_id = @currentStepId,		
			@step_name = @currentStepName,	
			@subsystem = N'TSQL',			
			@command = @currentCommand,		
			@on_success_action = 3,			
			@on_fail_action = 3, 
			@database_name = N'msdb',
			@retry_attempts = 2,
			@retry_interval = 1;			
	
		SET @currentStepId += 1;

	END;

	-- Remove FTCrawlHistory:
--	IF @CycleFTCrawlLogsInDatabases IS NOT NULL BEGIN

--		DECLARE @ftStepNameTemplate sysname = N'{dbName} - Truncate FT Crawl History';
--		SET @currentCommand = N'SET NOCOUNT ON;

--DECLARE @catalog sysname; 
--DECLARE @command nvarchar(300); 
--DECLARE @template nvarchar(200) = N''EXEC sp_fulltext_recycle_crawl_log ''''{0}''''; '';

--DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
--SELECT 
--	[name]
--FROM 
--	sys.[fulltext_catalogs]
--ORDER BY 
--	[name];

--OPEN walker; 
--FETCH NEXT FROM walker INTO @catalog;

--WHILE @@FETCH_STATUS = 0 BEGIN

--	SET @command = REPLACE(@template, N''{0}'', @catalog);

--	--PRINT @command;
--	EXEC sys.[sp_executesql] @command;

--	FETCH NEXT FROM walker INTO @catalog;
--END;

--CLOSE walker;
--DEALLOCATE walker; ';

--		DECLARE @currentDBName sysname;
--		DECLARE @targets table (
--			row_id int IDENTITY(1, 1) NOT NULL,
--			[db_name] sysname NOT NULL
--		);

--		INSERT INTO @targets 
--		EXEC dbo.list_databases 
--			@Targets = @CycleFTCrawlLogsInDatabases, 
--			@ExcludeClones = 1, 
--			@ExcludeSecondaries = 1, 
--			@ExcludeSimpleRecovery = 0, 
--			@ExcludeReadOnly = 1, 
--			@ExcludeRestoring = 1, 
--			@ExcludeRecovering = 1, 
--			@ExcludeOffline = 1;

--		DECLARE [cycler] CURSOR LOCAL FAST_FORWARD FOR 
--		SELECT
--			[db_name]
--		FROM 
--			@targets 
--		ORDER BY 
--			[row_id];

--		OPEN [cycler];
--		FETCH NEXT FROM [cycler] INTO @currentDBName;
		
--		WHILE @@FETCH_STATUS = 0 BEGIN
		
--			SET @currentStepName = REPLACE(@ftStepNameTemplate, N'{dbName}', @currentDBName);

--			EXEC msdb..sp_add_jobstep 
--				@job_id = @jobId,               
--				@step_id = @currentStepId,		
--				@step_name = @currentStepName,	
--				@subsystem = N'TSQL',			
--				@command = @currentCommand,		
--				@on_success_action = 3,			
--				@on_fail_action = 3, 
--				@database_name = @currentDBName,
--				@retry_attempts = 2,
--				@retry_interval = 1;			
	
--			SET @currentStepId += 1;
		
--			FETCH NEXT FROM [cycler] INTO @currentDBName;
--		END;
		
--		CLOSE [cycler];
--		DEALLOCATE [cycler];

--	END;

	-- Cycle Error Logs: 
	SET @currentStepName = N'Cycle Logs';
	SET @currentCommand = N'-- Error Log:
USE master;
GO
EXEC master.sys.sp_cycle_errorlog;
GO

-- SQL Server Agent Error Log:
USE msdb;
GO
EXEC dbo.sp_cycle_agent_errorlog;
GO ';	

	EXEC msdb..sp_add_jobstep 
			@job_id = @jobId,               
			@step_id = @currentStepId,		
			@step_name = @currentStepName,	
			@subsystem = N'TSQL',			
			@command = @currentCommand,		
			@on_success_action = 1,	-- quit reporting success	
			@on_fail_action = 2,	-- quit reporting failure 
			@database_name = N'msdb',
			@retry_attempts = 2,
			@retry_interval = 1;

	RETURN 0;
GO