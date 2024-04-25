/*

	vNEXT:	
		- Switch @TargetDataBASE to @TargetDataBASES - and include @excludedDatabases... 
			- use the above to get a list of databases ... and remove those where querystore is not enabled. 
			- create a #table for results - which'll also include [database_name] as a column... 
			- tweak the SQL accordingly... 
					   			 		  
	vNEXT:
		- rather than object_id for statements from a sproc/udf/etc. that are forced, why not pull back the actual object name and/or object_id (name_here) or whatever.


	vNEXT: 
		- metrics/deviation: 
			I JUST need the SSMS approach to DEVIATION for CPU/DURATION 
				i.e., I do NOT NEED their 'stdev_xxx' column. 
				NOR do I need their 'avg' column. 

			Instead, I should replace 'stdev_xxx' and 'avg_xxx' WITH:
				MAX(x)
				AVG(x) 




	SIGNATURE: 
		admindb.dbo.[querystore_list_forced_plans] 
			@OrderResultsBy = N'CPU', 
			@ShowTimespanInsteadOfDates = 1;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.querystore_list_forced_plans','P') IS NOT NULL
	DROP PROC dbo.[querystore_list_forced_plans];
GO

CREATE PROC dbo.[querystore_list_forced_plans]
	@TargetDatabase						sysname		= NULL, 
	@ShowTimespanInsteadOfDates			bit			= 0, 
	@IncludeObjectDetails				bit			= 0, 
	@OrderResultsBy						sysname		= N'DURATION',			-- { DURATION_DEVIATION | CPU_DEVIATION | DURATION | CPU | ERRORS | PLAN_COUNT } 
	@IncludeScriptDirectives			bit			= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @ShowTimespanInsteadOfDates = ISNULL(@ShowTimespanInsteadOfDates, 0);
	SET @IncludeObjectDetails = ISNULL(@IncludeObjectDetails, 0);
	SET @IncludeScriptDirectives = ISNULL(@IncludeScriptDirectives, 1);
	SET @OrderResultsBy = ISNULL(NULLIF(@OrderResultsBy, N''), N'DURATION');

	IF UPPER(@OrderResultsBy) NOT IN (N'DURATION_DEVIATION', N'CPU_DEVIATION', N'DURATION', N'CPU', N'ERRORS', N'PLAN_COUNT') BEGIN 
		RAISERROR(N'Allowed values for @OrderResultsBy are { DURATION_DEVIATION | CPU_DEVIATION | DURATION | CPU | ERRORS | PLAN_COUNT }.', 16, 1);
		RETURN -10;
	END;

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;
		
		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for @TargetDatabase and/or S4 was unable to determine calling-db-context. Please specify a valid database name for @TargetDatabase and retry. ', 16, 1);
			RETURN -5;
		END;
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabase AND [is_query_store_on] = 1) BEGIN 
		RAISERROR(N'The specified @TargetDatabase: [%s] does NOT exist OR Query Store is NOT enabled within %s.', 16, 1, @TargetDatabase, @TargetDatabase);
		RETURN -10;
	END;

	CREATE TABLE #forced_plans (
		[query_id] bigint NOT NULL,
		[plan_id] bigint NOT NULL,
		[query_text] nvarchar(max) NULL,
		[query_plan] xml NULL,
		[forcing_type] nvarchar(60) NULL,
		[plan_count] int NOT NULL, 
		[last_compile] datetime NULL,
		[last_execution] datetime NULL,
		[object_id] bigint NULL,
		[object_name] sysname NOT NULL,
		[failures] bigint NOT NULL,
		[last_failure] sysname NULL,
		[remove_script] nvarchar(331) NULL,
		[force_script] nvarchar(329) NULL
	);

	DECLARE @sql nvarchar(MAX) = N'SELECT
		[p].[query_id] [query_id],
		[p].[plan_id] [plan_id],
		[qt].[query_sql_text] [query_text],
		TRY_CAST([p].[query_plan] AS xml) [query_plan],
		[p].[plan_forcing_type_desc] [forcing_type],
		(SELECT COUNT(*) FROM [sys].[query_store_plan] [x] WHERE x.query_id = [p].query_id) [plan_count],
		CAST([p].[last_compile_start_time] AS datetime) [last_compile],
		CAST([p].[last_execution_time] AS datetime) [last_execution],
		[q].[object_id] [object_id],
		ISNULL(OBJECT_NAME([q].[object_id]), '''') [object_name],
		[p].[force_failure_count] [failures],
		[p].[last_force_failure_reason_desc] [last_failure],
		N''EXEC [{db_name}].sys.sp_query_store_unforce_plan @query_id = '' + CAST([p].[query_id] AS sysname) + N'', @plan_id = '' + CAST([p].[plan_id] AS sysname) + N'';'' [remove_script], 
		N''EXEC [{db_name}].sys.sp_query_store_force_plan @query_id = '' + CAST([p].[query_id] AS sysname) + N'', @plan_id = '' + CAST([p].[plan_id] AS sysname) + N'';'' [force_script]
	FROM
		[{db_name}].[sys].[query_store_plan] [p]
		INNER JOIN [{db_name}].[sys].[query_store_query] [q] ON [q].[query_id] = [p].[query_id]
		INNER JOIN [{db_name}].[sys].[query_store_query_text] [qt] ON [q].[query_text_id] = [qt].[query_text_id]
	WHERE
		[p].[is_forced_plan] = 1; ';

	SET @sql = REPLACE(@sql, N'{db_name}', @TargetDatabase);

	INSERT INTO [#forced_plans] (
		[query_id],
		[plan_id],
		[query_text],
		[query_plan],
		[forcing_type],
		[plan_count],
		[last_compile],
		[last_execution],
		[object_id],
		[object_name],
		[failures],
		[last_failure],
		[remove_script],
		[force_script]
	)
	EXEC sys.sp_executesql 
		@sql; 

	SET @sql = N'SELECT 
		[f].plan_id, 

		CAST(AVG([rs].[avg_duration]) as decimal(24,2)) [avg_duration], 
		CAST(MAX([rs].[avg_duration]) as decimal(24,2)) [max_duration],

		-- Deviation Logic 100% STOLEN from SSMS "Queries with High Variation" Report:
		ISNULL(ROUND(CONVERT(float, (SQRT(SUM([rs].[stdev_duration] * [rs].[stdev_duration] * [rs].[count_executions]) / NULLIF(SUM([rs].[count_executions]), 0)) * SUM([rs].[count_executions])) / NULLIF(SUM([rs].[avg_duration] * [rs].[count_executions]), 0)), 2), 0) [variation_duration],
		
		CAST(AVG([rs].[avg_cpu_time]) as decimal(24,2)) [avg_cpu_time], 
		CAST(MAX([rs].[avg_cpu_time]) as decimal(24,2)) [max_cpu_time],
		
		-- Ditto (except copy/paste/tweak to find variation based on cpu_usage): 
		ISNULL(ROUND(CONVERT(float, (SQRT(SUM([rs].[stdev_cpu_time] * [rs].[stdev_cpu_time] * [rs].[count_executions]) / NULLIF(SUM([rs].[count_executions]), 0)) * SUM([rs].[count_executions])) / NULLIF(SUM([rs].[avg_cpu_time] * [rs].[count_executions]), 0)), 2), 0) [variation_cpu_time]
	FROM 
		[#forced_plans] [f]
		INNER JOIN [{db_name}].[sys].[query_store_runtime_stats] [rs] ON [f].[plan_id] = [rs].[plan_id]
	GROUP BY 
		[f].[plan_id]; ';

	SET @sql = REPLACE(@sql, N'{db_name}', @TargetDatabase);

	CREATE TABLE #metrics (
		[plan_id] bigint NOT NULL,
		[avg_duration] float NOT NULL, 
		[max_duration] float NOT NULL, 
		[variation_duration] float NOT NULL, 
		[avg_cpu_time] float NOT NULL, 
		[max_cpu_time] float NOT NULL, 
		[variation_cpu_time] float NOT NULL
	);

	INSERT INTO [#metrics] (
		[plan_id],
		[avg_duration],
		[max_duration],
		[variation_duration],
		[avg_cpu_time],
		[max_cpu_time],
		[variation_cpu_time]
	)
	EXEC sp_executesql 
		@sql;

	SET @sql = N'SELECT 
	[f].[query_id],
	[f].[plan_id],
	[f].[query_text],
	[f].[query_plan],
	[f].[forcing_type],
	[f].[plan_count],
	{times}{options}
	[f].[failures],
	[f].[last_failure],
	[m].[avg_duration],
	[m].[max_duration],
	[m].[variation_duration],
	[m].[avg_cpu_time],
	[m].[max_cpu_time],
	[m].[variation_cpu_time], 
	N'''' [ ],
	[f].[remove_script],
	[f].[force_script]
FROM 
	[#forced_plans] [f]
	LEFT OUTER JOIN [#metrics] [m] ON [f].[plan_id] = [m].[plan_id]
ORDER BY 
	{order_by} DESC; '; 

	DECLARE @times nvarchar(MAX) = N'[f].[last_compile],
	[f].[last_execution], ';

	IF @ShowTimespanInsteadOfDates = 1 BEGIN 
		SET @times = N'admindb.dbo.format_timespan(DATEDIFF(MILLISECOND, [f].[last_compile], GETDATE())) [last_compile],
	admindb.dbo.format_timespan(DATEDIFF(MILLISECOND,[f].[last_execution], GETDATE())) [last_execution],';
	END;

	DECLARE @options nvarchar(MAX) = N''; 
	IF @IncludeObjectDetails = 1 BEGIN 
		SET @options = NCHAR(13) + NCHAR(10) + NCHAR(9) + N'[f].[object_id],
	[f].[object_name],'
	END;

	DECLARE @orderBy nvarchar(MAX);
	SET @orderBy = CASE UPPER(@OrderResultsBy)
		WHEN N'DURATION_DEVIATION' THEN N'[m].[variation_duration]'
		WHEN N'CPU_DEVIATION' THEN N'[m].[variation_cpu_time]'
		WHEN N'DURATION' THEN N'[m].[avg_duration]'
		WHEN N'CPU' THEN N'[m].[avg_cpu_time]'
		WHEN N'ERRORS' THEN N'[f].[failures]'
		WHEN N'PLAN_COUNT' THEN N'[f].[plan_count]'
		ELSE N'[m].[variation_duration]' 
	END;

	SET @sql = REPLACE(@sql, N'{times}', @times);
	SET @sql = REPLACE(@sql, N'{options}', @options);
	SET @sql = REPLACE(@sql, N'{order_by}', @orderBy);

	EXEC sys.sp_executesql 
		@sql;

	RETURN 0; 
GO