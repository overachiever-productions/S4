/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[block_sources]', N'P') IS NOT NULL
	DROP PROC dbo.[block_sources];
GO

CREATE PROC dbo.[block_sources]
	@granularity					sysname = N'SERVER',		-- { SERVER | DATABASE | TABLE }
	@order_by						sysname = N'TOTAL_ROW',		-- { TOTAL_ROW | AVG_ROW | TOTAL_PAGE | AVG_PAGE | PROMOTE_ATTEMPT | PROMOTE_SUCCESS }
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
	SET @order_by = UPPER(ISNULL(NULLIF(@order_by, N''), N'TOTAL_ROW'));
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @granularity NOT IN (N'SERVER', N'DATABASE', N'TABLE') BEGIN 
		RAISERROR(N'Valid values for @granularity are: { SERVER | DATABASE | TABLE }.', 16, 1);
		RETURN -1;
	END;

	IF @order_by NOT IN (N'TOTAL_ROW', N'AVG_ROW', N'TOTAL_PAGE', N'AVG_PAGE', N'PROMOTE_ATTEMPTS', N'PROMOTE_SUCCESS') BEGIN 
		RAISERROR(N'Valid values for @order_by are: { TOTAL_ROW | AVG_ROW | TOTAL_PAGE | AVG_PAGE | PROMOTE_ATTEMPTS | PROMOTE_SUCCESS }.', 16, 1);
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
		WHEN N'TOTAL_ROW' THEN N'[row_lock_ms] DESC, [page_lock_waits] + [ix_promote_attempts] DESC'
		WHEN N'AVG_ROW' THEN N'[avg_row_lock_ms] DESC, [page_lock_waits] + [ix_promote_attempts] DESC'
		WHEN N'TOTAL_PAGE' THEN N'[page_lock_ms] DESC, [row_lock_waits] + [ix_promote_attempts] DESC'
		WHEN N'AVG_PAGE' THEN N'[avg_page_lock_ms] DESC, [row_lock_waits] + [ix_promote_attempts] DESC'
		WHEN N'PROMOTE_ATTEMPTS' THEN N'[ix_promote_attempts] DESC, [row_lock_ms] + [page_lock_ms] DESC'
		WHEN N'PROMOTE_SUCCESS' THEN N'[ix_promote_success] DESC, [row_lock_ms] + [page_lock_ms] DESC'
		ELSE N''
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @sql nvarchar(max) = N'';

	IF @granularity = N'SERVER' BEGIN 

		/* NOTE: the ONLY reason for extracting locks database-by-database is to provide an OPTION for excluding SYSTEM-OBJECTS|tables|IXes. */
		CREATE TABLE #serverLocks (
			[database] sysname NOT NULL,
			[row_lock_waits] bigint NOT NULL,
			[row_lock_ms] bigint NOT NULL,
			[avg_row_lock_wait] bigint NOT NULL,
			[page_lock_waits] bigint NOT NULL,
			[page_lock_ms] bigint NOT NULL,
			[avg_page_lock_wait] bigint NOT NULL,
			[ix_promote_attempts] bigint NOT NULL,
			[ix_promote_success] bigint NOT NULL
		);

		SET @sql = N'USE [{CURRENT_DB}];
WITH core AS ( 
	SELECT
		DB_NAME([database_id]) [database],
		SUM([row_lock_wait_count]) [row_lock_waits],
		SUM([row_lock_wait_in_ms]) [row_lock_ms],
		SUM([page_lock_wait_count]) [page_lock_waits],
		SUM([page_lock_wait_in_ms]) [page_lock_ms],
		SUM([index_lock_promotion_attempt_count]) [ix_promote_attempts],
		SUM([index_lock_promotion_count]) [ix_promote_success]
	FROM
		[sys].dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL){WHERE}
	GROUP BY
		[database_id]
)

INSERT INTO #serverLocks ([database], [row_lock_waits], [row_lock_ms], [avg_row_lock_wait], [page_lock_waits], [page_lock_ms], [avg_page_lock_wait], [ix_promote_attempts], [ix_promote_success])
SELECT 
	ISNULL([c].[database], [empty].[database]) [database],
	ISNULL([c].[row_lock_waits], [empty].[row_lock_waits]) [row_lock_waits],
	ISNULL([c].[row_lock_ms], [empty].[row_lock_ms]) [row_lock_ms],
	ISNULL([c].[row_lock_waits] / NULLIF([c].[row_lock_ms], 0), 0) [avg_row_lock_wait],
	ISNULL([c].[page_lock_waits], [empty].[page_lock_waits]) [page_lock_waits],
	ISNULL([c].[page_lock_ms], [empty].[page_lock_ms]) [page_lock_ms],
	ISNULL([c].[page_lock_waits] / NULLIF([c].[page_lock_ms], 0), 0) [avg_page_lock_wait],
	ISNULL([c].[ix_promote_attempts], [empty].[ix_promote_attempts]) [ix_promote_attempts],
	ISNULL([c].[ix_promote_success], [empty].[ix_promote_success]) [ix_promote_success]
FROM 
	(SELECT DB_NAME() [database], 0 [row_lock_waits], 0 [row_lock_ms], 0 [avg_row_lock_wait], 0 [page_lock_waits], 0 [page_lock_ms], 0 [avg_page_lock_wait], 0 [ix_promote_attempts], 0 [ix_promote_success]) [empty]
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
			RAISERROR(N'Unexpected error while extracting lock details (per database): ', 16, 1);
			RETURN -20;
		END;

		CREATE TABLE [#finalLocks] (
			[row_id] int IDENTITY(1,1) NOT NULL,
			[database] sysname NOT NULL,
			[row_lock_waits] bigint NOT NULL,
			[row_lock_ms] bigint NOT NULL,
			[avg_row_lock_wait] bigint NOT NULL,
			[page_lock_waits] bigint NOT NULL,
			[page_lock_ms] bigint NOT NULL,
			[avg_page_lock_wait] bigint NOT NULL,
			[ix_promote_attempts] bigint NOT NULL,
			[ix_promote_success] bigint NOT NULL
		);

		SET @sql = N'SELECT
	[database],
	[row_lock_waits],
	[row_lock_ms],
	[avg_row_lock_wait],
	[page_lock_waits],
	[page_lock_ms],
	[avg_page_lock_wait],
	[ix_promote_attempts],
	[ix_promote_success]
FROM
	[#serverLocks]
ORDER BY
	' + @orderBy + N'; ';

		INSERT INTO #finalLocks ([database], [row_lock_waits], [row_lock_ms], [avg_row_lock_wait], [page_lock_waits], [page_lock_ms], [avg_page_lock_wait], [ix_promote_attempts], [ix_promote_success])
		EXEC sys.sp_executesql @sql;

		IF dbo.is_xml_empty(@serialized_output) = 1 BEGIN		
			SELECT @serialized_output = (
				SELECT 
					[row_lock_waits] [@row_lock_waits],
					[row_lock_ms] [@row_lock_ms],
					[avg_row_lock_wait] [@avg_row_lock_wait],
					[page_lock_waits] [@page_lock_waits],
					[page_lock_ms] [@page_lock_ms],
					[avg_page_lock_wait] [@avg_page_lock_wait],
					[ix_promote_attempts] [@ix_promote_attempts],
					[ix_promote_success] [@ix_promote_success],
					[database] [*]
				FROM 
					[#finalLocks]
				ORDER BY 
					[row_id]
				FOR XML PATH(N'lock'), ROOT(N'locks'), TYPE
			);

			RETURN 0;
		END;

		SELECT 
			[database],
			[row_lock_waits],
			[row_lock_ms],
			[avg_row_lock_wait],
			[page_lock_waits],
			[page_lock_ms],
			[avg_page_lock_wait],
			[ix_promote_attempts],
			[ix_promote_success]
		FROM 
			#finalLocks
		ORDER BY 
			[row_id];

		RETURN 0; 
	END;
		
	CREATE TABLE #finalDbLocks (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[table] nvarchar(260) NULL,
		[row_lock_waits] bigint NULL,
		[row_lock_ms] bigint NULL,
		[avg_row_lock_wait] bigint NOT NULL,
		[page_lock_waits] bigint NOT NULL,
		[page_lock_ms] bigint NULL,
		[avg_page_lock_wait] bigint NOT NULL,
		[ix_promote_attempts] bigint NULL,
		[ix_promote_success] bigint NOT NULL
	);

	IF @granularity = N'TABLE' BEGIN
		ALTER TABLE #finalDbLocks ADD [index_id] int NOT NULL;
		ALTER TABLE #finalDbLocks ADD [index_name] sysname NULL;
	END;

	SET @sql = N'USE [{CURRENT_DB}];
WITH core AS ( 
	SELECT
		[object_id],{index_id}
		SUM([row_lock_wait_count]) [row_lock_waits],
		SUM([row_lock_wait_in_ms]) [row_lock_ms],
		SUM([page_lock_wait_count]) [page_lock_waits],
		SUM([page_lock_wait_in_ms]) [page_lock_ms],
		SUM([index_lock_promotion_attempt_count]) [ix_promote_attempts],
		SUM([index_lock_promotion_count]) [ix_promote_success]
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
	[c].[row_lock_waits],
	[c].[row_lock_ms],
	ISNULL([c].[row_lock_waits] / NULLIF([c].[row_lock_ms], 0), 0) [avg_row_lock_wait],
	[c].[page_lock_waits],
	[c].[page_lock_ms],
	ISNULL([c].[page_lock_waits] / NULLIF([c].[page_lock_ms], 0), 0) [avg_page_lock_wait],
	[c].[ix_promote_attempts],
	[c].[ix_promote_success]{ix_Cols}
FROM 
	[core] [c]{ix_JOIN}
	INNER JOIN [names] [x] ON [c].[object_id] = [x].[object_id]{exclusionJoin}
ORDER BY 
	{orderBy}; ';

	SET @sql = REPLACE(@sql, N'{CURRENT_DB}', @databases);
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

	INSERT INTO #finalDbLocks
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
		(N'[row_lock_waits]', N'[@row_lock_waits]', 0, 0),
		(N'[row_lock_ms]', N'[@row_lock_ms]', 0, 0),
		(N'[avg_row_lock_wait]', N'[@avg_row_lock_wait]', 0, 0),
		(N'[page_lock_waits]', N'[@page_lock_waits]', 0, 0),
		(N'[page_lock_ms]', N'[@page_lock_ms]', 0, 0),
		(N'[avg_page_lock_wait]', N'[@avg_page_lock_wait]', 0, 0),
		(N'[ix_promote_attempts]', N'[@ix_promote_attempts]', 0, 0),
		(N'[ix_promote_success]', N'[@ix_promote_success]', 0, 0);

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
		SET @xmlPathOption = NCHAR(13) + NCHAR(10) + N'FOR XML PATH(N''lock''), ROOT(N''locks''), TYPE';

	SET @sql = @sql + @columnData + NCHAR(13) + NCHAR(10) + 
		N'FROM' + NCHAR(13) + NCHAR(10) + NCHAR(9) + 
		N'[#finalDbLocks]' + NCHAR(13) + NCHAR(10) + 
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