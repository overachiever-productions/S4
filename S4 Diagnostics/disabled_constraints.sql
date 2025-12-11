/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[disabled_constraints]','P') IS NOT NULL
	DROP PROC dbo.[disabled_constraints];
GO

CREATE PROC dbo.[disabled_constraints]
	@databases				nvarchar(MAX)		= N'{USER}', 
	@priorities				nvarchar(MAX)		= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @databases = ISNULL(NULLIF(@databases, N''), N'{USER}');
	SET @priorities = NULLIF(@priorities, N'');

    CREATE TABLE #disabledOrUntrustedConstraints (
        [row_id] int IDENTITY(1,1) NOT NULL,
        [database_name] sysname NOT NULL,
		[table_name] sysname NOT NULL,
        [constraint_type] sysname NOT NULL, 
        [constraint_name] sysname NOT NULL
    );

	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}];
WITH constraints AS ( 
    SELECT
        QUOTENAME(SCHEMA_NAME([t].[schema_id])) + N''.'' + QUOTENAME([t].[name]) [table],
        [c].[type_desc] [constraint_type],
        [c].[name] [constraint_name]
    FROM
        [sys].[tables] AS [t]
        INNER JOIN [sys].[check_constraints] AS [c] ON [t].[object_id] = [c].[parent_object_id]
    WHERE
        [c].[is_disabled] = 1

    UNION 

    SELECT 
        QUOTENAME(SCHEMA_NAME([schema_id])) + N''.'' + QUOTENAME(OBJECT_NAME([parent_object_id])) [table],
        CASE WHEN [is_disabled] = 1 THEN N''FOREIGN_KEY (DISABLED)'' ELSE N''FOREIGN_KEY (UNTRUSTED)'' END [constraint_type],
        [name] [constraint_name]
    FROM 
        [sys].[foreign_keys] 
    WHERE 
        [is_disabled] = 1 OR [is_not_trusted] = 1
)

INSERT INTO [#disabledOrUntrustedConstraints] ([database_name], [table_name], [constraint_type], [constraint_name])
SELECT 
    N''[{CURRENT_DB}]'' [database_name],
    [table],
    [constraint_type],
    [constraint_name] 
FROM 
    [constraints]
ORDER BY 
    [constraint_type], [table]; ';

    DECLARE @errors xml;
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Priorities = @priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT; 

	IF @errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected error. See [Errors] XML for more details.', 16, 1);
		SELECT @errors;
		RETURN -100;
	END;

    SELECT 
		[database_name],
		[table_name],
		[constraint_type],
		[constraint_name] 
    FROM 
        [#disabledOrUntrustedConstraints]
    ORDER BY 
        [row_id];

    RETURN 0;
GO  
