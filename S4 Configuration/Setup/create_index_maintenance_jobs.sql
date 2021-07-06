/*
	Assumes that Ola Hallengren's IX Maintenance Routines have been deployed to [master] database.

	TODO: 
		- Tweak/Optimize 'streamlined hallengren' deployment script to DROP existing objects and/or account for changes to the commandlog table
			i.e., make it so that it's easy to update/deploy newer versions of hallengren's code. 


	NOTE: 
		- This is effectively an MVP implementation at this point.



	SAMPLE EXECUTION: 

		EXEC [admindb].dbo.[create_index_maintenance_jobs]
			@DailyJobRunsOnDays = N'M,W,F',
			@WeekendJobRunsOnDays = N'Su',
			@OverWriteExistingJobs = 1;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_index_maintenance_jobs','P') IS NOT NULL
	DROP PROC dbo.[create_index_maintenance_jobs];
GO

CREATE PROC dbo.[create_index_maintenance_jobs]
	@DailyJobRunsOnDays							sysname					= N'M,W,F',			-- allow for whatever makes sense - i.e., all... or M,W,F and so on... 
	@WeekendJobRunsOnDays						sysname					= N'Sa, Su',				-- allow for one or both... 
	@IXMaintenanceJobStartTime					sysname					= N'21:50:00',				-- or whatever... (and note that UTC offset here ... could be tricky... 
	@TimeZoneForUtcOffset						sysname					= NULL,						-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@JobsNamePrefix								sysname					= N'Index Maintenance - ',
	@JobsCategoryName							sysname					= N'Database Maintenance',							
	@JobOperatorToAlertOnErrors					sysname					= N'Alerts',	
	@OverWriteExistingJobs						bit						= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	-- Validate Inputs: 
	SET @DailyJobRunsOnDays = ISNULL(NULLIF(@DailyJobRunsOnDays, N''), N'M,W,F');
	SET @WeekendJobRunsOnDays = ISNULL(NULLIF(@WeekendJobRunsOnDays, N''), N'Su');
	
	SET @TimeZoneForUtcOffset = NULLIF(@TimeZoneForUtcOffset, N'');

	DECLARE @days table (
		abbreviation sysname,
		day_name sysname, 
		bit_map int 
	);

	INSERT INTO @days (
		[abbreviation],
		[day_name],
		[bit_map]
	)
	VALUES	
		(N'Su', N'Sunday', 1),
		(N'Sun', N'Sunday', 1),
		(N'M', N'Monday', 2),
		(N'T', N'Tuesday', 4),
		(N'Tu', N'Tuesday', 4),
		(N'W', N'Wednesday', 8),
		(N'Th', N'Thursday', 16),
		(N'Thu', N'Thursday', 16),
		(N'F', N'Friday', 32),
		(N'Sa', N'Saturday', 64),
		(N'Sat', N'Saturday', 64);

	-- TODO: verify that @DailyJobsRunsOnDays and @WeekendJobRunsOnDays are 'in' the approved [abbreviation]s defined in @days.


	IF NULLIF(@IXMaintenanceJobStartTime, N'') IS NULL BEGIN 
		RAISERROR('@IXMaintenanceJobStartTime can NOT be NULL - please specify a start-time - e.g., ''04:20:00''.', 16, 1);
		RETURN -2;
	END;

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

			SET @IXMaintenanceJobStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @IXMaintenanceJobStartTime);
		  END;
		ELSE BEGIN
			RAISERROR('@TimeZoneForUtcOffset is NOT supported on SQL Server versions prior to SQL Server 2016. Set value to NULL.', 16, 1); 
			RETURN -100;
		END;
	END;

	DECLARE @weekDayIxTemplate nvarchar(MAX) = N'EXECUTE [master].dbo.IndexOptimize
	@Databases = ''ALL_DATABASES'',
	@FragmentationLow = NULL,
	@FragmentationMedium = ''INDEX_REORGANIZE'',
	@FragmentationHigh = ''INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE'',
	@FragmentationLevel1 = 40,
	@FragmentationLevel2 = 70, 
	@MSShippedObjects = ''Y'', -- include system objects/etc.
	@LogToTable = ''Y'',
	@UpdateStatistics = ''ALL'';  ';

	DECLARE @weekendIxTemplate nvarchar(MAX) = N'EXECUTE [master].dbo.IndexOptimize
	@Databases = ''ALL_DATABASES'',
	@FragmentationLow = NULL,
	@FragmentationMedium = ''INDEX_REORGANIZE'',
	@FragmentationHigh = ''INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE'',
	@FragmentationLevel1 = 20,
	@FragmentationLevel2 = 40, 
	@MSShippedObjects = ''Y'', -- include system objects/etc.
	@UpdateStatistics = ''ALL'', 
	@LogToTable = ''Y''; ';

	DECLARE @jobId uniqueidentifier; 
	DECLARE @jobName sysname = @JobsNamePrefix + N'WeekDay';
	DECLARE @dateAsInt int;
	DECLARE @startTimeAsInt int; 
	DECLARE @scheduleName sysname;

	DECLARE @weekdayInterval int; 
	DECLARE @weekendInterval int; 

	EXEC dbo.[create_agent_job]
		@TargetJobName = @jobName,
		@JobCategoryName = @JobsCategoryName,
		@JobEnabled = 0,
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobId OUTPUT;

	-- create a schedule:
	SET @dateAsInt = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, CAST(@IXMaintenanceJobStartTime AS datetime), 108), N':', N''), 6)) AS int);
	SET @scheduleName = @jobName + N' Schedule';
	
	SELECT 
		@weekdayInterval = SUM(x.[bit_map])
	FROM 
		@days x 
		INNER JOIN (
			SELECT 
				CAST([result] AS sysname) [abbreviation]
			FROM 
				dbo.[split_string](@DailyJobRunsOnDays, N',', 1)
		) y ON [x].[abbreviation] = [y].[abbreviation];

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 8,  -- weekly
		@freq_interval = @weekdayInterval,  -- every bit-map days... 					
		@freq_subday_type = 1,  -- at specified time... 							
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 1, -- every 1 weeks
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- add a job-step: 
	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 2,		-- place-holder already defined for step 1
		@step_name = N'Weekday Index Maintenance',
		@subsystem = N'TSQL',
		@command = @weekDayIxTemplate,
		@on_success_action = 1,		-- quit reporting success
		@on_fail_action = 2,		-- quit reporting failure 
		@database_name = N'master',
		@retry_attempts = 0,
		@retry_interval = 0;

	-- Reset and create a job for weekend maintenance
	SET @jobId = NULL;

	SET @jobName = @JobsNamePrefix + N'Weekend';

	EXEC dbo.[create_agent_job]
		@TargetJobName = @jobName,
		@JobCategoryName = @JobsCategoryName,
		@JobEnabled = 0,
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobId OUTPUT;

	-- define the schedule:
	SET @scheduleName = @jobName + N' Schedule';

	SELECT 
		@weekendInterval = SUM(x.[bit_map])
	FROM 
		@days x 
		INNER JOIN (
			SELECT 
				CAST([result] AS sysname) [abbreviation]
			FROM 
				dbo.[split_string](@WeekendJobRunsOnDays, N',', 1)
		) y ON [x].[abbreviation] = [y].[abbreviation];

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 8,  -- weekly
		@freq_interval = @weekendInterval,  -- every bit-map days... 					
		@freq_subday_type = 1,  -- at specified time... 							
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 1, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 2,		-- place-holder already defined for step 1
		@step_name = N'Weekend Index Maintenance',
		@subsystem = N'TSQL',
		@command = @weekendIxTemplate,
		@on_success_action = 1,		-- quit reporting success
		@on_fail_action = 2,		-- quit reporting failure 
		@database_name = N'master',
		@retry_attempts = 0,
		@retry_interval = 0;

	RETURN 0;
GO