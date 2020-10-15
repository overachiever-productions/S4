/*
	vNEXT:
		- Possibly: 
			change 'ratio' to 'benefit' - and/or make it more apparent what's going on relative to this 'benefit' (or lack thereof).

		- integrate:
			D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Diagnostics\Get Forwarded Record Counts.sql

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_index_metrics','P') IS NOT NULL
	DROP PROC dbo.[list_index_metrics];
GO

CREATE PROC dbo.[list_index_metrics]
	@TargetDatabase								sysname				= NULL,						-- can/will be derived by execution context. 
	@TargetTables								nvarchar(MAX)		= N'{ALL}',   
	@ExcludedTables								nvarchar(MAX)		= NULL, 
	@ExcludeSystemTables						bit					= 1,
	@IncludeFragmentationMetrics				bit					= 0,		-- really don't care about this - 99% of the time... 
	@MinRequiredTableRowCount					int					= 0,		-- ignore tables with < rows than this value... (but, note: this is per TABLE, not per IX cuz filtered indexes might only have a few rows on a much larger table).
	@OrderBy									sysname				= N'ROW_COUNT'					-- { ROW_COUNT | FRAGMENTATION | SIZE | BUFFER_SIZE | READS | WRITES }

	--	vNEXT:
	--		NOTE: the following will be implemented by a sproc: dbo.script_index (which required dbname, table-name, and IX name or [int]ID).
	--@IncludeScriptDefinition					bit					= 1   -- include/generate the exact definition needed for the IX... 
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

	SET @TargetTables = ISNULL(NULLIF(@TargetTables, N''), N'{ALL}'); 
	SET @ExcludedTables = NULLIF(@ExcludedTables, N'');

	DECLARE @sql nvarchar(MAX);

	---------------------------------------------------------------------------------------------------------------------------------------
	-- load core meta-data:
	SET @sql = N'SELECT 
		[i].[object_id],
		[i].[index_id],
		[o].[type],
		[s].[name] [schema_name],
		[o].[name] [table_name],
		[i].[name] [index_name],
		[i].[type_desc],
		[i].[is_unique],
		[i].[ignore_dup_key],
		[i].[is_primary_key],
		[i].[is_unique_constraint],
		[i].[fill_factor],
		[i].[is_padded],
		[i].[is_disabled],
		[i].[is_hypothetical],
		[i].[allow_row_locks],
		[i].[allow_page_locks],
		[i].[filter_definition]
	FROM 
		[{0}].sys.indexes i
		INNER JOIN [{0}].sys.objects o ON [i].[object_id] = [o].[object_id]
		INNER JOIN [{0}].sys.[schemas] s ON [o].[schema_id] = [s].[schema_id]; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	CREATE TABLE #sys_indexes (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL,
		[type] char(2) NULL,
		[schema_name] sysname NOT NULL,
		[table_name] sysname NOT NULL,
		[index_name] sysname NULL,
		[type_desc] nvarchar(60) NULL,
		[is_unique] bit NULL,
		[ignore_dup_key] bit NULL,
		[is_primary_key] bit NULL,
		[is_unique_constraint] bit NULL,
		[fill_factor] tinyint NOT NULL,
		[is_padded] bit NULL,
		[is_disabled] bit NULL,
		[is_hypothetical] bit NULL,
		[allow_row_locks] bit NULL,
		[allow_page_locks] bit NULL,
		[filter_definition] nvarchar(max) NULL
	);

	INSERT INTO [#sys_indexes] (
		[object_id],
		[index_id],
		[type],
		[schema_name],
		[table_name],
		[index_name],
		[type_desc],
		[is_unique],
		[ignore_dup_key],
		[is_primary_key],
		[is_unique_constraint],
		[fill_factor],
		[is_padded],
		[is_disabled],
		[is_hypothetical],
		[allow_row_locks],
		[allow_page_locks],
		[filter_definition]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@TargetDatabase sysname', 
		@TargetDatabase = @TargetDatabase;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- usage stats:
	SET @sql = N'WITH usage_stats AS (
	SELECT
		obj.[object_id],
		ixs.[index_id],
		usage.[user_seeks], 
		usage.[user_scans], 
		usage.[user_lookups],
		usage.user_seeks + usage.user_scans + usage.user_lookups [reads],
		usage.[user_updates] [writes]
	FROM
		[{0}].sys.dm_db_index_usage_stats usage
		INNER JOIN [{0}].sys.indexes ixs ON usage.[object_id] = ixs.[object_id] AND ixs.[index_id] = usage.[index_id]
		INNER JOIN [{0}].sys.objects obj ON usage.[object_id] = obj.[object_id]
	WHERE
		usage.database_id = DB_ID(@TargetDatabase)
	)

	SELECT
		[object_id],
		[index_id],
		[user_seeks], 
		[user_scans], 
		[user_lookups],
		[reads],
		[writes],
		CAST (
			CASE 
				WHEN writes = 0 THEN reads 
				WHEN reads = 0 AND writes > 0 THEN 0 - writes
				ELSE CAST(reads as decimal(24,2)) / CAST(writes as decimal(24,2))
			END 
		as decimal(24,2)) [read_write_ratio], 
		CAST( 
			CASE 
				WHEN user_seeks > user_scans THEN CAST(user_seeks AS decimal(24,2)) / (CAST(user_seeks AS decimal(24,2)) + CAST(user_scans AS decimal(24,2))) * 100.0 
				ELSE 0
			END
		AS decimal(24,2)) [seek_ratio]
	FROM
		usage_stats
	ORDER BY
		[read_write_ratio] DESC; ';

---------------------------------------------------------------------------------------------------------------------------------------
-- TODO: [ratio] calculations have 2x problems: a) short-circuiting of CASE operators (compare BOTH values); b) 'simple' ratio probably isn't the BEST approach here. 
-- vNEXT: address issue with simple-ratio not being the best option/outcome here... 
--			could be something as simple as: "likelihood of current use" ... HIGH,MED,LOW*,NONE* - where warnings would obviously go with low/none... 
--					and column name could be [usage] - and... could be based on the ratio > x ...and or situations where reads > xK or some PERCENTAGE of writes...
---------------------------------------------------------------------------------------------------------------------------------------

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	CREATE TABLE #usage_stats (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL,
		[user_seeks] bigint NOT NULL,
		[user_scans] bigint NOT NULL,
		[user_lookups] bigint NOT NULL,
		[reads] bigint NULL,
		[writes] bigint NOT NULL,
		[read_write_ratio] decimal(24,2) NULL,
		[seek_ratio] decimal(24,2) NULL
	);

	INSERT INTO [#usage_stats] (
		[object_id],
		[index_id],
		[user_seeks],
		[user_scans],
		[user_lookups],
		[reads],
		[writes],
		[read_write_ratio],
		[seek_ratio]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@TargetDatabase sysname', 
		@TargetDatabase = @TargetDatabase;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- operational stats:
	SET @sql = N'WITH operational_stats AS ( 
		SELECT 
			object_id,
			index_id,
			SUM(row_lock_count) [row_lock_count],
			SUM(row_lock_wait_in_ms) [row_lock_waits],
			SUM(page_lock_count) [page_lock_count],
			SUM(page_lock_wait_in_ms) [page_lock_waits], 
			SUM(page_io_latch_wait_count) [page_io_latch_count],
			SUM(page_io_latch_wait_in_ms) [page_io_latch_waits]--, 
			-- TODO: output any of the following columns that make sense (into the operational_details xml):
			--SUM(leaf_insert_count) [leaf_insert_count],
			--SUM(leaf_delete_count) [leaf_delete_count],
			--SUM(leaf_update_count) [leaf_update_count],
			--SUM(leaf_ghost_count) [leaf_ghost_count],  -- does''t include retained rows via snapshot isolation
			--SUM(range_scan_count) [ranges_scan_count],
			--SUM(singleton_lookup_count) [seek_count],
			--SUM(forwarded_fetch_count) [forwarded_count]
		FROM 
			sys.dm_db_index_operational_stats(DB_ID(@TargetDatabase),NULL,NULL,NULL)
		GROUP BY 
			[object_id], index_id
	 )  

	 SELECT 
		[object_id], 
		index_id,
		[row_lock_waits] [row_lock_wait_MS],
		CASE 
			WHEN [row_lock_count] = 0 THEN 0
			ELSE CAST(CAST([row_lock_waits] AS decimal(24,2)) / CAST([row_lock_count] AS decimal(24,2)) AS decimal(24,2))
		END [avg_row_lock_wait], 
		[page_lock_waits] [page_lock_wait_MS],
		CASE 
			WHEN [page_lock_count] = 0 THEN 0
			ELSE CAST(CAST([page_lock_waits] AS decimal(24,2)) / CAST([page_lock_count] AS decimal(24,2)) AS decimal(24,2)) 
		END [avg_page_lock_wait], 
		[page_io_latch_waits] [page_io_latch_wait_MS],
		CASE
			WHEN [page_io_latch_count] = 0 THEN 0 
			ELSE CAST(CAST([page_io_latch_waits] AS decimal(24,2)) / CAST([page_io_latch_count] AS decimal(24,2)) AS decimal(24,2)) 
		END [avg_page_io_latch_wait] 
	FROM 
		operational_stats; ';

	CREATE TABLE #operational_stats (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL,
		[row_lock_wait_MS] bigint NULL,
		[avg_row_lock_wait] decimal(24,2) NULL,
		[page_lock_wait_MS] bigint NULL,
		[avg_page_lock_wait] decimal(24,2) NULL,
		[page_io_latch_wait_MS] bigint NULL,
		[avg_page_io_latch_wait] decimal(24,2) NULL
	);

	INSERT INTO [#operational_stats] (
		[object_id],
		[index_id],
		[row_lock_wait_MS],
		[avg_row_lock_wait],
		[page_lock_wait_MS],
		[avg_page_lock_wait],
		[page_io_latch_wait_MS],
		[avg_page_io_latch_wait]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@TargetDatabase sysname', 
		@TargetDatabase = @TargetDatabase;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- physical stats: 

	CREATE TABLE #physical_stats (
		[object_id] int NULL,
		[index_id] int NULL,
		[alloc_unit_type_desc] nvarchar(60) NULL,
		[index_depth] tinyint NULL,
		[index_level] tinyint NULL,
		[avg_fragmentation_percent] decimal(5,2) NULL,
		[fragment_count] bigint NULL
	);

	IF @IncludeFragmentationMetrics = 1 BEGIN

		SET @sql = N'SELECT
			[object_id],
			index_id,
			alloc_unit_type_desc, 
			index_depth, 
			index_level, 
			CAST(avg_fragmentation_in_percent AS decimal(5,2)) avg_fragmentation_percent,
			fragment_count
		FROM 
			sys.dm_db_index_physical_stats(DB_ID(@TargetDatabase), NULL, -1, 0, ''LIMITED''); ';

		INSERT INTO [#physical_stats] (
			[object_id],
			[index_id],
			[alloc_unit_type_desc],
			[index_depth],
			[index_level],
			[avg_fragmentation_percent],
			[fragment_count]
		)
		EXEC [sys].[sp_executesql]
			@sql, 
			N'@TargetDatabase sysname', 
			@TargetDatabase = @TargetDatabase;

	END;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- sizing stats:
	SET @sql = N'SELECT
			[t].[object_id],
			[i].[index_id],
			[p].[rows] AS [row_count],
			CAST(((SUM([a].[total_pages]) * 8) / 1024.0) AS decimal(24, 2)) AS [allocated_mb],
			CAST(((SUM([a].[used_pages]) * 8) / 1024.0) AS decimal(24, 2)) AS [used_mb],
			CAST((((SUM([a].[total_pages]) - SUM([a].[used_pages])) * 8) / 1024.0) AS decimal(24, 2)) AS [unused_mb]
		FROM
			[{0}].[sys].[tables] [t]
			INNER JOIN [{0}].[sys].[indexes] [i] ON [t].[object_id] = [i].[object_id]
			INNER JOIN [{0}].[sys].[partitions] [p] ON [i].[object_id] = [p].[object_id] AND [i].[index_id] = [p].[index_id]
			INNER JOIN [{0}].[sys].[allocation_units] [a] ON [p].[partition_id] = [a].[container_id]
		GROUP BY
			[t].[object_id],
			[i].[index_id],
			[p].[rows]; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	CREATE TABLE #sizing_stats (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL,
		[row_count] bigint NULL,
		[allocated_mb] decimal(24,2) NULL,
		[used_mb] decimal(24,2) NULL,
		[unused_mb] decimal(24,2) NULL
	);

	INSERT INTO [#sizing_stats] (
		[object_id],
		[index_id],
		[row_count],
		[allocated_mb],
		[used_mb],
		[unused_mb]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@TargetDatabase sysname', 
		@TargetDatabase = @TargetDatabase;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- buffering stats: 
	SET @sql = N'SELECT
		allocation_unit_id,
		COUNT(*) cached_page_count
	INTO 
		#buffers	
	FROM 
		sys.dm_os_buffer_descriptors WITH(NOLOCK)
	WHERE 
		[database_id] = DB_ID(@TargetDatabase)
	GROUP BY 
		[allocation_unit_id];
	
	WITH buffered AS ( 
		SELECT
			p.[object_id],
			p.[index_id],
			CAST((buffers.[cached_page_count]) * 8.0 / 1024.0 AS decimal(24,2)) AS [buffered_size_mb]
		FROM
			[#buffers] buffers
			INNER JOIN [{0}].sys.allocation_units AS au ON au.[allocation_unit_id] = buffers.[allocation_unit_id]
			INNER JOIN [{0}].sys.partitions AS p ON au.[container_id] = p.[partition_id]
			INNER JOIN [{0}].sys.indexes AS i ON i.[index_id] = p.[index_id] AND p.[object_id] = i.[object_id]
	)

	SELECT
		b.[object_id], 
		b.index_id, 
		b.buffered_size_mb
	FROM 
		buffered b ; ';

-- TODO: may need to remap allocation_unit_ids to containers/targets as per example listed here: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-buffer-descriptors-transact-sql?view=sql-server-ver15#examples

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	CREATE TABLE #buffer_stats (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL,
		[buffered_size_mb] decimal(24,2) NULL
	);

	INSERT INTO [#buffer_stats] (
		[object_id],
		[index_id],
		[buffered_size_mb]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@TargetDatabase sysname', 
		@TargetDatabase = @TargetDatabase;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- index definition:
	DECLARE serializer CURSOR FAST_FORWARD FOR
	SELECT 
		[object_id], 
		[index_id]
	FROM 
		#sys_indexes
	ORDER BY 
		[object_id], 
		[index_id];

	DECLARE @object_id int;
	DECLARE @index_id int;
	DECLARE @serialized nvarchar(MAX);

	CREATE TABLE #definitions (
		[object_id] int, 
		index_id int, 
		[definition] nvarchar(MAX)
	);

	SET @sql = N'WITH core AS ( 
		SELECT 
			CASE 
				WHEN ic.is_descending_key = 1 AND ic.is_included_column = 1 THEN N''['' + c.[name] + N'' DESC]''
				WHEN ic.is_descending_key = 0 AND ic.is_included_column = 1 THEN N''['' + c.[name] + N'']''
				ELSE c.[name]
			END [name], 
			index_column_id [ordinal]
		FROM 
			[{0}].sys.index_columns ic
			INNER JOIN [{0}].sys.columns c ON ic.[object_id] = c.[object_id] AND ic.column_id = c.column_id
		WHERE 
			ic.[object_id] = @object_id
			AND ic.[index_id] = @index_id
	) 

	SELECT @serialized = @serialized + [name] + N'','' FROM core ORDER BY ordinal; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	OPEN serializer;
	FETCH NEXT FROM serializer INTO @object_id, @index_id;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @serialized = '';

		IF @index_id <> 0 BEGIN
			EXEC sp_executesql 
				@sql,
				N'@object_id int, @index_id int, @serialized nvarchar(MAX) OUTPUT', 
				@object_id = @object_id, 
				@index_id = @index_id,
				@serialized = @serialized OUTPUT;

			SET @serialized = SUBSTRING(@serialized, 0, LEN(@serialized));
		END;
	
		INSERT INTO #definitions VALUES (@object_id, @index_id, @serialized);
	
		FETCH NEXT FROM serializer INTO @object_id, @index_id;
	END;

	CLOSE serializer;
	DEALLOCATE serializer;

	SELECT 
		d.[object_id],
		d.[index_id],
		CASE WHEN d.index_id = 0 THEN '<HEAP>' ELSE d.[definition] END [definition]
	INTO 
		#column_definitions
	FROM 
		#definitions d;

	---------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection:
	---------------------------------------------------------------------------------------------------------------------------------------
	
	SET @sql = N'WITH collapsed_physical_stats AS (
		SELECT 
			[object_id], 
			index_id,
			SUM([avg_fragmentation_percent]) [avg_fragmentation_percent], 
			SUM([fragment_count]) [fragment_count]
		FROM 
			[#physical_stats]	
		GROUP BY	
			[object_id], 
			index_id
	), 
	collapsed_buffer_stats AS ( 
		SELECT 
			[object_id], 
			index_id,
			SUM([buffered_size_mb]) [buffered_size_mb]
		FROM 
			[#buffer_stats]
		GROUP BY 
			[object_id], 
			index_id
	)

	SELECT 
		--i.[object_id],
		i.[table_name],
		i.[index_id],
		ISNULL(i.[index_name], N'''') [index_name],
		cd.[definition],
		ss.[row_count],
		ISNULL(us.reads, 0) reads, 
		ISNULL(us.writes, 0) writes, 
		us.[read_write_ratio] [ratio], 
		ISNULL(os.avg_row_lock_wait, 0) avg_row_lock_ms, 
		ISNULL(os.avg_page_lock_wait, 0) avg_page_lock_ms,
		ISNULL(os.avg_page_io_latch_wait, 0) avg_page_io_latch_ms,
		{fragmentation_details}
		ss.allocated_mb, 
		ss.used_mb, 
		--ss.unused_mb,
		ISNULL(bs.buffered_size_mb, 0) cached_mb, 
		--br.buffered_percentage,
		ISNULL(us.user_seeks, 0) seeks, 
		ISNULL(us.user_scans, 0) scans, 
		ISNULL(us.user_lookups, 0) lookups,
		us.seek_ratio
	FROM 
		#sys_indexes i
		{IncludedTables}
		{ExcludedTables}
		LEFT OUTER JOIN #usage_stats us ON i.[object_id] = us.[object_id] AND i.[index_id] = us.index_id
		LEFT OUTER JOIN #operational_stats os ON i.[object_id] = os.[object_id] AND i.index_id = os.index_id
		{physical_stats}
		LEFT OUTER JOIN #sizing_stats ss ON i.[object_id] = ss.[object_id] AND i.index_id = ss.index_id
		LEFT OUTER JOIN [collapsed_buffer_stats] bs ON i.[object_id] = bs.[object_id] AND i.index_id = bs.index_id
		LEFT OUTER JOIN #column_definitions cd ON i.[object_id] = cd.[object_id] AND i.index_id = cd.index_id
	WHERE
		1 = 1
		{IncludeSystemTables}
		{MinRequiredTableRowCount}
	ORDER BY 
		{ORDERBY} DESC; ';

	-- predicates:
	IF @ExcludeSystemTables = 1 
		SET @sql = REPLACE(@sql, N'{IncludeSystemTables}', N'AND i.[type] = ''U'' '); -- exclude 'S'
	ELSE 
		SET @sql = REPLACE(@sql, N'{IncludeSystemTables}', N'');

	IF @MinRequiredTableRowCount <> 0 
		SET @sql = REPLACE(@sql, N'{MinRequiredTableRowCount}', N'AND ss.[row_count] > ' + CAST(@MinRequiredTableRowCount AS sysname));
	ELSE 
		SET @sql = REPLACE(@sql, N'{MinRequiredTableRowCount}', N'');

	IF @IncludeFragmentationMetrics = 1 BEGIN
		SET @sql = REPLACE(@sql, N'{fragmentation_details}', N'ps.avg_fragmentation_percent [fragmentation_%], ISNULL(ps.fragment_count, 0) [fragments],');
		SET @sql = REPLACE(@sql, N'{physical_stats}', N'LEFT OUTER JOIN [collapsed_physical_stats] ps ON i.[object_id] = ps.[object_id] AND i.index_id = ps.index_id');
	  END;
	ELSE BEGIN
		SET @sql = REPLACE(@sql, N'{fragmentation_details}', N'');
		SET @sql = REPLACE(@sql, N'{physical_stats}', N'');
	END;

	IF @TargetTables <> N'{ALL}' BEGIN 
		
		SELECT [result] [table_name] 
		INTO #target_tables
		FROM dbo.[split_string](@TargetTables, N',', 1);

		SET @sql = REPLACE(@sql, N'{IncludedTables}', N'INNER JOIN #target_tables targets ON i.table_name LIKE targets.table_name ');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{IncludedTables}', N'');
	END;

	IF @ExcludedTables IS NOT NULL BEGIN 
		
		SELECT [result] [table_name] 
		INTO #excluded_tables
		FROM dbo.[split_string](@ExcludedTables, N',', 1);		

		SET @sql = REPLACE(@sql, N'{ExcludedTables}', N'INNER JOIN #excluded_tables excluded ON i.table_name NOT LIKE excluded.table_name');
	  END; 
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{ExcludedTables}', N'');
	END;

	-- sort order:
	DECLARE @sort sysname; 
	SELECT @sort = CASE NULLIF(@OrderBy, N'')
		WHEN NULL THEN N'ss.[row_count]'
		WHEN N'FRAGMENTATION' THEN N'ps.avg_fragmentation_percent'
		WHEN N'SIZE' THEN N'ss.allocated_mb'
		WHEN N'BUFFER_SIZE' THEN N'bs.buffered_size_mb'
		WHEN N'READS' THEN N'us.reads'
		WHEN N'WRITES' THEN N'us.writes' 
		ELSE N'ss.[row_count]'
	END;

	SET @sql = REPLACE(@sql, N'{ORDERBY}', @sort);

	EXEC sp_executesql 
		@sql;

	RETURN 0;
GO
