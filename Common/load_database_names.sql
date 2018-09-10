

/*
	TODO: 
		- Implement logic for LIST_ALL mode - which will also include snapshots, offline dbs, and 'synchronizing' dbs... (i.e., all/everything).
		- The VERIFY mode is never really used. Pretty sure I call/leverage it from a few of the sprocs that depend upon this pig - but there is no explicit 'path' through the code that accounts for any speciaization. 
									hmmm. maybe that might be what verify means though - i.e., verify = 'drop through all of the default logic'?

	DEPENDENCIES:
		

	NOTES:
		- JUSTIFICATION: the logic defined in this sproc is consumed by 3x different sprocs (dba_BackupDatabases, dba_RestoreDatabases, dba_RemoveBackupFiles). 
			It is therefore put into this SINGLE sproc as an attempt at DRY (i.e., to avoid having 3x copies of ROUGHLY the same logic sprinkled throughout each
			of the 'consumers'. HOWEVER, because any sproc that CAN (i.e., is allowed to) read the file-system via the [READ_FROM_FILESYSTEM] token will need to 
			run an INSERT..EXEC statement, we CAN'T spit the output of THIS sproc (dba_LoadDatabaseNames) out as a normal projection (which could then be 'consumed'
			via an INSERT...EXEC within the consumer - because that runs afoul of the dreaded 'nested insert exec' limitation that is prevented by SQL Server. 
			AS SUCH: this sproc spits out a list of dbs via the @Output parameter as a serialized LIST of database names - that then need to be 'split' apart via
			split_string (or something else). That's a significant 'work-around' but the performance overhead is non-existent, meaning that the only overhead
			is one of code maintenance and the JUSTIFICATION for such a manuever is that, once coded, this will be EASIER to maintain as 1x block of code than 3x
			semi-similar blocks of code spread out among 3x different routines. 

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple	


	SCALABLE:
		3+



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.load_database_names','P') IS NOT NULL
	DROP PROC dbo.load_database_names;
GO

CREATE PROC dbo.load_database_names 
	@Input				nvarchar(MAX),				-- [ALL] | [SYSTEM] | [USER] | [READ_FROM_FILESYSTEM] | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions			nvarchar(MAX)	= NULL,		-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities			nvarchar(MAX)	= NULL,		-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@Mode				sysname,					-- BACKUP | RESTORE | REMOVE | VERIFY | LIST_ACTIVE | LIST_ALL | LIST_RESTORED | NON_RECOVERED 
	@BackupType			sysname			= NULL,		-- FULL | DIFF | LOG  -- only needed if @Mode = BACKUP | NON_RECOVERED
	@TargetDirectory	sysname			= NULL,		-- Only required when @Input is specified as [READ_FROM_FILESYSTEM].
	@Output				nvarchar(MAX)	OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @includeAdminDBAsSystemDatabase bit = 1; -- by default, tread admindb as a system database (i.e., exclude it from [USER] and include it in [SYSTEM];

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF ISNULL(@Input, N'') = N'' BEGIN;
		RAISERROR('@Input cannot be null or empty - it must either be the specialized token [ALL], [SYSTEM], [USER], [READ_FROM_FILESYSTEM], or a comma-delimited list of databases/folders.', 16, 1);
		RETURN -1;
	END

	IF ISNULL(@Mode, N'') = N'' BEGIN;
		RAISERROR('@Mode cannot be null or empty - it must be one of the following values: BACKUP | RESTORE | REMOVE | VERIFY | LIST_ACTIVE | LIST_ALL | LIST_RESTORED | NON_RECOVERED ', 16, 1);
		RETURN -2;
	END
	
	IF UPPER(@Mode) NOT IN (N'BACKUP',N'RESTORE',N'REMOVE',N'VERIFY', N'LIST_ACTIVE', N'LIST_ALL', N'LIST_RESTORED', N'NON_RECOVERED') BEGIN 
		RAISERROR('Permitted values for @Mode must be one of the following values: BACKUP | RESTORE | REMOVE | VERIFY | LIST_ACTIVE | LIST_ALL | LIST_RESTORED | NON_RECOVERED', 16, 1);
		RETURN -2;
	END

	IF UPPER(@Mode) = N'BACKUP' BEGIN;
		IF @BackupType IS NULL BEGIN;
			RAISERROR('When @Mode is set to BACKUP, the @BackupType value MUST be provided (and must be one of the following values: FULL | DIFF | LOG).', 16, 1);
			RETURN -5;
		END

		IF UPPER(@BackupType) NOT IN (N'FULL', N'DIFF', N'LOG') BEGIN;
			RAISERROR('When @Mode is set to BACKUP, the @BackupType value MUST be provided (and must be one of the following values: FULL | DIFF | LOG).', 16, 1);
			RETURN -5;
		END
	END

	IF UPPER(@Mode) = N'LIST_RESTORED' BEGIN 
		IF OBJECT_ID('dbo.restore_log') IS NULL BEGIN
			RAISERROR('S4 table dbo.restore_log is required to list restored databases.', 16, 1);
			RETURN -6;
		END;
	END;

	IF UPPER(@Input) = N'[READ_FROM_FILESYSTEM]' BEGIN;
		IF UPPER(@Mode) NOT IN (N'RESTORE', N'REMOVE') BEGIN;
			RAISERROR('The specialized token [READ_FROM_FILESYSTEM] can only be used when @Mode is set to RESTORE or REMOVE.', 16, 1);
			RETURN - 9;
		END

		IF @TargetDirectory IS NULL BEGIN;
			RAISERROR('When @Input is specified as [READ_FROM_FILESYSTEM], the @TargetDirectory must be specified - and must point to a valid path.', 16, 1);
			RETURN - 10;
		END
	END

	-----------------------------------------------------------------------------
	-- Initialize helper objects:

	SELECT TOP 1000 IDENTITY(int, 1, 1) as N 
    INTO #Tally
    FROM sys.columns;

    DECLARE @targets TABLE ( 
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

    IF UPPER(@Input) IN (N'[ALL]', N'[SYSTEM]') AND UPPER(@Mode) <> N'LIST_RESTORED' BEGIN;
	    INSERT INTO @targets ([database_name])
        SELECT 'master' UNION SELECT 'msdb' UNION SELECT 'model';

		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
			IF @includeAdminDBAsSystemDatabase = 1 
				INSERT INTO @targets ([database_name])
				VALUES ('admindb');
		END
    END; 

    IF UPPER(@Input) IN (N'[ALL]', N'[USER]') AND UPPER(@Mode) <> N'LIST_RESTORED' BEGIN; 
        IF @BackupType = 'LOG'
            INSERT INTO @targets ([database_name])
            SELECT name FROM sys.databases 
            WHERE recovery_model_desc = 'FULL' 
                AND name NOT IN ('master', 'model', 'msdb', 'tempdb') 
				AND source_database_id IS NULL  -- exclude database snapshots.
            ORDER BY name;
        ELSE 
            INSERT INTO @targets ([database_name])
            SELECT name FROM sys.databases 
            WHERE name NOT IN ('master', 'model', 'msdb','tempdb') 
				AND source_database_id IS NULL -- exclude database snapshots
            ORDER BY name;

		IF @includeAdminDBAsSystemDatabase = 1 
			DELETE FROM @targets WHERE [database_name] = 'admindb';
		
    END; 

    IF UPPER(@Input) = '[READ_FROM_FILESYSTEM]' BEGIN;

        DECLARE @directories table (
            row_id int IDENTITY(1,1) NOT NULL, 
            subdirectory sysname NOT NULL, 
            depth int NOT NULL
        );

        INSERT INTO @directories (subdirectory, depth)
        EXEC master.sys.xp_dirtree @TargetDirectory, 1, 0;

        INSERT INTO @targets ([database_name])
        SELECT subdirectory FROM @directories ORDER BY row_id;

      END; 

    IF (SELECT COUNT(*) FROM @targets) <= 0 AND UPPER(@Mode) <> N'LIST_RESTORED' BEGIN;

        DECLARE @SerializedDbs nvarchar(1200);
		SET @SerializedDbs = N',' + @Input + N',';

        INSERT INTO @targets ([database_name])
        SELECT  RTRIM(LTRIM((SUBSTRING(@SerializedDbs, N + 1, CHARINDEX(',', @SerializedDbs, N + 1) - N - 1))))
        FROM #Tally
        WHERE N < LEN(@SerializedDbs) 
            AND SUBSTRING(@SerializedDbs, N, 1) = ','
        ORDER BY #Tally.N;

		IF UPPER(@Mode) = N'BACKUP' BEGIN;
			IF @BackupType = 'LOG' BEGIN
				DELETE FROM @targets 
				WHERE [database_name] NOT IN (
					SELECT [name] FROM sys.databases WHERE recovery_model_desc = 'FULL'
				);
			  END;
			ELSE 
				DELETE FROM @targets
				WHERE [database_name] NOT IN (SELECT [name] FROM sys.databases);
		END
    END;

	-- remove AG'd and Mirrored databases:
	IF UPPER(@Mode) IN (N'BACKUP', N'LIST_ACTIVE') BEGIN;
		
		-- make sure that if any dbs were explicitly mentioned (i.e, N'oink, oink3, blah' - that they're VALID)
		DELETE FROM @targets 
		WHERE [database_name] NOT IN (SELECT [name] FROM sys.databases WHERE source_database_id IS NULL);

		DECLARE @synchronized table ( 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @synchronized ([database_name])
		SELECT [name] FROM sys.databases WHERE state_desc <> 'ONLINE'; -- this gets DBs that are NOT online - including those listed as RESTORING because they're mirrored. 

		-- account for SQL Server 2008/2008 R2 (i.e., pre-HADR):
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @synchronized ([database_name])
			EXEC sp_executesql N'SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc <> ''PRIMARY'';'	
		END

		-- Note, snapshots were removed earlier... 

		-- Exclude any databases that aren't operational: (NOTE, this excluding all dbs that are non-operational INCLUDING those that might be 'out' because of Mirroring, but it is NOT SOLELY trying to remove JUST mirrored/AG'd databases)
		DELETE FROM @targets 
		WHERE [database_name] IN (SELECT [database_name] FROM @synchronized);
	END
	
	IF UPPER(@Mode) IN (N'LIST_RESTORED') BEGIN
		-- only show dbs that have been restored (i.e., in dbo.restore_log).
		INSERT INTO @targets ([database_name])
		SELECT [database] FROM dbo.[restore_log] GROUP BY [database];
	END;

	IF UPPER(@Mode) IN (N'NON_RECOVERED') BEGIN
	
		-- remove dbs not in RECOVERY or STANDBY mode:
		DELETE FROM @targets
		WHERE [database_name] NOT IN (SELECT [name] FROM sys.databases WHERE [is_in_standby] = 1 OR [state_desc] = N'RESTORING');

		
		-- now delete any dbs that are in RESTORING state becauses they're MIRRORED or in an AG:
		DELETE FROM @targets 
		WHERE [database_name] IN (
			SELECT 
				d.[name] [database_name]
			FROM 
				sys.database_mirroring dm
				INNER JOIN sys.databases d ON dm.database_id = d.database_id
			WHERE 
				dm.mirroring_guid IS NOT NULL

		UNION

			SELECT
				dbcs.[database_name]
			FROM
				master.sys.availability_groups AS ag
				INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
				INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON AR.replica_id = arstates.replica_id AND arstates.is_local = 1
				INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		);
	END;

	-- Exclude any databases specified for exclusion:
	IF ISNULL(@Exclusions, '') <> '' BEGIN;
	
		DECLARE @removedDbs nvarchar(1200);
		SET @removedDbs = N',' + @Exclusions + N',';

		DELETE t 
		FROM @targets t 
		INNER JOIN (
			SELECT RTRIM(LTRIM(SUBSTRING(@removedDbs, N + 1, CHARINDEX(',', @removedDbs, N + 1) - N - 1))) [db_name]
			FROM #Tally
			WHERE N < LEN(@removedDbs)
				AND SUBSTRING(@removedDbs, N, 1) = ','		
		) exclusions ON t.[database_name] LIKE exclusions.[db_name];

	END;

	IF ISNULL(@Priorities, '') IS NOT NULL BEGIN;
		DECLARE @SerializedPriorities nvarchar(MAX);
		SET @SerializedPriorities = N',' + @Priorities + N',';

		DECLARE @prioritized table (
			priority_id int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @prioritized ([database_name])
		SELECT  RTRIM(LTRIM((SUBSTRING(@SerializedPriorities, N + 1, CHARINDEX(',', @SerializedPriorities, N + 1) - N - 1))))
        FROM #Tally
        WHERE N < LEN(@SerializedPriorities) 
            AND SUBSTRING(@SerializedPriorities, N, 1) = ','
        ORDER BY #Tally.N;

		DECLARE @alphabetized int;
		SELECT @alphabetized = priority_id FROM @prioritized WHERE [database_name] = '*';

		IF @alphabetized IS NULL
			SET @alphabetized = (SELECT MAX(entry_id) + 1 FROM @targets);

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
				@targets t 
				LEFT OUTER JOIN @prioritized p ON p.[database_name] = t.[database_name]
		) 

		INSERT INTO @prioritized_targets ([database_name])
		SELECT 
			[database_name]
		FROM core 
		ORDER BY 
			core.prioritized_priority;

		DELETE FROM @targets;
		INSERT INTO @targets ([database_name])
		SELECT [database_name] 
		FROM @prioritized_targets
		ORDER BY entry_id;

	END 

	-- Output (used to get around nasty 'insert exec can't be nested' error when reading from file-system.
	SET @Output = N'';
	SELECT @Output = @Output + [database_name] + ',' FROM @targets ORDER BY entry_id;

	IF ISNULL(@Output,'') <> ''
		SET @Output = LEFT(@Output, LEN(@Output) - 1);

	RETURN 0;
GO