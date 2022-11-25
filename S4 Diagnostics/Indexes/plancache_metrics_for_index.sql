/*


	EXAMPLE: 
		
			EXEC [admindb].dbo.[plancache_metrics_for_index] 
				@TargetDatabase = N'Billing',   -- NOT required IF you're executing from within the DB that owns the IX in question...
				@TargetIndex = N'CLIX_Entries_ByServiceDate';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.plancache_metrics_for_index','P') IS NOT NULL
	DROP PROC dbo.[plancache_metrics_for_index];
GO

CREATE PROC dbo.[plancache_metrics_for_index]
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
			--STRING_AGG([node_id], N', ') WITHIN GROUP (ORDER BY [node_id]) [nodes]
			COUNT([node_id]) [node_count]
		FROM 
			nodes 
		GROUP BY 
			[plan_id]
	)

	SELECT 
		[m].[plan_id],
		FORMAT(CAST([m].[size_in_bytes] AS decimal(24,2)) / 1024.0, N'N0') [plan_size_kb],
		FORMAT([m].[usecounts], N'N0') [use_counts],
		[m].[cacheobjtype] [cacheobj_type],
		[m].[objtype] [obj_type],
		[n].[node_count],
		[m].[query_plan]
	FROM 
		[#metrics] m
		INNER JOIN node_aggs n ON [m].[plan_id] = [n].[plan_id] 
	ORDER BY 
		[m].[plan_id];

	RETURN 0 
GO