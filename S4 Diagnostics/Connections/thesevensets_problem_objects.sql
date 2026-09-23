/*
	
	partner in crime is dbo.thesevensets_problem_connections. 


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[thesevensets_problem_objects]', N'P') IS NOT NULL 
	DROP PROC [dbo].[thesevensets_problem_objects];
GO

CREATE PROC [dbo].[thesevensets_problem_objects] 
	@databases						nvarchar(MAX)		= N'{ALL}', 
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
	SET NOCOUNT ON;

	-- {copyright}

	SET @databases = ISNULL(NULLIF(@databases, N''), N'{ALL}');

	CREATE TABLE #problems (
		[database_name] sysname NOT NULL, 
		[type] sysname NOT NULL,
		[object] sysname NOT NULL, 
		[problem] sysname NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}]; 

	INSERT INTO [#problems] ([database_name], [type], [object], [problem])
	SELECT
		N''[{CURRENT_DB}]'' [database_name],
		N''COLUMN'' [type],
		CONCAT(QUOTENAME(SCHEMA_NAME([o].[schema_id])), N''.'', QUOTENAME(OBJECT_NAME([c].[object_id]))) [object],
		CONCAT(N''ANSI_PADDED = OFF for column: '', QUOTENAME([c].[name]), N''.'') [problem]
	FROM
		[sys].[columns] [c]
		INNER JOIN [sys].[objects] [o] ON [c].[object_id] = [o].[object_id]
	WHERE
		TYPE_NAME([c].[system_type_id]) LIKE N''%char%'' 
-- MKC: need to triple check this logic:
		AND TYPE_NAME([c].[system_type_id]) NOT LIKE N''%MAX%)'' 
		AND [c].[is_ansi_padded] = 0
	
	UNION 

	SELECT 
		N''[{CURRENT_DB}]'' [database_name],
		N''TABLE'' [type],
		CONCAT(QUOTENAME(SCHEMA_NAME([schema_id])), N''.'', QUOTENAME([name])) [object],
		N''ANSI_NULLS = OFF.'' [problem]
	FROM 
		sys.[tables]
	WHERE 
		[uses_ansi_nulls] = 0

	UNION

	SELECT
		N''[{CURRENT_DB}]'' [database_name],
		CASE 
			WHEN [o].[type_desc] LIKE N''%FUNCTION'' THEN N''FUNC''
			WHEN [o].[type_desc] = N''DEFAULT_CONSTRAINT'' THEN N''DEFAULT''
			WHEN [o].[type_desc] = N''SQL_STORED_PROCEDURE'' THEN ''SPROC''
			WHEN [o].[type_desc] = N''SQL_TRIGGER'' THEN ''TRIGGER''
			ELSE [o].[type_desc]
		END [type],
		CONCAT(QUOTENAME(SCHEMA_NAME([o].[schema_id])), N''.'', QUOTENAME(OBJECT_NAME([m].[object_id]))) [object],
		CASE 
			WHEN [m].[uses_quoted_identifier] = 0 THEN N''QUOTED_IDENTIFIER = OFF.'' ELSE N'''' 
		END 
		+ 
		CASE 
			WHEN [m].[uses_ansi_nulls] = 0 THEN N'' ANSI_NULLS = OFF.'' ELSE N'''' 
		END [problem]
	FROM
		[sys].[sql_modules] [m]
		INNER JOIN sys.[objects] [o] ON [m].[object_id] = [o].[object_id]
	WHERE
		[m].[uses_ansi_nulls] = 0 OR [m].[uses_quoted_identifier] = 0; '; 
		
	DECLARE @Errors xml;
	DECLARE @errorContext nvarchar(MAX);
	EXEC dbo.[execute_per_database]
		@Databases = @Databases,
		@Statement = @sql,
		@Errors = @Errors OUTPUT; 

	IF @Errors IS NOT NULL BEGIN 
		SET @errorContext = N'Unexpected error while extracting table details (per database): ';
		GOTO ErrorDetails;
	END;

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

		SELECT @serialized_output = (
			SELECT 
				[database_name] [@database_name],
				[type] [@type],
				[object] [@object],
				TRIM([problem]) [*]
			FROM 
				[#problems]
			ORDER BY 
				[database_name]
			FOR XML PATH(N'problem'), ROOT(N'problems'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[database_name],
		[type],
		[object],
		TRIM([problem]) [problem]
	FROM 
		[#problems]
	ORDER BY 
		[database_name];

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
		dbo.[execute_per_database_errors](@Errors)
	ORDER BY 
		[error_id];

	RAISERROR(@errorContext, 16, 1);
	EXEC dbo.[print_long_string] @errorDetails;	
	RETURN -100;
GO