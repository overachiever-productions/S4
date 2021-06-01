/*
	Simple scheduling wrapper around most common/typical restore-test needs. 


	<#

		## DESCRIPTION


		## COVERAGE... 


		## PARAMETERS 
			<something dynamic - from sys.columns that pulls details... and then... the option to let me specify explicit deails on a '1 off' basis for specific params... eg.. @AllowReplace

		## REMARKS 



		## SEE ALSO

	#>
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_restore_test_job','P') IS NOT NULL
	DROP PROC dbo.[create_restore_test_job];
GO

CREATE PROC dbo.[create_restore_test_job]
    @JobName						sysname				= N'Database Backups - Regular Restore Tests',
	@RestoreTestStartTime			time				= N'22:30:00',
	@TimeZoneForUtcOffset			sysname				= NULL,				-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@JobCategoryName				sysname				= N'Backups',
	@AllowForSecondaries			bit					= 0,									-- IF AG/Mirrored environment (secondaries), then wrap restore-test in IF is_primary_server check... 
    @DatabasesToRestore				nvarchar(MAX)		= N'{READ_FROM_FILESYSTEM}', 
    @DatabasesToExclude				nvarchar(MAX)		= N'',									-- TODO: document specialized logic here... 
    @Priorities						nvarchar(MAX)		= NULL,
    @BackupsRootPath				nvarchar(MAX)		= N'{DEFAULT}',
    @RestoredRootDataPath			nvarchar(MAX)		= N'{DEFAULT}',
    @RestoredRootLogPath			nvarchar(MAX)		= N'{DEFAULT}',
    @RestoredDbNamePattern			nvarchar(40)		= N'{0}_s4test',
    @AllowReplace					nchar(7)			= NULL,									-- NULL or the exact term: N'REPLACE'...
	@RpoWarningThreshold			nvarchar(10)		= N'24 hours',							-- Only evaluated if non-NULL. 
    @DropDatabasesAfterRestore		bit					= 1,									-- Only works if set to 1, and if we've RESTORED the db in question. 
    @MaxNumberOfFailedDrops			int					= 1,									-- number of failed DROP operations we'll tolerate before early termination.
	@OperatorName					sysname				= N'Alerts',
    @MailProfileName				sysname				= N'General',
    @EmailSubjectPrefix				nvarchar(50)		= N'[RESTORE TEST] ',
	@OverWriteExistingJob			bit					= 0
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

			SET @RestoreTestStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @RestoreTestStartTime);
		  END;
		ELSE BEGIN 
			RAISERROR('@TimeZoneForUtcOffset is NOT supported on SQL Server versions prior to SQL Server 2016. Set value to NULL.', 16, 1); 
			RETURN -100;
		END;
	END;

	DECLARE @restoreStart time;
	SELECT 
		@restoreStart	= CAST(@RestoreTestStartTime AS time);

	-- Typical Use-Case/Pattern: 
	IF UPPER(@AllowReplace) <> N'REPLACE' AND @DropDatabasesAfterRestore IS NULL 
		SET @DropDatabasesAfterRestore = 1;

	-- Define the Job Step: 
	DECLARE @restoreTemplate nvarchar(MAX) = N'EXEC admindb.dbo.restore_databases  
	@DatabasesToRestore = N''{targets}'',{exclusions}{priorities}
	@BackupsRootPath = N''{backupsPath}'',
	@RestoredRootDataPath = N''{dataPath}'',
	@RestoredRootLogPath = N''{logPath}'',
	@RestoredDbNamePattern = N''{restorePattern}'',{replace}{rpo}{operator}{profile}
	@DropDatabasesAfterRestore = {drop},
	@PrintOnly = 0; ';

	IF @AllowForSecondaries = 1 BEGIN 
		SET @restoreTemplate = N'IF (SELECT admindb.dbo.is_primary_server()) = 1 BEGIN
	EXEC admindb.dbo.restore_databases  
		@DatabasesToRestore = N''{targets}'',{exclusions}{priorities}
		@BackupsRootPath = N''{backupsPath}'',
		@RestoredRootDataPath = N''{dataPath}'',
		@RestoredRootLogPath = N''{logPath}'',
		@RestoredDbNamePattern = N''{restorePattern}'',{replace}{rpo}{operator}{profile}
		@DropDatabasesAfterRestore = {drop},
		@PrintOnly = 0; 
END;'

	END;

	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @jobStepBody nvarchar(MAX) = @restoreTemplate;

	-- TODO: document the 'special case' of SYSTEM as exclusions... 
	IF @DatabasesToRestore IN (N'{READ_FROM_FILESYSTEM}', N'{ALL}') BEGIN 
		IF NULLIF(@DatabasesToExclude, N'') IS NULL 
			SET @DatabasesToExclude = N'{SYSTEM}'
		ELSE BEGIN
			IF @DatabasesToExclude NOT LIKE N'%{SYSTEM}%' BEGIN
				SET @DatabasesToExclude = N'{SYSTEM},' + @DatabasesToExclude;
			END;
		END;
	END;

	IF NULLIF(@DatabasesToExclude, N'') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{exclusions}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{exclusions}', @crlfTab + N'@DatabasesToExclude = ''' + @DatabasesToExclude + N''', ');

	IF NULLIF(@OperatorName, N'Alerts') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{operator}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{operator}', @crlfTab + N'@OperatorName = ''' + @OperatorName + N''', ');

	IF NULLIF(@MailProfileName, N'General') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{profile}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{profile}', @crlfTab + N'@MailProfileName = ''' + @MailProfileName + N''', ');

	IF NULLIF(@Priorities, N'') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{priorities}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{priorities}', @crlfTab + N'@Priorities = N''' + @Priorities + N''', ');

	IF NULLIF(@AllowReplace, N'') IS NULL
		SET @jobStepBody = REPLACE(@jobStepBody, N'{replace}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{replace}', @crlfTab + N'@AllowReplace = N''' + @AllowReplace + N''', ');

	IF NULLIF(@RpoWarningThreshold, N'') IS NULL
		SET @jobStepBody = REPLACE(@jobStepBody, N'{rpo}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{rpo}', @crlfTab + N'@RpoWarningThreshold = N''' + @RpoWarningThreshold + N''', ');

	SET @jobStepBody = REPLACE(@jobStepBody, N'{targets}', @DatabasesToRestore);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{backupsPath}', @BackupsRootPath);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{dataPath}', @RestoredRootDataPath);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{logPath}', @RestoredRootLogPath);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{restorePattern}', @RestoredDbNamePattern);

	SET @jobStepBody = REPLACE(@jobStepBody, N'{drop}', CAST(@DropDatabasesAfterRestore AS sysname));

	DECLARE @jobId uniqueidentifier = NULL;
	EXEC [dbo].[create_agent_job]
		@TargetJobName = @JobName,
		@JobCategoryName = @JobCategoryName,
		@JobEnabled = 0, -- create restore-test job as disabled (i.e., require admin review + manual intervention to enable... 
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrorss = @OperatorName,
		@OverWriteExistingJobDetails = @OverWriteExistingJob,
		@JobID = @jobId OUTPUT;
	
	-- create a schedule:
	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @restoreStart, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = @JobName + ' Schedule';

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 4,		-- daily								
		@freq_interval = 1, -- every 1 days							
		@freq_subday_type = 1,	-- at the scheduled time... 					
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- and add the job step: 
	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 2,		-- place-holder defined as job-step 1.
		@step_name = N'Restore Tests',
		@subsystem = N'TSQL',
		@command = @jobStepBody,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 0,
		@retry_interval = 0;
	
	RETURN 0;
GO