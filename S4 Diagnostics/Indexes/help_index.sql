/*
	CONVENTION: 
		- This sproc uses the 'determine calling context' convention - i.e., it's an admindb sproc, but it can be called from other databases 
			and will 'use' the context of the calling database if/when called from another db. 

			i.e., it pseudo-behaves like an sp_sproc... 



	TODO: 
		- REFACTOR: probably want to refactor this pig... the name ain't so great at this point... 

		- xml ... for advanced options? like.... is PK, is unique, is_disabled... is_hypot... (that should be in a 'WARNING')
		
		- Yeah, along the lines of the above... add a WARNINGS column... 
				and raise issues if: hypothetical or blocks any type of LOCK, or is_ignored_in_optimization (wth is that?)

		- also, need to have a filter detail as well... 


		AND. These are all just DEFINITION thingies... 
			eventually, there's no reason I can't include things like: 
				- row-counts, 
				- fragmentation, 
				- read-write ratios
				- duplication-factor (i.e., duplicates another IX) or overlaps it... i.e., duplicates AND overlaps would be fun... 
				- operational stats - i.e., locks times, latch times... 
				- physical stats (total size (table size for CLIX))... and amount in RAM... 
				- etc... 

	EXAMPLES / SIGNATURES: 


		----------------------------------------------------------------------
				USE Billing; 
				GO 

				EXEC admindb.dbo.help_index 'dbo.Entries';

		----------------------------------------------------------------------
				USE Monarch; 
				GO 

				EXEC admindb.dbo.help_index 'Logs';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.help_index','P') IS NOT NULL
	DROP PROC dbo.[help_index];
GO

CREATE PROC dbo.[help_index]
	@Target					sysname				= NULL

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @Target, 
		@ParameterNameForTarget = N'@Target', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 

	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetTable sysname;
	SELECT 
		@targetDatabase = PARSENAME(@normalizedName, 3),
		@targetSchema = PARSENAME(@normalizedName, 2), 
		@targetTable = PARSENAME(@normalizedName, 1);

	DECLARE @sql nvarchar(MAX);
	SET @sql = N'SELECT index_id, ISNULL([name], N''-HEAP-'') FROM [' + @targetDatabase + N'].sys.[indexes] WHERE [object_id] = @targetObjectID; ';

	CREATE TABLE #sys_indexes (
		index_id int NOT NULL, 
		index_name sysname NULL -- frickin' heaps
	);

	INSERT INTO [#sys_indexes] (
		[index_id],
		[index_name]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@targetObjectID int', 
		@targetObjectID = @targetObjectID;

	SET @sql = N'
	SELECT 
		ic.index_id, 
		c.[name] column_name, 
		ic.key_ordinal,
		ic.is_included_column, 
		ic.is_descending_key 
	FROM 
		[' + @targetDatabase + N'].sys.index_columns ic 
		INNER JOIN [' + @targetDatabase + N'].sys.columns c ON ic.[object_id] = c.[object_id] AND ic.column_id = c.column_id 
	WHERE 
		ic.[object_id] = @targetObjectID;
	';

	CREATE TABLE #index_columns (
		index_id int NOT NULL, 
		column_name sysname NOT NULL, 
		key_ordinal int NOT NULL,
		is_included_column bit NOT NULL, 
		is_descending_key bit NOT NULL
	);

	INSERT INTO [#index_columns] (
		[index_id],
		[column_name],
		[key_ordinal],
		[is_included_column],
		[is_descending_key]
	)
	EXEC [sys].[sp_executesql] 
		@sql, 
		N'@targetObjectID int', 
		@targetObjectID = @targetObjectID;

	CREATE TABLE #output (
		index_id int NOT NULL, 
		index_name sysname NOT NULL, 
		[definition] nvarchar(MAX) NOT NULL 
	);

	DECLARE @serialized nvarchar(MAX);
	DECLARE @currentIndexID int, @currentIndexName sysname;
	DECLARE [serializer] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		index_id, 
		index_name 
	FROM 
		[#sys_indexes] 
	ORDER BY 
		[index_id];
	
	OPEN [serializer];
	FETCH NEXT FROM [serializer] INTO @currentIndexID, @currentIndexName;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @serialized = N'';

		WITH core AS ( 
			SELECT 
				ic.column_name, 
				CASE 
					WHEN ic.is_included_column = 1 THEN 999 
					ELSE ic.key_ordinal 
				END [ordinal], 
				ic.is_descending_key
			FROM 
				[#sys_indexes] i
				INNER JOIN [#index_columns] ic ON i.[index_id] = ic.[index_id]
			WHERE 
				i.[index_id] = @currentIndexID
		) 	

		SELECT 
			@serialized = @serialized 
				+ CASE WHEN ordinal = 999 THEN N'[' ELSE N'' END 
				+ column_name 
				+ CASE WHEN is_descending_key = 1 THEN N' DESC' ELSE N'' END 
				+ CASE WHEN ordinal = 999 THEN N']' ELSE N'' END
				+ N','				   
		FROM 
			[core] 
		ORDER BY 
			[ordinal];

		SET @serialized = SUBSTRING(@serialized, 0, LEN(@serialized));

		INSERT INTO [#output] (
			[index_id],
			[index_name],
			[definition]
		)
		VALUES	(
			@currentIndexID, 
			@currentIndexName, 
			@serialized
		)

		FETCH NEXT FROM [serializer] INTO @currentIndexID, @currentIndexName;
	END;
	
	CLOSE [serializer];
	DEALLOCATE [serializer];

	-- Projection: 
	SELECT 
		[index_id],
		CASE WHEN [index_id] = 0 THEN N'-HEAP-' ELSE [index_name] END [index_name],
		CASE WHEN [index_id] = 0 THEN N'-HEAP-' ELSE [definition] END [definition]
	FROM 
		[#output]
	ORDER BY 
		[index_id];

	RETURN 0;
GO