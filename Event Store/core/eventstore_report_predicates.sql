/*

	TODO: ... sadly, add IPs... 



*/
USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_predicates]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_predicates];
GO

CREATE PROC dbo.[eventstore_report_predicates]
	@Databases				nvarchar(MAX) = NULL,
	@Applications			nvarchar(MAX) = NULL,
	@Hosts					nvarchar(MAX) = NULL,
	@Principals				nvarchar(MAX) = NULL,
	@Statements				nvarchar(MAX) = NULL,
	@JoinPredicates			nvarchar(MAX) OUTPUT, 
	@FilterPredicates		nvarchar(MAX) OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @JoinPredicates = N''; 
	SET @FilterPredicates = N'';

	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @outcome int = 0, @rowId int = NULL;

	IF @Databases IS NOT NULL BEGIN 
		DECLARE @databasesValues table (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[databases_value] sysname NOT NULL 
		); 

		INSERT INTO @databasesValues ([databases_value])
		SELECT [result] FROM dbo.[split_string](@Databases, N',', 1);

		INSERT INTO [#expandedDatabases] ([database], [is_exclude])
		SELECT 
			CASE WHEN [databases_value] LIKE N'-%' THEN RIGHT([databases_value], LEN([databases_value]) -1) ELSE [databases_value] END [database],
			CASE WHEN [databases_value] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			@databasesValues 
		WHERE 
			[databases_value] NOT LIKE N'%{%';

		IF EXISTS (SELECT NULL FROM @databasesValues WHERE [databases_value] LIKE N'%{%') BEGIN 
			DECLARE @databasesToken sysname, @dbTokenAbsolute sysname;
			DECLARE @databasesXml xml;

			DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				[row_id], 
				[databases_value]
			FROM 
				@databasesValues 
			WHERE 
				[databases_value] LIKE N'%{%';
			
			OPEN [walker];
			FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			
			WHILE @@FETCH_STATUS = 0 BEGIN
				
				SET @outcome = 0;
				SET @databasesXml = NULL;
				SELECT @dbTokenAbsolute = CASE WHEN @databasesToken LIKE N'-%' THEN RIGHT(@databasesToken, LEN(@databasesToken) -1) ELSE @databasesToken END;

				EXEC @outcome = dbo.[list_databases_matching_token]
					@Token = @dbTokenAbsolute,
					@SerializedOutput = @databasesXml OUTPUT;

				IF @outcome <> 0 
					RETURN @outcome; 

				WITH shredded AS ( 
					SELECT
						[data].[row].value('@id[1]', 'int') [row_id], 
						[data].[row].value('.[1]', 'sysname') [database]
					FROM 
						@databasesXml.nodes('//database') [data]([row])
				) 
				
				INSERT INTO [#expandedDatabases] ([database], [is_exclude])
				SELECT 
					[database], 
					CASE WHEN @databasesToken LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
				FROM 
					shredded
				WHERE 
					[database] NOT IN (SELECT [database] FROM [#expandedDatabases])
				ORDER BY 
					[row_id];
				
				FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			END;
			
			CLOSE [walker];
			DEALLOCATE [walker];
		END;

		IF EXISTS (SELECT NULL FROM [#expandedDatabases] WHERE [is_exclude] = 0) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#expandedDatabases] [d] ON [d].[is_exclude] = 0 AND [x].[database] LIKE [d].[database]';
		END; 

		IF EXISTS (SELECT NULL FROM [#expandedDatabases] WHERE [is_exclude] = 1) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#expandedDatabases] [dx] ON [dx].[is_exclude] = 1 AND [x].[database] LIKE [dx].[database]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [dx].[database] IS NULL';
		END; 
	END;

	IF @Applications IS NOT NULL BEGIN 
		INSERT INTO [#applications] ([application_name], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [application_name], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			[dbo].[split_string](@Applications, N',', 1);

		IF EXISTS (SELECT NULL FROM [#applications] WHERE [is_exclude] = 0) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#applications] [a] ON [a].[is_exclude] = 0 AND [x].[application_name] LIKE [a].[application_name]';
		END; 

		IF EXISTS (SELECT NULL FROM [#applications] WHERE [is_exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#applications] [ax] ON [ax].[is_exclude] = 1 AND [x].[application_name] LIKE [ax].[application_name]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ax].[application_name] IS NULL';
		END;
	END;

	IF @Hosts IS NOT NULL BEGIN 
		INSERT INTO [#hosts] ([host_name], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [host], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM	
			dbo.[split_string](@Hosts, N',', 1);

		IF EXISTS (SELECT NULL FROM [#hosts] WHERE [is_exclude] = 0) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#hosts] [h] ON [h].[is_exclude] = 0 AND [x].[host_name] LIKE [h].[host_name]';
		END;
		
		IF EXISTS (SELECT NULL FROM [#hosts] WHERE [is_exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#hosts] [hx] ON [hx].[is_exclude] = 1 AND [x].[host_name] LIKE [hx].[host_name]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [hx].[host_name] IS NULL';
		END;
	END;

	IF @Principals IS NOT NULL BEGIN
		INSERT INTO [#principals] ([principal], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [principal],
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			[dbo].[split_string](@Principals, N',', 1);

		IF EXISTS (SELECT NULL FROM [#principals] WHERE [is_exclude] = 0) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#principals] [p] ON [p].[is_exclude] = 0 AND [p].[principal] LIKE [x].[user_name]';
		END; 

		IF EXISTS (SELECT NULL FROM [#principals] WHERE [is_exclude] = 1) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#principals] [px] ON [p].[is_exclude] = 1 AND [x].[user_name] LIKE [px].[principal]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [px].[principal] IS NULL';
		END; 
	END;

	IF @Statements IS NOT NULL BEGIN 
		INSERT INTO [#statements] ([statement], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [statement],
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]			
		FROM 
			dbo.[split_string](@Statements, N', ', 1);

		IF EXISTS (SELECT NULL FROM [#statements] WHERE [is_exclude] = 0) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#statements] [s] ON [s].[is_exclude] = 0 AND [x].[statement] LIKE [s].[statement]';
		END;

		IF EXISTS (SELECT NULL FROM [#statements] WHERE [is_exclude] = 1) BEGIN 
			SET @JoinPredicates = @JoinPredicates  + @crlftab + N'LEFT OUTER JOIN [#statements] [sx] ON [sx].[is_exclude] = 1 AND [x].[statement] LIKE [sx].[statement]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [sx].[statement] IS NULL';
		END;
	END;

	RETURN 0;
GO