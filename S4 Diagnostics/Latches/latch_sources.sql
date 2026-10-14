/*


	.EXAMPLE Extracting Latch Details Per-Database
	This example pulls server-level latches - i.e., latches aggregated across each database: 

	```sql
	DECLARE @x xml;
	EXEC [latch_sources]
		@granularity = 'SERVER',
		@databases = N'{USER}, -admin%',
		@exclude_system_objects = 1, 
		@serialized_output = @x OUTPUT;

	SELECT @x;
	```

	.EXAMPLE Extracting Latch Details Per-Table
	This example extracts latch details for most tables within a SINGLE database. 
	Note that the `@tables` parameter is set to a value of `-numbers` to exclude any table with "numbers" in the name. 
	```sql

	DECLARE @x xml;
	EXEC [latch_sources]
		@granularity = 'DATABASE',
		@databases = N'admindb',
		@tables = N'-numbers',
		@exclude_system_objects = 1, 
		@serialized_output = @x OUTPUT;
	SELECT @x;

	```

	.EXAMPLE Projecting Per-Table (IX-Level) Latches
	Unlike the previous two examples, which extract latch info as xml, this invocation projects results instead.

	```sql
	EXEC [latch_sources]
		@granularity = 'TABLE',
		@databases = N'admindb',
		@tables = N'numbers',
		@exclude_system_objects = 1;
	```
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
	@databases						nvarchar(MAX)		= NULL, 
	@tables							nvarchar(MAX)		= NULL, 
	@serialized_output				xml					= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @databases = NULLIF(@databases, N'');
	SET @tables = NULLIF(@tables, N'');
	SET @exclude_system_objects = ISNULL(@exclude_system_objects, 1);
	SET @granularity = UPPER(ISNULL(NULLIF(@granularity, N''), N'SERVER'));
	SET @order_by = UPPER(ISNULL(NULLIF(@order_by, N''), N'AVG_LEAF'));
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @granularity NOT IN (N'SERVER', N'DATABASE', N'TABLE') BEGIN 
		RAISERROR(N'Valid values for @granularity are: { SERVER | DATABASE | TABLE }.', 16, 1);
		RETURN -1;
	END;

	IF @order_by NOT IN (N'TOTAL_LEAF', N'AVG_LEAF', N'TOTAL_TREE', N'AVG_TREE', N'TOTAL_IO', N'AVG_IO') BEGIN 
		RAISERROR(N'Valid values for @order_by are: { TOTAL_LEAF | AVG_LEAF | TOTAL_TREE | AVG_TREE | TOTAL_IO | AVG_IO }.', 16, 1);
		RETURN -2;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Dynamic Logic:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @filterPredicate nvarchar(MAX) = N'';
	DECLARE @filterJoin nvarchar(MAX) = N'';
	IF @granularity = N'SERVER' BEGIN 
		IF @tables IS NOT NULL BEGIN
			RAISERROR(N'A value for @tables is not permitted when @granularity is SERVER.', 16, 1);
			RETURN -4;
		END; 
	  END;
	ELSE BEGIN 
		IF @databases IS NULL BEGIN 
			RAISERROR(N'A value for @databases must be specified when @granularity is not SERVER.', 16, 1);
			RETURN -3;
		END;

		DECLARE @serializedOutput xml; 
		EXEC [admindb]..[targeted_databases]
			@Databases = @databases, 
			@SerializedOutput = @serializedOutput OUTPUT;

		DECLARE @count int;
		WITH shredded AS ( 
		SELECT 
			[data].[row].value('@id[1]', 'int') [row_id], 
			[data].[row].value('.[1]', 'sysname') [database_name]
		FROM 
			@serializedOutput.nodes('//database') [data]([row])
		)

		SELECT @count = COUNT(*) FROM shredded;

		IF @count <> 1 BEGIN 
			RAISERROR(N'The value for @databases must be the name of a SINGLE database when @granularity is not set to SERVER.', 16, 1);
			RETURN -6;
		END;

		IF @granularity = N'TABLE' BEGIN
			IF (SELECT COUNT(*) FROM dbo.split_string(@tables, N',', 1)) <> 1 BEGIN
				RAISERROR(N'The value for @tables must be the name of a SINGLE table when @granularity is set to TABLE.', 16, 1);
				RETURN -22;
			END;
		  END;
		ELSE BEGIN
			CREATE TABLE #ts_predicate_tables ([table] sysname NOT NULL, [exclude] bit NOT NULL);

			IF NULLIF(UPPER(@tables), N'{ALL}') IS NOT NULL BEGIN
				INSERT INTO #ts_predicate_tables ([table], [exclude])
				SELECT 
					CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [table], 
					CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
				FROM 
					dbo.[split_string](@tables, N',', 1);

				IF EXISTS (SELECT NULL FROM #ts_predicate_tables WHERE [exclude] = 0) BEGIN 
					SET @filterJoin = N'INNER JOIN #ts_predicate_tables [t] ON [t].[table] LIKE [x].[table]';
				END;

				IF EXISTS (SELECT NULL FROM #ts_predicate_tables WHERE [exclude] = 1) BEGIN 
					/* NOTE: because table(name) is wrapped in quoted_idents (for both schema and table) ... need to handle the LIKE a bit differently (than normal):  */
					SET @filterJoin = N'LEFT OUTER JOIN [#ts_predicate_tables] [t] ON [t].[exclude] = 1 AND [x].[table] LIKE N''%'' + REPLACE([t].[table], N''%'', N'''') + N''%''';
					SET @filterPredicate = N'[t].[table] IS NULL';					
				END;
			END;
		END;
	END;

	DECLARE @orderBy nvarchar(MAX) = N'';
	SELECT @orderBy = CASE @order_by 
		WHEN N'TOTAL_LEAF' THEN N'[leaf_latch_ms] DESC, [io_latch_count] DESC'
		WHEN N'AVG_LEAF' THEN N'[avg_leaf_latch_ms] DESC, [io_latch_count] DESC'
		WHEN N'TOTAL_TREE' THEN N'[tree_latch_ms] DESC, [io_latch_count] DESC'
		WHEN N'AVG_TREE' THEN N'[avg_tree_latch_ms] DESC, [io_latch_count] DESC'
		WHEN N'TOTAL_IO' THEN N'[io_latch_ms] DESC, [leaf_latch_count] DESC'
		WHEN N'AVG_IO' THEN N'[avg_io_latch_ms] DESC, [leaft_latch_count] DESC'
		ELSE N''
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @sql nvarchar(max) = N'';

	IF @granularity = N'SERVER' BEGIN 

		/* NOTE: the ONLY reason for extracting latches database-by-database is to provide an OPTION for excluding SYSTEM-OBJECTS|tables|IXes. */
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

		IF @exclude_system_objects = 1 
			SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N' WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9)+ N'OBJECTPROPERTY([object_id], ''IsUserTable'') = 1');
		ELSE 
			SET @sql = REPLACE(@sql, N'{WHERE}', N'');

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

		CREATE TABLE [#finalLatches] (
			[row_id] int IDENTITY(1,1) NOT NULL,
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

		SET @sql = N'SELECT
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
	' + @orderBy + N'; ';

		INSERT INTO #finalLatches ([database], [tree_latch_count], [tree_latch_ms], [avg_tree_latch_ms], [leaf_latch_count], [leaf_latch_ms], [avg_leaf_latch_ms], [io_latch_count], [io_latch_ms], [avg_io_latch_ms])
		EXEC sys.sp_executesql @sql;

		IF dbo.is_xml_empty(@serialized_output) = 1 BEGIN		
			SELECT @serialized_output = (
				SELECT 
					[tree_latch_count] [@tree_latch_count],
					[tree_latch_ms] [@tree_latch_ms],
					[avg_tree_latch_ms] [@avg_tree_latch_ms],
					[leaf_latch_count] [@leaf_latch_count],
					[leaf_latch_ms] [@leaf_latch_ms],
					[avg_leaf_latch_ms] [@avg_leaf_latch_ms],
					[io_latch_count] [@io_latch_count],
					[io_latch_ms] [@io_latch_ms],
					[avg_io_latch_ms] [@avg_io_latch_ms],
					[database] [*]
				FROM 
					[#finalLatches]
				ORDER BY 
					[row_id]
				FOR XML PATH(N'latch'), ROOT(N'latches'), TYPE
			);

			RETURN 0;
		END;

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
			[#finalLatches]
		ORDER BY 
			[row_id];

		RETURN 0; 
	END;
		
	CREATE TABLE #finalDbLatches (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[table] nvarchar(260) NULL,
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

	IF @granularity = N'TABLE' BEGIN
		ALTER TABLE #finalDbLatches ADD	[index_id] int NOT NULL;
		ALTER TABLE #finalDbLatches ADD	[index_name] sysname NULL;
	END;

	SET @sql = N'USE [{CURRENT_DB}];
WITH core AS ( 
	SELECT
		[object_id],{index_id}
		SUM([tree_page_latch_wait_count]) [tree_latch_count],
		SUM([tree_page_latch_wait_in_ms]) [tree_latch_ms],
		SUM([page_latch_wait_count]) - SUM([tree_page_latch_wait_count]) [leaf_latch_count],
		SUM([page_latch_wait_in_ms]) - SUM([tree_page_latch_wait_in_ms]) [leaf_latch_ms],
		SUM([page_io_latch_wait_count]) [io_latch_count],
		SUM([page_io_latch_wait_in_ms]) [io_latch_ms]
	FROM
		[sys].dm_db_index_operational_stats(DB_ID(), {tableName}, NULL, NULL){WHERE}
	GROUP BY
		[object_id]{ix_group}
), 
[names] AS ( 
	SELECT DISTINCT /* YES. This is Evil(TM). But ... I''m a trained professional - and in this case, DISTINCT is just, cough, easier. */
		[x].[object_id],
		QUOTENAME(SCHEMA_NAME([o].[schema_id])) + N''.'' + QUOTENAME([o].[name]) [table]
	FROM 
		[core] [x]
		INNER JOIN sys.objects [o] ON [x].[object_id] = [o].[object_id]
) 

SELECT 
	[x].[table],
	[c].[tree_latch_count],
	[c].[tree_latch_ms],
	ISNULL([c].[tree_latch_count] / NULLIF([c].[tree_latch_ms], 0), 0) [avg_tree_latch_ms],
	[c].[leaf_latch_count],
	[c].[leaf_latch_ms],
	ISNULL([c].[leaf_latch_count] / NULLIF([c].[leaf_latch_ms], 0), 0) [avg_leaf_latch_ms],
	[c].[io_latch_count],
	[c].[io_latch_ms],
	ISNULL([c].[io_latch_count] / NULLIF([c].[io_latch_ms], 0), 0) [avg_io_latch_ms]{ix_Cols}
FROM 
	[core] [c]{ix_JOIN}
	INNER JOIN [names] [x] ON [c].[object_id] = [x].[object_id]{exclusionJoin}
ORDER BY 
	{orderBy}; ';

	SET @sql = REPLACE(@sql, N'{CURRENT_DB}', DB_NAME());
	SET @sql = REPLACE(@sql, N'{orderBy}', @orderBy);

	IF @granularity = N'TABLE' BEGIN
		SET @sql = REPLACE(@sql, N'{index_id}', NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N'[index_id],');
		SET @sql = REPLACE(@sql, N'{tableName}', N'OBJECT_ID(N''' + @tables + N''')');
		SET @sql = REPLACE(@sql, N'{ix_group}', N', [index_id]');
		SET @sql = REPLACE(@sql, N'{ix_JOIN}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N'INNER JOIN sys.indexes [i] ON [c].[object_id] = [i].[object_id] AND [c].[index_id] = [i].[index_id]');
		SET @sql = REPLACE(@sql, N'{ix_Cols}', N',' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'[c].[index_id],' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'[i].[name] [index_name]');
	  END;
	ELSE BEGIN
		SET @sql = REPLACE(@sql, N'{index_id}', N'');
		SET @sql = REPLACE(@sql, N'{tableName}', N'NULL');
		SET @sql = REPLACE(@sql, N'{ix_group}', N'');
		SET @sql = REPLACE(@sql, N'{ix_JOIN}', N'');
		SET @sql = REPLACE(@sql, N'{ix_Cols}', N'');
	END;
		
	IF @exclude_system_objects = 1 
		SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N'WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9)+ N'OBJECTPROPERTY([object_id], ''IsUserTable'') = 1');
	ELSE
		SET @sql = REPLACE(@sql, N'{WHERE}', N'');
		
	IF @tables IS NULL 
		SET @sql = REPLACE(@sql, N'{exclusionJoin}', N'');
	ELSE BEGIN 
		DECLARE @exclusionDetails nvarchar(MAX) = NCHAR(13) + NCHAR(10) + NCHAR(9) + @filterJoin;
			
		IF @filterPredicate <> N'' 
			SET @exclusionDetails = @exclusionDetails + NCHAR(13) + NCHAR(10) + N'WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + @filterPredicate;

		SET @sql = REPLACE(@sql, N'{exclusionJoin}', @exclusionDetails);
	END;

	INSERT INTO #finalDbLatches
	EXEC sys.sp_executesql 
		@sql;

	DECLARE @columns table ( 
		[row_id] int IDENTITY(1,1) NOT NULL,
		[column] sysname NOT NULL, 
		[xml_alias] sysname NOT NULL, 
		[is_ix_detail] bit NOT NULL, 
		[sort] int NOT NULL
	);

	INSERT INTO @columns ([column], [xml_alias], [is_ix_detail], [sort])
	VALUES 
		(N'[table]', N'[*]', 0, 1000),
		(N'[index_id]', N'[@index_id]', 1, 0),
		(N'[index_name]', N'[@index_name]', 1, 0),
		(N'[tree_latch_count]', N'[@tree_latch_count]', 0, 0),
		(N'[tree_latch_ms]', N'[@tree_latch_ms]', 0, 0),
		(N'[avg_tree_latch_ms]', N'[@avg_tree_latch_ms]', 0, 0),
		(N'[leaf_latch_count]', N'[@leaf_latch_count]', 0, 0),
		(N'[leaf_latch_ms]', N'[@leaf_latch_ms]', 0, 0),
		(N'[avg_leaf_latch_ms]', N'[@avg_leaf_latch_ms]', 0, 0),
		(N'[io_latch_count]', N'[@io_latch_count]', 0, 0),
		(N'[io_latch_ms]', N'[@io_latch_ms]', 0, 0),
		(N'[avg_io_latch_ms]', N'[@avg_io_latch_ms]', 0, 0);

	SET @sql = N'SELECT' + NCHAR(13) + NCHAR(10) + NCHAR(9);

	DECLARE @forXML bit = dbo.is_xml_empty(@serialized_output);

	DECLARE @columnData nvarchar(MAX) = N'';
	WITH [core] AS (
		SELECT 
			CASE WHEN @forXML = 1 THEN [column] + N' ' + [xml_alias] ELSE [column] END [definition],
			CASE WHEN @forXML = 1 THEN [sort] + [row_id] ELSE [row_id] END [sort]
		FROM 
			@columns
		WHERE 
			[is_ix_detail] = CASE WHEN @granularity = N'DATABASE' THEN 0 ELSE [is_ix_detail] END 
	) 

	SELECT 
		@columnData = STRING_AGG([definition], N',' + NCHAR(13) + NCHAR(10) + NCHAR(9)) WITHIN GROUP (ORDER BY [sort])
	FROM 
		[core];
		
	DECLARE @xmlPathOption nvarchar(MAX) = N';';   -- default to non-XML output
	IF @forXML = 1 
		SET @xmlPathOption = NCHAR(13) + NCHAR(10) + N'FOR XML PATH(N''latch''), ROOT(N''latches''), TYPE';

	SET @sql = @sql + @columnData + NCHAR(13) + NCHAR(10) + 
		N'FROM' + NCHAR(13) + NCHAR(10) + NCHAR(9) + 
		N'[#finalDbLatches]' + NCHAR(13) + NCHAR(10) + 
		N'ORDER BY' + NCHAR(13) + NCHAR(10) + NCHAR(9) + @orderBy + 
		@xmlPathOption;

	IF dbo.is_xml_empty(@serialized_output) = 1 BEGIN
		
		SET @sql = N'SELECT @serialized_output = (' + @sql + N');';

		EXEC sys.sp_executesql
			@sql,
			N'@serialized_output xml OUTPUT',
			@serialized_output = @serialized_output OUTPUT;

		RETURN 0;
	END;

	EXEC sys.sp_executesql
		@sql;

	RETURN 0;
GO