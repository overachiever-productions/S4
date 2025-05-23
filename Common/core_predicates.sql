/*

	NOTE: 
		@Applications - @Statements code is generated via template: 
			https://www.notion.so/overachiever/Conventions-1bd5380af00e80d09c86eab014295239?pvs=4#1bd5380af00e8062a9c8f17df9c74c69
		(@Databases is ... a bit different because of the option to use {TOKENS})


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[core_predicates]','P') IS NOT NULL
	DROP PROC dbo.[core_predicates];
GO

CREATE PROC dbo.[core_predicates]
	@Databases				nvarchar(MAX) = NULL,
	@Applications			nvarchar(MAX) = NULL,
	@Hosts					nvarchar(MAX) = NULL,
	@IPs					nvarchar(MAX) = NULL,
	@Principals				nvarchar(MAX) = NULL,
	@Statements				nvarchar(MAX) = NULL,
	@JoinPredicates			nvarchar(MAX) OUTPUT, 
	@FilterPredicates		nvarchar(MAX) OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @IPs = NULLIF(@IPs, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Statements = NULLIF(@Statements, N'');

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

		INSERT INTO [#ts_cp_databases] ([database], [exclude])
		SELECT 
			CASE WHEN [databases_value] LIKE N'-%' THEN RIGHT([databases_value], LEN([databases_value]) -1) ELSE [databases_value] END [database],
			CASE WHEN [databases_value] LIKE N'-%' THEN 1 ELSE 0 END [exclude]
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
				
				INSERT INTO [#ts_cp_databases] ([database], [exclude])
				SELECT 
					[database], 
					CASE WHEN @databasesToken LIKE N'-%' THEN 1 ELSE 0 END [exclude]
				FROM 
					shredded
				WHERE 
					[database] NOT IN (SELECT [database] FROM [#ts_cp_databases])
				ORDER BY 
					[row_id];
				
				FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			END;
			
			CLOSE [walker];
			DEALLOCATE [walker];
		END;

		IF EXISTS (SELECT NULL FROM [#ts_cp_databases] WHERE [exclude] = 0) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#ts_cp_databases] [ts_d] ON [ts_d].[exclude] = 0 AND [x].[database] LIKE [ts_d].[database]';
		END; 

		IF EXISTS (SELECT NULL FROM [#ts_cp_databases] WHERE [exclude] = 1) BEGIN 
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#ts_cp_databases] [ts_dx] ON [ts_dx].[exclude] = 1 AND [x].[database] LIKE [ts_dx].[database]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ts_dx].[database] IS NULL';
		END; 
	END;

	IF @Applications IS NOT NULL BEGIN
		INSERT INTO [#ts_cp_applications]([application], [exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [application], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		FROM 
			[dbo].[split_string](@Applications, N',', 1);
		
		
		IF EXISTS (SELECT NULL FROM [#ts_cp_applications] WHERE [exclude] = 0) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#ts_cp_applications] [ts_a] ON [ts_a].[exclude] = 0 AND [x].[application] LIKE [ts_a].[application]';
		END;
	
		IF EXISTS (SELECT NULL FROM [#ts_cp_applications] WHERE [exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#ts_cp_applications] [ts_ax] ON [ts_ax].[exclude] = 1 AND [x].[application] LIKE [ts_ax].[application]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ts_ax].[application] IS NULL';	
		END;
	END;

	IF @Hosts IS NOT NULL BEGIN
		INSERT INTO [#ts_cp_hosts]([host], [exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [host], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		FROM 
			[dbo].[split_string](@Hosts, N',', 1);
		
		
		IF EXISTS (SELECT NULL FROM [#ts_cp_hosts] WHERE [exclude] = 0) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#ts_cp_hosts] [ts_h] ON [ts_h].[exclude] = 0 AND [x].[host] LIKE [ts_h].[host]';
		END;
	
		IF EXISTS (SELECT NULL FROM [#ts_cp_hosts] WHERE [exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#ts_cp_hosts] [ts_hx] ON [ts_hx].[exclude] = 1 AND [x].[host] LIKE [ts_hx].[host]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ts_hx].[host] IS NULL';	
		END;
	END;

	IF @IPs IS NOT NULL BEGIN
		INSERT INTO [#ts_cp_ips]([ip], [exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [ip], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		FROM 
			[dbo].[split_string](@IPs, N',', 1);
		
		
		IF EXISTS (SELECT NULL FROM [#ts_cp_ips] WHERE [exclude] = 0) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#ts_cp_ips] [ts_i] ON [ts_i].[exclude] = 0 AND [x].[ip] LIKE [ts_i].[ip]';
		END;
	
		IF EXISTS (SELECT NULL FROM [#ts_cp_ips] WHERE [exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#ts_cp_ips] [ts_ix] ON [ts_ix].[exclude] = 1 AND [x].[ip] LIKE [ts_ix].[ip]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ts_ix].[ip] IS NULL';	
		END;
	END;

	IF @Principals IS NOT NULL BEGIN
		INSERT INTO [#ts_cp_principals]([principal], [exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [principal], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		FROM 
			[dbo].[split_string](@Principals, N',', 1);
		
		
		IF EXISTS (SELECT NULL FROM [#ts_cp_principals] WHERE [exclude] = 0) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#ts_cp_principals] [ts_p] ON [ts_p].[exclude] = 0 AND [x].[principal] LIKE [ts_p].[principal]';
		END;
	
		IF EXISTS (SELECT NULL FROM [#ts_cp_principals] WHERE [exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#ts_cp_principals] [ts_px] ON [ts_px].[exclude] = 1 AND [x].[principal] LIKE [ts_px].[principal]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ts_px].[principal] IS NULL';	
		END;
	END;

	IF @Statements IS NOT NULL BEGIN
		INSERT INTO [#ts_cp_statements]([statement], [exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [statement], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		FROM 
			[dbo].[split_string](@Statements, N',', 1);
		
		
		IF EXISTS (SELECT NULL FROM [#ts_cp_statements] WHERE [exclude] = 0) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'INNER JOIN [#ts_cp_statements] [ts_s] ON [ts_s].[exclude] = 0 AND [x].[statement] LIKE [ts_s].[statement]';
		END;
	
		IF EXISTS (SELECT NULL FROM [#ts_cp_statements] WHERE [exclude] = 1) BEGIN
			SET @JoinPredicates = @JoinPredicates + @crlftab + N'LEFT OUTER JOIN [#ts_cp_statements] [ts_sx] ON [ts_sx].[exclude] = 1 AND [x].[statement] LIKE [ts_sx].[statement]';
			SET @FilterPredicates = @FilterPredicates + @crlftab + N'AND [ts_sx].[statement] IS NULL';	
		END;
	END;

	SET @JoinPredicates = ISNULL(@JoinPredicates, N'');
	SET @FilterPredicates = ISNULL(@FilterPredicates, N'');

	RETURN 0;
GO