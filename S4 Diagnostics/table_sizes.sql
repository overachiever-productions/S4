/*

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[table_sizes]','P') IS NOT NULL
	DROP PROC dbo.[table_sizes];
GO

CREATE PROC dbo.[table_sizes]
	@Databases				nvarchar(MAX)		= N'{ALL}',
	@Priorities				nvarchar(MAX)		= NULL,
	@Top					int					= 100, 
	@SerializedOutput		xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Databases = ISNULL(NULLIF(@Databases, N''), N'{ALL}');
	SET @Priorities = NULLIF(@Priorities, N'');
	
	CREATE TABLE #results (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL,
		[table_name] sysname NOT NULL,
		[row_count] sysname NULL,
		[reserved_gb] sysname NULL,
		[data_gb] sysname NULL,
		[indexes_gb] sysname NULL,
		[indexes] [int] NOT NULL,
		[columns] [int] NOT NULL,
		[triggers] [int] NOT NULL,
		[fks] [int] NOT NULL,
		[dfs] [int] NOT NULL,
		[cs] [int] NOT NULL,
		[uqs] [int] NOT NULL,
		[structure] sysname NOT NULL,
		[last_modified] [date] NULL, 
		[smells] nvarchar(MAX) NULL
	);

	DECLARE @template nvarchar(MAX) = N'USE [{CURRENT_DB}];
	WITH metrics AS ( 
			SELECT
				[ps].[object_id],
				(SELECT [o].[modify_date] FROM sys.[objects] [o] WHERE [o].[object_id] = [ps].[object_id]) [last_modified],
				SUM(CASE WHEN ([ps].[index_id] < 2) THEN [row_count] ELSE 0	END) AS [row_count],
				SUM([ps].[reserved_page_count]) AS [reserved],
				SUM(CASE WHEN ([ps].[index_id] < 2) THEN ([ps].[in_row_data_page_count] + [ps].[lob_used_page_count] + [ps].[row_overflow_used_page_count]) ELSE ([ps].[lob_used_page_count] + [ps].[row_overflow_used_page_count])	END) AS [data],
				SUM([ps].[used_page_count]) AS [used]
			FROM
				[sys].[dm_db_partition_stats] [ps]
			WHERE
				[ps].[object_id] NOT IN (SELECT [object_id] FROM [sys].[tables] WHERE [is_memory_optimized] = 1)
			GROUP BY
				[ps].[object_id]	
	), 
	expanded AS ( 
		SELECT 
			[m].[object_id],
			CAST([m].[last_modified] AS date) [last_modified],
			[m].[row_count], 
			[m].[reserved] * 8 [reserved], 
			[m].[data] * 8 [data],
			CASE WHEN [m].[used] > [m].[data] THEN [m].[used] - [m].[data] ELSE 0 END * 8 [index_size], 
			CASE WHEN [m].[reserved] > [m].[used] THEN [m].[reserved] - [m].[used] ELSE 0 END * 8 [unused]
		FROM 
			[metrics] [m]
	), 
	[indexes] AS (
		SELECT 
			[e].[object_id], 
			CASE WHEN MIN([i].[index_id]) = 0 THEN N''HEAP'' ELSE N''CLIX'' END [ix_type],
			COUNT([i].[index_id]) [index_count]
		FROM 
			sys.[indexes] [i]
			INNER JOIN [expanded] [e] ON [i].[object_id] = [e].[object_id]
		GROUP BY 
			[e].[object_id]
	), 
	[columns] AS ( 
		SELECT 
			[e].[object_id], 
			COUNT([c].[column_id]) [column_count]
		FROM 
			sys.[columns] [c]
			INNER JOIN [expanded] [e] ON [c].[object_id] = [e].[object_id]
		GROUP BY 
			[e].[object_id]
	), 
	[smell_types] AS ( 
		SELECT 
			[object_id]
		FROM 
			sys.columns 
		WHERE 
			[system_type_id] IN (34, 35, 99)
		GROUP BY 
			[object_id]
	),
	[smell_widths] AS ( 
		SELECT 
			[object_id], 
			SUM([max_length]) [width]
		FROM 
			sys.columns 
		WHERE 
			OBJECTPROPERTYEX([object_id], ''IsTable'') = 1 
			AND OBJECTPROPERTYEX([object_id], ''IsMSShipped'') = 0
		GROUP BY 
			[object_id]
		HAVING 
			SUM([max_length]) > 8060
	),
	[smell_pks] AS ( 
		SELECT 
			[object_id] 
		FROM 
			sys.tables [t]
		WHERE 
			OBJECTPROPERTYEX([t].[object_id], ''TableHasPrimaryKey'') = 0
			AND OBJECTPROPERTYEX([object_id], ''IsMSShipped'') = 0
	),
	[smell_constraints] AS ( 
		SELECT
			[t].[object_id],
			[c].[type_desc] [constraint_type],
			[c].[name] [constraint_name]
		FROM
			[sys].[tables] AS [t]
			INNER JOIN [sys].[check_constraints] AS [c] ON [t].[object_id] = [c].[parent_object_id]
		WHERE
			[c].[is_disabled] = 1

		UNION 

		SELECT 
			[parent_object_id] [object_id],
			CASE WHEN [is_disabled] = 1 THEN N''FOREIGN_KEY (DISABLED)'' ELSE N''FOREIGN_KEY (UNTRUSTED)'' END [constraint_type],
			[name] [constraint_name]
		FROM 
			[sys].[foreign_keys] 
		WHERE 
			[is_disabled] = 1 OR [is_not_trusted] = 1
	),
	[schema] AS (
		SELECT 
			[e].[object_id], 
			SUM(CASE WHEN [children].[type] = ''TR'' THEN 1 ELSE 0 END) [triggers],
			MAX(CASE WHEN [children].[type] = ''PK'' THEN 1 ELSE 0 END) [has_pk], 
			SUM(CASE WHEN [children].[type] = ''F'' THEN 1 ELSE 0 END) [fks], 
			SUM(CASE WHEN [children].[type] = ''D'' THEN 1 ELSE 0 END) [dfs],
			SUM(CASE WHEN [children].[type] = ''C'' THEN 1 ELSE 0 END) [cs], 
			SUM(CASE WHEN [children].[type] = ''UQ'' THEN 1 ELSE 0 END) [uqs]
		FROM 
			sys.[objects] [children]
			INNER JOIN [expanded] [e] ON [children].[parent_object_id] = [e].[object_id]
		GROUP BY 
			[e].[object_id]
	)

	INSERT INTO [#results] ([database_name], [table_name], [row_count], [reserved_gb], [data_gb], [indexes_gb], [indexes], [columns], [triggers], [fks], [dfs], [cs], [uqs], [structure], [last_modified], [smells])
	SELECT TOP ({top})
		N''[{CURRENT_DB}]'' [database_name],
		QUOTENAME(SCHEMA_NAME([t].[schema_id])) + N''.'' + QUOTENAME(OBJECT_NAME([e].[object_id])) [table_name],
		FORMAT([e].[row_count], N''N0'') [row_count],
		FORMAT([e].[reserved] / 1048576.0, N''N'') [reserved_gb],
		FORMAT([e].[data] / 1048576.0, N''N'') [data_gb],
		FORMAT([e].[index_size] / 1048576.0, N''N'') [indexes_gb], 
		ISNULL([i].[index_count], 0) [indexes],
		[c].[column_count] [columns],
		[s].[triggers],
		[s].[fks],
		[s].[dfs], 
		[s].[cs], 
		[s].[uqs],
		[i].[ix_type] + CASE WHEN [s].[has_pk] = 1 THEN N'' + PK'' ELSE N'''' END [structure],
		[e].[last_modified], 
		CASE WHEN [st].[object_id] IS NOT NULL THEN N'' DEPRECATED_DATA_TYPES; '' ELSE N'''' END
			+ CASE WHEN [sw].[object_id] IS NOT NULL THEN N'' WIDER_THAN_8060_BYTES; '' ELSE N'''' END
			+ CASE WHEN [sp].[object_id] IS NOT NULL THEN N'' NO_PK; '' ELSE N'''' END
			+ CASE WHEN [sc].[object_id] IS NOT NULL THEN N'' DISABLED_OR_UNTRUSTED_CONSTRAINTS; '' ELSE N'''' END
		[smells]
	FROM 
		[expanded] [e]
		INNER JOIN sys.[tables] [t] ON [e].[object_id] = [t].[object_id]
		INNER JOIN [schema] [s] ON [e].[object_id] = [s].[object_id]
		LEFT OUTER JOIN [indexes] [i] ON [e].[object_id] = [i].[object_id]
		LEFT OUTER JOIN [columns] [c] ON [e].[object_id] = [c].[object_id]
		LEFT OUTER JOIN [smell_types] [st] ON [e].[object_id] = [st].[object_id] 
		LEFT OUTER JOIN [smell_widths] [sw] ON [e].[object_id] = [sw].[object_id]
		LEFT OUTER JOIN [smell_pks] [sp] ON [e].[object_id] = [sp].[object_id]
		LEFT OUTER JOIN [smell_constraints] [sc] ON [e].[object_id] = [sc].[object_id]
	ORDER BY 
		[e].[reserved] DESC; ';

	DECLARE @sql nvarchar(MAX) = REPLACE(@template, N'{top}', @Top);

	DECLARE @Errors xml;
	DECLARE @errorContext nvarchar(MAX);
	EXEC dbo.[execute_per_database]
		@Databases = @Databases,
		@Priorities = @Priorities,
		@Statement = @sql,
		@Errors = @Errors OUTPUT; 

	IF @Errors IS NOT NULL BEGIN 
		SET @errorContext = N'Unexpected error while extracting table details (per database): ';
		GOTO ErrorDetails;
	END;

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN
		SET @SerializedOutput = (
			SELECT 
				[database_name],
				[table_name],
				[row_count],
				[reserved_gb],
				[data_gb],
				[indexes_gb],
				[indexes],
				[columns],
				[triggers],
				[fks],
				[dfs],
				[cs],
				[uqs],
				[structure],
				LTRIM(REPLACE([smells], N'  ', N' ')) [smells],
				[last_modified]
			FROM 
				[#results]
			ORDER BY 
				[row_id]
			FOR XML PATH(N'table'), ROOT(N'tables'), TYPE
		);
		RETURN 0;
	END;

	SELECT 
		[database_name],
		[table_name],
		[row_count],
		[reserved_gb],
		[data_gb],
		[indexes_gb],
		[indexes],
		[columns],
		[triggers],
		[fks],
		[dfs],
		[cs],
		[uqs],
		[structure],
		LTRIM(REPLACE([smells], N'  ', N' ')) [smells],
		[last_modified]
	FROM 
		[#results] 
	ORDER BY 
		[row_id];

	RETURN 0;

ErrorDetails:
	DECLARE @errorDetails nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	SELECT 
		@errorDetails = @errorDetails + N'DATABASE: ' + QUOTENAME([database_name]) 
		+ @crlftab + N'ERROR_MESSAGE: ' + REPLACE([error_message], @crlf, @crlftab)
		+ @crlftab + [statement] 
		+ @crlf
	FROM 
		dbo.[execute_per_database_errors](@errors)
	ORDER BY 
		[error_id];

	RAISERROR(@errorContext, 16, 1);
	EXEC dbo.[print_long_string] @errorDetails;	
	RETURN -100;
GO	