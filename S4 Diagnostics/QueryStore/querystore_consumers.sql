/*

	PICKUP / NEXT: 
		- There are a handful of 'columns' or dimensions/facets to ORDER BY (and report on) that I haven't yet 
		translated OVER from the original: 
			- D:\Dropbox\Repositories\S4\S4 Diagnostics\QueryStore\querystore_consumers.sql
		i.e., just need to identify those (the CASE on @MostExpensiveBy is a good place to start) determine the BEST way to tackle those
			AND ... then 'chase those through' to the end - i.e., at them to the initial table, and the select + insert, then the same with the SECOND dynamic sql + table + select. 
				AND then ... into the FINAL projection as well. 
					sigh. 

	vNEXT:
		- SKIM/SCAN/SHRED the latest plans (and ... all plans, frankly) 
			and look for MISSING INDEX ... then put this into a missing_ix column or whatever... 
			might even be able to create the equivalent of a smells column? 
			and/or an opportunities column? 

		- Provide an option to exclude operations like: 
			- UPDATE STATS or IX REBUILD/ETC. or BACKUP (hmm, does that execute within a given db?) ... and so on. 


		- provide an 'xml' column with a pre-configured query that can be run to get ALL plans for any queries with > 1 plan ... i.e., need to simplify 'fetching' those. 
			then... automate this too for the whole 'dump' to xls or whatever via powershell - i.e., have it go ahead and grab different plans for the same queryid? 
		
		- Add CPU_DEVIATION and DURATION_DEVIATION ... or something similar - i.e., plans/queries where the avg is nothing close to the MAX_xxx value from sys.query_store_runtime_stats
		- Could also add MOST_FAILED or CPU_FAILED or whatever... i.e., failed/aborted queries ordered by ... something.

		- ADD WAITS i.e., order by highest # of waits, descending - which i can get from sys.query_store_wait_stats ... see:
			https://docs.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver15
			example of "Highest Wait Durations"


	
		- Not really sure that the logic (sorting) for "GRANTS" is correct. 
			as in, when GRANTS are selected, then ... we sort by SUM(GRANTS) desc... 
			vs what MIGHT? make more sense ... which'd be AVG(GRANTS) desc... 
				AND... I guess I could have AVG_GRANTS or TOTAL_GRANTS as 2x different options here. 
				That same logic would make sense for ... all other options too. 


		- SQL Server 2016
			Query Store (metrics) do NOT provide info for: 
			- [avg_log_bytes_used]
			- [avg_tempdb_space_used] 
			Meaning that ... these 2x columns have to be NUKED from the original query... 
			AND that since I'm using them for avg and TOTAL (ish) ... the TOTAL versions of these have to be removed as well.

	FODDER: 
			https://docs.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver15
			https://www.mssqltips.com/sqlservertip/4047/sql-server-2016-query-store-queries/
			https://dba.stackexchange.com/questions/263998/find-specific-query-in-query-store
			https://www.sqlshack.com/performance-monitoring-via-sql-server-query-store/
			https://www.sqlshack.com/sql-server-query-store-overview/
			https://www.erikdarlingdata.com/sql-server/introducing-sp_quickiestore-find-your-worst-queries-in-query-store-fast/



	TODO:
		while I have AVG_ and TOTAL Duration and CPU ... I actuall, also, insanely, enough, also need MAX_ for both of those IF that's going to make sense ... 
			er... well, yeah... it's going to be hard to implment-ish. so much so that I might need to convert it into some OTHER func/proc... 
				e.g., say I have (contrived case) 100 query_ids. each with 10x PLANS each. 
					Now. say that 3x of those plans (randomly, among the 10000 plans available) are DOG slow or use a RIDONCULOUS amount of CPU... 
						IF I were to use THIS report ... MAX could work - as long as I also 'grabbed' the other 9x plans for each sproc/query_id (lol assuming that 1x query_id didn't have 2x, 3x, Nx of those bad plans)
						... which ... would work - i.e., the 'ALL' would show the worst offenders by MAX_CPU or MAX_DURATION
							BUT... i honestly wonder if there's not just a bettter way - i.e., "Show me the plans/queries using the MOST cpu or taking the longest" - at which point I don't care SO MUCH about the queries as I care about the plans. 
								i.e., this particular sproc is QUERY based/focused. (and I MIGHT want to name it as such). 
									whereas another sproc would be all about ... consumers (plans/executions - vs queries (i.e., query_id))

	TODO: 
		I should probably treat some of the plan details and other 'things' similar to how I'm treating 'smells' in dbo.list_database_details. 
		AND... I should determine what happens if/when I 'hint' a query vs FORCE it: 
			e.g., https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sys-sp-query-store-set-hints-transact-sql?view=sql-server-ver16#supported-query-hints

*/


USE [admindb];
GO

IF OBJECT_ID('dbo.[querystore_consumers]','P') IS NOT NULL
	DROP PROC dbo.[querystore_consumers];
GO

CREATE PROC dbo.[querystore_consumers]
	@TargetDatabase								sysname			= NULL, 
	@MostExpensiveBy							sysname			= N'AVG_DURATION',		-- { TOTAL_CPU | AVG_CPU | TOTAL_DURATION | AVG_DURATION | EXECUTIONCOUNTS | TOTAL_PHYS_READS | AVG_PHYS_READS | WRITES | ROWCOUNTS | AVG_TEMPDB | TOTAL_TEMPDB | GRANTS | TLOG | PLANCOUNTS | COMPILECOUNTS | DOP }
	@TopResults									int				= 30,
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL 
	--@ExcludeServiceBrokerQueues					bit				= 1, 
	--@ExcludeFailedAndAbortedQueries				bit				= 1
AS
    SET NOCOUNT ON; 

	SET @MostExpensiveBy = ISNULL(NULLIF(@MostExpensiveBy, N''), N'DURATION');

	IF UPPER(@MostExpensiveBy) NOT IN (N'TOTAL_CPU', N'AVG_CPU', N'TOTAL_DURATION', N'AVG_DURATION', N'EXECUTIONCOUNTS', N'TOTAL_PHYS_READS', N'AVG_PHYS_READS', N'WRITES', N'ROWCOUNTS', N'AVG_TEMPDB', N'TOTAL_TEMPDB', N'GRANTS', N'TLOG', N'PLANCOUNTS', N'COMPILECOUNTS', N'DOP') BEGIN
		RAISERROR('Allowed values for @MostExpensiveBy are { TOTAL_CPU | AVG_CPU | TOTAL_DURATION | AVG_DURATION | EXECUTIONCOUNTS | TOTAL_PHYS_READS | AVG_PHYS_READS | WRITES | ROWCOUNTS | AVG_TEMPDB | TOTAL_TEMPDB | GRANTS | TLOG | PLANCOUNTS | COMPILECOUNTS | DOP }.', 16, 1);
		RETURN -10;
	END;

	DECLARE @selector nvarchar(MAX);
	SET @selector = (SELECT 
		CASE @MostExpensiveBy 
			WHEN N'TOTAL_CPU' THEN N'[total_cpu_time]'
			WHEN N'AVG_CPU' THEN N'[avg_cpu_time]'
			WHEN N'TOTAL_DURATION' THEN N'[total_duration]'
			WHEN N'AVG_DURATION' THEN N'[avg_duration]'
			WHEN N'EXECUTIONCOUNTS' THEN N'[execution_count]'
			WHEN N'WRITES' THEN N'[avg_logical_io_writes]'
			WHEN N'AVG_PHYS_READS' THEN N'[avg_physical_reads]'
			WHEN N'TOTAL_PHYS_READS' THEN N'[total_physical_reads]'
			WHEN N'ROWCOUNTS' THEN N'[avg_rowcount]'
			WHEN N'AVG_TEMPDB' THEN N'[avg_tempdb_space_used]'
			WHEN N'TOTAL_TEMPDB' THEN N'[total_tempdb_space_used]'
			WHEN N'GRANTS' THEN N'[avg_used_memory]'
			WHEN N'TLOG' THEN N'[avg_log_bytes_used]'
			WHEN N'PLANCOUNTS' THEN N'[plan_count]'
			WHEN N'COMPILECOUNTS' THEN N'[compile_count]'
			WHEN N'DOP' THEN N'[max_dop]'
			ELSE NULL
		END);
	
	IF @selector IS NULL BEGIN 
		RAISERROR(N'Framework Error. %s has not had an ORDER BY clause defined.', 16, 1, @MostExpensiveBy);
		RETURN -20;
	END;

	DECLARE @sql nvarchar(MAX); 
	DECLARE @startTime datetime, @endTime datetime; 

	SET @sql = N'SELECT 
		@startTime = CAST(MIN(start_time) AS datetime), 
		@endTime = CAST(MAX(end_time) AS datetime) 
	FROM 
		[{targetDB}].sys.[query_store_runtime_stats_interval]; ';
	
	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	EXEC sys.[sp_executesql]
		@sql, 
		N'@startTime datetime OUTPUT, @endTime datetime OUTPUT', 
		@startTime = @startTime OUTPUT,
		@endTime = @endTime OUTPUT;

	DECLARE @where nvarchar(MAX) = N'';

	IF @OptionalEndTime IS NOT NULL BEGIN
		IF @OptionalEndTime < @endTime
			SET @endTime = @OptionalEndTime;
	END

	IF @OptionalStartTime IS NOT NULL BEGIN
		IF @OptionalStartTime > @startTime 
			SET @startTime = @OptionalStartTime;
	END;

	CREATE TABLE #queryAggregatedStats (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[query_id] bigint NOT NULL,
		[plan_id] bigint NOT NULL DEFAULT (-1),
		[plan_count] int NOT NULL,
		[compile_count] bigint NOT NULL,
		[execution_count] bigint NOT NULL,
		[avg_cpu_time] float NOT NULL,
		[total_cpu_time] float NOT NULL,
		[avg_duration] float NOT NULL,
		[total_duration] float NOT NULL,
		--[avg_logical_reads] float NOT NULL,
		--[total_logical_reads] float NOT NULL,
		[avg_writes] float NOT NULL,
		[total_writes] float NOT NULL,
		[avg_physical_reads] float NOT NULL,
		[total_physical_reads] float NOT NULL,
		[avg_used_memory] float NOT NULL,
		[total_used_memory] float NOT NULL,
		[avg_rowcount] float NOT NULL,
		--[total_rowcount] float NOT NULL,
		[avg_log_bytes_used] float NULL,
		[total_log_bytes_used] float NULL,
		[avg_tempdb_space_used] float NULL,
		[total_tempdb_space_used] float NULL,
		[max_dop] bigint NOT NULL
	);

	SET @sql = N'WITH core AS ( 
	SELECT
		[p].[query_id],
		COUNT(DISTINCT [s].[plan_id]) [plan_count],
		SUM([p].[count_compiles]) [compile_count],
		SUM([s].[count_executions]) [execution_count],
		AVG([s].[avg_cpu_time]) [avg_cpu_time], 
		SUM([s].[avg_cpu_time] * [s].[count_executions]) [total_cpu_time],
		AVG([s].[avg_duration]) [avg_duration],
		SUM([s].[avg_duration] * [s].[count_executions]) [total_duration],
		AVG([s].[avg_logical_io_writes]) [avg_writes],
		SUM([s].[avg_logical_io_writes] * [s].[count_executions]) [total_writes],
		AVG([s].[avg_physical_io_reads]) [avg_physical_reads],
		SUM([s].[avg_physical_io_reads] * [s].[count_executions]) [total_physical_reads],
		AVG([s].[avg_query_max_used_memory]) [avg_used_memory],
		SUM([s].[avg_query_max_used_memory] * [s].[count_executions]) [total_used_memory],
		AVG([s].[avg_rowcount]) [avg_rowcount],
		AVG([s].[avg_log_bytes_used]) [avg_log_bytes_used],
		SUM([s].[avg_log_bytes_used] * [s].[count_executions]) [total_log_bytes_used],
		AVG([s].[avg_tempdb_space_used]) [avg_tempdb_space_used], 
		SUM([s].[avg_tempdb_space_used] * [s].[count_executions]) [total_tempdb_space_used],
		MAX([s].[max_dop]) [max_dop]
	FROM 
		[{targetDB}].sys.[query_store_runtime_stats] [s]
		LEFT OUTER JOIN [{targetDB}].sys.[query_store_plan] [p] ON [s].[plan_id] = [p].[plan_id]
	WHERE 
		[p].[query_id] IS NOT NULL
		AND NOT ([s].[first_execution_time] > @endTime OR [s].[last_execution_time] < @startTime)
	GROUP BY 
		[p].[query_id]
)

SELECT TOP (@TopResults)
	[query_id],
	[plan_count],
	[compile_count],
	[execution_count],
	[avg_cpu_time],
	[total_cpu_time],
	[avg_duration],
	[total_duration],
	[avg_writes],
	[total_writes],
	[avg_physical_reads], 
	[total_physical_reads],
	[avg_used_memory],
	[total_used_memory],
	[avg_rowcount],
	[avg_log_bytes_used], 
	[total_log_bytes_used],
	[avg_tempdb_space_used],
	[total_tempdb_space_used],
	[max_dop]
FROM 
	core
ORDER BY 
	{sortBy} DESC; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{where}', @where);
	SET @sql = REPLACE(@sql, N'{sortBy}', @selector);

	INSERT INTO [#queryAggregatedStats]
	(
		[query_id],
		[plan_count],
		[compile_count],
		[execution_count],
		[avg_cpu_time],
		[total_cpu_time],
		[avg_duration],
		[total_duration],
		[avg_writes],
		[total_writes],
		[avg_physical_reads], 
		[total_physical_reads],
		[avg_used_memory],
		[total_used_memory],
		[avg_rowcount],
		[avg_log_bytes_used], 
		[total_log_bytes_used],
		[avg_tempdb_space_used],
		[total_tempdb_space_used],
		[max_dop]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@TopResults int, @startTime datetime, @endTime datetime', 
		@TopResults = @TopResults,
		@startTime = @startTime, 
		@endTime = @endTime;


	CREATE TABLE #planAggregatedStats (
		[row_id] int NOT NULL,
		[query_id] bigint NOT NULL,
		[plan_id] bigint NOT NULL,
		[plan_count] int NOT NULL,
		[compile_count] bigint NOT NULL,
		[execution_count] bigint NOT NULL,
		[avg_cpu_time] float NOT NULL,
		[total_cpu_time] float NOT NULL,
		[avg_duration] float NOT NULL,
		[total_duration] float NOT NULL,
		--[avg_logical_reads] float NOT NULL,
		--[total_logical_reads] float NOT NULL,
		[avg_writes] float NOT NULL,
		[total_writes] float NOT NULL,
		[avg_physical_reads] float NOT NULL,
		[total_physical_reads] float NOT NULL,
		[avg_used_memory] float NOT NULL,
		[total_used_memory] float NOT NULL,
		[avg_rowcount] float NOT NULL,
		--[total_rowcount] float NOT NULL,
		[avg_log_bytes_used] float NULL,
		[total_log_bytes_used] float NULL,
		[avg_tempdb_space_used] float NULL,
		[total_tempdb_space_used] float NULL,
		[max_dop] bigint NOT NULL--,
		--[min_dop] bigint NOT NULL
	);

	SET @sql = N'SELECT 
	[x].[row_id],
	[x].[query_id],
	[p].[plan_id], 
	MAX([x].[plan_count]) [plan_count],
	SUM([p].[count_compiles]) [compile_count],
	SUM([s].[count_executions]) [execution_count],
	SUM([s].[avg_cpu_time]) [avg_cpu_time], 
	SUM([s].[avg_cpu_time] * [s].[count_executions]) [total_cpu_time],
	SUM([s].[avg_duration]) [avg_duration],
	SUM([s].[avg_duration] * [s].[count_executions]) [total_duration],
	SUM([s].[avg_logical_io_writes]) [avg_writes],
	SUM([s].[avg_logical_io_writes] * [s].[count_executions]) [total_writes],
	SUM([s].[avg_physical_io_reads]) [avg_physical_reads],
	SUM([s].[avg_physical_io_reads] * [s].[count_executions]) [total_physical_reads],
	SUM([s].[avg_query_max_used_memory]) [avg_used_memory],
	SUM([s].[avg_query_max_used_memory] * [s].[count_executions]) [total_used_memory],
	SUM([s].[avg_rowcount]) [avg_rowcount],
	SUM([s].[avg_log_bytes_used]) [avg_log_bytes_used],
	SUM([s].[avg_log_bytes_used] * [s].[count_executions]) [total_log_bytes_used],
	SUM([s].[avg_tempdb_space_used]) [avg_tempdb_space_used], 
	SUM([s].[avg_tempdb_space_used] * [s].[count_executions]) [total_tempdb_space_used],
	MAX([s].[max_dop]) [max_dop]
FROM 
	[#queryAggregatedStats] [x]
	INNER JOIN [{targetDB}].sys.[query_store_plan] [p] ON [x].[query_id] = [p].[query_id]
	INNER JOIN {targetDB}.sys.[query_store_runtime_stats] [s] ON [p].[plan_id] = [s].[plan_id]
GROUP BY 
	[x].[row_id], 
	[x].[query_id], 
	[p].[plan_id]
ORDER BY 
	[x].[row_id]; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	INSERT INTO [#planAggregatedStats]
	(
		[row_id],
		[query_id],
		[plan_id],
		[plan_count],
		[compile_count],
		[execution_count],
		[avg_cpu_time],
		[total_cpu_time],
		[avg_duration],
		[total_duration],
		[avg_writes],
		[total_writes],
		[avg_physical_reads], 
		[total_physical_reads],
		[avg_used_memory],
		[total_used_memory],
		[avg_rowcount],
		[avg_log_bytes_used], 
		[total_log_bytes_used],
		[avg_tempdb_space_used],
		[total_tempdb_space_used],
		[max_dop]
	)
	EXEC sys.sp_executesql 
		@sql;

	CREATE TABLE #context ( 
		[row_id] int NOT NULL, 
		[module] sysname NULL,
		[query_text] nvarchar(MAX) NULL 
	); 

	SET @sql = N'SELECT 
	[x].[row_id],
	[o].[name] [module],
	[t].[query_sql_text]
FROM 
	[#queryAggregatedStats] [x]
	LEFT OUTER JOIN [{targetDB}].sys.[query_store_query] q ON [x].[query_id] = [q].[query_id]
	LEFT OUTER JOIN [{targetDB}].sys.[query_store_query_text] t ON [q].[query_text_id] = [t].[query_text_id]
	LEFT OUTER JOIN [{targetDB}].sys.[objects] [o] ON [q].[object_id] = [o].[object_id]; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	INSERT INTO #context (
		[row_id],
		[module],
		[query_text]
	)
	EXEC sys.[sp_executesql]
		@sql;

	CREATE TABLE #executionPlans ( 
		[row_id] int NOT NULL, 
		[plan_id] bigint NOT NULL, 
		[query_plan] nvarchar(MAX) NOT NULL, 
		[query_plan_xml] xml NULL,
		[trivial] bit NOT NULL, 
		[parallel] bit NOT NULL, 
		[last_execution_time] datetime NULL, -- downcasting... 
		[avg_compile_duration] float NOT NULL, 
		[forced] bit NOT NULL, 
		[force_failure_count] bigint NOT NULL, 
		[last_force_failure] nvarchar(128) NULL,  -- defaults to NONE but if MS every changes this ... then ... yeah. 
		[plan_forcing_type] nvarchar(60) NULL -- ditto. 
	); 

	SET @sql = N'SELECT 
		[x].[row_id], 
		[p].[plan_id], 
		[p].[query_plan], 
		[p].[is_trivial_plan], 
		[p].[is_parallel_plan], 
		[p].[last_execution_time],
		[p].[avg_compile_duration], 
		[p].[is_forced_plan], 
		[p].[force_failure_count], 
		[p].[last_force_failure_reason_desc], 
		[p].[plan_forcing_type_desc]
	FROM 
		[#planAggregatedStats] [x]
		INNER JOIN [{targetDB}].sys.[query_store_plan] [p] ON [x].[plan_id] = [p].[plan_id]; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	INSERT INTO [#executionPlans]
	(
		[row_id],
		[plan_id],
		[query_plan],
		[trivial],
		[parallel],
		[last_execution_time],
		[avg_compile_duration],
		[forced],
		[force_failure_count],
		[last_force_failure],
		[plan_forcing_type]
	)
	EXEC sys.[sp_executesql]
		@sql;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- XML Conversion / Shredding / etc. 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#executionPlans] 
	SET 
		[query_plan_xml] = CASE 
			WHEN TRY_CAST([query_plan] AS xml) IS NULL THEN (SELECT NCHAR(13) + NCHAR(10) + NCHAR(9) + N'This plan is too large to display. Remove the TOP line, and the BOTTOM line, then save as .sqlplan and open.' + NCHAR(13) + NCHAR(10) +
			REPLACE([query_plan], N'</ShowPlanXML>', N'</ShowPlanXML>' + NCHAR(13) + NCHAR(10)) [processing-instruction(Plan_Too_Large)] FOR XML PATH(N''), TYPE) 
			ELSE TRY_CAST([query_plan] AS xml)
		END
	WHERE
		[query_plan_xml] IS NULL;

	WITH rolledup AS ( 
		SELECT 
			*
		FROM 
			[#planAggregatedStats] WHERE [plan_count] > 1

		UNION 

		SELECT 
			*
		FROM  
			 [#queryAggregatedStats]
	), 
	lagged AS ( 
		SELECT 
			[row_id],
			LAG([rolledup].[row_id], 1) OVER (ORDER BY [rolledup].[row_id]) [x],
			[query_id],
			[plan_id],
			[plan_count],
			[compile_count],
			[execution_count],
			[avg_cpu_time],
			[total_cpu_time],
			[avg_duration],
			[total_duration],
			[avg_writes],
			[total_writes],
			[avg_physical_reads],
			[total_physical_reads],
			[avg_used_memory],
			[total_used_memory],
			[avg_rowcount],
			[avg_log_bytes_used], 
			[total_log_bytes_used],
			[avg_tempdb_space_used],
			[total_tempdb_space_used],
			[max_dop],
			CASE 
				WHEN [plan_count] > 1 THEN [plan_id]
				WHEN [plan_id] = -1 AND [plan_count] = 1 THEN (SELECT [plan_id] FROM [#planAggregatedStats] [p] WHERE [p].[row_id] = [rolledup].[row_id] AND [p].[plan_id] = [rolledup].[plan_id]) 
				ELSE NULL 
			END [actual_plan_id]
		FROM 
			[rolledup] 
	) 

	SELECT 
		CASE WHEN [l].[row_id] = [l].[x] THEN N'' ELSE CAST([l].[row_id] AS sysname) END [rank],
		CASE WHEN [l].[row_id] = [l].[x] THEN N'' ELSE CAST([l].[query_id] AS sysname) END [query_id],
		
		CASE 
			WHEN [l].[plan_count] > 1 AND [l].[plan_id] = -1 THEN 'ALL' 
			WHEN [l].[plan_count] = 1 AND [l].[plan_id] = -1 THEN CAST(l.[actual_plan_id] AS sysname)
			ELSE N'    ' + CAST([l].[plan_id] AS sysname) 
		END [plan_id], 

		CASE WHEN [l].[row_id] = [l].[x] THEN N'' ELSE ISNULL([c].[module], N'') END [module],
		CASE WHEN [l].[row_id] = [l].[x] THEN N'' ELSE ISNULL([c].[query_text], N'') END [query_text],

		[l].[compile_count],
		[l].[execution_count],
		CAST(([l].[avg_cpu_time] / 1000.0) AS decimal(24,2)) [avg_cpu_time_ms],
		CAST(([l].[total_cpu_time] / 1000.0) AS decimal(24,2)) [total_cpu_time_ms],
		CAST(([l].[avg_duration] / 1000.0) AS decimal(24,2)) [avg_duration_ms],
		CAST(([l].[total_duration] / 1000.0) AS decimal(24,2)) [total_duration_ms],

		CAST(([l].[avg_writes] * 8.0 / 1048576) AS decimal(24,2)) [avg_writes],
		CAST(([l].[total_writes] * 8.0 / 1048576) AS decimal(24,2)) [total_writes],


		CAST(([l].[avg_physical_reads] * 8.0 / 1048576) AS decimal(24,2)) [avg_physical_reads],
		CAST(([l].[total_physical_reads] * 8.0 / 1048576) AS decimal(24,2)) [total_physical_reads],

		CAST(([l].[avg_used_memory] * 8.0 / 1048576) AS decimal(24,2)) [avg_used_memory],
		CAST(([l].[total_used_memory] * 8.0 / 1048576) AS decimal(24,2)) [total_used_memory],
		CAST(([l].[avg_rowcount]) AS decimal(24,2)) [avg_rowcount],

		CAST(([l].[avg_log_bytes_used] * 8.0 / 1048576) AS decimal(24,2)) [avg_log_used],
		CAST(([l].[total_log_bytes_used] * 8.0 / 1048576) AS decimal(24,2)) [total_log_used],

		CAST(([l].[avg_tempdb_space_used] * 8.0 / 1048576) AS decimal(24,2)) [avg_tempdb_space_used],
		CAST(([l].[total_tempdb_space_used] * 8.0 / 1048576) AS decimal(24,2)) [total_tempdb_space_used],
		[l].[max_dop], 
		[p].[query_plan_xml] [query_plan]
	FROM 
		[lagged] [l]
		LEFT OUTER JOIN [#context] [c] ON [l].[row_id] = c.[row_id]
		LEFT OUTER JOIN [#executionPlans] [p] ON [l].[actual_plan_id] = [p].[plan_id]
	ORDER BY 
		[l].[row_id]; 

	RETURN 0;
GO