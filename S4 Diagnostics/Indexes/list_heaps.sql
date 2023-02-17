/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_heaps','P') IS NOT NULL
	DROP PROC dbo.[list_heaps];
GO

CREATE PROC dbo.[list_heaps]
		@TargetDatabase							sysname
AS
    SET NOCOUNT ON; 

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


	CREATE TABLE #heaps (
		[object_id] int NOT NULL,
		[heap_name] sysname NOT NULL, 
		[avg_page_space_used_in_percent] decimal(5,2) NULL,
		[ghost_record_count] bigint NULL,
		[avg_record_size_in_bytes] float NULL,
		[forwarded_record_count] bigint NULL
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
		[s].[ghost_record_count],
		[s].[avg_record_size_in_bytes],
		[s].[forwarded_record_count]
	FROM 
		heaps h
		CROSS APPLY sys.[dm_db_index_physical_stats](DB_ID(''{targetDatabase}''), [h].[object_id], 0, NULL, N''SAMPLED'') s; ';

	SET @sql = REPLACE(@sql, N'{targetDatabase}', @TargetDatabase);

	INSERT INTO [#heaps] (
		[object_id],
		[heap_name],
		[avg_page_space_used_in_percent],
		[ghost_record_count],
		[avg_record_size_in_bytes],
		[forwarded_record_count]
	)
	EXEC sp_executesql 
		@sql;


	WITH heaps AS (
		SELECT 
			[object_id],
			[heap_name],
			SUM(ISNULL([avg_page_space_used_in_percent], 0.0)) [avg_page_space_used_in_percent],
			SUM(ISNULL([ghost_record_count],0)) [ghost_record_count],
			SUM(ISNULL([avg_record_size_in_bytes], 0.0)) [avg_record_size_in_bytes],
			SUM(ISNULL([forwarded_record_count], 0)) [forwarded_record_count]
		FROM 
			[#heaps] 
		GROUP BY 
			[object_id], [heap_name]
	)

	SELECT 
		[h].[heap_name],
		[s].[row_count],
		[s].[reserved_gb],
		[s].[data_gb],
		[s].[indexes_gb],
		[s].[unused_gb],
		N'' [ ],
		[h].[avg_page_space_used_in_percent],
		[h].[ghost_record_count],
		[h].[avg_record_size_in_bytes],
		[h].[forwarded_record_count]
	FROM 
		[heaps] [h]
		INNER JOIN [#sizes] [s] ON [h].[object_id] = [s].[object_id]
	ORDER BY 
		[s].[reserved_gb] DESC;

	RETURN 0;
GO