/*
	INTERNAL


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.create_agent_job','P') IS NOT NULL
	DROP PROC dbo.[create_agent_job];
GO

CREATE PROC dbo.[create_agent_job]
	@TargetJobName							sysname, 
	@JobCategoryName						sysname					= NULL, 
	@JobEnabled								bit						= 1,					-- Default to creation of the job in Enabled state.
	@AddBlankInitialJobStep					bit						= 1, 
	@OperatorToAlertOnErrorss				sysname					= N'Alerts',
	@OverWriteExistingJobDetails			bit						= 0,					-- NOTE: Initially, this means: DROP/CREATE. Eventually, this'll mean: repopulate the 'guts' of the job if/as needed... 
	@JobID									uniqueidentifier		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @existingJob sysname; 
	SELECT 
		@existingJob = [name]
	FROM 
		msdb.dbo.sysjobs
	WHERE 
		[name] = @TargetJobName;

	IF @existingJob IS NOT NULL BEGIN 
		IF @OverWriteExistingJobDetails = 1 BEGIN 
			-- vNEXT: for now this just DROPs/CREATEs a new job. While that makes sure the config/details are correct, that LOSEs job-history. 
			--			in the future, another sproc will go out and 'gut'/reset/remove ALL job-details - leaving just a 'shell' (the job and its name). 
			--				at which point, we can then 'add' in all details specified here... so that: a) the details are correct, b) we've kept the history. 
			EXEC msdb..sp_delete_job 
			    @job_name = @TargetJobName,
			    @delete_history = 1,
			    @delete_unused_schedule = 1; 
		  END;
		ELSE BEGIN
			RAISERROR('Unable to create job [%s] - because it already exists. Set @OverwriteExistingJobs = 1 or manually remove existing job/etc.', 16, 1, @TargetJobName);
			RETURN -5;
		END;
	END;

	-- Ensure that the Job Category exists:
	IF NULLIF(@JobCategoryName, N'') IS NULL 
		SET @JobCategoryName = N'[Uncategorized (Local)'; 

	IF NOT EXISTS(SELECT NULL FROM msdb..syscategories WHERE [name] = @JobCategoryName) BEGIN 
		EXEC msdb..sp_add_category 
			@class = N'JOB',
			@type = 'LOCAL',  
		    @name = @JobCategoryName;
	END;

	-- Create the Job:
	SET @JobID = NULL;  -- nasty 'bug' with sp_add_job: if @jobID is NOT NULL, it a) is passed out bottom and b) if a JOB with that ID already exists, sp_add_job does nothing. 
	
	EXEC msdb.dbo.sp_add_job
		@job_name = @TargetJobName,                     
		@enabled = @JobEnabled,                         
		@description = N'',                   
		@category_name = @JobCategoryName,                
		@owner_login_name = N'sa',             
		@notify_level_eventlog = 0,           
		@notify_level_email = 2,              
		@notify_email_operator_name = @OperatorToAlertOnErrorss,   
		@delete_level = 0,                    
		@job_id = @JobID OUTPUT;

	EXEC msdb.dbo.[sp_add_jobserver] 
		@job_id = @jobId, 
		@server_name = N'(LOCAL)';


	IF @AddBlankInitialJobStep = 1 BEGIN
		EXEC msdb..sp_add_jobstep
			@job_id = @jobId,
			@step_id = 1,
			@step_name = N'Initialize Job History',
			@subsystem = N'TSQL',
			@command = N'/* 

  SQL Server Agent Job History can NOT be shown until the first 
  Job Step is complete. This step is a place-holder. 

*/',
			@on_success_action = 3,		-- go to the next step
			@on_fail_action = 3,		-- go to the next step. Arguably, should be 'quit with failure'. But, a) this shouldn't fail and, b) we don't CARE about this step 'running' so much as we do about SUBSEQUENT steps.
			@database_name = N'admindb',
			@retry_attempts = 0;

	END;

	RETURN 0;
GO