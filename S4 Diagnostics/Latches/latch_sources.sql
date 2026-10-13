/*

	for locks:
		row and page locks ... count and ms ... so'z I can calculate avg of each. 


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[latch_sources]', N'P') IS NOT NULL
	DROP PROC dbo.[latch_sources];
GO

CREATE PROC dbo.[latch_sources]
	@granularity					sysname = N'SERVER',		-- { SERVER | DATABASE | TABLE }
	@order_by						sysname = N'AVG_LEAF',		-- { TOTAL_LEAF | AVG_LEAF | TOTAL_TREE | AVG_TREE | TOTAL_IO | AVG_IO }
	@exclude_system_objects			bit = 1,					-- { 0 | 1 }
	@databases						nvarchar(MAX) = NULL, 
	@tables							nvarchar(MAX) = NULL, 
	@indexes						nvarchar(MAX) = NULL	
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @databases = NULLIF(@databases, N'');
	SET @tables = NULLIF(@tables, N'');
	SET @indexes = NULLIF(@indexes, N'');
	SET @exclude_system_objects = ISNULL(@exclude_system_objects, 1);

	SET @granularity = UPPER(ISNULL(NULLIF(@granularity, N''), N'SERVER'));
	SET @order_by = UPPER(ISNULL(NULLIF(@order_by, N''), N'AVG_LEAF'));
	
	IF @granularity NOT IN (N'SERVER', N'DATABASE', N'TABLE') BEGIN 
		RAISERROR(N'Valid values for @granularity are: { SERVER | DATABASE | TABLE }.', 16, 1);
		RETURN -1;
	END;

	IF @order_by NOT IN (N'TOTAL_LEAF', N'AVG_LEAF', N'TOTAL_TREE', N'AVG_TREE', N'TOTAL_IO', N'AVG_IO') BEGIN 
		RAISERROR(N'Valid values for @order_by are: { TOTAL_LEAF | AVG_LEAF | TOTAL_TREE | AVG_TREE | TOTAL_IO | AVG_IO }.', 16, 1);
		RETURN -2;
	END;

	IF @granularity = N'SERVER' BEGIN 
		IF @databases IS NOT NULL BEGIN
			PRINT 'todo ... figure out how to filter here... ';
			-- guess that I need to get a #list of dbs by ID and names ... 
			-- then JOIN those vs the SELECT from sys.dm_db_index_operational_stats ...down below. 
		END;

		IF @tables IS NOT NULL BEGIN
			RAISERROR(N'@tables is not supported when @granularity is SERVER.', 16, 1);
			RETURN -4;
		END; 

		IF @indexes IS NOT NULL BEGIN
			RAISERROR(N'@indexes is not supported when @granularity is SERVER.', 16, 1);
			RETURN -5;
		END;
	  END;
	ELSE BEGIN 
		-- @databases MUST be 1x value ONLY AND must MATCH A db IN sys.databases.
		IF @databases IS NULL BEGIN 
			RAISERROR(N'@databases must be specified when @granularity is not SERVER.', 16, 1);
			RETURN -3;
		END;

		-- databases MUST be 1x only ... no wildcards/etc. 
		-- TODO: figure out how to confirm that there's only a single DB ... 
		--		could do split_string and check the count... might be the best option. 
		--		and make sure that there are no wildcards... 
		--     actually ... i think that if I were to hand this logic off to 'get tokenized dbs' ... it would return 1 or MORE dbs, right? 

		IF @tables IS NOT NULL BEGIN
			PRINT 'todo ... figure out how to filter here... ';
			-- guess that I need to get a #list of tables by ID and names ... 
			-- then JOIN those vs the SELECT from sys.dm_db_index_operational_stats ...down below. 
		END;

		IF @indexes IS NOT NULL BEGIN
			PRINT 'todo ... figure out how to filter here... ';
			-- guess that I need to get a #list of indexes by ID and names ... 
			-- then JOIN those vs the SELECT from sys.dm_db_index_operational_stats ...down below. 
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @sql nvarchar(max) = N'';

	IF @granularity = N'SERVER' BEGIN 

		CREATE TABLE #serverLatches (
			[database] sysname NULL,
			[tree_latch_count] bigint NULL,
			[tree_latch_ms] bigint NULL,
			[avg_tree_latch_ms] bigint NOT NULL,
			[leaf_latch_count] bigint NULL,
			[leaf_latch_ms] bigint NULL,
			[avg_leaf_latch_ms] bigint NOT NULL,
			[io_latch_count] bigint NULL,
			[io_latch_ms] bigint NULL,
			[avg_io_latch_ms] bigint NOT NULL
		);

		SET @sql = N'USE [{CURRENT_DB}];
WITH core AS ( 
	SELECT
		DB_NAME([database_id]) [database],
		SUM([tree_page_latch_wait_count]) [tree_latch_count],
		SUM([tree_page_latch_wait_in_ms]) [tree_latch_ms],
		SUM([page_latch_wait_count]) - SUM([tree_page_latch_wait_count]) [leaf_latch_count],
		SUM([page_latch_wait_in_ms]) - SUM([tree_page_latch_wait_in_ms]) [leaf_latch_ms],
		SUM([page_io_latch_wait_count]) [io_latch_count],
		SUM([page_io_latch_wait_in_ms]) [io_latch_ms]
	FROM
		[sys].dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL){WHERE}
	GROUP BY
		[database_id]
)

INSERT INTO #serverLatches ([database], [tree_latch_count], [tree_latch_ms], [avg_tree_latch_ms], [leaf_latch_count], [leaf_latch_ms], [avg_leaf_latch_ms], [io_latch_count], [io_latch_ms], [avg_io_latch_ms])
SELECT 
	ISNULL([c].[database], [empty].[database]) [database],
	ISNULL([c].[tree_latch_count], [empty].[tree_latch_count]) [tree_latch_count],
	ISNULL([c].[tree_latch_ms], [empty].[tree_latch_ms]) [tree_latch_ms],
	ISNULL([c].[tree_latch_count] / NULLIF([c].[tree_latch_ms], 0), 0) [avg_tree_latch_ms],
	ISNULL([c].[leaf_latch_count], [empty].[leaf_latch_count]) [leaf_latch_count],
	ISNULL([c].[leaf_latch_ms], [empty].[leaf_latch_ms]) [leaf_latch_ms],
	ISNULL([c].[leaf_latch_count] / NULLIF([c].[leaf_latch_ms], 0), 0) [avg_leaf_latch_ms],
	ISNULL([c].[io_latch_count], [empty].[io_latch_count]) [io_latch_count],
	ISNULL([c].[io_latch_ms], [empty].[io_latch_ms]) [io_latch_ms],
	ISNULL([c].[io_latch_count] / NULLIF([c].[io_latch_ms], 0), 0) [avg_io_latch_ms]
FROM 
	(SELECT DB_NAME() [database], 0 [tree_latch_count], 0 [tree_latch_ms], 0 [avg_tree_latch_ms], 0 [leaf_latch_count], 0 [leaf_latch_ms], 0 [avg_leaf_latch_ms], 0 [io_latch_count], 0 [io_latch_ms], 0 [avg_io_latch_ms]) [empty]
	LEFT OUTER JOIN [core] [c] ON [empty].[database] = [c].[database];';

		IF @exclude_system_objects = 1 BEGIN 
			SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N' WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9)+ N'OBJECTPROPERTY([object_id], ''IsUserTable'') = 1');
		END ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{WHERE}', N'');
		END;

		DECLARE @errors xml;
		DECLARE @errorContext nvarchar(MAX);

		SET @databases = ISNULL(@databases, N'{ALL}');	
		EXEC dbo.[execute_per_database]
			@Databases = @databases,
			@Statement = @sql,
			@Errors = @errors OUTPUT; 

		IF @errors IS NOT NULL BEGIN 
			SET @errorContext = N'Unexpected error while extracting latch details (per database): ';
			RETURN -20;
		END;

-- turn into dynamic SQL ... with ORDER BY via @sort_by. 
		SELECT
			[database],
			[tree_latch_count],
			[tree_latch_ms],
			[avg_tree_latch_ms],
			[leaf_latch_count],
			[leaf_latch_ms],
			[avg_leaf_latch_ms],
			[io_latch_count],
			[io_latch_ms],
			[avg_io_latch_ms]
		FROM
			[#serverLatches]
		ORDER BY
			[leaf_latch_ms] DESC,
			[io_latch_ms] DESC;

		RETURN 0; 
	END;


	IF @granularity = N'DATABASE' BEGIN 
		
		-- USE [{database}];
		WITH core AS ( 
			SELECT
				[object_id],
				SUM([tree_page_latch_wait_count]) [tree_latch_count],
				SUM([tree_page_latch_wait_in_ms]) [tree_latch_ms],
				SUM([page_latch_wait_count]) - SUM([tree_page_latch_wait_count]) [leaf_latch_count],
				SUM([page_latch_wait_in_ms]) - SUM([tree_page_latch_wait_in_ms]) [leaf_latch_ms],
				SUM([page_io_latch_wait_count]) [io_latch_count],
				SUM([page_io_latch_wait_in_ms]) [io_latch_ms]
			FROM
				[sys].dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL)
			GROUP BY
				[object_id]
		)

		SELECT 
			QUOTENAME(SCHEMA_NAME([o].[schema_id])) + N'.' + QUOTENAME([o].[name]) [table],
			[c].[tree_latch_count],
			[c].[tree_latch_ms],
			ISNULL([c].[tree_latch_count] / NULLIF([c].[tree_latch_ms], 0), 0) [avg_tree_latch_ms],
			[c].[leaf_latch_count],
			[c].[leaf_latch_ms],
			ISNULL([c].[leaf_latch_count] / NULLIF([c].[leaf_latch_ms], 0), 0) [avg_leaf_latch_ms],
			[c].[io_latch_count],
			[c].[io_latch_ms],
			ISNULL([c].[io_latch_count] / NULLIF([c].[io_latch_ms], 0), 0) [avg_io_latch_ms]
		FROM 
			[core] [c]
			INNER JOIN sys.objects [o] ON [c].[object_id] = [o].[object_id]
		ORDER BY 
			[avg_leaf_latch_ms] DESC;

		RETURN 0;
	END;

	IF @granularity = N'TABLE' BEGIN
		-- USE [{database}];
		WITH core AS ( 
			SELECT
				[object_id],
				[index_id],
				SUM([tree_page_latch_wait_count]) [tree_latch_count],
				SUM([tree_page_latch_wait_in_ms]) [tree_latch_ms],
				SUM([page_latch_wait_count]) - SUM([tree_page_latch_wait_count]) [leaf_latch_count],
				SUM([page_latch_wait_in_ms]) - SUM([tree_page_latch_wait_in_ms]) [leaf_latch_ms],
				SUM([page_io_latch_wait_count]) [io_latch_count],
				SUM([page_io_latch_wait_in_ms]) [io_latch_ms]
			FROM
				[sys].dm_db_index_operational_stats(DB_ID(), OBJECT_ID(N'backup_log'), NULL, NULL)
			GROUP BY
				[object_id], [index_id]
		)

		SELECT 
			QUOTENAME(SCHEMA_NAME([o].[schema_id])) + N'.' + QUOTENAME([o].[name]) [table],
			[c].[index_id],
			[i].[name] [index_name],
			[c].[tree_latch_count],
			[c].[tree_latch_ms],
			ISNULL([c].[tree_latch_count] / NULLIF([c].[tree_latch_ms], 0), 0) [avg_tree_latch_ms],
			[c].[leaf_latch_count],
			[c].[leaf_latch_ms],
			ISNULL([c].[leaf_latch_count] / NULLIF([c].[leaf_latch_ms], 0), 0) [avg_leaf_latch_ms],
			[c].[io_latch_count],
			[c].[io_latch_ms],
			ISNULL([c].[io_latch_count] / NULLIF([c].[io_latch_ms], 0), 0) [avg_io_latch_ms]
		FROM 
			[core] [c]
			INNER JOIN sys.objects [o] ON [c].[object_id] = [o].[object_id]
			INNER JOIN sys.indexes [i] ON [c].[object_id] = [i].[object_id] AND [c].[index_id] = [i].[index_id]
		ORDER BY 
			[avg_leaf_latch_ms] DESC;

		RETURN 0;
	END;