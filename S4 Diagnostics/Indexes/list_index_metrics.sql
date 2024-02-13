/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.	

	vNEXT / ADMINDB: 
		- Need to allow 'wildcards' for @TargetTables - i.e., something like @TargetTables = N'Table1, Table2, InventoryPIES%, etc'
				IMPLEMENTATION: Which means... i won't just be doing string-split ... i'll have to do a JOIN vs [{0}].sys.tables ... on ... LIKE ... etcc. 
			- AND, along with the above, I'll need to re-enable the option for @ExcludedTables. so that (with the 'example' above, I could have something like @ExcludedTables = N'%Audit' so that InventoryPIES_xxxx_Audit(s) would be excluded but all InventoryPIES_X|Y|Z would be included, etc. 
			- Likewise, once @ExcludedTables is re-enabled... i need to make sure that it can ONLY be set/non-NULL if/when @TargetTables = {ALL} or ... there are > 1x entries or something in @TargetTables (wildcards would make sense, but I could see 2x or more tables (hard-named) being good enough for exclusions - i guess. 
	
	
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
--	@ExcludedTables								nvarchar(MAX)		= NULL, 
	@ExcludeSystemTables						bit					= 1,
	@IncludeFragmentationMetrics				bit					= 0,						-- really don't care about this - 99% of the time... 
	@MinRequiredTableRowCount					int					= 0,						-- ignore tables with < rows than this value... (but, note: this is per TABLE, not per IX cuz filtered indexes might only have a few rows on a much larger table).
	@OrderBy									sysname				= N'ROW_COUNT',				-- { ROW_COUNT | FRAGMENTATION | SIZE | BUFFER_SIZE | READS | WRITES }
	@IncludeDefinition							bit					= 1,						 -- include/generate the exact definition needed for the IX... 
	@SerializedOutput				xml				= N'<default/>'	    OUTPUT
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
--	SET @ExcludedTables = NULLIF(@ExcludedTables, N'');

	DECLARE @sql nvarchar(MAX);

-- TODO: @ExcludedTables ... and i think I only allow that to work with/against {ALL}
--		as in, if {ALL} then @Excluded can be set, otherwise... i guess there's a potential for @TargetTables to be a LIKE? 
	IF @TargetTables <> N'{ALL}' BEGIN 
		CREATE TABLE #target_tables (
			[table_name] sysname NOT NULL, 
			[object_id] int NULL
		);

		INSERT INTO [#target_tables] ([table_name])
		SELECT [result] FROM dbo.split_string(@TargetTables, N',', 1);

		SET @sql = N'USE [' + @TargetDatabase + N'];
		UPDATE #target_tables 
		SET 
			[object_id] = OBJECT_ID([table_name])
		WHERE 
			[object_id] IS NULL; ';

		EXEC sp_executesql 
			@sql;
	
		IF EXISTS (SELECT NULL FROM [#target_tables] WHERE [object_id] IS NULL) BEGIN 
			SELECT [table_name] [target_table], [object_id] FROM [#target_tables] WHERE [object_id] IS NULL; 

			RAISERROR(N'One or more supplied @TargetTables could not be identified (i.e., does not have a valid object_id). Please remove or correct.', 16, 1);
			RETURN -11;
		END;
	END;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Load Core Meta Data:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	SET @sql = N'	SELECT 
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
		INNER JOIN [{0}].sys.[schemas] s ON [o].[schema_id] = [s].[schema_id]{where}; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	IF @TargetTables = N'{ALL}' BEGIN 
		SET @sql = REPLACE(@sql, N'{where}', N'');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{where}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N' WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N'[i].[object_id] IN (SELECT [object_id] FROM [#target_tables])');
	END;

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

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Usage Stats:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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
		usage.database_id = DB_ID(@TargetDatabase){targets}
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
		AS decimal(5,2)) [seek_ratio]
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
	IF @TargetTables = N'{ALL}' BEGIN 
		SET @sql = REPLACE(@sql, N'{targets}', N'');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{targets}', NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N' AND obj.[object_id] IN (SELECT [object_id] FROM [#target_tables])');
	END;

	CREATE TABLE #usage_stats (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL,
		[user_seeks] bigint NOT NULL,
		[user_scans] bigint NOT NULL,
		[user_lookups] bigint NOT NULL,
		[reads] bigint NULL,
		[writes] bigint NOT NULL,
		[read_write_ratio] decimal(24,2) NULL,
		[seek_ratio] decimal(5,2) NULL
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

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Operational Stats
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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
			sys.dm_db_index_operational_stats(DB_ID(@TargetDatabase),NULL,NULL,NULL){where}
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

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);
	IF @TargetTables = N'{ALL}' BEGIN 
		SET @sql = REPLACE(@sql, N'{where}', N'');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{where}', NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N'WHERE' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N' [object_id] IN (SELECT [object_id] FROM [#target_tables])');
	END;

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

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Physical Stats:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Sizing Stats
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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
			INNER JOIN [{0}].[sys].[allocation_units] [a] ON [p].[partition_id] = [a].[container_id]{where}
		GROUP BY
			[t].[object_id],
			[i].[index_id],
			[p].[rows]; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);
	IF @TargetTables = N'{ALL}' BEGIN 
		SET @sql = REPLACE(@sql, N'{where}', N'');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{where}', NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N'WHERE' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N' [t].[object_id] IN (SELECT [object_id] FROM [#target_tables])');
	END;

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

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Buffering Stats
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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
			INNER JOIN [{0}].sys.indexes AS i ON i.[index_id] = p.[index_id] AND p.[object_id] = i.[object_id]{objects}
	)

	SELECT
		b.[object_id], 
		b.index_id, 
		b.buffered_size_mb
	FROM 
		buffered b ; ';

-- TODO: may need to remap allocation_unit_ids to containers/targets as per example listed here: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-buffer-descriptors-transact-sql?view=sql-server-ver15#examples

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);
	IF @TargetTables = N'{ALL}' BEGIN 
		SET @sql = REPLACE(@sql, N'{objects}', N'');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{objects}', NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9) + N'INNER JOIN #target_tables [t] ON [p].[object_id] = [t].[object_id]');
	END;


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

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Index Definition:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @ixDefinitions xml; 
	EXEC dbo.[script_indexes]
		@TargetDatabase = @TargetDatabase,
		@ExcludeHeaps = 1,
		@IncludeSystemTables = 0,
		@IncludeViews = 0,
		@SerializedOutput = @ixDefinitions OUTPUT; 

	CREATE TABLE #definitions (
		[object_id] int NOT NULL, 
		[index_id] int NOT NULL,
		[key_columns] nvarchar(MAX) NOT NULL, 
		[included_columns] nvarchar(MAX) NULL, 
		[definition] nvarchar(MAX) NOT NULL 
	);

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(object_id)[1]', N'int') [object_id],
			[data].[row].value(N'(index_id)[1]', N'int') [index_id],
			[data].[row].value(N'(key_columns)[1]', N'nvarchar(MAX)') [key_columns],
			[data].[row].value(N'(included_columns)[1]', N'nvarchar(MAX)') [included_columns],
			[data].[row].value(N'(definition)[1]', N'nvarchar(MAX)') [definition]
		FROM 
			@ixDefinitions.nodes(N'//object') [data]([row])
	)	

	INSERT INTO [#definitions] (
		[object_id],
		[index_id],
		[key_columns],
		[included_columns],
		[definition]
	)
	SELECT 
		[object_id],
		[index_id],
		[key_columns],
		[included_columns],
		[definition] 
	FROM 
		[shredded];

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection:
	----------------------------------------------------------------------------------------------------------------------------------------------------------
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

	{projectOrReturn}SELECT 
		--i.[object_id],
		i.[table_name],
		i.[index_id],
		ISNULL(i.[index_name], N'''') [index_name],
		--cd.[definition],
		[d].[key_columns], 
		[d].[included_columns],
		ss.[row_count],
		ISNULL(us.reads, 0) reads, 
		ISNULL(us.writes, 0) writes, 
		us.[read_write_ratio] [ratio], 
		{fragmentation_details}
		ss.allocated_mb, 
		ss.used_mb, 
		--ss.unused_mb,
		ISNULL(bs.buffered_size_mb, 0) cached_mb, 
		--br.buffered_percentage,
		ISNULL(us.user_seeks, 0) seeks, 
		ISNULL(us.user_scans, 0) scans, 
		ISNULL(us.user_lookups, 0) lookups,
		us.seek_ratio, 
		(SELECT 
			[name] ''@name'', [metric] ''@value''  FROM ( 
				VALUES
					(ISNULL(os.avg_row_lock_wait, 0), N''avg_row_lock_ms''),
					(ISNULL(os.avg_page_lock_wait, 0), N''avg_page_lock_ms''), 
					(ISNULL(os.avg_page_io_latch_wait, 0), N''avg_page_io_latch_ms'')
			) AS x([metric], [name])
		FOR XML PATH(''metric''), ROOT(''operational_metrics''), type) [operational_metrics]{definitions}
	FROM 
		#sys_indexes i
		--{IncludedTables}
		--{ExcludedTables}
		LEFT OUTER JOIN #usage_stats us ON i.[object_id] = us.[object_id] AND i.[index_id] = us.index_id
		LEFT OUTER JOIN #operational_stats os ON i.[object_id] = os.[object_id] AND i.index_id = os.index_id
		{physical_stats}
		LEFT OUTER JOIN #sizing_stats ss ON i.[object_id] = ss.[object_id] AND i.index_id = ss.index_id
		LEFT OUTER JOIN [collapsed_buffer_stats] bs ON i.[object_id] = bs.[object_id] AND i.index_id = bs.index_id
		--LEFT OUTER JOIN #column_definitions cd ON i.[object_id] = cd.[object_id] AND i.index_id = cd.index_id
		LEFT OUTER JOIN #definitions [d] ON [i].[object_id] = [d].[object_id] AND [i].[index_id] = [d].[index_id]
	WHERE
		1 = 1
		{IncludeSystemTables}
		{MinRequiredTableRowCount}
	ORDER BY 
		{ORDERBY} DESC{forxml}; ';

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
		SET @sql = REPLACE(@sql, N'{IncludedTables}', N'INNER JOIN #target_tables targets ON i.table_name LIKE targets.table_name ');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{IncludedTables}', N'');
	END;

	-- etc... 
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	IF @IncludeDefinition = 1 BEGIN 
		SET @sql = REPLACE(@sql, N'{definitions}', N',' + @crlf + @tab + N'[d].[definition] [index_definition]');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{definitions}', N'');
	END;

	--IF @ExcludedTables IS NOT NULL BEGIN 
		
	--	SELECT [result] [table_name] 
	--	INTO #excluded_tables
	--	FROM dbo.[split_string](@ExcludedTables, N',', 1);		

	--	SET @sql = REPLACE(@sql, N'{ExcludedTables}', N'INNER JOIN #excluded_tables excluded ON i.table_name NOT LIKE excluded.table_name');
	--  END; 
	--ELSE BEGIN 
	--	SET @sql = REPLACE(@sql, N'{ExcludedTables}', N'');
	--END;

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

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- RETURN instead of project.. 
		DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

		-- NOTE: the following line INCLUDES the ) for nesting the select @output = (nested_goes_here):
		SET @sql = REPLACE(@sql, N'{forxml}', @crlftab + N'FOR XML PATH(N''index''), ROOT (N''indexes''))');
		SET @sql = REPLACE(@sql, N'{projectOrReturn}', N'SELECT @output = (');

		PRINT @sql;
		DECLARE @output xml;
		EXEC [sys].[sp_executesql]
			@sql, 
			N'@output xml OUTPUT', 
			@output = @output OUTPUT;

		SET @SerializedOutput = @output;

		RETURN 0;
	END;

	SET @sql = REPLACE(@sql, N'{forxml}', N'');
	SET @sql = REPLACE(@sql, N'{projectOrReturn}', N'');
	EXEC sp_executesql 
		@sql;

	RETURN 0;
GO