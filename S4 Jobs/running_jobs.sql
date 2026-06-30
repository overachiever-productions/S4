/*




    .CONVENTIONS:
	- PROJECT or RETURN


	.OUTPUTS 

	.bounds 
		Provides context/details on interaction between start and end of a job-step vs the @start and @end parameters (if/when provided). 
		Specifically, there are 4 main outcomes possible: 
			➡️⏹️ - Job Step was RUNNING before @start but ended before @end. 
			➡️➡️  - Job Step was RUNNING before @start and continued running after @end.
			⏹️➡️ - Job Step started after @start but continued running after @end.
			⏹️⏹️ - Job Step started after @start and ended before @end.

		NOTE: 
			When no @start date is provided, then [bounds] will have an @start and @end of GETDATE(). 
			Which means that we're looking for ANY jobs running "right now". 
			And because they're running NOW (before @start) and will (presumably) still be running (after GETDATE()/@end)... 
				then, any jobs actively running "right this second" will have a [bounds] of ➡️➡️
				These jobs will not, however, have an [end_time] - because the job has NOT completed yet. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[running_jobs]','P') IS NOT NULL
	DROP PROC dbo.[running_jobs];
GO

--##CONDITIONAL_SUPPORT(> 10.5)

CREATE PROC dbo.[running_jobs]
	@start								datetime				= NULL, 
	@end								datetime				= NULL, 
	@jobs								nvarchar(MAX)			= NULL, 
    @serialized_output					xml						= N'<default/>'			OUTPUT			
AS
	SET NOCOUNT ON; 

	-- {copyright}

	SET @start = NULLIF(@start, N'');  -- can't be the case with this as a datetime ... but once I change this to a timespan or whatever... then it'll be sysname. 
	SET @jobs = NULLIF(@jobs, N'');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @start IS NOT NULL BEGIN 
		IF @end IS NULL BEGIN
			SET @end = GETDATE();
		  END;
		ELSE BEGIN
			IF @end < @start BEGIN
				RAISERROR('Parameter Value for @end must be greater than (or equal to) Parameter Value for @start.', 16, 1);
				RETURN -2;		
			END;
		END;
	  END;
	ELSE BEGIN
		IF @end is NOT NULL BEGIN
			RAISERROR('Parameter Value for @start must be specified if Parameter Value for @end is specified.', 16, 1);
			RETURN -3;		
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE [#RunningJobs] (
		[row_id] int IDENTITY(1, 1) NOT NULL,
		[job_name] sysname NOT NULL,
		[job_id] uniqueidentifier NOT NULL,
		[step_id] int NOT NULL,
		[step_name] sysname NOT NULL,
		[start_time] datetime NOT NULL,
		[end_time] datetime NULL
	);

	DECLARE @currentlyRunning bit = 0;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- NO @start or @end - i.e., jobs running RIGHT NOW (or actively running jobs). 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @start IS NULL BEGIN
		INSERT INTO [#RunningJobs] ([job_name], [job_id], [step_name], [step_id], [start_time], [end_time])
		SELECT 
			j.[name] [job_name], 
			ja.job_id,
			js.[step_name] [step_name],
			js.[step_id],
			ja.[start_execution_date] [start_time], 
			NULL [end_time]
		FROM 
			msdb.dbo.[sysjobactivity] ja 
			LEFT OUTER JOIN msdb.dbo.[sysjobhistory] jh ON [ja].[job_history_id] = [jh].[instance_id]
			INNER JOIN msdb.dbo.[sysjobs] j ON [ja].[job_id] = [j].[job_id] 
			INNER JOIN msdb.dbo.[sysjobsteps] js ON [ja].[job_id] = [js].[job_id] AND ISNULL([ja].[last_executed_step_id], 0) + 1 = [js].[step_id]
		WHERE 
			[ja].[session_id] = (SELECT TOP (1) [session_id] FROM msdb.dbo.[syssessions] ORDER BY [agent_start_date] DESC) 
			AND [ja].[start_execution_date] IS NOT NULL 
			AND [ja].[stop_execution_date] IS NULL;

		SET @currentlyRunning = 1;
		--SELECT 
		--	@start = GETDATE(), 
		--	@end = GETDATE(); 

		GOTO JOB_PREDICATES;
	END;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounded Jobs:
	--
	-- NOTE: msdb..sysjobhistory.run_date is ... stupidly an int. So, we'll 'CAST' @start to int to avoid any implicit conversions.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @startInt int = CAST(CONVERT(char(8), DATEADD(DAY, 0 - 1, @start), 112) AS int);

	WITH starts AS ( 
		SELECT 
			instance_id,
			job_id, 
			step_id,
			step_name, 
			CAST((LEFT(run_date, 4) + '-' + SUBSTRING(CAST(run_date AS char(8)),5,2) + '-' + RIGHT(run_date,2) + ' ' + LEFT(REPLICATE('0', 6 - LEN(run_time)) + CAST(run_time AS varchar(6)), 2) + ':' + SUBSTRING(REPLICATE('0', 6 - LEN(run_time)) + CAST(run_time AS varchar(6)), 3, 2) + ':' + RIGHT(REPLICATE('0', 6 - LEN(run_time)) + CAST(run_time AS varchar(6)), 2)) AS datetime) AS [start_time],
			RIGHT((REPLICATE(N'0', 6) + CAST([run_duration] AS sysname)), 6) [duration]
		FROM 
			msdb.dbo.[sysjobhistory] 
		WHERE 
			[run_date] >= @startInt
	), 
	ends AS ( 
		SELECT 
			instance_id,
			job_id, 
			step_id,
			step_name, 
			[start_time], 
			CAST((LEFT([duration], 2)) AS int) * 3600 + CAST((SUBSTRING([duration], 3, 2)) AS int) * 60 + CAST((RIGHT([duration], 2)) AS int) [total_seconds]
		FROM 
			starts
	),
	normalized AS ( 
		SELECT 
			instance_id,
			job_id, 
			step_id,
			step_name, 
			start_time, 
			DATEADD(SECOND, CASE WHEN total_seconds = 0 THEN 1 ELSE [ends].[total_seconds] END, start_time) end_time, 
			LEAD(step_id) OVER (PARTITION BY job_id ORDER BY instance_id) [next_job_step_id]  -- note, this isn't 2008 compat... (and ... i don't think i care... )
		FROM 
			ends
	)

	INSERT INTO [#RunningJobs] ([job_name], [job_id], [step_name], [step_id], [start_time], [end_time])
	SELECT 
		[j].[name] [job_name],
		[n].[job_id], 
		ISNULL([js].[step_name], [n].[step_name]) [step_name],
		[n].[step_id],
		[n].[start_time],
		[n].[end_time]
	FROM 
		normalized n
		LEFT OUTER JOIN msdb.dbo.[sysjobs] j ON [n].[job_id] = [j].[job_id] -- allow this to be NULL - i.e., if we're looking for a job that ran this morning at 2AM, it's better to see that SOMETHING ran other than that a Job that existed (and ran) - but has since been deleted - 'looks' like it didn't run.
		LEFT OUTER JOIN msdb.dbo.[sysjobsteps] js ON [n].[job_id] = [js].[job_id] AND n.[step_id] = js.[step_id]
	WHERE
		[n].[step_id] <> 0 AND ( 
			[n].[start_time] <= @end 
			AND [n].[end_time] >= @start
		);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Job Predication:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
JOB_PREDICATES: 

	CREATE TABLE #ts_cp_jobs (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[job] sysname NOT NULL, 
		[exclude] bit DEFAULT(0), 
		PRIMARY KEY CLUSTERED ([exclude], [job])
	);

	IF @jobs IS NOT NULL BEGIN
		INSERT INTO #ts_cp_jobs ([job], [exclude]) 
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [job], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		FROM 
			[dbo].[split_string](@jobs, N',', 1);

		IF EXISTS (SELECT NULL FROM [#ts_cp_jobs] WHERE exclude = 0) BEGIN
			DELETE [x]
			FROM 
				[#RunningJobs] [x]
				INNER JOIN [#ts_cp_jobs] [j] ON [x].[job_name] NOT LIKE [j].[job] 
			WHERE 
				[j].[exclude] = 0;
		END;

		IF EXISTS (SELECT NULL FROM [#ts_cp_jobs] WHERE exclude = 1) BEGIN
			DELETE [x]
			FROM 
				[#RunningJobs] [x]
				INNER JOIN [#ts_cp_jobs] [j] ON [x].[job_name] LIKE [j].[job] 
			WHERE 
				[j].[exclude] = 1;
		END;
	END;
    
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- RETURN (vs PROJECT):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY...  

		SELECT @serialized_output = (
			SELECT 
				[job_name],
				[job_id],
				[step_name],
				[step_id],
				[start_time],
				[end_time], 
				CASE 
					WHEN @currentlyRunning = 1 THEN N'➡️➡️'
					WHEN [start_time] < @start AND [end_time] < @end THEN N'➡️⏹️'
					WHEN [start_time] < @start AND [end_time] > @end THEN N'➡️➡️'
					WHEN [start_time] >= @start AND [end_time] > @end THEN N'⏹️➡️'
					ELSE N'⏹️⏹️'
				END [bounds]
			FROM 
				[#RunningJobs] 
			ORDER BY 
				[start_time]
			FOR XML PATH(N'job'), ROOT(N'jobs')
		);

		RETURN 0;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- PROJECT:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT 
		[job_name],
        [job_id],
        [step_name],
		[step_id],
        [start_time],
		[end_time],
		CASE 
			WHEN @currentlyRunning = 1 THEN N'➡️➡️'
			WHEN [start_time] < @start AND [end_time] < @end THEN N'➡️⏹️'
			WHEN [start_time] < @start AND [end_time] > @end THEN N'➡️➡️'
			WHEN [start_time] >= @start AND [end_time] > @end THEN N'⏹️➡️'
			ELSE N'⏹️⏹️'
		END [bounds]
	FROM 
		[#RunningJobs]
	ORDER BY 
		[start_time];

	RETURN 0;
GO