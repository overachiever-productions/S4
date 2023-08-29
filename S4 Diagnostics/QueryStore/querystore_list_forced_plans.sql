/*

	vNEXT:	
		- Switch @TargetDataBASE to @TargetDataBASES - and include @excludedDatabases... 
			- use the above to get a list of databases ... and remove those where querystore is not enabled. 
			- create a #table for results - which'll also include [database_name] as a column... 
			- tweak the SQL accordingly... 



	vNEXT:
		- Move this into admindb. 
			- which means dynamic SQL... 
		- switch last compile/execution to admindb.dbo.format_timespan? 
		- dynamic details on ... failures or not @includeFailures ... 
		- dynamic @includeObjectDetails. 

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
	@IncludeScriptDirectives			bit			= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}

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
	
	DECLARE @times nvarchar(MAX) = N'CAST([p].[last_compile_start_time] AS datetime) [last_compile],
		CAST([p].[last_execution_time] AS datetime) [last_execution],';

	IF @ShowTimespanInsteadOfDates = 1 BEGIN 
		SET @times = N'admindb.dbo.format_timespan(DATEDIFF(MILLISECOND, [p].[last_compile_start_time], GETDATE())) [last_compile],
		admindb.dbo.format_timespan(DATEDIFF(MILLISECOND,[p].[last_execution_time], GETDATE())) [last_execution],';
	END;

	DECLARE @objectDetails nvarchar(MAX) = N'
		[q].[object_id] [object_id],
		ISNULL(OBJECT_NAME([q].[object_id]), '''') [object_name],';

	IF @IncludeObjectDetails = 0 
		SET @objectDetails = N'';

	DECLARE @scriptDirectives nvarchar(MAX) = N', 
		N'''' [ ], 
		N''EXEC [{db_name}].sys.sp_query_store_unforce_plan @query_id = '' + CAST([p].[query_id] AS sysname) + N'', @plan_id = '' + CAST([p].[plan_id] AS sysname) + N'';'' [remove_script], 
		N''EXEC [{db_name}].sys.sp_query_store_force_plan @query_id = '' + CAST([p].[query_id] AS sysname) + N'', @plan_id = '' + CAST([p].[plan_id] AS sysname) + N'';'' [force_script] ';

	IF @IncludeScriptDirectives = 0 
		SET @scriptDirectives = N'';

	DECLARE @sql nvarchar(MAX) = N'SELECT
		[p].[query_id] [query_id],
		[p].[plan_id] [plan_id],
		[qt].[query_sql_text] [query_text],
		TRY_CAST([p].[query_plan] AS xml) [query_plan],
		[p].[plan_forcing_type_desc] [forcing_type],
		{times}{object_details}
		[p].[force_failure_count] [failures],
		[p].[last_force_failure_reason_desc] [last_failure]{script_directives}
	FROM
		[{db_name}].[sys].[query_store_plan] [p]
		JOIN [{db_name}].[sys].[query_store_query] [q] ON [q].[query_id] = [p].[query_id]
		JOIN [{db_name}].[sys].[query_store_query_text] [qt] ON [q].[query_text_id] = [qt].[query_text_id]
	WHERE
		[p].[is_forced_plan] = 1; ';

	SET @sql = REPLACE(@sql, N'{times}', @times);
	SET @sql = REPLACE(@sql, N'{object_details}', @objectDetails);
	SET @sql = REPLACE(@sql, N'{script_directives}', @scriptDirectives);
	SET @sql = REPLACE(@sql, N'{db_name}', @TargetDatabase);

	EXEC sys.sp_executesql 
		@sql; 

	RETURN 0; 
GO