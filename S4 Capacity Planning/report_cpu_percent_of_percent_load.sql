/*


	EXEC [admindb].dbo.[report_cpu_percent_of_percent_load]
		@MetricsSourceTable = N'FIS_CPU_Sizing3', 
		@CoreCountCalculationsRange = 8, 
		@IncludeContinuityHeader = 0;




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[report_cpu_percent_of_percent_load]','P') IS NOT NULL
	DROP PROC dbo.[report_cpu_percent_of_percent_load];
GO

CREATE PROC dbo.[report_cpu_percent_of_percent_load]
	@SourceTable						sysname, 
	@CoreCountCalculationsRange			int					= 10,			-- + or - on either side of @currentCoreCount... 
	@AllowSmallCoreCounts				bit					= 0,			-- by default, stop at a MIN of 4 cores. If/when this is true, allow 4, 2, 1 cores (for Azure and other workload sizing).
	@AllowSmallBuckets					bit					= 0				-- by default, smallest bucket is 0-60% usage. when this is true, allow 20, 40, 60, etc. buckets. 
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @SourceTable, 
		@ParameterNameForTarget = N'@SourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 

	-------------------------------------------------------------------------------------------------------------------------
	-- begin processing/assessing outputs: 

	DECLARE @sql nvarchar(MAX); 

	DECLARE @totalCoreCount int;
	DECLARE @targetDatabase sysname = PARSENAME(@normalizedName, 3);

	SET @sql = N'SELECT @totalCoreCount = (SELECT COUNT(*) FROM [' + @targetDatabase + N'].sys.columns WHERE [object_id] = OBJECT_ID(''' + @normalizedName + N''') AND [name] LIKE N''processor%''); ';

	EXEC sys.[sp_executesql]
		@sql, 
		N'@totalCoreCount int OUTPUT', 
		@totalCoreCount = @totalCoreCount OUTPUT;

	IF @totalCoreCount < 1 BEGIN 
		RAISERROR(N'Unable to ascertain total core-count for table %s. Please ensure that @SourceTable points to a valid set of CPU metrics.', 16, 1);
		RETURN -10;
	END;

	DECLARE @serverName sysname; 
	SET @sql = N'SELECT @serverName = (SELECT TOP 1 [server_name] FROM ' + @normalizedName + N'); ';

	EXEC sys.[sp_executesql]
		@sql, 
		N'@serverName sysname OUTPUT', 
		@serverName = @serverName OUTPUT;

	IF OBJECT_ID('tempdb..#sizings') IS NOT NULL BEGIN
		DROP TABLE #sizings;
	END;

	CREATE TABLE #sizings ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		[server] sysname NOT NULL, 
		current_core_count int NOT NULL, 
		target_core_count int NOT NULL,

		[< 20% usage] decimal(5,2) NOT NULL, 
		[20-40% usage] decimal(5,2) NOT NULL,
		[40-60% usage] decimal(5,2) NOT NULL,
		
		[< 60% usage] decimal(5,2) NOT NULL,
		[60-90% usage] decimal(5,2) NOT NULL,
		[90-98% usage] decimal(5,2) NOT NULL,
		[99+% usage] decimal(5,2) NOT NULL	
	);

	DECLARE @totalRows int;
	SET @sql = N'SELECT @totalRows = (SELECT COUNT(*) FROM ' + @normalizedName + N'); ';
	EXEC sys.sp_executesql 
		@sql, 
		N'@totalRows int OUTPUT', 
		@totalRows = @totalRows OUTPUT;
	
	DECLARE @targetCoreCount int = @totalCoreCount - @CoreCountCalculationsRange;
	IF @targetCoreCount < 4 SET @targetCoreCount = 4;

	IF @AllowSmallCoreCounts = 1 BEGIN 
		SET @targetCoreCount = 1;
	END;

	DECLARE @additionalCores int = 0;

	WHILE @targetCoreCount <= @totalCoreCount + @CoreCountCalculationsRange BEGIN

		SET @sql = N'WITH partitioned AS ( 
			SELECT 
				[timestamp],

				CASE WHEN [total_cpu_used] < ((@targetCoreCount * 100) * .2) THEN 1 ELSE 0 END [< 20% usage], 
				CASE WHEN [total_cpu_used] > ((@targetCoreCount * 100) * .2) AND [total_cpu_used] <= ((@targetCoreCount * 100) * .40) THEN 1 ELSE 0 END [20-40% usage], 
				CASE WHEN [total_cpu_used] > ((@targetCoreCount * 100) * .4) AND [total_cpu_used] <= ((@targetCoreCount * 100) * .60) THEN 1 ELSE 0 END [40-60% usage], 

				CASE WHEN [total_cpu_used] < ((@targetCoreCount * 100) * .6) THEN 1 ELSE 0 END [< 60% usage], 
				CASE WHEN [total_cpu_used] > ((@targetCoreCount * 100) * .6) AND [total_cpu_used] <= ((@targetCoreCount * 100) * .90) THEN 1 ELSE 0 END [60-90% usage], 
				CASE WHEN [total_cpu_used] > ((@targetCoreCount * 100) * .9) AND [total_cpu_used] <= ((@targetCoreCount * 100) * .98) THEN 1 ELSE 0 END [90-98% usage], 
				
				CASE WHEN [total_cpu_used] > ((@targetCoreCount * 100) * .98) THEN 1 ELSE 0 END [99+% usage], 
				
				[total_cpu_used]
			FROM 
				' + @normalizedName + N'

		), 
		aggregated AS ( 
			SELECT 
				CAST(SUM([< 20% usage]) AS decimal(22,4)) [< 20% usage], 
				CAST(SUM([20-40% usage]) AS decimal(22,4)) [20-40% usage], 
				CAST(SUM([40-60% usage]) AS decimal(22,4)) [40-60% usage],

				CAST(SUM([< 60% usage]) AS decimal(22,4)) [< 60% usage], 
				CAST(SUM([60-90% usage]) AS decimal(22,4)) [60-90% usage], 
				CAST(SUM([90-98% usage]) AS decimal(22,4)) [90-98% usage], 
				CAST(SUM([99+% usage]) AS decimal(22,4)) [99+% usage]
			FROM 
				[partitioned]
		) 

		SELECT 
			@serverName [server], 
			@totalCoreCount [current_core_count], 
			@targetCoreCount [target_core_count],

			CAST((([< 20% usage] / @totalRows)	* 100.0) AS decimal(5,2)) [< 20% usage],
			CAST((([20-40% usage] / @totalRows)	* 100.0) AS decimal(5,2)) [20-40% usage],
			CAST((([40-60% usage] / @totalRows)	* 100.0) AS decimal(5,2)) [40-60% usage],

			CAST((([< 60% usage] / @totalRows)	* 100.0) AS decimal(5,2)) [< 60% usage],
			CAST((([60-90% usage] / @totalRows)	* 100.0) AS decimal(5,2)) [60-90% usage],
			CAST((([90-98% usage] / @totalRows)	* 100.0) AS decimal(5,2)) [90-98% usage],
			CAST((([99+% usage]	/ @totalRows)	* 100.0) AS decimal(5,2)) [99+% usage]	
		FROM 
			[aggregated]; ';

		INSERT INTO [#sizings] (
			[server],
			[current_core_count],
			[target_core_count],
            [< 20% usage], 
            [20-40% usage],
            [40-60% usage],
			[< 60% usage],
			[60-90% usage],
			[90-98% usage],
			[99+% usage]
		)
		EXEC sys.[sp_executesql] 
			@sql, 
			N'@serverName sysname, @totalCoreCount int, @targetCoreCount int, @totalRows int', 
			@serverName = @serverName, 
			@totalCoreCount = @totalCoreCount, 
			@targetCoreCount = @targetCoreCount, 
			@totalRows = @totalRows;

		IF @targetCoreCount = 1 
			SET @targetCoreCount = 2;
		ELSE 
			SET @targetCoreCount = @targetCoreCount + 2;

	END;

	-----------------------------------------------------------------------------------
	-- Final Projection: 
	SET @sql = N'

	SELECT 
		[server],
		--[target_core_count],
		CAST([target_core_count] AS sysname) + CASE WHEN [target_core_count] = @totalCoreCount THEN N'' -> CURRENT'' ELSE N'''' END [target_core_count],
		
		{smallBuckets}
		[< 60% usage],
		[60-90% usage],
		[90-98% usage],
		[99+% usage]
	FROM 
		[#sizings] 
	ORDER BY 
		LEFT([target_core_count], CHARINDEX(N'' '', [target_core_count])); ';

	DECLARE @smallBuckets nvarchar(MAX) = N'[< 20% usage], 
		[20-40% usage],
		[40-60% usage],'

	IF @AllowSmallBuckets = 1 
		SET @sql = REPLACE(@sql, N'{smallBuckets}', @smallBuckets);
	ELSE 
		SET @sql = REPLACE(@sql, N'{smallBuckets}', N'');

	EXEC [admindb].dbo.[print_long_string] @sql;
	
	EXEC sys.[sp_executesql]
		@sql, 
		N'@totalCoreCount int', 
		@totalCoreCount = @totalCoreCount;

	RETURN 0;
GO