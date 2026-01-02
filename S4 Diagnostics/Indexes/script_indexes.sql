/*

	TODO:
		- currently using STUFF + FOR XML PATH ... vs STRING_AGG for SQL Server 16 and lower. 
				need to set up some DYNAMIC code that replaces those operations depending upon which version of SQL SErver we're dealing with.
		- Likewise, need to do something similar for the 3x columns found in SQL SErver 2022 (within sys.indexes) that aren't found in down-level versions. 
			AND ... i've started this (in terms of logical addition of columns for #indexes_to_script ... but... 'gave up' when I then had to change the INSERT + SELECT clauses... 
						i.e., just need to make the INSERT/SELECT statements fully dynamic.
				that said... no need to bother including these 3x columns ([is_ignored_in_optimization], [suppress_dup_key_messages], [optimize_for_sequential_key]) if they're NOT needed for scripting definitions.

	vNEXT: 
		- Implement the @Directives and @Overrides. 
				- @Directives would be anything that can be set for execution at runtime - i.e., IX creation SYNTAX that doesn't become PART of the persisted IX definition. 
							SORT_IN_TEMPDB
							ONLINE = ON/OFF (otherwise, defaults to edition type). 
							MAXDOP
							MAXDURATION 
							RESUMABLE 
							DROP_EXISTING ... i think this is one of the few 'options' that COULD be specified in either @Directives OR @Overrides
							INCLUDE_GO ... directive for this SPROC ... which determines whether to drop a GO after EACH statement - or not. 
					where, again, the idea is to 'direct' specific details during IX creation/definition... 
					and, where there's an option - above to cause the output of dbo.script_indexes to include a GO (batch terminator) after each IX definition. 
				
				- On the other hand, @Overrides would be anything that explicitly CHANGES the definition of the IX, such as: 
							PAD_INDEX (e.g. PAD_INDEX or PAD_INDEX_OFF (PAD_INDEX_ON is the same as PAD_INDEX). 
							FILL_FACTOR_#
							IGNORE_DUPLICATE_KEY_ON|OFF
							STATS_NORECOMPUTE ... 
							STATS_INCREMENTAL
							ALLOW_PAGE|ROW_LOCKs 
							OPTIMIZE_FOR_SEQUENTIAL_KEY
							DATA_COMPRESSION (ROW | PAGE | NONE) - e.g., DATA_COMPRESSION_NONE ... 
							XML_COMPRESSION ??? i don't even know if my index 'syntax' above supports the idea of an XML index... 
					where, again, the idea here is that - say, ... we want to change all IXes against a given table to have a changed/different FILLFACTOR ... 
							at that point, we could set @Overrides = 'FILLFACTOR = 70' and the new, forced/overridden, FILLFACTOR for EVERY IX scripted via this sproc would be ... 70. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_indexes','P') IS NOT NULL
	DROP PROC dbo.[script_indexes];
GO

CREATE PROC dbo.[script_indexes]
	@TargetDatabase				sysname				= NULL, 
	@TargetTables				nvarchar(MAX)		= N'{ALL}', 
	@ExcludedTables				nvarchar(MAX)		= NULL,
	@TargetIndexes				sysname				= N'{ALL}', 
	@ExcludedIndexes			nvarchar(MAX)		= NULL,
	@ExcludeHeaps				bit					= 1,
	@IncludeSystemTables		bit					= 0, 
	@IncludeViews				bit					= 0, 
	@SerializedOutput			xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TargetTables = ISNULL(NULLIF(@TargetTables, N''), N'{ALL}'); 
	SET @TargetIndexes = ISNULL(NULLIF(@TargetIndexes, N''), N'{ALL}'); 

	SET @ExcludedTables = NULLIF(@ExcludedTables, N'');
	SET @ExcludedIndexes = NULLIF(@ExcludedIndexes, N'');

	SET @ExcludeHeaps = ISNULL(@ExcludeHeaps, 1);

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;
		
		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for @TargetDatabase and/or S4 was unable to determine calling-db-context. Please specify a valid database name for @TargetDatabase and retry. ', 16, 1);
			RETURN -5;
		END;
	END;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
    DECLARE @newAtrributeLine sysname = @crlf + NCHAR(9) + N' ';
	DECLARE @sql nvarchar(MAX);
	DECLARE @types sysname = N'''U'''; 
	IF @IncludeSystemTables = 1 SET @types = @types + N', ''S''';
	IF @IncludeViews = 1 SET @types = @types + N', ''V''';

	IF @ExcludedTables IS NOT NULL BEGIN 
		CREATE TABLE #excluded_tables (
			[table_name] sysname NOT NULL
		);

		INSERT INTO [#excluded_tables] ([table_name])
		SELECT [result] FROM dbo.split_string(@ExcludedTables, N',', 1);
	END;

	CREATE TABLE #target_tables (
		[table_name] sysname NOT NULL, 
		[object_id] int NULL
	);

	IF @TargetTables <> N'{ALL}' BEGIN 
		INSERT INTO [#target_tables] ([table_name])
		SELECT [result] FROM dbo.split_string(@TargetTables, N',', 1);

		IF EXISTS (SELECT NULL FROM [#target_tables] WHERE [table_name] LIKE N'%`%%' ESCAPE N'`') BEGIN 
			SET @sql = N'SELECT 
				[t].[name]
			FROM 
				[{0}].sys.[objects] [t]
				LEFT OUTER JOIN [#target_tables] [x] ON [t].[name] LIKE [x].[table_name]
			WHERE 
				[t].[type] IN ({types})
				AND [x].[table_name] LIKE N''%`%'' ESCAPE N''`''; '; 

			SET @sql = REPLACE(@sql, N'{types}', @types);
			SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

			INSERT INTO [#target_tables] ([table_name]) 
			EXEC sys.sp_executesql 
				@sql; 

			DELETE FROM [#target_tables] WHERE [table_name] LIKE N'%`%%' ESCAPE N'`';
		END;

		SET @sql = N'USE [' + @TargetDatabase + N'];
		UPDATE #target_tables 
		SET 
			[object_id] = OBJECT_ID([table_name])
		WHERE 
			[object_id] IS NULL; ';

		EXEC sp_executesql 
			@sql;

		-- MKC: need to 'pre-exclude' here to avoid error about NOT finding an explicitly defined table. (AND need to exclude below as well).
		IF @ExcludedTables IS NOT NULL BEGIN 
			DELETE [t] 
			FROM 
				[#target_tables] [t] 
				INNER JOIN [#excluded_tables] [x] ON [t].[table_name] LIKE [x].[table_name];
		END;
		
		IF EXISTS (SELECT NULL FROM [#target_tables] WHERE [object_id] IS NULL) BEGIN 
			SELECT [table_name] [target_table], [object_id] FROM [#target_tables] WHERE [object_id] IS NULL; 

			RAISERROR(N'One or more supplied @TargetTables could not be identified (i.e., does not have a valid object_id). Please remove or correct.', 16, 1);
			RETURN -11;
		END;
	END;

	CREATE TABLE #target_indexes (
		[object_name] sysname NOT NULL, 
		[object_id] sysname NOT NULL, 
		[schema_id] int NOT NULL,
		[object_type] char(1) NOT NULL,
		[index_id] int NOT NULL, 
		[index_name] sysname NULL 
		-- other cols here as needed
	);

	SET @sql = N'	SELECT 
		[o].[name], 
		[o].[object_id], 
		[o].[schema_id], 
		[o].[type],
		[i].[index_id], 
		[i].[name]
	FROM 
		[{0}].sys.objects [o] 
		INNER JOIN [{0}].sys.indexes [i] ON [o].[object_id] = [i].[object_id] 
	WHERE 
		[o].[type] IN ({types}){filter}; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{types}', @types);
	
	IF UPPER(@TargetTables) = N'{ALL}' BEGIN 
		SET @sql = REPLACE(@sql, N'{filter}', N'');
	  END; 
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{filter}', @newAtrributeLine + NCHAR(9) + N'AND [o].[name] IN (SELECT [table_name] FROM [#target_tables])');
	END;

	INSERT INTO [#target_indexes] ([object_name], [object_id], [schema_id], [object_type], [index_id], [index_name])
	EXEC sys.sp_executesql 
		@sql;

	IF @ExcludedTables IS NOT NULL BEGIN 
		DELETE [t] 
		FROM 
			[#target_indexes] [t] 
			INNER JOIN [#excluded_tables] [x] ON [t].[object_name] LIKE [x].[table_name];
	END; 

	IF @ExcludedIndexes IS NOT NULL BEGIN 
		DELETE [t] 
		FROM 
			[#target_indexes] [t] 
			INNER JOIN (SELECT [result] FROM dbo.[split_string](@ExcludedIndexes, N',', 1)) [x] ON [t].[index_name] LIKE [x].[result];
	END;
	
	IF NOT EXISTS (SELECT NULL FROM [#target_indexes]) BEGIN 
		PRINT N'No matches found for provided inputs.';
		RETURN 0;  
	END;
	
	CREATE TABLE #indexes_to_script (
		[schema_name] sysname NOT NULL,
		[object_type] char(1) NOT NULL,
		[object_id] int NOT NULL,
		[object_name] sysname NOT NULL,
		[index_id] int NOT NULL,
		[index_name] sysname NULL,
		[type_desc] nvarchar(60) NULL,
		[key_columns] nvarchar(4000) NULL,
		[included_columns] nvarchar(4000) NULL,
		[is_unique] bit NULL,
		[data_space_id] int NULL,
		[dataspace_name] sysname NULL,
		[partition_scheme_name] sysname NULL,
		[ignore_dup_key] bit NULL,
		[is_primary_key] bit NULL,
		[is_unique_constraint] bit NULL,
		[fill_factor] tinyint NOT NULL,
		[is_padded] bit NULL,
		[is_disabled] bit NULL,
		--[is_ignored_in_optimization] bit NULL,
		[allow_row_locks] bit NULL,
		[allow_page_locks] bit NULL,
		[filter_definition] nvarchar(max) NULL,
		[compression_delay] int NULL,
		--[suppress_dup_key_messages] bit NULL,  -- 2017+
		--[optimize_for_sequential_key] bit NULL  -- 2019+ 
	);

	-- TODO: figure out a) IF [is_ignored_in_optimization] is something that needs to be part of IX definitions/scripts and b) when it was added 
	IF (SELECT dbo.[get_engine_version]()) >= 14.00 BEGIN 
		ALTER TABLE [#indexes_to_script] ADD [suppress_dup_key_messages] bit NULL;
	END;

	IF (SELECT dbo.[get_engine_version]()) >= 15.00 BEGIN 
		ALTER TABLE [#indexes_to_script] ADD [optimize_for_sequential_key] bit NULL;
	END;

	SET @sql = N'	SELECT 
		[s].[name] [schema_name],
		[x].[object_type],
		[x].[object_id],
		[x].[object_name],
		[x].[index_id],
		[x].[index_name],
		[i].[type_desc],
		--(SELECT STRING_AGG((QUOTENAME([c].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN N'' DESC'' ELSE N'''' END), N'', '') WITHIN GROUP(ORDER BY [ic].[key_ordinal]) FROM [{0}].sys.[index_columns] [ic] INNER JOIN [{0}].sys.columns [c] ON [ic].[object_id] = [c].[object_id] AND [ic].[column_id] = [c].[column_id] WHERE [ic].[key_ordinal] > 0 AND [ic].[object_id] = [i].[object_id] AND [ic].[index_id] = [i].[index_id]) [key_columns], 
		--(SELECT STRING_AGG(QUOTENAME([c].[name]), N'', '') WITHIN GROUP(ORDER BY [ic].[key_ordinal]) FROM [{0}].sys.[index_columns] [ic] INNER JOIN [{0}].sys.columns [c] ON [ic].[object_id] = [c].[object_id] AND [ic].[column_id] = [c].[column_id] WHERE [ic].[is_included_column] = 1 AND [ic].[object_id] = [i].[object_id] AND [ic].[index_id] = [i].[index_id]) [included_columns],
		(SELECT STUFF((SELECT N'', '' + QUOTENAME([c].[name]) + CASE WHEN [ic].[is_descending_key] = 1 THEN N'' DESC'' ELSE N'''' END FROM [{0}].sys.[index_columns] [ic] INNER JOIN [{0}].sys.columns [c] ON [ic].[object_id] = [c].[object_id] AND [ic].[column_id] = [c].[column_id] WHERE [ic].[key_ordinal] > 0 AND [ic].[object_id] = [i].[object_id] AND [ic].[index_id] = [i].[index_id] ORDER BY [ic].[key_ordinal] FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(MAX)''), 1, 1, N'''')) [key_columns],
		(SELECT STUFF((SELECT N'', '' + QUOTENAME([c].[name]) FROM [{0}].sys.[index_columns] [ic] INNER JOIN [{0}].sys.columns [c] ON [ic].[object_id] = [c].[object_id] AND [ic].[column_id] = [c].[column_id] WHERE [ic].[is_included_column] = 1 AND [ic].[object_id] = [i].[object_id] AND [ic].[index_id] = [i].[index_id] ORDER BY [ic].[key_ordinal] FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(MAX)''), 1, 1, N'''')) [included_columns],
		[i].[is_unique],
		[i].[data_space_id], 
		[d].[name] [dataspace_name],
		[ps].[name] [partition_scheme_name], -- TODO: going to have to look up the columns? for this? 
		[i].[ignore_dup_key],
		[i].[is_primary_key],
		[i].[is_unique_constraint],
		[i].[fill_factor],
		[i].[is_padded],
		[i].[is_disabled],
		--[i].[is_ignored_in_optimization], -- no idea when this was added ... 
		[i].[allow_row_locks],
		[i].[allow_page_locks],
		--[i].[has_filter],
		[i].[filter_definition],
		[i].[compression_delay]
		--[i].[suppress_dup_key_messages],
		--[i].[optimize_for_sequential_key] 
	FROM 
		[{0}].sys.indexes [i]
		INNER JOIN [#target_indexes] [x] ON [i].[object_id] = [x].[object_id] AND [i].[index_id] = [x].[index_id]
		INNER JOIN [{0}].sys.[schemas] [s] ON [x].[schema_id] = [s].[schema_id]
		LEFT OUTER JOIN [{0}].sys.[data_spaces] [d] ON [i].[data_space_id] = [d].[data_space_id]
		LEFT OUTER JOIN [{0}].sys.[partition_schemes] [ps] ON [i].[data_space_id] = [ps].[data_space_id]
	ORDER BY 
		[x].[object_name], [i].[index_id]; ';

	SET @sql = REPLACE(@sql, N'{0}', @TargetDatabase);

	INSERT INTO [#indexes_to_script] (
		[schema_name],
		[object_type],
		[object_id],
		[object_name],
		[index_id],
		[index_name],
		[type_desc],
		[key_columns],
		[included_columns],
		[is_unique],
		[data_space_id],
		[dataspace_name],
		[partition_scheme_name],
		[ignore_dup_key],
		[is_primary_key],
		[is_unique_constraint],
		[fill_factor],
		[is_padded],
		[is_disabled],
		--[is_ignored_in_optimization],
		[allow_row_locks],
		[allow_page_locks],
		[filter_definition],
		[compression_delay]--,
		--[suppress_dup_key_messages],
		--[optimize_for_sequential_key]
	)
	EXEC sys.[sp_executesql]
		@sql;
	
	IF @ExcludeHeaps = 1 BEGIN 
		DELETE FROM [#indexes_to_script] WHERE [index_id] = 0;
	END;
	   
	WITH options AS ( 
		SELECT 
			[object_id], 
			[index_id],
			CASE WHEN [is_padded] = 1 THEN N'PAD_INDEX = ON, ' ELSE N'' END 
				-- + stats recompute (where do i even find this?)
				-- + compression (page/row/none (default))
				--		though... this can also be defined by partitions ... so... that's complex. 
				-- + sort_in_tempdb... (directive)
				-- + drop_existing... (directive)
				-- + ONLINE (directive)
			+ CASE WHEN [allow_row_locks] = 0 THEN N' ALLOW_ROW_LOCKS = OFF,' ELSE N'' END 
			+ CASE WHEN [allow_page_locks] = 0 THEN N' ALLOW_PAGE_LOCKS = OFF' ELSE N'' END
			+ CASE WHEN [fill_factor] <> 0 THEN N' FILLFACTOR = ' + CAST([fill_factor] AS sysname) + N', ' ELSE N'' END
			 [options]
		FROM 
			[#indexes_to_script] 
	)

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[i].[object_id],
		[i].[index_id],
		[i].[schema_name], 
		[i].[object_name], 
		[i].[index_name],
		[i].[key_columns], 
		[i].[included_columns],
		CASE 
			WHEN [i].[index_id] = 0 THEN N'-- HEAP: ' + QUOTENAME([i].[schema_name]) + N'.' + QUOTENAME([object_name]) + @crlf
			ELSE 
				CASE WHEN [i].[is_primary_key] = 1 THEN N'ALTER TABLE ' + QUOTENAME([i].[schema_name]) + N'.' + QUOTENAME([object_name]) + N' ADD CONSTRAINT ' + QUOTENAME([i].[index_name]) + @crlf + N'PRIMARY KEY ' + CASE WHEN [i].[index_id] = 1 THEN N'CLUSTERED' ELSE N'' END + N' '
				ELSE N'CREATE ' + CASE WHEN [i].[is_unique] = 1 THEN N'UNIQUE' ELSE N'' END + CASE WHEN [i].[index_id] = 1 THEN N'' ELSE N'NON' END + N'CLUSTERED INDEX' + ' ' + QUOTENAME([i].[index_name]) + N' ' + @crlf + N'ON ' + QUOTENAME([i].[schema_name]) + N'.' + QUOTENAME([i].[object_name])
			END
			+ N' (' + LTRIM([i].[key_columns]) + N')'
			+ CASE WHEN [i].[included_columns] IS NOT NULL THEN @crlf + N'INCLUDE (' + LTRIM([i].[included_columns]) + N')' ELSE N'' END
			+ CASE WHEN [i].[filter_definition] IS NOT NULL THEN @crlf + N'WHERE ' + [i].[filter_definition] + N' ' ELSE N'' END
			+ CASE WHEN NULLIF(ISNULL([o].[options], N''), N'') IS NULL THEN N'' ELSE @crlf + N'WITH (' + LTRIM(LEFT([o].[options], LEN([o].[options]) - 1)) + N')' END
			+ @crlf + CASE WHEN [i].[partition_scheme_name] IS NULL THEN CASE WHEN [i].[dataspace_name] IS NULL THEN N'WITH STATISTICS_ONLY = -1' ELSE N'ON ' + QUOTENAME([i].[dataspace_name]) END ELSE N'<partition_scheme_column_here>' END			
			+ N';' + @crlf 
		END + @crlf [definition]
	INTO 
		#projected_indexes
	FROM 
		[#indexes_to_script] [i]
		INNER JOIN [options] [o] ON [i].[object_id] = [o].[object_id] AND [i].[index_id] = [o].[index_id]
	ORDER BY 
		[i].[object_name], [i].[index_id];

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- RETURN instead of project.. 
		SELECT @SerializedOutput = (
			SELECT 
				[object_id],
				[index_id],
				[schema_name],
				[object_name],
				[index_name],
				[key_columns], 
				[included_columns],
				[definition]
			FROM 
				[#projected_indexes] 
			ORDER BY 
				[row_id]
			FOR XML PATH(N'object'), ROOT(N'objects'), TYPE, ELEMENTS XSINIL
		);

		RETURN 0;
	END;

	-- otherwise: 
	DECLARE @output nvarchar(MAX) = N'';
	SELECT 
		@output = @output + ISNULL([definition], N'[ERROR: definition is NULL]' + NCHAR(13) + NCHAR(10) + NCHAR(13) + NCHAR(10)) 
	FROM 
		[#projected_indexes] 
	ORDER BY 
		[row_id];

	EXEC [dbo].[print_long_string] @output;

	RETURN 0; 
GO