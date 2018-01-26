


/*
	
	TODO:
		- Maybe name this 4.x to 4.N.sql? 
		- Arguably, create a .ps1 or something else that will 'intelligently' push code as needed/etc. 


	UPDATES 
		(List of specific/disting 'updates' or 'patches' defined in this script):
		- 4.2.0.16786. Rollup of multiple 4.1 and 4.1.x changes - includding initial addition of monitoring scripts and upgrades/changes to backup removal processes to address bugs with 'synchronized' host servers and system databases, etc. 


	CHANGELOG:
		(List of all changes since 4.0). 

		- 4.1.0.16761. BugFix: Optimizing logic in dbo.[remove_backups] to account for mirrored and AG'd backups of system databases (i.e., server-name in backup path). 
		- 4.1.0.16763. Updating documentation for dbo.backup_databases. Integrating @ServerNameInSystemBackupPath into [backup_databases].
		- 4.1.0.16764. Integrated file-removal for mirrored servers/hosts into change and deployment scripts. 
		- 4.1.1.16773. Modifying + testing load_database_names and backup_databases to be able to ignore HADR checks if/when server version < 11.0. 
		- 4.1.1.16780. High-level planning and specifications planning for additional code/sproc to test RPOs and 'staleness' of restored (or non-restored) data as part of regular restore test outcomes. 
		- 4.1.2.16785. Hours writing and testing query to provide 'lambda' query capabilities for testing both restore-test validation (data-stale/fresh concerns) and RPOs (as well as RTOs) under smoke and rubble testing scenarios. 
		- 4.2.0.16786. Initial addition of monitoring scripts (verify_backup_execution and verify_database_activity) + rollup of changes. 
		---> ROLLUP: 4.2.0.16786.
		- 4.x.x.x. etc... 



	NOTES:
		- It's effectively impossible to 'intelligently' process changes in the script below (via T-SQL 'as is'). Because, if we, say a) check for @version = suchAndSuch and if it's not found, then try to run a bunch of code... 
			then that CODE will be a bunch of IF/ELSE statements that create/drop sprocs UDFs and the likes and... ultimately which have gobs of their own logic in place. In other words we can't say: 
					IF @something = true BEGIN
							IF OBJECT_ID('Something') IS NOT NULL 
								DROP Something;
							GO 

							CREATE PROC 
								@here
							AS 
								lots of complex 
								logic
								and branching 

							and the likes

								RETURN;
							GO
					END; -- end the IF... 

			To get around that, the only REAL option is... object drop/create statements would have to be wrapped in 'ticks' and run via sp_executesql... which... sucks. 


			So. intead, this script/approach takes a hybrid approach that'll have to work until... it no longer works. Which is: 
				- check for and push any DML and or even SOME DDL (modifications to tables and such) changes within IF blocks per each rollup/release defined. 
				- Add meta-data to the version_history table about any changes. 
				- bundle up ALL scripts/changes since 4.0 until the LATEST version of the code and... put those at the 'bottom' of this script. 
					(which means that the idea/approach here is: a) drop/recreate ALL objects to the VERY latest version and b) 'iterate' over each major rollup/update and push and meta-data about said rollup into the history ALL while having a 'chance' to push any 
						DDL changes and such that would be dependent on each rollup/release. 

*/


USE [admindb];
GO



----------------------------------------------------------------------------------------
-- Version 4.2.0.16786 Rollup: 
DECLARE @targetVersion varchar(20) = '4.2.1.16808';
IF NOT EXISTS(SELECT NULL FROM dbo.version_history WHERE version_number = @targetVersion) BEGIN
	
	PRINT 'Deploying v4.2 Updates.... ';


	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@targetVersion, 'Deployed via Upgrade Script. Bug Fixes and Initial addition of copy_database functionality.', GETDATE());

END;


----------------------------------------------------------------------------------------
-- Code Changes/Updates:
USE [master];
GO

-- 4.2.0.16786
IF OBJECT_ID('dba_VerifyBackupExecution', 'P') IS NOT NULL BEGIN
		
	-- 
	PRINT 'Older version of dba_VerifyBackupExecution found. Check for jobs to replace/update... '
	DROP PROC dbo.dba_VerifyBackupExecution;
END;


-------------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_database_names','P') IS NOT NULL
	DROP PROC dbo.load_database_names;
GO

CREATE PROC dbo.load_database_names 
	@Input				nvarchar(MAX),				-- [SYSTEM] | [USER] | [READ_FROM_FILESYSTEM] | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions			nvarchar(MAX)	= NULL,		-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities			nvarchar(MAX)	= NULL,		-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@Mode				sysname,					-- BACKUP | RESTORE | REMOVE | VERIFY
	@BackupType			sysname			= NULL,		-- FULL | DIFF | LOG  -- only needed if @Mode = BACKUP
	@TargetDirectory	sysname			= NULL,		-- Only required when @Input is specified as [READ_FROM_FILESYSTEM].
	@Output				nvarchar(MAX)	OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @includeAdminDBAsSystemDatabase bit = 1; -- by default, tread admindb as a system database (i.e., exclude it from [USER] and include it in [SYSTEM];

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF ISNULL(@Input, N'') = N'' BEGIN;
		RAISERROR('@Input cannot be null or empty - it must either be the specialized token [SYSTEM], [USER], [READ_FROM_FILESYSTEM], or a comma-delimited list of databases/folders.', 16, 1);
		RETURN -1;
	END

	IF ISNULL(@Mode, N'') = N'' BEGIN;
		RAISERROR('@Mode cannot be null or empty - it must be one of the following values: BACKUP | RESTORE | REMOVE | VERIFY', 16, 1);
		RETURN -2;
	END
	
	IF UPPER(@Mode) NOT IN (N'BACKUP',N'RESTORE',N'REMOVE',N'VERIFY') BEGIN 
		RAISERROR('Permitted values for @Mode must be one of the following values: BACKUP | RESTORE | REMOVE | VERIFY', 16, 1);
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

    IF UPPER(@Input) = '[SYSTEM]' BEGIN;
	    INSERT INTO @targets ([database_name])
        SELECT 'master' UNION SELECT 'msdb' UNION SELECT 'model';

		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
			IF @includeAdminDBAsSystemDatabase = 1 
				INSERT INTO @targets ([database_name])
				VALUES ('admindb');
		END
    END; 

    IF UPPER(@Input) = '[USER]' BEGIN; 
        IF @BackupType = 'LOG'
            INSERT INTO @targets ([database_name])
            SELECT name FROM sys.databases 
            WHERE recovery_model_desc = 'FULL' 
                AND name NOT IN ('master', 'model', 'msdb', 'tempdb') 
            ORDER BY name;
        ELSE 
            INSERT INTO @targets ([database_name])
            SELECT name FROM sys.databases 
            WHERE name NOT IN ('master', 'model', 'msdb','tempdb') 
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

    IF (SELECT COUNT(*) FROM @targets) <= 0 BEGIN;

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
					SELECT name FROM sys.databases WHERE recovery_model_desc = 'FULL'
				);
			  END;
			ELSE 
				DELETE FROM @targets
				WHERE [database_name] NOT IN (SELECT name FROM sys.databases);
		END
    END;

	IF UPPER(@Mode) IN (N'BACKUP') BEGIN;

		DECLARE @synchronized table ( 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @synchronized ([database_name])
		SELECT [name] FROM	sys.databases WHERE state_desc != 'ONLINE'; -- this gets DBs that are NOT online - including those listed as RESTORING because they're mirrored. 

		-- account for SQL Server 2008/2008 R2 (i.e., pre-HADR):
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @synchronized ([database_name])
			EXEC sp_executesql N'SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc != ''PRIMARY'';'	
		END

		-- Exclude any databases that aren't operational: (NOTE, this excluding all dbs that are non-operational INCLUDING those that might be 'out' because of Mirroring, but it is NOT SOLELY trying to remove JUST mirrored/AG'd databases)
		DELETE FROM @targets 
		WHERE [database_name] IN (SELECT [database_name] FROM @synchronized);
	END

	-- Exclude any databases specified for exclusion:
	IF ISNULL(@Exclusions, '') != '' BEGIN;
	
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

	IF ISNULL(@Output,'') != ''
		SET @Output = LEFT(@Output, LEN(@Output) - 1);

	RETURN 0;
GO




USE [admindb];
GO

IF OBJECT_ID('[dbo].[remove_backup_files]','P') IS NOT NULL
	DROP PROC [dbo].[remove_backup_files];
GO

CREATE PROC [dbo].[remove_backup_files] 
	@BackupType							sysname,						-- { ALL | FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),					-- { [READ_FROM_FILESYSTEM] | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,			-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000),					-- { path_to_backups }
	@Retention							nvarchar(10),					-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@ServerNameInSystemBackupPath		bit = 0,						-- for mirrored servers/etc.
	@Output								nvarchar(MAX) = NULL OUTPUT,	-- When set to non-null value, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@SendNotifications					bit	= 0,						-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
	@PrintOnly							bit = 0 						-- { 0 | 1 }
AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.execute_uncatchable_command', 'P') IS NULL BEGIN;
		RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN;
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN;
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN;
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN;
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN;
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF ((@PrintOnly = 0) OR (@Output IS NULL)) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN; 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN;
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG', 'ALL') BEGIN;
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	SET @Retention = LTRIM(RTRIM(@Retention));
	DECLARE @retentionType char(1);
	DECLARE @retentionValue int;

	SET @retentionType = LOWER(RIGHT(@Retention,1));

	-- Only approved values are allowed: (m[inutes], [h]ours, [d]ays, [b]ackups (a specific count)). 
	IF @retentionType NOT IN ('m','h','d','w','b') BEGIN 
		RAISERROR('Invalid @Retention value specified. @Retention must take the format of #L - where # is a positive integer, and L is a SINGLE letter [m | h | d | w | b] for minutes, hours, days, weeks, or backups (i.e., a specific number of most recent backups to retain).', 16, 1);
		RETURN -10000;	
	END 

	-- a WHOLE lot of negation going on here... but, this is, insanely, right:
	IF NOT EXISTS (SELECT 1 WHERE LEFT(@Retention, LEN(@Retention) - 1) NOT LIKE N'%[^0-9]%') BEGIN 
		RAISERROR('Invalid @Retention specified defined (more than one non-integer value found in @Retention value). Please specify an integer and then either [ m | h | d | w | b ] for minutes, hours, days, weeks, or backups (specific number of most recent backups) to retain.', 16, 1);
		RETURN -10001;
	END
	
	SET @retentionValue = CAST(LEFT(@Retention, LEN(@Retention) -1) AS int);

	IF @PrintOnly = 1 BEGIN
		IF @retentionType = 'b'
			PRINT 'Retention specification is to keep the last ' + CAST(@retentionValue AS sysname) + ' backup(s).';
		ELSE 
			PRINT 'Retention specification is to remove backups more than ' + CAST(@retentionValue AS sysname) + CASE @retentionType WHEN 'm' THEN ' minutes ' WHEN 'h' THEN ' hour(s) ' WHEN 'd' THEN ' day(s) ' ELSE ' week(s) ' END + 'old.';
	END;

	DECLARE @retentionCutoffTime datetime = NULL; 
	IF @retentionType != 'b' BEGIN
		IF @retentionType = 'm'
			SET @retentionCutoffTime = DATEADD(MINUTE, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'h'
			SET @retentionCutoffTime = DATEADD(HOUR, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'd'
			SET @retentionCutoffTime = DATEADD(DAY, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'w'
			SET @retentionCutoffTime = DATEADD(WEEK, 0 - @retentionValue, GETDATE());
		
		IF @RetentionCutoffTime >= GETDATE() BEGIN; 
			 RAISERROR('Invalid @Retention specification. Specified value is in the future.', 16, 1);
			 RETURN -10;
		END;		
	END

	-- normalize paths: 
	IF(RIGHT(@TargetDirectory, 1) = '\')
		SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

	-- verify that path exists:
	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		RAISERROR('Invalid @TargetDirectory specified - either the path does not exist, or SQL Server''s Service Account does not have permissions to access the specified directory.', 16, 1);
		RETURN -10;
	END

	-----------------------------------------------------------------------------
	DECLARE @routeInfoAsOutput bit = 0;
	IF @Output IS NOT NULL 
		SET @routeInfoAsOutput = 1; 

	SET @Output = NULL;

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToProcess,
	    @Exclusions = @DatabasesToExclude,
	    @Mode = N'REMOVE',
	    @BackupType = @BackupType, 
		@TargetDirectory = @TargetDirectory,
		@Output = @serialized OUTPUT;

	DECLARE @targetDirectories table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [directory_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDirectories ([directory_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	-----------------------------------------------------------------------------
	-- Account for backups of system databases with the server-name in the path:  
	IF @ServerNameInSystemBackupPath = 1 BEGIN
		
		-- simply add additional/'duplicate-ish' directories to check for anything that's a system database:
		DECLARE @serverName sysname = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 


		-- and, note that IF we hand off the name of an invalid directory (i.e., say admindb backups are NOT being treated as system - so that D:\SQLBackups\admindb\SERVERNAME\ was invalid, then xp_dirtree (which is what's used to query for files) will simply return 'empty' results and NOT throw errors.
		INSERT INTO @targetDirectories (directory_name)
		SELECT 
			directory_name + @serverName 
		FROM 
			@targetDirectories
		WHERE 
			directory_name IN (N'master', N'msdb', N'model', N'admindb'); 

	END;

	-----------------------------------------------------------------------------
	-- Process files for removal:

	DECLARE @currentDirectory sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @targetPath nvarchar(512);
	DECLARE @outcome varchar(4000);
	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @file nvarchar(512);

	DECLARE @files table (
		id int IDENTITY(1,1),
		subdirectory nvarchar(512), 
		depth int, 
		isfile bit
	);

	DECLARE @lastN table ( 
		id int IDENTITY(1,1) NOT NULL, 
		original_id int NOT NULL, 
		backup_name nvarchar(512), 
		backup_type sysname
	);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL
	);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		directory_name
	FROM 
		@targetDirectories
	ORDER BY 
		[entry_id];

	OPEN processor;

	FETCH NEXT FROM processor INTO @currentDirectory;

	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @targetPath = @TargetDirectory + N'\' + @currentDirectory;

		SET @errorMessage = NULL;
		SET @outcome = NULL;

		IF @retentionType = 'b' BEGIN -- Remove all backups of target type except the most recent N (where N is @retentionValue).
			
			-- clear out any state from previous iterations.
			DELETE FROM @files;
			DELETE FROM @lastN;

			SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

			IF @PrintOnly = 1
				PRINT N'--' + @command;

			INSERT INTO @files (subdirectory, depth, isfile)
			EXEC sys.sp_executesql @command;

			-- Remove non-matching files/entries:
			DELETE FROM @files WHERE isfile = 0; -- remove directories.

			IF @BackupType IN ('LOG', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'LOG'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'LOG%.trn'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN
					DELETE FROM @files WHERE subdirectory NOT LIKE '%.trn';  -- if we're NOT doing all, then remove DIFF and FULL backups... 
				END;
			END;

			IF @BackupType IN ('FULL', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'FULL'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'FULL%.bak'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN 
					DELETE FROM @files WHERE subdirectory NOT LIKE 'FULL%.bak'; -- if we're NOT doing all, then remove all non-FULL backups...  
				END
			END;

			IF @BackupType IN ('DIFF', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'DIFF'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'DIFF%.bak'
				ORDER BY 
					id DESC;

					IF @BackupType != 'ALL' BEGIN 
						DELETE FROM @files WHERE subdirectory NOT LIKE 'DIFF%.bak'; -- if we're NOT doing all, the remove non-DIFFs so they won't be nuked.
					END
			END;
			
			-- prune any/all files we're supposed to keep: 
			DELETE x 
			FROM 
				@files x 
				INNER JOIN @lastN l ON x.id = l.original_id AND x.subdirectory = l.backup_name;

			-- and delete all, enumerated, files that are left:
			DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT subdirectory FROM @files ORDER BY id;

			OPEN nuker;
			FETCH NEXT FROM nuker INTO @file;

			WHILE @@FETCH_STATUS = 0 BEGIN;

				-- reset per each 'grab':
				SET @errorMessage = NULL;
				SET @outcome = NULL

				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), GETDATE(), 120), ' ', 'T') + ''', 0;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN; 

					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting backup [' + @file + N'] from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					END CATCH

				END;

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END

				FETCH NEXT FROM nuker INTO @file;

			END;

			CLOSE nuker;
			DEALLOCATE nuker;
		  END;
		ELSE BEGIN -- Any backups older than @RetentionCutoffTime are removed. 

			IF @BackupType IN ('LOG', 'ALL') BEGIN;
			
				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + ''', N''trn'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 1;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN 
					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;

						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting older LOG backups from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					END CATCH;				
				END

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + N' [Command: ' + @command + N']';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END
			END

			IF @BackupType IN ('FULL', 'DIFF', 'ALL') BEGIN;

				-- start by clearing any previous values:
				DELETE FROM @files;
				SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

				IF @PrintOnly = 1
					PRINT N'--' + @command;

				INSERT INTO @files (subdirectory, depth, isfile)
				EXEC sys.sp_executesql @command;

				DELETE FROM @files WHERE isfile = 0; -- remove directories.
				DELETE FROM @files WHERE subdirectory NOT LIKE '%.bak'; -- remove (from processing) any files that don't use the .bak extension. 

				-- If a specific backup type is specified ONLY target that backup type:
				IF @BackupType != N'ALL' BEGIN;
				
					IF @BackupType = N'FULL'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'FULL%';

					IF @BackupType = N'DIFF'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'DIFF%';
				END

				DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
				SELECT subdirectory FROM @files WHERE isfile = 1 AND subdirectory NOT LIKE '%.trn' ORDER BY id;

				OPEN nuker;
				FETCH NEXT FROM nuker INTO @file;

				WHILE @@FETCH_STATUS = 0 BEGIN;

					-- reset per each 'grab':
					SET @errorMessage = NULL;
					SET @outcome = NULL

					SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 0;';

					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN; 

						BEGIN TRY
							EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
							IF @outcome IS NOT NULL 
								SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

						END TRY 
						BEGIN CATCH
							SET @errorMessage = ISNULL(@errorMessage, '') +  N'Error deleting DIFF/FULL Backup with command: [' + ISNULL(@command, '##NOT SET YET##') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
						END CATCH

					END;

					IF @errorMessage IS NOT NULL BEGIN;
						SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

						INSERT INTO @errors ([error_message])
						VALUES (@errorMessage);
					END

					FETCH NEXT FROM nuker INTO @file;
				END;

				CLOSE nuker;
				DEALLOCATE nuker;

		    END
		END;

		FETCH NEXT FROM processor INTO @currentDirectory;
	END

	CLOSE processor;
	DEALLOCATE processor;

	-----------------------------------------------------------------------------
	-- Cleanup:
	IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
		CLOSE nuker;
		DEALLOCATE nuker;
	END;

	-----------------------------------------------------------------------------
	-- Error Reporting:
	DECLARE @errorInfo nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	IF EXISTS (SELECT NULL FROM @errors) BEGIN;
		
		-- format based on output type (output variable or email/error-message), then 'raise, return, or send'... 
		IF @routeInfoAsOutput = 1 BEGIN;
			SELECT @errorInfo = @errorInfo + [error_message] + N', ' FROM @errors ORDER BY error_id;
			SET @errorInfo = LEFT(@errorInfo, LEN(@errorInfo) - 2);

			SET @output = @errorInfo;
		  END
		ELSE BEGIN;

			SELECT @errorInfo = @errorInfo + @tab + N'- ' + [error_message] + @crlf + @crlf
			FROM 
				@errors
			ORDER BY 
				error_id;

			IF (@SendNotifications = 1) AND (@Edition != 'EXPRESS') BEGIN;
				DECLARE @emailSubject nvarchar(2000);
				SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

				SET @errorInfo = N'The following errors were encountered: ' + @crlf + @errorInfo;

				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @errorInfo;				
			END

			-- this is being executed as a stand-alone job (most likely) so... throw the output into the job's history... 
			PRINT @errorInfo;  
			
			RAISERROR(@errorMessage, 16, 1);
			RETURN -100;
		END
	END;

	RETURN 0;
GO



USE [admindb];
GO

IF OBJECT_ID('dbo.backup_databases','P') IS NOT NULL
	DROP PROC dbo.backup_databases;
GO

CREATE PROC dbo.backup_databases 
	@BackupType							sysname,					-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(MAX),				-- { [SYSTEM]|[USER]|name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX) = NULL,		-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX) = NULL,		-- { higher,priority,dbs,*,lower,priority,dbs } - where * represents dbs not specifically specified (which will then be sorted alphabetically
	@BackupDirectory					nvarchar(2000),				-- { path_to_backups }
	@CopyToBackupDirectory				nvarchar(2000) = NULL,		-- { NULL | path_for_backup_copies } 
	@BackupRetention					nvarchar(10),				-- [DOCUMENT HERE]
	@CopyToRetention					nvarchar(10) = NULL,		-- [DITTO: As above, but allows for diff retention settings to be configured for copied/secondary backups.]
	@RemoveFilesBeforeBackup			bit = 0,					-- { 0 | 1 } - when true, then older backups will be removed BEFORE backups are executed.
	@EncryptionCertName					sysname = NULL,				-- Ignored if not specified. 
	@EncryptionAlgorithm				sysname = NULL,				-- Required if @EncryptionCertName is specified. AES_256 is best option in most cases.
	@AddServerNameToSystemBackupPath	bit	= 0,					-- If set to 1, backup path is: @BackupDirectory\<db_name>\<server_name>\
	@AllowNonAccessibleSecondaries		bit = 0,					-- If review of @DatabasesToBackup yields no dbs (in a viable state) for backups, exception thrown - unless this value is set to 1 (for AGs, Mirrored DBs) and then execution terminates gracefully with: 'No ONLINE dbs to backup'.
	@LogSuccessfulOutcomes				bit = 0,					-- By default, exceptions/errors are ALWAYS logged. If set to true, successful outcomes are logged to dba_DatabaseBackup_logs as well.
	@OperatorName						sysname = N'Alerts',
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Database Backups ] ',
	@PrintOnly							bit = 0						-- Instead of EXECUTING commands, they're printed to the console only. 	
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.backup_log', 'U') IS NULL BEGIN
		RAISERROR('S4 Table dbo.backup_log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.check_paths', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.check_paths not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.execute_uncatchable_command', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF (@PrintOnly = 0) AND (@Edition != 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NULLIF(@BackupDirectory, N'') IS NULL BEGIN
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG') BEGIN
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	IF UPPER(@DatabasesToBackup) = N'[READ_FROM_FILESYSTEM]' BEGIN
		RAISERROR('@DatabasesToBackup may NOT be set to the token [READ_FROM_FILESYSTEM] when processing backups.', 16, 1);
		RETURN -9;
	END


-- TODO: I really need to validate retention details HERE... i.e., BEFORE we start running backups. 
--		not sure of the best way to do that - i.e., short of copy/paste of the logic (here and there).

-- honestly, probably makes the most sense to push validation into a scalar UDF. the UDF returns a string/error or NULL (if there's nothing wrong). That way, both sprocs can use the validation details easily. 

	--IF (DATEADD(MINUTE, 0 - @fileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN 
	--	 RAISERROR('Invalid @BackupRetentionHours - greater than or equal to NOW.', 16, 1);
	--	 RETURN -10;
	--END;

	--IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN
	--	IF (DATEADD(MINUTE, 0 - @copyToFileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN
	--		RAISERROR('Invalid @CopyToBackupRetentionHours - greater than or equal to NOW.', 16, 1);
	--		RETURN -11;
	--	END;
	--END;

	IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
		-- make sure the cert name is legit and that an encryption algorithm was specified:
		IF NOT EXISTS (SELECT NULL FROM master.sys.certificates WHERE name = @EncryptionCertName) BEGIN
			RAISERROR('Certificate name specified by @EncryptionCertName is not a valid certificate (not found in sys.certificates).', 16, 1);
			RETURN -15;
		END;

		IF NULLIF(@EncryptionAlgorithm, '') IS NULL BEGIN
			RAISERROR('@EncryptionAlgorithm must be specified when @EncryptionCertName is specified.', 16, 1);
			RETURN -15;
		END;
	END;

	-----------------------------------------------------------------------------
	-- Determine which databases to backup:
	DECLARE @executingSystemDbBackups bit = 0;

	IF UPPER(@DatabasesToBackup) = '[SYSTEM]' BEGIN
		SET @executingSystemDbBackups = 1;
	END; 

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToBackup,
	    @Exclusions = @DatabasesToExclude,
		@Priorities = @Priorities,
	    @Mode = N'BACKUP',
	    @BackupType = @BackupType, 
		@Output = @serialized OUTPUT;

	DECLARE @targetDatabases table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDatabases ([database_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	-- verify that we've got something: 
	IF (SELECT COUNT(*) FROM @targetDatabases) <= 0 BEGIN
		IF @AllowNonAccessibleSecondaries = 1 BEGIN
			-- Because we're dealing with Mirrored DBs, we won't fail or throw an error here. Instead, we'll just report success (with no DBs to backup).
			PRINT 'No ONLINE databases available for backup. BACKUP terminating with success.';
			RETURN 0;

		   END; 
		ELSE BEGIN
			PRINT 'Usage: @DatabasesToBackup = [SYSTEM]|[USER]|dbname1,dbname2,dbname3,etc';
			RAISERROR('No databases specified for backup.', 16, 1);
			RETURN -20;
		END;
	END;

	IF @BackupDirectory = @CopyToBackupDirectory BEGIN
		RAISERROR('@BackupDirectory and @CopyToBackupDirectory can NOT be the same directory.', 16, 1);
		RETURN - 50;
	END;

	-- normalize paths: 
	IF(RIGHT(@BackupDirectory, 1) = '\')
		SET @BackupDirectory = LEFT(@BackupDirectory, LEN(@BackupDirectory) - 1);

	IF(RIGHT(@CopyToBackupDirectory, 1) = '\')
		SET @CopyToBackupDirectory = LEFT(@CopyToBackupDirectory, LEN(@CopyToBackupDirectory) - 1);

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- meta-data:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @operationStart datetime;
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @copyMessage nvarchar(MAX);
	DECLARE @currentOperationID int;

	DECLARE @currentDatabase sysname;
	DECLARE @backupPath nvarchar(2000);
	DECLARE @copyToBackupPath nvarchar(2000);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @serverName sysname;
	DECLARE @extension sysname;
	DECLARE @now datetime;
	DECLARE @timestamp sysname;
	DECLARE @offset sysname;
	DECLARE @backupName sysname;
	DECLARE @encryptionClause nvarchar(2000);
	DECLARE @copyStart datetime;
	DECLARE @outcome varchar(4000);

	DECLARE @command nvarchar(MAX);
	
	-- Begin the backups:
	DECLARE backups CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name] 
	FROM 
		@targetDatabases
	ORDER BY 
		[entry_id];

	OPEN backups;

	FETCH NEXT FROM backups INTO @currentDatabase;
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @errorMessage = NULL;
		SET @copyMessage = NULL;
		SET @outcome = NULL;
		SET @currentOperationID = NULL;

-- TODO: this logic is duplicated in dbo.load_database_names. And, while we NEED this check here ... the logic should be handled in a UDF or something - so'z there aren't 2x locations for bugs/issues/etc. 
		-- start by making sure the current DB (which we grabbed during initialization) is STILL online/accessible (and hasn't failed over/etc.): 
		DECLARE @synchronized table ([database_name] sysname NOT NULL);
		INSERT INTO @synchronized ([database_name])
		SELECT [name] FROM sys.databases WHERE UPPER(state_desc) != N'ONLINE';  -- mirrored dbs that have failed over and are now 'restoring'... 

		-- account for SQL Server 2008/2008 R2 (i.e., pre-HADR):
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @synchronized ([database_name])
			EXEC sp_executesql N'SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc != ''PRIMARY'';'	
		END

		IF @currentDatabase IN (SELECT [database_name] FROM @synchronized) BEGIN
			PRINT 'Skipping database: ' + @currentDatabase + ' because it is no longer available, online, or accessible.';
			GOTO NextDatabase;  -- just 'continue' - i.e., short-circuit processing of this 'loop'... 
		END; 

		-- specify and verify path info:
		IF @executingSystemDbBackups = 1 AND @AddServerNameToSystemBackupPath = 1
			SET @serverName = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 
		ELSE 
			SET @serverName = N'';

		SET @backupPath = @BackupDirectory + N'\' + @currentDatabase + @serverName;
		SET @copyToBackupPath = REPLACE(@backupPath, @BackupDirectory, @CopyToBackupDirectory); 

		SET @operationStart = GETDATE();
		IF (@LogSuccessfulOutcomes = 1) AND (@PrintOnly = 0)  BEGIN
			INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start)
			VALUES(@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart);
			
			SELECT @currentOperationID = SCOPE_IDENTITY();
		END;

		IF @RemoveFilesBeforeBackup = 1 BEGIN
			GOTO RemoveOlderFiles;  -- zip down into the logic for removing files, then... once that's done... we'll get sent back up here (to DoneRemovingFilesBeforeBackup) to execute the backup... 

DoneRemovingFilesBeforeBackup:
		END

		SET @command = 'EXECUTE master.dbo.xp_create_subdir N''' + @backupPath + ''';';

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'CREATEDIR', @result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

			END TRY
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception attempting to validate file path for backup: [' + @backupPath + N']. Error: [' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N']. Backup Filepath non-valid. Cannot continue with backup.';
			END CATCH;
		END;

		-- Normally, it wouldn't make sense to 'bail' on backups simply because we couldn't remove an older file. But, when the directive is to RemoveFilesBEFORE backups, we have to 'bail' to avoid running out of disk space when we can't delete files BEFORE backups. 
		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		-- Create a Backup Name: 
		SET @extension = N'.bak';
		IF @BackupType = N'LOG'
			SET @extension = N'.trn';

		SET @now = GETDATE();
		SET @timestamp = REPLACE(REPLACE(REPLACE(CONVERT(sysname, @now, 120), '-','_'), ':',''), ' ', '_');
		SET @offset = RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),7);

		SET @backupName = @BackupType + N'_' + @currentDatabase + '_backup_' + @timestamp + '_' + @offset + @extension;

		SET @command = N'BACKUP {type} ' + QUOTENAME(@currentDatabase, N'[]') + N' TO DISK = N''' + @backupPath + N'\' + @backupName + ''' 
	WITH 
		{COMPRESSION}{DIFFERENTIAL}{ENCRYPTION} NAME = N''' + @backupName + ''', SKIP, REWIND, NOUNLOAD, CHECKSUM;
	
	';

		IF @BackupType IN (N'FULL', N'DIFF')
			SET @command = REPLACE(@command, N'{type}', N'DATABASE');
		ELSE 
			SET @command = REPLACE(@command, N'{type}', N'LOG');

		IF @Edition IN (N'EXPRESS',N'WEB')
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'');
		ELSE 
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'COMPRESSION, ');

		IF @BackupType = N'DIFF'
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'DIFFERENTIAL, ');
		ELSE 
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'');

		IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
			SET @encryptionClause = ' ENCRYPTION (ALGORITHM = ' + ISNULL(@EncryptionAlgorithm, N'AES_256') + N', SERVER CERTIFICATE = ' + ISNULL(@EncryptionCertName, '') + N'), ';
			SET @command = REPLACE(@command, N'{ENCRYPTION}', @encryptionClause);
		  END;
		ELSE 
			SET @command = REPLACE(@command, N'{ENCRYPTION}','');

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'BACKUP', @result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception executing backup with the following command: [' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH;
		END;

		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		IF @LogSuccessfulOutcomes = 1 BEGIN
			UPDATE dbo.backup_log 
			SET 
				backup_end = GETDATE(),
				backup_succeeded = 1, 
				verification_start = GETDATE()
			WHERE 
				backup_id = @currentOperationID;
		END;

		-----------------------------------------------------------------------------
		-- Kick off the verification:
		SET @command = N'RESTORE VERIFYONLY FROM DISK = N''' + @backupPath + N'\' + @backupName + N''' WITH NOUNLOAD, NOREWIND;';

		IF @PrintOnly = 1 
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				EXEC sys.sp_executesql @command;

				IF @LogSuccessfulOutcomes = 1 BEGIN
					UPDATE dbo.backup_log
					SET 
						verification_end = GETDATE(),
						verification_succeeded = 1
					WHERE
						backup_id = @currentOperationID;
				END;
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception during backup verification for backup of database: ' + @currentDatabase + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';

					UPDATE dbo.backup_log
					SET 
						verification_end = GETDATE(),
						verification_succeeded = 0,
						error_details = @errorMessage
					WHERE
						backup_id = @currentOperationID;

				GOTO NextDatabase;
			END CATCH;
		END;

		-----------------------------------------------------------------------------
		-- Now that the backup (and, optionally/ideally) verification are done, copy the file to a secondary location if specified:
		IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN
			
			SET @copyStart = GETDATE();
			SET @command = 'EXECUTE master.dbo.xp_create_subdir N''' + @copyToBackupPath + ''';';

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN
				BEGIN TRY 
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'CREATEDIR', @result = @outcome OUTPUT;
					
					IF @outcome IS NOT NULL
						SET @copyMessage = @outcome;
				END TRY
				BEGIN CATCH
					SET @copyMessage = N'Unexpected exception attempting to validate COPY_TO file path for backup: [' + @copyToBackupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N'. Detail: [' + ISNULL(@copyMessage, '') + N']';
				END CATCH;
			END;

			-- if we didn't run into validation errors, we can go ahead and try the copyTo process: 
			IF @copyMessage IS NULL BEGIN

				DECLARE @copyOutput TABLE ([output] nvarchar(2000));
				DELETE FROM @copyOutput;

				SET @command = 'EXEC xp_cmdshell ''COPY "' + @backupPath + N'\' + @backupName + '" "' + @copyToBackupPath + '\"''';

				IF @PrintOnly = 1
					PRINT @command;
				ELSE BEGIN
					BEGIN TRY

						INSERT INTO @copyOutput ([output])
						EXEC sys.sp_executesql @command;

						IF NOT EXISTS(SELECT NULL FROM @copyOutput WHERE [output] LIKE '%1 file(s) copied%') BEGIN; -- there was an error, and we didn't copy the file.
							SET @copyMessage = ISNULL(@copyMessage, '') + (SELECT TOP 1 [output] FROM @copyOutput WHERE [output] IS NOT NULL AND [output] NOT LIKE '%0 file(s) copied%') + N' ';
						END;

						IF @LogSuccessfulOutcomes = 1 BEGIN 
							UPDATE dbo.backup_log
							SET 
								copy_succeeded = 1,
								copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
								failed_copy_attempts = 0
							WHERE
								backup_id = @currentOperationID;
						END;
					END TRY
					BEGIN CATCH

						SET @copyMessage = ISNULL(@copyMessage, '') + N'Unexpected error copying backup to [' + @copyToBackupPath + @serverName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
					END CATCH;
				END;
		    END;

			IF @copyMessage IS NOT NULL BEGIN

				IF @currentOperationId IS NULL BEGIN
					-- if we weren't logging successful operations, this operation isn't now a 100% failure, but there are problems, so we need to create a row for reporting/tracking purposes:
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(),0);

					SELECT @currentOperationID = SCOPE_IDENTITY();
				END

				UPDATE dbo.backup_log
				SET 
					copy_succeeded = 0, 
					copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
					failed_copy_attempts = 1, 
					copy_details = @copyMessage
				WHERE 
					backup_id = @currentOperationID;
			END;
		END;

		-----------------------------------------------------------------------------
		-- Remove backups:
		-- Branch into this logic either by means of a GOTO (called from above) or by means of evaluating @RemoveFilesBeforeBackup.... 
		IF @RemoveFilesBeforeBackup = 0 BEGIN;
			
RemoveOlderFiles:
			BEGIN TRY

				IF @PrintOnly = 1 BEGIN;
					PRINT '-- EXEC dbo.remove_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @BackupDirectory + ''', @Retention = ''' + @BackupRetention + ''', @ServerNameInSystemBackupPath = ' + CAST(@AddServerNameToSystemBackupPath AS sysname) + N',  @PrintOnly = 1;';
					
                    EXEC dbo.remove_backup_files
                        @BackupType= @BackupType,
                        @DatabasesToProcess = @currentDatabase,
                        @TargetDirectory = @BackupDirectory,
                        @Retention = @BackupRetention, 
						@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile,

						-- note:
                        @PrintOnly = 1;

				  END;
				ELSE BEGIN;
					SET @outcome = 'OUTPUT';
					DECLARE @Output nvarchar(MAX);
					EXEC dbo.remove_backup_files
						@BackupType= @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@TargetDirectory = @BackupDirectory,
						@Retention = @BackupRetention,
						@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile, 
						@Output = @outcome OUTPUT;

					IF @outcome IS NOT NULL 
						SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + ' ';

				END

				IF NULLIF(@CopyToBackupDirectory,'') IS NOT NULL BEGIN;
				
					IF @PrintOnly = 1 BEGIN;
						PRINT '-- EXEC dbo.remove_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @CopyToBackupDirectory + ''', @Retention = ''' + @CopyToRetention + ''', @ServerNameInSystemBackupPath = ' + CAST(@AddServerNameToSystemBackupPath AS sysname) + N',  @PrintOnly = 1;';
						
						EXEC dbo.remove_backup_files
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@Retention = @CopyToRetention, 
							@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
							@OperatorName = @OperatorName,
							@MailProfileName  = @DatabaseMailProfile,

							--note:
							@PrintOnly = 1;

					  END;
					ELSE BEGIN;
						SET @outcome = 'OUTPUT';
					
						EXEC dbo.remove_backup_files
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@Retention = @CopyToRetention, 
							@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
							@OperatorName = @OperatorName,
							@MailProfileName  = @DatabaseMailProfile,
							@Output = @outcome OUTPUT;					
					
						IF @outcome IS NOT NULL
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
					END
				END
			END TRY 
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + 'Unexpected Error removing backups. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH

			IF @RemoveFilesBeforeBackup = 1 BEGIN;
				IF @errorMessage IS NULL -- there weren't any problems/issues - so keep processing.
					GOTO DoneRemovingFilesBeforeBackup;

				-- otherwise, the remove operations failed, they were set to run FIRST, which means we now might not have enough disk - so we need to 'fail' this operation and move on to the next db... 
				GOTO NextDatabase;
			END
		END

NextDatabase:
		IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
			CLOSE nuker;
			DEALLOCATE nuker;
		END;

		IF NULLIF(@errorMessage,'') IS NOT NULL BEGIN;
			IF @PrintOnly = 1 
				PRINT @errorMessage;
			ELSE BEGIN;
				IF @currentOperationId IS NULL BEGIN;
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, error_details)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(), 0, @errorMessage);
				  END;
				ELSE BEGIN;
					UPDATE dbo.backup_log
					SET 
						error_details = @errorMessage
					WHERE 
						backup_id = @currentOperationID;
				END;
			END;
		END; 

		PRINT '
';

		FETCH NEXT FROM backups INTO @currentDatabase;
	END;

	CLOSE backups;
	DEALLOCATE backups;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- Cleanup:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','backups')) > -1 BEGIN;
		CLOSE backups;
		DEALLOCATE backups;
	END;


	-- MKC:
--			need to add some additional logic/processing here. 
--			a) look for failed copy operations up to X hours ago? 
--		    b) try to re-run them - via dba_sync... or ... via 'raw' roboopy? hmmm. 
--			c) mark any that succeed as done... success. 
--			d) up-tick any that still failed. 
--			e) for any that exceed @maxCopyToRetries - create an error and log it against all previous rows/databases that have failed? hmmm. Yeah... if we've been failing for, say, 45 minutes and sending 'warnings'... then we want to 
--				'call it' for all of the ones that have failed up to this point... and flag them as 'errored out' (might require a new column in the table). OR... maybe it works by me putting something like the following into error details
--				(for ALL rows that have failed up to this point - i.e., previous attempts + the current attempt/iteration):
--				"Attempts to copy backups from @sourcePath to @copyToPath consistently failed from @backupEndTime to @now (duration?) over @MaxSomethingAttempts. No longer attempting to synchronize files - meaning that backups are in jeopardy. Please
--					fix @CopyToPath and, when complete, run dba_syncDbs with such and such arguments? to ensure dbs copied on to secondary...."
--			   because, if that happens... then... the 'history' for backups will show errors (whereas they didn't show/report errors previously - so that covers 'history' - with a summary of when we 'called it'... 
--				and, this covers... the current rows as well. i.e., they'll have errors... which will then get picked up by the logic below. 
--			f) for any true 'errors', those get picked up below. 
--			g) for any non-errors - but failures to copy, there needs to be a 'warning' email sent - with a summary (list) of each db that hasn't copied - current number of attempts, how long it's been, etc. 



	DECLARE @emailErrorMessage nvarchar(MAX);

	IF EXISTS (SELECT NULL FROM dbo.backup_log WHERE execution_id = @executionID AND error_details IS NOT NULL) BEGIN;
		SET @emailErrorMessage = N'The following errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Target Database: [' + [database] + N']. Error: ' + error_details + @crlf + @crlf
		FROM 
			dbo.backup_log
		WHERE 
			execution_id = @executionID
			AND error_details IS NOT NULL 
		ORDER BY 
			backup_id;

	END;

	DECLARE @emailSubject nvarchar(2000);
	IF @emailErrorMessage IS NOT NULL BEGIN;
		
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
		
		IF @Edition != 'EXPRESS' BEGIN;
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;

		-- make sure the sproc FAILS at this point (especially if this is a job). 
		SET @errorMessage = N'One or more operations failed. Execute [ SELECT * FROM [admindb].dbo.backup_log WHERE execution_id = ''' + CAST(@executionID AS nvarchar(36)) + N'''; ] for details.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -100;
	END;

	RETURN 0;
GO



USE admindb;
GO


IF OBJECT_ID('dbo.copy_database','P') IS NOT NULL
	DROP PROC dbo.copy_database;
GO

CREATE PROC dbo.copy_database 
	@SourceDatabaseName			sysname, 
	@TargetDatabaseName			sysname, 
	@BackupsRootPath			sysname	= N'<BackupsRootPath, sysname, E:\SQLBackups>', 
	@DataPath					sysname = N'<DataPath, sysname, D:\SQLData>', 
	@LogPath					sysname = N'<LogPath, sysname, D:\SQLData>',
	@OperatorName				sysname = N'<OperatorName, sysname, Alerts>',
	@MailProfileName			sysname = N'<MailProfileName, sysname, General>'
AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	IF NULLIF(@SourceDatabaseName,'') IS NULL BEGIN
		RAISERROR('@SourceDatabaseName cannot be Empty/NULL. Please specify the name of the database you wish to copy (from).', 16, 1);
		RETURN -1;
	END;

	IF NULLIF(@TargetDatabaseName, '') IS NULL BEGIN
		RAISERROR('@TargetDatabaseName cannot be Empty/NULL. Please specify the name of new database that you want to create (as a copy).', 16, 1);
		RETURN -1;
	END;

	-- Make sure the target database doesn't already exist: 
	IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabaseName) BEGIN
		RAISERROR('@TargetDatabaseName already exists as a database. Either pick another target database name - or drop existing target before retrying.', 16, 1);
		RETURN -5;
	END;

	PRINT N'Attempting to Restore a backup of [' + @SourceDatabaseName + N'] as [' + @TargetDatabaseName + N']';
	
	DECLARE @restored bit = 0;
	DECLARE @errorMessage nvarchar(MAX); 

	BEGIN TRY 
		EXEC admindb.dbo.restore_databases
			@DatabasesToRestore = @SourceDatabaseName,
			@BackupsRootPath = @BackupsRootPath,
			@RestoredRootDataPath = @DataPath,
			@RestoredRootLogPath = @LogPath,
			@RestoredDbNamePattern = @TargetDatabaseName,
			@SkipLogBackups = 0,
			@CheckConsistency = 0, 
			@DropDatabasesAfterRestore = 0,
			@OperatorName = @OperatorName, 
			@MailProfileName = @MailProfileName, 
			@EmailSubjectPrefix = N'[COPY DATABASE OPERATION] : ';

	END TRY
	BEGIN CATCH
		SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception while restoring copy of database. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
	END CATCH

	-- 'sadly', restore_databases does a great job of handling most exceptions during execution - meaning that if we didn't get errors, that doesn't mean there weren't problems. So, let's check up: 
	IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabaseName AND state_desc = N'ONLINE')
		SET @restored = 1; -- success (the db wasn't there at the start of this sproc, and now it is (and it's online). 
	ELSE BEGIN 
		-- then we need to grab the latest error: 
		SELECT @errorMessage = error_details FROM dbo.restore_log WHERE restore_test_id = (
			SELECT MAX(restore_test_id) FROM dbo.restore_log WHERE test_date = GETDATE() AND [database] = @SourceDatabaseName AND restored_as = @TargetDatabaseName);

		IF @errorMessage IS NULL -- hmmm weird:
			SET @errorMessage = N'Unknown error with restore operation - execution did NOT complete as expected. Please Check Email for additional details/insights.';

	END

	IF @errorMessage IS NULL
		PRINT N'Restore Complete. Kicking off backup [' + @TargetDatabaseName + N'].';
	ELSE BEGIN
		PRINT @errorMessage;
		RETURN -10;
	END;
	
	DECLARE @backedUp bit = 0;
	IF @restored = 1 BEGIN
		
		BEGIN TRY
			EXEC admindb.dbo.backup_databases
				@BackupType = N'FULL',
				@DatabasesToBackup = @TargetDatabaseName,
				@BackupDirectory = @BackupsRootPath,
				@BackupRetention = N'24h',
				@OperatorName = @OperatorName, 
				@MailProfileName = @MailProfileName, 
				@EmailSubjectPrefix = N'[COPY DATABASE OPERATION] : ';

			SET @backedUp = 1;
		END TRY
		BEGIN CATCH
			SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception while executing backup of new/copied database. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
		END CATCH

	END;

	IF @restored = 1 AND @backedUp = 1 
		PRINT N'Operation Complete.';
	ELSE BEGIN
		PRINT N'Errors occurred during execution:';
		PRINT @errorMessage;
	END;

	RETURN 0;
GO



----------------------------------------------------------------------------------------
-- Display Versioning info:
SELECT * FROM dbo.version_history;


