/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.

		
	SIGNATURES:
		
		-----------------------------------------------------------------
			-- expected exception (unless {PRIORITY7} is a defined token in dbo.[settings]):
			        EXEC dbo.list_databases_matching_token N'{PRIORITY7}';

		-----------------------------------------------------------------
            -- expect PROJECTion of all dbs:
			        EXEC dbo.list_databases_matching_token N'[ALL]';

		-----------------------------------------------------------------
            -- ditto, but just SYSTEM dbs... 
			        EXEC dbo.list_databases_matching_token N'[SYSTEM]';

		-----------------------------------------------------------------
            -- ditto, but ONLY if DEV has been defined in dbo.settings. 
			        EXEC dbo.list_databases_matching_token N'[DEV]';

		-----------------------------------------------------------------
			-- expected exception IF there are no [TEST] definitions in dbo.settings: 

			        EXEC dbo.list_databases_matching_token N'[TEST]';

		-----------------------------------------------------------------
            -- expect REPLY as serialized xml via @databases.
			    DECLARE @databases xml;
			    EXEC dbo.list_databases_matching_token 
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
	@Token								sysname			= N'{DEV}',					-- { [DEV] | [TEST] }
	@SerializedOutput					xml				= N'<default/>'	    OUTPUT
AS 

	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	
	IF NOT @Token LIKE N'{%}' BEGIN 
		RAISERROR(N'@Token names must be ''wrapped'' in {curly brackets] (and must also be defined in dbo.setttings).', 16, 1);
		RETURN -5;
	END;

	-----------------------------------------------------------------------------
	-- Processing:
	DECLARE @tokenMatches table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	);

	IF UPPER(@Token) IN (N'{ALL}', N'{SYSTEM}', N'{USER}') BEGIN
		-- define system databases - we'll potentially need this in a number of different cases...
		DECLARE @system_databases TABLE ( 
			[entry_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		); 	
	
		INSERT INTO @system_databases ([database_name])
		SELECT N'master' UNION SELECT N'msdb' UNION SELECT N'model';		

		-- Treat admindb as [SYSTEM] if defined as system... : 
		IF (SELECT dbo.is_system_database('admindb')) = 1 BEGIN
			INSERT INTO @system_databases ([database_name])
			VALUES ('admindb');
		END;

		-- same with distribution database - but only if present:
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'distribution') BEGIN
			IF (SELECT dbo.is_system_database('distribution')) = 1  BEGIN
				INSERT INTO @system_databases ([database_name])
				VALUES ('distribution');
			END;
		END;

		IF UPPER(@Token) IN (N'{ALL}', N'{SYSTEM}') BEGIN 
			INSERT INTO @tokenMatches ([database_name])
			SELECT [database_name] FROM @system_databases; 
		END; 

		IF UPPER(@Token) IN (N'{ALL}', N'{USER}') BEGIN 
			INSERT INTO @tokenMatches ([database_name])
			SELECT [name] FROM sys.databases
			WHERE [name] NOT IN (SELECT [database_name] COLLATE SQL_Latin1_General_CP1_CI_AS  FROM @system_databases)
				AND LOWER([name]) <> N'tempdb'
			ORDER BY [name];
		 END; 

	  END; 
	ELSE BEGIN
		
		-- 'custom token'... 
		DECLARE @tokenDefs table (
			row_id int IDENTITY(1,1) NOT NULL,
			pattern sysname NOT NULL
		); 

		INSERT INTO @tokenDefs ([pattern])
		SELECT 
			[setting_value] 
		FROM 
			dbo.[settings]
		WHERE 
			[setting_key] = @Token
		ORDER BY 
			[setting_id];

		IF NOT EXISTS (SELECT NULL FROM @tokenDefs) BEGIN 
			DECLARE @errorMessage nvarchar(2000) = N'No filter definitions were defined for token: ' + @Token + '. Please check dbo.settings for ' + @Token + N' settings_key(s) and/or create as needed.';
			RAISERROR(@errorMessage, 16, 1);
			RETURN -1;
		END;
	
		INSERT INTO @tokenMatches ([database_name])
		SELECT 
			d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS [database_name]
		FROM 
			sys.databases d
			INNER JOIN @tokenDefs f ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE f.[pattern] 
		ORDER BY 
			f.row_id, d.[name];
	END;

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY... 

		SELECT @SerializedOutput = (SELECT 
			[row_id] [database/@id],
			[database_name] [database]
		FROM 
			@tokenMatches
		ORDER BY 
			[row_id] 
		FOR XML PATH(''), ROOT('databases'));		

		RETURN 0;
	END;

    -- otherwise (if we're still here) ... PROJECT:
	SELECT 
		[database_name]
	FROM 
		@tokenMatches 
	ORDER BY 
		[row_id];

	RETURN 0;
GO