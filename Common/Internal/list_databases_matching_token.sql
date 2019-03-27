/*
		
		INTERNAL:
			NOT designed for API/External use - i.e., this is an internal 'helper' function. 
				
			


		SIGNATURES:
		
			-----------------------------------------------------------------
				-- expected exception (for now):
				EXEC dbo.list_databases_for_token N'[PRIORITY]';

			-----------------------------------------------------------------
				EXEC dbo.list_databases_for_token N'[DEV]';

			-----------------------------------------------------------------
				-- expected exception IF there are no [TEST] definitions in dbo.settings: 
				EXEC dbo.list_databases_for_token N'[TEST]';

			-----------------------------------------------------------------
				DECLARE @databases xml = N'';
				EXEC dbo.list_databases_for_token 
					@Token = N'[DEV]', 
					@SerializedOutput = @databases OUTPUT; 

				SELECT @databases;

*/


USE	[admindb];
GO

IF OBJECT_ID('dbo.list_databases_matching_token','P') IS NOT NULL
	DROP PROC dbo.list_databases_matching_token;
GO

CREATE PROC dbo.list_databases_matching_token	
	@Token								sysname			= N'[DEV]',					-- { [DEV] | [TEST] }
	@SerializedOutput					xml				= NULL	OUTPUT
AS 

	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	
	-- make sure @Token LIKE '~[%~]' ESCAPE '~'
	IF NOT @Token LIKE N'~[%~]' ESCAPE N'~' BEGIN 
		RAISERROR(N'@Token names must we ''wrapped'' in [square brackets] (and must also be defined in dbo.setttings).', 16, 1);
		RETURN -5;
	END;

	-----------------------------------------------------------------------------
	-- Processing:
	DECLARE @filterDefs table (
		row_id int IDENTITY(1,1) NOT NULL,
		pattern sysname NOT NULL
	); 

	INSERT INTO @filterDefs ([pattern])
	SELECT 
		[setting_value] 
	FROM 
		dbo.[settings]
	WHERE 
		[setting_key] = @Token
	ORDER BY 
		[setting_id];

	IF NOT EXISTS (SELECT NULL FROM @filterDefs) BEGIN 
		DECLARE @errorMessage nvarchar(2000) = N'No filter definitions were defined for token: ' + @Token + '. Please check admindb.dbo.settings for ' + @Token + N' settings_key(s) and/or create as needed.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END;
	
	DECLARE @filterMatches table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	);

	INSERT INTO @filterMatches ([database_name])
	SELECT 
		d.[name] [database_name]
	FROM 
		sys.databases d
		INNER JOIN @filterDefs f ON d.[name] LIKE f.[pattern] 
	ORDER BY 
		f.row_id, d.[name];

	IF @SerializedOutput IS NOT NULL BEGIN 
		SELECT @SerializedOutput = (SELECT 
			[row_id] [database/@id],
			[database_name] [database]
		FROM 
			@filterMatches
		ORDER BY 
			[row_id] 
		FOR XML PATH(''), ROOT('databases'));		

		RETURN 0;
	END;

	SELECT 
		[database_name]
	FROM 
		@filterMatches 
	ORDER BY 
		[row_id];

	RETURN 0;
GO