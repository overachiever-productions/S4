/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.


	SIGNATURES / EXAMPLE EXECUTIONS: 

			EXEC admindb.dbo.[get_low_seekratio_indexes]
				@TargetDatabase = N'BookCrossing', 
				@ExcludedIndexes = N'_dta%', 
				--@ExcludedTables = N'%ember%', 
				@Verbose = 1;


			DECLARE @targetIxes nvarchar(MAX);
			EXEC admindb.dbo.[get_low_seekratio_indexes]
				@TargetDatabase = N'BookCrossing', 
				@ExcludedIndexes = N'_dta%', 
				@ExcludedTables = N'%ember%', 
				@Output = @targetIxes OUTPUT; 

			SELECT @targetIxes;



	REFACTOR: 
		get_low_seekratio_indexes ... 
		get_indexes_with_low_seekratios
		indexes_with_low_seekratios
		
		low_seekratio_indexes

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_low_seekratio_indexes','P') IS NOT NULL
	DROP PROC dbo.[get_low_seekratio_indexes];
GO

CREATE PROC dbo.[get_low_seekratio_indexes]
	@TargetDatabase						sysname, 
	@ExcludedIndexes					nvarchar(MAX)		= NULL,
	@ExcludedTables						nvarchar(MAX)		= NULL,
	@MinimumPageCount					int					= 1000,
	@UpperFragmentationThreshold		decimal(3,1)		= 50.0, 
	@LowerFragmentationThreshold		decimal(3,1)		= 5.0, 
	@SeekRatioThreshold					decimal(3,1)		= 94.0, 
	@Verbose							bit					= 0,			-- When 1, outputs/prints excluded IXes and reasons they were excluded. 
	@Output								nvarchar(MAX)		= ''		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @ExcludedIndexes = NULLIF(@ExcludedIndexes, N'');
	SET @ExcludedTables = NULLIF(@ExcludedTables, N'');

	CREATE TABLE [#targetIndexes] (
		[object_id] int NOT NULL,
		[index_id] int NOT NULL, 
		[schema_name] sysname NULL, 
		[table_name] sysname NULL, 
		[index_name] sysname NULL,
		[seek_ratio] decimal(20,2) NOT NULL, 
		[page_count] int NULL, 
		[avg_fragmentation_in_percent] float NULL, 
		[removal_reason] sysname NULL
	);

	WITH core AS ( 
		SELECT 
			[object_id],
			index_id,
			u.user_seeks, 
			u.user_scans,
			u.user_lookups,
			CAST(CAST(u.user_seeks AS decimal(20,2)) / (CAST(u.user_seeks AS decimal(20,2)) + CAST(u.user_scans AS decimal(20,2))) * 100.0 AS decimal(20,2)) [seek_ratio]
		FROM 
			sys.dm_db_index_usage_stats u
		WHERE 
			u.database_id = DB_ID(@TargetDatabase)  
			AND u.user_seeks > u.user_scans
	)

	INSERT INTO #targetIndexes ([object_id], index_id, seek_ratio)
	SELECT 
		[object_id],
		index_id,
		seek_ratio
	FROM 
		core;

	DECLARE @namesSql nvarchar(MAX) = N'WITH source AS ( 
	SELECT 
		i.[object_id],
		i.[index_id],
		s.[name] [schema_name],
		o.[name] [table_name],
		--OBJECT_NAME(i.[object_id], DB_ID(@TargetDatabase)) [table_name], 
		i.[name] [index_name]
	FROM 
		[{targetDb}].sys.[indexes] i 
		INNER JOIN [{targetDb}].sys.[objects] o ON i.[object_id] = o.[object_id]
		INNER JOIN [{targetDb}].sys.[schemas] s ON o.[schema_id] = s.[schema_id]
		INNER JOIN #targetIndexes x ON i.[object_id] = x.[object_id] AND i.[index_id] = x.[index_id]
) 

UPDATE x 
SET 
	x.[schema_name] = s.[schema_name],
	x.[table_name] = s.[table_name], 
	x.[index_name] = s.[index_name] 
FROM 
	#targetIndexes x 
	INNER JOIN source s ON x.[object_id] = s.[object_id] AND x.[index_id] = s.[index_id];
';

	SET @namesSql = REPLACE(@namesSql, N'{targetDb}', @TargetDatabase);

	EXEC sp_executesql 
		@namesSql, 
		N'@TargetDatabase sysname', 
		@TargetDatabase = @TargetDatabase;

	UPDATE [#targetIndexes]
	SET 
		[removal_reason] = N'BELOW_SEEK_THRESHOLD'
	WHERE 
		[seek_ratio] < @SeekRatioThreshold; 

	UPDATE x 
	SET 
		x.[page_count] = s.[page_count], 
		x.[avg_fragmentation_in_percent] = s.[avg_fragmentation_in_percent]
	FROM 
		[#targetIndexes] x 
		CROSS APPLY sys.[dm_db_index_physical_stats](DB_ID(@TargetDatabase), x.[object_id], x.[index_id], NULL, N'SAMPLED') s
	WHERE 
		[removal_reason] IS NULL;

	UPDATE [#targetIndexes] 
	SET 
		[removal_reason] = N'BELOW_MINIMUM_PAGE_COUNT'
	WHERE 
		[page_count] < @MinimumPageCount;

	UPDATE [#targetIndexes] 
	SET 
		[removal_reason] = N'ABOVE_FRAGMENTATION_THRESHOLD'
	WHERE 
		[avg_fragmentation_in_percent] >= @UpperFragmentationThreshold

	UPDATE [#targetIndexes] 
	SET 
		[removal_reason] = N'BELOW_FRAGMENTATION_THRESHOLD'
	WHERE 
		[avg_fragmentation_in_percent] <= @LowerFragmentationThreshold

	IF @ExcludedIndexes IS NOT NULL BEGIN
		UPDATE t
		SET 
			t.[removal_reason] = N'EXPLICIT_IX_EXLCUSION: ' + x.[result]
		FROM 
			[#targetIndexes] t
			INNER JOIN dbo.[split_string](@ExcludedIndexes, N',', 1) x ON t.[index_name] LIKE x.[result]
		WHERE 
			[t].[removal_reason] IS NULL;
	END;
	
	IF @ExcludedTables IS NOT NULL BEGIN 
		UPDATE t 
		SET 
			t.[removal_reason] = N'EXPLICIT_TABLE_EXCLUSUION: ' + x.[result]
		FROM 
			[#targetIndexes] t
			INNER JOIN dbo.[split_string](@ExcludedTables, N',', 1) x ON t.[table_name] LIKE x.[result]
		WHERE 
			t.[removal_reason] IS NULL;
	END;

	DECLARE @result nvarchar(MAX) = N'ALL_INDEXES,';

	SELECT
		@result = @result + N'-' + QUOTENAME(@TargetDatabase) + N'.' + QUOTENAME([schema_name]) + N'.' + QUOTENAME([table_name]) + N'.' + [index_name] + N','
	FROM 
		[#targetIndexes] 
	WHERE 
		[removal_reason] IS NULL
		AND [index_name] NOT LIKE '%,%';  -- HACK to skip/avoid indexes with , in them... 

	SET @result = LEFT(@result, LEN(@result) - 1);

	IF @Verbose = 1 BEGIN 
		IF EXISTS(SELECT NULL FROM [#targetIndexes] WHERE [removal_reason] IS NOT NULL) BEGIN 
			DECLARE @crlf nchar(2)  = NCHAR(13) + NCHAR(10); 
			DECLARE @tab nchar(1) = NCHAR(9);
			DECLARE @details nvarchar(MAX) = N'EXCLUDED INDEXES:' + @crlf; 

			SELECT
				@details = @details + @tab + N'- ' + QUOTENAME([table_name]) + N'.' + QUOTENAME([index_name]) + N' (seek_ratio: ' + CAST([seek_ratio] AS sysname) + N', page_count: ' + CAST([page_count] AS sysname) + N', frag_%: ' + CAST(CAST([avg_fragmentation_in_percent] AS decimal(3,1)) AS sysname) + N', removal_reason: ' + [removal_reason] + N')' + @crlf
			FROM 
				[#targetIndexes] 
			WHERE 
				[removal_reason] IS NOT NULL 
			ORDER BY 
				[removal_reason];

			EXEC dbo.[print_long_string] @details;
		  END; 
		ELSE BEGIN 
			PRINT 'NO INDEXES were EXCLUDED from targetting.';
		END;
	END;

	IF @Output IS NULL BEGIN 
		SET @Output = @result;
	  END;
	ELSE BEGIN 
		SELECT @result;
	END;

	RETURN 0;
GO