/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[querystore_variations_by_query_ids]','P') IS NOT NULL
	DROP PROC dbo.[querystore_variations_by_query_ids];
GO

CREATE PROC dbo.[querystore_variations_by_query_ids]
	@TargetDatabase			sysname					= NULL,
	@Granularity			sysname					= N'TOTAL',			-- { TOTAL | DAY | NATIVE }
	@QueryIds				bigint_enumeration		READONLY,
	@ExtractParameters		bit						= 0,
	@StartTime				datetime2(7), 
	@EndTime				datetime2(7)
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'TOTAL'));

	IF @Granularity NOT IN (N'TOTAL', N'DAY', N'NATIVE') BEGIN
		RAISERROR(N'Allowed values for @Granularity are: { TOTAL | DAY | NATIVE }.', 16, 1);
		RETURN -10;
	END;

	CREATE TABLE #results (
		[query_id] [bigint] NOT NULL,
		[plan_id] [bigint] NOT NULL,
		[text] [nvarchar](MAX) NULL,
		[execution_count] [bigint] NULL,
		[max_duration] [float] NULL,
		[total_duration] [float] NULL,
		[avg_duration] [float] NULL,
		[min_duration] [float] NULL,
		[window_start] [datetimeoffset](3) NULL,
		[window_end] [datetimeoffset](3) NULL,
		[query_plan] [xml] NULL,
		[is_forced_plan] [bit] NOT NULL,
		[execution_type] [nvarchar](60) NULL
	);

	DECLARE @granularityColumns nvarchar(MAX) = N'';
	DECLARE @granularityGroupBy nvarchar(MAX) = N'';

	IF @Granularity = N'TOTAL' BEGIN
		SET @granularityColumns = N'MIN([rs].[last_execution_time]) [window_start],' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N'MAX([rs].[last_execution_time]) [window_end],';
		SET @granularityGroupBy = N'';
	END	

	IF @Granularity = N'DAY' BEGIN
		SET @granularityColumns = N'CAST([rs].[last_execution_time] AS date) [window_start],' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N'DATEADD(DAY, 1, CAST([rs].[last_execution_time] AS date)) [window_end],';
		SET @granularityGroupBy = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N'CAST([rs].[last_execution_time] AS date),';
	END 

	IF @Granularity = N'NATIVE' BEGIN
		SET @granularityColumns = N'DATEADD(HOUR, ((DATEDIFF(HOUR, 0, [rs].[last_execution_time]))), 0) [window_start],' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N'DATEADD(HOUR, (1 + (DATEDIFF(HOUR, 0, [rs].[last_execution_time]))), 0) [window_end],';
		SET @granularityGroupBy = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N'DATEDIFF(HOUR, 0, [rs].[last_execution_time]),';
	END;

	DECLARE @sql nvarchar(MAX) = N'WITH bucketizer AS (
		-- MKC: Stolen from SSMS'' Tracked-Query Report.
		SELECT
			[x].[value] [query_id],  
			[rs].[plan_id] [plan_id],
			[rs].[execution_type_desc] [execution_type],
			SUM([rs].count_executions) [execution_count],
			{granularityColumns}
			ROUND(CONVERT(float, SUM([rs].[avg_duration] * [rs].[count_executions])) / NULLIF(SUM([rs].[count_executions]), 0) * .001, 2) [avg_duration],
			ROUND(CONVERT(float, MAX([rs].[max_duration])) * .001, 2) [max_duration],
			ROUND(CONVERT(float, MIN([rs].[min_duration])) * .001, 2) [min_duration],
			--ROUND(CONVERT(float, SQRT(SUM([rs].[stdev_duration] * [rs].[stdev_duration] * [rs].[count_executions])/NULLIF(SUM([rs].[count_executions]), 0)))*0.001,2) [stdev_duration],
			--ISNULL(ROUND(CONVERT(float, (SQRT(SUM([rs].[stdev_duration] * [rs].[stdev_duration] * [rs].[count_executions]) / NULLIF(SUM([rs].[count_executions]), 0)) * SUM([rs].[count_executions])) / NULLIF(SUM([rs].[avg_duration] *[rs].[count_executions]), 0)), 2), 0) [variation_duration],
			ROUND(CONVERT(float, SUM([rs].[avg_duration] * [rs].[count_executions])) * .001, 2) [total_duration]
		FROM
			{targetDB}.sys.[query_store_runtime_stats] [rs]
			INNER JOIN {targetDB}.sys.[query_store_plan] [p] ON [p].[plan_id] = [rs].[plan_id]
			INNER JOIN @QueryIds [x] ON p.[query_id] = [x].[value]  
		WHERE
			NOT ([rs].[first_execution_time] > @EndTime OR [rs].[last_execution_time] <= @StartTime)
		GROUP BY
			[rs].plan_id,
			[rs].execution_type_desc,{granularityGroupBy}
			[x].[value]
),
is_forced as
(
	SELECT [is_forced_plan], [plan_id]
		FROM {targetDB}.sys.[query_store_plan]
)

SELECT 
	[b].[query_id], 
	[b].[plan_id],
	[t].[query_sql_text] [text],
	[execution_count],
	[max_duration],
	[total_duration], 
	[avg_duration],
	[min_duration],
	SWITCHOFFSET([window_start], DATEPART(TZOFFSET, @StartTime)) [window_start],
	SWITCHOFFSET([window_end], DATEPART(TZOFFSET, @StartTime)) [window_end],
	CASE 
		WHEN TRY_CAST([p].[query_plan] AS xml) IS NULL THEN (SELECT NCHAR(13) + NCHAR(10) + NCHAR(9) + N''This plan is too large to display. Remove the TOP line, and the BOTTOM line, then save as .sqlplan and open.'' + NCHAR(13) + NCHAR(10) +
			REPLACE([p].[query_plan], N''</ShowPlanXML>'', N''</ShowPlanXML>'' + NCHAR(13) + NCHAR(10)) [processing-instruction(Plan_Too_Large)] FOR XML PATH(N''''), TYPE) 
		ELSE TRY_CAST([p].[query_plan] AS xml)
	END,
	[f].[is_forced_plan],
	[execution_type]
FROM 
	[bucketizer] [b]
	INNER JOIN [is_forced] [f] ON [f].[plan_id] = [b].[plan_id]
	INNER JOIN {targetDB}.[sys].[query_store_plan] [p] ON [b].[plan_id] = [p].[plan_id] AND b.query_id = p.[query_id]
	INNER JOIN {targetDB}.[sys].[query_store_query] [q] ON [b].[query_id] = [q].[query_id]
	INNER JOIN {targetDB}.[sys].[query_store_query_text] [t] ON [q].[query_text_id] = [t].[query_text_id]; ';	

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{granularityColumns}', @granularityColumns);
	SET @sql = REPLACE(@sql, N'{granularityGroupBy}', @granularityGroupBy);

	DECLARE @errorMessage nvarchar(MAX), @errorLine int;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	BEGIN TRY
		INSERT INTO [#results] (
			[query_id],
			[plan_id],
			[text],
			[execution_count],
			[max_duration],
			[total_duration],
			[avg_duration],
			[min_duration],
			[window_start],
			[window_end],
			[query_plan],
			[is_forced_plan],
			[execution_type]
		)
		EXEC sys.[sp_executesql]
			@sql,
			N'@QueryIds bigint_enumeration READONLY, @StartTime datetime2(7), @EndTime datetime2(7)', 
			@QueryIds = @QueryIds,
			@StartTime = @StartTime,
			@EndTime = @EndTime;
	END TRY 
	BEGIN CATCH 
		SELECT 
			@errorLine = ERROR_LINE(), 
			@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();

		RAISERROR(@errorMessage, 16, 1);
		EXEC admindb.dbo.[extract_dynamic_code_lines] @sql, @errorLine, 6;
	END CATCH;

	SELECT 
		[query_id],
		[plan_id],
		[text],
		[execution_count],
		[max_duration],
		[total_duration],
		[avg_duration],
		[min_duration],
		[window_start],
		[window_end],
		[query_plan],
		[is_forced_plan],
		[execution_type] 
	FROM 
		[#results]
	ORDER BY 
		[query_id],
		[plan_id],
		[window_start];

	RETURN 0;
GO