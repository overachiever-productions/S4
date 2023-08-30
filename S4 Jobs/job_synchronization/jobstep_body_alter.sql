/*

	REFACTOR: 
		dbo.jobstep_body_alter 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.jobstep_body_alter','P') IS NOT NULL
	DROP PROC dbo.[jobstep_body_alter];
GO

CREATE PROC dbo.[jobstep_body_alter]
	@JobName			sysname, 
	@StepName			sysname, 
	@NewBody			nvarchar(MAX)
AS
    SET NOCOUNT ON; 

	-- {copyright}

	/* Verify that Job + Step Exist */
	DECLARE @jobID uniqueidentifier;
	SELECT @jobID = job_id FROM [msdb].dbo.[sysjobs] WHERE [name] = @JobName;
	IF @jobID IS NULL BEGIN 
		RAISERROR(N'Invalid Job Name. The job [%s] does not exist on current server.', 16, 1, @JobName);
		RETURN -10;
	END;
	
	DECLARE @stepId int;
	SELECT @stepId = [step_id] FROM [msdb].dbo.[sysjobsteps] WHERE [job_id] = @jobID AND [step_name] = @StepName

	IF @stepId IS NULL BEGIN
		RAISERROR(N'Invalid Job Step Name. A JobStep with the name [%s] does not exist within job [%s].', 16, 1, @StepName, @JobName);
		RETURN -20;
	END;

	DECLARE @outcome int;
	BEGIN TRY 

		EXEC @outcome = [msdb].dbo.[sp_update_jobstep]
			@job_id = @jobID,
			@step_id = @stepId,
			@command = @NewBody;
	
	END TRY 
	BEGIN CATCH 
		DECLARE @error nvarchar(MAX);
		SELECT @error = N'ERROR NUMBER: ' + CAST(ERROR_NUMBER() as sysname) + N'. ERROR MESSAGE: ' + ERROR_MESSAGE();

		IF @@TRANCOUNT > 0 
			ROLLBACK;
	END CATCH;

	IF @outcome <> 0 BEGIN 
		RAISERROR(N'Unexpected Error. No exception was thrown by msdb.dbo.sp_update_jobstep, but it also did NOT return SUCCESS.', 16, 1);
		RETURN -100;
	END;

	RETURN 0;
GO