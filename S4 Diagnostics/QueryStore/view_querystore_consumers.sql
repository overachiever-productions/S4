/*

	vNEXT: 
		- Add CPU_DEVIATION and DURATION_DEVIATION ... or something similar - i.e., plans/queries where the avg is nothing close to the MAX_xxx value from sys.query_store_runtime_stats
		- Could also add MOST_FAILED or CPU_FAILED or whatever... i.e., failed/aborted queries ordered by ... something.

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

	TODO: 
		'COMPILECOUNTS' is STOOOPID slow... 

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

IF OBJECT_ID('dbo.view_querystore_consumers','P') IS NOT NULL
	DROP PROC dbo.[view_querystore_consumers];
GO

CREATE PROC dbo.[view_querystore_consumers]
	@TargetDatabase								sysname			= NULL, 
	@MostExpensiveBy							sysname			= N'DURATION',		-- { CPU | DURATION | EXECUTIONCOUNTS | READS | WRITES | ROWCOUNTS | TEMPDB | GRANTS | TLOG | PLANCOUNTS | COMPILECOUNTS }
	@TopResults									int				= 30,
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL 
	--@ExcludeServiceBrokerQueues					bit				= 1, 
	--@ExcludeFailedAndAbortedQueries				bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @MostExpensiveBy = ISNULL(NULLIF(@MostExpensiveBy, N''), N'DURATION');

	IF UPPER(@MostExpensiveBy) NOT IN (N'CPU', N'DURATION', N'EXECUTIONCOUNTS', N'READS', N'WRITES', N'ROWCOUNTS', N'TEMPDB', N'GRANTS', N'TLOG', N'PLANCOUNTS', N'COMPILECOUNTS') BEGIN
		RAISERROR('Allowed values for @MostExpensiveBy are { CPU | DURATION | EXECUTIONCOUNTS | READS | WRITES | ROWCOUNTS | TEMPDB | GRANTS | TLOG | PLANCOUNTS | COMPILECOUNTS}.', 16, 1);
		RETURN -10;
	END;

	DECLARE @orderBy sysname;
	SET @orderBy = (SELECT 
		CASE @MostExpensiveBy 
			WHEN N'CPU' THEN N'x.[total_cpu_time_ms]'
			WHEN N'DURATION' THEN N'x.[total_duration_ms]'
			WHEN N'EXECUTIONCOUNTS' THEN N'x.[total_executions]'
			WHEN N'READS' THEN N'x.[total_io_reads]'
			WHEN N'WRITES' THEN N'x.[total_io_writes]'
			WHEN N'ROWCOUNTS' THEN N'x.[total_row_counts]'
			WHEN N'TEMPDB' THEN N'x.[total_tempdb_space_used]'
			WHEN N'GRANTS' THEN N'x.[total_used_memory]'
			WHEN N'TLOG' THEN N'x.[total_log_bytes_used]'
			WHEN N'PLANCOUNTS' THEN N'[plan_count]'
			WHEN N'COMPILECOUNTS' THEN N'[q].[count_compiles]'
			ELSE NULL
		END);
	
	IF @orderBy IS NULL BEGIN 
		RAISERROR('S4 Framework Error. %s has not had an ORDER BY clause defined.', 16, 1, @MostExpensiveBy);
		RETURN -20;
	END;

	DECLARE @sql nvarchar(MAX); 
	DECLARE @qsStart datetime, @qsEnd datetime; 
	
	SET @sql = N'SELECT 
		@qsStart = CAST(MIN(start_time) AS datetime), 
		@qsEnd = CAST(MAX(end_time) AS datetime) 
	FROM 
		[{targetDB}].sys.[query_store_runtime_stats_interval]; ';
	
	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	EXEC sys.[sp_executesql]
		@sql, 
		N'@qsStart datetime OUTPUT, @qsEnd datetime OUTPUT', 
		@qsStart = @qsStart OUTPUT,
		@qsEnd = @qsEnd OUTPUT;

	DECLARE @minutes int;
	SET @sql = N'SELECT @minutes = interval_length_minutes FROM [{targetDB}].sys.[database_query_store_options]; ';
	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	EXEC sys.sp_executesql
		@sql, 
		N'@minutes int OUTPUT', 
		@minutes = @minutes OUTPUT;

	IF @OptionalStartTime IS NOT NULL BEGIN 
		IF @OptionalStartTime > @qsStart 
			SET @qsStart = @OptionalStartTime;
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF @OptionalEndTime < @qsEnd
			SET @qsEnd = @OptionalEndTime;
	END;

	DECLARE @startTime datetime, @endTime datetime;
	SELECT 
		@startTime = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @qsStart) / @minutes * @minutes, 0), 
		@endTime = DATEADD(MINUTE, @minutes, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @qsEnd) / @minutes * @minutes, 0));
	
	DECLARE @startInterval int, @endInterval int;
	SET @sql = N'SET @startInterval = (SELECT TOP 1 [runtime_stats_interval_id] FROM [{targetDB}].sys.[query_store_runtime_stats_interval] WHERE [start_time] >= @startTime); ';
	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	EXEC sys.[sp_executesql]
		@sql, 
		N'@startTime datetime, @startInterval int OUTPUT', 
		@startTime = @startTime,
		@startInterval = @startInterval OUTPUT;

	SET @sql = N'SET @endInterval = (SELECT TOP 1 [runtime_stats_interval_id] FROM [{targetDB}].sys.[query_store_runtime_stats_interval] WHERE [end_time] <= @endTime ORDER BY [end_time] DESC); ';
	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	EXEC sys.[sp_executesql]
		@sql, 
		N'@endTime datetime, @endInterval int OUTPUT', 
		@endTime = @endTime,
		@endInterval = @endInterval OUTPUT;

	CREATE TABLE #TopQueryStoreStats (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[plan_id] bigint NOT NULL, 
		[total_executions] bigint NOT NULL,
		[avg_duration_ms] float NOT NULL,
		[total_duration_ms] float NOT NULL,
		[avg_cpu_time_ms] float NOT NULL, 
		[total_cpu_time_ms] float NOT NULL, 
		[avg_io_reads] float NOT NULL, 
		[total_io_reads] float NOT NULL, 
		[avg_io_writes] float NOT NULL,
		[total_io_writes] float NOT NULL,
		[avg_used_memory] float NOT NULL,
		[total_used_memory] float NOT NULL,
		[avg_row_counts] float NOT NULL,
		[total_row_counts] float NOT NULL,
		[avg_log_bytes_used] float NOT NULL,
		[total_log_bytes_used] float NOT NULL,
		[avg_tempdb_space_used] float NOT NULL,
		[total_tempdb_space_used] float NOT NULL
	);

	SET @sql = N'WITH core AS ( 
		SELECT 
			s.[plan_id],
			s.[count_executions],
			CAST(s.[avg_duration] / 1000.0 as decimal(24,2)) [avg_duration_ms],
			CAST(s.[avg_cpu_time] / 1000.0 as decimal(24,2)) [avg_cpu_time_ms],
			s.[avg_logical_io_reads],
			s.[avg_logical_io_writes],
			s.[avg_physical_io_reads],
			s.[avg_query_max_used_memory],
			s.[avg_rowcount],
			s.[avg_log_bytes_used],
			s.[avg_tempdb_space_used]
		FROM 
			[{targetDB}].sys.[query_store_runtime_stats] s
			INNER JOIN [{targetDB}].sys.[query_store_runtime_stats_interval] i ON s.[runtime_stats_interval_id] = i.[runtime_stats_interval_id]
		WHERE 
			s.[runtime_stats_interval_id] >= @startInterval
			AND s.[runtime_stats_interval_id] <= @endInterval
	), 
	aggregated AS ( 
		SELECT 
			[plan_id],
			SUM([count_executions]) [total_executions],
			AVG([avg_duration_ms]) [avg_duration_ms],
			SUM([avg_duration_ms]) [total_duration_ms],
			AVG([avg_cpu_time_ms]) [avg_cpu_time_ms],
			SUM([avg_cpu_time_ms]) [total_cpu_time_ms],
			AVG([avg_logical_io_reads]) [avg_io_reads],
			SUM([avg_logical_io_reads]) [total_io_reads],
			AVG([avg_logical_io_writes]) [avg_io_writes],
			SUM([avg_logical_io_writes]) [total_io_writes],
			AVG([avg_query_max_used_memory]) [avg_used_memory],
			SUM([avg_query_max_used_memory]) [total_used_memory],
			AVG([avg_rowcount]) [avg_row_counts],
			SUM([avg_rowcount]) [total_row_counts],
			AVG([avg_log_bytes_used]) [avg_log_bytes_used],
			SUM([avg_log_bytes_used]) [total_log_bytes_used],
			AVG([avg_tempdb_space_used]) [avg_tempdb_space_used], 
			SUM([avg_tempdb_space_used]) [total_tempdb_space_used] 
		FROM 
			core 
		GROUP BY 
			[plan_id]
	)

	SELECT 
		[plan_id],
		[total_executions],
		[avg_duration_ms],
		[total_duration_ms],
		[avg_cpu_time_ms],
		[total_cpu_time_ms],
		[avg_io_reads],
		[total_io_reads],
		[avg_io_writes],
		[total_io_writes],
		[avg_used_memory],
		[total_used_memory],
		[avg_row_counts],
		[total_row_counts],
		[avg_log_bytes_used],
		[total_log_bytes_used],
		[avg_tempdb_space_used],
		[total_tempdb_space_used] 
	FROM 
		[aggregated]; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	INSERT INTO [#TopQueryStoreStats] (
		[plan_id],
		[total_executions],
		[avg_duration_ms],
		[total_duration_ms],
		[avg_cpu_time_ms],
		[total_cpu_time_ms],
		[avg_io_reads],
		[total_io_reads],
		[avg_io_writes],
		[total_io_writes],
		[avg_used_memory],
		[total_used_memory],
		[avg_row_counts],
		[total_row_counts],
		[avg_log_bytes_used],
		[total_log_bytes_used],
		[avg_tempdb_space_used],
		[total_tempdb_space_used] 
	)
	EXEC sys.[sp_executesql] 
		@sql, 
		N'@TopResults int, @startInterval int, @endInterval int', 
		@TopResults = @TopResults,
		@startInterval = @startInterval, 
		@endInterval = @endInterval;

	CREATE TABLE #TopRows (
		[row_id] int IDENTITY(1, 1) NOT NULL,
		[plan_id] bigint NOT NULL,
		[query_id] bigint NOT NULL,
		[plan_count] int NULL,
		[plan_compiles] bigint NULL,
		[query_compiles] bigint NULL,
		[query_sql_text] nvarchar(MAX) NOT NULL, 
		[query_plan] nvarchar(MAX) NULL,
		[total_executions] bigint NOT NULL,
		[avg_duration_ms] float NOT NULL,
		[total_duration_ms] float NOT NULL,
		[avg_cpu_time_ms] float NOT NULL,
		[total_cpu_time_ms] float NOT NULL,
		[avg_io_reads] float NOT NULL,
		[total_io_reads] float NOT NULL,
		[avg_io_writes] float NOT NULL,
		[total_io_writes] float NOT NULL,
		[avg_used_memory] float NOT NULL,
		[total_used_memory] float NOT NULL,
		[avg_row_counts] float NOT NULL,
		[total_row_counts] float NOT NULL,
		[avg_log_bytes_used] float NOT NULL,
		[total_log_bytes_used] float NOT NULL,
		[avg_tempdb_space_used] float NOT NULL,
		[total_tempdb_space_used] float NOT NULL
	);

	SET @sql = N'SELECT TOP(@TopResults)
		[x].[plan_id],
		[p].[query_id],
		(SELECT COUNT(*) FROM [{targetDB}].sys.[query_store_plan] x2 WHERE x2.[query_id] = [p].[query_id]) [plan_count], 
		[p].[count_compiles] [plan_compiles], 
		[q].[count_compiles] [query_compiles], 
		[t].[query_sql_text],
		[p].[query_plan],
		[x].[total_executions],
		[x].[avg_duration_ms],
		[x].[total_duration_ms],
		[x].[avg_cpu_time_ms],
		[x].[total_cpu_time_ms],
		[x].[avg_io_reads],
		[x].[total_io_reads],
		[x].[avg_io_writes],
		[x].[total_io_writes],
		[x].[avg_used_memory],
		[x].[total_used_memory],
		[x].[avg_row_counts],
		[x].[total_row_counts],
		[x].[avg_log_bytes_used],
		[x].[total_log_bytes_used],
		[x].[avg_tempdb_space_used],
		[x].[total_tempdb_space_used] 
	FROM 
		[#TopQueryStoreStats] x
		LEFT OUTER JOIN [{targetDB}].sys.[query_store_plan] p ON [x].[plan_id] = [p].[plan_id]
		LEFT OUTER JOIN [{targetDB}].sys.[query_store_query] q ON [p].[query_id] = [q].[query_id]
		LEFT OUTER JOIN [{targetDB}].sys.[query_store_query_text] t ON [q].[query_text_id] = [t].[query_text_id]
	ORDER BY 
		{orderBy} DESC; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{orderBy}', @orderBy);

	INSERT INTO [#TopRows] (
		[plan_id],
		[query_id],
		[plan_count],
		[plan_compiles],
		[query_compiles],
		[query_sql_text], 
		[query_plan],
		[total_executions],
		[avg_duration_ms],
		[total_duration_ms],
		[avg_cpu_time_ms],
		[total_cpu_time_ms],
		[avg_io_reads],
		[total_io_reads],
		[avg_io_writes],
		[total_io_writes],
		[avg_used_memory],
		[total_used_memory],
		[avg_row_counts],
		[total_row_counts],
		[avg_log_bytes_used],
		[total_log_bytes_used],
		[avg_tempdb_space_used],
		[total_tempdb_space_used]
	)
	EXEC sys.[sp_executesql] 
		@sql, 
		N'@TopResults int', 
		@TopResults = @TopResults;

	WITH core AS (

	SELECT 
		[x].[row_id],
		[x].[query_sql_text],
		TRY_CAST([x].[query_plan] AS xml) [query_plan],
		[x].[total_executions],
		CAST(([x].[avg_duration_ms] / 1000.0) AS decimal(24,2)) [avg_duration_ms],
		CAST(([x].[total_duration_ms] / 1000.0) AS decimal(24,2)) [total_duration_ms],
		CAST(([x].[avg_cpu_time_ms] / 1000.0) AS decimal(24,2)) [avg_cpu_time_ms],
		CAST(([x].[total_cpu_time_ms] / 1000.0) AS decimal(24,2)) [total_cpu_time_ms],
		CAST(([x].[avg_io_reads] * 8.0 / 1073741824) AS decimal(24,2)) [avg_io_reads],
		CAST(([x].[total_io_reads] * 8.0 / 1073741824) AS decimal(24,2)) [total_io_reads],
		CAST(([x].[avg_io_writes] * 8.0 / 1073741824) AS decimal(24,2)) [avg_io_writes],
		CAST(([x].[total_io_writes] * 8.0 / 1073741824) AS decimal(24,2)) [total_io_writes],
		CAST(([x].[avg_used_memory] * 8.0 / 1073741824) AS decimal(24,2)) [avg_used_memory],
		CAST(([x].[total_used_memory] * 8.0 / 1073741824) AS decimal(24,2)) [total_used_memory],
		CAST([x].[avg_row_counts] AS decimal(24,2)) [avg_row_counts],
		CAST([x].[total_row_counts] AS decimal(24,2)) [total_row_counts],
		CAST(([x].[avg_log_bytes_used] / 1073741824.0) AS decimal(24,2)) [avg_log_bytes_used],
		CAST(([x].[total_log_bytes_used] / 1073741824.0) AS decimal(24,2)) [total_log_bytes_used],
		CAST(([x].[avg_tempdb_space_used] * 8.0 / 1073741824) AS decimal(24,2)) [avg_tempdb_space_used],
		CAST(([x].[total_tempdb_space_used] * 8.0 / 1073741824) AS decimal(24,2)) [total_tempdb_space_used],

		[x].[query_id],
		[x].[plan_id],
		[x].[plan_count],
		[x].[plan_compiles],
		[x].[query_compiles]

	FROM 
		[#TopRows] x
	)

	SELECT 
		[x].[row_id],
		[x].[query_sql_text],
		CASE WHEN x.[query_plan] IS NULL THEN (SELECT x2.[plan_id] [plan_id_with_more_than_128_xml_levels] FROM [core] x2 WHERE x2.[row_id] = x.[row_id] FOR XML AUTO, TYPE) ELSE x.[query_plan] END [query_plan],
		[x].[total_executions] [execution_count],
		[x].[avg_duration_ms],
		[x].[avg_cpu_time_ms],
		dbo.[format_timespan]([x].[total_duration_ms]) [aggregate_duration],
		dbo.[format_timespan]([x].[total_cpu_time_ms]) [aggregate_cpu_time],
		[x].[avg_io_reads] [avg_reads_GB],
		[x].[total_io_reads] [aggregate_reads_GB],
		[x].[avg_io_writes] [avg_writes_GB],
		[x].[total_io_writes] [aggregate_writes_GB],
		[x].[avg_used_memory] [avg_grant_GB],
		[x].[total_used_memory] [aggregate_grant_GB],
		[x].[avg_row_counts] [avg_row_count],
		[x].[total_row_counts] [aggregate_row_count],
		[x].[avg_log_bytes_used] [avg_log_GB],
		[x].[total_log_bytes_used] [aggregate_log_GB],
		[x].[avg_tempdb_space_used] [avg_tempdb_GB],
		[x].[total_tempdb_space_used] [aggregate_tempdb_GB],
		[x].[query_id],
		[x].[plan_id],
		[x].[plan_count],
		[x].[plan_compiles],
		[x].[query_compiles]
	FROM 
		core x 
	ORDER BY 
		x.[row_id];

	RETURN 0;
GO