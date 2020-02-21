/*

	


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.enable_disk_monitoring','P') IS NOT NULL
	DROP PROC dbo.[enable_disk_monitoring];
GO

CREATE PROC dbo.[enable_disk_monitoring]
	@WarnWhenFreeGBsGoBelow				decimal(12,1)		= 22.0,				
	@HalveThresholdAgainstCDrive		bit					= 0,	
	@DriveCheckJobName					sysname				= N'Regular Drive Space Checks',
	@JobCategoryName					sysname				= N'Monitoring',
	@JobOperatorToAlertOnErrors			sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[DriveSpace Checks] ',
	@CheckFrequencyInterval				sysname				= N'20 minutes', 
	
	@OverWriteExistingJob				bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	-- TODO: validate inputs... 
	
	DECLARE @dailyJobStartTime	time = '00:03';

	-- translate/validate job start/frequency:
	DECLARE @frequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @CheckFrequencyInterval,
		@ValidationParameterName = N'@CheckFrequency',
		@ProhibitedIntervals = N'MILLISECOND,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	DECLARE @scheduleFrequencyType int = 4;  -- daily (in all scenarios below)
	DECLARE @schedFrequencyInterval int;   
	DECLARE @schedSubdayType int; 
	DECLARE @schedSubdayInteval int; 
	DECLARE @translationSet bit = 0;  -- bit of a hack at this point... 

	IF @frequencyMinutes <= 0 BEGIN
		RAISERROR('Invalid value for @CheckFrequencyInterval. Intervals must be > 1 minute and <= 24 hours.', 16, 1);
		RETURN -5;
	END;

	IF @CheckFrequencyInterval LIKE '%day%' BEGIN 
		IF @frequencyMinutes > (60 * 24 * 7) BEGIN 
			RAISERROR('@CheckFrequencyInterval may not be set for > 7 days. Hours/Minutes and < 7 days are allowable options.', 16, 1);
			RETURN -20;
		END;

		SET @schedFrequencyInterval = @frequencyMinutes / (60 * 24);
		SET @schedSubdayType = 1; -- at the time specified... 
		SET @schedSubdayInteval = 0;   -- ignored... 

		SET @translationSet = 1;
	END;

	IF @CheckFrequencyInterval LIKE '%hour%' BEGIN
		IF @frequencyMinutes > (60 * 24) BEGIN 
			RAISERROR('Please specify ''day[s]'' for @CheckFrequencyInterval when setting values for > 1 day.', 16, 1);
			RETURN -21;
		END;

		SET @schedFrequencyInterval = 1;
		SET @schedSubdayType = 8;  -- hours
		SET @schedSubdayInteval = @frequencyMinutes / 60;
		SET @translationSet = 1; 
	END;
	
	IF @CheckFrequencyInterval LIKE '%minute%' BEGIN
		IF @frequencyMinutes > (60 * 24) BEGIN 
			RAISERROR('Please specify ''day[s]'' for @CheckFrequencyInterval when setting values for > 1 day.', 16, 1);
			RETURN -21;
		END;		

		SET @schedFrequencyInterval = 1;
		SET @schedSubdayType = 4;  -- minutes
		SET @schedSubdayInteval = @frequencyMinutes;
		SET @translationSet = 1;
	END;

--SELECT @scheduleFrequencyType [FreqType], @schedFrequencyInterval [FrequencyInterval], @schedSubdayType [subdayType], @schedSubdayInteval [subDayInterval];
--RETURN 0;

	IF @translationSet = 0 BEGIN
		RAISERROR('Invalid timespan value specified for @CheckFrequencyInterval. Allowable values are Minutes, Hours, and (less than) 7 days.', 16, 1);
		RETURN -30;
	END;

	DECLARE @jobId uniqueidentifier;
	EXEC dbo.[create_agent_job]
		@TargetJobName = @DriveCheckJobName,
		@JobCategoryName = @JobCategoryName,
		@AddBlankInitialJobStep = 0,	-- this isn't usually a long-running job - so it doesn't need this... 
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJob,
		@JobID = @jobId OUTPUT;
	
	-- create a schedule:
	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @dailyJobStartTime, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = N'Schedule: ' + @DriveCheckJobName;

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = @scheduleFrequencyType,										
		@freq_interval = @schedFrequencyInterval,								
		@freq_subday_type = @schedSubdayType,							
		@freq_subday_interval = @schedSubdayInteval, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- Define Job Step for execution of checkup logic: 
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @stepBody nvarchar(MAX) = N'EXEC admindb.dbo.verify_drivespace 
	@WarnWhenFreeGBsGoBelow = {freeGBs}{halveForC}{Operator}{Profile}{Prefix};';
	
	SET @stepBody = REPLACE(@stepBody, N'{freeGBs}', CAST(@WarnWhenFreeGBsGoBelow AS sysname));

	--TODO: need a better way of handling/processing addition of non-defaults... 
	IF @HalveThresholdAgainstCDrive = 1
		SET @stepBody = REPLACE(@stepBody, N'{halveForC}', @crlfTab + N',@HalveThresholdAgainstCDrive = 1')
	ELSE 
		SET @stepBody = REPLACE(@stepBody, N'{halveForC}', N'');

	IF UPPER(@JobOperatorToAlertOnErrors) <> N'ALERTS' 
		SET @stepBody = REPLACE(@stepBody, N'{Operator}', @crlfTab + N',@OperatorName = ''' + @JobOperatorToAlertOnErrors + N'''');
	ELSE 
		SET @stepBody = REPLACE(@stepBody, N'{Operator}', N'');

	IF UPPER(@MailProfileName) <> N'GENERAL'
		SET @stepBody = REPLACE(@stepBody, N'{Profile}', @crlfTab + N',@MailProfileName = ''' + @MailProfileName + N'''');
	ELSE 
		SET @stepBody = REPLACE(@stepBody, N'{Profile}', N'');

	IF UPPER(@EmailSubjectPrefix) <> N'[DRIVESPACE CHECKS] '
		SET @stepBody = REPLACE(@stepBody, N'{Prefix}', @crlfTab + N',@EmailSubjectPrefix = ''' + @EmailSubjectPrefix + N'''');
	ELSE
		SET @stepBody = REPLACE(@stepBody, N'{Prefix}', N'');

	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 1,
		@step_name = N'Check on Disk Space and Send Alerts',
		@subsystem = N'TSQL',
		@command = @stepBody,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 1,
		@retry_interval = 1;
	
	RETURN 0;
GO