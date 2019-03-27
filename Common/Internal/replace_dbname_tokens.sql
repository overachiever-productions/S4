
/*

	INTERNAL:
		- NOT designed for API/External use - i.e., this is an internal 'helper' function. 
		- Does NOT replace tokens for [USER], [SYSTEM], [ALL]. 
		- Effectively just targets 'custom' dbName Tokens.	
		

	SIGNATURES: 
	
		-----------------------------------------------------------------
				-- expected exception (for now):
			

		-----------------------------------------------------------------
			DECLARE @replaced nvarchar(max);
			EXEC dbo.replace_dbname_tokens 
				@Input = N'[DEV],Billing', 
				--@AllowedTokens = N'[DEV]',
				@Output = @replaced OUTPUT; 

			SELECT @replaced [targets];

		-----------------------------------------------------------------
			DECLARE @replaced nvarchar(max);
			EXEC dbo.replace_dbname_tokens 
				@Input = N'[DEV],Meddling, [PRIORITY], Utilities', 
				--@AllowedTokens = N'[DEV]',
				@Output = @replaced OUTPUT; 

			SELECT @replaced [targets];



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.replace_dbname_tokens','P') IS NOT NULL
	DROP PROC dbo.replace_dbname_tokens;
GO

CREATE PROC dbo.replace_dbname_tokens
	@Input					nvarchar(MAX), 
	@AllowedTokens			nvarchar(MAX)		= NULL,			-- When NON-NULL overrides lookup of all DEFINED token types in dbo.settings (i.e., where the setting_key is like [xxx]). 			
	@Output					nvarchar(MAX)		OUTPUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs: 

	IF NULLIF(@AllowedTokens, N'') IS NULL BEGIN

		SET @AllowedTokens = N'';
		
		WITH aggregated AS (
			SELECT 
				UPPER(setting_key) [token], 
				COUNT(*) [definitions_count]
			FROM 
				dbo.[settings] 
			WHERE 
				[setting_key] LIKE '~[%~]' ESCAPE N'~'
			GROUP BY 
				[setting_key]
		) 

		SELECT @AllowedTokens = @AllowedTokens + [token] + N',' FROM [aggregated] ORDER BY [definitions_count] DESC;

		-- short-circuite: there are no tokens defined in 
		IF @AllowedTokens = N'' BEGIN
			SET @Output = @Input;
			RETURN 0;
		END;

		SET @AllowedTokens = LEFT(@AllowedTokens, LEN(@AllowedTokens) - 1);
	END;
	
	-----------------------------------------------------------------------------
	-- processing: 
	DECLARE @intermediateResults nvarchar(MAX) = @Input;

	DECLARE @tokensToProcess table (
		row_id int IDENTITY(1,1) NOT NULL, 
		token sysname NOT NULL
	); 

	INSERT INTO @tokensToProcess ([token])
	SELECT [result] FROM dbo.[split_string](@AllowedTokens, N',', 1) ORDER BY [row_id];

	DECLARE @currentToken sysname;
	DECLARE @databases xml;
	DECLARE @serialized nvarchar(MAX);

	DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT token FROM @tokensToProcess ORDER BY [row_id];

	OPEN walker; 
	FETCH NEXT FROM walker INTO @currentToken;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @databases = '';
		SET @serialized = N'';

		EXEC dbo.list_databases_matching_token 
			@Token = @currentToken, 
			@SerializedOutput = @databases OUTPUT; 		

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@databases.nodes('//database') [data]([row])
		) 
		
		SELECT 
			@serialized = @serialized + [database_name] + ', '
		FROM 
			[shredded] 
		ORDER BY 
			[row_id];

		SET @serialized = LEFT(@serialized, LEN(@serialized) -1); 

		SET @intermediateResults = REPLACE(@intermediateResults, @currentToken, @serialized);


		FETCH NEXT FROM walker INTO @currentToken;
	END;

	CLOSE walker;
	DEALLOCATE walker;

	SET @Output = @intermediateResults;

	RETURN 0;
GO