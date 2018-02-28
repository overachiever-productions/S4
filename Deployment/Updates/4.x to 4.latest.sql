
/*

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


USE [master];
GO

-- 4.2.0.16786
IF OBJECT_ID('dba_VerifyBackupExecution', 'P') IS NOT NULL BEGIN
	-- 
	PRINT 'Older version of dba_VerifyBackupExecution found. Check for jobs to replace/update... '
	DROP PROC dbo.dba_VerifyBackupExecution;
END;

-- 4.4.1.16836
-- cleanup of any previous/older system objects in the master database:
--IF OBJECT_ID('dbo.dba_traceflags','U') IS NOT NULL
--	DROP TABLE dbo.dba_traceflags;
--GO


USE [admindb];
GO

----------------------------------------------------------------------------------------
-- Latest Rollup/Version:
DECLARE @targetVersion varchar(20) = '4.6.1.16842';
IF NOT EXISTS(SELECT NULL FROM dbo.version_history WHERE version_number = @targetVersion) BEGIN
	
	PRINT N'Deploying v' + @targetVersion + N' Updates.... ';

	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@targetVersion, 'Deployed via Upgrade Script. Integration of 4.4.1.16835 logic (streamlined HA).', GETDATE());

END;


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Deploy latest code / code updates:

---------------------------------------------------------------------------
-- Common Code:
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.check_paths','P') IS NOT NULL
	DROP PROC dbo.check_paths;
GO

CREATE PROC dbo.check_paths 
	@Path				nvarchar(MAX),
	@Exists				bit					OUTPUT
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	SET @Exists = 0;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @command nvarchar(2000) = N'IF EXIST "' + @Path + N'" ECHO EXISTS';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @command;

	IF EXISTS (SELECT NULL FROM @results WHERE [output] = 'EXISTS')
		SET @Exists = 1;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NOT NULL
	DROP PROC dbo.execute_uncatchable_command;
GO

CREATE PROC dbo.execute_uncatchable_command
	@statement				varchar(4000), 
	@filterType				varchar(20), 
	@result					varchar(4000)			OUTPUT	
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	IF @filterType NOT IN ('BACKUP','RESTORE','CREATEDIR','ALTER','DROP','DELETEFILE') BEGIN;
		RAISERROR('Configuration Problem: Non-Supported @filterType value specified.', 16, 1);
		SET @result = 'Configuration Problem with dba_ExecuteAndFilterNonCatchableCommand.';
		RETURN -1;
	END 

	DECLARE @filters table (
		filter_text varchar(200) NOT NULL, 
		filter_type varchar(20) NOT NULL
	);

	INSERT INTO @filters (filter_text, filter_type)
	VALUES 
	-- BACKUP:
	('Processed % pages for database %', 'BACKUP'),
	('BACKUP DATABASE successfully processed % pages in %','BACKUP'),
	('BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %', 'BACKUP'),
	('BACKUP LOG successfully processed % pages in %', 'BACKUP'),
	('The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %', 'BACKUP'),  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 

	-- RESTORE:
	('RESTORE DATABASE successfully processed % pages in %', 'RESTORE'),
	('RESTORE LOG successfully processed % pages in %', 'RESTORE'),
	('Processed % pages for database %', 'RESTORE'),
		-- whenever there's a patch or upgrade...
	('Converting database % from version % to the current version %', 'RESTORE'), 
	('Database % running the upgrade step from version % to version %.', 'RESTORE'),

	-- CREATEDIR:
	('Command(s) completed successfully.', 'CREATEDIR'), 

	-- ALTER:
	('Command(s) completed successfully.', 'ALTER'),
	('Nonqualified transactions are being rolled back. Estimated rollback completion%', 'ALTER'), 

	-- DROP:
	('Command(s) completed successfully.', 'DROP'),

	-- DELETEFILE:
	('Command(s) completed successfully.','DELETEFILE')

	-- add other filters here as needed... 
	;

	DECLARE @delimiter nchar(4) = N' -> ';

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @command varchar(2000) = 'sqlcmd {0} -q "' + REPLACE(@statement, @crlf, ' ') + '"';

	-- Account for named instances:
	DECLARE @serverName sysname = '';
	IF @@SERVICENAME != N'MSSQLSERVER'
		SET @serverName = N' -S .\' + @@SERVICENAME;
		
	SET @command = REPLACE(@command, '{0}', @serverName);

	--PRINT @command;

	INSERT INTO #Results (result)
	EXEC master..xp_cmdshell @command;

	DELETE r
	FROM 
		#Results r 
		INNER JOIN @filters x ON x.filter_type = @filterType AND r.RESULT LIKE x.filter_text;

	IF EXISTS (SELECT NULL FROM #Results WHERE result IS NOT NULL) BEGIN;
		SET @result = '';
		SELECT @result = @result + result + @delimiter FROM #Results WHERE result IS NOT NULL ORDER BY result_id;
		SET @result = LEFT(@result, LEN(@result) - LEN(@delimiter));
	END

	RETURN 0;
GO


-----------------------------------
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


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.split_string','TF') IS NOT NULL
	DROP FUNCTION dbo.split_string;
GO

CREATE FUNCTION dbo.split_string(@serialized nvarchar(MAX), @delimiter nvarchar(20))
RETURNS @Results TABLE (result nvarchar(200))
	--WITH SCHEMABINDING 
AS 
	BEGIN

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )
	
	IF NULLIF(@serialized,'') IS NOT NULL BEGIN

		DECLARE @MaxLength int;
		SET @MaxLength = LEN(@serialized) + 1000;

		SET @serialized = @delimiter + @serialized + @delimiter;

		WITH tally AS ( 
			SELECT TOP (@MaxLength) 
				ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
			FROM sys.all_objects o1 
			CROSS JOIN sys.all_objects o2
		)

		INSERT INTO @Results (result)
		SELECT  RTRIM(LTRIM((SUBSTRING(@serialized, n + 1, CHARINDEX(@delimiter, @serialized, n + 1) - n - 1))))
		FROM tally t
		WHERE n < LEN(@serialized) 
			AND SUBSTRING(@serialized, n, 1) = @delimiter
		ORDER BY t.n;
	END;

	RETURN;
END

GO


-----------------------------------
USE admindb;
GO


IF OBJECT_ID('dbo.load_default_path','FN') IS NOT NULL
	DROP FUNCTION dbo.load_default_path;
GO

CREATE FUNCTION dbo.load_default_path(@PathType sysname) 
RETURNS nvarchar(4000)
AS
BEGIN 
	DECLARE @output sysname;

	IF UPPER(@PathType) = N'BACKUPS'
		SET @PathType = N'BACKUP';

	IF UPPER(@PathType) = N'LOGS'
		SET @PathType = N'LOG';

	DECLARE @valueName nvarchar(4000);

	SET @valueName = CASE @PathType
		WHEN N'BACKUP' THEN N'BackupDirectory'
		WHEN N'DATA' THEN N'DefaultData'
		WHEN N'LOG' THEN N'DefaultLog'
		ELSE N''
	END;

	IF @valueName = N''
		RETURN 'Error. Invalid @PathType Specified.';

	EXEC master..xp_instance_regread
		N'HKEY_LOCAL_MACHINE',  
		N'Software\Microsoft\MSSQLServer\MSSQLServer',  
		@valueName,
		@output OUTPUT, 
		'no_output'

	RETURN @output;
END;
GO





---------------------------------------------------------------------------
-- Backups:
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('[dbo].[remove_backup_files]','P') IS NOT NULL
	DROP PROC [dbo].[remove_backup_files];
GO

CREATE PROC [dbo].[remove_backup_files] 
	@BackupType							sysname,									-- { ALL | FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),								-- { [READ_FROM_FILESYSTEM] | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,						-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000) = N'[DEFAULT]',				-- { path_to_backups }
	@Retention							nvarchar(10),								-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@ServerNameInSystemBackupPath		bit = 0,									-- for mirrored servers/etc.
	@Output								nvarchar(MAX) = NULL OUTPUT,				-- When set to non-null value, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@SendNotifications					bit	= 0,									-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
	@PrintOnly							bit = 0 									-- { 0 | 1 }
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

	IF UPPER(@TargetDirectory) = N'[DEFAULT]' BEGIN
		SELECT @TargetDirectory = dbo.load_default_path('BACKUP');
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


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.backup_databases','P') IS NOT NULL
	DROP PROC dbo.backup_databases;
GO

CREATE PROC dbo.backup_databases 
	@BackupType							sysname,										-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(MAX),									-- { [SYSTEM]|[USER]|name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX) = NULL,							-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX) = NULL,							-- { higher,priority,dbs,*,lower,priority,dbs } - where * represents dbs not specifically specified (which will then be sorted alphabetically
	@BackupDirectory					nvarchar(2000) = N'[DEFAULT]',					-- { [DEFAULT] | path_to_backups }
	@CopyToBackupDirectory				nvarchar(2000) = NULL,							-- { NULL | path_for_backup_copies } 
	@BackupRetention					nvarchar(10),									-- [DOCUMENT HERE]
	@CopyToRetention					nvarchar(10) = NULL,							-- [DITTO: As above, but allows for diff retention settings to be configured for copied/secondary backups.]
	@RemoveFilesBeforeBackup			bit = 0,										-- { 0 | 1 } - when true, then older backups will be removed BEFORE backups are executed.
	@EncryptionCertName					sysname = NULL,									-- Ignored if not specified. 
	@EncryptionAlgorithm				sysname = NULL,									-- Required if @EncryptionCertName is specified. AES_256 is best option in most cases.
	@AddServerNameToSystemBackupPath	bit	= 0,										-- If set to 1, backup path is: @BackupDirectory\<db_name>\<server_name>\
	@AllowNonAccessibleSecondaries		bit = 0,										-- If review of @DatabasesToBackup yields no dbs (in a viable state) for backups, exception thrown - unless this value is set to 1 (for AGs, Mirrored DBs) and then execution terminates gracefully with: 'No ONLINE dbs to backup'.
	@LogSuccessfulOutcomes				bit = 0,										-- By default, exceptions/errors are ALWAYS logged. If set to true, successful outcomes are logged to dba_DatabaseBackup_logs as well.
	@OperatorName						sysname = N'Alerts',
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Database Backups ] ',
	@PrintOnly							bit = 0											-- Instead of EXECUTING commands, they're printed to the console only. 	
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

	IF UPPER(@BackupDirectory) = N'[DEFAULT]' BEGIN
		SELECT @BackupDirectory = dbo.load_default_path('BACKUP');
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



---------------------------------------------------------------------------
-- Restores:
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.restore_databases','P') IS NOT NULL
	DROP PROC dbo.restore_databases;
GO

CREATE PROC dbo.restore_databases 
	@DatabasesToRestore				nvarchar(MAX),
	@DatabasesToExclude				nvarchar(MAX) = NULL,
	@Priorities						nvarchar(MAX) = NULL,
	@BackupsRootPath				nvarchar(MAX) = N'[DEFAULT]',
	@RestoredRootDataPath			nvarchar(MAX) = N'[DEFAULT]',
	@RestoredRootLogPath			nvarchar(MAX) = N'[DEFAULT]',
	@RestoredDbNamePattern			nvarchar(40) = N'{0}_test',
	@AllowReplace					nchar(7) = NULL,		-- NULL or the exact term: N'REPLACE'...
	@SkipLogBackups					bit = 0,
	@CheckConsistency				bit = 1,
	@DropDatabasesAfterRestore		bit = 0,				-- Only works if set to 1, and if we've RESTORED the db in question. 
	@MaxNumberOfFailedDrops			int = 1,				-- number of failed DROP operations we'll tolerate before early termination.
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[RESTORE TEST] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN
		RAISERROR('S4 Table dbo.restore_log not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;
	
	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.check_paths', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.check_paths not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16, 1);
		RETURN -1;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -2;
		 END;
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -2;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -2;
		END; 
	END;

	IF @MaxNumberOfFailedDrops <= 0 BEGIN
		RAISERROR('@MaxNumberOfFailedDrops must be set to a value of 1 or higher.', 16, 1);
		RETURN -6;
	END;

	IF NULLIF(@AllowReplace, '') IS NOT NULL AND UPPER(@AllowReplace) != N'REPLACE' BEGIN
		RAISERROR('The @AllowReplace switch must be set to NULL or the exact term N''REPLACE''.', 16, 1);
		RETURN -4;
	END;

	IF @AllowReplace IS NOT NULL AND @DropDatabasesAfterRestore = 1 BEGIN
		RAISERROR('Databases cannot be explicitly REPLACED and DROPPED after being replaced. If you wish DBs to be restored (on a different server for testing) with SAME names as PROD, simply leave suffix empty (but not NULL) and leave @AllowReplace NULL.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@DatabasesToRestore) IN (N'[SYSTEM]', N'[USER]') BEGIN
		RAISERROR('The tokens [SYSTEM] and [USER] cannot be used to specify which databases to restore via dba_RestoreDatabases. Use either [READ_FROM_FILESYSTEM] (plus any exclusions via @DatabasesToExclude), or specify a comma-delimited list of databases to restore.', 16, 1);
		RETURN -10;
	END;

	IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
		SET @DatabasesToExclude = NULL;

	IF (@DatabasesToExclude IS NOT NULL) AND (UPPER(@DatabasesToRestore) != N'[READ_FROM_FILESYSTEM]') BEGIN
		RAISERROR('@DatabasesToExclude can ONLY be specified when @DatabasesToRestore is defined as the [READ_FROM_FILESYSTEM] token. Otherwise, if you don''t want a database restored, don''t specify it in the @DatabasesToRestore ''list''.', 16, 1);
		RETURN -20;
	END;

	IF (NULLIF(@RestoredDbNamePattern,'')) IS NULL BEGIN
		RAISERROR('@RestoredDbNamePattern can NOT be NULL or empty. It MAY also contain the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname'').', 16, 1);
		RETURN -22;
	END;

	-- 'Global' Variables:
	DECLARE @isValid bit;
	DECLARE @earlyTermination nvarchar(MAX) = N'';
	DECLARE @emailErrorMessage nvarchar(MAX);
	DECLARE @emailSubject nvarchar(300);
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @restoreSucceeded bit;
	DECLARE @failedDrops int = 0;

	-- Allow for default paths:
	IF UPPER(@BackupsRootPath) = N'[DEFAULT]' BEGIN
		SELECT @BackupsRootPath = dbo.load_default_path('BACKUP');
	END;

	IF UPPER(@RestoredRootDataPath) = N'[DEFAULT]' BEGIN
		SELECT @RestoredRootDataPath = dbo.load_default_path('DATA');
	END;

	IF UPPER(@RestoredRootLogPath) = N'[DEFAULT]' BEGIN
		SELECT @RestoredRootLogPath = dbo.load_default_path('LOG');
	END;

	-- Verify Paths: 
	EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END
	
	EXEC dbo.check_paths @RestoredRootDataPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@RestoredRootDataPath (' + @RestoredRootDataPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END

	EXEC dbo.check_paths @RestoredRootLogPath, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		SET @earlyTermination = N'@RestoredRootLogPath (' + @RestoredRootLogPath + N') is invalid - restore operations terminated prematurely.';
		GOTO FINALIZE;
	END

	-----------------------------------------------------------------------------
	-- Construct list of databases to restore:
	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToRestore,         
	    @Exclusions = @DatabasesToExclude,		-- only works if [READ_FROM_FILESYSTEM] is specified for @Input... 
		@Priorities = @Priorities,
	    @Mode = N'RESTORE',
	    @TargetDirectory = @BackupsRootPath, 
		@Output = @serialized OUTPUT;

	DECLARE @dbsToRestore table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @dbsToRestore ([database_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	IF NOT EXISTS (SELECT NULL FROM @dbsToRestore) BEGIN;
		RAISERROR('No Databases Specified to Restore. Please Check inputs for @DatabasesToRestore + @DatabasesToExclude and retry.', 16, 1);
		RETURN -20;
	END

	IF @PrintOnly = 1 BEGIN;
		PRINT '-- Databases To Attempt Restore Against: ' + @serialized;
	END

	DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@dbsToRestore
	WHERE
		LEN([database_name]) > 0
	ORDER BY 
		entry_id;

	DECLARE @databaseToRestore sysname;
	DECLARE @restoredName sysname;

	DECLARE @fullRestoreTemplate nvarchar(MAX) = N'RESTORE DATABASE [{0}] FROM DISK = N''{1}'' WITH {move},{replace} NORECOVERY;'; 
	DECLARE @move nvarchar(MAX);
	DECLARE @restoreLogId int;
	DECLARE @sourcePath nvarchar(500);
	DECLARE @statusDetail nvarchar(500);
	DECLARE @pathToDatabaseBackup nvarchar(600);
	DECLARE @outcome varchar(4000);

	DECLARE @temp TABLE (
		[id] int IDENTITY(1,1), 
		[output] varchar(500)
	);

	-- Assemble a list of dbs (if any) that were NOT dropped during the last execution (only) - so that we can drop them before proceeding. 
	DECLARE @NonDroppedFromPreviousExecution table( 
		[Database] sysname NOT NULL, 
		RestoredAs sysname NOT NULL
	);

	DECLARE @LatestBatch uniqueidentifier;
	SELECT @LatestBatch = (SELECT TOP 1 execution_id FROM dbo.restore_log ORDER BY restore_test_id DESC);

	INSERT INTO @NonDroppedFromPreviousExecution ([Database], RestoredAs)
	SELECT [database], [restored_as]
	FROM dbo.restore_log 
	WHERE execution_id = @LatestBatch
		AND [dropped] = 'NOT-DROPPED'
		AND [restored_as] IN (SELECT name FROM sys.databases WHERE UPPER(state_desc) = 'RESTORING');  -- make sure we're only targeting DBs in the 'restoring' state too. 

	IF @CheckConsistency = 1 BEGIN
		IF OBJECT_ID('tempdb..##DBCC_OUTPUT') IS NOT NULL 
			DROP TABLE ##DBCC_OUTPUT;

		CREATE TABLE ##DBCC_OUTPUT(
				RowID int IDENTITY(1,1) NOT NULL, 
				Error int NULL,
				[Level] int NULL,
				[State] int NULL,
				MessageText nvarchar(2048) NULL,
				RepairLevel nvarchar(22) NULL,
				[Status] int NULL,
				[DbId] int NULL, -- was smallint in SQL2005
				DbFragId int NULL,      -- new in SQL2012
				ObjectId int NULL,
				IndexId int NULL,
				PartitionId bigint NULL,
				AllocUnitId bigint NULL,
				RidDbId smallint NULL,  -- new in SQL2012
				RidPruId smallint NULL, -- new in SQL2012
				[File] smallint NULL,
				[Page] int NULL,
				Slot int NULL,
				RefDbId smallint NULL,  -- new in SQL2012
				RefPruId smallint NULL, -- new in SQL2012
				RefFile smallint NULL,
				RefPage int NULL,
				RefSlot int NULL,
				Allocation smallint NULL
		);
	END

	CREATE TABLE #FileList (
		LogicalName nvarchar(128) NOT NULL, 
		PhysicalName nvarchar(260) NOT NULL,
		[Type] CHAR(1) NOT NULL, 
		FileGroupName nvarchar(128) NULL, 
		Size numeric(20,0) NOT NULL, 
		MaxSize numeric(20,0) NOT NULL, 
		FileID bigint NOT NULL, 
		CreateLSN numeric(25,0) NOT NULL, 
		DropLSN numeric(25,0) NULL, 
		UniqueId uniqueidentifier NOT NULL, 
		ReadOnlyLSN numeric(25,0) NULL, 
		ReadWriteLSN numeric(25,0) NULL, 
		BackupSizeInBytes bigint NOT NULL, 
		SourceBlockSize int NOT NULL, 
		FileGroupId int NOT NULL, 
		LogGroupGUID uniqueidentifier NULL, 
		DifferentialBaseLSN numeric(25,0) NULL, 
		DifferentialBaseGUID uniqueidentifier NOT NULL, 
		IsReadOnly bit NOT NULL, 
		IsPresent bit NOT NULL, 
		TDEThumbprint varbinary(32) NULL
	);

	-- SQL Server 2016 adds SnapshotURL of nvarchar(360) for azure stuff:
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE x.ProductMajorVersion = '13') BEGIN;
		ALTER TABLE #FileList ADD SnapshotURL nvarchar(360) NULL;
	END

	DECLARE @command nvarchar(2000);

	OPEN restorer;

	FETCH NEXT FROM restorer INTO @databaseToRestore;
	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @statusDetail = NULL; -- reset every 'loop' through... 
		SET @restoredName = REPLACE(@RestoredDbNamePattern, N'{0}', @databaseToRestore);
		IF (@restoredName = @databaseToRestore) AND (@RestoredDbNamePattern != '{0}') -- then there wasn't a {0} token - so set @restoredName to @RestoredDbNamePattern
			SET @restoredName = @RestoredDbNamePattern;  -- which seems odd, but if they specified @RestoredDbNamePattern = 'Production2', then that's THE name they want...

		IF @PrintOnly = 0 BEGIN;
			INSERT INTO dbo.restore_log (execution_id, [database], restored_as, restore_start, error_details)
			VALUES (@executionID, @databaseToRestore, @restoredName, GETUTCDATE(), '#UNKNOWN ERROR#');

			SELECT @restoreLogId = SCOPE_IDENTITY();
		END

		-- Verify Path to Source db's backups:
		SET @sourcePath = @BackupsRootPath + N'\' + @databaseToRestore;
		EXEC dbo.check_paths @sourcePath, @isValid OUTPUT;
		IF @isValid = 0 BEGIN 
			SET @statusDetail = N'The backup path: ' + @sourcePath + ' is invalid;';
			GOTO NextDatabase;
		END

		-- Determine how to respond to an attempt to overwrite an existing database (i.e., is it explicitly confirmed or... should we throw an exception).
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN;
			
			-- if this is a 'failure' from a previous execution, drop the DB and move on, otherwise, make sure we are explicitly configured to REPLACE. 
			IF EXISTS (SELECT NULL FROM @NonDroppedFromPreviousExecution WHERE [Database] = @databaseToRestore AND RestoredAs = @restoredName) BEGIN;
				SET @command = N'DROP DATABASE [' + @restoredName + N'];';
				
				EXEC dbo.execute_uncatchable_command @command, 'DROP', @result = @outcome OUTPUT;
				SET @statusDetail = @outcome;

				IF @statusDetail IS NOT NULL BEGIN;
					GOTO NextDatabase;
				END
			  END
			ELSE BEGIN;
				IF ISNULL(@AllowReplace, '') != N'REPLACE' BEGIN;
					SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
					GOTO NextDatabase;
				END
			END
		END

		-- Enumerate the files and ensure we've got backups:
		--SET @command = N'dir "' + @sourcePath + N'\" /B /A-D /OD';

		--IF @PrintOnly = 1 BEGIN;
		--	PRINT N'-- xp_cmdshell ''' + @command + ''';';
		--END
		
		DECLARE @fileList nvarchar(MAX);

EXEC load_backup_files
	@SourcePath = 'D:\SQLBackups\TESTS\Billing', 
	@Mode = 'ignored',
	@Output = @fileList OUTPUT;


--SELECT @fileList;
INSERT INTO @temp ([output])
SELECT [result] FROM dbo.split_string(@fileList, N',');


SELECT * FROM @temp;

RETURN;



		INSERT INTO @temp ([output])
		EXEC master..xp_cmdshell @command;
		DELETE FROM @temp WHERE [output] IS NULL AND [output] NOT LIKE '%' + @databaseToRestore + '%';  -- remove 'empty' entries and any backups for databases OTHER than target.

		IF NOT EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'FULL%') BEGIN 
			IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE '%access%denied%') 
				SET @statusDetail = N'Access to path "' + @sourcePath + N'" is denied.';
			ELSE 
				SET @statusDetail = N'No FULL backups found for database [' + @databaseToRestore + N'] found in "' + @sourcePath + N'".';
			
			GOTO NextDatabase;	
		END

		-- Find the most recent FULL to 'seed' the restore;
		DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE 'FULL%');
		SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'FULL%';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- FULL Backup found at: ' + @pathToDatabaseBackup;
		END

		-- Query file destinations:
		SET @move = N'';
		SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

		IF @PrintOnly = 1 BEGIN;
			PRINT N'-- ' + @command;
		END

		BEGIN TRY 
			DELETE FROM #FileList;
			INSERT INTO #FileList -- shorthand syntax is usually bad, but... whatever. 
			EXEC sys.sp_executesql @command;
		END TRY
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Error Restoring FileList: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			
			GOTO NextDatabase;
		END CATCH
	
		-- Make sure we got some files (i.e. RESTORE FILELIST doesn't always throw exceptions if the path you send it sucks:
		IF ((SELECT COUNT(*) FROM #FileList) < 2) BEGIN;
			SET @statusDetail = N'The backup located at "' + @pathToDatabaseBackup + N'" is invalid, corrupt, or does not contain a viable FULL backup.';
			
			GOTO NextDatabase;
		END 
		
		-- Map File Destinations:
		DECLARE @LogicalFileName sysname, @FileId bigint, @Type char(1);
		DECLARE mover CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			LogicalName, FileID, [Type]
		FROM 
			#FileList
		ORDER BY 
			FileID;

		OPEN mover; 
		FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;

		WHILE @@FETCH_STATUS = 0 BEGIN 

			SET @move = @move + N'MOVE ''' + @LogicalFileName + N''' TO ''' + CASE WHEN @FileId = 2 THEN @RestoredRootLogPath ELSE @RestoredRootDataPath END + N'\' + @restoredName + '.';
			IF @FileId = 1
				SET @move = @move + N'mdf';
			IF @FileId = 2
				SET @move = @move + N'ldf';
			IF @FileId NOT IN (1, 2)
				SET @move = @move + N'ndf';

			SET @move = @move + N''', '

			FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;
		END

		CLOSE mover;
		DEALLOCATE mover;

		SET @move = LEFT(@move, LEN(@move) - 1); -- remove the trailing ", "... 

		-- IF we're going to allow an explicit REPLACE, start by putting the target DB into SINGLE_USER mode: 
		IF @AllowReplace = N'REPLACE' BEGIN;
			
			-- only attempt to set to single-user mode if ONLINE (i.e., if somehow stuck in restoring... don't bother, just replace):
			IF EXISTS(SELECT NULL FROM sys.databases WHERE name = @restoredName AND state_desc = 'ONLINE') BEGIN;

				BEGIN TRY 
					SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName, N'[]') + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';

					IF @PrintOnly = 1 BEGIN;
						PRINT @command;
					  END
					ELSE BEGIN
						SET @outcome = NULL;
						EXEC dbo.execute_uncatchable_command @command, 'ALTER', @result = @outcome OUTPUT;
						SET @statusDetail = @outcome;
					END

					-- give things just a second to 'die down':
					WAITFOR DELAY '00:00:02';

				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while setting target database: "' + @restoredName + N'" into SINGLE_USER mode to allow explicit REPLACE operation. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH

				IF @statusDetail IS NOT NULL
				GOTO NextDatabase;
			END
		END

		-- Set up the Restore Command and Execute:
		SET @command = REPLACE(@fullRestoreTemplate, N'{0}', @restoredName);
		SET @command = REPLACE(@command, N'{1}', @pathToDatabaseBackup);
		SET @command = REPLACE(@command, N'{move}', @move);

		-- Otherwise, address the REPLACE command in our RESTORE @command: 
		IF @AllowReplace = N'REPLACE'
			SET @command = REPLACE(@command, N'{replace}', N' REPLACE, ');
		ELSE 
			SET @command = REPLACE(@command, N'{replace}',  N'');

		BEGIN TRY 
			IF @PrintOnly = 1 BEGIN;
				PRINT @command;
			  END
			ELSE BEGIN;
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END
		END TRY 
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
		END CATCH

		IF @statusDetail IS NOT NULL BEGIN;
			GOTO NextDatabase;
		END

		-- Restore any DIFF backups as needed:
		IF EXISTS (SELECT NULL FROM @temp WHERE [output] LIKE 'DIFF%') BEGIN;
			DELETE FROM @temp WHERE id < (SELECT MAX(id) FROM @temp WHERE [output] LIKE N'DIFF%');

			SELECT @pathToDatabaseBackup = @sourcePath + N'\' + [output] FROM @temp WHERE [output] LIKE 'DIFF%';

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			BEGIN TRY
				IF @PrintOnly = 1 BEGIN;
					PRINT @command;
				  END
				ELSE BEGIN;
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END
			END TRY
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH

			IF @statusDetail IS NOT NULL BEGIN;
				GOTO NextDatabase;
			END
		END

		-- Restore any LOG backups if specified and if present:
		IF @SkipLogBackups = 0 BEGIN;
			DECLARE logger CURSOR LOCAL FAST_FORWARD FOR 
			SELECT [output] FROM @temp WHERE [output] LIKE 'LOG%' ORDER BY id ASC;			

			OPEN logger;
			FETCH NEXT FROM logger INTO @pathToDatabaseBackup;

			WHILE @@FETCH_STATUS = 0 BEGIN;
				SET @command = N'RESTORE LOG ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @sourcePath + N'\' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';
				
				BEGIN TRY 
					IF @PrintOnly = 1 BEGIN;
						PRINT @command;
					  END
					ELSE BEGIN;
						SET @outcome = NULL;
						EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

						SET @statusDetail = @outcome;
					END
				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					-- this has to be closed/deallocated - or we'll run into it on the 'next' database/pass.
					IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
						CLOSE logger;
						DEALLOCATE logger;
					END
					
				END CATCH

				IF @statusDetail IS NOT NULL BEGIN;
					GOTO NextDatabase;
				END

				FETCH NEXT FROM logger INTO @pathToDatabaseBackup;
			END

			CLOSE logger;
			DEALLOCATE logger;
		END

		-- Recover the database:
		SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' WITH RECOVERY;';

		BEGIN TRY
			IF @PrintOnly = 1 BEGIN;
				PRINT @command;
			  END
			ELSE BEGIN
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

				SET @statusDetail = @outcome;
			END;
		END TRY	
		BEGIN CATCH
			SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
		END CATCH

		IF @statusDetail IS NOT NULL BEGIN;
			GOTO NextDatabase;
		END

		-- If we've made it here, then we need to update logging/meta-data:
		IF @PrintOnly = 0 BEGIN;
			UPDATE dbo.restore_log 
			SET 
				restore_succeeded = 1, 
				restore_end = GETUTCDATE(), 
				error_details = NULL
			WHERE 
				restore_test_id = @restoreLogId;
		END

		-- Run consistency checks if specified:
		IF @CheckConsistency = 1 BEGIN;

			SET @command = N'DBCC CHECKDB([' + @restoredName + N']) WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;'; -- outputting data for review/analysis. 

			IF @PrintOnly = 0 BEGIN 
				UPDATE dbo.restore_log
				SET 
					consistency_start = GETUTCDATE(),
					consistency_succeeded = 0, 
					error_details = '#UNKNOWN ERROR CHECKING CONSISTENCY#'
				WHERE
					restore_test_id = @restoreLogId;
			END

			BEGIN TRY 
				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN 
					DELETE FROM ##DBCC_OUTPUT;
					INSERT INTO ##DBCC_OUTPUT (Error, [Level], [State], MessageText, RepairLevel, [Status], [DbId], DbFragId, ObjectId, IndexId, PartitionId, AllocUnitId, RidDbId, RidPruId, [File], [Page], Slot, RefDbId, RefPruId, RefFile, RefPage, RefSlot, Allocation)
					EXEC sp_executesql @command; 

					IF EXISTS (SELECT NULL FROM ##DBCC_OUTPUT) BEGIN; -- consistency errors: 
						SET @statusDetail = N'CONSISTENCY ERRORS DETECTED against database ' + QUOTENAME(@restoredName, N'[]') + N'. Details: ' + @crlf;
						SELECT @statusDetail = @statusDetail + MessageText + @crlf FROM ##DBCC_OUTPUT ORDER BY RowID;

						UPDATE dbo.restore_log
						SET 
							consistency_end = GETUTCDATE(),
							consistency_succeeded = 0,
							error_details = @statusDetail
						WHERE 
							restore_test_id = @restoreLogId;

					  END
					ELSE BEGIN; -- there were NO errors:
						UPDATE dbo.restore_log
						SET
							consistency_end = GETUTCDATE(),
							consistency_succeeded = 1, 
							error_details = NULL
						WHERE 
							restore_test_id = @restoreLogId;

					END
				END

			END TRY	
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while running consistency checks. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				GOTO NextDatabase;
			END CATCH

		END

		-- Drop the database if specified and if all SAFE drop precautions apply:
		IF @DropDatabasesAfterRestore = 1 BEGIN;
			
			-- Make sure we can/will ONLY restore databases that we've restored in this session. 
			SELECT @restoreSucceeded = restore_succeeded FROM dbo.restore_log WHERE restored_as = @restoredName AND execution_id = @executionID;

			IF @PrintOnly = 1 AND @DropDatabasesAfterRestore = 1
				SET @restoreSucceeded = 1; 
			
			IF ISNULL(@restoreSucceeded, 0) = 0 BEGIN 
				-- We can't drop this database.
				SET @failedDrops = @failedDrops + 1;

				UPDATE dbo.restore_log
				SET 
					[dropped] = 'ERROR', 
					error_details = error_details + @crlf + '(NOTE: DROP was configured but SKIPPED due to ERROR state.)'
				WHERE 
					restore_test_id = @restoreLogId;

				GOTO NextDatabase;
			END

			IF @restoreSucceeded = 1 BEGIN; -- this is a db we restored in this 'session' - so we can drop it:
				SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName, N'[]') + N';';

				BEGIN TRY 
					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN;
						UPDATE dbo.restore_log 
						SET 
							[dropped] = N'ATTEMPTED'
						WHERE 
							restore_test_id = @restoreLogId;

						EXEC sys.sp_executesql @command;

						IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN;
							SET @failedDrops = @failedDrops;
							SET @statusDetail = N'Executed command to DROP database [' + @restoredName + N']. No exceptions encountered, but database still in place POST-DROP.';

							GOTO NextDatabase;
						  END
						ELSE 
							UPDATE dbo.restore_log
							SET 
								dropped = 'DROPPED'
							WHERE 
								restore_test_id = @restoreLogId;
					END

				END TRY 
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while attempting to DROP database [' + @restoredName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					SET @failedDrops = @failedDrops + 1;

					UPDATE dbo.restore_log
					SET 
						dropped = 'ERROR'
					WHERE 
						restore_test_id = @restoredName;

					GOTO NextDatabase;
				END CATCH
			END

		  END
		ELSE BEGIN;
			UPDATE dbo.restore_log 
			SET 
				dropped = 'NOT-DROPPED'
			WHERE
				restore_test_id = @restoreLogId;
		END

		PRINT N'-- Operations for database [' + @restoredName + N'] completed successfully.' + @crlf + @crlf;

		-- If we made this this far, there have been no errors... and we can drop through into processing the next database... 
NextDatabase:

		DELETE FROM @temp; -- always make sure to clear the list of files handled for the previous database... 

		-- Record any status details as needed:
		IF @statusDetail IS NOT NULL BEGIN;

			IF @PrintOnly = 1 BEGIN;
				PRINT N'ERROR: ' + @statusDetail;
			  END
			ELSE BEGIN;
				UPDATE dbo.restore_log
				SET 
					restore_end = GETUTCDATE(),
					error_details = @statusDetail
				WHERE 
					restore_test_id = @restoreLogId;
			END

			PRINT N'-- Operations for database [' + @restoredName + N'] failed.' + @crlf + @crlf;
		END

		-- Check-up on total number of 'failed drops':
		IF @failedDrops >= @MaxNumberOfFailedDrops BEGIN;
			-- we're done - no more processing (don't want to risk running out of space with too many restore operations.
			SET @earlyTermination = N'Max number of databases that could NOT be dropped after restore/testing was reached. Early terminatation forced to reduce risk of causing storage problems.';
			GOTO FINALIZE;
		END

		FETCH NEXT FROM restorer INTO @databaseToRestore;
	END

	-----------------------------------------------------------------------------
FINALIZE:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN;
		CLOSE restorer;
		DEALLOCATE restorer;
	END

	IF (SELECT CURSOR_STATUS('local','mover')) > -1 BEGIN;
		CLOSE mover;
		DEALLOCATE mover;
	END

	IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
		CLOSE logger;
		DEALLOCATE logger;
	END

	-- Assemble details on errors - if there were any (i.e., logged errors OR any reason for early termination... 
	IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN;

		SET @emailErrorMessage = N'The following Errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Source Database: [' + [database] + N']. Attempted to Restore As: [' + restored_as + N']. Error: ' + error_details + @crlf + @crlf
		FROM 
			dbo.restore_log
		WHERE 
			execution_id = @executionID
			AND error_details IS NOT NULL
		ORDER BY 
			restore_test_id;

		-- notify too that we stopped execution due to early termination:
		IF NULLIF(@earlyTermination, '') IS NOT NULL BEGIN;
			SET @emailErrorMessage = @emailErrorMessage + @tab + N'- ' + @earlyTermination;
		END
	END
	
	IF @emailErrorMessage IS NOT NULL BEGIN;

		IF @PrintOnly = 1
			PRINT N'ERROR: ' + @emailErrorMessage;
		ELSE BEGIN;
			SET @emailSubject = @emailSubjectPrefix + N' - ERROR';

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END
	END 

	RETURN 0;
GO


-----------------------------------
USE admindb;
GO


IF OBJECT_ID('dbo.copy_database','P') IS NOT NULL
	DROP PROC dbo.copy_database;
GO

CREATE PROC dbo.copy_database 
	@SourceDatabaseName			sysname, 
	@TargetDatabaseName			sysname, 
	@BackupsRootDirectory		nvarchar(2000)	= N'[DEFAULT]', 
	@CopyToBackupDirectory		nvarchar(2000)	= NULL,
	@DataPath					sysname			= N'[DEFAULT]', 
	@LogPath					sysname			= N'[DEFAULT]',
	@OperatorName				sysname			= N'Alerts',
	@MailProfileName			sysname			= N'General'
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

	-- Allow for default paths:
	IF UPPER(@BackupsRootDirectory) = N'[DEFAULT]' BEGIN
		SELECT @BackupsRootDirectory = dbo.load_default_path('BACKUP');
	END;

	IF UPPER(@DataPath) = N'[DEFAULT]' BEGIN
		SELECT @DataPath = dbo.load_default_path('DATA');
	END;

	IF UPPER(@LogPath) = N'[DEFAULT]' BEGIN
		SELECT @LogPath = dbo.load_default_path('LOG');
	END;

	DECLARE @retention nvarchar(10) = N'110w'; -- if we're creating/copying a new db, there shouldn't be ANY backups. Just in case, give it a very wide berth... 
	DECLARE @copyToRetention nvarchar(10) = NULL;
	IF @CopyToBackupDirectory IS NOT NULL 
		SET @copyToRetention = @retention;

	PRINT N'Attempting to Restore a backup of [' + @SourceDatabaseName + N'] as [' + @TargetDatabaseName + N']';
	
	DECLARE @restored bit = 0;
	DECLARE @errorMessage nvarchar(MAX); 

	BEGIN TRY 
		EXEC admindb.dbo.restore_databases
			@DatabasesToRestore = @SourceDatabaseName,
			@BackupsRootPath = @BackupsRootDirectory,
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
	
	-- Make sure the DB owner is set correctly: 
	DECLARE @sql nvarchar(MAX) = N'ALTER AUTHORIZATION ON DATABASE::[' + @TargetDatabaseName + N'] TO sa;';
	EXEC sp_executesql @sql;

	DECLARE @backedUp bit = 0;
	IF @restored = 1 BEGIN
		
		BEGIN TRY
			EXEC admindb.dbo.backup_databases
				@BackupType = N'FULL',
				@DatabasesToBackup = @TargetDatabaseName,
				@BackupDirectory = @BackupsRootDirectory,
				@BackupRetention = @retention,
				@CopyToBackupDirectory = @CopyToBackupDirectory, 
				@CopyToRetention = @copyToRetention,
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
	


---------------------------------------------------------------------------
--- Monitoring
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_backup_execution','P') IS NOT NULL
	DROP PROC dbo.verify_backup_execution;
GO

CREATE PROC dbo.verify_backup_execution 
	@DatabasesToCheck					nvarchar(MAX),
	@DatabasesToExclude					nvarchar(MAX)		= NULL,
	@FullBackupAlertThresholdHours		int, 
	@LogBackupAlertThresholdMinutes		int,
	@MonitoredJobs						nvarchar(MAX)		= NULL, 
	@AllowNonAccessibleSecondaries		bit					= 0,
	@MinimumElapsedSecondsToConsider	int					= 60,   -- if a specified backup job has been running < @MinimumElapsedSecondsToConsider, then there's NO reason to raise an alert. 
	@MaximumElapsedSecondsToIgnore		int					= 300,			-- if a backup job IS running longer than normal, but is STILL under @MaximumElapsedSecondsToIgnore, then there's no reason to raise an alert. 
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[Database Backups - Failed Checkups] ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )
	-- To determine current/deployed version, execute the following: SELECT CAST([value] AS sysname) [Version] FROM master.sys.extended_properties WHERE major_id = OBJECT_ID('dbo.dba_DatabaseBackups_Log') AND [name] = 'Version';	

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 

	-- Operator Checks:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalild Operator Name Specified.', 16, 1);
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

	-----------------------------------------------------------------------------

	DECLARE @outputs table (
		output_id int IDENTITY(1,1) NOT NULL, 
		[type] sysname NOT NULL, -- warning or error 
		[message] nvarchar(MAX)
	);

	DECLARE @errorMessage nvarchar(MAX) = '';

	-----------------------------------------------------------------------------
	-- Determine which databases to check:
	DECLARE @databaseToCheckForFullBackups table (
		[name] sysname NOT NULL
	);

	DECLARE @databaseToCheckForLogBackups table (
		[name] sysname NOT NULL
	);

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names 
		@Input = @DatabasesToCheck,
		@Exclusions = @DatabasesToExclude, 
		@Priorities = NULL, 
		@Mode = N'VERIFY', 
		@BackupType = N'FULL',
		@Output = @serialized OUTPUT;

	INSERT INTO @databaseToCheckForFullBackups 
	SELECT [result] FROM dbo.split_string(@serialized, N',');


	-- TODO: If these are somehow in the @Exclusions list... then... don't add them. 
	INSERT INTO @databaseToCheckForFullBackups ([name])
	VALUES ('master'),('msdb');

	EXEC dbo.load_database_names 
		@Input = @DatabasesToCheck,
		@Exclusions = @DatabasesToExclude, 
		@Priorities = NULL, 
		@Mode = N'VERIFY', 
		@BackupType = N'LOG',
		@Output = @serialized OUTPUT;

	INSERT INTO @databaseToCheckForLogBackups 
	SELECT [result] FROM dbo.split_string(@serialized, N',');


	-- Verify that there are backups to check:

	-----------------------------------------------------------------------------
	-- Determine which jobs to check:
	DECLARE @specifiedJobs table ( 
		jobname sysname NOT NULL
	);

	DECLARE @jobsToCheck table ( 
		jobname sysname NOT NULL, 
		jobid uniqueidentifier NULL
	);

	INSERT INTO @specifiedJobs (jobname)
	SELECT [result] FROM dbo.split_string(@MonitoredJobs, N',');

	INSERT INTO @jobsToCheck (jobname, jobid)
	SELECT 
		s.jobname, 
		j.job_id [jobid]
	FROM 
		@specifiedJobs s
		LEFT OUTER JOIN msdb..sysjobs j ON s.jobname = j.[name];

	-----------------------------------------------------------------------------
	-- backup checks:

	BEGIN TRY

		-- FULL Backup Checks: 
		DECLARE @backupStatuses table (
			backup_id int IDENTITY(1,1) NOT NULL,
			[database_name] sysname NOT NULL, 
			[backup_type] sysname NOT NULL, 
			[minutes_since_last_backup] int
		);

		WITH core AS (
			SELECT 
				b.[database_name],
				CASE b.[type]	
					WHEN 'D' THEN 'FULL'
					WHEN 'I' THEN 'DIFF'
					WHEN 'L' THEN 'LOG'
					ELSE 'OTHER'  -- options include, F, G, P, Q, [NULL] 
				END [backup_type],
				MAX(b.backup_finish_date) [last_completion]
			FROM 
				@databaseToCheckForFullBackups x
				INNER JOIN msdb.dbo.backupset b ON x.[name] = b.[database_name]
			WHERE
				b.is_damaged = 0
				AND b.has_incomplete_metadata = 0
				AND b.is_copy_only = 0
			GROUP BY 
				b.[database_name], 
				b.[type]
		) 
	
		INSERT INTO @backupStatuses ([database_name], backup_type, minutes_since_last_backup)
		SELECT 
			[database_name],
			[backup_type],
			DATEDIFF(MINUTE, last_completion, GETDATE()) [minutes_since_last_backup]
		FROM 
			core
		ORDER BY 
			[core].[database_name];

		-- Grab a list of any dbs that were specified for checkups, but which aren't on the server - then report on those, and use the temp-table for exclusions from subsequent checks:
		DECLARE @phantoms table (
			[name] sysname NOT NULL
		);

		INSERT INTO @phantoms ([name])
		SELECT [name] FROM @databaseToCheckForFullBackups WHERE [name] NOT IN (SELECT [name] FROM master.sys.databases WHERE state_desc = 'ONLINE');

		-- Remove non-accessible secondaries (Mirrored or AG'd) as needed/specified:
		IF @AllowNonAccessibleSecondaries = 1 BEGIN

			DECLARE @activeSecondaries table ( 
				[name] sysname NOT NULL
			);

			INSERT INTO @activeSecondaries ([name])
			SELECT [name] FROM master.sys.databases 
			WHERE [name] IN (SELECT d.[name] FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL AND m.mirroring_role_desc != 'PRINCIPAL' )
			OR [name] IN (
				SELECT d.name 
				FROM master.sys.databases d 
				INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
				WHERE hars.role_desc != 'PRIMARY'
			); -- grab any dbs that are in an AG where the current role != PRIMARY. 


			-- remove secondaries from any list of CHECKS and from the list of statuses we've pulled back (because evaluation is a comparison of BOTH sides of the union/join of these sets).
			DELETE FROM @backupStatuses WHERE [database_name] IN (SELECT [name] FROM @activeSecondaries);

			DELETE FROM @phantoms WHERE [name] IN (SELECT [name] FROM @activeSecondaries);
			DELETE FROM @databaseToCheckForFullBackups WHERE [name] IN (SELECT [name] FROM @activeSecondaries);
			DELETE FROM @databaseToCheckForLogBackups WHERE [name] IN (SELECT [name] FROM @activeSecondaries);

		END;

		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING',
			N'Database [' + [name] + N'] was configured for backup checks/verifications - but is NOT currently listed as an ONLINE database on the server.'
		FROM 
			@phantoms
		ORDER BY 
			[name];

		-- Report on databases that were specified for checks, but which have NEVER been backed-up:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING', 
			N'Database [' + [name] + '] has been configured for regular FULL backup checks/verifications - but has NEVER been backed up.'
		FROM 
			@databaseToCheckForFullBackups
		WHERE 
			[name] NOT IN (SELECT [database_name] FROM @backupStatuses WHERE backup_type = 'FULL')
			AND [name] NOT IN (SELECT [name] FROM @phantoms);
		
		-- Report on databases that were specified for checks, but which haven't had FULL backups in > @FullBackupAlertThresholdHours:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING' [type], 
			N'The last successful FULL backup for database [' + [database_name] + N'] was ' + CAST((minutes_since_last_backup / 60) AS sysname) + N' hours (and ' + CAST((minutes_since_last_backup % 60) AS sysname) + N' minutes) ago - which exceeds the currently specified value of ' + CAST(@FullBackupAlertThresholdHours AS sysname) + N' hours for @FullBackupAlertThresholdHours.'
		FROM 
			@backupStatuses
		WHERE 
			backup_type = 'FULL'
			AND minutes_since_last_backup > 60 * @FullBackupAlertThresholdHours
		ORDER BY 
			minutes_since_last_backup DESC;

		-- Report on User DBs specified for checkups that are set to NON-SIMPLE recovery, and which haven't had their T-Logs backed up:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING',
			N'Database [' + [name] + N'] has been configured for regular LOG backup checks/verifiation - but has NEVER had its Transaction Log backed up.'
		FROM 
			@databaseToCheckForLogBackups
		WHERE 
			[name] NOT IN (SELECT [database_name] FROM @backupStatuses WHERE backup_type = 'LOG')
			AND [name] NOT IN (SELECT [name] FROM @phantoms);

		-- Report on databases in NON-SIMPLE recovery mode that haven't had their T-Logs backed up in > @LogBackupAlertThresholdMinutes:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING', 
			N'The last successful Transaction Log backup for database [' + [database_name] + N'] was ' + CAST((minutes_since_last_backup / 60) AS sysname) + N' hours (and ' + CAST((minutes_since_last_backup % 60) AS sysname) + N' minutes) ago - which exceeds the currently specified value of ' + CAST(@LogBackupAlertThresholdMinutes AS sysname) + N' minutes for @LogBackupAlertThresholdMinutes.'
		FROM 
			@backupStatuses
		WHERE 
			backup_type = 'LOG'
			AND minutes_since_last_backup > @LogBackupAlertThresholdMinutes
		ORDER BY 
			minutes_since_last_backup DESC;
	
	END TRY
	BEGIN CATCH
		SELECT @errorMessage = N'Exception during Backup Checks: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']'; 

		INSERT INTO @outputs ([type], [message])
		VALUES ('EXCEPTION', @errorMessage);

		SET @errorMessage = '';
	END CATCH

	-----------------------------------------------------------------------------
	-- job checks:


	IF (SELECT COUNT(*) FROM @jobsToCheck) > 0 BEGIN

		BEGIN TRY
			-- Warn about any jobs specified for checks that aren't actual jobs (i.e., where the names couldn't match a SQL Agent job).
			INSERT INTO @outputs ([type], [message])
			SELECT 
				N'WARNING', 
				N'Job [' + jobname + '] was configured for a regular checkup - but is NOT a VALID SQL Server Agent Job Name.'
			FROM 
				@jobsToCheck 
			WHERE 
				jobid IS NULL
			ORDER BY 
				jobname;

			-- otherwise, make sure that if the job is currently running, it hasn't exceeded 130% of the time it normally takes to run. 
			DECLARE @currentJobName sysname, @currentJobID uniqueidentifier;
			DECLARE @instanceCounts int, @avgRunDuration int;

			DECLARE @isExecuting bit, @elapsed int;
		
			DECLARE checker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT jobname, jobid FROM @jobsToCheck WHERE jobid IS NOT NULL; 

			OPEN checker;
			FETCH NEXT FROM checker INTO @currentJobName, @currentJobID;

			WHILE @@FETCH_STATUS = 0 BEGIN
				SET @isExecuting = 0;
				SET @elapsed = 0;

				WITH core AS ( 
					SELECT job_id, 
						DATEDIFF(SECOND, run_requested_date, GETDATE()) [elapsed] 
					FROM msdb.dbo.sysjobactivity 
					WHERE run_requested_date IS NOT NULL AND stop_execution_date IS NULL
				)

				SELECT 
					@isExecuting = CASE when job_id IS NULL THEN 0 ELSE 1 END, 
					@elapsed = elapsed 
				FROM 
					core
				WHERE 
					job_id = @currentJobID;

				-- 4.2.3.16822 Only check for 'long-running' jobs if a) duration is > @MinimumElapsedSecondsToConsider (i.e., don't alert for a job running 220% over normal IF 220% over normal is, say, 10 seconds TOTAL)
				--		 _AND_ b) if @elapsed is >  @MaximumElapsedSecondsToIgnore - i.e., don't alert if 'total elapsed' time is, say, 3 minutes - who cares...  (in 15 minutes when we run again, IF this job is still running (and that's a problem), THEN we'll get an alert). 
				IF (@isExecuting = 1) AND (@elapsed > @MinimumElapsedSecondsToConsider) AND (@elapsed > @MaximumElapsedSecondsToIgnore) BEGIN	

					-- check on execution durations:
					SELECT 
						@instanceCounts = COUNT(*), 
						@avgRunDuration = AVG(run_duration) 
					FROM (
						SELECT TOP(20)
							run_duration 
						FROM 
							msdb.dbo.sysjobhistory 
						WHERE 
							job_id = @currentJobID
							AND step_id = 0 AND run_status = 1 -- only grab metrics/durations for the ENTIRE duration of (successful only) executions.
						ORDER BY 
							run_date DESC, 
							run_time DESC
						) latest;
				

					IF @instanceCounts < 6 BEGIN 
						-- Arguably, we could send a 'warning' here ... but that's lame. At present, there is NOT a problem - because we don't have enough history to determine if this execution is 'out of scope' or not. 
						--		so, rather than causing false-alarms/red-herrings, just spit out a bit of info into the job history instead.
						PRINT 'History for job [' + @currentJobName + '] only contains information on the last ' + CAST(@instanceCounts AS sysname) + N' executions of the job. Meaning there is not enough history to determine abnormalities.'

				       END;
					ELSE BEGIN

						-- otherwise, if the current execution duration is > 220% of normal execution - raise an alert... 
						IF @elapsed > @avgRunDuration * 2.2 BEGIN
							INSERT INTO @outputs ([type], [message])
							SELECT 
								N'WARNING',
								N'Job [' + @currentJobName + N'] is currently running, and has been running for ' + CAST(@elapsed AS sysname) + N' seconds - which is greater than 220% of the average time it has taken to execute over the last ' + CAST(@instanceCounts AS sysname) + N' executions.'
						END;
					END;
				
				END;

				FETCH NEXT FROM checker INTO @currentJobName, @currentJobID;
			END;


		END TRY
		BEGIN CATCH
			SELECT @errorMessage = N'Exception during Job Checks: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']'; 

			INSERT INTO @outputs ([type], [message])
			VALUES ('EXCEPTION', @errorMessage);			
		END CATCH

		CLOSE checker;
		DEALLOCATE checker;

	END;  -- /IF JobChecks


	IF EXISTS (SELECT NULL FROM @outputs) BEGIN

		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9); 

		DECLARE @message nvarchar(MAX); 
		DECLARE @subject nvarchar(2000);

		IF EXISTS (SELECT NULL FROM @outputs WHERE [type] = 'EXCEPTION') 
			SET @subject = @EmailSubjectPrefix + N' Exceptions Detected';
		ELSE  
			SET @subject = @EmailSubjectPrefix + N' Warnings Detected';

		SET @message = N'The following problems were encountered during execution:' + @crlf + @crlf;

		--MKC: Insane. The following does NOT work. It returns only the LAST row from a multi-row 'set'. (remove the order-by, and ALL results return. Crazy.)
			--SELECT 
			--	@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
			--FROM 
			--	@outputs
			--ORDER BY 
			--	CASE WHEN [type] = 'EXCEPTION' THEN 0 ELSE 1 END ASC, output_id ASC;

		-- So, instead of combining 'types' of outputs, i'm just hacking this to concatenate 2x different result 'sets' or types of results. (I could try a CTE + Windowing Function... or .. something else, but this is easiest for now). 
		SELECT 
			@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
		FROM 
			@outputs
		WHERE 
			[type] = 'EXCEPTION'
		ORDER BY 
			output_id ASC;

		-- + this:
		SELECT 
			@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
		FROM 
			@outputs
		WHERE 
			[type] = 'WARNING'
		ORDER BY 
			output_id ASC;

		IF @PrintOnly = 1 BEGIN
			
			PRINT @subject;
			PRINT @message;

		  END
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @subject, 
				@body = @message;
		END;

	END;

	RETURN 0;
GO


-----------------------------------
USE admindb;
GO


IF OBJECT_ID('dbo.verify_database_configurations','P') IS NOT NULL
	DROP PROC dbo.verify_database_configurations;
GO

CREATE PROC dbo.verify_database_configurations 
	@DatabasesToExclude				nvarchar(MAX) = NULL,
	@CompatabilityExclusions		nvarchar(MAX) = NULL,
	@ReportDatabasesNotOwnedBySA	bit	= 0,
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[Database Configuration Alert] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -2;
		 END;
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -2;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -2;
		END; 
	END;

	IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
		SET @DatabasesToExclude = NULL;

	IF RTRIM(LTRIM(@CompatabilityExclusions)) = N''
		SET @DatabasesToExclude = NULL;

	-----------------------------------------------------------------------------
	-- Set up / initialization:

	-- start by (messily) grabbing the current version on the server:
	DECLARE @serverVersion int;
	SET @serverVersion = (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) * 10;

	DECLARE @serialized nvarchar(MAX);
	DECLARE @databasesToCheck table (
		[name] sysname
	);
	
	EXEC dbo.load_database_names 
		@Input = N'[USER]',
		@Exclusions = @DatabasesToExclude, 
		@Mode = N'VERIFY', 
		@BackupType = N'FULL',
		@Output = @serialized OUTPUT;

	INSERT INTO @databasesToCheck ([name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	DECLARE @excludedComptabilityDatabases table ( 
		[name] sysname NOT NULL
	); 

	IF @CompatabilityExclusions IS NOT NULL BEGIN 
		INSERT INTO @excludedComptabilityDatabases ([name])
		SELECT [result] FROM dbo.split_string(@CompatabilityExclusions, N',');
	END; 

	DECLARE @issues table ( 
		issue_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		issue varchar(2000) NOT NULL 
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);

	-----------------------------------------------------------------------------
	-- Checks: 
	
	-- Compatablity Checks: 
	INSERT INTO @issues ([database], issue)
	SELECT 
		d.[name] [database],
		N'Compatibility should be ' + CAST(@serverVersion AS sysname) + N' but is currently set to ' + CAST(d.compatibility_level AS sysname) + N'.' [issue]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] = x.[name]
		LEFT OUTER JOIN @excludedComptabilityDatabases e ON d.[name] LIKE e.[name] -- allow LIKE %wildcard% exclusions
	WHERE 
		d.[compatibility_level] <> CAST(@serverVersion AS tinyint)
		AND e.[name] IS  NULL -- only include non-exclusions
	ORDER BY 
		d.[name] ;
		

	-- Page Verify: 
	INSERT INTO @issues ([database], issue)
	SELECT 
		[name] [database], 
		N'Page Verify should be set to CHECKSUM - but is currently set to ' + ISNULL(page_verify_option_desc, 'NOTHING') + N'.' + @crlf + @tab + @tab + N'To correct, execute: ALTER DATABASE ' + QUOTENAME([name],'[]') + N' SET PAGE_VERIFY CHECKSUM; ' + @crlf [issue]
	FROM 
		sys.databases 
	WHERE 
		page_verify_option_desc != N'CHECKSUM'
	ORDER BY 
		[name];

	-- OwnerChecks:
	IF @ReportDatabasesNotOwnedBySA = 1 BEGIN
		INSERT INTO @issues ([database], issue)
		SELECT 
			[name] [database], 
			N'Should by Owned by 0x01 (SysAdmin) but is currently owned by 0x' + CONVERT(nvarchar(MAX), owner_sid, 2) + N'.' + @crlf + @tab + @tab + N'To correct, execute:  ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME([name],'[]') + N' TO sa;' + @crlf [issue]
		FROM 
			sys.databases 
		WHERE 
			owner_sid != 0x01;

	END;

	-----------------------------------------------------------------------------
	-- add other checks as needed/required per environment:



	-----------------------------------------------------------------------------
	-- reporting: 
	DECLARE @emailErrorMessage nvarchar(MAX);
	IF EXISTS (SELECT NULL FROM @issues) BEGIN 
		
		DECLARE @emailSubject nvarchar(300);

		SET @emailErrorMessage = N'The following configuration discrepencies were detected: ' + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + @tab + N'[' + [database] + N']. ' + [issue] + @crlf
		FROM 
			@issues 
		ORDER BY 
			[database],
			issue_id;

	END;

	-- send/display any problems:
	IF @emailErrorMessage IS NOT NULL BEGIN
		IF @PrintOnly = 1 
			PRINT @emailErrorMessage;
		ELSE BEGIN 
			SET @emailSubject = @EmailSubjectPrefix + N' - Configuration Problems Detected';

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;

		END
	END;

	RETURN 0;
GO



---------------------------------------------------------------------------
-- Monitoring (HA):
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.is_primary_database','FN') IS NOT NULL
	DROP FUNCTION dbo.is_primary_database;
GO

CREATE FUNCTION dbo.is_primary_database(@DatabaseName sysname)
RETURNS bit
AS
	BEGIN 

		DECLARE @description sysname;
				
		-- Check for Mirrored Status First: 
		SELECT 
			@description = mirroring_role_desc
		FROM 
			sys.database_mirroring 
		WHERE
			database_id = DB_ID(@DatabaseName);
	
		IF @description = 'PRINCIPAL'
			RETURN 1;
			

		-- Check for AG'd state:
		SELECT 
			@description = 	hars.role_desc
		FROM 
			sys.databases d
			INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
		WHERE 
			d.database_id = DB_ID(@DatabaseName);
	
		IF @description = 'PRIMARY'
			RETURN 1;
	
		-- if no matches, return 0
		RETURN 0;
	END;
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.job_synchronization_checks','P') IS NOT NULL
	DROP PROC dbo.job_synchronization_checks
GO

CREATE PROC [dbo].[job_synchronization_checks]
	@IgnoredJobs			nvarchar(MAX)		= '',
	@MailProfileName		sysname				= N'General',	
	@OperatorName			sysname				= N'Alerts',	
	@PrintOnly			bit						= 0					-- output only to console - don't email alerts (for debugging/manual execution, etc.)
AS 
	SET NOCOUNT ON;

	---------------------------------------------
	-- A) Validation Checks: 
	IF @PrintOnly = 0 BEGIN -- if we're not running a 'manual' execution - make sure we have all parameters:
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

	----------------------------------------------
	-- Figure out which server this should be running on (and then, from this point forward, only run on the Primary);
	DECLARE @firstMirroredDB sysname; 
	SET @firstMirroredDB = (SELECT TOP 1 d.name FROM sys.databases d INNER JOIN sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL ORDER BY d.name); 

	-- if there are NO mirrored dbs, then this job will run on BOTH servers at the same time (which seems weird, but if someone sets this up without mirrored dbs, no sense NOT letting this run). 
	IF @firstMirroredDB IS NOT NULL BEGIN 
		-- Check to see if we're on the primary or not. 
		IF (SELECT dbo.is_primary_database(@firstMirroredDB)) = 0 BEGIN 
			PRINT 'Server is Not Primary. Execution Terminating (but will continue on Primary).'
			RETURN 0; -- tests/checks are now done on the secondary
		END
	END 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	SET @remoteServerName = (SELECT TOP 1 name FROM PARTNER.master.sys.servers WHERE server_id = 0);

	CREATE TABLE #IgnoredJobs (
		name nvarchar(200) NOT NULL
	);

	----------------------------------------------
	-- deserialize the job names to ingore via an inline-split 'function':
	DECLARE @deserializedJobs nvarchar(MAX) = N'SELECT ' + REPLACE(REPLACE(REPLACE(N'''{0}''',N'{0}', @IgnoredJobs), N',', N''','''), N',', N' UNION SELECT ');

	INSERT INTO #IgnoredJobs (name)
	EXEC(@deserializedJobs);

	----------------------------------------------
	-- create a container for output/differences. 
	CREATE TABLE #Divergence (
		rowid int IDENTITY(1,1) NOT NULL,
		name nvarchar(100) NOT NULL, 
		[description] nvarchar(300) NOT NULL
	);

	---------------------------------------------------------------------------------------------
	-- B) Process 'server level jobs' (or jobs that aren't mapped to a mirrorable database - i.e., WHERE Job.CategoryName != DbName):
	DECLARE @mirrorableDatabases TABLE ( 
		name sysname NOT NULL 
	); 

	-- get a list of Job Categories that could BE a database name (i.e., mirror-able):
	INSERT INTO @mirrorableDatabases
	SELECT name FROM master.sys.databases WHERE name NOT IN ('master','tempdb','model','msdb','distribution','ReportServer','ReportServerTempDB','admindb') 
	UNION 
	SELECT name FROM PARTNER.master.sys.databases WHERE name NOT IN ('master','tempdb','model','msdb','distribution','ReportServer','ReportServerTempDB','admindb'); 

	CREATE TABLE #LocalJobs (
		job_id uniqueidentifier, 
		name sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	CREATE TABLE #RemoteJobs (
		job_id uniqueidentifier, 
		name sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	-- Load Details: 
	INSERT INTO #LocalJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.name, 'local') operator_name,
		ISNULL(sc.name, 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
	WHERE
		sj.name NOT IN (SELECT name FROM #IgnoredJobs); 

	INSERT INTO #RemoteJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.name, 'local') operator_name,
		ISNULL(sc.name, 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		PARTNER.msdb.dbo.sysjobs sj
		LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
	WHERE
		sj.name NOT IN (SELECT name FROM #IgnoredJobs);

	----------------------------------------------
	-- Process high-level details about each job (i.e., jobs on ONE server only - or jobs on both servers but with differences):
	INSERT INTO #Divergence (name, [description])
	SELECT 
		name,
		N'Server-Level job exists on ' + @localServerName + N' only.'
	FROM 
		#LocalJobs 
	WHERE
		name NOT IN (SELECT name FROM #RemoteJobs)
		AND name NOT IN (SELECT name FROM @mirrorableDatabases);

	INSERT INTO #Divergence (name, [description])
	SELECT 
		name, 
		N'Server-Level job exists on ' + @remoteServerName + N' only.'
	FROM 
		#RemoteJobs
	WHERE
		name NOT IN (SELECT name FROM #LocalJobs);

	INSERT INTO #Divergence (name, [description])
	SELECT 
		lj.name, 
		N'Differences between Server-Level job details between servers (owner, enabled, category name, job-steps count, start-step, notification, etc)'
	FROM 
		#LocalJobs lj
		INNER JOIN #RemoteJobs rj ON rj.name = lj.name
	WHERE
		lj.category_name NOT IN (SELECT name FROM @mirrorableDatabases) 
		AND rj.category_name NOT IN (SELECT name FROM @mirrorableDatabases)
		AND (
			lj.[enabled] != rj.[enabled]
			OR lj.[description] != rj.[description]
			OR lj.start_step_id != rj.start_step_id
			OR lj.owner_sid != rj.owner_sid
			OR lj.notify_level_email != rj.notify_level_email
			OR lj.operator_name != rj.operator_name
			OR lj.job_step_count != rj.job_step_count
			OR lj.category_name != rj.category_name
		);

	----------------------------------------------
	-- now check the job steps/schedules/etc. 
	CREATE TABLE #LocalJobSteps (
		step_id int, 
		[checksum] int
	);

	CREATE TABLE #RemoteJobSteps (
		step_id int, 
		[checksum] int
	);

	CREATE TABLE #LocalJobSchedules (
		schedule_name sysname, 
		[checksum] int
	);

	CREATE TABLE #RemoteJobSchedules (
		schedule_name sysname, 
		[checksum] int
	);

	DECLARE server_level_checker CURSOR LOCAL FAST_FORWARD FOR
	SELECT 
		[local].job_id local_job_id, 
		[remote].job_id remote_job_id, 
		[local].name 
	FROM 
		#LocalJobs [local]
		INNER JOIN #RemoteJobs [remote] ON [local].name = [remote].name;

	DECLARE @localJobID uniqueidentifier, @remoteJobId uniqueidentifier, @jobName sysname;
	DECLARE @localCount int, @remoteCount int;

	OPEN server_level_checker;
	FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
	
		-- check jobsteps first:
		DELETE FROM #LocalJobSteps;
		DELETE FROM #RemoteJobSteps;

		INSERT INTO #LocalJobSteps (step_id, [checksum])
		SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, database_name) [detail]
		FROM msdb.dbo.sysjobsteps
		WHERE job_id = @localJobID;

		INSERT INTO #RemoteJobSteps (step_id, [checksum])
		SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, database_name) [detail]
		FROM PARTNER.msdb.dbo.sysjobsteps
		WHERE job_id = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

		IF @localCount != @remoteCount
			INSERT INTO #Divergence (name, [description]) 
			VALUES (
				@jobName, 
				N'Job Step Counts between servers are NOT the same.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence (name, [description])
			SELECT 
				@jobName, 
				N'Job Step details between servers are NOT the same.'
			FROM 
				#LocalJobSteps ljs 
				INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
			WHERE	
				ljs.[checksum] != rjs.[checksum];
		END;

		-- Now Check Schedules:
		DELETE FROM #LocalJobSchedules;
		DELETE FROM #RemoteJobSchedules;

		INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
		SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [details]
		FROM 
			msdb.dbo.sysjobschedules sjs
			INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @localJobID;

		INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
		SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [details]
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

		IF @localCount != @remoteCount
			INSERT INTO #Divergence (name, [description]) 
			VALUES (
				@jobName, 
				N'Job Schedule Counts between servers are different.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence (name, [description])
			SELECT
				@jobName, 
				N'Job Schedule Details between servers are different.'
			FROM 
				#LocalJobSchedules ljs
				INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
			WHERE 
				ljs.[checksum] != rjs.[checksum];

		END;

		FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;
	END;

	CLOSE server_level_checker;
	DEALLOCATE server_level_checker;

	---------------------------------------------------------------------------------------------
	-- C) Start Batch Jobs by reporting on any jobs that have a Job.CategoryName IN (@mirrorableDatabases) but are Disabled or Which have Job.CategoryName = 'Disabled' and are enabled. 
	
	INSERT INTO #Divergence (name, [description])
	SELECT 
		sj.name,
		N'Job is disabled on ' + @localServerName + N', but the job''s category name is not set to ''Disabled'' (meaning this job will be ENABLED on the secondary following a failover).'
	FROM 
		msdb.dbo.sysjobs sj
		INNER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		INNER JOIN @mirrorableDatabases x ON sj.name = x.name
	WHERE 
		sj.[enabled] = 0 
		AND sj.name NOT IN (SELECT name FROM #IgnoredJobs); 

	INSERT INTO #Divergence (name, [description])
	SELECT 
		sj.name,
		N'Job is disabled on ' + @remoteServerName + N', but the job''s category name is not set to ''Disabled'' (meaning this job will be ENABLED on the secondary following a failover).'
	FROM 
		PARTNER.msdb.dbo.sysjobs sj
		INNER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		INNER JOIN @mirrorableDatabases x ON sj.name = x.name
	WHERE 
		sj.[enabled] = 0 
		AND sj.name NOT IN (SELECT name FROM #IgnoredJobs); 

	-- Report on jobs that should be disabled, but aren't. 
	INSERT INTO #Divergence (name, [description])
	SELECT 
		sj.name, 
		N'Job is enabled on ' + @localServerName + N', but job category name is ''Disabled'' (meaning this job will be DISABLED on secondary following a failover).'
	FROM 
		msdb.dbo.sysjobs sj
		INNER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
	WHERE
		sj.[enabled] = 1
		AND LOWER(sc.name) = 'disabled'
		AND sj.name NOT IN (SELECT name FROM #IgnoredJobs);

	INSERT INTO #Divergence (name, [description])
	SELECT 
		sj.name, 
		N'Job is enabled on ' + @remoteServerName + N', but job category name is ''Disabled'' (meaning this job will be DISABLED on secondary following a failover).'
	FROM 
		PARTNER.msdb.dbo.sysjobs sj
		INNER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
	WHERE
		sj.[enabled] = 1
		AND LOWER(sc.name) = 'disabled'
		AND sj.name NOT IN (SELECT name FROM #IgnoredJobs);

	---------------------------------------------------------------------------------------------
	-- D) Check on all jobs for mirrored databases:
	TRUNCATE TABLE #LocalJobs;
	TRUNCATE TABLE #RemoteJobs;

	DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		d.name
	FROM 
		master.sys.databases d
		INNER JOIN master.sys.database_mirroring m ON m.database_id = d.database_id
	WHERE
		m.mirroring_guid IS NOT NULL
	ORDER BY 
		d.name;

	DECLARE @currentMirroredDB sysname; 

	OPEN looper;
	FETCH NEXT FROM looper INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		TRUNCATE TABLE #LocalJobs;
		TRUNCATE TABLE #RemoteJobs;
		
		INSERT INTO #LocalJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		SELECT 
			sj.job_id, 
			sj.name, 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.name, 'local') operator_name,
			ISNULL(sc.name, 'local') [category_name],
			ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			msdb.dbo.sysjobs sj
			LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.name) = UPPER(@currentMirroredDB)
			AND sj.name NOT IN (SELECT name FROM #IgnoredJobs);

		INSERT INTO #RemoteJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		SELECT 
			sj.job_id, 
			sj.name, 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.name, 'local') operator_name,
			ISNULL(sc.name, 'local') [category_name],
			ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
			LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.name) = UPPER(@currentMirroredDB)
			AND sj.name NOT IN (SELECT name FROM #IgnoredJobs);

		------------------------------------------
		-- Now start comparing differences: 

		-- local  only:
		INSERT INTO #Divergence (name, [description])
		SELECT 
			[local].name, 
			N'Job for database ' + @currentMirroredDB + N' exists on ' + @localServerName + N' only.'
		FROM 
			#LocalJobs [local]
			LEFT OUTER JOIN #RemoteJobs [remote] ON [local].name = [remote].name
		WHERE 
			[remote].name IS NULL;

		-- remote only:
		INSERT INTO #Divergence (name, [description])
		SELECT 
			[remote].name, 
			N'Job for database ' + @currentMirroredDB + N' exists on ' + @remoteServerName + N' only.'
		FROM 
			#RemoteJobs [remote]
			LEFT OUTER JOIN #LocalJobs [local] ON [remote].name = [local].name
		WHERE 
			[local].name IS NULL;

		-- differences:
		INSERT INTO #Divergence (name, [description])
		SELECT 
			[local].name, 
			N'Job for database ' + @currentMirroredDB + N' is different between servers (owner, start-step, notification, etc).'
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [remote].name = [local].name
		WHERE
			[local].start_step_id != [remote].start_step_id
			OR [local].owner_sid != [remote].owner_sid
			OR [local].notify_level_email != [remote].notify_level_email
			OR [local].operator_name != [remote].operator_name
			OR [local].job_step_count != [remote].job_step_count
			OR [local].category_name != [remote].category_name;
		
		-- NOTE: While this script assumes the 'PRIMARY' is server that's hosting the Principal for the FIRST mirrored DB detected, the reality
		--		is more complex - as the first mirrored db (automation) might be on SQL1, but (batches) might be 'failed' over and running on SQL2
		IF (SELECT master.dbo.is_primary_database(@currentMirroredDB)) = 1 BEGIN 
			-- report on any mirroring jobs that are disabled on the primary:
			INSERT INTO #Divergence (name, [description])
			SELECT 
				name, 
				N'Batch Job is disabled on ' + @localServerName + N' (PRIMARY) and should be ENABLED.'
			FROM 
				#LocalJobs
			WHERE
				[enabled] = 0; 		
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence (name, [description])
			SELECT 
				name, 
				N'Batch Job is enabled on ' + @remoteServerName + N' (SECONDARY) and should be DISABLED.'
			FROM 
				#RemoteJobs
			WHERE
				[enabled] = 1; 
		  END 
		ELSE BEGIN -- otherwise, simply 'flip' the logic:
			-- report on any mirroring jobs that are disabled on the primary:
			INSERT INTO #Divergence (name, [description])
			SELECT 
				name, 
				N'Batch Job is disabled on ' + @remoteServerName + N' (PRIMARY) and should be ENABLED.'
			FROM 
				#RemoteJobs
			WHERE
				[enabled] = 0; 		
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence (name, [description])
			SELECT 
				name, 
				N'Batch Job is enabled on ' + @localServerName + N' (SECONDARY) and should be DISABLED.'
			FROM 
				#LocalJobs
			WHERE
				[enabled] = 1; 

		END

		---------------
		-- job-steps processing:
		TRUNCATE TABLE #LocalJobSteps;
		TRUNCATE TABLE #RemoteJobSteps;
		TRUNCATE TABLE #LocalJobSchedules;
		TRUNCATE TABLE #RemoteJobSchedules;

		DECLARE checker CURSOR LOCAL FAST_FORWARD FOR
		SELECT 
			[local].job_id local_job_id, 
			[remote].job_id remote_job_id, 
			[local].name 
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [local].name = [remote].name;

		OPEN checker;
		FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;

		WHILE @@FETCH_STATUS = 0 BEGIN 
	
			-- check jobsteps first:
			DELETE FROM #LocalJobSteps;
			DELETE FROM #RemoteJobSteps;

			INSERT INTO #LocalJobSteps (step_id, [checksum])
			SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, database_name) [detail]
			FROM msdb.dbo.sysjobsteps
			WHERE job_id = @localJobID;

			INSERT INTO #RemoteJobSteps (step_id, [checksum])
			SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, database_name) [detail]
			FROM PARTNER.msdb.dbo.sysjobsteps
			WHERE job_id = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

			IF @localCount != @remoteCount
				INSERT INTO #Divergence (name, [description]) 
				VALUES (
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Step Counts between servers are NOT the same.'
				);
			ELSE BEGIN 
				INSERT INTO #Divergence
				SELECT 
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Step details between servers are NOT the same.'
				FROM 
					#LocalJobSteps ljs 
					INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
				WHERE	
					ljs.[checksum] != rjs.[checksum];
			END;

			-- Now Check Schedules:
			DELETE FROM #LocalJobSchedules;
			DELETE FROM #RemoteJobSchedules;

			INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
			SELECT 
				ss.name,
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				msdb.dbo.sysjobschedules sjs
				INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @localJobID;


			INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
			SELECT 
				ss.name,
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				PARTNER.msdb.dbo.sysjobschedules sjs
				INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

			IF @localCount != @remoteCount
				INSERT INTO #Divergence (name, [description])
				VALUES (
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Schedule Counts between servers are different.'
				);
			ELSE BEGIN 
				INSERT INTO #Divergence (name, [description])
				SELECT
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Schedule Details between servers are different.'
				FROM 
					#LocalJobSchedules ljs
					INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
				WHERE 
					ljs.[checksum] != rjs.[checksum];

			END;

			FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;
		END;

		CLOSE checker;
		DEALLOCATE checker;

		---------------

		FETCH NEXT FROM looper INTO @currentMirroredDB;
	END 

	CLOSE looper;
	DEALLOCATE looper;

	---------------------------------------------------------------------------------------------
	-- X) Report on any problems or discrepencies:
	IF(SELECT COUNT(*) FROM #Divergence WHERE name NOT IN(SELECT name FROM #IgnoredJobs)) > 0 BEGIN 

		DECLARE @subject nvarchar(200) = 'SQL Server Agent Job Synchronization Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = 'Problems detected with the following SQL Server Agent Jobs: '
		+ @crlf;

		SELECT 
			@message = @message + @tab + N'- ' + name + N' -> ' + [description] + @crlf
		FROM 
			#Divergence
		ORDER BY 
			rowid;

		SELECT @message += @crlf + @tab + N'NOTE: Jobs can be synchronized by scripting them on the Primary and running scripts on the Secondary.'
			+ @crlf + @tab + @tab + N'To Script Multiple Jobs at once: SSMS > SQL Server Agent Jobs > F7 -> then shift/ctrl + click to select multiple jobs simultaneously.';

		SELECT @message += @crlf + @tab + N'NOTE: If a Job is assigned to a Mirrored DB (Job Category Name) on ONE server but not the other, it will likely '
			+ @crlf + @tab + @tab + N'show up 2x in the list of problems - once as a Server-Level job on one Server only, and once as a Mirrored-DB Job on the other server.';

		IF @PrintOnly = 1 BEGIN 
			-- just Print out details:
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;

		  END
		ELSE BEGIN
			-- send a message:
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject,
				@body = @message;
		END;
	END;

	DROP TABLE #LocalJobs;
	DROP TABLE #RemoteJobs;
	DROP TABLE #Divergence;
	DROP TABLE #LocalJobSteps;
	DROP TABLE #RemoteJobSteps;
	DROP TABLE #LocalJobSchedules;
	DROP TABLE #RemoteJobSchedules;
	DROP TABLE #IgnoredJobs;

	RETURN 0;
GO



-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.respond_to_db_failover','P') IS NOT NULL
	DROP PROC dbo.respond_to_db_failover;
GO

CREATE PROC dbo.respond_to_db_failover 
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname = N'Alerts', 
	@PrintOnly					bit		= 0					-- for testing (i.e., to validate things work as expected)
AS
	SET NOCOUNT ON;

	IF @PrintOnly = 0
		WAITFOR DELAY '00:00:03.00'; -- No, really, give things about 3 seconds (just to let db states 'settle in' to synchronizing/synchronized).

	DECLARE @serverName sysname = @@serverName;
	DECLARE @username sysname;
	DECLARE @report nvarchar(200);

	DECLARE @orphans table (
		UserName sysname,
		UserSID varbinary(85)
	);

	-- Start by querying current/event-ing server for list of databases and states:
	DECLARE @databases table (
		[db_name] sysname NOT NULL, 
		[sync_type] sysname NOT NULL, -- 'Mirrored' or 'AvailabilityGroup'
		[ag_name] sysname NULL, 
		[primary_server] sysname NOT NULL, 
		[role] sysname NOT NULL, 
		[state] sysname NOT NULL, 
		[is_suspended] bit NULL,
		[is_ag_member] bit NULL,
		[owner] sysname NULL,   -- interestingly enough, this CAN be NULL in some strange cases... 
		[jobs_status] nvarchar(max) NULL,  -- whether we were able to turn jobs off or not and what they're set to (enabled/disabled)
		[users_status] nvarchar(max) NULL, 
		[other_status] nvarchar(max) NULL
	);

	-- account for Mirrored databases:
	INSERT INTO @databases ([db_name], [sync_type], [role], [state], [owner])
	SELECT 
		d.[name] [db_name],
		N'MIRRORED' [sync_type],
		dm.mirroring_role_desc [role], 
		dm.mirroring_state_desc [state], 
		sp.[name] [owner]
	FROM sys.database_mirroring dm
	INNER JOIN sys.databases d ON dm.database_id = d.database_id
	LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
	WHERE 
		dm.mirroring_guid IS NOT NULL
	ORDER BY 
		d.[name];

	-- account for AG databases:
	INSERT INTO @databases ([db_name], [sync_type], [ag_name], [primary_server], [role], [state], [is_suspended], [is_ag_member], [owner])
	SELECT
		dbcs.[database_name] [db_name],
		N'AVAILABILITY_GROUP' [sync_type],
		ag.[name] [ag_name],
		ISNULL(agstates.primary_replica, '') [primary_server],
		ISNULL(arstates.role_desc,'UNKNOWN') [role],
		ISNULL(dbrs.synchronization_state_desc, 'UNKNOWN') [state],
		ISNULL(dbrs.is_suspended, 0) [is_suspended],
		ISNULL(dbcs.is_database_joined, 0) [is_ag_member], 
		x.[owner]
	FROM
		master.sys.availability_groups AS ag
		LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states AS agstates ON ag.group_id = agstates.group_id
		INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
		INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON AR.replica_id = arstates.replica_id AND arstates.is_local = 1
		INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		LEFT OUTER JOIN master.sys.dm_hadr_database_replica_states AS dbrs ON dbcs.replica_id = dbrs.replica_id AND dbcs.group_database_id = dbrs.group_database_id
		LEFT OUTER JOIN (SELECT d.name, sp.name [owner] FROM master.sys.databases d INNER JOIN master.sys.server_principals sp ON d.owner_sid = sp.sid) x ON x.name = dbcs.database_name
	ORDER BY
		AG.name ASC,
		dbcs.database_name;

	-- process:
	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[db_name], 
		[role],
		[state]
	FROM 
		@databases
	ORDER BY 
		[db_name];

	DECLARE @currentDatabase sysname, @currentRole sysname, @currentState sysname; 
	DECLARE @enabledOrDisabled bit; 
	DECLARE @jobsStatus nvarchar(max);
	DECLARE @usersStatus nvarchar(max);
	DECLARE @otherStatus nvarchar(max);

	DECLARE @ownerChangeCommand nvarchar(max);

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		IF @currentState IN ('SYNCHRONIZED','SYNCHRONIZING') BEGIN 
			IF @currentRole IN (N'PRIMARY', N'PRINCIPAL') BEGIN 
				-----------------------------------------------------------------------------------------------
				-- specify jobs status:
				SET @enabledOrDisabled = 1;

				-----------------------------------------------------------------------------------------------
				-- set database owner to 'sa' if it's not owned currently by 'sa':
				IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE name = @currentDatabase AND owner_sid = 0x01) BEGIN 
					SET @ownerChangeCommand = N'ALTER AUTHORIZATION ON DATABASE::[' + @currentDatabase + N'] TO sa;';

					IF @PrintOnly = 1
						PRINT @ownerChangeCommand;
					ELSE 
						EXEC sp_executesql @ownerChangeCommand;
				END

				-----------------------------------------------------------------------------------------------
				-- attempt to fix any orphaned users: 
				DELETE FROM @orphans;
				SET @report = N'[' + @currentDatabase + N'].dbo.sp_change_users_login ''Report''';

				INSERT INTO @orphans
				EXEC(@report);

				DECLARE fixer CURSOR LOCAL FAST_FORWARD FOR
				SELECT UserName FROM @orphans;

				OPEN fixer;
				FETCH NEXT FROM fixer INTO @username;

				WHILE @@FETCH_STATUS = 0 BEGIN

					BEGIN TRY 
						IF @PrintOnly = 1 
							PRINT 'Processing Orphans for Principal Database ' + @currentDatabase
						ELSE
							EXEC sp_change_users_login @Action = 'Update_One', @UserNamePattern = @username, @LoginName = @username;  -- note: this only attempts to repair bindings in situations where the Login name is identical to the User name
					END TRY 
					BEGIN CATCH 
						-- swallow... 
					END CATCH

					FETCH NEXT FROM fixer INTO @username;
				END

				CLOSE fixer;
				DEALLOCATE fixer;

				----------------------------------
				-- Report on any logins that couldn't be corrected:
				DELETE FROM @orphans;

				INSERT INTO @orphans
				EXEC(@report);

				IF (SELECT COUNT(*) FROM @orphans) > 0 BEGIN 
					SET @usersStatus = N'Orphaned Users Detected (attempted repair did NOT correct) : ';
					SELECT @usersStatus = @usersStatus + UserName + ', ' FROM @orphans;

					SET @usersStatus = LEFT(@usersStatus, LEN(@usersStatus) - 1); -- trim trailing , 
					END
				ELSE 
					SET @usersStatus = N'No Orphaned Users Detected';					

			  END 
			ELSE BEGIN -- we're NOT the PRINCIPAL instance:
				SELECT 
					@enabledOrDisabled = 0,  -- make sure all jobs are disabled
					@usersStatus = N'', -- nothing will show up...  
					@otherStatus = N''; -- ditto
			  END

		  END
		ELSE BEGIN -- db isn't in SYNCHRONIZED/SYNCHRONIZING state... 
			-- can't do anything because of current db state. So, disable all jobs for db in question, and 'report' on outcome. 
			SELECT 
				@enabledOrDisabled = 0, -- preemptively disable
				@usersStatus = N'Unable to process - due to database state',
				@otherStatus = N'Database in non synchronized/synchronizing state';
		END

		-----------------------------------------------------------------------------------------------
		-- Process Jobs (i.e. toggle them on or off based on whatever value was set above):
		BEGIN TRY 
			DECLARE toggler CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				sj.job_id, sj.name
			FROM 
				msdb.dbo.sysjobs sj
				INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
			WHERE 
				LOWER(sc.name) = LOWER(@currentDatabase);

			DECLARE @jobid uniqueidentifier; 
			DECLARE @jobname sysname;

			OPEN toggler; 
			FETCH NEXT FROM toggler INTO @jobid, @jobname;

			WHILE @@FETCH_STATUS = 0 BEGIN 
		
				IF @PrintOnly = 1 BEGIN 
					PRINT 'EXEC msdb.dbo.sp_updatejob @job_name = ''' + @jobname + ''', @enabled = ' + CAST(@enabledOrDisabled AS varchar(1)) + ';'
				  END
				ELSE BEGIN
					EXEC msdb.dbo.sp_update_job
						@job_id = @jobid, 
						@enabled = @enabledOrDisabled;
				END

				FETCH NEXT FROM toggler INTO @jobid, @jobname;
			END 

			CLOSE toggler;
			DEALLOCATE toggler;

			IF @enabledOrDisabled = 1
				SET @jobsStatus = N'Jobs set to ENABLED';
			ELSE 
				SET @jobsStatus = N'Jobs set to DISABLED';

		END TRY 
		BEGIN CATCH 

			SELECT @jobsStatus = N'ERROR while attempting to set Jobs to ' + CASE WHEN @enabledOrDisabled = 1 THEN ' ENABLED ' ELSE ' DISABLED ' END + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(20)) + N' -> ' + ERROR_MESSAGE();
		END CATCH

		-----------------------------------------------------------------------------------------------
		-- Update the status for this job. 
		UPDATE @databases 
		SET 
			[jobs_status] = @jobsStatus,
			[users_status] = @usersStatus,
			[other_status] = @otherStatus
		WHERE 
			[db_name] = @currentDatabase;

		FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;
	END

	CLOSE processor;
	DEALLOCATE processor;
	
	-----------------------------------------------------------------------------------------------
	-- final report/summary. 
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);
	DECLARE @message nvarchar(MAX) = N'';
	DECLARE @subject nvarchar(400) = N'';
	DECLARE @dbs nvarchar(4000) = N'';
	
	SELECT @dbs = @dbs + N'  DATABASE: ' + [db_name] + @crlf 
		+ @tab + N'AG_MEMBERSHIP = ' + CASE WHEN [is_ag_member] = 1 THEN [ag_name] ELSE 'DISCONNECTED !!' END + @crlf
		+ @tab + N'CURRENT_ROLE = ' + [role] + @crlf 
		+ @tab + N'CURRENT_STATE = ' + CASE WHEN is_suspended = 1 THEN N'SUSPENDED !!' ELSE [state] END + @crlf
		+ @tab + N'OWNER = ' + ISNULL([owner], N'NULL') + @crlf 
		+ @tab + N'JOBS_STATUS = ' + jobs_status + @crlf 
		+ @tab + CASE WHEN NULLIF(users_status, '') IS NULL THEN N'' ELSE N'USERS_STATUS = ' + users_status END
		+ CASE WHEN NULLIF(other_status,'') IS NULL THEN N'' ELSE @crlf + @tab + N'OTHER_STATUS = ' + other_status END + @crlf 
		+ @crlf
	FROM @databases
	ORDER BY [db_name];

	SET @subject = N'Availability Groups Failover Detected on ' + @serverName;
	SET @message = N'Post failover-response details are as follows: ';
	SET @message = @message + @crlf + @crlf + N'SERVER NAME: ' + @serverName + @crlf;
	SET @message = @message + @crlf + @dbs;

	IF @PrintOnly = 1 BEGIN 
		-- just Print out details:
		PRINT 'SUBJECT: ' + @subject;
		PRINT 'BODY: ' + @crlf + @message;

		END
	ELSE BEGIN
		-- send a message:
		EXEC msdb..sp_notify_operator 
			@profile_name = @MailProfileName, 
			@name = @OperatorName, 
			@subject = @subject,
			@body = @message;
	END;	

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.server_synchronization_checks','P') IS NOT NULL
	DROP PROC dbo.server_synchronization_checks;
GO

CREATE PROC dbo.server_synchronization_checks 
	@IgnoreMirroredDatabaseOwnership	bit		= 0,					-- check by default. 
	@IgnoredMasterDbObjects				nvarchar(4000) = NULL,
	@IgnoredLogins						nvarchar(4000) = NULL,
	@IgnoredAlerts						nvarchar(4000) = NULL,
	@IgnoredLinkedServers				nvarchar(4000) = NULL,
	@MailProfileName					sysname = N'General',					
	@OperatorName						sysname = N'Alerts',					
	@PrintOnly							bit		= 0						-- output only to console if @PrintOnly = 1
AS
	SET NOCOUNT ON; 

	-- if we're not manually running this, make sure the server is the primary:
	IF @PrintOnly = 0 BEGIN -- if we're not running a 'manual' execution - make sure we have all parameters:
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

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE name = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END 

	IF OBJECT_ID('server_trace_flags', 'U') IS NULL BEGIN 
		RAISERROR('Table dbo.server_trace_flags is not present in master. Synchronization check can not be processed.', 16, 1);
		RETURN -6;
	END

	-- Start by updating master.dbo.dba_TraceFlags on both servers:
	TRUNCATE TABLE dbo.dba_traceflags; -- truncating and replacing nets < 1 page of data and typically around 0ms of CPU. 

	INSERT INTO dbo.server_trace_flags(trace_flag, [status], [global], [session])
	EXECUTE ('DBCC TRACESTATUS() WITH NO_INFOMSGS');

	-- Figure out which server this should be running on (and then, from this point forward, only run on the Primary);
	DECLARE @firstMirroredDB sysname; 
	SET @firstMirroredDB = (SELECT TOP 1 d.name FROM sys.databases d INNER JOIN sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL ORDER BY d.name); 

	-- if there are NO mirrored dbs, then this job will run on BOTH servers at the same time (which seems weird, but if someone sets this up without mirrored dbs, no sense NOT letting this run). 
	IF @firstMirroredDB IS NOT NULL BEGIN 
		-- Check to see if we're on the primary or not. 
		IF (SELECT dbo.is_primary_database(@firstMirroredDB)) = 0 BEGIN 
			PRINT 'Server is Not Primary.'
			RETURN 0; -- tests/checks are now done on the secondary
		END
	END 

	DECLARE @deserializer nvarchar(MAX);

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	SET @remoteServerName = (SELECT TOP 1 name FROM PARTNER.master.sys.servers WHERE server_id = 0);

	-- Just to make sure that this job (running on both servers) has had enough time to update dba_traceflags, go ahead and give everything 200ms of 'lag'.
	--	 Lame, yes. But helps avoid false-positives and also means we don't have to set up RPC perms against linked servers. 
	WAITFOR DELAY '00:00:00.200';

	CREATE TABLE #Divergence (
		rowid int IDENTITY(1,1) NOT NULL, 
		name nvarchar(100) NOT NULL, 
		[description] nvarchar(500) NOT NULL
	);

	---------------------------------------
	-- Server Level Configuration/Settings: 
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'ConfigOption: ' + [source].name, 
		N'Server Configuration Option is different between ' + @localServerName + N' and ' + @remoteServerName + N'. (Run ''EXEC sp_configure;'' on both servers.)'
	FROM 
		master.sys.configurations [source]
		INNER JOIN PARTNER.master.sys.configurations [target] ON [source].[configuration_id] = [target].[configuration_id]
	WHERE 
		[source].value_in_use != [target].value_in_use;

	---------------------------------------
	-- Trace Flags: 
	DECLARE @remoteFlags TABLE (
		TraceFlag int NOT NULL, 
		[Status] bit NOT NULL, 
		[Global] bit NOT NULL, 
		[Session] bit NOT NULL
	);
	
	INSERT INTO @remoteFlags (TraceFlag, [Status], [Global], [Session])
	EXEC sp_executesql 'SELECT trace_flag [status], [global], [session] FROM PARTNER.admindb.dbo.server_trace_flags;';
	
	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(trace_flag AS nvarchar(5)), 
		N'TRACE FLAG is enabled on ' + @localServerName + N' only.'
	FROM 
		admin.dbo.server_trace_flags 
	WHERE 
		TraceFlag NOT IN (SELECT TraceFlag FROM @remoteFlags);

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(TraceFlag AS nvarchar(5)), 
		N'TRACE FLAG is enabled on ' + @remoteServerName + N' only.'
	FROM 
		@remoteFlags
	WHERE 
		TraceFlag NOT IN (SELECT trace_flag FROM admindb.dbo.server_trace_flags);

	-- different values: 
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(x.trace_flag AS nvarchar(5)), 
		N'TRACE FLAG Enabled Value is different between both servers.'
	FROM 
		admindb.dbo.server_trace_flags [x]
		INNER JOIN @remoteFlags [y] ON x.trace_flag = y.TraceFlag 
	WHERE 
		x.[Status] != y.[Status]
		OR x.[Global] != y.[Global]
		OR x.[Session] != y.[Session];


	---------------------------------------
	-- Make sure sys.messages.message_id #1480 is set so that is_event_logged = 1 (for easier/simplified role change (failover) notifications). Likewise, make sure 1440 is still set to is_event_logged = 1 (the default). 
	-- local:
	INSERT INTO #Divergence (name, [description])
	SELECT
		N'ErrorMessage: ' + CAST(message_id AS nvarchar(20)), 
		N'The is_event_logged property for this message_id on ' + @localServerName + N' is NOT set to 1. Please run Mirroring Failover setup scripts.'
	FROM 
		sys.messages 
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

		-- remote:
		INSERT INTO #Divergence (name, [description])
		SELECT
			N'ErrorMessage: ' + CAST(message_id AS nvarchar(20)), 
			N'The is_event_logged property for this message_id on ' + @remoteServerName + N' is NOT set to 1. Please run Mirroring Failover setup scripts.'
		FROM 
			PARTNER.master.sys.messages 
		WHERE 
			language_id = @@langid
			AND message_id IN (1440, 1480)
			AND is_event_logged = 0;

	---------------------------------------
	-- admindb versions: 
	DECLARE @localAdminDBVersion sysname;
	DECLARE @remoteAdminDBVersion sysname;

	SELECT @localAdminDBVersion = version_number FROM admindb..version_history WHERE version_id = (SELECT MAX(version_id) FROM admindb..version_history);
	SELECT @remoteAdminDBVersion = version_number FROM PARTNER.admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM PARTNER.admindb.dbo.version_history);

	IF @localAdminDBVersion <> @remoteAdminDBVersion BEGIN
		INSERT INTO #Divergence (name, [description])
		SELECT 
			N'admindb versions are NOT synchronized',
			N'Admin db on ' + @localServerName + ' is ' + @localAdminDBVersion + ' while the version on ' + @remoteServerName + ' is ' + @remoteAdminDBVersion + '.';

	END;

	---------------------------------------
	-- Mirrored database ownership:
	IF @IgnoreMirroredDatabaseOwnership = 0 BEGIN 
		INSERT INTO #Divergence (name, [description])
		SELECT 
			N'Database: ' + [local].name, 
			N'Database Owners are different between servers.'
		FROM 
			(SELECT d.name, d.owner_sid FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL) [local]
			INNER JOIN (SELECT d.name, d.owner_sid FROM PARTNER.master.sys.databases d INNER JOIN PARTNER.master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL) [remote]
				ON [local].name = [remote].name
		WHERE
			[local].owner_sid != [remote].owner_sid;
	END

	---------------------------------------
	-- Linked Servers:
	DECLARE @IgnoredLinkedServerNames TABLE (
		name sysname NOT NULL
	);

	SET @deserializer = N'SELECT ' + REPLACE(REPLACE(REPLACE(N'''{0}''', '{0}', @IgnoredLinkedServers), ',', ''','''), ',', ' UNION SELECT ');
	INSERT INTO @IgnoredLinkedServerNames(name)
	EXEC(@deserializer);

	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [local].name,
		N'Linked Server exists on ' + @localServerName + N' only.'
	FROM 
		sys.servers [local]
		LEFT OUTER JOIN PARTNER.master.sys.servers [remote] ON [local].name = [remote].name
	WHERE 
		[local].server_id > 0 
		AND [local].name <> 'PARTNER'
		AND [local].name NOT IN (SELECT name FROM @IgnoredLinkedServerNames)
		AND [remote].name IS NULL;

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [remote].name,
		N'Linked Server exists on ' + @remoteServerName + N' only.'
	FROM 
		PARTNER.master.sys.servers [remote]
		LEFT OUTER JOIN master.sys.servers [local] ON [local].name = [remote].name
	WHERE 
		[remote].server_id > 0 
		AND [remote].name <> 'PARTNER'
		AND [remote].name NOT IN (SELECT name FROM @IgnoredLinkedServerNames)
		AND [local].name IS NULL;

	
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [local].name, 
		N'Linkded server definitions are different between servers.'
	FROM 
		sys.servers [local]
		INNER JOIN PARTNER.master.sys.servers [remote] ON [local].name = [remote].name
	WHERE 
		[local].name NOT IN (SELECT name FROM @IgnoredLinkedServerNames)
		AND ( 
			[local].product != [remote].product
			OR [local].provider != [remote].provider
			-- Sadly, PARTNER is a bit of a pain/problem - it has to exist on both servers - but with slightly different versions:
			OR (
				CASE 
					WHEN [local].name = 'PARTNER' AND [local].data_source != [remote].data_source THEN 0 -- non-true (i.e., non-'different' or non-problematic)
					ELSE 1  -- there's a problem (because data sources are different, but the name is NOT 'Partner'
				END 
				 = 1  
			)
			OR [local].location != [remote].location
			OR [local].provider_string != [remote].provider_string
			OR [local].[catalog] != [remote].[catalog]
			OR [local].is_remote_login_enabled != [remote].is_remote_login_enabled
			OR [local].is_rpc_out_enabled != [remote].is_rpc_out_enabled
			OR [local].is_collation_compatible != [remote].is_collation_compatible
			OR [local].uses_remote_collation != [remote].uses_remote_collation
			OR [local].collation_name != [remote].collation_name
			OR [local].connect_timeout != [remote].connect_timeout
			OR [local].query_timeout != [remote].query_timeout
			OR [local].is_remote_proc_transaction_promotion_enabled != [remote].is_remote_proc_transaction_promotion_enabled
			OR [local].is_system != [remote].is_system
			OR [local].lazy_schema_validation != [remote].lazy_schema_validation
		);
		

	---------------------------------------
	-- Logins:
	DECLARE @ignoredLoginName TABLE (
		name sysname NOT NULL
	);

	SET @deserializer = N'SELECT ' + REPLACE(REPLACE(REPLACE(N'''{0}''', '{0}', @IgnoredLogins), ',', ''','''), ',', ' UNION SELECT ');
	INSERT INTO @ignoredLoginName(name)
	EXEC(@deserializer);

	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Login: ' + [local].name, 
		N'Login exists on ' + @localServerName + N' only.'
	FROM 
		sys.server_principals [local]
	WHERE 
		principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S'
		AND [local].name NOT IN (SELECT name FROM PARTNER.master.sys.server_principals WHERE principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S')
		AND [local].name NOT IN (SELECT name FROM @ignoredLoginName);

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Login: ' + [remote].name, 
		N'Login exists on ' + @remoteServerName + N' only.'
	FROM 
		PARTNER.master.sys.server_principals [remote]
	WHERE 
		principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S'
		AND [remote].name NOT IN (SELECT name FROM sys.server_principals WHERE principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S')
		AND [remote].name NOT IN (SELECT name FROM @ignoredLoginName);

	-- differences
	INSERT INTO #Divergence (name, [description])
	SELECT
		N'Login: ' + [local].name, 
		N'Login is different between servers. (Check SID, disabled, or password_hash (for SQL Logins).)'
	FROM 
		(SELECT p.name, p.[sid], p.is_disabled, l.password_hash FROM sys.server_principals p LEFT OUTER JOIN sys.sql_logins l ON p.name = l.name) [local]
		INNER JOIN (SELECT p.name, p.[sid], p.is_disabled, l.password_hash FROM PARTNER.master.sys.server_principals p LEFT OUTER JOIN PARTNER.master.sys.sql_logins l ON p.name = l.name) [remote] ON [local].name = [remote].name
	WHERE
		[local].name NOT IN (SELECT name FROM @ignoredLoginName)
		AND [local].name NOT LIKE '##MS%' -- skip all of the MS cert signers/etc. 
		AND (
			[local].[sid] != [remote].[sid]
			--OR [local].password_hash != [remote].password_hash  -- sadly, these are ALWAYS going to be different because of master keys/encryption details. So we can't use it for comparison purposes.
			OR [local].is_disabled != [remote].is_disabled
		);

	---------------------------------------
	-- Endpoints? 
	--		[add if needed/desired.]

	---------------------------------------
	-- Server Level Triggers?
	--		[add if needed/desired.]


	---------------------------------------
	-- Operators:
	-- local only
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [local].name, 
		N'Operator exists on ' + @localServerName + N' only.'
	FROM 
		msdb.dbo.sysoperators [local]
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators [remote] ON [local].name = [remote].name
	WHERE 
		[remote].name IS NULL;

	-- remote only
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [remote].name, 
		N'Operator exists on ' + @remoteServerName + N' only.'
	FROM 
		PARTNER.msdb.dbo.sysoperators [remote]
		LEFT OUTER JOIN msdb.dbo.sysoperators [local] ON [remote].name = [local].name
	WHERE 
		[local].name IS NULL;

	-- differences (just checking email address in this particular config):
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [local].name, 
		N'Operator definition is different between servers. (Check email address(es) and enabled.)'
	FROM 
		msdb.dbo.sysoperators [local]
		INNER JOIN PARTNER.msdb.dbo.sysoperators [remote] ON [local].name = [remote].name
	WHERE 
		[local].[enabled] != [remote].[enabled]
		OR [local].[email_address] != [remote].[email_address];

	---------------------------------------
	-- Alerts:
	DECLARE @ignoredAlertName TABLE (
		name sysname NOT NULL
	);

	SET @deserializer = N'SELECT ' + REPLACE(REPLACE(REPLACE(N'''{0}''', '{0}', @IgnoredAlerts), ',', ''','''), ',', ' UNION SELECT ');
	INSERT INTO @ignoredAlertName(name)
	EXEC(@deserializer);

	-- local only
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [local].name, 
		N'Alert exists on ' + @localServerName + N' only.'
	FROM 
		msdb.dbo.sysalerts [local]
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysalerts [remote] ON [local].name = [remote].name
	WHERE
		[remote].name IS NULL
		AND [local].name NOT IN (SELECT name FROM @ignoredAlertName);

	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [remote].name, 
		N'Alert exists on ' + @remoteServerName + N' only.'
	FROM 
		PARTNER.msdb.dbo.sysalerts [remote]
		LEFT OUTER JOIN msdb.dbo.sysalerts [local] ON [remote].name = [local].name
	WHERE
		[local].name IS NULL
		AND [remote].name NOT IN (SELECT name FROM @ignoredAlertName);

	-- differences:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [local].name, 
		N'Alert definition is different between servers.'
	FROM	
		msdb.dbo.sysalerts [local]
		INNER JOIN PARTNER.msdb.dbo.sysalerts [remote] ON [local].name = [remote].name
	WHERE 
		[local].name NOT IN (SELECT name FROM @ignoredAlertName)
		AND (
		[local].message_id != [remote].message_id
		OR [local].severity != [remote].severity
		OR [local].[enabled] != [remote].[enabled]
		OR [local].delay_between_responses != [remote].delay_between_responses
		OR [local].notification_message != [remote].notification_message
		OR [local].include_event_description != [remote].include_event_description
		OR [local].database_name != [remote].database_name
		OR [local].event_description_keyword != [remote].event_description_keyword
		-- JobID is problematic. If we have a job set to respond, it'll undoubtedly have a diff ID from one server to the other. So... we just need to make sure ID != 'empty' on one server, while not on the other, etc. 
		OR (
			CASE 
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 0 -- no problem
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id != N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem - one alert is 'empty' and the other is not. 
				WHEN [local].job_id != N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem (inverse of above). 
				WHEN ([local].job_id != N'00000000-0000-0000-0000-000000000000' AND [remote].job_id != N'00000000-0000-0000-0000-000000000000') AND ([local].job_id != [remote].job_id) THEN 0 -- they're both 'non-empty' so... we assume it's good
			END 
			= 1
		)
		OR [local].has_notification != [remote].has_notification
		OR [local].performance_condition != [remote].performance_condition
		OR [local].category_id != [remote].category_id
		);

	---------------------------------------
	-- Objects in Master Database:  
	DECLARE @localMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	DECLARE @ignoredMasterObjects TABLE (
		name sysname NOT NULL
	);

	SET @deserializer = N'SELECT ' + REPLACE(REPLACE(REPLACE(N'''{0}''', '{0}', @IgnoredMasterDbObjects), ',', ''','''), ',', ' UNION SELECT ');
	INSERT INTO @ignoredMasterObjects(name)
	EXEC(@deserializer);

	INSERT INTO @localMasterObjects ([object_name])
	SELECT name FROM sys.objects WHERE [type] IN ('U','V','P','FN','IF','TF') AND is_ms_shipped = 0 AND name NOT IN (SELECT name FROM @ignoredMasterObjects);
	
	DECLARE @remoteMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	INSERT INTO @remoteMasterObjects ([object_name])
	SELECT name FROM PARTNER.master.sys.objects WHERE [type] IN ('U','V','P','FN','IF','TF') AND is_ms_shipped = 0 AND name NOT IN (SELECT name FROM @ignoredMasterObjects);

	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'object: ' + [local].[object_name], 
		N'Object exists only in master database on ' + @localServerName + '.'
	FROM 
		@localMasterObjects [local]
		LEFT OUTER JOIN @remoteMasterObjects [remote] ON [local].[object_name] = [remote].[object_name]
	WHERE
		[remote].[object_name] IS NULL;
	
	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'object: ' + [remote].[object_name], 
		N'Object exists only in master database on ' + @remoteServerName + '.'
	FROM 
		@remoteMasterObjects [remote]
		LEFT OUTER JOIN @localMasterObjects [local] ON [remote].[object_name] = [local].[object_name]
	WHERE
		[local].[object_name] IS NULL;


	CREATE TABLE #Definitions (
		row_id int IDENTITY(1,1) NOT NULL, 
		location sysname NOT NULL, 
		[object_name] sysname NOT NULL, 
		[type] char(2) NOT NULL,
		[hash] varbinary(MAX) NULL
	);

	INSERT INTO #Definitions (location, [object_name], [type], [hash])
	SELECT 
		'local', 
		name, 
		[type], 
		CASE 
			WHEN [type] IN ('V','P','FN','IF','TF') THEN 
				CASE
					-- HASHBYTES barfs on > 8000 chars. So, using this: http://www.sqlnotes.info/2012/01/16/generate-md5-value-from-big-data/
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
						--CAST((DATALENGTH(sm.[definition]) + CHECKSUM(sm.[definition])) AS varbinary(max)) -- CHECKSUM + DATALEN should give us sufficient coverage for differences. 
					ELSE HASHBYTES('SHA1', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		master.sys.objects o
		LEFT OUTER JOIN master.sys.sql_modules sm ON o.object_id = sm.object_id
		INNER JOIN @localMasterObjects x ON o.name = x.[object_name];

	DECLARE localtabler CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'local';

	DECLARE @currentObjectName sysname;
	DECLARE @hash varbinary(MAX);
	DECLARE @checksum bigint = 0;

	OPEN localtabler;
	FETCH NEXT FROM localtabler INTO @currentObjectName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0;

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		SELECT @checksum = @checksum + [local].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.name, c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM master.sys.columns c INNER JOIN master.sys.objects o ON o.object_id = c.object_id WHERE o.name = @currentObjectName
		) [local];

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'local';

		FETCH NEXT FROM localtabler INTO @currentObjectName;
	END 

	CLOSE localtabler;
	DEALLOCATE localtabler;

	INSERT INTO #Definitions (location, [object_name], [type], [hash])
	SELECT 
		'remote', 
		name, 
		[type], 
		CASE 
			WHEN [type] IN ('V','P','FN','IF','TF') THEN 
				CASE
					-- HASHBYTES barfs on > 8000 chars. So, using this: http://www.sqlnotes.info/2012/01/16/generate-md5-value-from-big-data/
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
					ELSE HASHBYTES('SHA1', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		PARTNER.master.sys.objects o
		LEFT OUTER JOIN PARTNER.master.sys.sql_modules sm ON o.object_id = sm.object_id
		INNER JOIN @remoteMasterObjects x ON o.name = x.[object_name];

	DECLARE remotetabler CURSOR LOCAL FAST_FORWARD FOR
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'remote';

	OPEN remotetabler;
	FETCH NEXT FROM remotetabler INTO @currentObjectName; 

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0;

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		SELECT @checksum = @checksum + [remote].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.name, c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM PARTNER.master.sys.columns c INNER JOIN PARTNER.master.sys.objects o ON o.object_id = c.object_id WHERE o.name = @currentObjectName
		) [remote];

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'remote';

		FETCH NEXT FROM remotetabler INTO @currentObjectName; 
	END 

	CLOSE remotetabler;
	DEALLOCATE remotetabler;

	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'object: ' + [local].[object_name], 
		N'Object definitions between servers are different.'
	FROM 
		(SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'local') [local]
		INNER JOIN (SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'remote') [remote] ON [local].object_name = [remote].object_name
	WHERE 
		[local].[hash] != [remote].[hash];
	
	------------------------------------------------------------------------------
	-- Report on any discrepancies: 
	IF(SELECT COUNT(*) FROM #Divergence) > 0 BEGIN 

		DECLARE @subject nvarchar(300) = N'SQL Server Synchronization Check Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = N'The following synchronization issues were detected: ' + @crlf;

		SELECT 
			@message = @message + @tab + name + N' -> ' + [description] + @crlf
		FROM 
			#Divergence
		ORDER BY 
			rowid;
		
		IF @PrintOnly = 1 BEGIN 
			-- just Print out details:
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;

		  END
		ELSE BEGIN
			-- send a message:
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject,
				@body = @message;
		END;

	END 

	DROP TABLE #Divergence;
	DROP TABLE #Definitions;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.server_trace_flags','U') IS NOT NULL
	DROP TABLE dbo.server_trace_flags;
GO

CREATE TABLE dbo.server_trace_flags (
	[trace_flag] [int] NOT NULL,
	[status] [bit] NOT NULL,
	[global] [bit] NOT NULL,
	[session] [bit] NOT NULL,
	CONSTRAINT [PK_server_traceflags] PRIMARY KEY CLUSTERED ([trace_flag] ASC)
) 
ON [PRIMARY];

GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_job_states','P') IS NOT NULL
	DROP PROC dbo.verify_job_states;
GO

CREATE PROC dbo.verify_job_states 
	@SendChangeNotifications	bit = 1,
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname	= N'Alerts', 
	@EmailSubjectPrefix			sysname = N'[SQL Agent Jobs-State Updates]',
	@PrintOnly					bit	= 0
AS 
	SET NOCOUNT ON;

	IF @PrintOnly = 0 BEGIN -- if we're not running a 'manual' execution - make sure we have all parameters:
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

	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @jobsStatus nvarchar(MAX) = N'';

	-- Start by querying for list of mirrored then AG'd database to process:
	DECLARE @targetDatabases table (
		[db_name] sysname NOT NULL, 
		[role] sysname NOT NULL, 
		[state] sysname NOT NULL, 
		[owner] sysname NULL
	);

	INSERT INTO @targetDatabases ([db_name], [role], [state], [owner])
	SELECT 
		d.[name] [db_name],
		dm.mirroring_role_desc [role], 
		dm.mirroring_state_desc [state], 
		sp.[name] [owner]
	FROM 
		sys.database_mirroring dm
		INNER JOIN sys.databases d ON dm.database_id = d.database_id
		LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
	WHERE 
		dm.mirroring_guid IS NOT NULL;

	INSERT INTO @targetDatabases ([db_name], [role], [state], [owner])
	SELECT 
		dbcs.[database_name] [db_name],
		ISNULL(arstates.role_desc,'UNKNOWN') [role],
		ISNULL(dbrs.synchronization_state_desc, 'UNKNOWN') [state],
		x.[owner]
	FROM 
		master.sys.availability_groups AS ag
		LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states AS agstates ON ag.group_id = agstates.group_id
		INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
		INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON ar.replica_id = arstates.replica_id AND arstates.is_local = 1
		INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		LEFT OUTER JOIN master.sys.dm_hadr_database_replica_states AS dbrs ON dbcs.replica_id = dbrs.replica_id AND dbcs.group_database_id = dbrs.group_database_id
		LEFT OUTER JOIN (SELECT d.name, sp.name [owner] FROM master.sys.databases d INNER JOIN master.sys.server_principals sp ON d.owner_sid = sp.sid) x ON x.name = dbcs.database_name;

	DECLARE @currentDatabase sysname, @currentRole sysname, @currentState sysname; 
	DECLARE @enabledOrDisabled bit; 
	DECLARE @countOfJobsToModify int;

	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[db_name], 
		[role],
		[state]
	FROM 
		@targetDatabases
	ORDER BY 
		[db_name];

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;

	WHILE @@FETCH_STATUS = 0 BEGIN;

		SET @enabledOrDisabled = 0; -- default to disabled. 

		-- if the db is synchronized/synchronizing AND PRIMARY, then enable jobs:
		IF (@currentRole IN (N'PRINCIPAL',N'PRIMARY')) AND (@currentState IN ('SYNCHRONIZED','SYNCHRONIZING')) BEGIN
			SET @enabledOrDisabled = 1;
		END;

		-- determine if there are any jobs OUT of sync with their expected settings:
		SELECT @countOfJobsToModify = ISNULL((
				SELECT COUNT(*) FROM msdb.dbo.sysjobs sj INNER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id WHERE LOWER(sc.name) = LOWER(@currentDatabase) AND sj.enabled != @enabledOrDisabled 
			), 0);

		IF @countOfJobsToModify > 0 BEGIN;

			BEGIN TRY 
				DECLARE toggler CURSOR LOCAL FAST_FORWARD FOR 
				SELECT 
					sj.job_id, sj.name
				FROM 
					msdb.dbo.sysjobs sj
					INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
				WHERE 
					LOWER(sc.name) = LOWER(@currentDatabase)
					AND sj.[enabled] <> @enabledOrDisabled;

				DECLARE @jobid uniqueidentifier; 
				DECLARE @jobname sysname;

				OPEN toggler; 
				FETCH NEXT FROM toggler INTO @jobid, @jobname;

				WHILE @@FETCH_STATUS = 0 BEGIN 
		
					IF @PrintOnly = 1 BEGIN 
						PRINT '-- EXEC msdb.dbo.sp_updatejob @job_name = ''' + @jobname + ''', @enabled = ' + CAST(@enabledOrDisabled AS varchar(1)) + ';'
					  END
					ELSE BEGIN
						EXEC msdb.dbo.sp_update_job
							@job_id = @jobid, 
							@enabled = @enabledOrDisabled;
					END

					SET @jobsStatus = @jobsStatus + @tab + N'- [' + ISNULL(@jobname, N'#ERROR#') + N'] to ' + CASE WHEN @enabledOrDisabled = 1 THEN N'ENABLED' ELSE N'DISABLED' END + N'.' + @crlf;

					FETCH NEXT FROM toggler INTO @jobid, @jobname;
				END 

				CLOSE toggler;
				DEALLOCATE toggler;

			END TRY 
			BEGIN CATCH 
				SELECT @errorMessage = @errorMessage + N'ERROR while attempting to set Jobs to ' + CASE WHEN @enabledOrDisabled = 1 THEN N' ENABLED ' ELSE N' DISABLED ' END + N'. [ Error: ' + CAST(ERROR_NUMBER() AS nvarchar(20)) + N' -> ' + ERROR_MESSAGE() + N']';
			END CATCH
		
			-- cleanup cursor if it didn't get closed:
			IF (SELECT CURSOR_STATUS('local','toggler')) > -1 BEGIN;
				CLOSE toggler;
				DEALLOCATE toggler;
			END
		END

		FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;
	END

	CLOSE processor;
	DEALLOCATE processor;

	IF (SELECT CURSOR_STATUS('local','processor')) > -1 BEGIN;
		CLOSE processor;
		DEALLOCATE processor;
	END

	IF (@jobsStatus <> N'') AND (@SendChangeNotifications = 1) BEGIN;

		DECLARE @serverName sysname;
		SELECT @serverName = @@SERVERNAME; 

		SET @jobsStatus = N'The following changes were made to SQL Server Agent Jobs on ' + @serverName + ':' + @crlf + @jobsStatus;

		IF @errorMessage <> N'' 
			SET @jobsStatus = @jobsStatus + @crlf + @crlf + N'The following Error Details were also encountered: ' + @crlf + @tab + @errorMessage;

		DECLARE @emailSubject nvarchar(2000) = @EmailSubjectPrefix + N' Change Report for ' + @serverName;

		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
			PRINT @jobsStatus;

		  END
		ELSE BEGIN 
			EXEC msdb.dbo.sp_notify_operator 
				@profile_name = @MailProfileName,
				@name = @OperatorName, 
				@subject = @emailSubject, 
				@body = @jobsStatus;
		END
	END

	RETURN 0;

GO


---------------------------------------------------------------------------
-- Display Versioning info:
SELECT * FROM dbo.version_history;
GO
