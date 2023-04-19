/*
		
	vNEXT:
		- Refactor @FullAndLog* ... no longer makes sense it's @UserDB*... 
		- OffSite Path + retentions


		
	
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_backup_jobs','P') IS NOT NULL
	DROP PROC dbo.[create_backup_jobs];
GO

CREATE PROC dbo.[create_backup_jobs]
	@UserDBTargets								sysname					= N'{USER}',
	@UserDBExclusions							sysname					= N'',
	@EncryptionCertName							sysname					= NULL,
	@BackupsDirectory							sysname					= N'{DEFAULT}', 
	@CopyToBackupDirectory						sysname					= N'',
	--@OffSiteBackupPath						sysname					= NULL, 
	@SystemBackupRetention						sysname					= N'4 days', 
	@CopyToSystemBackupRetention				sysname					= N'4 days', 
	@UserFullBackupRetention					sysname					= N'3 days', 
	@CopyToUserFullBackupRetention				sysname					= N'3 days',
	@LogBackupRetention							sysname					= N'73 hours', 
	@CopyToLogBackupRetention					sysname					= N'73 hours',
	@AllowForSecondaryServers					bit						= 0,							-- Set to 1 for Mirrored/AG'd databases. 
	@FullSystemBackupsStartTime					sysname					= N'18:50:00',					-- if '', then system backups won't be created... 
	@FullUserBackupsStartTime					sysname					= N'02:00:00',					
	@DiffBackupsStartTime						sysname					= NULL, 
	@DiffBackupsRunEvery						sysname					= NULL,							-- minutes or hours ... e.g., N'4 hours' or '180 minutes', etc. 
	@LogBackupsStartTime						sysname					= N'00:02:00',					-- ditto ish
	@LogBackupsRunEvery							sysname					= N'10 minutes',				-- vector, but only allows minutes (i think).
	@TimeZoneForUtcOffset									sysname					= NULL,							-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@JobsNamePrefix								sysname					= N'Database Backups - ',		-- e.g., "Database Backups - USER - FULL" or "Database Backups - USER - LOG" or "Database Backups - SYSTEM - FULL"
	@JobsCategoryName							sysname					= N'Backups',							
	@JobOperatorToAlertOnErrors					sysname					= N'Alerts',	
	@ProfileToUseForAlerts						sysname					= N'General',
	@OverWriteExistingJobs						bit						= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
    DECLARE @check int;

	EXEC @check = dbo.verify_advanced_capabilities;
    IF @check <> 0
        RETURN @check;

    EXEC @check = dbo.verify_alerting_configuration
        @JobOperatorToAlertOnErrors, 
        @ProfileToUseForAlerts;

    IF @check <> 0 
        RETURN @check;

	-- TODO: validate inputs: 
	SET @EncryptionCertName = NULLIF(@EncryptionCertName, N'');
	SET @DiffBackupsStartTime = NULLIF(@DiffBackupsStartTime, N'');
	SET @TimeZoneForUtcOffset = NULLIF(@TimeZoneForUtcOffset, N'');

	IF NULLIF(@DiffBackupsStartTime, N'') IS NOT NULL AND @DiffBackupsRunEvery IS NULL BEGIN 
		RAISERROR('@DiffBackupsRunEvery must be set/specified when a @DiffBackupsStartTime is specified.', 16, 1);
		RETURN -2;
	END;

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		IF (SELECT [dbo].[get_engine_version]()) >= 13.0 BEGIN 
			IF NOT EXISTS (SELECT NULL FROM sys.[time_zone_info] WHERE [name] = @TimeZoneForUtcOffset) BEGIN
				RAISERROR(N'Invalid Time-Zone Specified: %s.', 16, 1, @TimeZoneForUtcOffset);
				RETURN -10;
			END;

			DECLARE @utc datetime = GETUTCDATE();
			DECLARE @atTimeZone datetime;
			
			DECLARE @offsetSQL nvarchar(MAX) = N'SELECT @atTimeZone = @utc AT TIME ZONE ''UTC'' AT TIME ZONE @TimeZoneForUtcOffset; ';
			
			EXEC sys.[sp_executesql]
				@offsetSQL, 
				N'@atTimeZone datetime OUTPUT, @utc datetime, @TimeZoneForUtcOffset sysname', 
				@atTimeZone = @atTimeZone OUTPUT, 
				@utc = @utc, 
				@TimeZoneForUtcOffset = @TimeZoneForUtcOffset;

		  END;
		ELSE BEGIN 
			-- TODO: I might be able to pull this info out of the registry? https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-time-zone-info-transact-sql?view=sql-server-ver16  

			RAISERROR('@TimeZoneForUtcOffset is NOT supported on SQL Server versions prior to SQL Server 2016. Set value to NULL.', 16, 1); 
			RETURN -100;
		END;

		SET @FullSystemBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @FullSystemBackupsStartTime);
		SET @FullUserBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @FullUserBackupsStartTime);
		SET @LogBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @LogBackupsStartTime);
		SET @DiffBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @DiffBackupsStartTime);
	END;

	DECLARE @systemStart time, @userStart time, @logStart time, @diffStart time;
	SELECT 
		@systemStart	= CAST(@FullSystemBackupsStartTime AS time), 
		@userStart		= CAST(@FullUserBackupsStartTime AS time), 
		@logStart		= CAST(@LogBackupsStartTime AS time), 
		@diffStart		= CAST(@DiffBackupsStartTime AS time);

	DECLARE @logFrequencyMinutes int;
	DECLARE @diffFrequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @LogBackupsRunEvery,
		@ValidationParameterName = N'@LogBackupsRunEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @logFrequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	IF @diffStart IS NOT NULL BEGIN 

		EXEC @outcome = dbo.[translate_vector]
			@Vector = @DiffBackupsRunEvery,
			@ValidationParameterName = N'@DiffBackupsRunEvery',
			@ProhibitedIntervals = N'MILLISECOND,SECOND,DAY,WEEK,MONTH,YEAR',
			@TranslationDatePart = 'MINUTE',
			@Output = @diffFrequencyMinutes OUTPUT,
			@Error = @error OUTPUT;

		IF @outcome <> 0 BEGIN 
			RAISERROR(@error, 16, 1); 
			RETURN @outcome;
		END;

		IF @diffFrequencyMinutes > 90 BEGIN
			DECLARE @remainder int = (SELECT @diffFrequencyMinutes % 60);
			IF @remainder <> 0 BEGIN 
				RAISERROR(N'@DiffBackupsRunEvery can only be specified in minutes up to a max of 90 minutes - otherwise, they must be specified in hours (e.g., 2 hours, 4 hours, or 28 minutes are all valid inputs).', 16, 1);
				RETURN - 100;
			END;

			IF @diffFrequencyMinutes > 1200 BEGIN 
				RAISERROR(N'@DiffBackupsRunEvery can not be > 1200 minutes.', 16, 1);
				RETURN -101;
			END;
		END;
	END;

	DECLARE @backupsTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[backup_databases]
	@BackupType = N''{backupType}'',
	@DatabasesToBackup = N''{targets}'',
	@DatabasesToExclude = N''{exclusions}'',
	@BackupDirectory = N''{backupsDirectory}'',{copyToDirectory}
	@BackupRetention = N''{retention}'',{copyToRetention}{encryption}
	@LogSuccessfulOutcomes = 1,{secondaries}{operator}{profile}
	@PrintOnly = 0;';

	DECLARE @sysBackups nvarchar(MAX), @userBackups nvarchar(MAX), @diffBackups nvarchar(MAX), @logBackups nvarchar(MAX);
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

	-- 'global' template config settings/options: 
	SET @backupsTemplate = REPLACE(@backupsTemplate, N'{backupsDirectory}', @BackupsDirectory);
	
	IF NULLIF(@EncryptionCertName, N'') IS NULL 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{encryption}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{encryption}', @crlfTab + N'@EncryptionCertName = N''' + @EncryptionCertName + N''',' + @crlfTab + N'@EncryptionAlgorithm = N''AES_256'',');

	IF NULLIF(@CopyToBackupDirectory, N'') IS NULL BEGIN
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToDirectory}', N'');
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToRetention}', N'');
	  END;
	ELSE BEGIN
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToDirectory}', @crlfTab + N'@CopyToBackupDirectory = N''' + @CopyToBackupDirectory + N''', ');
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToRetention}', @crlfTab + N'@CopyToRetention = N''{copyRetention}'', ');
	END;

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{operator}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{profile}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-- system backups: 
	SET @sysBackups = REPLACE(@backupsTemplate, N'{exclusions}', N'');

	IF @AllowForSecondaryServers = 0 
		SET @sysBackups = REPLACE(@sysBackups, N'{secondaries}', N'');
	ELSE 
		SET @sysBackups = REPLACE(@sysBackups, N'{secondaries}', @crlfTab + N'@AddServerNameToSystemBackupPath = 1, ');

	SET @sysBackups = REPLACE(@sysBackups, N'{backupType}', N'FULL');
	SET @sysBackups = REPLACE(@sysBackups, N'{targets}', N'{SYSTEM}');
	SET @sysBackups = REPLACE(@sysBackups, N'{retention}', @SystemBackupRetention);
	SET @sysBackups = REPLACE(@sysBackups, N'{copyRetention}', ISNULL(@CopyToSystemBackupRetention, N''));

	-- Make sure to exclude _s4test dbs from USER backups: 
	IF NULLIF(@UserDBExclusions, N'') IS NULL 
		SET @UserDBExclusions = N'%s4test';
	ELSE BEGIN 
		IF @UserDBExclusions NOT LIKE N'%s4test%'
			SET @UserDBExclusions = @UserDBExclusions + N', %s4test';
	END;

	SET @backupsTemplate = REPLACE(@backupsTemplate, N'{exclusions}', @UserDBExclusions);

	-- MKC: this code is terrible (i.e., the copy/paste/tweak of 3x roughly similar calls - for full, diff, log - but with slightly diff parameters.
	-- full user backups: 
	SET @userBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @userBackups = REPLACE(@userBackups, N'{secondaries}', N'');
	ELSE 
		SET @userBackups = REPLACE(@userBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @userBackups = REPLACE(@userBackups, N'{backupType}', N'FULL');
	SET @userBackups = REPLACE(@userBackups, N'{targets}', @UserDBTargets);
	SET @userBackups = REPLACE(@userBackups, N'{retention}', @UserFullBackupRetention);
	SET @userBackups = REPLACE(@userBackups, N'{copyRetention}', ISNULL(@CopyToUserFullBackupRetention, N''));
	SET @userBackups = REPLACE(@userBackups, N'{exclusions}', @UserDBExclusions);

	-- diff user backups: 
	SET @diffBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @diffBackups = REPLACE(@diffBackups, N'{secondaries}', N'');
	ELSE 
		SET @diffBackups = REPLACE(@diffBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @diffBackups = REPLACE(@diffBackups, N'{backupType}', N'DIFF');
	SET @diffBackups = REPLACE(@diffBackups, N'{targets}', @UserDBTargets);
	SET @diffBackups = REPLACE(@diffBackups, N'{retention}', @UserFullBackupRetention);
	SET @diffBackups = REPLACE(@diffBackups, N'{copyRetention}', ISNULL(@CopyToUserFullBackupRetention, N''));
	SET @diffBackups = REPLACE(@diffBackups, N'{exclusions}', @UserDBExclusions);

	-- log backups: 
	SET @logBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @logBackups = REPLACE(@logBackups, N'{secondaries}', N'');
	ELSE 
		SET @logBackups = REPLACE(@logBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @logBackups = REPLACE(@logBackups, N'{backupType}', N'LOG');
	SET @logBackups = REPLACE(@logBackups, N'{targets}', @UserDBTargets);
	SET @logBackups = REPLACE(@logBackups, N'{retention}', @LogBackupRetention);
	SET @logBackups = REPLACE(@logBackups, N'{copyRetention}', ISNULL(@CopyToLogBackupRetention, N''));
	SET @logBackups = REPLACE(@logBackups, N'{exclusions}', @UserDBExclusions);

	DECLARE @jobs table (
		job_id int IDENTITY(1,1) NOT NULL, 
		job_name sysname NOT NULL, 
		job_step_name sysname NOT NULL, 
		job_body nvarchar(MAX) NOT NULL,
		job_start_time time NULL
	);

	INSERT INTO @jobs (
		[job_name],
		[job_step_name],
		[job_body],
		[job_start_time]
	)
	VALUES	
	(
		N'SYSTEM - Full', 
		N'FULL Backup of SYSTEM Databases', 
		@sysBackups, 
		@systemStart
	), 
	(
		N'USER - Full', 
		N'FULL Backup of USER Databases', 
		@userBackups, 
		@userStart
	), 
	(
		N'USER - Diff', 
		N'DIFF Backup of USER Databases', 
		@diffBackups, 
		@diffStart
	), 
	(
		N'USER - Log', 
		N'TLOG Backup of USER Databases', 
		@logBackups, 
		@logStart
	);
	
	DECLARE @currentJobSuffix sysname, @currentJobStep sysname, @currentJobStepBody nvarchar(MAX), @currentJobStart time;

	DECLARE @currentJobName sysname;
	DECLARE @existingJob sysname; 
	DECLARE @jobID uniqueidentifier;

	DECLARE @dateAsInt int;
	DECLARE @startTimeAsInt int; 
	DECLARE @scheduleName sysname;

	DECLARE @schedSubdayType int; 
	DECLARE @schedSubdayInteval int; 
	
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[job_name],
		[job_step_name],
		[job_body],
		[job_start_time]
	FROM 
		@jobs
	WHERE 
		[job_start_time] IS NOT NULL -- don't create jobs for 'tasks' without start times.
	ORDER BY 
		[job_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentJobSuffix, @currentJobStep, @currentJobStepBody, @currentJobStart;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @currentJobName =  @JobsNamePrefix + @currentJobSuffix;

		SET @jobID = NULL;
		EXEC [admindb].[dbo].[create_agent_job]
			@TargetJobName = @currentJobName,
			@JobCategoryName = @JobsCategoryName,
			@JobEnabled = 0, -- create backup jobs as disabled (i.e., require admin review + manual intervention to enable... 
			@AddBlankInitialJobStep = 1,
			@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
			@OverWriteExistingJobDetails = @OverWriteExistingJobs,
			@JobID = @jobID OUTPUT;
		
		-- create a schedule:
		SET @dateAsInt = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
		SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, @currentJobStart, 108), N':', N''), 6)) AS int);
		SET @scheduleName = @currentJobName + N' Schedule';

		IF (@currentJobName LIKE '%Log%') OR (@currentJobName LIKE '%Diff%') BEGIN 
			IF (@currentJobName LIKE '%Log%') BEGIN
				SET @schedSubdayType = 4; -- every N minutes
				SET @schedSubdayInteval = @logFrequencyMinutes;
			
			  END;
			 ELSE BEGIN
				IF @diffFrequencyMinutes > 90 BEGIN
					SET @schedSubdayType = 8; -- every N hours
					SET @schedSubdayInteval = @diffFrequencyMinutes / 60;
				  END;
				ELSE BEGIN 
					SET @schedSubdayType = 4;
					SET @schedSubdayInteval = @diffFrequencyMinutes;
				END;
			END;
		  END; 
		ELSE BEGIN 
			SET @schedSubdayType = 1; -- at the specified (start) time. 
			SET @schedSubdayInteval = 0
		END;

		EXEC msdb.dbo.sp_add_jobschedule 
			@job_id = @jobID,
			@name = @scheduleName,
			@enabled = 1, 
			@freq_type = 4,  -- daily										
			@freq_interval = 1,  -- every 1 days... 								
			@freq_subday_type = @schedSubdayType,							
			@freq_subday_interval = @schedSubdayInteval, 
			@freq_relative_interval = 0, 
			@freq_recurrence_factor = 0, 
			@active_start_date = @dateAsInt, 
			@active_start_time = @startTimeAsInt;

		-- now add the job step:
		EXEC msdb..sp_add_jobstep
			@job_id = @jobID,
			@step_id = 2,		-- place-holder already defined for step 1
			@step_name = @currentJobStep,
			@subsystem = N'TSQL',
			@command = @currentJobStepBody,
			@on_success_action = 1,		-- quit reporting success
			@on_fail_action = 2,		-- quit reporting failure 
			@database_name = N'admindb',
			@retry_attempts = 0,
			@retry_interval = 0;
	
	FETCH NEXT FROM [walker] INTO @currentJobSuffix, @currentJobStep, @currentJobStepBody, @currentJobStart;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];
	
	RETURN 0;
GO