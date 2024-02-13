/*
	CONVENTION: 
		- This sproc uses the 'determine calling context' convention - i.e., it's an admindb sproc, but it can be called from other databases 
			and will 'use' the context of the calling database if/when called from another db. 

			i.e., it pseudo-behaves like an sp_sproc... 


	vNEXT:
		- Currently assumes dbo as Schema name and ... doesn't allow for different schemas. 
			so... make it do that... 


	TODO: 
		MOVE all of the follwing into list_index_metrics... (and maybe change list_index_metrics to ... list_index_details? or somethign?)

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

	-- See vNEXT about ... not supporting schema names currently.
	--DECLARE @targetTableName sysname = QUOTENAME(@targetSchema) + N'.' + QUOTENAME(@targetTable);

	DECLARE @indexData xml; 
	EXEC dbo.[list_index_metrics]
		@TargetDatabase = @targetDatabase,
		@TargetTables = @targetTable,
		@ExcludeSystemTables = 1,
		@IncludeFragmentationMetrics = 0,
		@MinRequiredTableRowCount = 0,
		@SerializedOutput = @indexData OUTPUT; 

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(table_name)[1]', N'sysname') [table_name], 
			[data].[row].value(N'(index_id)[1]', N'int') [index_id], 
			[data].[row].value(N'(index_name)[1]', N'sysname') [index_name], 
			[data].[row].value(N'(index_definition)[1]', N'nvarchar(MAX)') [index_definition], 
			[data].[row].value(N'(key_columns)[1]', N'nvarchar(MAX)') [key_columns], 
			[data].[row].value(N'(included)[1]', N'nvarchar(MAX)') [included_columns], 
			[data].[row].value(N'(row_count)[1]', N'bigint') [row_count], 
			[data].[row].value(N'(reads)[1]', N'bigint') [reads], 
			[data].[row].value(N'(writes)[1]', N'bigint') [writes], 
			[data].[row].value(N'(allocated_mb)[1]', N'decimal(24,2)') [allocated_mb], 
			[data].[row].value(N'(used_mb)[1]', N'decimal(24,2)') [used_mb], 
			[data].[row].value(N'(cached_mb)[1]', N'decimal(24,2)') [cached_mb], 
			[data].[row].value(N'(seeks)[1]', N'bigint') [seeks], 
			[data].[row].value(N'(scans)[1]', N'bigint') [scans], 
			[data].[row].value(N'(lookups)[1]', N'bigint') [lookups], 
			[data].[row].value(N'(seek_ratio)[1]', N'decimal(5,2)') [seek_ratio],
			[data].[row].query(N'(//operational_metrics/operational_metrics)[1]') [operational_metrics]
		FROM 
			@indexData.nodes(N'//index') [data]([row])

	) 

	SELECT 
		* 
	INTO 
		#hydrated 
	FROM 
		[shredded];

	SELECT
		[index_id],
		[index_name],
		[key_columns],
		[included_columns],
		N' ' [ ],
		[row_count],
		[reads],
		[writes],
		[allocated_mb],
		[used_mb],
		[cached_mb],
		[seeks],
		[scans],
		[lookups],
		[seek_ratio],
		[operational_metrics], 
		[index_definition]
	FROM 
		#hydrated
	ORDER BY 
		[index_id];
	
	SELECT 
		SUM(CASE WHEN [index_id] IN (0,1) THEN [allocated_mb] ELSE 0 END) [data], 
		SUM(CASE WHEN [index_id] NOT IN (0,1) THEN [allocated_mb] ELSE 0 END) [index]
	FROM 
		[#hydrated] 

	RETURN 0;
GO