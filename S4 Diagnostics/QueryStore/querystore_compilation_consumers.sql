/*

	BUGs: 
		- I'm doing QUERYID wrong: https://www.notion.so/overachiever/Plan-Cache-Compilations-1015380af00e8041a35bf13bf0239f49?pvs=4 

	vNEXT: 
		This thing is SURPRISINGLY MORE useful than I could have imagined. 
			> it's helping me spot stupid ad-hoc queries that should be sproc-ified in some environments (BC). 
		And, I think one thing that I could do to make this a bit clearer/better would be: 
			- AFTER I've extracted plans (i.e., in a ANOTHER query/operation against an #initialResults table) ... 
			I should be extracting the COST of these stubs/plans... just as some additional insight. 
		ALSO, for those statements coming from a module, I think I'd like to see total number of statements in the module too... 
		ALSO, an @PerHourAvg 'switch' that'll let this thing do a rough/approximate # of compilations by HOUR for a given query. 
			e.g., in BC I had a sproc with 27 statements ... and each of those was(is) getting compiled 55M times in ~14 days. 
				I did the math, and that's roughly 2.7K/minute. 
				It'd be NICE to see something like this as 'just another column'. 
	
	vNEXT:
		hmm. MIGHT? make sense to do a 'CONTEXTS' @Mode variant - i.e., ORDER BY # of contexts... 
		along those same lines, a 'PLANS' option would make a lot of sense too. 
			that'd show queries with high variability.


	vNEXT: 
		I'm CONSISTENTLY 'tempted' to add execution counts into the mix. 
		Which... might (obviously) be something GOOD to have. 
		BUT. 
			i don't care if something is called/executed 480 times an hour (or 48000/hour) IF it's taking 10 minutes a day to compile - the PROBLEM there would be the 10 minutes of compilation time (and	
				yeah, cough, nothing's going to take that long (i mean, other than things that can, seriously, take HOURs) ... but still. 
				SO. 
				Maybe it'd make sense to add an @IncludeExecutionCounts 


	SAMPLE EXECUTION: 
			
			USE [MyDBHere];
			GO 

			EXEC admindb.dbo.querystore_compilation_consumers @Mode = N'DURATION';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[querystore_compilation_consumers]','P') IS NOT NULL
	DROP PROC dbo.[querystore_compilation_consumers];
GO

CREATE PROC dbo.[querystore_compilation_consumers]
	@TargetDatabase				sysname			= NULL, 
	@Mode						sysname			= N'DURATION',		-- { DURATION | COUNT | MODULE_COUNT | MODULE_DURATION }  
	@TopN						int				= 100, 
	@ExcludeSystemCalls			bit				= 1, 
	@PrintOnly					bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SET @Mode = UPPER(ISNULL(NULLIF(@Mode, N''), N'DURATION'));
	SET @ExcludeSystemCalls = ISNULL(@ExcludeSystemCalls, 1);
	SET @TopN = ISNULL(NULLIF(@TopN, 0), 100);

	IF @Mode NOT IN (N'DURATION', N'COUNT', N'MODULE_COUNT', N'MODULE_DURATION') BEGIN 
		RAISERROR(N'Invalid @Mode specification. Allowed values are { DURATION | COUNT | MODULE_COUNT | MODULE_DURATION }.', 16, 1);
		RETURN -2;
	END;

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;
		
		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for @TargetDatabase and/or S4 was unable to determine calling-db-context. Please specify a valid database name for @TargetDatabase and retry. ', 16, 1);
			RETURN -5;
		END;
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT @actual = actual_state FROM [{db}].sys.database_query_store_options;';
	SET @sql = REPLACE(@sql, N'{db}', @TargetDatabase);
	DECLARE @actuaLState smallint;
	EXEC sys.[sp_executesql]
		@sql, 
		N'@actual smallint OUTPUT', 
		@actual = @actuaLState OUTPUT; 

	IF @actuaLState = 0 BEGIN 
		RAISERROR(N'Query Store is not currently enabled against @TargetDatabase: [%s].', 16, 1, @TargetDatabase);
		RETURN -50;
	END;
	
	SET @sql = N'SELECT TOP (' + CAST(@TopN AS sysname) + N') 
	[q].[query_id],
	(SELECT COUNT(*) FROM [{db}].sys.[query_store_plan] [p] WHERE [p].[query_id] = [q].[query_id]) [plans],
	(SELECT DISTINCT COUNT(*) FROM [{db}].sys.[query_store_query] [x] WHERE [x].[query_text_id] = q.[query_text_id]) [contexts],
	CASE WHEN [o].[object_id] IS NULL THEN N'''' ELSE QUOTENAME([s].[name]) + N''.'' + QUOTENAME([o].[name]) END [module_name],
	[t].[query_sql_text] [text],
	
	(
		(SELECT TOP (1) CASE 
			WHEN TRY_CAST([p].[query_plan] as xml) IS NULL THEN 
				(SELECT 
					NCHAR(13) + NCHAR(10) + NCHAR(9) 
					+ N''This plan is too large to display. Remove the TOP line, and the BOTTOM line, then save as .sqlplan and load into SSMS.'' 
					+ NCHAR(13) + NCHAR(10) + REPLACE([p].[query_plan], N''</ShowPlanXML>'', N''</ShowPlanXML>'' + NCHAR(13) + NCHAR(10)) [processing-instruction(Plan_Too_Large)]
				
				FOR XML PATH(N''''), TYPE)
			ELSE 
				TRY_CAST([p].[query_plan] as xml)
		END 
		FROM [{db}].sys.[query_store_plan] [p] WHERE [p].[query_id] = [q].[query_id] ORDER BY [p].[last_execution_time] DESC) 
		
		
	) [latest_plan],
	CASE WHEN [q].[batch_sql_handle] IS NOT NULL THEN 1 ELSE 0 END [@|#],{internal}
	[q].[query_parameterization_type_desc] [parameterization],
	CAST([initial_compile_start_time] AS date) [store_debut],
	admindb.dbo.[format_timespan](DATEDIFF_BIG(MILLISECOND, [q].[initial_compile_start_time], GETUTCDATE())) [store_age],
	admindb.dbo.[format_timespan](DATEDIFF_BIG(MILLISECOND, [q].[last_execution_time], GETUTCDATE())) [last_run],
	[q].[count_compiles] [compilations],
	CAST([q].[avg_compile_duration] / 1000.0 AS decimal(24,1)) [avg_plan_create_ms],
	CAST([q].[avg_bind_duration] / 1000.0 AS decimal(24,1)) [avg_stats_bind_ms],
	CAST([q].[avg_optimize_duration] / 1000.0 AS decimal(24,1)) [avg_optimize_ms],
	CAST([q].[avg_optimize_cpu_time] / 1000.0 AS decimal(24,1)) [avg_optimize_cpu],
	CAST(([q].[avg_compile_memory_kb] / 1024.0) AS decimal(12,1)) [avg_compile_mem_MB]
FROM 
	[{db}].sys.[query_store_query] [q]
	INNER JOIN [{db}].sys.[query_store_query_text] [t] ON [q].[query_text_id] = [t].[query_text_id]
	LEFT OUTER JOIN [{db}].sys.[objects] [o] ON [q].[object_id] = [o].[object_id]
	LEFT OUTER JOIN [{db}].sys.[schemas] [s] ON [o].[schema_id] = [s].[schema_id]{where}
ORDER BY 
	{mode}; ';

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	
	DECLARE @orderBy nvarchar(MAX) = (SELECT CASE @Mode 
		WHEN N'DURATION' THEN N'[q].[avg_compile_duration] DESC' 
		WHEN N'COUNT' THEN N'[q].[count_compiles] DESC'
		WHEN N'MODULE_COUNT' THEN N'[module], [q].[count_compiles] DESC'
		WHEN N'MODULE_DURATION' THEN N'[module], [q].[count_compiles] DESC'
	END);
	
	SET @sql = REPLACE(@sql, N'{db}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{mode}', @orderBy);

	IF @ExcludeSystemCalls = 1 BEGIN 
		SET @sql = REPLACE(@sql, N'{internal}', N'');
		SET @sql = REPLACE(@sql, N'{where}', @crlf + N'WHERE' + @crlftab + N'[q].[is_internal_query] = 0');
	  END; 
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{internal}', @crlftab + N'[q].[is_internal_query] [is_internal]');
		SET @sql = REPLACE(@sql, N'{where}',  N'');
	END;
	
	IF @PrintOnly = 1 BEGIN 
		EXEC dbo.[print_long_string] @sql;
		RETURN 0;
	END;

	EXEC sys.[sp_executesql] 
		@sql;

	RETURN 0;
GO