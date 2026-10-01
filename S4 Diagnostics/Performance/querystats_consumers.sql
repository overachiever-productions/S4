/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[querystats_consumers]', N'P') IS NOT NULL
	DROP PROC dbo.[querystats_consumers];
GO

CREATE PROC dbo.[querystats_consumers]
	@top								int				= 20, 
	@order_by							sysname			= N'CPU_TOTAL'		-- { CPU_TOTAL | CPU_MAX | DURATION_TOTAL | DURATION_MAX | GRANT_TOTAL | GRANT_MAX | SPILLS_TOTAL | SPILLS_MAX | READS_TOTAL | READS_MAX }
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @order_by = UPPER(ISNULL(NULLIF(@order_by, N''), N'CPU_TOTAL'));

	-- TODO: verify ... @order_by in ... 

	CREATE TABLE #top_n (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[creation_time] datetime NULL,
		[last_execution_time] datetime NULL,
		[plan_generation_num] bigint NULL,
		[execution_count] bigint NOT NULL,
		[total_cpu] bigint NOT NULL,
		[max_cpu] bigint NOT NULL,
		[total_physical_reads] bigint NOT NULL,
		[max_physical_reads] bigint NOT NULL,
		[total_duration] bigint NOT NULL,
		[max_duration] bigint NOT NULL,
		[total_rows] bigint NULL,
		[max_rows] bigint NULL,
		[total_grant_kb] bigint NULL,
		[max_grant_kb] bigint NULL,
		[total_spills] bigint NULL, 
		[max_spills] bigint NULL, 
		[sql_handle] varbinary(64) NOT NULL,
		[plan_handle] varbinary(64) NOT NULL,
		[querystore_sql_handle] varbinary(64) NULL,
		[querystore_context_id] bigint NULL,
		[statement_start_offset] int NOT NULL,
		[statement_end_offset] int NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'WITH core AS ( 
	SELECT 
		[sql_handle],
		[statement_start_offset],
		[statement_end_offset],
		[plan_generation_num],
		[plan_handle],
		[creation_time],
		[last_execution_time],
		[execution_count],
		[total_worker_time] [total_cpu],
		[max_worker_time] [max_cpu],
		[total_physical_reads],
		[max_physical_reads],
		[total_elapsed_time] [total_duration],
		[max_elapsed_time] [max_duration],
		[total_rows] [total_rows],
		[max_rows] [max_rows],
		[statement_sql_handle] [querystore_sql_handle],
		[statement_context_id] [querystore_context_id],
		[total_grant_kb],
		[max_grant_kb],
		[total_spills], 
		[max_spills]
	FROM 
		sys.[dm_exec_query_stats]
)

SELECT TOP (@top)
	[creation_time],
	[last_execution_time],
	[plan_generation_num],
	[execution_count],
	[total_cpu],
	[max_cpu],
	[total_physical_reads],
	[max_physical_reads],
	[total_duration],
	[max_duration],
	[total_rows],
	[max_rows],
	[total_grant_kb],
	[max_grant_kb],
	[total_spills], 
	[max_spills], 
	[sql_handle],
	[plan_handle],
	[querystore_sql_handle],
	[querystore_context_id],
	[statement_start_offset],
	[statement_end_offset]
FROM 
	[core] 
ORDER BY 
	{order_by} DESC; ';

	DECLARE @orderBy sysname; 
	SELECT @orderBy = CASE @order_by
		WHEN N'CPU_TOTAL' THEN N'[total_cpu]'
		WHEN N'CPU_MAX' THEN N'[max_cpu]'
		WHEN N'DURATION_TOTAL' THEN N'[total_duration]'
		WHEN N'DURATION_MAX' THEN N'[max_duration]'
		WHEN N'GRANT_TOTAL' THEN N'[total_grant_kb]'
		WHEN N'GRANT_MAX' THEN N'[max_grant_kb]'
		WHEN N'SPILLS_TOTAL' THEN N'[total_spills]'
		WHEN N'SPILLS_MAX' THEN N'[max_spills]'
		WHEN N'READS_TOTAL' THEN N'[total_physical_reads]'
		WHEN N'READS_MAX' THEN N'[max_physical_reads]'
		ELSE N'[total_cpu]'
	END;

	SET @sql = REPLACE(@sql, N'{order_by}', @orderBy);

	INSERT INTO [#top_n] (
		[creation_time],
		[last_execution_time],
		[plan_generation_num],
		[execution_count],
		[total_cpu],
		[max_cpu],
		[total_physical_reads],
		[max_physical_reads],
		[total_duration],
		[max_duration],
		[total_rows],
		[max_rows],
		[total_grant_kb],
		[max_grant_kb],
		[total_spills],
		[max_spills],
		[sql_handle],
		[plan_handle],
		[querystore_sql_handle],
		[querystore_context_id],
		[statement_start_offset],
		[statement_end_offset]
	)
	EXEC sys.[sp_executesql]
		@sql, 
		N'@top int', 
		@top = @top;

	SELECT 
		[n].[row_id],
		dbo.format_timespan(DATEDIFF_BIG(MILLISECOND, [n].[creation_time], GETDATE())) [plan_age],
		dbo.format_timespan(DATEDIFF_BIG(MILLISECOND, [n].[last_execution_time], GETDATE())) [last_execution],
		CASE WHEN ISNULL([t].[dbid], [x].[dbid]) = 32767 THEN N'resource_db' ELSE DB_NAME(ISNULL([t].[dbid], [x].[dbid])) END [database], 
		CASE WHEN ISNULL([t].[dbid], [x].[dbid]) = 32767 THEN N'  (object_id: ' + ISNULL(CAST([x].[objectid] AS sysname), N'') + N')' ELSE OBJECT_NAME(ISNULL([t].[objectid], [x].[objectid]), ISNULL([t].[dbid], [x].[dbid])) END [module],
		SUBSTRING([t].[text], n.[statement_start_offset] / 2 + 1, (CASE WHEN [n].[statement_end_offset] = -1 THEN LEN([t].[text]) * 2 ELSE [n].[statement_end_offset] END - [n].[statement_start_offset]) / 2) [statement],
		--CAST([x].[query_plan] AS xml) [statement_plan],
		CASE 
			WHEN TRY_CAST([x].[query_plan] AS xml) IS NULL THEN (SELECT NCHAR(13) + NCHAR(10) + NCHAR(9) + N'This plan is too large to display. Remove the TOP line, and the BOTTOM line, then save as .sqlplan and open.' + NCHAR(13) + NCHAR(10) +
			REPLACE([x].[query_plan], N'</ShowPlanXML>', N'</ShowPlanXML>' + NCHAR(13) + NCHAR(10)) [processing-instruction(Plan_Too_Large)] FOR XML PATH(N''), TYPE)
			ELSE TRY_CAST([x].[query_plan] AS xml)
		END [statement_plan],
		[p].[query_plan] [batch_plan],
		FORMAT([n].[execution_count], N'N0') [exec_count],
		FORMAT([n].[total_cpu] / 1000, N'N0') [total_cpu_ms],
		FORMAT([n].[total_cpu] / [n].[execution_count] / 1000, N'N0') [avg_cpu_ms],
		FORMAT([n].[max_cpu] / 1000, N'N0') [max_cpu_ms],
		FORMAT([n].[total_duration] / 1000, N'N0') [total_duration_ms],
		FORMAT([n].[total_duration] / [n].[execution_count] / 1000, N'N0') [avg_duration_ms],
		FORMAT([n].[max_duration] / 1000, N'N0') [max_duration_ms],
		CAST([n].[total_physical_reads] * 8 / 1048576. AS decimal(22,2)) [total_reads_gb],
		CAST([n].[total_physical_reads] * 8 / 1048576. / [n].[execution_count] AS decimal(22,2)) [avg_reads_gb],
		CAST([n].[max_physical_reads] * 8 / 1048576. AS decimal(22,2)) [max_reads_gb],
		FORMAT([n].[total_rows], N'N0') [total_rows],
		FORMAT([n].[total_rows] / [n].[execution_count], N'N0') [avg_rows],
		FORMAT([n].[max_rows], N'N0') [max_rows],
		CAST([n].[total_grant_kb] / 1024. AS decimal(22,2)) [total_grant_mb],
		CAST([n].[total_grant_kb] / 1024. / [n].[execution_count] AS decimal(22,2)) [avg_grant_mb],
		CAST([n].[max_grant_kb] / 1024. AS decimal(22,2)) [max_grant_mb],
		CAST([n].[total_spills] * 8 / 1048576. AS decimal(22,2)) [total_spills_gb],
		CAST([n].[total_spills] * 8 / 1048576. / [n].[execution_count] AS decimal(22,2)) [avg_spill_gb],
		CAST([n].[max_spills] * 8 / 1048576. AS decimal(22,2)) [max_spill_gb],

		-- TODO: see https://overachieverllc.atlassian.net/browse/S4-969
		[n].[querystore_sql_handle],
		[n].[querystore_context_id]
	INTO 
		#intermediate
	FROM 
		[#top_n] [n]
		OUTER APPLY sys.[dm_exec_query_plan]([n].[plan_handle]) [p]
		OUTER APPLY sys.[dm_exec_sql_text]([n].[sql_handle]) [t]
		OUTER APPLY sys.[dm_exec_text_query_plan]([n].[plan_handle], [n].[statement_start_offset], [n].[statement_end_offset]) [x];

	SET @sql = N'SELECT 
	[plan_age],
	[last_execution],
	[database],
	[module],
	[statement],
	[statement_plan],
	[batch_plan],
	[exec_count],
	{targetColumns}, 
	(SELECT {metricsColumns} FROM [#intermediate] [i2] WHERE [#intermediate].[row_id] = [i2].[row_id] FOR XML PATH(N''detail''), TYPE) [metrics],
	[querystore_sql_handle],
	[querystore_context_id] 
FROM 
	[#intermediate]
ORDER BY 
	[row_id]; ';

	DECLARE @columnMaps table (
		[column_name] sysname NOT NULL, 
		[category] sysname NOT NULL
	);

	INSERT INTO @columnMaps ([column_name], [category])
	VALUES 
		(N'[total_cpu_ms]', N'CPU'), 
		(N'[avg_cpu_ms]', N'CPU'), 
		(N'[max_cpu_ms]', N'CPU'), 
		(N'[total_duration_ms]', N'DUR'), 
		(N'[avg_duration_ms]', N'DUR'), 
		(N'[max_duration_ms]', N'DUR'), 
		(N'[total_reads_gb]', N'REA'), 
		(N'[avg_reads_gb]', N'REA'), 
		(N'[max_reads_gb]', N'REA'), 
		(N'[total_rows]', N''), 
		(N'[avg_rows]', N''), 
		(N'[max_rows]', N''), 
		(N'[total_grant_mb]', N'GRA'), 
		(N'[avg_grant_mb]', N'GRA'), 
		(N'[max_grant_mb]', N'GRA'), 
		(N'[total_spills_gb]', N'SPI'), 
		(N'[avg_spill_gb]', N'SPI'), 
		(N'[max_spill_gb]', N'SPI'); 

	DECLARE @targetColumns nvarchar(MAX);
	DECLARE @metricsColumns nvarchar(MAX);

	SELECT @targetColumns = STRING_AGG([column_name], ', ') FROM @columnMaps WHERE [category] = LEFT(@order_by, 3);
	SELECT @metricsColumns = STRING_AGG([column_name], ', ') FROM @columnMaps WHERE [category] <> LEFT(@order_by, 3);

	SET @sql = REPLACE(@sql, N'{targetColumns}', @targetColumns);
	SET @sql = REPLACE(@sql, N'{metricsColumns}', @metricsColumns);

	EXEC sys.[sp_executesql] 
		@sql;

	RETURN 0;
GO