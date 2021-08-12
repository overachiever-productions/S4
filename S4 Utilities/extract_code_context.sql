/*
	Pulls out relevant lines of code + surrounding lines to provide context - based on LIKE predicates


	vNext: 
		@ExcludedModules ? 
		@ExcludedModuleTypes? 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.extract_code_context','P') IS NOT NULL
	DROP PROC dbo.[extract_code_context];
GO

CREATE PROC dbo.[extract_code_context]
	@TargetDatabase						sysname = NULL,
	@TargetPattern						sysname, 
	@BeforeAndAfterLines				int		= 10
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SET @TargetPattern = NULLIF(@TargetPattern, N'');
	SET @BeforeAndAfterLines = ISNULL(@BeforeAndAfterLines, 10);		

	IF @TargetPattern IS NULL BEGIN 
		RAISERROR(N'Please specify a value for @TargetPattern - e.g., N''%%something%%''.', 16, 1);  
		RETURN -10;
	END; 

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;
		
		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. Please use dbname.schemaname.objectname qualified names.', 16, 1, N'@TargetDatabase');
			RETURN -5;
		END;
	END;		

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	o.[object_id],
	o.[name], 
	CASE o.[type]
		WHEN N''P'' THEN ''Sproc'' 
		WHEN N''V'' THEN ''View''
		ELSE o.[type] 
	END [type]
FROM 
	[{database}].sys.[sql_modules] m 
	INNER JOIN [{database}].sys.[objects] o ON m.[object_id] = o.[object_id]
WHERE 
	m.[definition] LIKE @TargetPattern
ORDER BY 
	o.[type], o.[name];'

	SET @sql = REPLACE(@sql, N'{database}', @TargetDatabase);

	CREATE TABLE #targets (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[object_id] int NOT NULL, 
		[name] sysname NOT NULL, 
		[type] sysname NOT NULL
	);

	INSERT INTO [#targets] (
		[object_id],
		[name],
		[type]
	)
	EXEC sp_executesql 
		@sql, 
		N'@TargetPattern sysname',
		@TargetPattern = @TargetPattern;

	DECLARE @name sysname, @type sysname, @objectId int; 
	DECLARE @definition nvarchar(MAX); 
	DECLARE @output nvarchar(MAX);
	DECLARE @position int;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @lineCount int; 
	DECLARE @startLine int;
	DECLARE @endLine int;

	CREATE TABLE #lines (
		line_id int, 
		line nvarchar(MAX)
	);

	DECLARE @definitionSql nvarchar(MAX) = 'SELECT @def = [definition] FROM [{database}].sys.sql_modules WHERE [object_id] = @objectId; '; 
	SET @definitionSql = REPLACE(@definitionSql, N'{database}', @TargetDatabase);

	DECLARE @template nvarchar(MAX) = N'------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- {type}: {name} 
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

';

	DECLARE [spitter] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[name], 
		[type], 
		[object_id]
	FROM 
		[#targets]
	ORDER BY 
		[row_id];
	
	OPEN [spitter];
	FETCH NEXT FROM [spitter] INTO @name, @type, @objectId;
	
	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @output = REPLACE(@template, N'{name}', @name);
		SET @output = REPLACE(@output, N'{type}', @type);
		
		PRINT @output;

		SET @definition = N'';
		EXEC sp_executesql 
			@definitionSql, 
			N'@def nvarchar(MAX) OUTPUT, @objectId int', 
			@def = @definition OUTPUT, 
			@objectId = @objectId; 

		DELETE FROM [#lines];
		INSERT INTO #lines ([line_id], [line])
		SELECT 
			[row_id], 
			[result]
		FROM 
			dbo.[split_string](@definition, @crlf, 0)
		ORDER BY 
			[row_id];

		INSERT INTO [#lines] (
			[line_id],
			[line]
		)
		VALUES	(
			(SELECT MAX(line_id) + 1 FROM [#lines]),
			N'GO'  /* helpful for visually confirming if/when we're at the 'end' of a sproc/module... */ 
		);

		SELECT @lineCount = COUNT(line_id) FROM [#lines];
		SELECT @position = 0;

		WHILE @position < @lineCount BEGIN 

			SELECT @position = MIN([line_id]) FROM [#lines] WHERE [line] LIKE @TargetPattern;

			IF @position IS NOT NULL BEGIN 
				SET @startLine = @position - @BeforeAndAfterLines; 
				SET @endLine = @position + @BeforeAndAfterLines; 

				IF @startLine < 0 SET @startLine = 0; 
				IF @endLine > @lineCount SET @endLine = @lineCount;

				SET @output = N'';
				SELECT
					@output = @output + @tab + RIGHT(N'  ' + CAST([line_id] AS sysname), 2) + CASE WHEN ([line_id] = @position) OR ([line] LIKE @TargetPattern) THEN N'/*>*/' ELSE @tab END + @tab + @tab + [line] + @crlf
				FROM 
					[#lines] 
				WHERE 
					line_id >= @startLine 
					AND 
					line_id <= @endLine;

				DELETE FROM [#lines] WHERE [line_id] <= @endLine;

				EXEC dbo.[print_long_string] @output;
			  END; 
			ELSE BEGIN 
				SET @position = @lineCount;
			END;
		END;

		PRINT @crlf + @crlf;
	
		FETCH NEXT FROM [spitter] INTO @name, @type, @objectId;
	END;
	
	CLOSE [spitter];
	DEALLOCATE [spitter];
	
	RETURN 0;
GO