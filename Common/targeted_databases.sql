/*
		
		admindb successor to S4's dbo.list_databases. 
			a. @Databases
			b. refactored name. (i.e., doesn't need/use a verb)
			c. @SerializedOutput (xml) to help avoid nested insert / insert-exec



		SIGNATURES: 
						DECLARE @SerializedOutput xml;
						EXEC [admindb]..[targeted_databases] 
							@Databases = N'{ALL}, -admindb_%, -af%',
							@Priorities = N'IdentityDb, NoMerge, PointInTime, *, SSVDev, Sniffles', 
							@SerializedOutput = @SerializedOutput OUTPUT; 

						SELECT @SerializedOutput;


						-- man... this is DREAMY:
						EXEC [admindb]..[targeted_databases] 
							@Databases = N'admin%, PSP%', 
							@Priorities = N'admin%, *, PSP%'

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[targeted_databases]','P') IS NOT NULL
	DROP PROC dbo.[targeted_databases];
GO

CREATE PROC dbo.[targeted_databases]
	@Databases								nvarchar(MAX)	= N'{ALL}',
	@Priorities								nvarchar(MAX)	= NULL, 
	@ExcludeClones							bit				= 1, 
	@ExcludeSecondaries						bit				= 1,			-- exclude AG and Mirroring secondaries... 
	@ExcludeSimpleRecovery					bit				= 0,			-- exclude databases in SIMPLE recovery mode
	@ExcludeReadOnly						bit				= 0,			
	@ExcludeRestoring						bit				= 1,			-- explicitly removes databases in RESTORING and 'STANDBY' modes... 
	@ExcludeRecovering						bit				= 1,			-- explicitly removes databases in RECOVERY, RECOVERY_PENDING, and SUSPECT modes.
	@ExcludeOffline							bit				= 1,			-- removes ANY state other than ONLINE.
	@SerializedOutput						xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Databases = ISNULL(NULLIF(@Databases, N''), N'{ALL}');
	SET @Priorities = NULLIF(@Priorities, N'');	
	SET @ExcludeClones = ISNULL(@ExcludeClones, 1);
	SET @ExcludeSecondaries = ISNULL(@ExcludeSecondaries, 1);
	SET @ExcludeSimpleRecovery = ISNULL(@ExcludeSimpleRecovery, 0);
	
	-- TODO: remove identifiers (i.e., strip [] and ") from @Databases and from @Priorities.

	IF (SELECT dbo.[count_matches](@Databases, N'{READ_FROM_FILESYSTEM}')) > 0 BEGIN 
		RAISERROR(N'@Databases may NOT be set to (or contain) {READ_FROM_FILESYSTEM}. The {READ_FROM_FILESYSTEM} token is ONLY allowed as an option/token for @TargetDatabases in dbo.restore_databases and dbo.apply_logs.', 16, 1);
		RETURN -3;
	END;

	DECLARE @exclusions nvarchar(MAX) = N'';
	SELECT 
		@exclusions = @exclusions + LTRIM(SUBSTRING([result], CHARINDEX(N'-', [result]) + 1, LEN([result]))) + N','
	FROM 
		dbo.[split_string](@Databases, N',', 1)
	WHERE 
		[result] LIKE N'-%'
	ORDER BY 
		[row_id];

	IF @exclusions <> N''
		SET @exclusions = LEFT(@exclusions, LEN(@exclusions) - 1);

	IF (SELECT dbo.[count_matches](@exclusions, N'{READ_FROM_FILESYSTEM}')) > 0 BEGIN 
		RAISERROR(N'The Token {READ_FROM_FILESYSTEM} is NOT a valid exclusion token.', 16, 1);
		RETURN -2;
	END;

	IF (SELECT dbo.[count_matches](@exclusions, N'{ALL}')) > 0 BEGIN 
		RAISERROR(N'The Token {ALL} is NOT a valid exclusion', 16, 1);
		RETURN -7;
	END;

	DECLARE @targets nvarchar(MAX) = N'';
	SELECT 
		@targets = @targets + [result] + N','
	FROM 
		[dbo].[split_string](@Databases, N',', 1)
	WHERE 
		[result] NOT LIKE N'-%'
	ORDER BY 
		[row_id];

	IF @targets <> N''
		SET @targets = LEFT(@targets, LEN(@targets) - 1);

	IF NULLIF(@targets, N'') IS NULL BEGIN
		RAISERROR('@Databases can NOT specify ONLY exclusions.', 16, 1);
		RETURN -1;
	END

	DECLARE @system_databases TABLE ( 
		[entry_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 	

	DECLARE @xmlOutput xml = '';
	EXEC dbo.[list_databases_matching_token]
	    @Token = N'{SYSTEM}',
	    @SerializedOutput = @xmlOutput OUTPUT;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value('@id[1]', 'int') [row_id], 
			[data].[row].value('.[1]', 'sysname') [database_name]
		FROM 
			@xmlOutput.nodes('//database') [data]([row])
	)
	 
	INSERT INTO @system_databases ([database_name])
	SELECT [database_name] FROM [shredded] ORDER BY [row_id];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Hydrate Targets and Explicit Exclusions: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @targetDatabases table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL 
	);

	DECLARE @excludedDatabases table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL 
	);
	
	INSERT INTO @targetDatabases ([database_name])
	SELECT 
		[result] [database_name]
	FROM 
		dbo.[split_string](@targets, N',', 1);

	INSERT INTO @excludedDatabases ([database_name])
	SELECT 
		[result] [database_name]
	FROM 
		dbo.[split_string](@exclusions, N',', 1);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Token Processing / Replacement:
	-		AND. Start with an 'odd' business rule/implementation detail which is that IF there are any wildcards (e.g., @Databases = N'PSPData%') 
	-			BUT there aren't any TOKENs (e.g., {ALL} or {USER}, etc) then ... the ONLY way for a wildcard to be matched is IF {ALL} is also
	-			part of the @Databases input. i.e., counter-intuitive for end-users (hell even for me) ... but an ... implementation detail.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @Databases LIKE N'%`%%' ESCAPE N'`' AND @Databases NOT LIKE N'%{%' BEGIN 
		INSERT INTO @targetDatabases ([database_name]) VALUES (N'{ALL}');
	END;

	DECLARE @currentToken sysname;
	WHILE EXISTS (SELECT NULL FROM @targetDatabases WHERE [database_name] LIKE N'%{%}%') BEGIN
		SET @currentToken = (SELECT TOP (1) [database_name] FROM @targetDatabases WHERE [database_name] LIKE N'%{%}%');
		
		SET @xmlOutput = '';
		EXEC dbo.[list_databases_matching_token]
			@Token = @currentToken,
			@SerializedOutput = @xmlOutput OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@xmlOutput.nodes('//database') [data]([row])
		)

		INSERT INTO @targetDatabases ([database_name])
		SELECT [database_name] FROM [shredded] ORDER BY [shredded].[row_id];

		DELETE FROM @targetDatabases WHERE [database_name] = @currentToken;
	END;

	WHILE EXISTS (SELECT NULL FROM @excludedDatabases WHERE [database_name] LIKE N'%{%}%') BEGIN
		SET @currentToken = (SELECT TOP (1) [database_name] FROM @excludedDatabases WHERE [database_name] LIKE N'%{%}%');
		
		SET @xmlOutput = '';
		EXEC dbo.[list_databases_matching_token]
			@Token = @currentToken,
			@SerializedOutput = @xmlOutput OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@xmlOutput.nodes('//database') [data]([row])
		)

		INSERT INTO @excludedDatabases ([database_name])
		SELECT [database_name] FROM [shredded] ORDER BY [shredded].[row_id];

		DELETE FROM @excludedDatabases WHERE [database_name] = @currentToken;		
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Filters (not QUITE the same thing as exclusions):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF EXISTS (SELECT NULL FROM @targetDatabases WHERE [database_name] LIKE N'%`%%' ESCAPE N'`') BEGIN
		DECLARE @filteredDatabases table (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL 
		);

		INSERT INTO @filteredDatabases ([database_name])
		SELECT 
			[database_name]
		FROM 
			@targetDatabases 
		WHERE 
			[database_name] LIKE N'%`%%' ESCAPE N'`'; 

		DECLARE @currentFilter sysname;
		WHILE EXISTS (SELECT NULL FROM @filteredDatabases WHERE [database_name] LIKE N'%`%%' ESCAPE N'`') BEGIN
			SET @currentFilter = (SELECT TOP (1) [database_name] FROM @filteredDatabases WHERE [database_name] LIKE N'%`%%' ESCAPE N'`');

			INSERT INTO @filteredDatabases ([database_name])
			SELECT 
				[database_name]
			FROM 
				@targetDatabases 
			WHERE 
				[database_name] LIKE @currentFilter;

			DELETE FROM @filteredDatabases WHERE [database_name] = @currentFilter;
		END;

		DELETE FROM @targetDatabases;
		INSERT INTO @targetDatabases ([database_name])
		SELECT [database_name] FROM @filteredDatabases;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process ALL Exclusions (i.e., -YY and any @ExcludeXXX options):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DELETE [t] 
	FROM 
		@targetDatabases [t]
		LEFT OUTER JOIN @excludedDatabases [e] ON [t].[database_name] LIKE [e].[database_name]
	WHERE 
		[e].[database_name] IS NOT NULL;

	IF @ExcludeClones = 1 BEGIN
		DELETE FROM @targetDatabases
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE source_database_id IS NOT NULL);
	END;

	IF @ExcludeSecondaries = 1 BEGIN
		DECLARE @synchronized table ( 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @synchronized ([database_name])
		SELECT d.[name] 
		FROM sys.[databases] d 
		INNER JOIN sys.[database_mirroring] dm ON d.[database_id] = dm.[database_id] AND dm.[mirroring_guid] IS NOT NULL
		WHERE UPPER(dm.[mirroring_role_desc]) <> N'PRINCIPAL';

		IF (SELECT dbo.get_engine_version()) >= 11.0 BEGIN		
			CREATE TABLE #hadr_names ([name] sysname NOT NULL);
			EXEC sp_executesql N'INSERT INTO #hadr_names ([name]) SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc <> ''PRIMARY'';'	

			INSERT INTO @synchronized ([database_name])
			SELECT [name] FROM #hadr_names;
		END

		-- Exclude any databases that aren't operational: (NOTE, this excluding all dbs that are non-operational INCLUDING those that might be 'out' because of Mirroring, but it is NOT SOLELY trying to remove JUST mirrored/AG'd databases)
		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [database_name] FROM @synchronized);
	END;
	
	IF @ExcludeSimpleRecovery = 1 BEGIN
		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([recovery_model_desc]) = N'SIMPLE');
	END;

	IF @ExcludeReadOnly = 1 BEGIN
		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE [is_read_only] = 1)
	END;

	IF @ExcludeRestoring = 1 BEGIN
		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([state_desc]) = N'RESTORING');		

		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE [is_in_standby] = 1);
	END;

	IF @ExcludeRecovering = 1 BEGIN
		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([state_desc]) IN (N'RECOVERY', N'RECOVERY_PENDING', N'SUSPECT'));
	END;

	IF @ExcludeOffline = 1 BEGIN
		DELETE FROM @targetDatabases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([state_desc]) = N'OFFLINE');
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Prioritize: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @Priorities IS NOT NULL BEGIN 

		DECLARE @prioritized table (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL 
		);

		INSERT INTO @prioritized ([database_name])
		SELECT [result] FROM dbo.[split_string](@Priorities, N',', 1) ORDER BY [row_id];

		DECLARE @alphabetized int;
		SELECT @alphabetized = [row_id] FROM @prioritized WHERE [database_name] = '*';

		IF @alphabetized IS NULL
			SET @alphabetized = (SELECT MAX([row_id]) + 1 FROM @targetDatabases);

		DECLARE @prioritized_targets TABLE ( 
			[entry_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		); 

		WITH core AS ( 
			SELECT 
				[t].[database_name], 
				CASE 
					WHEN [p].[database_name] IS NULL THEN 0 + [t].[row_id]
					WHEN [p].[database_name] IS NOT NULL AND [p].[row_id] <= @alphabetized THEN -32767 + [p].[row_id]
					WHEN [p].[database_name] IS NOT NULL AND [p].[row_id] > @alphabetized THEN 32767 + [p].[row_id]
				END [prioritized_priority]
			FROM 
				@targetDatabases [t] 
				LEFT OUTER JOIN @prioritized [p] ON [t].[database_name] LIKE p.[database_name]
		) 

		INSERT INTO @prioritized_targets ([database_name])
		SELECT 
			[database_name]
		FROM core 
		ORDER BY 
			core.prioritized_priority;

		DELETE FROM @targetDatabases;
		INSERT INTO @targetDatabases ([database_name])
		SELECT [database_name] 
		FROM @prioritized_targets
		ORDER BY entry_id;
	END;

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN
		SELECT @SerializedOutput = (SELECT 
			[row_id] [database/@id],
			[database_name] [database]
		FROM 
			@targetDatabases
		ORDER BY 
			[row_id] 
		FOR XML PATH(N''), ROOT(N'databases'));		

		RETURN 0;
	END;

	SELECT 
		[database_name]
	FROM 
		@targetDatabases 
	ORDER BY 
		[row_id]; 

	RETURN 0;

ErrorCondition:
	RETURN -100;
GO