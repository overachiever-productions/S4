/*

	EXAMPLES: 

				Super Simple
					EXEC dbo.[execute_per_database]
						@Databases = N'admin%, PSP%', 
						@Priorities = N'admin%, *, PSP%',
						@Statement = N'SELECT ''{CURRENT_DB}'' [db_name];'



				Semi-Complex - i.e., with state/output into a #tempTable: 

							DROP TABLE IF EXISTS #freeSpace;
							CREATE TABLE #freeSpace (
								[row_id] int IDENTITY(1,1) NOT NULL,
								[database_name] sysname NOT NULL, 
								[file_name] sysname NOT NULL, 
								[type] tinyint NOT NULL,
								[file_size_mb] decimal(24,2) NULL, 
								[free_space_mb] decimal(24,2) NULL 
							); 

							DECLARE @myStatement nvarchar(MAX) = N'USE [{CURRENT_DB}];

							INSERT INTO [#freeSpace] ([database_name], [file_name], [type], [file_size_mb], [free_space_mb])
							SELECT
								N''{CURRENT_DB}'' [database_name], 
								[name] AS [file_name],
								[type],
								CAST(([size] / 128.0) AS decimal(22,2)) AS [file_size_mb],
								CAST(([size] / 128.0 - CAST(FILEPROPERTY([name], ''SpaceUsed'') AS int) / 128.0) AS decimal(22,2)) AS [free_space_mb]
							FROM
								[sys].[database_files]; ';


							DECLARE @errors xml;
							EXEC dbo.[execute_per_database]
								@Databases = N'{SYSTEM}',
								@Statement = @myStatement,
								@Errors = @errors OUTPUT;

							SELECT 
								* 
							FROM 
								[#freeSpace]
							ORDER BY 
								[row_id];
			



				Similar example, but showing how to evaluate @errors / etc. - i.e., the INSERT statment is missing a column ([type]:

							DROP TABLE IF EXISTS #freeSpace;
							CREATE TABLE #freeSpace (
								[row_id] int IDENTITY(1,1) NOT NULL,
								[database_name] sysname NOT NULL, 
								[file_name] sysname NOT NULL, 
								[type] tinyint NOT NULL,
								[file_size_mb] decimal(24,2) NULL, 
								[free_space_mb] decimal(24,2) NULL 
							); 

							DECLARE @myStatement nvarchar(MAX) = N'USE [{CURRENT_DB}];

							INSERT INTO [#freeSpace] ([database_name], [file_name], [file_size_mb], [free_space_mb])
							SELECT
								N''{CURRENT_DB}'' [database_name], 
								[name] AS [file_name],
								[type],
								CAST(([size] / 128.0) AS decimal(22,2)) AS [file_size_mb],
								CAST(([size] / 128.0 - CAST(FILEPROPERTY([name], ''SpaceUsed'') AS int) / 128.0) AS decimal(22,2)) AS [free_space_mb]
							FROM
								[sys].[database_files]; ';


							DECLARE @errors xml;
							EXEC dbo.[execute_per_database]
								@Databases = N'{SYSTEM}',
								--@Priorities = ?,
								@Statement = @myStatement,
								@Errors = @errors OUTPUT;

							IF @errors IS NOT NULL BEGIN 
								SELECT @errors;
							END;

							SELECT 
								* 
							FROM 
								[#freeSpace]
							ORDER BY 
								[row_id];

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[execute_per_database]','P') IS NOT NULL
	DROP PROC dbo.[execute_per_database];
GO

CREATE PROC dbo.[execute_per_database]
	@Databases							nvarchar(MAX), 
	@Priorities							nvarchar(MAX)		= NULL, 
	@Statement							nvarchar(MAX),										-- Specialized token {CURRENT_DB} allowed here - and replaced with DB_NAME() for currently executing db. 
	@Errors								xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Databases = NULLIF(@Databases, N'');
	SET @Priorities = NULLIF(@Priorities, N'');
	SET @Statement = NULLIF(@Statement, N'');

	IF @Databases IS NULL BEGIN 
		RAISERROR(N'Parameter @Databases may not be null or empty.', 16, 1);
		RETURN -1;
	END; 

	IF @Statement IS NULL BEGIN 
		RAISERROR(N'Parameter @Statement may not be null of empty.', 16, 1);
		RETURN - 2;
	END;

	DECLARE @targetDatabases table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL 
	);

	DECLARE @errorDetails table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL, 
		[dynamic_sql] nvarchar(MAX) NULL 
	);

	DECLARE @xmlOutput xml;
	EXEC dbo.[targeted_databases]
		@Databases = @Databases,
		@Priorities = @Priorities,
		@ExcludeClones = 1,
		@ExcludeSecondaries = 1,
		@ExcludeSimpleRecovery = 0,
		@ExcludeReadOnly = 1,
		@ExcludeRestoring = 1,
		@ExcludeRecovering = 1,
		@ExcludeOffline = 1,
		@SerializedOutput = @xmlOutput OUTPUT;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value('@id[1]', 'int') [row_id], 
			[data].[row].value('.[1]', 'sysname') [database_name]
		FROM 
			@xmlOutput.nodes('//database') [data]([row])
	)
	 
	INSERT INTO @targetDatabases ([database_name])
	SELECT [database_name] FROM [shredded] ORDER BY [row_id];

	DECLARE @errorMessage nvarchar(MAX), @errorLine int;
	DECLARE @isolatedCodeLine nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @currentDatabase sysname; 
	DECLARE @sql nvarchar(MAX);
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@targetDatabases 
	ORDER BY 
		[row_id];	
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDatabase;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @sql = @Statement;
		SET @sql = REPLACE(@sql, N'{CURRENT_DB}', @currentDatabase);

		BEGIN TRY 
			EXEC sys.[sp_executesql]
				@sql;

		END TRY 
		BEGIN CATCH 
			SELECT 
				@errorLine = ERROR_LINE(), 
				@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
			-- !!!! DANGER: always assess the impact of this (if in a loop - problems):
			-- TODO: https://overachieverllc.atlassian.net/browse/BDG-17
			IF @@TRANCOUNT > 0 
				ROLLBACK;
			
			SET @isolatedCodeLine = NULL;
			EXEC dbo.[extract_dynamic_code_lines]
				@DynamicCode = @sql,
				@TargetLine = @errorLine,
				@StringOutput = @isolatedCodeLine OUTPUT;
			
			INSERT INTO @errorDetails ([database_name], [error_message], [dynamic_sql])
			VALUES (@currentDatabase, @errorMessage, @isolatedCodeLine)
		END CATCH;
	
		FETCH NEXT FROM [walker] INTO @currentDatabase;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	IF (SELECT dbo.is_xml_empty(@Errors)) = 1 BEGIN
		SELECT @Errors = (
			SELECT 
				[row_id] [@id],
				[database_name],
				[error_message],
				[dynamic_sql] [statement]
			FROM 
				@errorDetails
			FOR XML PATH(N'error'), ROOT(N'errors'), TYPE);
		
		RETURN -99;
	END;

	IF EXISTS (SELECT NULL FROM @errorDetails) BEGIN 
		SELECT 
			[row_id] [error_id],
			[database_name],
			[error_message],
			[dynamic_sql] [statement]
		FROM 
			@errorDetails
		ORDER BY 
			[row_id];

		RETURN -98;
	END;

	RETURN 0;
GO