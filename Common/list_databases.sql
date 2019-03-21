/*


	-- TODO: 
		- verify that if I do the following: 
			1. dbo.load_databases '[READ_FROM_FILESYSTEM]' to get a list of dbnames - like: 'oldDbBackupWhereDbIsn'tOnTheServerAnymoreButBackupIs, etc, blah, yada';
			2. dbo.list_databases??? (i.e., prioritize and such...) 
					that oldDbBackupWhereDbIsn'tOnTheServerAnymoreButBackupIs
						isn't stripped from the list of options/outputs simply because it's NOT in sys.databases... 

				AND... I think the 'fix' there is to set @ExcludOffline = 0... so that we don't exclude 'non-active' databases... 



	TESTS: 

			-- expect exception:
			EXEC dbo.list_databases 
				@Targets = N'[READ_FROM_FILESYSTEM]';

			-- expect exception:
			EXEC dbo.list_databases 
				@Exclusions = N'[READ_FROM_FILESYSTEM]';

			-- expect exception:
			EXEC dbo.list_databases 
				@Targets = N'[ALL]', 
				@Exclusions = N'[SYSTEM]';
			GO

			-- expect exception:
			EXEC dbo.list_databases 
				@Targets = N'[ALL]', 
				@Exclusions = N'[USER]';
			GO

			EXEC dbo.list_databases;
			GO

			EXEC dbo.list_databases 
				@Targets = N'[ALL]';
			GO

			EXEC dbo.list_databases 
				@Targets = N'[SYSTEM]';
			GO

			EXEC dbo.list_databases 
				@Targets = N'[USER]';
			GO

			EXEC dbo.list_databases 
				@Targets = N'[ALL]', 
				@Exclusions = N'BayCar%';
			GO

			EXEC dbo.list_databases 
				@Targets = N'Billing, SelectEXP,Traces,Utilities, Licensing';
			GO

			EXEC dbo.list_databases 
				@Targets = N'Billing, SelectEXP,Traces,Utilities, Licensing', 
				@Priorities = N'SelectExp, *, Traces';
			GO

			EXEC dbo.list_databases 
				@ExcludeReadOnly = 1;
			GO

			-- expect exception (for now)
			EXEC dbo.list_databases 
				@ExcludeDev = 1;

			-- expect exception (for now)
			EXEC dbo.list_databases 
				@ExcludeTest = 1;

*/

USE [admindb];
GO 

IF OBJECT_ID('dbo.list_databases','P') IS NOT NULL
	DROP PROC dbo.list_databases
GO

CREATE PROC dbo.list_databases
	@Targets								nvarchar(MAX)	= N'[ALL]',		-- [ALL] | [SYSTEM] | [USER] | [READ_FROM_FILESYSTEM] | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions								nvarchar(MAX)	= NULL,			-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities								nvarchar(MAX)	= NULL,			-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@ExcludeClones							bit				= 1, 
	@ExcludeSecondaries						bit				= 1,			-- exclude AG and Mirroring secondaries... 
	@ExcludeSimpleRecovery					bit				= 0,			-- exclude databases in SIMPLE recovery mode
	@ExcludeReadOnly						bit				= 0,			
	@ExcludeRestoring						bit				= 1,			-- explicitly removes databases in RESTORING and 'STANDBY' modes... 
	@ExcludeRecovering						bit				= 1,			-- explicitly removes databases in RECOVERY, RECOVERY_PENDING, and SUSPECT modes.
	@ExcludeOffline							bit				= 1,			-- removes ANY state other than ONLINE.
	@ExcludeDev								bit				= 0,			-- not yet implemented
	@ExcludeTest							bit				= 0				-- not yet implemented
AS 
	SET NOCOUNT ON; 

	-- {copyright} 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF NULLIF(@Targets, N'') IS NULL BEGIN
		RAISERROR('@Targets cannot be null or empty - it must either be the specialized token [ALL], [SYSTEM], [USER], or a comma-delimited list of databases/folders.', 16, 1);
		RETURN -1;
	END

	IF (SELECT dbo.[count_matches](@Exclusions, N'[READ_FROM_FILESYSTEM]')) > 0 BEGIN 
		RAISERROR(N'The [READ_FROM_FILESYSTEM] is NOT a valid exclusion token.', 16, 1);
		RETURN -2;
	END;

	IF (SELECT dbo.[count_matches](@Targets, N'[READ_FROM_FILESYSTEM]')) > 0 BEGIN 
		RAISERROR(N'@Targets may NOT be set to (or containt) [READ_FROM_FILESYSTEM]. The [READ_FROM_FILESYSTEM] token is ONLY allowed as an option/token for @TargetDatabases in dbo.restore_databases and dbo.apply_logs.', 16, 1);
		RETURN -3;
	END;

	IF ((SELECT dbo.[count_matches](@Exclusions, N'[SYSTEM]')) > 0) AND ((SELECT dbo.[count_matches](@Targets, N'[ALL]')) > 0) BEGIN
		RAISERROR(N'[SYSTEM] can NOT be specified as an Exclusion when @Targets is (or contains) [ALL]. Replace [ALL] with [USER] for @Targets and remove [SYSTEM] from @Exclusions instead (to load all databases EXCEPT ''System'' Databases.', 16, 1);
		RETURN -5;
	END;

	IF ((SELECT dbo.[count_matches](@Exclusions, N'[USER]')) > 0) AND ((SELECT dbo.[count_matches](@Targets, N'[ALL]')) > 0) BEGIN
		RAISERROR(N'[USER] can NOT be specified as an Exclusion when @Targets is (or contains) [ALL]. Replace [ALL] with [SYSTEM] for @Targets and remove [USER] from @Exclusions instead (to load all databases EXCEPT ''User'' Databases.', 16, 1);
		RETURN -6;
	END;

	IF ((SELECT dbo.[count_matches](@Exclusions, N'[USER]')) > 0) OR ((SELECT dbo.[count_matches](@Exclusions, N'[ALL]')) > 0) BEGIN 
		RAISERROR(N'@Exclusions may NOT be set to [ALL] or [USER].', 16, 1);
		RETURN -7;
	END;

	-----------------------------------------------------------------------------
	-- Initialize helper objects:
	DECLARE @topN int = (SELECT COUNT(*) FROM sys.databases) + 100;

	SELECT TOP (@topN) IDENTITY(int, 1, 1) as N 
    INTO #Tally
    FROM sys.columns;

	DECLARE @deserialized table (
		[row_id] int NOT NULL, 
		[result] sysname NOT NULL
	); 

    DECLARE @target_databases TABLE ( 
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

    DECLARE @system_databases TABLE ( 
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	-- define system databases - we'll potentially need this in a number of different cases...
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

	-----------------------------------------------------------------------------
	-- Load Targets:
	IF UPPER(@Targets) IN (N'[ALL]', N'[SYSTEM]') BEGIN 
		INSERT INTO @target_databases ([database_name])
		SELECT [database_name] FROM @system_databases; 
	END; 

	IF UPPER(@Targets) IN (N'[ALL]', N'[USER]') BEGIN 
		INSERT INTO @target_databases ([database_name])
		SELECT [name] FROM sys.databases
		WHERE [name] NOT IN (SELECT [database_name] FROM @system_databases)
			AND LOWER([name]) <> N'tempdb'
		ORDER BY [name];
	 END; 

	 -- If not a token, then try comma delimitied: 
	 IF NOT EXISTS (SELECT NULL FROM @target_databases) BEGIN
	
		INSERT INTO @deserialized ([row_id], [result])
		SELECT [row_id], CAST([result] AS sysname) [result] FROM [admindb].dbo.[split_string](@Targets, N',', 1);

		IF EXISTS (SELECT NULL FROM @deserialized) BEGIN 
			INSERT INTO @target_databases ([database_name])
			SELECT RTRIM(LTRIM([result])) FROM @deserialized ORDER BY [row_id];
		END;
	 END;

	-----------------------------------------------------------------------------
	-- Remove Exclusions: 
	IF @ExcludeClones = 1 BEGIN 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE source_database_id IS NOT NULL);		
	END;

	IF @ExcludeSecondaries = 1 BEGIN 

		DECLARE @synchronized table ( 
			[database_name] sysname NOT NULL
		);

		-- remove any mirrored secondaries: 
		INSERT INTO @synchronized ([database_name])
		SELECT d.[name] 
		FROM sys.[databases] d 
		INNER JOIN sys.[database_mirroring] dm ON d.[database_id] = dm.[database_id] AND dm.[mirroring_guid] IS NOT NULL
		WHERE UPPER(dm.[mirroring_role_desc]) <> N'PRINCIPAL';

		-- dynamically account for any AG'd databases:
		IF (SELECT admindb.dbo.get_engine_version()) >= 11.0 BEGIN		
			CREATE TABLE #hadr_names ([name] sysname NOT NULL);
			EXEC sp_executesql N'INSERT INTO #hadr_names ([name]) SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc <> ''PRIMARY'';'	

			INSERT INTO @synchronized ([database_name])
			SELECT [name] FROM #hadr_names;
		END

		-- Exclude any databases that aren't operational: (NOTE, this excluding all dbs that are non-operational INCLUDING those that might be 'out' because of Mirroring, but it is NOT SOLELY trying to remove JUST mirrored/AG'd databases)
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [database_name] FROM @synchronized);
	END;

	IF @ExcludeSimpleRecovery = 1 BEGIN 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE UPPER([recovery_model_desc]) = 'SIMPLE');
	END; 

	IF @ExcludeReadOnly = 1 BEGIN
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE [is_read_only] = 1)
	END;

	IF @ExcludeRestoring = 1 BEGIN
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE UPPER([state_desc]) = 'RESTORING');		

		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE [is_in_standby] = 1);
	END; 

	IF @ExcludeRecovering = 1 BEGIN 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE UPPER([state_desc]) IN (N'RECOVERY', N'RECOVERY_PENDING', N'SUSPECT'));
	END;
	 
	IF @ExcludeOffline = 1 BEGIN -- all states OTHER than online... 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] FROM sys.databases WHERE UPPER([state_desc]) <> N'ONLINE');
	END;

	IF @ExcludeDev = 1 OR @ExcludeTest = 1 BEGIN 
		RAISERROR('Dev and Test Exclusions have not YET been implemented.', 16, 1);
		RETURN - 100; 

		-- NOTE: RATHER than doing @ExcludeX explicitly... 
		--		PROBABLY makes way more sense to have [DEV] [TEST] tokens - they work the SAME way (lookups to dbo.settings)... but end up being WAY more versatile...

		-- TODO: Implement. for each type, there will be an option to drop in a setting/key that defines what dev or test dbs look like... 
		--			as in ... a setting that effectively equates all dev or test with '%_dev' or 'test_%' - whatever an org's format is. 
		--					AND, also needs to enable one-off additions to these as well, e.g., 'ImportStaging' or 'Blah' could be marked a test or dev.
	END; 

	-- Exclude explicit exclusions: 
	IF NULLIF(@Exclusions, '') IS NOT NULL BEGIN;
		
		DELETE FROM @deserialized;

		IF (SELECT dbo.[count_matches](@Exclusions, N'[SYSTEM]')) > 0 BEGIN
			INSERT INTO @deserialized ([row_id], [result])
			SELECT 1 [fake_row_id], [database_name] FROM @system_databases;	

			-- account for distribution (and note that it can/will only be EXCLUDED (i.e., IF it was found and IF it's marked as 'system', we won't restore it)).
			IF (SELECT dbo.is_system_database('distribution')) = 1  BEGIN
				INSERT INTO @deserialized ([row_id], [result])
				VALUES (99, 'distribution');
			END;

			SET @Exclusions = REPLACE(@Exclusions, N'[SYSTEM]', N'');
		END;

		INSERT INTO @deserialized ([row_id], [result])
		SELECT [row_id], CAST([result] AS sysname) [result] FROM [admindb].dbo.[split_string](@Exclusions, N',', 1);

		DELETE t 
		FROM @target_databases t
		INNER JOIN @deserialized d ON t.[database_name] LIKE d.[result];
	END;

	-----------------------------------------------------------------------------
	-- Prioritize:
	IF ISNULL(@Priorities, '') IS NOT NULL BEGIN;

		DECLARE @prioritized table (
			priority_id int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @prioritized ([database_name])
		SELECT [result] FROM dbo.[split_string](@Priorities, N',', 1) ORDER BY [row_id];
				
		DECLARE @alphabetized int;
		SELECT @alphabetized = priority_id FROM @prioritized WHERE [database_name] = '*';

		IF @alphabetized IS NULL
			SET @alphabetized = (SELECT MAX(entry_id) + 1 FROM @target_databases);

		DECLARE @prioritized_targets TABLE ( 
			[entry_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		); 

		WITH core AS ( 
			SELECT 
				t.[database_name], 
				CASE 
					WHEN p.[database_name] IS NULL THEN 0 + t.entry_id
					WHEN p.[database_name] IS NOT NULL AND p.priority_id <= @alphabetized THEN -32767 + p.priority_id
					WHEN p.[database_name] IS NOT NULL AND p.priority_id > @alphabetized THEN 32767 + p.priority_id
				END [prioritized_priority]
			FROM 
				@target_databases t 
				LEFT OUTER JOIN @prioritized p ON p.[database_name] = t.[database_name]
		) 

		INSERT INTO @prioritized_targets ([database_name])
		SELECT 
			[database_name]
		FROM core 
		ORDER BY 
			core.prioritized_priority;

		DELETE FROM @target_databases;
		INSERT INTO @target_databases ([database_name])
		SELECT [database_name] 
		FROM @prioritized_targets
		ORDER BY entry_id;
	END;

	-----------------------------------------------------------------------------
	-- project: 
	SELECT 
		[database_name] 
	FROM 
		@target_databases
	ORDER BY 
		[entry_id];

	RETURN 0;
GO