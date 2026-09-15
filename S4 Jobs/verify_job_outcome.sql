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
	@alert_on_step_failures			sysname					= N'{ANY}',		-- { NONE | ANY (same as all) | N+ | N, O, Q }
	@alert_on_skipped_steps			sysname					= N'{NONE}',
	@profile						sysname					= N'General',
	@operator						sysname					= N'Alerts', 
	@subject_prefix					sysname					= N'SQL Server Agent Job Failure: ', 
	@print_only						bit						= 0				-- Does NOT send email alerts, prints them instead.
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation + Input Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @job_name = NULLIF(@job_name, N'');
	SET @alert_on_step_failures = UPPER(ISNULL(NULLIF(@alert_on_step_failures, N''), N'{ANY}'));
	SET @alert_on_skipped_steps = UPPER(ISNULL(NULLIF(@alert_on_skipped_steps, N''), N'{NONE}'));

	IF @alert_on_step_failures = NULL AND @alert_on_skipped_steps = NULL BEGIN
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

	IF @job_id IS NULL AND @job_name IS NOT NULL BEGIN 
		SELECT @job_id = [job_id] FROM msdb..[sysjobs] WHERE [name] = @job_name;
	END;

	IF NOT EXISTS (SELECT NULL FROM msdb..[sysjobs] WHERE job_id = @job_id) BEGIN
		DECLARE @jobString sysname = CAST(@job_id AS sysname);
		RAISERROR(N'Parameter @job_id with value: [%s] does NOT match a SQL Server Agent Job.', 16, 1, @jobString);
		RETURN -20;
	END;

	-- SLIGHT hacks to avoid SKIPPING/non-processing of N'x' vs N'x, y' inputs/values. 
	IF @alert_on_step_failures IS NOT NULL AND @alert_on_step_failures NOT LIKE N'%+%' AND @alert_on_step_failures NOT LIKE N'%ANY%' AND @alert_on_step_failures NOT LIKE N'%,%'
		SET @alert_on_step_failures = @alert_on_step_failures + N','; 
	IF @alert_on_skipped_steps IS NOT NULL AND @alert_on_skipped_steps NOT LIKE N'%+%' AND @alert_on_skipped_steps NOT LIKE N'%ANY%' AND @alert_on_skipped_steps NOT LIKE N'%,%'
		SET @alert_on_skipped_steps = @alert_on_skipped_steps + N','; 

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
			[data].[row].value(N'(duration)[1]', N'sysname') [duration], 
			[data].[row].value(N'(sql_message_id)[1]', N'int') [sql_message_id],
			[data].[row].value(N'(sql_severity)[1]', N'int') [sql_severity],
			[data].[row].value(N'(message)[1]', N'nvarchar(MAX)') [message]
		FROM 
			@serializedHistory.nodes(N'//job_step') [data]([row])
	) 

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[job_name],
		[step_id],
		[step_name],
		[outcome],
		[duration], 
		[sql_message_id], 
		[sql_severity], 
		[message], 
		CASE WHEN [outcome] = N'SUCCESS' THEN NULL ELSE 1 END [is_error]
	INTO 
		#jobHistory
	FROM 
		[shredded]
	ORDER BY 
		[step_id];

	WITH ordered AS ( 

		SELECT 
			[row_id],
			ROW_NUMBER() OVER (PARTITION BY ISNULL([is_error], -1) ORDER BY [row_id]) [error_id]
		FROM 
			[#jobHistory] 
	) 

	UPDATE [x]
	SET 
		[x].[is_error] = [o].[error_id]
	FROM 
		[#jobHistory] [x]
		INNER JOIN [ordered] [o] ON [x].[row_id] = [o].[row_id] 
	WHERE 
		[x].[is_error] IS NOT NULL;

	DECLARE @failureAlertsNeeded bit = 0;
	DECLARE @skipAlertsNeeded bit = 0;
	DECLARE @minStep int;
	IF @alert_on_step_failures IS NOT NULL AND EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] IN (N'FAILURE', N'CANCELLED', N'RETRYING')) BEGIN
			
		IF @alert_on_step_failures LIKE N'%ANY%'
			SET @failureAlertsNeeded = 1;

		IF @alert_on_step_failures LIKE N'%+%' BEGIN
			SET @minStep = CAST(REPLACE(REPLACE(@alert_on_step_failures, N'+', N''), N' ', N'') AS int);

			IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] IN (N'FAILURE', N'CANCELLED') AND step_id >= @minStep)
				SET @failureAlertsNeeded = 1;
		END;

		IF @alert_on_step_failures LIKE N'%,%' BEGIN
			DECLARE @jobSteps table (
				[row_id] int IDENTITY(1,1) NOT NULL,
				[failure_step] int NOT NULL
			); 

			INSERT INTO @jobSteps ([failure_step])
			SELECT [result] FROM dbo.[split_string](@alert_on_step_failures, N',', 1) ORDER BY [row_id];

			IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] IN (N'FAILURE', N'CANCELLED') AND [step_id] IN (SELECT failure_step FROM @jobSteps))
				SET @failureAlertsNeeded = 1;
		END;
	END;

	IF @alert_on_skipped_steps IS NOT NULL AND EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] = N'SKIPPED') BEGIN
		IF @alert_on_skipped_steps LIKE N'%ANY%'
			SET @skipAlertsNeeded = 1;
		
		IF @alert_on_skipped_steps LIKE N'%+%' BEGIN
			SET @minStep = CAST(REPLACE(REPLACE(@alert_on_step_failures, N'+', N''), N' ', N'') AS int);

			IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] = N'SKIPPED' AND step_id >= @minStep)
				SET @skipAlertsNeeded = 1;
		END;

		IF @alert_on_skipped_steps LIKE N'%,%' BEGIN
			DELETE FROM @jobSteps; 
			
			INSERT INTO @jobSteps ([failure_step])
			SELECT [result] FROM dbo.[split_string](@alert_on_skipped_steps, N',', 1) ORDER BY [row_id];

			IF EXISTS (SELECT NULL FROM [#jobHistory] WHERE [outcome] = N'SKIPPED' AND [step_id] IN (SELECT failure_step FROM @jobSteps))
				SET @skipAlertsNeeded = 1;
		END;
	END;

	IF @failureAlertsNeeded = 1 OR @skipAlertsNeeded = 1 BEGIN
		DECLARE @historyString nvarchar(MAX) = N'';

-- PICKUP / NEXT: 
		-- need to report on what/which problems we ran into: failures? skips, or both? 
		--		and... don't need any details-ish - other than to say: "trigger was for x (or y) and we hit ... z" 
		--		cuz the SUMMARY itself will show what the problem was. 

-- then... once the above is done... 
--		tackle ... 'variance'. 

		SELECT
			@historyString = @historyString + 
			CASE WHEN [job_name] = N'' THEN REPLICATE(N' ', LEN(@job_name)) ELSE [job_name] END + N'  ' + 
			dbo.[format_text_width]([step_id], 3, N'RIGHT') + N' - ' +
			--RIGHT(N'   ' + CAST([step_id] AS sysname), 3) + N' - ' +
			--LEFT([step_name] + REPLICATE(N' ', 40), 30) + N' - ' +
			dbo.[format_text_width]([step_name], 44, N'LEFT') + N' - ' + 
			dbo.[format_text_width]([outcome], 8, N'LEFT')  + N' - ' +
			CAST([duration] AS sysname) + 
			CASE WHEN [is_error] IS NOT NULL THEN N'  [*' + CAST(CHAR(64 + [is_error]) AS sysname) + N']' ELSE N'' END +
			NCHAR(13) + NCHAR(10)
		FROM
			[#jobHistory] 
		ORDER BY 
			[row_id];
		
		SET @historyString = @historyString + NCHAR(13) + NCHAR(10) + N'----------------------------------------------------------------------' + NCHAR(13) + NCHAR(10);

		SELECT 
			@historyString = @historyString + 
			N'- [*' + CAST(CHAR(64 + [is_error]) AS sysname) + N'] - ' + N'SEVERITY: ' + CAST([sql_severity] AS sysname) + N' - '  + [message] +
			NCHAR(13) + NCHAR(10)
		FROM 
			[#jobHistory]
		WHERE 
			[is_error] IS NOT NULL 
		ORDER BY 
			[row_id];
		
		DECLARE @subject sysname = @subject_prefix + N' ' + QUOTENAME(@job_name);

		IF @print_only = 1 BEGIN 
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'----------------------------------------------------------------------------------------------';
			PRINT N'BODY:';
			PRINT N'';
			PRINT @historyString;
		  END;
		ELSE BEGIN 
			EXEC msdb..[sp_notify_operator]
				@profile_name = @profile,
				@name = @operator,
				@subject = @subject,
				@body = @historyString;
			
		END;
	END;

	RETURN 0;
GO