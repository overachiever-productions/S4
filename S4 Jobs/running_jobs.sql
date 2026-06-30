/*

    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.


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
    @SerializedOutput					xml						= N'<default/>'			OUTPUT			-- when set to any non-null value (i.e., '') this will be populated with output - rather than having the output projected through the 'bottom' of the sproc (so that we can consume these details from other sprocs/etc.)
AS
	SET NOCOUNT ON; 

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Validate Inputs: 

	-- I THINK there are 2 valide ways to pass in parameters: 
	--		@start and @end are both NULL - so ... jobs RIGHT NOW. 
	--		@start is NOT NULL 
	--				at which point, we get a START date. 
	--				@END, unless otherwise specified, is GETDATE(). 

	--IF (@start IS NOT NULL AND @end IS NULL) OR (@end IS NOT NULL AND @start IS NULL) BEGIN
 --       RAISERROR('@start and @end must both either be specified - or both must be NULL (indicating that you''d like to see jobs running right now).', 16, 1);
 --       RETURN -1;
 --   END;

	IF @start IS NOT NULL AND @end < @start BEGIN
        RAISERROR('Parameter Value for @end must be greater than (or equal to) Parameter Value for @start.', 16, 1);
        RETURN -2;		
	END;

	-----------------------------------------------------------------------------
	CREATE TABLE #RunningJobs (
		row_id int IDENTITY(1,1) NOT NULL, 
		job_name sysname NOT NULL, 
		job_id uniqueidentifier NOT NULL, 
		step_id int NOT NULL,
		step_name sysname NOT NULL, 
		start_time datetime NOT NULL, 
		end_time datetime NULL, 
		completed bit NULL
	);

    -----------------------------------------------------------------------------
    -- If there's no filter, then we want jobs that are currently running (i.e., those that have started, but their stop time is NULL): 
	IF (@start IS NULL) OR (@end >= GETDATE()) BEGIN
		INSERT INTO [#RunningJobs] ( [job_name], [job_id], [step_name], [step_id], [start_time], [end_time], [completed])
		SELECT 
			j.[name] [job_name], 
			ja.job_id,
			js.[step_name] [step_name],
			js.[step_id],
			ja.[start_execution_date] [start_time], 
			NULL [end_time], 
			0 [completed]
		FROM 
			msdb.dbo.[sysjobactivity] ja 
			LEFT OUTER JOIN msdb.dbo.[sysjobhistory] jh ON [ja].[job_history_id] = [jh].[instance_id]
			INNER JOIN msdb.dbo.[sysjobs] j ON [ja].[job_id] = [j].[job_id] 
			INNER JOIN msdb.dbo.[sysjobsteps] js ON [ja].[job_id] = [js].[job_id] AND ISNULL([ja].[last_executed_step_id], 0) + 1 = [js].[step_id]
		WHERE 
			[ja].[session_id] = (SELECT TOP (1) [session_id] FROM msdb.dbo.[syssessions] ORDER BY [agent_start_date] DESC) 
			AND [ja].[start_execution_date] IS NOT NULL 
			AND [ja].[stop_execution_date] IS NULL;
	END;
	
	IF @start IS NOT NULL BEGIN
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
				-- rather than a scan of the entire table - restrict things to 1 week before the specified start date and 1 week after the specified end date... 
				[run_date] >= CAST(CONVERT(char(8), DATEADD(WEEK, 0 - @PreFilterPaddingWeeks, @StartTime), 112) AS int)
				AND 
				[run_date] <= CAST(CONVERT(char(8), DATEADD(WEEK, @PreFilterPaddingWeeks, @end), 112) AS int)
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

		INSERT INTO [#RunningJobs] ( [job_name], [job_id], [step_name], [step_id], [start_time], [end_time], [completed])
		SELECT 
			[j].[name] [job_name],
			[n].[job_id], 
			ISNULL([js].[step_name], [n].[step_name]) [step_name],
			[n].[step_id],
			[n].[start_time],
			[n].[end_time], 
			CASE WHEN [n].[next_job_step_id] = 0 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END [completed]
		FROM 
			normalized n
			LEFT OUTER JOIN msdb.dbo.[sysjobs] j ON [n].[job_id] = [j].[job_id] -- allow this to be NULL - i.e., if we're looking for a job that ran this morning at 2AM, it's better to see that SOMETHING ran other than that a Job that existed (and ran) - but has since been deleted - 'looks' like it didn't run.
			LEFT OUTER JOIN msdb.dbo.[sysjobsteps] js ON [n].[job_id] = [js].[job_id] AND n.[step_id] = js.[step_id]
		WHERE 
			n.[step_id] <> 0 AND (
				-- jobs that start/stop during specified time window... 
				(n.[start_time] >= @start AND n.[end_time] <= @end)

				-- jobs that were running when the specified window STARTS (and which may or may not end during out time window - but the jobs were ALREADY running). 
				OR (n.[start_time] < @start AND n.[end_time] > @start)

				-- jobs that get started during our time window (and which may/may-not stop during our window - because, either way, they were running...)
				OR (n.[start_time] > @start AND n.[end_time] > @end)
			)
	END;

	-- Exclude any jobs specified: 
-- this needs to be a LIKE for + and - matches ... 
	DELETE FROM [#RunningJobs] WHERE [job_name] IN (SELECT [result] FROM dbo.[split_string](@jobs, N',', 1));
    
	-- TODO: are there any expansions/details we want to join from the Jobs themselves at this point? (or any other history info?) 
	
	-----------------------------------------------------------------------------
    -- Send output as XML if requested:
	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY...  

		SELECT @SerializedOutput = (
			SELECT 
				[job_name],
				[job_id],
				[step_name],
				[step_id],
				[start_time],
				CASE WHEN [completed] = 1 THEN [end_time] ELSE NULL END [end_time], 
				CASE WHEN [completed] = 1 THEN 'COMPLETED' ELSE 'INCOMPLETE' END [job_status]
			FROM 
				[#RunningJobs] 
			ORDER BY 
				[start_time]
			FOR XML PATH('job'), ROOT('jobs')
		);

		RETURN 0;
	END;

	-----------------------------------------------------------------------------
	-- otherwise, project:
	SELECT 
		[job_name],
        [job_id],
        [step_name],
		[step_id],
        [start_time],
		CASE WHEN [completed] = 1 THEN [end_time] ELSE NULL END [end_time], 
		CASE WHEN [completed] = 1 THEN 'COMPLETED' ELSE 'INCOMPLETE' END [job_status]
	FROM 
		[#RunningJobs]
	ORDER BY 
		[start_time];

	RETURN 0;
GO