/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_consistency_checks_job','P') IS NOT NULL
	DROP PROC dbo.[create_consistency_checks_job];
GO

CREATE PROC dbo.[create_consistency_checks_job]
	@ExecutionDays							sysname									= N'M, W, F, Su',
	@JobStartTime							sysname									= N'04:10:00',
	@JobName								sysname									= N'Database Consistency Checks',
	@JobCategoryName						sysname									= N'Database Maintenance',			
	@TimeZoneForUtcOffset					sysname									= NULL,
	@Targets								nvarchar(MAX)	                        = N'{ALL}',		-- {ALL} | {SYSTEM} | {USER} | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions								nvarchar(MAX)	                        = NULL,			-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities								nvarchar(MAX)	                        = NULL,			-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@IncludeExtendedLogicalChecks           bit                                     = 0,
    @OperatorName						    sysname									= N'Alerts',
	@MailProfileName					    sysname									= N'General',
	@EmailSubjectPrefix					    nvarchar(50)							= N'[Database Corruption Checks] ',	
    @OverWriteExistingJobs					bit										= 0

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExecutionDays = ISNULL(NULLIF(@ExecutionDays, N''), N'M, W, F, Su');
	SET @JobName = ISNULL(NULLIF(@JobName, N''), N'Database Consistency Checks');
	SET @JobCategoryName = ISNULL(NULLIF(@JobCategoryName, N''), N'Database Maintenance');
	
	SET @TimeZoneForUtcOffset = NULLIF(@TimeZoneForUtcOffset, N'');

	/*  Dependencies Validation: */ 
    DECLARE @check int;

	EXEC @check = dbo.verify_advanced_capabilities;
    IF @check <> 0
        RETURN @check;

    EXEC @check = dbo.verify_alerting_configuration
        @OperatorName, 
        @MailProfileName;

    IF @check <> 0 
        RETURN @check;

	/* UTC Translation if/as necessary */
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

			SET @JobStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @JobStartTime);

		  END;
		ELSE BEGIN 
			RAISERROR('@TimeZoneForUtcOffset is NOT supported on SQL Server versions prior to SQL Server 2016. Set value to NULL.', 16, 1); 
			RETURN -100;
		END;
	END;

	DECLARE @jobStart time = CAST(@JobStartTime AS time);

	DECLARE @jobTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[check_database_consistency]
	@Targets = N''{Targets}'', 
	@IncludeExtendedLogicalChecks = {extended}{Exclusions}{Priorities}{operator}{profile}{prefix}; ';
	--@Exclusions = N''{Exclusions}'', 
	--@Priorities = N''{Priorities}''; ';

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9); 

	DECLARE @dbccJobStep nvarchar(MAX) = @jobTemplate;

	SET @dbccJobStep = REPLACE(@dbccJobStep, N'{Targets}', @Targets);
	SET @dbccJobStep = REPLACE(@dbccJobStep, N'{extended}', CAST(@IncludeExtendedLogicalChecks AS sysname));

	IF @Exclusions IS NULL 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{Exclusions}', N'');
	ELSE 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{Exclusions}', N',' + @crlf + @tab + N'@Exclusions = N''' + @Exclusions + N'''');

	IF @Priorities IS NULL 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{Priorities}', N'');
	ELSE 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{Priorities}', N',' + @crlf + @tab + N'@Priorities = N''' + @Priorities + N'''');

	IF UPPER(@OperatorName) = N'ALERTS'
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{operator}', N'');
	ELSE 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{operator}', N',' + @crlf + @tab + N'@OperatorName = N''' + @OperatorName + N'''');

	IF UPPER(@MailProfileName) = N'GENERAL'
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{profile}', N'');
	ELSE 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{profile}', N',' + @crlf + @tab + N'@MailProfileName = N''' + @MailProfileName + N'''');

	IF @EmailSubjectPrefix = N'[Database Corruption Checks] '
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{prefix}', N'');
	ELSE 
		SET @dbccJobStep = REPLACE(@dbccJobStep, N'{prefix}', N',' + @crlf + @tab + N'@EmailSubjectPrefix = N''' + @EmailSubjectPrefix + N'''');

	/* Scheduling Logic */
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

	DECLARE @daysOfWeek int;

	SELECT 
		@daysOfWeek = SUM(x.[bit_map])
	FROM 
		@days x 
		INNER JOIN (
			SELECT 
				CAST([result] AS sysname) [abbreviation]
			FROM 
				dbo.[split_string](@ExecutionDays, N',', 1)
		) y ON [x].[abbreviation] = [y].[abbreviation];


	/* Job Creation */
	DECLARE @jobId uniqueidentifier; 
	DECLARE @dateAsInt int;
	DECLARE @startTimeAsInt int; 
	DECLARE @scheduleName sysname;

	EXEC dbo.[create_agent_job]
		@TargetJobName = @JobName,
		@JobCategoryName = @JobCategoryName,
		@JobEnabled = 0,
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrors = @OperatorName,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobId OUTPUT;

	SET @dateAsInt = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, CAST(@JobStartTime AS datetime), 108), N':', N''), 6)) AS int);
	SET @scheduleName = @JobName + N' Schedule';

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 8,  -- weekly
		@freq_interval = @daysOfWeek,  -- every bit-map days... 					
		@freq_subday_type = 1,  -- at specified time... 							
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 1, -- every 1 weeks
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 2,		-- place-holder already defined for step 1
		@step_name = N'Check Database Consistency',
		@subsystem = N'TSQL',
		@command = @dbccJobStep,
		@on_success_action = 1,		-- quit reporting success
		@on_fail_action = 2,		-- quit reporting failure 
		@database_name = N'master',
		@retry_attempts = 0,
		@retry_interval = 0;

	RETURN 0;
GO