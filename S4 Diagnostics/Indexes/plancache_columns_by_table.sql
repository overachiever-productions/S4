/*
	EXAMPLE: 

			EXEC [admindb].dbo.[plancache_columns_by_table] 
				@TargetDatabase = N'Billing', 
				@TargetTable = N'Entries';

	vNEXT:
		this accidentally gets tables with different schemas 'right' 
			as in ... if there's a table of txnproc.batch_status vs dbo.batch_status
				it'll accidentally get that right. 
			however, if there were dbo.batch_status and myschema.batch_status, it'd NEVER 
				be able to differentiate and ... probably crash/burn. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.plancache_columns_by_table','P') IS NOT NULL
	DROP PROC dbo.[plancache_columns_by_table];
GO

CREATE PROC dbo.[plancache_columns_by_table]
	@TargetDatabase				sysname = NULL,
	@TargetTable				sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDatabase = REPLACE(REPLACE(@TargetDatabase, N'[', N''), N']', N']');
	SET @TargetTable = REPLACE(REPLACE(@TargetTable, N'[', N''), N']', N']');

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;

		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. ', 16, 1);
			RETURN -5;
		END;
	END;

	CREATE TABLE #columnNames (
		[column_id] int NOT NULL, 
		[name] sysname NOT NULL 
	);
	
	DECLARE @sql nvarchar(MAX) = N'SELECT 
		[c].[column_id],
		[c].[name]
	FROM 
		[{targetDb}].sys.[all_columns] c
		INNER JOIN [{targetDb}].sys.objects [o] ON [c].[object_id] = [o].[object_id]
	WHERE 
		[o].[name] = @TargetTable; ';

	SET @sql = REPLACE(@sql, N'{targetDb}', @TargetDatabase);

	INSERT INTO [#columnNames] ([column_id],[name])
	EXEC sys.sp_executesql 
		@sql, 
		N'@TargetTable sysname', 
		@TargetTable = @TargetTable;

	IF NOT EXISTS (SELECT NULL FROM [#columnNames]) BEGIN 
		RAISERROR('Invalid @TargetTable specified - or @TargetTable NOT found in CURRENT database. Either specify @TargetDatabase or EXECUTE this sproc from within database with @TargetTable.', 16, 1);
		RETURN -10;	
	END;

	SET @TargetTable = QUOTENAME(@TargetTable);

	/* 
		DRY VIOLATION: The code below is 98% duplicated between plancache_columns_by_index and plancache_columns_by_table. 
				The ONLY differences are the WHERE clauses (2x in the core CTE + projection) for .exist()... 
			TODO: https://overachieverllc.atlassian.net/browse/S4-516
	*/

	/* Find all plans with REFERENCES to the table in question: */
	WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
	core AS (
		SELECT 
			ROW_NUMBER() OVER(ORDER BY [cp].[plan_handle]) [plan_number],
			[cp].[usecounts],
			[cp].[cacheobjtype],
			[qp].[query_plan]
		FROM 
			sys.[dm_exec_cached_plans] cp 
			CROSS APPLY sys.[dm_exec_query_plan](cp.[plan_handle]) qp
		WHERE 
			[qp].[dbid] = DB_ID(@TargetDatabase)
			AND [qp].[query_plan].exist('//Object[@Table=sql:variable("@TargetTable")]') = 1
	)

	SELECT 
		[c].[plan_number],
		[c].[usecounts],
		[c].[cacheobjtype],
		[c].[query_plan], 
		[n].[node].value(N'(@NodeId)[1]', N'int') [node_id], 
		[n].[node].value(N'(@PhysicalOp)[1]', N'sysname') [physical_op],
		STUFF((
			SELECT DISTINCT 
				', ' + [r].[ref].value(N'(@Column)[1]', N'sysname')
			FROM 
				[n].[node].nodes(N'OutputList') [o]([outputs])
				CROSS APPLY [o].[outputs].nodes(N'ColumnReference') [r]([ref])
			WHERE 
				[r].[ref].value(N'(@Column)[1]', N'sysname') IN (SELECT [name] FROM [#columnNames])
			FOR XML PATH('')
		), 1, 2, '') [output_cols]
		
		,[n].[node].query(N'.') [rel_op]
	INTO 
		#planRelOps
	FROM 
		core [c]
		CROSS APPLY [c].[query_plan].nodes(N'//RelOp') [n]([node]) 
	WHERE 
		[n].[node].exist(N'IndexScan/Object[@Table=sql:variable("@TargetTable")]') = 1;

	/* Extract ColumnReference details */
	WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
	SELECT 
		[p].[plan_number],
		[p].[node_id],
		[n].[node].value(N'local-name(./..)', N'sysname') [great_grandparent_name],
		[n].[node].query(N'./..') [great_grandparent_node],
		[n].[node].value(N'local-name(.)', N'sysname') [grandparent_name],
		[n].[node].query(N'.') [grandparent_node], 
		[n].[node].value(N'local-name(*[1])', N'sysname') [parent_name],
		[n].[node].query(N'./*[1]') [parent_node],
		[n].[node].query(N'./*[1]/*[1]') [node]				-- child/child of [node]
	INTO 
		#explodedColRefs
	FROM 
		[#planRelOps] [p] 
		CROSS APPLY [p].rel_op.nodes(N'//*[ColumnReference]/..') [n]([node]) -- MKC: //*[ColumnReference] grabs ALL elements with name of 'ColumnReference]. And /.. then grabs the PARENT of said node. 
	WHERE 
		[n].[node].value(N'local-name(*[1])', N'sysname') NOT IN (N'OutputList', N'DefinedValue') --, N'Identifier')
	ORDER BY 
		[p].[plan_number], [p].[node_id], [parent_name];

	WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
	SELECT 
		[r].[plan_number],
		[r].[node_id],
		[r].[grandparent_name],
		CASE
			WHEN [r].[great_grandparent_name] = N'Intrinsic' THEN [r].[great_grandparent_node].value(N'(/Intrinsic/@FunctionName)[1]', N'sysname')
			WHEN [r].[great_grandparent_name] = N'Compare' THEN [r].[great_grandparent_node].value(N'(/Compare/@CompareOp)[1]', N'sysname')
			WHEN [r].[grandparent_name] = N'Prefix' THEN [r].[grandparent_node].value(N'(/Prefix/@ScanType)[1]', N'sysname') 
			WHEN [r].[grandparent_name] = N'EndRange' THEN [r].[grandparent_node].value(N'(/EndRange/@ScanType)[1]', N'sysname') 
			WHEN [r].[grandparent_name] = N'StartRange' THEN [r].[grandparent_node].value(N'(/StartRange/@ScanType)[1]', N'sysname')
			ELSE N'' 
		END [scan_type],
		[r].[grandparent_node],
		[r].[parent_name],
		[r].[parent_node],
		[r].[node],
		[r].[node].value(N'(ColumnReference/@Column)[1]', N'sysname') [column_name]
	INTO 
		#expandedColumns
	FROM 
		#explodedColRefs [r]
	WHERE 
		[r].[node].value(N'(ColumnReference/@Column)[1]', N'sysname') IN (SELECT [name] FROM [#columnNames])
	ORDER BY 
		[r].[plan_number], [r].[node_id];

	WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
	SELECT 
		[p].[plan_number],
		[p].[node_id] [operation_id],
		[p].[cacheobjtype],
		[p].[usecounts],
		[p].[physical_op] [operation],
		N' ' [ ], 
		[p].[rel_op].value(N'(//Object/@Index)[1]', N'sysname') [index],
		STUFF((
			SELECT DISTINCT
				N', ' + [e].[column_name]
			FROM 
				[#expandedColumns] [e]
			WHERE 
				[e].[scan_type] = N'EQ' 
				AND [e].[plan_number] = [p].[plan_number] AND [e].[node_id] = [p].[node_id]
			FOR XML PATH('')
			), 1, 2, N'') [equality_columns],
		STUFF((
			SELECT DISTINCT
				N', ' + [e].[column_name] + N' (' + UPPER([e].[scan_type]) + N')'
			FROM 
				[#expandedColumns] [e]
			WHERE 
				NULLIF([e].[scan_type], N'') IS NOT NULL AND [e].[scan_type] <> N'EQ' 
				AND [e].[plan_number] = [p].[plan_number] AND [e].[node_id] = [p].[node_id]
			FOR XML PATH('')
			), 1, 2, N'') [inequality_columns],		

		[p].[output_cols] [output_columns],
		N' ' [_], 
		[p].[query_plan]
		--[p].[rel_op] [operation_xml]
	FROM 
		[#planRelOps] [p]
	ORDER BY 
		[p].[plan_number], [p].[node_id];

	RETURN 0;
GO