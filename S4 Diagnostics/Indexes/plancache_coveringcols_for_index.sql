/*
	EXAMPLE: 
		
			EXEC [admindb].dbo.[plancache_coveringcols_for_index]
				@TargetDatabase = N'Billing',  -- NOT required IF you're executing from within the DB that owns the IX in question... 
				@TargetIndex = N'CLIX_Entries_ByServiceDate';



	NOTE:
		[predicates] are a bit of a cheat. 
			I'm using the <Identifier /> wrapper/parent around <ColumnReference> entries in the 'predicates' sections. 
				where 'predicates' can be either (or AT LEAST?) 
					<Predicate>
					<SeekPredicates> 

			AND, yeah..the above isn't perfect. Actually, not really even close... 
				in fact... totally busted. 


				LOOKS like what I need to focus on is: 
					<SeekPredicate><SeekPredicateNew><SeekKeys><Prefix><RangeColumns> - for one...  whereas, in cases with combos like this ... the <Predicate> nodes are ... not what I'm shooting for. 
				








*/

USE [admindb];
GO

IF OBJECT_ID('dbo.plancache_coveringcols_for_index','P') IS NOT NULL
	DROP PROC dbo.[plancache_coveringcols_for_index];
GO

CREATE PROC dbo.[plancache_coveringcols_for_index]
	@TargetDatabase				sysname = NULL,
	@TargetIndex				sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SELECT @TargetIndex = REPLACE(REPLACE(@TargetIndex, N']', N''), N'[', N''); 

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;

		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. ', 16, 1);
			RETURN -5;
		END;
	END;

	DECLARE @ixId int; 
	DECLARE @sql nvarchar(MAX) = N'SELECT @ixID = [index_id] FROM [{0}].[sys].[indexes] WHERE [name] = @TargetIndex; ';
	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase); 

	EXEC sys.sp_executesql 
		@sql, 
		N'@TargetIndex sysname, @ixID int OUTPUT', 
		@TargetIndex = @TargetIndex, 
		@ixId = @ixId OUTPUT; 

	IF @ixId IS NULL BEGIN 
		RAISERROR('Invalid @TargetIndex specified - or @TargetIndex NOT found in CURRENT database. Either specify @TargetDatabase or EXECUTE this sproc from within database with @TargetIndex.', 16, 1);
		RETURN -10;
	END;
	
	SELECT @TargetIndex = QUOTENAME(@TargetIndex); 

	WITH XMLNAMESPACES (
		DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
	), 
	matches AS ( 
		SELECT 
			[cp].[usecounts],
			[cp].[size_in_bytes],
			[cp].[cacheobjtype],
			[cp].[objtype],
			[cp].[plan_handle],
			[cp].[parent_plan_handle],
			[qp].[dbid],
			[qp].[query_plan]
		FROM 
			sys.[dm_exec_cached_plans] cp 
			CROSS APPLY sys.[dm_exec_query_plan](cp.[plan_handle]) qp
		WHERE 
			[qp].[dbid] = DB_ID(@TargetDatabase)
			AND [qp].[query_plan].exist('//Object[@Index=sql:variable("@TargetIndex")]') = 1
	)

	SELECT
		ROW_NUMBER() OVER(ORDER BY plan_handle) [plan_id],
		[usecounts],
		[size_in_bytes],
		[cacheobjtype],
		[objtype],
		[query_plan] 
	INTO 
		#metrics
	FROM 
		[matches];	


	WITH XMLNAMESPACES (
		DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan'
	),
	nodes AS ( 
		SELECT 
			[plan_id],
			[operation].value(N'(@NodeId)[1]', N'int') [node_id],
			[operation].value(N'(@PhysicalOp)[1]', N'sysname') [op_type],
			[operation].query(N'.') [operation]
		FROM 
			[#metrics]
			CROSS APPLY [query_plan].nodes(N'.//RelOp') [nodes]([operation])
		WHERE 
			[operation].value(N'(./IndexScan/Object/@Index)[1]', N'sysname') = @TargetIndex
	), 
	node_aggs AS ( 
		SELECT 
			[plan_id], 
			STRING_AGG([node_id], N', ') WITHIN GROUP (ORDER BY [node_id]) [nodes]
		FROM 
			nodes 
		GROUP BY 
			[plan_id]
	),
	outputs AS ( 
		SELECT 
			[plan_id], 
			[node_id],
			[column].value(N'(@Column)[1]', N'sysname') [column]
		FROM  
			[nodes] 
			CROSS APPLY [operation].nodes(N'//OutputList/ColumnReference') [outputs]([column])
	), 
	output_aggs AS ( 
		SELECT 
			[plan_id], 
			[node_id], 
			STRING_AGG([column], N', ') [output_columns]
		FROM 
			[outputs] 
		GROUP BY 
			[plan_id], [node_id]
	), 
	ix_keys AS (
		SELECT 
			[plan_id], 
			[node_id],
			[column].value(N'(@Table)[1]', N'sysname') [table],
			[column].value(N'(@Column)[1]', N'sysname') [column]
		FROM 
			[nodes] 
			CROSS APPLY [operation].nodes(N'//Identifier/ColumnReference') [predicate]([column])
	),
	ix_aggs AS ( 
		SELECT DISTINCT -- bletch
			[plan_id], 
			[node_id],
			STRING_AGG([column], N', ') [predicates]
		FROM 
			[ix_keys] 
		WHERE 
			[table] IS NOT NULL 
		GROUP BY 
			[plan_id], [node_id]
	),
	coordinated AS ( 
		SELECT 
			[m].[plan_id],
			LAG([m].[plan_id], 1, 0) OVER (ORDER BY [m].[plan_id]) [prev],
			[m].[usecounts],
			[m].[size_in_bytes],
			[x].[node_id],
			[x].[output_columns],
			[m].[cacheobjtype],
			[m].[objtype],
			[m].[query_plan],
			[p].[predicates]
		FROM 
			[#metrics] m 
			INNER JOIN [output_aggs] x ON [m].[plan_id] = [x].[plan_id]
			INNER JOIN [ix_aggs] p ON [m].[plan_id] = [p].[plan_id] AND [x].[node_id] = [p].[node_id]
	)

	SELECT 
		CASE WHEN [c].[plan_id] = [c].[prev] THEN N'' ELSE CAST([c].[plan_id] AS sysname) END [plan_id],
		CASE WHEN [c].[plan_id] = [c].[prev] THEN N'' ELSE FORMAT((CAST(CAST([c].[size_in_bytes] AS decimal(24,2)) / 1024.0 AS int)), N'N0') END [plan_size_kb],
		CASE WHEN [c].[plan_id] = [c].[prev] THEN N'' ELSE FORMAT([c].[usecounts], N'N0') END [usecounts],
		CASE WHEN [c].[plan_id] = [c].[prev] THEN N'' ELSE [c].[cacheobjtype] END [cacheobject_type],
		CASE WHEN [c].[plan_id] = [c].[prev] THEN N'' ELSE [c].[objtype] END [obj_type],
		[c].[node_id],
		[c].[predicates],
		[c].[output_columns],
		[c].[query_plan]
	FROM 
		[coordinated] c
	ORDER BY 
		[c].[plan_id];

	RETURN 0 ;
GO