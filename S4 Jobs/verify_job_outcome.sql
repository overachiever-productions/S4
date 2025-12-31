/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[verify_job_outcome]','P') IS NOT NULL
	DROP PROC dbo.[verify_job_outcome];
GO

CREATE PROC dbo.[verify_job_outcome]
	@job_id							uniqueidentifier		= NULL, 
	@job_name						sysname					= NULL, 
	@alert_on_step_failures			sysname					= NULL,		-- { NONE | ANY (same as all) | N+ | N, O, Q }
	@alert_on_skipped_steps			sysname					= NULL, 
	@operator						sysname					= NULL, 
	@subject						sysname					= NULL, 
	@print_only						bit						= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation + Input Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @job_name = NULLIF(@job_name, N'');
	SET @alert_on_step_failures = NULLIF(@alert_on_step_failures, N'');
	SET @alert_on_skipped_steps = NULLIF(@alert_on_skipped_steps, N'');

	IF @alert_on_step_failures = NULL AND @alert_on_skipped_steps = NULL BEGIN
		-- nothing to verify/check
		RETURN 0;
	END;

	DECLARE @errorString nvarchar(MAX);

	IF @job_id IS NULL AND @job_name IS NULL BEGIN
		DECLARE @applicationName sysname; 
		SELECT @applicationName = [program_name] FROM sys.[dm_exec_sessions] WHERE session_id = @@SPID;
		BEGIN TRY 
			DECLARE @jobIDString sysname = SUBSTRING(@applicationName, CHARINDEX(N'Job 0x', @applicationName) + 4, 34);
			DECLARE @currentStepString sysname = REPLACE(REPLACE(@applicationName, LEFT(@applicationName, CHARINDEX(N': Step', @applicationName) + 6), N''), N')', N''); 
			SET @job_id = CAST((CONVERT(binary(16), @jobIDString, 1)) AS uniqueidentifier);
		END TRY
		BEGIN CATCH
			SET @errorString = N'Error converting Program Name: [' + @applicationName + '] to SQL Server Agent JobID (Guid).';
		END CATCH

		IF @errorString IS NOT NULL BEGIN
			RAISERROR(N'Parameters @job_id and @job_name can ONLY be NULL when called from WITHIN a SQL Server Agent Job.', 16, 1);
			RAISERROR(@errorString, 16, 1);
			RETURN -10;
		END;
	END;

	IF NOT EXISTS (SELECT NULL FROM msdb..[sysjobs] WHERE job_id = @job_id) BEGIN
		DECLARE @jobString sysname = CAST(@job_id AS sysname);
		RAISERROR(N'Parameter @job_id with value: [%s] does NOT match a SQL Server Agent Job.', 16, 1, @jobString);
		RETURN -20;
	END;

	-- TODO: 
	--	translate ... NONE, ANY, and N+, as well as M, N, O ... options into something actionable
	--		for both failed and skipped. 

	EXEC dbo.[job_history]
		@job_id = @job_id,
		@job_name = NULL,
		@latest_only = 1;


	RETURN 0;
GO