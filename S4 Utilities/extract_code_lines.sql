/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.extract_code_lines','P') IS NOT NULL
	DROP PROC dbo.[extract_code_lines];
GO

CREATE PROC dbo.[extract_code_lines]
	@TargetModule					sysname, 
	@TargetLine						int, 
	@BeforeAndAfterLines			int		= 10
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetModule = NULLIF(@TargetModule, N'');
	SET @TargetLine = ISNULL(@TargetLine, -1);
	SET @BeforeAndAfterLines = ISNULL(@BeforeAndAfterLines, 8);	

	IF @TargetModule IS  NULL BEGIN 
		RAISERROR('Please specify the name of the module (sproc, trigger, udf) to extract code from as @TargetModule.', 16, 1);
		RETURN -1;
	END;

	IF @TargetLine < 1 BEGIN 
		RAISERROR('Please specify a value for @TargetLine.', 16, 1);
		RETURN -2;
	END;

	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
	SELECT 
		@targetDatabase = PARSENAME(@TargetModule, 3), 
		@targetSchema = ISNULL(PARSENAME(@TargetModule, 2), N'dbo'), 
		@targetObjectName = PARSENAME(@TargetModule, 1);
	
	IF @targetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		
		IF @targetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. Please use dbname.schemaname.objectname qualified names.', 16, 1, N'@TargetTable');
			RETURN -5;
		END;
	END;

	DECLARE @fullName sysname = QUOTENAME(@targetDatabase) + N'.' + QUOTENAME(@targetSchema) + N'.' + QUOTENAME(@targetObjectName);

	DECLARE @body nvarchar(MAX); 
	DECLARE @sql nvarchar(MAX); 

	SET @sql = N'SELECT @body = [definition] FROM [{database}].sys.[sql_modules] WHERE [object_id] = OBJECT_ID(N''{fqn}''); ';

	SET @sql = REPLACE(@sql, N'{database}', @targetDatabase);
	SET @sql = REPLACE(@sql, N'{fqn}', @fullName);

	EXEC sys.[sp_executesql]
		@sql, 
		N'@body nvarchar(MAX) OUTPUT', 
		@body = @body OUTPUT;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	SELECT 
		[row_id],
		[result]
	INTO 
		#lines
	FROM 
		dbo.[split_string](@body, @crlf, 0)
	ORDER BY 
		row_id;

	DECLARE @lineCount int; 
	SELECT @lineCount = (SELECT COUNT(*) FROM [#lines]);

	DECLARE @startLine int = @TargetLine - @BeforeAndAfterLines;
	DECLARE @endLine int = @TargetLine + @BeforeAndAfterLines;

	IF @startLine < 0 SET @startLine = 0;
	IF @endLine > @lineCount SET @endLine = @lineCount;

	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @output nvarchar(MAX) = N'';
	DECLARE @padding varchar(4) = REPLICATE(N' ', LEN(@TargetLine + @BeforeAndAfterLines));

	SELECT 
		@output = @output + CASE WHEN [row_id] = @TargetLine THEN N'--> ' ELSE @tab END + + RIGHT(@padding + CAST(row_id AS sysname), LEN(@TargetLine + @BeforeAndAfterLines)) + @tab + [result] + @crlf
	FROM 
		[#lines]
	WHERE 
		row_id >= @startLine 
		AND 
		row_id <= @endLine
	ORDER BY 
		row_id;

	EXEC dbo.[print_long_string] @output;

	RETURN 0;
GO