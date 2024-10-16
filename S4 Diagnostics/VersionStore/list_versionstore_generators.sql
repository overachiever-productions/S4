/*


	REFACTOR ... maybe call this something along the lines of versionstore tables/names ... or versionstore_sources... 

		Or just dbo.versionstore_consumers



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_versionstore_generators','P') IS NOT NULL
	DROP PROC dbo.[list_versionstore_generators];
GO

CREATE PROC dbo.[list_versionstore_generators]
	@ExcludeMsdb			bit				= 1,	
	@TargetDatabase			sysname			= NULL,				-- when specified, only pulls data (all tables/usages) for a SINGLE, given, database... 
	@DatabasesOnly			bit				= 0					-- vs tables - by/from - each database ... (DEFAULT). 
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @ExcludeMsdb = ISNULL(@ExcludeMsdb, 1);
	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SET @DatabasesOnly = ISNULL(@DatabasesOnly, 0);

	IF @TargetDatabase IS NOT NULL BEGIN
		IF DB_ID(@TargetDatabase) IS NULL BEGIN 
			RAISERROR(N'Specified @TargetDatabase: [%s] does NOT exist.', 16, 1, @TargetDatabase);
			RETURN -3;
		END;
	END;
	
	CREATE TABLE #generators (
		row_id int IDENTITY(1,1) NOT NULL, 
		database_id int NOT NULL, 
		rowset_id bigint NOT NULL, 
		[length] bigint NOT NULL, 
		[schema] sysname NULL, 
		[name] sysname NULL, 
		[partition_number] int NULL
	); 
	
	INSERT INTO [#generators] ([database_id], [rowset_id], [length])
	SELECT 
		[database_id],
		[rowset_id],
		[aggregated_record_length_in_bytes] [length]
	FROM 
		sys.[dm_tran_top_version_generators]; 

	IF @ExcludeMsdb = 1 BEGIN 
		DELETE FROM [#generators] WHERE [database_id] = 4;
	END;

	DECLARE @databaseID int; 
	DECLARE @sql nvarchar(MAX);
	
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_id]
	FROM 
		[#generators]
	GROUP BY 
		[database_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @databaseID;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @sql = N'USE [{database}];

WITH core AS (
	SELECT 
		@databaseID [database_id], 
		[g].rowset_id,
		OBJECT_SCHEMA_NAME([p].[object_id]) [schema],
		OBJECT_NAME([p].[object_id]) [name], 
		[p].partition_number [partition_number]	
	FROM 
		#generators [g]
		INNER JOIN sys.partitions [p] ON [g].[rowset_id] = [p].[hobt_id]
) 

UPDATE x 
SET 
	[x].[schema] = [c].[schema],
	[x].[name] = [c].[name], 
	[x].partition_number = [c].partition_number
FROM 
	#generators x 
	INNER JOIN core c ON x.database_id = @databaseID AND x.rowset_id = c.rowset_id; ';

		SET @sql = REPLACE(@sql, N'{database}', DB_NAME(@databaseID));

		EXEC sys.[sp_executesql]
			@sql, 
			N'@databaseID int', 
			@databaseID = @databaseID;
	
		FETCH NEXT FROM [walker] INTO @databaseID;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	SELECT 
		[database_id], 
		SUM(CAST([length] AS bigint)) [total_length]
	INTO 
		#sizing
	FROM 
		[#generators]
	GROUP BY 
		[database_id];

	IF @DatabasesOnly = 1 BEGIN 
		SELECT 
			DB_NAME([database_id]) [database], 
			CAST([total_length] / 1073741824.0 AS decimal(24,2)) [versioned_gb]
		FROM 
			[#sizing] 
		ORDER BY 
			[total_length] DESC;

		RETURN 0;
	END;

	IF @TargetDatabase IS NOT NULL BEGIN 
		DELETE FROM [#generators] 
		WHERE 
			[database_id] <> DB_ID(@TargetDatabase);
	END;

	SELECT 
		DB_NAME([g].[database_id]) [database],
		QUOTENAME([g].[schema]) + N'.' + QUOTENAME([g].[name]) + CASE WHEN [g].[partition_number] = 1 THEN N'' ELSE N'::' + CAST([g].[partition_number] AS sysname) END [table],
		CAST([g].[length] / 1073741824.0 AS decimal(24,2)) [versioned_gb]
	FROM 
		[#generators] [g]
		INNER JOIN [#sizing] [s] ON [g].[database_id] = [s].[database_id]
	ORDER BY 
		[s].[total_length] DESC, [g].[length] DESC;

	RETURN 0;
GO