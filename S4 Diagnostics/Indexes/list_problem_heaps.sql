/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_problem_heaps','P') IS NOT NULL
	DROP PROC dbo.[list_problem_heaps];
GO

CREATE PROC dbo.[list_problem_heaps]
	@TargetDatabase							sysname, 
	@PageUsagePercentBelowThreshold			decimal(5,2)	= 20.0
AS
    SET NOCOUNT ON; 

	SET @PageUsagePercentBelowThreshold = ISNULL(@PageUsagePercentBelowThreshold, 20.0);

	-- {copyright}

	CREATE TABLE #sizes (
		[object_id] int NOT NULL, 
		[heap_name] sysname NOT NULL, 
		[row_count] bigint NOT NULL, 
		[reserved_gb] decimal(10,1) NOT NULL,
		[data_gb] decimal(10,1) NOT NULL, 
		[indexes_gb] decimal(10,1) NOT NULL, 
		[unused_gb] decimal(10,1) NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'WITH metrics AS ( 
			SELECT
				[ps].[object_id],
				SUM(CASE WHEN ([ps].[index_id] < 2) THEN [row_count] ELSE 0	END) AS [row_count],
				SUM([ps].[reserved_page_count]) AS [reserved],
				SUM(CASE WHEN ([ps].[index_id] < 2) THEN ([ps].[in_row_data_page_count] + [ps].[lob_used_page_count] + [ps].[row_overflow_used_page_count]) ELSE ([ps].[lob_used_page_count] + [ps].[row_overflow_used_page_count])	END) AS [data],
				SUM([ps].[used_page_count]) AS [used]
			FROM
				[{targetDatabase}].[sys].[dm_db_partition_stats] [ps]
			WHERE
				[ps].[object_id] NOT IN (SELECT [object_id] FROM [sys].[tables] WHERE [is_memory_optimized] = 1)
			GROUP BY
				[ps].[object_id]	
	), 
	expanded AS ( 
		SELECT 
			[m].[object_id],
			[m].[row_count], 
			[m].[reserved] * 8 [reserved], 
			[m].[data] * 8 [data],
			CASE WHEN [m].[used] > [m].[data] THEN [m].[used] - [m].[data] ELSE 0 END * 8 [index_size], 
			CASE WHEN [m].[reserved] > [m].[used] THEN [m].[reserved] - [m].[used] ELSE 0 END * 8 [unused]
		FROM 
			[metrics] [m]
	)

	SELECT
		[e].[object_id],
		[s].[name] + N''.'' + [t].[name] [table_name],
		[e].[row_count] [row_count],
		[e].[reserved] / 1048576.00 [reserved_gb],
		[e].[data] / 1048576.00 [data_gb],
		[e].[index_size] / 1048576.00 [indexes_gb], 
		[e].[unused] / 1048576.00 [unused_gb]
	FROM 
		[expanded] [e]
		INNER JOIN [{targetDatabase}].sys.[tables] [t] ON [e].[object_id] = [t].[object_id]
		INNER JOIN [{targetDatabase}].sys.schemas [s] ON [t].[schema_id] = [s].[schema_id]; ';
		
	SET @sql = REPLACE(@sql, N'{targetDatabase}', @TargetDatabase);

	IF (SELECT dbo.[get_engine_version]()) <= 11.00 BEGIN 
		SET @sql = REPLACE(@sql, N'
			WHERE
				[ps].[object_id] NOT IN (SELECT [object_id] FROM [sys].[tables] WHERE [is_memory_optimized] = 1)', N'');
	END;

	INSERT INTO [#sizes] (
		[object_id],
		[heap_name],
		[row_count],
		[reserved_gb],
		[data_gb],
		[indexes_gb],
		[unused_gb]
	)
	EXEC sys.[sp_executesql]
		@sql;
	
	/* Identify HEAPS with avg_page_space_used_in_percent < @PageUsagePercent  */
	CREATE TABLE #potentialProblems (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[object_id] int NOT NULL,
		[heap_name] sysname NOT NULL, 
		[avg_page_space_used_in_percent] decimal(5,2) NOT NULL,
		[page_count] bigint NOT NULL,
		[record_count] bigint NOT NULL,
		[ghost_record_count] bigint NOT NULL,
		[avg_record_size_in_bytes] float NOT NULL,
		[forwarded_record_count] bigint NOT NULL
	);

	SET @sql = N'WITH heaps AS (
		SELECT 
			[i].[object_id], 
			[t].[name] [table_name]
		FROM 
			[{targetDatabase}].sys.[indexes] [i]
			INNER JOIN [{targetDatabase}].sys.[tables] [t] ON [i].[object_id] = [t].[object_id]
		WHERE 
			[i].[type] = 0 
			AND [i].[is_hypothetical] = 0
	)

	SELECT 
		[h].[object_id],
		[h].[table_name] [heap_name],
		[s].[avg_page_space_used_in_percent],
		[s].[page_count],
		[s].[record_count],
		[s].[ghost_record_count],
		[s].[avg_record_size_in_bytes],
		[s].[forwarded_record_count]
	FROM 
		heaps h
		CROSS APPLY sys.[dm_db_index_physical_stats](DB_ID(''{targetDatabase}''), [h].[object_id], 0, NULL, N''SAMPLED'') s
	WHERE
		[s].[record_count] > 0
		AND [s].[page_count] > 1300  -- don''t bother with tables < ~10MB in size... 
		AND [s].[avg_page_space_used_in_percent] < @PageUsagePercentBelowThreshold; ';

	SET @sql = REPLACE(@sql, N'{targetDatabase}', @TargetDatabase);

	INSERT INTO [#potentialProblems] (
		[object_id],
		[heap_name],
		[avg_page_space_used_in_percent],
		[page_count],
		[record_count],
		[ghost_record_count],
		[avg_record_size_in_bytes],
		[forwarded_record_count]
	)
	EXEC sp_executesql
		@sql, 
		N'@PageUsagePercentBelowThreshold decimal(5,2)', 
		@PageUsagePercentBelowThreshold = @PageUsagePercentBelowThreshold;	


	/* Now that we've identified POTENTIAL problems, grab more detailed metrics */
	CREATE TABLE #detailedFragmentation (
		[object_id] int NOT NULL, 
		[avg_fragmentation_in_percent] decimal(5,2) NOT NULL
	);

	SET @sql = N'SELECT 
		[p].[object_id],
		[s].[avg_fragmentation_in_percent]
	FROM 
		[#potentialProblems] p 
		CROSS APPLY sys.[dm_db_index_physical_stats](DB_ID(''{targetDatabase}''), [p].[object_id], 0, NULL, ''DETAILED'') s; ';

	SET @sql = REPLACE(@sql, N'{targetDatabase}', @TargetDatabase);

	INSERT INTO [#detailedFragmentation] (
		[object_id],
		[avg_fragmentation_in_percent]
	)
	EXEC sp_executesql
		@sql;

	--SELECT * FROM [#tableSizes];
	--SELECT * FROM [#potentialProblems];
	--SELECT * FROM [#detailedFragmentation];

	WITH core AS ( 
		SELECT 
			[p].[heap_name],
			[s].[row_count], 
			[s].[reserved_gb], 
			[s].[data_gb], 
			[s].[indexes_gb],
			[f].[avg_fragmentation_in_percent],
			[p].[avg_page_space_used_in_percent],
			[p].[ghost_record_count],
			[p].[forwarded_record_count],
			[p].[avg_record_size_in_bytes],
			([p].[avg_record_size_in_bytes] * [p].[record_count]) / 1073741824.000 [expected_size_gb]

		FROM 
			[#potentialProblems] [p]
			INNER JOIN [#detailedFragmentation] [f] ON [p].[object_id] = [f].[object_id]
			INNER JOIN [#sizes] [s] ON [p].[object_id] = [s].[object_id]
	) 

	SELECT 
		[heap_name],
		FORMAT([row_count], N'N0') [row_count],
		FORMAT([reserved_gb], N'N1') [reserved_gb],
		FORMAT([data_gb], N'N1') [data_gb],
		FORMAT([indexes_gb], N'N1') [indexes_gb],
		'' [ ],
		FORMAT([avg_fragmentation_in_percent], N'N1') [avg_frag_%],
		FORMAT([avg_page_space_used_in_percent], N'N1') [avg_page_use_%],
		FORMAT([ghost_record_count], N'N0') [ghost_records],
		FORMAT([forwarded_record_count], N'N0') [forwarded_records],
		FORMAT([avg_record_size_in_bytes], N'N1') [avg_record_size],
		'' [=>],
		FORMAT([expected_size_gb], N'N1') [expected_size_gb], 
		CASE WHEN [reserved_gb] > [expected_size_gb] THEN FORMAT((([reserved_gb] - [expected_size_gb])), N'N1') ELSE FORMAT((0 - [expected_size_gb] - [reserved_gb]), N'N1') END [size_diff_gb]
	FROM 
		core 
	ORDER BY 
		[core].[reserved_gb] DESC;

	RETURN 0;
GO	