/*

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
	@job_id						uniqueidentifier, 
	@job_name					sysname, 
	@latest_only				bit						= 1,
	@history_start				datetime				= NULL, 
	@history_end				datetime				= NULL
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

	SELECT @job_name = [name] FROM [msdb]..[sysjobs] WHERE [name] = @job_name

	IF @job_name IS NULL BEGIN 
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

	-- BUG: https://overachieverllc.atlassian.net/browse/S4-762
	WITH translated AS ( 
		SELECT 
			[h].[job_name],
			ISNULL(NULLIF([h].[step_id], 0), 1000) [step_id],
			[h].[step_name],
			CASE 
				WHEN [h].[step_id] = 0 THEN DATEADD(SECOND, [h].[run_seconds], [h].[run_time]) 
				ELSE [h].[run_time]
			END [run_time],
			[h].[weekday],
			[h].[run_seconds],
			[h].[run_status]
		FROM 
			dbo.[job_histories]() [h]
		WHERE 
			[h].[job_name] = @job_name
			AND [h].[run_time] >= DATEADD(MONTH, -3, GETDATE())		 -- MKC: BUG -> https://overachieverllc.atlassian.net/browse/S4-761
	), 
	lagged AS ( 
		SELECT
			ROW_NUMBER() OVER (ORDER BY [run_time], [step_id]) [row_number],
			[job_name],
			CASE WHEN LAG([step_id], 1, 1000) OVER (ORDER BY [run_time], [step_id]) = 1000 THEN ROW_NUMBER() OVER (ORDER BY [run_time], [step_id]) ELSE NULL END [instance],
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

	SELECT 
		CASE WHEN [h].[instance] IS NOT NULL THEN [h].[job_name] ELSE N'' END [job_name],
		ISNULL(NULLIF(CAST([h].[step_id] AS sysname), N'1000'), N'--') [step_id],
		[h].[step_name],

		CASE 
			WHEN [s].[step_id] IS NULL AND [s].[step_id] <> 0 THEN N'SKIPPED'
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
		[#jobHistory] [h]
		LEFT OUTER JOIN [#jobSteps] [s] ON [h].[step_id] = [s].[step_id]
	ORDER BY 
		[row_number];
	



	
	