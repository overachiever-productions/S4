/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.count_rows','P') IS NOT NULL
	DROP PROC dbo.[count_rows];
GO

CREATE PROC dbo.[count_rows]
	@Target					sysname				= NULL, 
	@Output					int					= -1			OUTPUT
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

	DECLARE @count int; 
	DECLARE @sql nvarchar(MAX) = N'SELECT
		@count	= SUM([p].[rows])
	FROM
		' + QUOTENAME(@targetDatabase) + N'.[sys].[partitions] AS [p]
		INNER JOIN ' + QUOTENAME(@targetDatabase) + N'.[sys].[tables] AS [t] ON [p].[object_id] = [t].[object_id]
		INNER JOIN ' + QUOTENAME(@targetDatabase) + N'.[sys].[schemas] AS [s] ON [t].[schema_id] = [s].[schema_id]
	WHERE
		[p].[index_id] IN (0, 1) -- heap or clustered index
		AND [t].[name] = @targetTable AND [s].[name] = @targetSchema ; ';
		
	EXEC sp_executesql 
		@sql, 
		N'@targetTable sysname, @targetSchema sysname, @count int OUTPUT', 
		@targetTable = @targetTable, 
		@targetSchema = @targetSchema, 
		@count = @count OUTPUT;

	
	IF @Output = -1 BEGIN
		SELECT @count [row_count];
		RETURN 0;
	END;

	SET @Output = @count;

	RETURN 0;
GO