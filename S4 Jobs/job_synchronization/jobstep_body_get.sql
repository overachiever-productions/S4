/*
    NOTE: 
        - This sproc adheres to the PROJECT/REPLY usage convention.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.jobstep_body_get','P') IS NOT NULL
	DROP PROC dbo.[jobstep_body_get];
GO

CREATE PROC dbo.[jobstep_body_get]
	@JobName			sysname, 
	@StepName			sysname, 
	@Output				nvarchar(MAX)	= N'' OUTPUT
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

	DECLARE @body nvarchar(MAX) = (SELECT [command] FROM [msdb].dbo.[sysjobsteps] WHERE [job_id] = @jobID AND [step_name] = @StepName);

	IF @Output IS NULL BEGIN 
		SET @Output = @body;
		RETURN 0;
	END;

	SELECT @body [body];

	RETURN 0;
GO