/*
	INTERNAL
		Explicitly internal sproc - used to wrap/extend T-SQL PARSENAME() function AND allow for dynamic detection
			of the currently executing database. 

	LOGIC
		Currently implemented as 'restricted' to tables-only - no real reason it couldn't be 


	SAMPLE EXECUTION: 



				DECLARE @objectID int; 
				DECLARE @name sysname; 

				EXEC admindb.dbo.load_id_for_normalized_name 
					@TargetName = N'MeMCPUAndSQL', 
					@ParameterNameForTarget = N'@TargetMetricsTable', 
					@NormalizedName = @name OUTPUT, 
					@ObjectID = @objectID OUTPUT; 

				SELECT 
					@name, @objectID;



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.load_id_for_normalized_name','P') IS NOT NULL
	DROP PROC dbo.[load_id_for_normalized_name];
GO

CREATE PROC dbo.[load_id_for_normalized_name]
	@TargetName						sysname, 
	@ParameterNameForTarget			sysname			= N'@Target',
	@NormalizedName					sysname			OUTPUT, 
	@ObjectID						int				OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
	DECLARE @targetObjectId int;
	DECLARE @sql nvarchar(MAX);

	SELECT 
		@targetDatabase = PARSENAME(@TargetName, 3), 
		@targetSchema = ISNULL(PARSENAME(@TargetName, 2), N'dbo'), 
		@targetObjectName = PARSENAME(@TargetName, 1);
	
	IF @targetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		
		IF @targetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. Please use dbname.schemaname.objectname qualified names.', 16, 1, @ParameterNameForTarget);
			RETURN -5;
		END;
	END;

	SET @sql = N'SELECT @targetObjectId = o.[object_id] FROM [' + @targetDatabase + N'].sys.objects o INNER JOIN [' + @targetDatabase + N'].sys.[schemas] s ON [o].[schema_id] = [s].[schema_id] WHERE s.[name] = @targetSchema AND o.[name] = @targetObjectName; '

	EXEC [sys].[sp_executesql]
		@sql, 
		N'@targetSchema sysname, @targetObjectName sysname, @targetObjectId int OUTPUT', 
		@targetSchema = @targetSchema, 
		@targetObjectName = @targetObjectName, 
		@targetObjectId = @targetObjectId OUTPUT;

	IF @targetObjectId IS NULL BEGIN 
		RAISERROR(N'Invalid Table Name specified for %s. Please use dbname.schemaname.objectname qualified names.', 16, 1, @ParameterNameForTarget);
		RETURN -10;
	END;

	SET @ObjectID = @targetObjectId;
	SET @NormalizedName = QUOTENAME(@targetDatabase) + N'.' + QUOTENAME(@targetSchema) + N'.' + QUOTENAME(@targetObjectName);

	RETURN 0;
GO