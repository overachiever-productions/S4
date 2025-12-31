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
	SET @alert_on_step_failures = UPPER(NULLIF(@alert_on_step_failures, N''));
	SET @alert_on_skipped_steps = UPPER(NULLIF(@alert_on_skipped_steps, N''));

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

	SELECT @job_name = [name] FROM msdb..sysjobs WHERE [job_id] = @job_id;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing Logic:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @serializedHistory xml;
	EXEC dbo.[job_history]
		@job_id = @job_id,
		@latest_only = 1, 
		@serialized_output = @serializedHistory OUTPUT;

	-- NOTE: Skipping ROOT node and going direct to children.
	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(job_name)[1]', N'sysname') [job_name],
			[data].[row].value(N'(step_id)[1]', N'int') [step_id],
			[data].[row].value(N'(step_name)[1]', N'sysname') [step_name],
			[data].[row].value(N'(outcome)[1]', N'sysname') [outcome],
			[data].[row].value(N'(duration)[1]', N'sysname') [duration]
		FROM 
			@serializedHistory.nodes(N'//job_step') [data]([row])
	) 

	SELECT 
		[job_name],
		[step_id],
		[step_name],
		[outcome],
		[duration] 
	INTO 
		#jobHistory
	FROM 
		[shredded];

UPDATE [#jobHistory] SET [outcome] = N'FAILURE' WHERE [step_id] = 3;
UPDATE [#jobHistory] SET [outcome] = N'RUNNING' WHERE [step_id] = 0;

	DECLARE @alertsNeeded bit = 0;
	IF @alert_on_step_failures LIKE N'%ANY%' BEGIN
		IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] IN (N'FAILURE', N'CANCELLED'))
			SET @alertsNeeded = 1;
	END;

	IF @alert_on_step_failures LIKE N'%+%' BEGIN
		DECLARE @minStep int = CAST(REPLACE(REPLACE(@alert_on_step_failures, N'+', N''), N' ', N'') AS int);

		IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] IN (N'FAILURE', N'CANCELLED') AND step_id >= @minStep)
			SET @alertsNeeded = 1;
	END;

	IF @alert_on_step_failures LIKE N'%,%' BEGIN
		DECLARE @jobSteps table (
			[row_id] int IDENTITY(1,1) NOT NULL,
			[failure_step] int NOT NULL
		); 

		INSERT INTO @jobSteps ([failure_step])
		SELECT [result] FROM dbo.[split_string](@alert_on_step_failures, N',', 1) ORDER BY [row_id];

		IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] IN (N'FAILURE', N'CANCELLED') AND [step_id] IN (SELECT failure_step FROM @jobSteps))
			SET @alertsNeeded = 1;
	END;

	IF @alertsNeeded = 1 BEGIN
		DECLARE @historyString nvarchar(MAX) = N'';

		SELECT
			@historyString = @historyString + 
			CASE WHEN [job_name] = N'' THEN REPLICATE(N' ', LEN(@job_name)) ELSE [job_name] END + N'  ' + 
			RIGHT(N'   ' + CAST([step_id] AS sysname), 3) + N' - ' +
			LEFT([step_name] + REPLICATE(N' ', 40), 30) + N' - ' +
			[outcome] + N' - ' +
			CAST([duration] AS sysname) + 
			NCHAR(13) + NCHAR(10)
		FROM
			[#jobHistory] 
		ORDER BY 
			[step_id];
	

		PRINT @historyString;

	END;


	RETURN 0;
GO