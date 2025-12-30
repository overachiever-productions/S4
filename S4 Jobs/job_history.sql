/*


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

	SELECT 
		[h].[job_name],
		[h].[step_id],
		[h].[step_name],
		[h].[run_time],
		[h].[weekday],
		[h].[run_seconds],
		[h].[run_status]
	INTO 
		#jobHistory
	FROM 
		dbo.[job_histories]() [h]
	WHERE 
		[h].[job_name] = @job_name
		AND [h].[run_time] >= @history_start
		AND [h].[run_time] <= @history_end;

	SELECT 
		[job_name], 
		[step_id], 
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

	WITH translated AS ( 
		SELECT 
			CASE 
				WHEN [step_id] = 0 THEN DATEADD(SECOND, [run_seconds], [run_time]) 
				ELSE [run_time]
			END [run_time],
			ISNULL(NULLIF([step_id], 0), 1000) [step_id]
		FROM 
			[#jobHistory]
	), 
	lagged AS ( 
		SELECT
			ROW_NUMBER() OVER (ORDER BY [run_time], [step_id]) [row_number],
			[step_id], 
			--CASE WHEN LAG([step_id], 1, 1000) OVER (ORDER BY [run_time], [step_id]) = 1000 THEN N'NEW' ELSE N'' END [instance],
			CASE WHEN LAG([step_id], 1, 1000) OVER (ORDER BY [run_time], [step_id]) = 1000 THEN ROW_NUMBER() OVER (ORDER BY [run_time], [step_id]) ELSE NULL END [instance],
			[run_time]
		FROM 
			[translated]
	), 
	ordered AS ( 
		SELECT 
			[lagged].[row_number], 
			[lagged].[step_id], 
			[lagged].[run_time], 
			[lagged].[instance]
		FROM 
			[lagged]
	) 


	SELECT * FROM [ordered];



	
	