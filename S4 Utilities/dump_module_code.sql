/*

	Simple 'helper' to dump/output code matching a specific search string across one or more databases. 

	NOTE: 
		It COULD be possible to create logic that might tweak, say, CREATE PROC[edure] to CREATE OR ALTER or ... simply ALTER, and so on... 
		BUT, the real focus of this sproc is to simply identify/dump code... 
			which, should then be 'manually' reviewed and changed if/as needed. 


	EXAMPLE: 
		EXEC admindb.dbo.dump_module_code @ExcludedDatabases = N'admindb', @TargetPattern = N'%admindb.%'; -- i.e., not just code that 'mentions' admindb, but where admindb is part of a 4-part name, etc. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[dump_module_code]','P') IS NOT NULL
	DROP PROC dbo.[dump_module_code];
GO

CREATE PROC dbo.[dump_module_code]
	@TargetDatabases			nvarchar(MAX) = N'{ALL}', 
	@ExcludedDatabases			nvarchar(MAX) = NULL, 
	@Priorities					nvarchar(MAX) = NULL,
	@TargetPattern				sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}

	CREATE TABLE #matches (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[schema_name] sysname NOT NULL, 
		[module_name] sysname NOT NULL, 
		[module_type] sysname NOT NULL, 
		[module_definition] nvarchar(MAX) NOT NULL 
	);

	DECLARE @sql nvarchar(MAX); 
	DECLARE @currentDB sysname; 

	DECLARE @databaseTargets table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @databaseTargets ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@Priorities = @Priorities,
		@ExcludeClones = 1,
		@ExcludeSecondaries = 1,
		@ExcludeSimpleRecovery = 0,
		@ExcludeReadOnly = 0,
		@ExcludeRestoring = 1,
		@ExcludeRecovering = 1,
		@ExcludeOffline = 1;

	DECLARE [cursorName] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@databaseTargets 
	ORDER BY 
		[entry_id];
	
	OPEN [cursorName];
	FETCH NEXT FROM [cursorName] INTO @currentDB;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @sql = N'SELECT 
		N''{dbName}'' [database_name],
		[s].[name] [schema_name],
		[o].[name] [module_name],
		[o].[type_desc] [module_type],
		[m].[definition] [module_definition]
	FROM 
		[{dbName}].sys.[sql_modules] m 
		INNER JOIN [{dbName}].sys.[objects] o ON [m].[object_id] = [o].[object_id]
		INNER JOIN [{dbName}].sys.[schemas] s ON [o].[schema_id] = [s].[schema_id]
	WHERE 
		[m].[definition] LIKE @TargetPattern; ';

		SET @sql = REPLACE(@sql, N'{dbName}', @currentDB);

		INSERT INTO [#matches] (
			[database_name],
			[schema_name],
			[module_name],
			[module_type],
			[module_definition]
		)
		EXEC sys.sp_executesql
			@sql, 
			N'@TargetPattern sysname', 
			@TargetPattern = @TargetPattern;

		FETCH NEXT FROM [cursorName] INTO @currentDB;
	END;
	
	CLOSE [cursorName];
	DEALLOCATE [cursorName];

	DECLARE @previousDB sysname = N'';
	DECLARE @schemaName sysname, @moduleName sysname, @definition nvarchar(MAX); 
	DECLARE @testDefinition nvarchar(MAX);

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name], 
		[schema_name],
		[module_name], 
		[module_definition]
	FROM 
		[#matches]
	ORDER BY 
		[row_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDB, @schemaName, @moduleName, @definition;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		IF @previousDB <> @currentDB BEGIN 
			PRINT N'--==================================================================================================================================--';
			PRINT N' -- ' + @currentDB
			PRINT N'--==================================================================================================================================--';
			PRINT N'USE [' + @currentDB + N'];'
			PRINT N'GO';
			SET @previousDB = @currentDB;
		END;

		SET @testDefinition = REPLACE(REPLACE(@definition, N'[', N''), N']', '');

		PRINT N'------------------------------+-+-~-+-+------------------------------';  -- goofy little pattern makes searching easier... 
		PRINT N'-- ' + QUOTENAME(@currentDB) + N'.' + QUOTENAME(@schemaName) + N'.' + QUOTENAME(@moduleName); 
		IF @testDefinition NOT LIKE '%' + @moduleName + N'%' BEGIN 
			PRINT N'-- WARNING: Object Definition does NOT contain LITERAL name of ' + @moduleName + N' - i.e., potential rename';
		END;
		PRINT N'---------------------------------------------------------------------';
		PRINT N'GO '; -- prevents the comments above from becoming part of the module definition... 

		EXEC dbo.[print_long_string] @definition;

		PRINT N'GO';
		PRINT N'';
	
		FETCH NEXT FROM [walker] INTO @currentDB, @schemaName, @moduleName, @definition;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	RETURN 0; 
GO


	
