/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[querystore_details]','P') IS NOT NULL
	DROP PROC dbo.[querystore_details];
GO

CREATE PROC dbo.[querystore_details]
	@databases					nvarchar(MAX)		= N'{ALL}',									-- TODO: need to create (AND document) a specialized/one-off token of {ALL_QS_ENABLED} - or similar. https://overachieverllc.atlassian.net/browse/S4-730
	@priorities					nvarchar(MAX)		= NULL, 
	@serialized_output			xml					= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @databases = ISNULL(NULLIF(@databases, N''), N'{ALL}');
	SET @priorities = NULLIF(@priorities, N'');

	CREATE TABLE #QueryStoreDetails(
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL,
		[is_query_store_on] bit NOT NULL, 
		[desired_state_desc] nvarchar(60) NULL,
		[actual_state_desc] nvarchar(60) NULL,
		[readonly_reason] int NULL,
		[min_stats_interval] date NULL,
		[stats_inverval_days] int NULL,
		[query_capture_mode_desc] nvarchar(60) NULL,
		[wait_stats_capture_mode_desc] nvarchar(60) NULL,
		[current_storage_size_mb] bigint NULL,
		[max_storage_size_mb] bigint NULL,
		[flush_interval_seconds] bigint NULL,
		[interval_length_minutes] bigint NULL,
		[stale_query_threshold_days] bigint NULL,
		[max_plans_per_query] bigint NULL,
		[current_max_plan_count] int NULL,
		[size_based_cleanup_mode_desc] nvarchar(60) NULL
	);

	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}];
IF EXISTS(SELECT NULL FROM sys.databases WHERE database_id = DB_ID() AND [is_query_store_on] = 1) BEGIN
	INSERT INTO [#QueryStoreDetails] (
		[database_name],
		[is_query_store_on],
		[desired_state_desc],
		[actual_state_desc],
		[readonly_reason],
		[min_stats_interval],
		[stats_inverval_days],
		[query_capture_mode_desc],
		[wait_stats_capture_mode_desc],
		[current_storage_size_mb],
		[max_storage_size_mb],
		[flush_interval_seconds],
		[interval_length_minutes],
		[stale_query_threshold_days],
		[max_plans_per_query],
		[current_max_plan_count],
		[size_based_cleanup_mode_desc]
	)
	SELECT 
		DB_NAME() [database_name],
		CAST(1 AS bit) [is_query_store_on],
		[desired_state_desc],
		[actual_state_desc],
		[readonly_reason],
		(SELECT CAST(MIN([start_time]) AS date) FROM [sys].[query_store_runtime_stats_interval]) [min_stats_interval], 
		(SELECT DATEDIFF(DAY, MIN([start_time]), GETDATE()) FROM [sys].[query_store_runtime_stats_interval]) [stats_inverval_days],
		[query_capture_mode_desc],
		[wait_stats_capture_mode_desc],
		[current_storage_size_mb],
		[max_storage_size_mb],
		[flush_interval_seconds],
		[interval_length_minutes],
		[stale_query_threshold_days],			-- max of 7 days on Azure SQL Database BASIC instances. 
		[max_plans_per_query],					-- default is 200, can be set to 0 (unlimited). I should spin up a query to detect if/when getting close to exceeding this limit - a) that query sucks (likely), b) we stop tracking new plans 
		(SELECT TOP (1) COUNT(*) FROM [sys].[query_store_plan] GROUP BY [query_id] ORDER BY 1 DESC) [current_max_plan_count],
		[size_based_cleanup_mode_desc]
	FROM 
		sys.[database_query_store_options];
  END;
ELSE BEGIN 
	INSERT INTO [#QueryStoreDetails] (
		[database_name],
		[is_query_store_on]
	)
	VALUES (
		N''{CURRENT_DB}'', 
		CAST(0 as bit)
	)
END; ';

	DECLARE @Errors xml;
	EXEC dbo.[execute_per_database]
		@Databases = @Databases,
		@Priorities = @Priorities,
		@Statement = @sql,
		@Errors = @Errors OUTPUT;	

	IF @Errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected Errors during Execution. See (Printed) @Errors for additional details.', 16, 1);
		--EXEC dbo.[print_long_string] @Errors;  -- https://overachieverllc.atlassian.net/browse/S4-728
		PRINT CAST(@Errors AS nvarchar(MAX));
		RETURN -3; 
	END;

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				[database_name],
				[is_query_store_on],
				[desired_state_desc],
				[actual_state_desc],
				[readonly_reason],
				[min_stats_interval],
				[stats_inverval_days],
				[query_capture_mode_desc],
				[wait_stats_capture_mode_desc],
				[current_storage_size_mb],
				[max_storage_size_mb],
				[flush_interval_seconds],
				[interval_length_minutes],
				[stale_query_threshold_days],
				[max_plans_per_query],
				[current_max_plan_count],
				[size_based_cleanup_mode_desc] 
			FROM 
				[#QueryStoreDetails]
			ORDER BY 
				[row_id]
			FOR XML PATH (N'database'), ROOT(N'databases'), TYPE, ELEMENTS XSINIL
		); 
		RETURN 0;
	END; 

	SELECT 
		[database_name],
		[is_query_store_on],
		[desired_state_desc],
		[actual_state_desc],
		[readonly_reason],
		[min_stats_interval],
		[stats_inverval_days],
		[query_capture_mode_desc],
		[wait_stats_capture_mode_desc],
		[current_storage_size_mb],
		[max_storage_size_mb],
		[flush_interval_seconds],
		[interval_length_minutes],
		[stale_query_threshold_days],
		[max_plans_per_query],
		[current_max_plan_count],
		[size_based_cleanup_mode_desc] 
	FROM 
		[#QueryStoreDetails]
	ORDER BY 
		[row_id];

	RETURN 0;
GO