/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_verify_jobs]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_verify_jobs];
GO

CREATE PROC dbo.[eventstore_verify_jobs]
	@ForceOverwrite			bit		= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);

	IF @ForceOverwrite = 1 OR (NOT EXISTS (SELECT NULL FROM msdb..[sysjobs] WHERE [name] = N'EventStore Processor')) BEGIN

		DECLARE @jobStep nvarchar(MAX) = N'EXEC admindb.dbo.[eventstore_etl_processor];';

		DECLARE @JobID uniqueidentifier;
		EXEC dbo.[create_agent_job]
			@TargetJobName = N'EventStore Processor',
			@JobCategoryName = N'EventStore',
			@JobEnabled = 1,
			@AddBlankInitialJobStep = 1,
			@OverWriteExistingJobDetails = 1,
			@JobID = @JobID OUTPUT; 

		EXEC msdb..[sp_update_job] 
			@job_id = @JobID,
			@description = N'Transforms EventStore XE Session Target Data to EventStore Reporting Data.';		

		EXEC msdb..[sp_add_jobschedule]
			@job_id = @JobID,
			@name = N'Regular EventStore ETL Processing Schedule',
			@enabled = 1,
			@freq_type = 4,		-- daily
			@freq_interval = 1,  -- every 1 day
			@freq_subday_type = 4,	-- every N minutes
			@freq_subday_interval = 1,  -- 1 minute (i.e., N from above).
			@freq_relative_interval = 0,
			@freq_recurrence_factor = 0,
			@active_start_date = @dateAsInt,
			@active_start_time = 140;  -- at 12:01:40

		EXEC msdb..[sp_add_jobstep]
			@job_id = @JobID,
			@step_id = 2,
			@step_name = N'Process EventStore Transformations',
			@subsystem = N'TSQL',
			@command = @jobStep,
			@on_success_action = 1,
			@on_fail_action = 2,
			@database_name = N'admindb',
			@retry_attempts = 0,
			@retry_interval = 0;
	END;

	IF @ForceOverwrite = 1 OR (NOT EXISTS (SELECT NULL FROM msdb..[sysjobs] WHERE [name] = N'EventStore Cleanup')) BEGIN 
		
		SET @jobStep = N'EXEC admindb.dbo.[eventstore_data_cleanup];';

		SET @JobID = NULL;
		EXEC dbo.[create_agent_job]
			@TargetJobName = N'EventStore Cleanup',
			@JobCategoryName = N'EventStore',
			@JobEnabled = 1,
			@AddBlankInitialJobStep = 1,
			@OverWriteExistingJobDetails = 1,
			@JobID = @JobID OUTPUT; 

		EXEC msdb..[sp_update_job] 
			@job_id = @JobID,
			@description = N'Regular cleanup of EventStore data.';		

		EXEC msdb..[sp_add_jobschedule]
			@job_id = @JobID,
			@name = N'Regular EventStore Cleanup Schedule',
			@enabled = 1,
			@freq_type = 4,		-- daily
			@freq_interval = 1,  -- every 1 day
			@freq_subday_type = 1,	
			@freq_subday_interval = 0,  
			@freq_relative_interval = 0,
			@freq_recurrence_factor = 0,
			@active_start_date = @dateAsInt,
			@active_start_time = 223000;  -- 10:30PM

		EXEC msdb..[sp_add_jobstep]
			@job_id = @JobID,
			@step_id = 2,
			@step_name = N'Cleanup Transformed EventStore Data.',
			@subsystem = N'TSQL',
			@command = @jobStep,
			@on_success_action = 1,
			@on_fail_action = 2,
			@database_name = N'admindb',
			@retry_attempts = 0,
			@retry_interval = 0;
	END;

	RETURN 0;
GO