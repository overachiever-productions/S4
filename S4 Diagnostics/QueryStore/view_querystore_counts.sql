/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_querystore_counts','P') IS NOT NULL
	DROP PROC dbo.[view_querystore_counts];
GO

CREATE PROC dbo.[view_querystore_counts]
	@TargetDatabase								sysname			= NULL, 
	@Granularity								sysname			= N'HOUR',		-- { MINUTES | HOUR | DAY } 
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL, 
	--@ExcludeServiceBrokerQueues					bit				= 1, 
	--@ExcludeFailedAndAbortedQueries				bit				= 1, 
	@OptionalCoreCount							int				= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');
	
	IF UPPER(@Granularity) NOT IN (N'MINUTE', N'MINUTES', N'HOUR', N'DAY') BEGIN 
		RAISERROR('@Granularity can only be set to { MINUTE(S) | HOUR | DAY }. ', 16, 1);
		RETURN -10;
	END;

	DECLARE @minutes int = 60; 
	DECLARE @sql nvarchar(MAX); 
	DECLARE @qsStart datetime, @qsEnd datetime; 

	IF UPPER(@Granularity) = N'DAY' BEGIN
		SET @minutes = 60 * 24;
	END;

	IF UPPER(@Granularity) = N'MINUTES' BEGIN 
		SET @sql = N'SELECT @minutes = interval_length_minutes FROM [{targetDB}].sys.[database_query_store_options]; ';
		SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

		EXEC sys.sp_executesql
			@sql, 
			N'@minutes int OUTPUT', 
			@minutes = @minutes OUTPUT;
	END;
	
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

	DECLARE @coreCount int = @OptionalCoreCount;
	IF @coreCount IS NULL BEGIN 
		SELECT @coreCount = cpu_count FROM sys.dm_os_sys_info;  -- this provides LOGICAL core counts, but that's good/accurate enough.
	END;

	DECLARE @cpuMillisecondsPerInterval int = (1000 * @coreCount * 60) * @minutes;  -- milliseconds * cores * 60 seconds (1 minute) ... * # of minutes.
	
	
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

	CREATE TABLE #QueryStoreStats (
		[runtime_stats_id] bigint NOT NULL,
		[start] datetime NOT NULL, 
		[end] datetime NOT NULL, 
		[execution_type] tinyint NOT NULL,
		[count_executions] bigint NOT NULL,
		[avg_duration] decimal(24,2) NOT NULL,
		[avg_cpu_time] decimal(24,2) NOT NULL,
		[avg_logical_io_reads] float NOT NULL,
		[avg_logical_io_writes] float NOT NULL,
		[avg_physical_io_reads] float NOT NULL,
		[avg_query_max_used_memory] float NOT NULL,
		[avg_rowcount] float NOT NULL,
		[avg_log_bytes_used] float NOT NULL,
		[avg_tempdb_space_used]	 float NOT NULL		
	);

	SET @sql = N'SELECT 
		s.[runtime_stats_id],
		CAST(i.[start_time] AS datetime) [start], 
		CAST(i.[end_time] AS datetime) [end],
		s.[execution_type],
		s.[count_executions],
		CAST(s.[avg_duration] / 1000.0 as decimal(24,2)) [avg_duration],
		CAST(s.[avg_cpu_time] / 1000.0 as decimal(24,2)) [avg_cpu_time],
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
		AND s.[runtime_stats_interval_id] <= @endInterval; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	INSERT INTO #QueryStoreStats (
		[runtime_stats_id],
		[start],
		[end],
		[execution_type],
		[count_executions],
		[avg_duration],
		[avg_cpu_time],
		[avg_logical_io_reads],
		[avg_logical_io_writes],
		[avg_physical_io_reads],
		[avg_query_max_used_memory],
		[avg_rowcount],
		[avg_log_bytes_used],
		[avg_tempdb_space_used]
	)
	EXEC sys.[sp_executesql] 
		@sql, 
		N'@startInterval int, @endInterval int', 
		@startInterval = @startInterval, 
		@endInterval = @endInterval;

	CREATE TABLE #times (
		row_id int IDENTITY(1,1) NOT NULL, 
		time_block datetime NOT NULL
	);

	WITH times AS ( 
		SELECT @startTime [time_block] 

		UNION ALL 

		SELECT DATEADD(MINUTE, @minutes, [time_block]) [time_block]
		FROM [times]
		WHERE [time_block] < @endTime
	) 

	INSERT INTO [#times] (
		[time_block]
	)
	SELECT [time_block] 
	FROM times
	OPTION (MAXRECURSION 0);	

	WITH times AS ( 
		SELECT 
			row_id,
			t.[time_block] [end],
			LAG(t.[time_block], 1, DATEADD(MINUTE, (0 - @minutes), @startTime)) OVER (ORDER BY row_id) [start]
		FROM 
			[#times] t
	), 
	correlated AS ( 
		SELECT 
			t.[row_id], 
			t.[start] [time_period],
			[s].[runtime_stats_id],
			[s].[start],
			[s].[end],
			[s].[execution_type],
			[s].[count_executions],
			[s].[avg_duration],
			[s].[avg_cpu_time],
			[s].[avg_logical_io_reads],
			[s].[avg_logical_io_writes],
			[s].[avg_physical_io_reads],
			[s].[avg_query_max_used_memory],
			[s].[avg_rowcount],
			[s].[avg_log_bytes_used],
			[s].[avg_tempdb_space_used]
		FROM 
			[times] t 
			LEFT OUTER JOIN [#QueryStoreStats] s ON s.[end] < t.[end] AND s.[end] > t.[start]
	), 
	aggregated AS ( 
		SELECT 
			[time_period], 
			--COUNT([runtime_stats_id]) [total_collections], 
			SUM([count_executions]) [total_executions], 
			SUM([avg_cpu_time]) [avg_cpu], 
			CAST(((SUM([avg_cpu_time]) / @cpuMillisecondsPerInterval) * 100.0) AS decimal(4,2)) [%_cpu_ms],
			SUM([avg_duration]) [avg_duration],
			CAST(((SUM([avg_duration]) / @cpuMillisecondsPerInterval) * 100.0) AS decimal(4,2)) [%_duration_ms],
		-- this guy is usually a PIG compared to everything else: 
			CAST(((SUM([avg_logical_io_reads]) * 8.0) / 1073741824.0) AS decimal(24,2)) [logical_reads_TB], 
			CAST(((SUM([avg_logical_io_writes]) * 8.0) / 1048576.0) AS decimal(24,2)) [logical_writes_GB], 
			CAST(((SUM([avg_query_max_used_memory]) * 8.0) / 1048576.0) AS decimal(24,2)) [grant_GB],
			SUM([avg_rowcount]) [rowcounts], 
			CAST((SUM([avg_log_bytes_used]) / 1073741824.0) AS decimal(24,2)) [logged_GB], 
			CAST(((SUM([avg_tempdb_space_used]) * 8.0) / 1048576.0) AS decimal(24,2)) [tempdb_GB]
		FROM 
			[correlated] 
		WHERE 
			[correlated].[count_executions] IS NOT NULL
		GROUP BY 
			[time_period]
	), 
	formatted AS ( 
		SELECT 
			[time_period],
			FORMAT([total_executions], N'##,##0') [operations],
			FORMAT([rowcounts], N'##,##0') [rowcounts],
			dbo.[format_timespan](@cpuMillisecondsPerInterval) [available_ms],
			dbo.[format_timespan]([avg_cpu]) [consumed_cpu_ms],
			[%_cpu_ms],
			dbo.[format_timespan]([avg_duration]) [duration_ms],
			[%_duration_ms],
			[logical_reads_TB],
			[logical_writes_GB],
			[logged_GB],
			[grant_GB],
			[tempdb_GB] 
		FROM 
			[aggregated]
	) 

	SELECT 
		* 
	FROM 
		[formatted] 
	ORDER BY 
		[time_period];

	RETURN 0;
GO