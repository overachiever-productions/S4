/*

	PICKUP / NEXT: 
		at some point, I started a full-on rewrite of this pig to enable GROUP BY ... query_id and plan_id ... (which took some doing). 
			so that I could break out the results by QUERY > PLAN ... 
				i.e., with my 'special' multi-line kind of results thingy... (same as I do with ... blocked processes and such). 
		ONLY... i never actually finished the implementation . 
			i.e., 
				here's what I need to do: 
					a. finish the overall logic (cross-check and verify that it's all good). 
					b. extract plans. 
					c. JOIN plans into the final results. 

	vNEXT: 
		actually, i 100% need a MAX_duration and MAX_CPU set of columns. 
			and the option to SORT BY these. 
			These, of course, would be initially aggreated as MAX(max_cpu) or whatever...
		With the idea being that I could then look for really long-running or problematic operations. 
		MIGHT even potentially make sense to do this with MEMORY usage, spills, and logging? 


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



	vNEXT:
		- Not really sure that the logic (sorting) for "GRANTS" is correct. 
			as in, when GRANTS are selected, then ... we sort by SUM(GRANTS) desc... 
			vs what MIGHT? make more sense ... which'd be AVG(GRANTS) desc... 
				AND... I guess I could have AVG_GRANTS or TOTAL_GRANTS as 2x different options here. 
				That same logic would make sense for ... all other options too. 


	SQL Server 2016
		Query Store (metrics) do NOT provide info for: 
		- [avg_log_bytes_used]
		- [avg_tempdb_space_used] 
		Meaning that ... these 2x columns have to be NUKED from the original query... 
		AND that since I'm using them for avg and TOTAL (ish) ... the TOTAL versions of these have to be removed as well.



	TODO: 
		- there's a fun BUG with XML ... 
			as in, run: 

						EXEC [admindb].dbo.[view_querystore_consumers]
							@TargetDatabase = N'TS_NA1_Clone', 
							@MostExpensiveBy = N'GRANTS'

			And it'll throw: 
				Msg 6335, Level 16, State 101, Procedure admindb.dbo.view_querystore_consumers, Line 314 [Batch Start Line 0]
				XML datatype instance has too many levels of nested nodes. Maximum allowed depth is 128 levels.
			Which is happening when trying to cast the nvarchar(MAX) plan to ... xml... 
					so... i might need to ... try and just grab the plan_handle instead? 



	SAMPLE EXECUTION:
				EXEC [admindb].dbo.[querystore_consumers]
					@TargetDatabase = N'Billing', 
					@MostExpensiveBy = N'DURATION';




	FODDER: 
			https://docs.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver15
			https://www.mssqltips.com/sqlservertip/4047/sql-server-2016-query-store-queries/
			https://dba.stackexchange.com/questions/263998/find-specific-query-in-query-store
			https://www.sqlshack.com/performance-monitoring-via-sql-server-query-store/
			https://www.sqlshack.com/sql-server-query-store-overview/
			https://www.erikdarlingdata.com/sql-server/introducing-sp_quickiestore-find-your-worst-queries-in-query-store-fast/

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[querystore_consumers]','P') IS NOT NULL
	DROP PROC dbo.[querystore_consumers];
GO

CREATE PROC dbo.[querystore_consumers]
	@TargetDatabase								sysname			= NULL, 
	@MostExpensiveBy							sysname			= N'DURATION',		-- { CPU | DURATION | EXECUTIONCOUNTS | READS | WRITES | ROWCOUNTS | TEMPDB | GRANTS | TLOG | PLANCOUNTS | COMPILECOUNTS | DOP }
	@TopResults									int				= 30,
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL
	
	--@ExcludeServiceBrokerQueues					bit				= 1, 
	--@ExcludeFailedAndAbortedQueries				bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @MostExpensiveBy = ISNULL(NULLIF(@MostExpensiveBy, N''), N'DURATION');

	IF UPPER(@MostExpensiveBy) NOT IN (N'CPU', N'DURATION', N'EXECUTIONCOUNTS', N'READS', N'WRITES', N'ROWCOUNTS', N'TEMPDB', N'GRANTS', N'TLOG', N'PLANCOUNTS', N'COMPILECOUNTS', N'DOP') BEGIN
		RAISERROR('Allowed values for @MostExpensiveBy are { CPU | DURATION | EXECUTIONCOUNTS | READS | WRITES | ROWCOUNTS | TEMPDB | GRANTS | TLOG | PLANCOUNTS | COMPILECOUNTS | DOP }.', 16, 1);
		RETURN -10;
	END;

	-- meh: 
	IF UPPER(@MostExpensiveBy) = N'COMPILECOUNTS' BEGIN 
		RAISERROR('Sorry, COMPILECOUNTS is not YET implemented.', 16, 1);
		RETURN -11;
	END;

	DECLARE @orderBy sysname;
	SET @orderBy = (SELECT 
		CASE @MostExpensiveBy 
			WHEN N'CPU' THEN N'[total_cpu_time]'
			WHEN N'DURATION' THEN N'[total_duration]'
			WHEN N'EXECUTIONCOUNTS' THEN N'[executions_count]'
			WHEN N'READS' THEN N'[total_logical_reads]'
			WHEN N'WRITES' THEN N'[total_logical_writes]'
			WHEN N'ROWCOUNTS' THEN N'[total_rowcount]'   
			WHEN N'TEMPDB' THEN N'[total_tempdb_space_used]'
			WHEN N'GRANTS' THEN N'[total_used_memory]'
			WHEN N'TLOG' THEN N'[total_log_bytes_used]'
			WHEN N'PLANCOUNTS' THEN N'[plans_count]'
			WHEN N'COMPILECOUNTS' THEN N'[compiles_count]'
			WHEN N'DOP' THEN N'[max_dop]'
			ELSE NULL
		END);
	
	IF @orderBy IS NULL BEGIN 
		RAISERROR('S4 Framework Error. %s has not had an ORDER BY clause defined.', 16, 1, @MostExpensiveBy);
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

	IF @OptionalStartTime IS NOT NULL BEGIN 
		IF @OptionalStartTime > @startTime 
			SET @startTime = @OptionalStartTime;
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF @OptionalEndTime < @endTime
			SET @endTime = @OptionalEndTime;
	END;

	CREATE TABLE #TopQueryStoreStats (
		[row_id] int IDENTITY(1, 1) NOT NULL,
		[query_id] bigint NOT NULL,
		--[plan_id] bigint NOT NULL,
		[plans_count] int NOT NULL,
		[compiles_count] bigint NOT NULL,
		[executions_count] bigint NOT NULL,
		[avg_cpu_time] float NOT NULL,
		[total_cpu_time] float NOT NULL,
		[max_cpu_time] float NOT NULL,
		[avg_duration] float NOT NULL,
		[total_duration] float NOT NULL,
		[max_duration] float NOT NULL,
		[avg_logical_reads] float NOT NULL,
		[total_logical_reads] float NOT NULL,
		[avg_logical_writes] float NOT NULL,
		[total_logical_writes] float NOT NULL,
		[avg_physical_reads] float NOT NULL,
		[total_physical_reads] float NOT NULL,
		[avg_used_memory] float NOT NULL,
		[total_used_memory] float NOT NULL,
		[avg_rowcount] float NOT NULL,
		[total_rowcount] float NOT NULL,
		[avg_log_bytes_used] float NULL,
		[total_log_bytes_used] float NULL,
		[avg_tempdb_space_used] float NULL,
		[total_tempdb_space_used] float NULL,
		[max_dop] bigint NOT NULL,
		[min_dop] bigint NOT NULL
	);

	SET @sql = N'WITH core AS ( 
	SELECT 
		[p].[query_id],
		--[p].[plan_id],
		COUNT(DISTINCT [s].[plan_id]) [plans_count],
		MAX([p].[count_compiles]) [compiles_count],  
		SUM([s].[count_executions]) [executions_count],
		AVG([s].[avg_cpu_time]) [avg_cpu_time],
		AVG([s].[avg_cpu_time]) * SUM([s].[count_executions]) [total_cpu_time],
		MAX([s].[max_cpu_time]) [max_cpu_time],
		AVG([s].[avg_duration]) [avg_duration],
		AVG([s].[avg_duration]) * SUM([s].[count_executions]) [total_duration],
		MAX([s].[max_duration]) [max_duration],
		AVG([s].[avg_logical_io_reads]) [avg_logical_reads],
		AVG([s].[avg_logical_io_reads]) * SUM([s].[count_executions]) [total_logical_reads],
		AVG([s].[avg_logical_io_writes]) [avg_logical_writes],
		AVG([s].[avg_logical_io_writes]) * SUM([s].[count_executions]) [total_logical_writes],
		AVG([s].[avg_physical_io_reads]) [avg_physical_reads],
		AVG([s].[avg_physical_io_reads]) * SUM([s].[count_executions]) [total_physical_reads],
		AVG([s].[avg_query_max_used_memory]) [avg_used_memory],
		AVG([s].[avg_query_max_used_memory]) * SUM([s].[count_executions]) [total_used_memory],
		AVG([s].[avg_rowcount]) [avg_rowcount],
		AVG([s].[avg_rowcount]) * SUM([s].[count_executions]) [total_rowcount],
		AVG([s].[avg_log_bytes_used]) [avg_log_bytes_used],
		AVG([s].[avg_log_bytes_used]) * SUM([s].[count_executions]) [total_log_bytes_used],
		AVG([s].[avg_tempdb_space_used]) [avg_tempdb_space_used], 
		AVG([s].[avg_tempdb_space_used]) * SUM([s].[count_executions]) [total_tempdb_space_used],
		MAX([s].[max_dop]) [max_dop], 
		MIN([s].[min_dop]) [min_dop]
	FROM 
		[{targetDB}].sys.[query_store_runtime_stats] [s]
		LEFT OUTER JOIN [{targetDB}].sys.[query_store_plan] [p] ON [s].[plan_id] = [p].[plan_id]
	WHERE 
		NOT ([s].[first_execution_time] > @endTime OR [s].[last_execution_time] < @startTime)
	GROUP BY 
		[p].[query_id]--, 
		--[p].[plan_id]
) 

SELECT TOP (@TopResults)
	[query_id],
	--[plan_id],
	[plans_count],
	[compiles_count],
	[executions_count],
	[avg_cpu_time],
	[total_cpu_time],
	[max_cpu_time],
	[avg_duration],
	[total_duration],
	[max_duration],
	[avg_logical_reads],
	[total_logical_reads],
	[avg_logical_writes],
	[total_logical_writes],
	[avg_physical_reads],
	[total_physical_reads],
	[avg_used_memory],
	[total_used_memory],
	[avg_rowcount],
	[total_rowcount],
	[avg_log_bytes_used],
	[total_log_bytes_used],
	[avg_tempdb_space_used],
	[total_tempdb_space_used],
	[max_dop],
	[min_dop] 
FROM 
	core 
ORDER BY 
	{orderBy} DESC; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{orderBy}', @orderBy);

	INSERT INTO [#TopQueryStoreStats] (
		[query_id],
		--[plan_id],
		[plans_count],
		[compiles_count],
		[executions_count],
		[avg_cpu_time],
		[total_cpu_time],
		[max_cpu_time],
		[avg_duration],
		[total_duration],
		[max_duration],
		[avg_logical_reads],
		[total_logical_reads],
		[avg_logical_writes],
		[total_logical_writes],
		[avg_physical_reads],
		[total_physical_reads],
		[avg_used_memory],
		[total_used_memory],
		[avg_rowcount],
		[total_rowcount],
		[avg_log_bytes_used],
		[total_log_bytes_used],
		[avg_tempdb_space_used],
		[total_tempdb_space_used],
		[max_dop],
		[min_dop]
	)
	EXEC sys.[sp_executesql] 
		@sql, 
		N'@TopResults int, @startTime datetime, @endTime datetime', 
		@TopResults = @TopResults,
		@startTime = @startTime, 
		@endTime = @endTime;

	CREATE TABLE #context ( 
		[row_id] int NOT NULL, 
		[query_id] bigint NOT NULL,
		--[most_recent_plan] nvarchar(MAX) NULL, 
		[module] sysname NULL,
		[query_text] nvarchar(MAX) NULL 
	); 

	SET @sql = N'SELECT 
	[x].[row_id],
	[x].[query_id],
	--(SELECT TOP (1) p.[query_plan] FROM [{targetDB}].sys.[query_store_plan] p WHERE p.[query_id] = x.[query_id] ORDER BY [plan_id] DESC) [most_recent_plan], 
	[o].[name] [module],
	[t].[query_sql_text]
FROM 
	[#TopQueryStoreStats] [x]
	LEFT OUTER JOIN [{targetDB}].sys.[query_store_query] q ON [x].[query_id] = [q].[query_id]
	LEFT OUTER JOIN [{targetDB}].sys.[query_store_query_text] t ON [q].[query_text_id] = [t].[query_text_id]
	LEFT OUTER JOIN [{targetDB}].sys.[objects] [o] ON [q].[object_id] = [o].[object_id]; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	INSERT INTO #context (
		[row_id],
		[query_id],
		[module],
		[query_text]
	)
	EXEC sys.[sp_executesql]
		@sql;

	CREATE TABLE #plans (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[plan_id] bigint NOT NULL, 
		[plan] nvarchar(MAX) NOT NULL, 
		[is_trivial_plan] bit NOT NULL, 
		[is_parallel] bit NOT NULL, 
		[last_execution_time] datetime NOT NULL, -- downcasting... 
		[count_compiles] bigint NOT NULL, 
		[avg_compile_duration] float NOT NULL, 
		[is_forced_plan] bit NOT NULL, 
		[force_failure_count] bigint NOT NULL, 
		[last_force_failure_reason_desc] nvarchar(128) NULL,  -- defaults to NONE but if MS every changes this ... then ... yeah. 
		[plan_forcing_type_desc] nvarchar(60) NULL -- ditto. 
	);

	SET @sql = N'SELECT 
	[p].[plan_id],
	[p].[query_plan],
	[p].[is_trivial_plan],
	[p].[is_parallel_plan] [is_parallel],
	[p].[last_execution_time],
	[p].[count_compiles],
	[p].[avg_compile_duration],
	[p].[is_forced_plan],
	[p].[force_failure_count],
	[p].[last_force_failure_reason_desc],
	[p].[plan_forcing_type_desc]
FROM 
	[{targetDB}].sys.[query_store_plan] [p]
	INNER JOIN [#TopQueryStoreStats] [x] ON [p].[plan_id] = [x].[plan_id]; ';

	--SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	--INSERT INTO [#plans]
	--(
	--	[plan_id],
	--	[plan],
	--	[is_trivial_plan],
	--	[is_parallel],
	--	[last_execution_time],
	--	[count_compiles],
	--	[avg_compile_duration],
	--	[is_forced_plan],
	--	[force_failure_count],
	--	[last_force_failure_reason_desc],
	--	[plan_forcing_type_desc]
	--)
	--EXEC sys.sp_executesql 
	--	@sql;
	

-- PICKUP / NEXT ... this SELECT on down to the RETURN 0 was uncommented... 

--		SELECT 
--			[x].[row_id],
--			[x].[query_id],
--			[c].[query_text], 
--			[c].[module],
--			--TRY_CAST([d].[most_recent_plan] AS xml) [query_plan],
--[x].[plans_count],
--			[x].[compiles_count],
--			[x].[executions_count],
--			CAST(([x].[avg_duration] / 1000.0) AS decimal(24,2)) [avg_duration_ms],
--			CAST(([x].[total_duration] / 1000.0) AS decimal(24,2)) [total_duration_ms],
--			CAST(([x].[avg_cpu_time] / 1000.0) AS decimal(24,2)) [avg_cpu_time_ms],
--			CAST(([x].[total_cpu_time] / 1000.0) AS decimal(24,2)) [total_cpu_time_ms],
--			CAST(([x].[avg_logical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [avg_logical_reads],
--			CAST(([x].[total_logical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [total_logical_reads],
--			CAST(([x].[avg_logical_writes] * 8.0 / 1073741824) AS decimal(24,2)) [avg_logical_writes],
--			CAST(([x].[total_logical_writes] * 8.0 / 1073741824) AS decimal(24,2)) [total_logical_writes],
--			CAST(([x].[avg_physical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [avg_physical_reads],
--			CAST(([x].[total_physical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [total_physical_reads],
--			CAST(([x].[avg_used_memory] * 8.0 / 1073741824) AS decimal(24,2)) [avg_used_memory],
--			CAST(([x].[total_used_memory] * 8.0 / 1073741824) AS decimal(24,2)) [total_used_memory],
--			CAST(([x].[avg_rowcount]) AS decimal(24,2)) [avg_rowcount],
--			CAST(([x].[total_rowcount]) AS decimal(24,2)) [total_rowcount],
--			CAST(([x].[avg_log_bytes_used] / 1073741824.0) AS decimal(24,2)) [avg_log_bytes_used],
--			CAST(([x].[total_log_bytes_used] / 1073741824.0) AS decimal(24,2)) [total_log_bytes_used],
--			CAST(([x].[avg_tempdb_space_used] * 8.0 / 1073741824) AS decimal(24,2)) [avg_tempdb_space_used],
--			CAST(([x].[total_tempdb_space_used] * 8.0 / 1073741824) AS decimal(24,2)) [total_tempdb_space_used],
--			[x].[max_dop],
--			[x].[min_dop]
--		FROM 
--			[#TopQueryStoreStats] [x] 
--			INNER JOIN [#context] [c] ON [x].[row_id] = [c].[row_id]
--		ORDER BY 
--			[c].[row_id];

--RETURN 0;


	WITH expanded AS ( 
		SELECT 
			[x].[row_id],
			[x].[query_id],
			[c].[query_text], 
			[c].[module],
			--TRY_CAST([d].[most_recent_plan] AS xml) [query_plan],
--[x].[plans_count],
			[x].[compiles_count],
			[x].[executions_count],
			CAST(([x].[avg_duration] / 1000.0) AS decimal(24,2)) [avg_duration_ms],
			CAST(([x].[total_duration] / 1000.0) AS decimal(24,2)) [total_duration_ms],
			CAST(([x].[max_duration] / 1000.0) AS decimal(24,2)) [max_duration_ms],
			CAST(([x].[avg_cpu_time] / 1000.0) AS decimal(24,2)) [avg_cpu_time_ms],
			CAST(([x].[total_cpu_time] / 1000.0) AS decimal(24,2)) [total_cpu_time_ms],
			CAST(([x].[max_cpu_time] / 1000.0) AS decimal(24,2)) [max_cpu_time_ms],
			CAST(([x].[avg_logical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [avg_logical_reads],
			CAST(([x].[total_logical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [total_logical_reads],
			CAST(([x].[avg_logical_writes] * 8.0 / 1073741824) AS decimal(24,2)) [avg_logical_writes],
			CAST(([x].[total_logical_writes] * 8.0 / 1073741824) AS decimal(24,2)) [total_logical_writes],
			CAST(([x].[avg_physical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [avg_physical_reads],
			CAST(([x].[total_physical_reads] * 8.0 / 1073741824) AS decimal(24,2)) [total_physical_reads],
			CAST(([x].[avg_used_memory] * 8.0 / 1073741824) AS decimal(24,2)) [avg_used_memory],
			CAST(([x].[total_used_memory] * 8.0 / 1073741824) AS decimal(24,2)) [total_used_memory],
			CAST(([x].[avg_rowcount]) AS decimal(24,2)) [avg_rowcount],
			CAST(([x].[total_rowcount]) AS decimal(24,2)) [total_rowcount],
			CAST(([x].[avg_log_bytes_used] / 1073741824.0) AS decimal(24,2)) [avg_log_bytes_used],
			CAST(([x].[total_log_bytes_used] / 1073741824.0) AS decimal(24,2)) [total_log_bytes_used],
			CAST(([x].[avg_tempdb_space_used] * 8.0 / 1073741824) AS decimal(24,2)) [avg_tempdb_space_used],
			CAST(([x].[total_tempdb_space_used] * 8.0 / 1073741824) AS decimal(24,2)) [total_tempdb_space_used],
			[x].[max_dop],
			[x].[min_dop]
		FROM 
			[#TopQueryStoreStats] [x] 
			INNER JOIN [#context] [c] ON [x].[row_id] = [c].[row_id]
	)

	SELECT 
		[query_id],
		[executions_count] [execution_count],
		dbo.format_timespan([avg_duration_ms]) [avg_duration],
		dbo.format_timespan([total_duration_ms]) [total_duration],
		dbo.format_timespan([max_duration_ms]) [max_duration],
		dbo.format_timespan([avg_cpu_time_ms]) [avg_cpu_time],
		dbo.format_timespan([total_cpu_time_ms]) [total_cpu_time],
		dbo.format_timespan([max_cpu_time_ms]) [max_cpu_time],
		[module] [module_name],
		[query_text],
		
		--CASE WHEN [query_plan] IS NULL THEN (SELECT [most_recent_plan] FROM [#details] x WHERE x.[row_id] = [expanded].[row_id]) ELSE [query_plan] END [query_plan],
--[plans_count],
		[compiles_count],
		
		[avg_logical_reads] [avg_reads_GB],
		[total_logical_reads] [total_reads_GB],
		[avg_logical_writes] [avg_writes_GB],
		[total_logical_writes] [total_writes_GB],
		--[avg_physical_reads],
		--[total_physical_reads],
		[avg_used_memory] [avg_grant_GB],
		[total_used_memory] [total_grant_GB],
		[avg_rowcount],
		[total_rowcount],
		[avg_log_bytes_used] [avg_log_GB],
		[total_log_bytes_used] [total_log_GB],
		[avg_tempdb_space_used] [avg_spills_GB],
		[total_tempdb_space_used] [total_spills_GB],
		[max_dop]
		--[query_plan] [most_recent_plan]
	FROM 
		[expanded]
	ORDER BY 
		[row_id];

	RETURN 0;
GO