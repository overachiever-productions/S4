/*

	NOTE:
		This code might, superficially, seem fairly simple. 
		It's actually not. 
			msdb..jobhistory does NOT account for: 
				- instances of job execution. 
				- skipped steps - which 1000000% can/will happen based upon on-success/on-failure directives
					very much an edge case, but ... still. 
				- jobs still RUNNING at the time of execution (of this sproc/query)
					because the step_id for a job (vs it's individual steps) is ... 0
						and may NOT be present at execution time. 
		The logic in this sproc leverages some semi-complex logic to address ALL of the above. 
				In order to create an ACCURATE 'picture' of all selected and/or the CURRENTLY-executing outcome (progress) of an executing job. 





	TODO:
		Pretty sure I REALLY need this IX (i've created it on DEV ... and it does help reduce the COST of pulling info from dbo.job_histories()

					USE [msdb];
					GO
					CREATE NONCLUSTERED INDEX [COVIX_sysjobhistory_Details_By_JobId]
					ON [dbo].[sysjobhistory] ([job_id])
					INCLUDE ([step_id],[step_name],[run_date],[run_time],[run_duration], [run_status], [sql_message_id], [sql_severity], [message]);
					GO



	EXAMPLE: 

			EXEC [admindb]..job_history NULL, N'Regular History Cleanup';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[job_history]','P') IS NOT NULL
	DROP PROC dbo.[job_history];
GO

CREATE PROC dbo.[job_history]
	@job_id						uniqueidentifier		= NULL,	
	@job_name					sysname					= NULL, 
	@latest_only				bit						= 1,
	@history_start				datetime				= NULL, 
	@history_end				datetime				= NULL, 
	@serialized_output			xml						= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation + Input Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @job_name = NULLIF(@job_name, N'');
	SET @latest_only = ISNULL(@latest_only, 1);

	IF @job_id IS NULL AND @job_name IS NULL BEGIN 
		RAISERROR(N'Please specify inputs for either @job_id OR @job_name.', 16, 1);
		RETURN -1;
	END;

	IF @job_id IS NOT NULL BEGIN 
		SELECT @job_name = [name] FROM msdb..[sysjobs] WHERE [job_id] = @job_id;
	END;

	IF NOT EXISTS(SELECT NULL FROM msdb..[sysjobs] WHERE [name] = @job_name) BEGIN 
		DECLARE @detailString sysname;
		IF @job_name IS NOT NULL 
			SET @detailString = N'@job_name = N''' + @job_name + N'''.';
		ELSE 
			SET @detailString = N'@job_id ''' + CAST(@job_id AS sysname) + N'''.';

		RAISERROR(N'Could not find job matching input %s', 16, 1, @detailString);
		RETURN -10;
	END;

	IF @latest_only <> 1 BEGIN
		IF @history_start IS NULL BEGIN
			RAISERROR(N'Parameter @history_start may NOT be null/empty when @latest_only = 0. Please specify a start-date(time) via @history_start.', 16, 1);
			RETURN -12;
		END;
		
		IF @history_start > GETDATE() BEGIN
			RAISERROR(N'Parameter @history_start may NOT be > GETDATE().', 16, 1); -- hmm... what about ... GETUTCDATE()? 
			RETURN -13;
		END;
	END;

	IF @latest_only = 1 BEGIN
		SET @history_start = DATEADD(MONTH, -2, GETDATE());
	END;

	IF @history_end IS NULL BEGIN
		SET @history_end = GETDATE();
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing Logic:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT @job_id = job_id FROM msdb..[sysjobs] WHERE [name] = @job_name;
	
	SELECT 
		[step_id],
		[step_name]
	INTO 
		#jobSteps
	FROM 
		msdb..[sysjobsteps]
	WHERE 
		[job_id] = @job_id
	ORDER BY 
		[step_id];

	-- Job instance may NOT be complete ... 
	INSERT INTO [#jobSteps] ([step_id], [step_name])
	VALUES (0, N'(Job outcome)'); 

	-- BUG: https://overachieverllc.atlassian.net/browse/S4-762
	WITH translated AS ( 
		SELECT 
			[h].[job_name],
			[h].[step_id],
			[h].[step_name],
			[h].[run_time],
			[h].[weekday],
			[h].[run_seconds],
			[h].[run_status]
		FROM 
			dbo.[job_histories]() [h]
		WHERE 
			[h].[job_name] = @job_name
			AND [h].[run_time] >= DATEADD(MONTH, -3, GETDATE())		 -- MKC: BUG -> https://overachieverllc.atlassian.net/browse/S4-761

--AND NOT ([h].[step_id] = 0 AND [h].[run_time] = '2025-12-28 09:45:00.000')
	), 
	lagged AS ( 
		SELECT
			ROW_NUMBER() OVER (ORDER BY [run_time], [step_id]) [row_number],
			[job_name],
			CASE WHEN LAG([step_id], 1, 1000) OVER (ORDER BY [run_time], [step_id]) > [step_id] THEN ROW_NUMBER() OVER (ORDER BY [translated].[run_time], [translated].[step_id]) ELSE NULL END [instance],
			[step_id], 
			[step_name],
			[run_time], 
			[weekday], 
			[run_seconds], 
			[run_status]
		FROM 
			[translated]
	)

	SELECT 
		[row_number],
		[job_name],
		[instance] [lead],
		[instance],
		[step_id],
		[step_name],
		[run_time],
		[weekday],
		[run_seconds],
		[run_status] 
	INTO
		#jobHistory
	FROM 
		[lagged]
	ORDER BY 
		[row_number];

	SELECT 
		[job_name], 
		[step_id], 
		COUNT([job_name]) [count],
		AVG([run_seconds]) [avg_seconds], 
		MAX([run_seconds]) [max_seconds], 
		MIN([run_seconds]) [min_seconds]
	INTO 
		#jobStats
	FROM 
		[#jobHistory]
	GROUP BY 
		[job_name], 
		[step_id];

	IF @latest_only = 1 BEGIN
		DELETE FROM [#jobHistory] WHERE [row_number] < (SELECT MAX([instance]) FROM [#jobHistory]);
	  END;
	ELSE BEGIN
		DELETE FROM [#jobHistory] 
		WHERE 
			[row_number] < (SELECT MAX([instance]) FROM [#jobHistory] WHERE [run_time] < @history_start)
			AND [row_number] > (SELECT MIN([instance]) FROM [#jobHistory] WHERE [run_seconds] > @history_end);
	END;
	
	WITH instance_starts AS ( 
		SELECT 
			[row_number],
			[job_name],
			[instance],
			0 [step_id]
		FROM 
			[#jobHistory] 
		WHERE 
			[instance] IS NOT NULL
	) 

	SELECT 
		[i].[instance],
		[x].[step_id], 
		[x].[step_name]
	INTO 
		#frame
	FROM 
		[instance_starts] [i]
		CROSS APPLY (SELECT [step_id], [step_name] FROM [#jobSteps]) x
	ORDER BY 
		[i].[instance], x.[step_id];

	WITH correlated AS ( 
		SELECT 
			[h].[row_number],
			CASE WHEN [h].[instance] IS NOT NULL THEN [h].[instance] ELSE (SELECT MAX([x].[instance]) FROM [#jobHistory] [x] WHERE [x].[row_number] <= [h].[row_number]) END [instance]
		FROM 
			[#jobHistory] [h]
	) 

	UPDATE [x]
	SET 
		[x].[instance] = [c].[instance]
	FROM 
		[correlated] [c] 
		INNER JOIN #jobHistory [x] ON [c].[row_number] = [x].[row_number]
	WHERE 
		x.[instance] IS NULL;

--DELETE FROM [#jobHistory] WHERE [instance] = 43 AND [step_id] IN (3,4,6);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Project or RETURN:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (SELECT 
			CASE WHEN [x].[step_id] = 0 THEN @job_name ELSE N'' END [job_name],
			[x].[step_id], 
			[x].[step_name],
			CASE 
				WHEN [h].[step_id] IS NULL THEN CASE WHEN [x].[step_id] = 0 THEN N'RUNNING' ELSE N'SKIPPED' END 
				ELSE CASE
					WHEN [h].[run_status] = 0 THEN 'FAILURE'  -- message and/or error_id/status? 
					WHEN [h].[run_status] = 1 THEN N'SUCCESS'
					WHEN [h].[run_status] = 3 THEN N'CANCELLED'
					WHEN [h].[run_status] = 2 THEN N'RETRYING'
					WHEN [h].[run_status] = 4 THEN N'RUNNING'
				END
			END [outcome],
			[h].[run_time],
			dbo.[format_timespan](1000 * [h].[run_seconds]) [duration]
		FROM 
			[#frame] [x]
			LEFT OUTER JOIN [#jobHistory] [h] ON [x].[instance] = [h].[instance] AND [x].[step_id] = [h].[step_id]
		ORDER BY 
			[x].[instance], [x].[step_id]
		FOR XML PATH(N'job_step'), ROOT(N'job_instance'), TYPE);		
		
		RETURN 0;	
	END;	

	SELECT 
		--[x].[instance],
		CASE WHEN [x].[step_id] = 0 THEN @job_name ELSE N'' END [job_name],
		[x].[step_id], 
		[x].[step_name],
		CASE 
			WHEN [h].[step_id] IS NULL THEN CASE WHEN [x].[step_id] = 0 THEN N'RUNNING' ELSE N'SKIPPED' END 
			ELSE CASE
				WHEN [h].[run_status] = 0 THEN 'FAILURE'  -- message and/or error_id/status? 
				WHEN [h].[run_status] = 1 THEN N'SUCCESS'
				WHEN [h].[run_status] = 3 THEN N'CANCELLED'
				WHEN [h].[run_status] = 2 THEN N'RETRYING'
				WHEN [h].[run_status] = 4 THEN N'RUNNING'
			END
		END [outcome],
		[h].[run_time],
		dbo.[format_timespan](1000 * [h].[run_seconds]) [duration]
	FROM 
		[#frame] [x]
		LEFT OUTER JOIN [#jobHistory] [h] ON [x].[instance] = [h].[instance] AND [x].[step_id] = [h].[step_id]
	ORDER BY 
		[x].[instance], [x].[step_id];

	RETURN 0;
GO