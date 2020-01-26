/*

	vNEXT: Implement params-list/output on @Action = N'TEST' - as down in the body of the sproc


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_sync_check_jobs','P') IS NOT NULL
	DROP PROC dbo.[create_sync_check_jobs];
GO

CREATE PROC dbo.[create_sync_check_jobs]
	@Action											sysname				= N'TEST',				-- 'TEST | CREATE' are the 2x options - i.e., test/output what we'd see... or ... create the jobs. 	
	@ServerAndJobsSyncCheckJobStart					sysname				= N'00:01:00', 
	@DataSyncCheckJobStart							sysname				= N'00:03:00', 
	@ServerAndJobsSyncCheckJobRunsEvery				sysname				= N'30 minutes', 
	@DataSyncCheckJobRunsEvery						sysname				= N'20 minutes',
	@IgnoreSynchronizedDatabaseOwnership			bit		            = 0,					
	@IgnoredMasterDbObjects							nvarchar(MAX)       = NULL,
	@IgnoredLogins									nvarchar(MAX)       = NULL,
	@IgnoredAlerts									nvarchar(MAX)       = NULL,
	@IgnoredLinkedServers							nvarchar(MAX)       = NULL,
    @IgnorePrincipalNames							bit                 = 1,  
	@IgnoredJobs									nvarchar(MAX)		= NULL,
	@IgnoredDatabases								nvarchar(MAX)		= NULL,
	@RPOThreshold									sysname				= N'10 seconds',
	@RTOThreshold									sysname				= N'40 seconds',
	@AGSyncCheckIterationCount						int					= 8, 
	@AGSyncCheckDelayBetweenChecks					sysname				= N'1800 milliseconds',
	@ExcludeAnomolousSyncDeviations					bit					= 0,    -- Primarily for Ghosted Records Cleanup... 	
	@JobsNamePrefix									sysname				= N'Sync-Check.',		
	@JobsCategoryName								sysname				= N'SynchronizationChecks',							
	@JobOperatorToAlertOnErrors						sysname				= N'Alerts',	
	@ProfileToUseForAlerts							sysname				= N'General',
	@OverWriteExistingJobs							bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@Action, N'') IS NULL SET @Action = N'TEST';

	IF UPPER(@Action) NOT IN (N'TEST', N'CREATE') BEGIN 
		RAISERROR('Invalid option specified for parameter @Action. Valid options are ''TEST'' (test/show sync-check outputs without creating a job) and ''CREATE'' (create sync-check jobs).', 16, 1);
		RETURN -1;
	END;

	-- vNEXT: MAYBE look at extending the types of intervals allowed?
	-- Verify minutes-only sync-check intervals. 
	IF @ServerAndJobsSyncCheckJobRunsEvery IS NULL BEGIN 
		RAISERROR('Parameter @ServerAndJobsSyncCheckJobRunsEvery cannot be left empty - and specifies how frequently (in minutes) the server/job sync-check job runs - e.g., N''20 minutes''.', 16, 1);
		RETURN -2;
	  END
	ELSE BEGIN
		IF @ServerAndJobsSyncCheckJobRunsEvery NOT LIKE '%minute%' BEGIN 
			RAISERROR('@ServerAndJobsSyncCheckJobRunsEvery can only specify values defined in minutes - e.g., N''5 minutes'', or N''10 minutes'', etc.', 16, 1);
			RETURN -3;
		END;
	END;

	IF @DataSyncCheckJobRunsEvery IS NULL BEGIN 
		RAISERROR('Parameter @DataSyncCheckJobRunsEvery cannot be left empty - and specifies how frequently (in minutes) the data sync-check job runs - e.g., N''20 minutes''.', 16, 1);
		RETURN -4;
	  END
	ELSE BEGIN
		IF @DataSyncCheckJobRunsEvery NOT LIKE '%minute%' BEGIN 
			RAISERROR('@DataSyncCheckJobRunsEvery can only specify values defined in minutes - e.g., N''5 minutes'', or N''10 minutes'', etc.', 16, 1);
			RETURN -5;
		END;
	END;


--vNEXT:
	--IF UPPER(@Action) = N'TEST' BEGIN
	--	PRINT 'TODO: Output all parameters - to make config easier... ';
	--	-- SEE https://overachieverllc.atlassian.net/browse/S4-304 for more details. Otherwise, effecively: SELECT [name] FROM sys.parameters WHERE object_id = @@PROCID;
	--END;
	
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

	DECLARE @serverSyncTemplate nvarchar(MAX) = N'EXEC dbo.[verify_server_synchronization]
	@IgnoreSynchronizedDatabaseOwnership = {ingoreOwnership},
	@IgnoredMasterDbObjects = {ignoredMasterObjects},
	@IgnoredLogins = {ignoredLogins},
	@IgnoredAlerts = {ignoredAlerts},
	@IgnoredLinkedServers = {ignoredLinkedServers},
	@IgnorePrincipalNames = {ignorePrincipals},{operator}{profile}
	@PrintOnly = {printOnly}; ';

	DECLARE @jobsSyncTemplate nvarchar(MAX) = N'EXEC dbo.[verify_job_synchronization] 
	@IgnoredJobs = {ignoredJobs},{operator}{profile}
	@PrintOnly = {printOnly}; ';

	DECLARE @dataSyncTemplate nvarchar(MAX) = N'EXEC [dbo].[verify_data_synchronization]
	@IgnoredDatabases = {ignoredDatabases},{rpo}{rto}{checkCount}{checkDelay}{excludeAnomalies}{operator}{profile}
	@PrintOnly = {printOnly}; ';
	
	-----------------------------------------------------------------------------
	-- Process Server Sync Checks:
	DECLARE @serverBody nvarchar(MAX) = @serverSyncTemplate;
	
	IF @IgnoreSynchronizedDatabaseOwnership = 1 
		SET @serverBody = REPLACE(@serverBody, N'{ingoreOwnership}', N'1');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ingoreOwnership}', N'0');

	IF NULLIF(@IgnoredMasterDbObjects, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredMasterObjects}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredMasterObjects}', N'N''' + @IgnoredMasterDbObjects + N'''');

	IF NULLIF(@IgnoredLogins, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLogins}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLogins}', N'N''' + @IgnoredLogins + N'''');

	IF  NULLIF(@IgnoredAlerts, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredAlerts}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredAlerts}', N'N''' + @IgnoredAlerts + N'''');

	IF  NULLIF(@IgnoredLinkedServers, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLinkedServers}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLinkedServers}', N'N''' + @IgnoredLinkedServers + N'''');

	IF @IgnorePrincipalNames = 1
		SET @serverBody = REPLACE(@serverBody, N'{ignorePrincipals}', N'1');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignorePrincipals}', N'0');

	IF UPPER(@Action) = N'TEST' 
		SET @serverBody = REPLACE(@serverBody, N'{printOnly}', N'1');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{printOnly}', N'0');

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @serverBody = REPLACE(@serverBody, N'{operator}', N'');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @serverBody = REPLACE(@serverBody, N'{profile}', N'');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-----------------------------------------------------------------------------
	-- Process Job Sync Checks
	DECLARE @jobsBody nvarchar(MAX) = @jobsSyncTemplate;

	IF NULLIF(@IgnoredJobs, N'') IS NULL 
		SET @jobsBody = REPLACE(@jobsBody, N'{ignoredJobs}', N'NULL');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{ignoredJobs}', N'''' + @IgnoredJobs + N'''');

	IF UPPER(@Action) = N'TEST' 
		SET @jobsBody = REPLACE(@jobsBody, N'{printOnly}', N'1');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{printOnly}', N'0');

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @jobsBody = REPLACE(@jobsBody, N'{operator}', N'');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @jobsBody = REPLACE(@jobsBody, N'{profile}', N'');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-----------------------------------------------------------------------------
	-- Process Data Sync Checks

	DECLARE @dataBody nvarchar(MAX) = @dataSyncTemplate;

	IF NULLIF(@IgnoredDatabases, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{ignoredDatabases}', N'NULL');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{ignoredDatabases}', N'N''' + @IgnoredDatabases + N'''');

	IF NULLIF(@RPOThreshold, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{rpo}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{rpo}', @crlfTab + N'@RPOThreshold = N''' + @RPOThreshold + N''',');

	IF NULLIF(@RTOThreshold, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{rto}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{rto}', @crlfTab + N'@RTOThreshold = N''' + @RTOThreshold + N''',');

	IF @AGSyncCheckIterationCount IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{checkCount}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{checkCount}', @crlfTab + N'@AGSyncCheckIterationCount = ' + CAST(@AGSyncCheckIterationCount AS sysname) + N',');

	IF NULLIF(@AGSyncCheckDelayBetweenChecks, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{checkDelay}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{checkDelay}', @crlfTab + N'@AGSyncCheckDelayBetweenChecks = N''' + @AGSyncCheckDelayBetweenChecks + N''',');

	IF @ExcludeAnomolousSyncDeviations IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{excludeAnomalies}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{excludeAnomalies}', @crlfTab + N'@ExcludeAnomolousSyncDeviations = ' + CAST(@ExcludeAnomolousSyncDeviations AS sysname) + N',');

	IF UPPER(@Action) = N'TEST' 
		SET @dataBody = REPLACE(@dataBody, N'{printOnly}', N'1');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{printOnly}', N'0');

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @dataBody = REPLACE(@dataBody, N'{operator}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @dataBody = REPLACE(@dataBody, N'{profile}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	IF UPPER(@Action) = N'TEST' BEGIN
		
		PRINT N'NOTE: Operating in Test Mode. ';
		PRINT N'	SET @Action = N''CREATE'' when ready to create actual jobs... ' + @crlf + @crlf;
		PRINT N'EXECUTING synchronization-check calls as follows: ' + @crlf + @crlf;
		PRINT @serverBody + @crlf + @crlf;
		PRINT @jobsBody + @crlf + @crlf;
		PRINT @dataBody + @crlf + @crlf; 

		PRINT N'OUTPUT FROM EXECUTION of the above operations FOLLOWS:';
		PRINT N'--------------------------------------------------------------------------------------------------------';

		EXEC sp_executesql @serverBody;
		EXEC sp_executesql @jobsBody;
		EXEC sp_executesql @dataBody;


		PRINT N'--------------------------------------------------------------------------------------------------------';
		

		RETURN 0;
	END;
	-----------------------------------------------------------------------------
	-- Create the Server and Jobs Sync-Check Job:
	DECLARE @jobID uniqueidentifier; 
	DECLARE @currentJobName sysname = @JobsNamePrefix + N'Verify Server and Jobs';

	EXEC dbo.[create_agent_job]
		@TargetJobName = @currentJobName,
		@JobCategoryName = @JobsCategoryName,
		@AddBlankInitialJobStep = 0,  -- not for these jobs, they should be fairly short in execution... 
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobID OUTPUT;

	-- Add a schedule: 
	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @ServerAndJobsSyncCheckJobStart, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = @currentJobName + ' Schedule';

	DECLARE @frequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @ServerAndJobsSyncCheckJobRunsEvery,
		@ValidationParameterName = N'@ServerAndJobsSyncCheckJobRunsEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	-- TODO: scheduling logic here isn't as robust as it is in ...dbo.enable_disk_monitoring (and... i should expand the logic in THAT sproc, and move it out to it's own sub-sproc - i.e., pass in an @JobID and other params to a sproc called something like dbo.add_agent_job_schedule
	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobID,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 4,		-- daily								
		@freq_interval = 1, -- every 1 days							
		@freq_subday_type = 4,	-- minutes			
		@freq_subday_interval = @frequencyMinutes, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;	

	DECLARE @compoundJobStep nvarchar(MAX) = N'-- Server Synchronization Checks: 
' + @serverBody + N'

-- Jobs Synchronization Checks: 
' + @jobsBody;

	EXEC msdb..sp_add_jobstep
		@job_id = @jobID,
		@step_id = 1,
		@step_name = N'Synchronization Checks for Server Objects and Jobs Details',
		@subsystem = N'TSQL',
		@command = @compoundJobStep,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 1,
		@retry_interval = 1;

	-----------------------------------------------------------------------------
	-- Create the Data Sync-Check Job:

	SET @currentJobName = @JobsNamePrefix + N'Data-Sync Verification';
	SET @jobID = NULL;

	EXEC dbo.[create_agent_job]
		@TargetJobName = @currentJobName,
		@JobCategoryName = @JobsCategoryName,
		@AddBlankInitialJobStep = 0,  -- not for these jobs, they should be fairly short in execution... 
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobID OUTPUT;

	-- Add a schedule: 

	SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, @DataSyncCheckJobStart, 108), N':', N''), 6)) AS int);
	SET @scheduleName = @currentJobName + ' Schedule';

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @DataSyncCheckJobRunsEvery,
		@ValidationParameterName = N'@DataSyncCheckJobRunsEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	-- TODO: scheduling logic here isn't as robust as it is in ...dbo.enable_disk_monitoring (and... i should expand the logic in THAT sproc, and move it out to it's own sub-sproc - i.e., pass in an @JobID and other params to a sproc called something like dbo.add_agent_job_schedule
	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobID,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 4,		-- daily								
		@freq_interval = 1, -- every 1 days							
		@freq_subday_type = 4,	-- minutes			
		@freq_subday_interval = @frequencyMinutes, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- Add job Body: 
	DECLARE @singleBody nvarchar(MAX) = N'-- Data Synchronization Checks: 
' + @dataBody;

	EXEC msdb..sp_add_jobstep
		@job_id = @jobID,
		@step_id = 1,
		@step_name = N'Data Synchronization + Topology Health Checks',
		@subsystem = N'TSQL',
		@command = @singleBody,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 1,
		@retry_interval = 1;

	RETURN 0;
GO