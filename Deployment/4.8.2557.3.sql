
/*

	REFERENCE:
		- License, documentation, and source code at: 
			https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
			username: s4
			password: simple

	NOTES:
		- This script will either install/deploy S4 version 4.8.2557.3 or upgrade a PREVIOUSLY deployed version of S4 to 4.8.2557.3.
		- This script will enable xp_cmdshell if it is not currently enabled. 
		- This script will create a new, admindb, if one is not already present on the server where this code is being run.

	vNEXT: 
		- If xp_cmdshell ends up being enabled, drop a link to S4 documentation on what it is, why it's needed, and why it's not the security risk some folks on interwebs make it out to be. 


	Deployment Steps/Overview: 
		1. Enable xp_cmdshell if not enabled. 
		2. Create admindb if not already present.
		3. Create admindb.dbo.version_history + Determine and process version info (i.e., from previous versions if present). 
		4. Create admindb.dbo.backup_log and admindb.dbo.restore_log + other files needed for backups, restore-testing, and other needs/metrics. + import any log data from pre v4 deployments. 
		5. Cleanup any code/objects from previous versions of S4 installed and no longer needed. 
		6. Deploy S4 version 4.8.2557.3 code to admindb (overwriting any previous versions). 
		7. Reporting on current + any previous versions of S4 installed. 

*/


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 1. Enable xp_cmdshell if/as needed: 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [master];
GO

IF EXISTS (SELECT NULL FROM sys.configurations WHERE [name] = N'xp_cmdshell' AND value_in_use = 0) BEGIN;

	SELECT 'Enabling xp_cmdshell for use by SysAdmin role-members only.' [NOTE: Server Configuration Change Made (xp_cmdshell)];

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE [name] = 'show advanced options' AND value_in_use = 0) BEGIN

		EXEC sp_configure 'show advanced options', 1;
		RECONFIGURE;

		EXEC sp_configure 'xp_cmdshell', 1;
		RECONFIGURE;

		-- switch BACK to not-showing advanced options:
		EXEC sp_configure 'show advanced options', 1;
		RECONFIGURE;

	  END;
	ELSE BEGIN
		EXEC sp_configure 'xp_cmdshell', 1;
		RECONFIGURE;
	END;
END;
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 2. Create admindb if/as needed: 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [master];
GO

IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
	CREATE DATABASE [admindb];  -- TODO: look at potentially defining growth size details - based upon what is going on with model/etc. 

	ALTER AUTHORIZATION ON DATABASE::[admindb] TO sa;

	ALTER DATABASE [admindb] SET RECOVERY SIMPLE;  -- i.e., treat like master/etc. 
END;
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 3. Create admindb.dbo.version_history if needed - and populate as necessary (i.e., this version and any previous version if this is a 'new' install).
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [admindb];
GO

IF OBJECT_ID('version_history', 'U') IS NULL BEGIN

	CREATE TABLE dbo.version_history (
		version_id int IDENTITY(1,1) NOT NULL, 
		version_number varchar(20) NOT NULL, 
		[description] nvarchar(200) NULL, 
		deployed datetime NOT NULL CONSTRAINT DF_version_info_deployed DEFAULT GETDATE(), 
		CONSTRAINT PK_version_info PRIMARY KEY CLUSTERED (version_id)
	);

	EXEC sys.sp_addextendedproperty
		@name = 'S4',
		@value = 'TRUE',
		@level0type = 'Schema',
		@level0name = 'dbo',
		@level1type = 'Table',
		@level1name = 'version_history';
END;

DECLARE @CurrentVersion varchar(20) = N'4.8.2557.3';

-- Add previous details if any are present: 
DECLARE @version sysname; 
DECLARE @objectId int;
DECLARE @createDate datetime;
SELECT @objectId = [object_id], @createDate = create_date FROM master.sys.objects WHERE [name] = N'dba_DatabaseBackups_Log';
SELECT @version = CAST([value] AS sysname) FROM master.sys.extended_properties WHERE major_id = @objectId AND [name] = 'Version';

IF NULLIF(@version,'') IS NOT NULL BEGIN
	IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @version) BEGIN
		INSERT INTO dbo.version_history (version_number, [description], deployed)
		VALUES ( @version, N'Found during deployment of ' + @CurrentVersion + N'.', @createDate);
	END;
END;
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 4. Create and/or modify dbo.backup_log and dbo.restore_log + populate with previous data from non v4 versions that may have been deployed. 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [admindb];
GO

IF OBJECT_ID('dbo.backup_log', 'U') IS NULL BEGIN

		CREATE TABLE dbo.backup_log  (
			backup_id int IDENTITY(1,1) NOT NULL,
			execution_id uniqueidentifier NOT NULL,
			backup_date date NOT NULL CONSTRAINT DF_backup_log_log_date DEFAULT (GETDATE()),
			[database] sysname NOT NULL, 
			backup_type sysname NOT NULL,
			backup_path nvarchar(1000) NOT NULL, 
			copy_path nvarchar(1000) NULL, 
			backup_start datetime NOT NULL, 
			backup_end datetime NULL, 
			backup_succeeded bit NOT NULL CONSTRAINT DF_backup_log_backup_succeeded DEFAULT (0), 
			verification_start datetime NULL, 
			verification_end datetime NULL, 
			verification_succeeded bit NULL, 
			copy_succeeded bit NULL, 
			copy_seconds int NULL, 
			failed_copy_attempts int NULL, 
			copy_details nvarchar(MAX) NULL,
			error_details nvarchar(MAX) NULL, 
			CONSTRAINT PK_backup_log PRIMARY KEY CLUSTERED (backup_id)
		);	
END;

IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN

	CREATE TABLE dbo.restore_log  (
		restore_test_id int IDENTITY(1,1) NOT NULL,
		execution_id uniqueidentifier NOT NULL,
		test_date date NOT NULL CONSTRAINT DF_restore_log_test_date DEFAULT (GETDATE()),
		[database] sysname NOT NULL, 
		restored_as sysname NOT NULL, 
		restore_start datetime NOT NULL, 
		restore_end datetime NULL, 
		restore_succeeded bit NOT NULL CONSTRAINT DF_restore_log_restore_succeeded DEFAULT (0), 
		restored_files xml NULL, -- added v4.7.0.16942
		consistency_start datetime NULL, 
		consistency_end datetime NULL, 
		consistency_succeeded bit NULL, 
		dropped varchar(20) NOT NULL CONSTRAINT DF_restore_log_dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_restore_log PRIMARY KEY CLUSTERED (restore_test_id)
	);

END;
GO

---------------------------------------------------------------------------
-- Copy previous log data (v3 and below) if this is a new v4 install. 
---------------------------------------------------------------------------

DECLARE @objectId int;
SELECT @objectId = [object_id] FROM master.sys.objects WHERE [name] = N'dba_DatabaseBackups_Log';

IF @objectId IS NOT NULL BEGIN 
		
	PRINT 'Importing Previous Data from backup log....';
	SET IDENTITY_INSERT dbo.backup_log ON;

	INSERT INTO dbo.backup_log (backup_id, execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, verification_start,  
		verification_end, verification_succeeded, copy_details, failed_copy_attempts, error_details)
	SELECT 
		BackupId,
        ExecutionId,
        BackupDate,
        [Database],
        BackupType,
        BackupPath,
        CopyToPath,
        BackupStart,
        BackupEnd,
        BackupSucceeded,
        VerificationCheckStart,
        VerificationCheckEnd,
        VerificationCheckSucceeded,
        CopyDetails,
		0,     --FailedCopyAttempts,
        ErrorDetails
	FROM 
		master.dbo.dba_DatabaseBackups_Log
	WHERE 
		BackupId NOT IN (SELECT backup_id FROM dbo.backup_log);

	SET IDENTITY_INSERT dbo.backup_log OFF;
END;

SELECT @objectId = [object_id] FROM master.sys.objects WHERE [name] = 'dba_DatabaseRestore_Log';
IF @objectId IS NOT NULL BEGIN;

	PRINT 'Importing Previous Data from restore log.... ';
	SET IDENTITY_INSERT dbo.restore_log ON;

	INSERT INTO dbo.restore_log (restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, 
		consistency_start, consistency_end, consistency_succeeded, dropped, error_details)
	SELECT 
		RestorationTestId,
        ExecutionId,
        TestDate,
        [Database],
        RestoredAs,
        RestoreStart,
		RestoreEnd,
        RestoreSucceeded,
        ConsistencyCheckStart,
        ConsistencyCheckEnd,
        ConsistencyCheckSucceeded,
        Dropped,
        ErrorDetails
	FROM 
		master.dbo.dba_DatabaseRestore_Log
	WHERE 
		RestorationTestId NOT IN (SELECT restore_test_id FROM dbo.restore_log);

	SET IDENTITY_INSERT dbo.restore_log OFF;

END;
GO

---------------------------------------------------------------------------
-- Make sure the admindb.dbo.restore_log.restored_files column exists ... 
---------------------------------------------------------------------------

USE [admindb];
GO

IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.restore_log') AND [name] = N'restored_files') BEGIN

	BEGIN TRANSACTION
		ALTER TABLE dbo.restore_log
			DROP CONSTRAINT DF_restore_log_test_date;

		ALTER TABLE dbo.restore_log
			DROP CONSTRAINT DF_restore_log_restore_succeeded;
			
		ALTER TABLE dbo.restore_log
			DROP CONSTRAINT DF_restore_log_dropped;
			
		CREATE TABLE dbo.Tmp_restore_log
			(
			restore_test_id int NOT NULL IDENTITY (1, 1),
			execution_id uniqueidentifier NOT NULL,
			test_date date NOT NULL,
			[database] sysname NOT NULL,
			restored_as sysname NOT NULL,
			restore_start datetime NOT NULL,
			restore_end datetime NULL,
			restore_succeeded bit NOT NULL,
			restored_files xml NULL,
			consistency_start datetime NULL,
			consistency_end datetime NULL,
			consistency_succeeded bit NULL,
			dropped varchar(20) NOT NULL,
			error_details nvarchar(MAX) NULL
			)  ON [PRIMARY];
			
		ALTER TABLE dbo.Tmp_restore_log ADD CONSTRAINT
			DF_restore_log_test_date DEFAULT (getdate()) FOR test_date;
			
		ALTER TABLE dbo.Tmp_restore_log ADD CONSTRAINT
			DF_restore_log_restore_succeeded DEFAULT ((0)) FOR restore_succeeded;
			
		ALTER TABLE dbo.Tmp_restore_log ADD CONSTRAINT
			DF_restore_log_dropped DEFAULT ('NOT-DROPPED') FOR dropped;
			
		SET IDENTITY_INSERT dbo.Tmp_restore_log ON;
			
				EXEC('INSERT INTO dbo.Tmp_restore_log (restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details)
				SELECT restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details FROM dbo.restore_log WITH (HOLDLOCK TABLOCKX)')
			
		SET IDENTITY_INSERT dbo.Tmp_restore_log OFF;
			
		DROP TABLE dbo.restore_log;
			
		EXECUTE sp_rename N'dbo.Tmp_restore_log', N'restore_log', 'OBJECT' ;
			
		ALTER TABLE dbo.restore_log ADD CONSTRAINT
			PK_restore_log PRIMARY KEY CLUSTERED 
			(
			restore_test_id
			) WITH( STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY];
			
	COMMIT;
END;
GO

---------------------------------------------------------------------------
-- Process UTC to local time change (v4.7). 
---------------------------------------------------------------------------

USE [admindb];
GO

DECLARE @currentVersion decimal(2,1); 
SELECT @currentVersion = MAX(CAST(LEFT(version_number, 3) AS decimal(2,1))) FROM [dbo].[version_history];

IF @currentVersion < 4.7 BEGIN 

	DECLARE @hoursDiff int; 
	SELECT @hoursDiff = DATEDIFF(HOUR, GETDATE(), GETUTCDATE());

	UPDATE dbo.[restore_log]
	SET 
		[restore_start] = DATEADD(HOUR, 0 - @hoursDiff, [restore_start]), 
		[restore_end] = DATEADD(HOUR, 0 - @hoursDiff, [restore_end]),
		[consistency_start] = DATEADD(HOUR, 0 - @hoursDiff, [consistency_start]),
		[consistency_end] = DATEADD(HOUR, 0 - @hoursDiff, [consistency_end])
	WHERE 
		[restore_test_id] > 0;

	PRINT 'Updated dbo.restore_log.... (UTC shift)';
END;
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 5. Cleanup and pre-v4 objects (i.e., in master db)... 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [master];
GO

-------------------------------------------------------------
-- Tables:
IF OBJECT_ID('dbo.dba_DatabaseBackups_Log','U') IS NOT NULL
	DROP TABLE dbo.dba_DatabaseBackups_Log;
GO

IF OBJECT_ID('dbo.dba_DatabaseRestore_Log','U') IS NOT NULL
	DROP TABLE dbo.dba_DatabaseRestore_Log;
GO

-- UDFs:
IF OBJECT_ID('dbo.dba_SplitString','TF') IS NOT NULL
	DROP FUNCTION dbo.dba_SplitString;
GO

-------------------------------------------------------------
-- Sprocs:
-- common:
IF OBJECT_ID('dbo.dba_CheckPaths','P') IS NOT NULL
	DROP PROC dbo.dba_CheckPaths;
GO

IF OBJECT_ID('dbo.dba_ExecuteAndFilterNonCatchableCommand','P') IS NOT NULL
	DROP PROC dbo.dba_ExecuteAndFilterNonCatchableCommand;
GO

IF OBJECT_ID('dbo.dba_LoadDatabaseNames','P') IS NOT NULL
	DROP PROC dbo.dba_LoadDatabaseNames;
GO

-- Backups:
IF OBJECT_ID('[dbo].[dba_RemoveBackupFiles]','P') IS NOT NULL
	DROP PROC [dbo].[dba_RemoveBackupFiles];
GO

IF OBJECT_ID('dbo.dba_BackupDatabases','P') IS NOT NULL
	DROP PROC dbo.dba_BackupDatabases;
GO

IF OBJECT_ID('dba_RestoreDatabases','P') IS NOT NULL
	DROP PROC dba_RestoreDatabases;
GO

IF OBJECT_ID('dba_VerifyBackupExecution', 'P') IS NOT NULL
	DROP PROC dbo.dba_VerifyBackupExecution;
GO

-------------------------------------------------------------
-- Potential FORMER versions of basic code (pre 1.0).

IF OBJECT_ID('dbo.dba_DatabaseBackups','P') IS NOT NULL
	DROP PROC dbo.dba_DatabaseBackups;
GO

IF OBJECT_ID('dbo.dba_ExecuteNonCatchableCommand','P') IS NOT NULL
	DROP PROC dbo.dba_ExecuteNonCatchableCommand;
GO

IF OBJECT_ID('dba_RestoreDatabases','P') IS NOT NULL
	DROP PROC dba_RestoreDatabases;
GO

IF OBJECT_ID('dbo.dba_DatabaseRestore_CheckPaths','P') IS NOT NULL
	DROP PROC dbo.dba_DatabaseRestore_CheckPaths;
GO

-------------------------------------------------------------
-- Potential FORMER versions of HA monitoring (pre 1.0):
IF OBJECT_ID('dbo.dba_AvailabilityGroups_HealthCheck','P') IS NOT NULL
	DROP PROC dbo.dba_AvailabilityGroups_HealthCheck;
GO

IF OBJECT_ID('dbo.dba_Mirroring_HealthCheck','P') IS NOT NULL
	DROP PROC dbo.dba_Mirroring_HealthCheck;
GO

--------------------------------------------------------------
-- Potential FORMER versions of alert filtering: 
IF OBJECT_ID('dbo.dba_FilterAndSendAlerts','P') IS NOT NULL BEGIN
	DROP PROC dbo.dba_FilterAndSendAlerts;
	SELECT 'NOTE: dbo.dba_FilterAndSendAlerts was dropped from master database - make sure to change job steps/names as needed.' [WARNING - Potential Configuration Changes Required (alert filtering)];
END;
GO


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 6. Deploy new/updated code.
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [admindb];
GO

---------------------------------------------------------------------------
-- Common Code:
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.get_engine_version','FN') IS NOT NULL
	DROP FUNCTION dbo.get_engine_version;
GO

CREATE FUNCTION dbo.get_engine_version() 
RETURNS decimal(4,2)
AS
	BEGIN 
		DECLARE @output decimal(4,2);
		
		DECLARE @major sysname, @minor sysname, @full sysname;
		SELECT 
			@major = CAST(SERVERPROPERTY('ProductMajorVersion') AS sysname), 
			@minor = CAST(SERVERPROPERTY('ProductMinorVersion') AS sysname), 
			@full = CAST(SERVERPROPERTY('ProductVersion') AS sysname); 

		IF @major IS NULL BEGIN
			SELECT @major = LEFT(@full, 2);
			SELECT @minor = REPLACE((SUBSTRING(@full, LEN(@major) + 2, 2)), N'.', N'');
		END;

		SET @output = CAST((@major + N'.' + @minor) AS decimal(4,2));

		RETURN @output;
	END;
GO




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
	IF @@SERVICENAME <> N'MSSQLSERVER'
		SET @serverName = N' -S .\' + @@SERVICENAME;
		
	SET @command = REPLACE(@command, '{0}', @serverName);

	--PRINT @command;

	INSERT INTO #Results (result)
	EXEC master.sys.xp_cmdshell @command;

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
	@Input				nvarchar(MAX),				-- [ALL] | [SYSTEM] | [USER] | [READ_FROM_FILESYSTEM] | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions			nvarchar(MAX)	= NULL,		-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities			nvarchar(MAX)	= NULL,		-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@Mode				sysname,					-- BACKUP | RESTORE | REMOVE | VERIFY | LIST
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
		RAISERROR('@Input cannot be null or empty - it must either be the specialized token [ALL], [SYSTEM], [USER], [READ_FROM_FILESYSTEM], or a comma-delimited list of databases/folders.', 16, 1);
		RETURN -1;
	END

	IF ISNULL(@Mode, N'') = N'' BEGIN;
		RAISERROR('@Mode cannot be null or empty - it must be one of the following values: BACKUP | RESTORE | REMOVE | VERIFY', 16, 1);
		RETURN -2;
	END
	
	IF UPPER(@Mode) NOT IN (N'BACKUP',N'RESTORE',N'REMOVE',N'VERIFY', N'LIST') BEGIN 
		RAISERROR('Permitted values for @Mode must be one of the following values: BACKUP | RESTORE | REMOVE | VERIFY | LIST', 16, 1);
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

    IF UPPER(@Input) IN (N'[ALL]', N'[SYSTEM]') BEGIN;
	    INSERT INTO @targets ([database_name])
        SELECT 'master' UNION SELECT 'msdb' UNION SELECT 'model';

		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
			IF @includeAdminDBAsSystemDatabase = 1 
				INSERT INTO @targets ([database_name])
				VALUES ('admindb');
		END
    END; 

    IF UPPER(@Input) IN (N'[ALL]', N'[USER]') BEGIN; 
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

	IF OBJECT_ID('dbo.load_default_path', 'FN') IS NULL BEGIN
		RAISERROR('S4 User Defined Function dbo.load_default_path not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

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

	IF(RIGHT(ISNULL(@CopyToBackupDirectory, N''), 1) = '\')
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


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.print_logins','P') IS NOT NULL
	DROP PROC dbo.print_logins;
GO

CREATE PROC dbo.print_logins 
	@TargetDatabases						nvarchar(MAX)			= N'[ALL]',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@DatabasePriorities						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL,
	@ExcludeMSAndServiceLogins				bit						= 1,
	@DisablePolicyChecks					bit						= 0,
	@DisableExpiryChecks					bit						= 0, 
	@ForceMasterAsDefaultDB					bit						= 0,
	@WarnOnLoginsHomedToOtherDatabases		bit						= 0				-- warns when a) set to 1, and b) default_db is NOT master NOR the current DB where the user is defined... (for a corresponding login).
AS
	SET NOCOUNT ON; 

	IF NULLIF(@TargetDatabases,'') IS NULL BEGIN
		RAISERROR('Parameter @TargetDatabases cannot be NULL or empty.', 16, 1)
		RETURN -1;
	END; 

	DECLARE @ignoredDatabases table (
		[database_name] sysname NOT NULL
	);

	DECLARE @ingnoredLogins table (
		[login_name] sysname NOT NULL 
	);

	DECLARE @ingoredUsers table (
		[user_name] sysname NOT NULL
	);

	CREATE TABLE #Users (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL
	);

	CREATE TABLE #Orphans (
		name sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL
	);

	SELECT * 
	INTO #SqlLogins
	FROM master.sys.sql_logins;

	DECLARE @name sysname;
	DECLARE @sid varbinary(85); 
	DECLARE @passwordHash varbinary(256);
	DECLARE @policyChecked nvarchar(3);
	DECLARE @expirationChecked nvarchar(3);
	DECLARE @defaultDb sysname;
	DECLARE @defaultLang sysname;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @info nvarchar(MAX);

	INSERT INTO @ignoredDatabases ([database_name])
	SELECT [result] [database_name] FROM admindb.dbo.[split_string](@ExcludedDatabases, N',');

	INSERT INTO @ingnoredLogins ([login_name])
	SELECT [result] [login_name] FROM [admindb].dbo.[split_string](@ExcludedLogins, N',');

	IF @ExcludeMSAndServiceLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM [admindb].dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',');		
	END;

	INSERT INTO @ingoredUsers ([user_name])
	SELECT [result] [user_name] FROM [admindb].dbo.[split_string](@ExcludedUsers, N',');

	-- remove ignored logins:
	DELETE l 
	FROM [#SqlLogins] l
	INNER JOIN @ingnoredLogins i ON l.[name] LIKE i.[login_name];	
			
	DECLARE @currentDatabase sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @principalsTemplate nvarchar(MAX) = N'SELECT name, [sid] FROM [{0}].sys.database_principals WHERE type = ''S'' AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'')';

	DECLARE @dbNames nvarchar(MAX); 
	EXEC admindb.dbo.[load_database_names]
		@Input = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@Priorities = @DatabasePriorities,
		@Mode = N'LIST',
		@Output = @dbNames OUTPUT;

	SET @TargetDatabases = @dbNames;

	DECLARE db_walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [result] 
	FROM admindb.dbo.[split_string](@TargetDatabases, N',');

	OPEN [db_walker];
	FETCH NEXT FROM [db_walker] INTO @currentDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN

		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
		PRINT '-- DATABASE: ' + @currentDatabase 
		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'

		DELETE FROM [#Users];
		DELETE FROM [#Orphans];

		SET @command = REPLACE(@principalsTemplate, N'{0}', @currentDatabase); 
		INSERT INTO #Users ([name], [sid])
		EXEC master.sys.sp_executesql @command;

		-- remove any ignored users: 
		DELETE u 
		FROM [#Users] u 
		INNER JOIN 
			@ingoredUsers i ON i.[user_name] LIKE u.[name];

		INSERT INTO #Orphans (name, [sid])
		SELECT 
			u.[name], 
			u.[sid]
		FROM 
			#Users u 
			INNER JOIN [#SqlLogins] l ON u.[sid] = l.[sid]
		WHERE
			l.[name] IS NULL OR l.[sid] IS NULL;

		SET @info = N'';

		-- Report on Orphans:
		SELECT @info = @info + 
			N'-- ORPHAN DETECTED: ' + [name] + N' (SID: ' + CONVERT(nvarchar(MAX), [sid], 2) + N')' + @crlf
		FROM 
			[#Orphans]
		ORDER BY 
			[name]; 

		IF NULLIF(@info,'') IS NOT NULL
			PRINT @info; 

		-- Report on differently-homed logins if/as directed:
		IF @WarnOnLoginsHomedToOtherDatabases = 1 BEGIN
			SET @info = N'';

			SELECT @info = @info +
				N'-- NOTE: Login ' + u.[name] + N' is set to use [' + l.[default_database_name] + N'] as its default database instead of [' + @currentDatabase + N'].'
			FROM 
				[#Users] u
				LEFT OUTER JOIN [#SqlLogins] l ON u.[sid] = l.[sid]
			WHERE 
				u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
				AND u.[name] NOT IN (SELECT [name] FROM #Orphans)
				AND l.default_database_name <> 'master'  -- master is fine... 
				AND l.default_database_name <> @currentDatabase; 				
				
			IF NULLIF(@info, N'') IS NOT NULL 
				PRINT @info;
		END;

		-- Output LOGINS:
		SET @info = N'';

		SELECT @info = @info +
			N'IF NOT EXISTS (SELECT NULL FROM master.sys.sql_logins WHERE [name] = ''' + u.[name] + N''') BEGIN ' 
			+ @crlf + @tab + N'CREATE LOGIN [' + u.[name] + N'] WITH '
			+ @crlf + @tab + @tab + N'PASSWORD = 0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' HASHED,'
			+ @crlf + @tab + N'SID = 0x' + CONVERT(nvarchar(MAX), u.[sid], 2) + N','
			+ @crlf + @tab + N'CHECK_EXPIRATION = ' + CASE WHEN (l.is_expiration_checked = 1 AND @DisableExpiryChecks = 0) THEN N'ON' ELSE N'OFF' END + N','
			+ @crlf + @tab + N'CHECK_POLICY = ' + CASE WHEN (l.is_policy_checked = 1 AND @DisablePolicyChecks = 0) THEN N'ON' ELSE N'OFF' END + N','
			+ @crlf + @tab + N'DEFAULT_DATABASE = [' + CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.default_database_name END + N'],'
			+ @crlf + @tab + N'DEFAULT_LANGUAGE = [' + l.default_language_name + N'];'
			+ @crlf + N'END;'
			+ @crlf
			+ @crlf
		FROM 
			#Users u
			INNER JOIN [#SqlLogins] l ON u.[sid] = l.[sid]
		WHERE 
			u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
			AND u.[name] NOT IN (SELECT name FROM #Orphans);
			
		IF NULLIF(@info, N'') IS NOT NULL
			PRINT @info;

		PRINT @crlf;

		FETCH NEXT FROM [db_walker] INTO @currentDatabase;
	END; 

	CLOSE [db_walker];
	DEALLOCATE [db_walker];

	RETURN 0;
GO


-----------------------------------
USE [admindb];

IF OBJECT_ID('dbo.script_server_logins','P') IS NOT NULL
	DROP PROC dbo.script_server_logins;
GO

CREATE PROC dbo.script_server_logins
	@TargetDatabases						nvarchar(MAX)			= N'[ALL]',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@DatabasePriorities						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL,
	@OutputPath								nvarchar(2000)			= N'[DEFAULT]',
	@CopyToPath								nvarchar(2000)			= NULL, 	
	@ExcludeMSAndServiceLogins				bit						= 1,
	@DisablePolicyChecks					bit						= 0,
	@DisableExpiryChecks					bit						= 0, 
	@ForceMasterAsDefaultDB					bit						= 0,
	@WarnOnLoginsHomedToOtherDatabases		bit						= 0,
	@AddServerNameToFileName				bit						= 1,
	@OperatorName							sysname					= N'Alerts',
	@MailProfileName						sysname					= N'General',
	@EmailSubjectPrefix						nvarchar(50)			= N'[Login Exports] ',	 
	@PrintOnly								bit						= 0	
AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.load_default_path', 'FN') IS NULL BEGIN
		RAISERROR('S4 User Defined Function dbo.load_default_path not defined - unable to continue.', 16, 1);
		RETURN -1;
	END
	
	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @edition sysname;
	SELECT @edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @edition = N'STANDARD' OR @edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @edition = 'WEB';
	END;
	
	IF @edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	IF (@PrintOnly = 0) AND (@edition <> 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

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
		DECLARE @databaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @databaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@OutputPath) = N'[DEFAULT]' BEGIN
		SELECT @OutputPath = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@OutputPath, N'') IS NULL BEGIN
		RAISERROR('@OutputPath cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF @PrintOnly = 1 BEGIN
		-- just process the sproc that prints outputs/details: 
		EXEC admindb.dbo.[print_logins]
		    @TargetDatabases = @TargetDatabases, 
		    @ExcludedDatabases = @ExcludedDatabases, 
		    @DatabasePriorities = @DatabasePriorities, 
		    @ExcludedLogins = @ExcludedLogins, 
		    @ExcludedUsers = @ExcludedUsers, 
		    @ExcludeMSAndServiceLogins = @ExcludeMSAndServiceLogins, 
		    @DisablePolicyChecks = @DisablePolicyChecks, 
		    @DisableExpiryChecks = @DisableExpiryChecks, 
		    @ForceMasterAsDefaultDB = @ForceMasterAsDefaultDB, 
		    @WarnOnLoginsHomedToOtherDatabases = @WarnOnLoginsHomedToOtherDatabases; 

		RETURN 0; 
	END; 

	-- if we're still here, we need to dynamically output/execute dbo.print_logins so that output is directed to a file (and copied if needed)
	--		while catching and alerting on any errors or problems. 

	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	-- normalize paths: 
	IF(RIGHT(@OutputPath, 1) = '\')
		SET @OutputPath = LEFT(@OutputPath, LEN(@OutputPath) - 1);

	IF(RIGHT(ISNULL(@CopyToPath, N''), 1) = '\')
		SET @CopyToPath = LEFT(@CopyToPath, LEN(@CopyToPath) - 1);

	DECLARE @outputFileName varchar(2000);
	SET @outputFileName = @OutputPath + '\' + CASE WHEN @AddServerNameToFileName = 1 THEN @@SERVERNAME + '_' ELSE '' END + N'Logins.sql';

	DECLARE @errors table ( 
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) 
	);

	DECLARE @xpCmdShellOutput table (
		result_id int IDENTITY(1,1) NOT NULL, 
		result nvarchar(MAX) NULL
	);

	-- Set up a 'translation' of the sproc call (for execution via xp_cmdshell): 
	DECLARE @sqlCommand varchar(MAX); 
	SET @sqlCommand = N'EXEC admindb.dbo.print_logins @TargetDatabases = N''{0}'', @ExcludedDatabases = N''{1}'', @DatabasePriorities = N''{2}'', @ExcludedLogins = N''{3}'', @ExcludedUsers = N''{4}'', '
		+ '@ExcludeMSAndServiceLogins = {5}, @DisablePolicyChecks = {6}, @DisableExpiryChecks = {7}, @ForceMasterAsDefaultDB = {8}, @WarnOnLoginsHomedToOtherDatabases = {9};';

	SET @sqlCommand = REPLACE(@sqlCommand, N'{0}', CAST(@TargetDatabases AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{1}', CAST(ISNULL(@ExcludedDatabases, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{2}', CAST(ISNULL(@DatabasePriorities, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{3}', CAST(ISNULL(@ExcludedLogins, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{4}', CAST(ISNULL(@ExcludedUsers, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{5}', CASE WHEN @ExcludeMSAndServiceLogins = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{6}', CASE WHEN @DisablePolicyChecks = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{7}', CASE WHEN @DisableExpiryChecks = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{8}', CASE WHEN @ForceMasterAsDefaultDB = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{9}', CASE WHEN @WarnOnLoginsHomedToOtherDatabases = 1 THEN '1' ELSE '0' END);

	IF LEN(@sqlCommand) > 8000 BEGIN 
		INSERT INTO @errors (error) VALUES ('Combined length of all input parameters to dbo.print_logins exceeds 8000 characters and can NOT be executed dynamically. DUMP/OUTPUT of logins can not and did NOT proceed as expected.')
		GOTO REPORTING;
	END; 

	DECLARE @command varchar(8000) = 'sqlcmd {0} -q "{1}" -o "{2}"';

	-- replace parameters: 
	SET @command = REPLACE(@command, '{0}', CASE WHEN UPPER(@@SERVICENAME) = 'MSSQLSERVER' THEN '' ELSE ' -S .\' + UPPER(@@SERVICENAME) END);
	SET @command = REPLACE(@command, '{1}', @sqlCommand);
	SET @command = REPLACE(@command, '{2}', @outputFileName);

	BEGIN TRY

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL; 

		IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 
			SET @errorDetails = N'';
			SELECT 
				@errorDetails = @errorDetails + [result] + @crlf + @tab
			FROM 
				@xpCmdShellOutput 
			ORDER BY 
				[result_id];

			SET @errorDetails = N'Unexpected problem while attempting to write logins to disk: ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

			INSERT INTO @errors (error) VALUES (@errorDetails);
		END


		-- Verify that the file was written as expected: 
		SET @command = 'for %a in ("' + @outputFileName + '") do @echo %~ta';
		DELETE FROM @xpCmdShellOutput; 

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DECLARE @timeStamp datetime; 
		SELECT @timeStamp = MAX(CAST([result] AS datetime)) FROM @xpCmdShellOutput WHERE [result] IS NOT NULL;

		IF DATEDIFF(MINUTE, @timeStamp, GETDATE()) > 2 BEGIN 
			SET @errorDetails = N'TimeStamp for [' + @outputFileName + N'] reads ' + CONVERT(nvarchar(30), @timeStamp, 120) + N'. Current Execution Time is: ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'. File writing operations did NOT throw an error, but time-stamp difference shows ' + @outputFileName + N' file was NOT written as expected.' ;
			
			INSERT INTO @errors (error) VALUES (@errorDetails);
		END;

		-- copy the file if/as needed:
		IF @CopyToPath IS NOT NULL BEGIN

			DELETE FROM @xpCmdShellOutput;
			SET @command = 'COPY "{0}" "{1}\"';

			SET @command = REPLACE(@command, '{0}', @outputFileName);
			SET @command = REPLACE(@command, '{1}', @CopyToPath);

			INSERT INTO @xpCmdShellOutput ([result])
			EXEC master.sys.[xp_cmdshell] @command;

			DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL OR [result] LIKE '%1 file(s) copied.%'; 

			IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 

				SET @errorDetails = N'';
				SELECT 
					@errorDetails = @errorDetails + [result] + @crlf + @tab
				FROM 
					@xpCmdShellOutput 
				ORDER BY 
					[result_id];

				SET @errorDetails = N'Unexpected problem while copying file from @OutputPath to @CopyFilePath : ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

				INSERT INTO @errors (error) VALUES (@errorDetails);
			END 
		END;

	END TRY 
	BEGIN CATCH
		SET @errorDetails = N'Unexpected Exception while executing command: [' + ISNULL(@command, N'#ERROR#') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

		INSERT INTO @errors (error) VALUES (@errorDetails);
	END CATCH
	

REPORTING: 
	IF EXISTS (SELECT NULL FROM @errors) BEGIN
		DECLARE @emailErrorMessage nvarchar(MAX) = N'The following errors were encountered: ' + @crlf + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + N'- ' + [error] + @crlf
		FROM 
			@errors
		ORDER BY 
			error_id;

		DECLARE @emailSubject nvarchar(2000);
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
	
		IF @edition <> 'EXPRESS' BEGIN;
			EXEC msdb.dbo.sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;		

	END;

	RETURN 0;
GO








-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.print_configuration','P') IS NOT NULL
	DROP PROC dbo.print_configuration;
GO

CREATE PROC dbo.print_configuration 

AS
	SET NOCOUNT ON;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- meta / formatting: 
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);

	DECLARE @sectionMarker nvarchar(2000) = N'--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
	
	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Hardware: 
	PRINT @sectionMarker;
	PRINT N'-- Hardware'
	PRINT @sectionMarker;	

	DECLARE @output nvarchar(MAX) = @crlf + @tab;
	SET @output = @output + N'-- Processors' + @crlf; 

	SELECT @output = @output
		+ @tab + @tab + N'PhysicalCpuCount: ' + CAST(cpu_count/hyperthread_ratio AS sysname) + @crlf
		+ @tab + @tab + N'HyperthreadRatio: ' + CAST([hyperthread_ratio] AS sysname) + @crlf
		+ @tab + @tab + N'LogicalCpuCount: ' + CAST(cpu_count AS sysname) + @crlf
	FROM 
		sys.dm_os_sys_info;

	DECLARE @cpuFamily sysname; 
	EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', N'ProcessorNameString', @cpuFamily OUT;

	SET @output = @output + @tab + @tab + N'ProcessorFamily: ' + @cpuFamily + @crlf;
	PRINT @output;

	SET @output = @crlf + @tab + N'-- Memory' + @crlf;
	SELECT @output = @output + @tab + @tab + N'PhysicalMemoryOnServer: ' + CAST(physical_memory_kb/1024 AS sysname) + N'MB ' + @crlf FROM sys.[dm_os_sys_info];
	SET @output = @output + @tab + @tab + N'MemoryNodes: ' + @crlf;

	SELECT @output = @output 
		+ @tab + @tab + @tab + N'NODE_ID: ' + CAST(node_id AS sysname) + N' - ' + node_state_desc + N' (OnlineSchedulerCount: ' + CAST(online_scheduler_count AS sysname) + N', CpuAffinity: ' + CAST(cpu_affinity_mask AS sysname) + N')' + @crlf
	FROM sys.dm_os_nodes;
	
	PRINT @output;

	SET @output = @crlf + @crlf + @tab + N'-- Disks' + @crlf;

	DECLARE @disks table (
		[volume_mount_point] nvarchar(256) NULL,
		[file_system_type] nvarchar(256) NULL,
		[logical_volume_name] nvarchar(256) NULL,
		[total_gb] decimal(18,2) NULL,
		[available_gb] decimal(18,2) NULL
	);

	INSERT INTO @disks ([volume_mount_point], [file_system_type], [logical_volume_name], [total_gb], [available_gb])
	SELECT DISTINCT 
		vs.volume_mount_point, 
		vs.file_system_type, 
		vs.logical_volume_name, 
		CONVERT(DECIMAL(18,2),vs.total_bytes/1073741824.0) AS [total_gb],
		CONVERT(DECIMAL(18,2), vs.available_bytes/1073741824.0) AS [available_gb]  
	FROM 
		sys.master_files AS f
		CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs; 

	SELECT @output = @output
		+ @tab + @tab + volume_mount_point + @crlf + @tab + @tab + @tab + N'Label: ' + logical_volume_name + N', FileSystem: ' + file_system_type + N', TotalGB: ' + CAST([total_gb] AS sysname)  + N', AvailableGB: ' + CAST([available_gb] AS sysname) + @crlf
	FROM 
		@disks 
	ORDER BY 
		[volume_mount_point];	

	PRINT @output + @crlf;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process Installation Details:
	PRINT @sectionMarker;
	PRINT N'-- Installation Details'
	PRINT @sectionMarker;

	DECLARE @properties table (
		row_id int IDENTITY(1,1) NOT NULL, 
		segment_name sysname, 
		property_name sysname
	);

	INSERT INTO @properties (segment_name, property_name)
	VALUES 
	(N'ProductDetails', 'Edition'), 
	(N'ProductDetails', 'ProductLevel'), 
	(N'ProductDetails', 'ProductUpdateLevel'),
	(N'ProductDetails', 'ProductVersion'),
	(N'ProductDetails', 'ProductMajorVersion'),
	(N'ProductDetails', 'ProductMinorVersion'),

	(N'InstanceDetails', 'ServerName'),
	(N'InstanceDetails', 'InstanceName'),
	(N'InstanceDetails', 'IsClustered'),
	(N'InstanceDetails', 'Collation'),

	(N'InstanceFeatures', 'FullTextInstalled'),
	(N'InstanceFeatures', 'IntegratedSecurityOnly'),
	(N'InstanceFeatures', 'FilestreamConfiguredLevel'),
	(N'InstanceFeatures', 'HadrEnabled'),
	(N'InstanceFeatures', 'InstanceDefaultDataPath'),
	(N'InstanceFeatures', 'InstanceDefaultLogPath'),
	(N'InstanceFeatures', 'ErrorLogFileName'),
	(N'InstanceFeatures', 'BuildClrVersion');

	DECLARE propertyizer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		segment_name,
		property_name 
	FROM 
		@properties
	ORDER BY 
		row_id;

	DECLARE @segment sysname; 
	DECLARE @propertyName sysname;
	DECLARE @propertyValue sysname;
	DECLARE @segmentFamily sysname = N'';

	DECLARE @sql nvarchar(MAX);

	OPEN propertyizer; 

	FETCH NEXT FROM propertyizer INTO @segment, @propertyName;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @sql = N'SELECT @output = CAST(SERVERPROPERTY(''' + @propertyName + N''') as sysname);';

		EXEC sys.sp_executesql 
			@stmt = @sql, 
			@params = N'@output sysname OUTPUT', 
			@output = @propertyValue OUTPUT;

		IF @segment <> @segmentFamily BEGIN 
			SET @segmentFamily = @segment;

			PRINT @crlf + @tab + N'-- ' + @segmentFamily;
		END 
		
		PRINT @tab + @tab + @propertyName + ': ' + ISNULL(@propertyValue, N'NULL');

		FETCH NEXT FROM propertyizer INTO @segment, @propertyName;
	END;

	CLOSE propertyizer; 
	DEALLOCATE propertyizer;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Output Service Details:
	PRINT @crlf + @crlf;
	PRINT @sectionMarker;
	PRINT N'-- Service Details'
	PRINT @sectionMarker;	

	DECLARE @memoryType sysname = N'CONVENTIONAL';
	IF EXISTS (SELECT NULL FROM sys.dm_os_memory_nodes WHERE [memory_node_id] <> 64 AND [locked_page_allocations_kb] <> 0) 
		SET @memoryType = N'LOCKED';


	PRINT @crlf + @tab + N'-- LPIM CONFIG: ' +  @crlf + @tab + @tab + @memoryType;

	DECLARE @command nvarchar(MAX);
	SET @command = N'SELECT 
	servicename, 
	startup_type_desc, 
	service_account, 
	is_clustered, 
	cluster_nodename, 
	[filename] [path], 
	{0} ifi_enabled 
FROM 
	sys.dm_server_services;';	

	IF ((SELECT admindb.dbo.get_engine_version()) >= 13.00) -- ifi added to 2016+
		SET @command = REPLACE(@command, N'{0}', 'instant_file_initialization_enabled');
	ELSE 
		SET @command = REPLACE(@command, N'{0}', '''?''');


	DECLARE @serviceDetails table (
		[servicename] nvarchar(256) NOT NULL,
		[startup_type_desc] nvarchar(256) NOT NULL,
		[service_account] nvarchar(256) NOT NULL,
		[is_clustered] nvarchar(1) NOT NULL,
		[cluster_nodename] nvarchar(256) NULL,
		[path] nvarchar(256) NOT NULL,
		[ifi_enabled] nvarchar(1) NOT NULL
	);
	
	INSERT INTO @serviceDetails ([servicename],  [startup_type_desc], [service_account], [is_clustered], [cluster_nodename], [path], [ifi_enabled])
	EXEC master.sys.[sp_executesql] @command;

	SET @output = @crlf + @tab;

	SELECT 
		@output = @output 
		+ N'-- ' + [servicename] + @crlf 
		+ @tab + @tab + N'StartupType: ' + [startup_type_desc] + @crlf 
		+ @tab + @tab + N'ServiceAccount: ' + service_account + @crlf 
		+ @tab + @tab + N'IsClustered: ' + [is_clustered] + CASE WHEN [cluster_nodename] IS NOT NULL THEN + N' (' + cluster_nodename + N')' ELSE N'' END + @crlf  
		+ @tab + @tab + N'FilePath: ' + [path] + @crlf
		+ @tab + @tab + N'IFI Enabled: ' + [ifi_enabled] + @crlf + @crlf + @tab

	FROM 
		@serviceDetails;


	PRINT @output;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- TODO: Cluster Details (if/as needed). 


	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Global Trace Flags
	DECLARE @traceFlags table (
		[trace_flag] [int] NOT NULL,
		[status] [bit] NOT NULL,
		[global] [bit] NOT NULL,
		[session] [bit] NOT NULL
	)

	INSERT INTO @traceFlags (trace_flag, [status], [global], [session])
	EXECUTE ('DBCC TRACESTATUS() WITH NO_INFOMSGS');

	PRINT @sectionMarker;
	PRINT N'-- Trace Flags'
	PRINT @sectionMarker;

	SET @output = N'' + @crlf;

	SELECT @output = @output 
		+ @tab + N'-- ' + CAST([trace_flag] AS sysname) + N': ' + CASE WHEN [status] = 1 THEN 'ENABLED' ELSE 'DISABLED' END + @crlf
	FROM 
		@traceFlags 
	WHERE 
		[global] = 1;

	PRINT @output + @crlf;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Configuration Settings (outside of norms): 

	DECLARE @config_defaults TABLE (
		[name] nvarchar(35) NOT NULL,
		default_value sql_variant NOT NULL
	);

	INSERT INTO @config_defaults (name, default_value) VALUES 
	('access check cache bucket count',0),
	('access check cache quota',0),
	('Ad Hoc Distributed Queries',0),
	('affinity I/O mask',0),
	('affinity mask',0),
	('affinity64 I/O mask',0),
	('affinity64 mask',0),
	('Agent XPs',1),
	('allow polybase export', 0),
	('allow updates',0),
	('automatic soft-NUMA disabled', 0), -- default is good in best in most cases
	('awe enabled',0),
	('backup checksum default', 0), -- this should really be 1
	('backup compression default',0),
	('blocked process threshold (s)',0),
	('c2 audit mode',0),
	('clr enabled',0),
	('clr strict', 1), -- 2017+ (enabled by default)
	('common criteria compliance enabled',0),
	('contained database authentication', 0),
	('cost threshold for parallelism',5),
	('cross db ownership chaining',0),
	('cursor threshold',-1),
	('Database Mail XPs',0),
	('default full-text language',1033),
	('default language',0),
	('default trace enabled',1),
	('disallow results from triggers',0),
	('EKM provider enabled',0),
	('external scripts enabled',0),  -- 2016+
	('filestream access level',0),
	('fill factor (%)',0),
	('ft crawl bandwidth (max)',100),
	('ft crawl bandwidth (min)',0),
	('ft notify bandwidth (max)',100),
	('ft notify bandwidth (min)',0),
	('index create memory (KB)',0),
	('in-doubt xact resolution',0),
	('hadoop connectivity', 0),  -- 2016+
	('lightweight pooling',0),
	('locks',0),
	('max degree of parallelism',0),
	('max full-text crawl range',4),
	('max server memory (MB)',2147483647),
	('max text repl size (B)',65536),
	('max worker threads',0),
	('media retention',0),
	('min memory per query (KB)',1024),
	('min server memory (MB)',0), -- NOTE: SQL Server apparently changes this one 'in-flight' on a regular basis
	('nested triggers',1),
	('network packet size (B)',4096),
	('Ole Automation Procedures',0),
	('open objects',0),
	('optimize for ad hoc workloads',0),
	('PH timeout (s)',60),
	('polybase network encryption',1),
	('precompute rank',0),
	('priority boost',0),
	('query governor cost limit',0),
	('query wait (s)',-1),
	('recovery interval (min)',0),
	('remote access',1),
	('remote admin connections',0),
	('remote data archive',0),
	('remote login timeout (s)',10),
	('remote proc trans',0),
	('remote query timeout (s)',600),
	('Replication XPs',0),
	('scan for startup procs',0),
	('server trigger recursion',1),
	('set working set size',0),
	('show advanced options',0),
	('SMO and DMO XPs',1),
	('SQL Mail XPs',0),
	('transform noise words',0),
	('two digit year cutoff',2049),
	('user connections',0),
	('user options',0),
	('xp_cmdshell',0);

	PRINT @sectionMarker;
	PRINT N'-- Modified Configuration Options'
	PRINT @sectionMarker;	

	SET @output = N'';

	SELECT @output = @output +
		+ @tab + N'-- ' + c.[name] + @crlf
		+ @tab + @tab + N'DEFAULT: ' + CAST([d].[default_value] AS sysname) + @crlf
		+ @tab + @tab + N'VALUE_IN_USE: ' +  CAST(c.[value_in_use] AS sysname) + @crlf
		+ @tab + @tab + N'VALUE: ' + CAST(c.[value] AS sysname) + @crlf + @crlf
	FROM sys.configurations c 
	INNER JOIN @config_defaults d ON c.name = d.name
	WHERE
		c.value <> c.value_in_use
		OR c.value_in_use <> d.default_value;
	

	PRINT @output;


		-- Server Log - config setttings (path and # to keep/etc.)

		-- base paths - backups, data, log... 

		-- count of all logins... 
		-- list of all logins with SysAdmin membership.

		-- list of all dbs, files/file-paths... and rough sizes/details. 

		-- DDL triggers. 

		-- endpoints. 

		-- linked servers. 

		-- credentials (list and detail - sans passwords/sensitive info). 

		-- Resource Governor Pools/settings/etc. 

		-- Audit Specs? (yes - though... guessing they're hard-ish to script?)  -- and these are things i can add-in later - i.e., 30 - 60 minutes here/there to add in audits, XEs, and the likes... 

		-- XEs ? (yeah... why not). 

		-- Mirrored DB configs. (partners, listeners, certs, etc.)

		-- AG configs + listeners and such. 

		-- replication pubs and subs

		-- Mail Settings. Everything. 
			-- profiles and which one is the default. 
			--		list of accounts per profile (in ranked order)
			-- accounts and all details. 


		-- SQL Server Agent - 
			-- config settings. 
			-- operators
			-- alerts
			-- operators
			-- JOBS... all of 'em.  (guessing I can FIND a script that'll do this for me - i.e., someone else has likely written it).


	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.script_server_configuration','P') IS NOT NULL
	DROP PROC dbo.script_server_configuration;
GO

CREATE PROC dbo.script_server_configuration 
	@OutputPath								nvarchar(2000)			= N'[DEFAULT]',
	@CopyToPath								nvarchar(2000)			= NULL, 
	@AddServerNameToFileName				bit						= 1, 
	@OperatorName							sysname					= N'Alerts',
	@MailProfileName						sysname					= N'General',
	@EmailSubjectPrefix						nvarchar(50)			= N'[Server Configuration Export] ',	 
	@PrintOnly								bit						= 0	

AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
    IF OBJECT_ID('dbo.get_engine_version', 'FN') IS NULL BEGIN
        RAISERROR('S4 UDF dbo.get_engine_version not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;

	IF OBJECT_ID('dbo.load_default_path', 'FN') IS NULL BEGIN
		RAISERROR('S4 User Defined Function dbo.load_default_path not defined - unable to continue.', 16, 1);
		RETURN -1;
	END
	
	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @edition sysname;
	SELECT @edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @edition = N'STANDARD' OR @edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @edition = 'WEB';
	END;
	
	IF @edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	IF (@PrintOnly = 0) AND (@edition <> 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

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
		DECLARE @databaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @databaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@OutputPath) = N'[DEFAULT]' BEGIN
		SELECT @OutputPath = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@OutputPath, N'') IS NULL BEGIN
		RAISERROR('@OutputPath cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF @PrintOnly = 1 BEGIN 
		
		-- just execute the sproc that prints info to the screen: 
		EXEC admindb.dbo.print_configuration;

		RETURN 0;
	END; 


	-- if we're still here, we need to dynamically output/execute dbo.print_configuration so that output is directed to a file (and copied if needed)
	--		while catching and alerting on any errors or problems. 
	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	-- normalize paths: 
	IF(RIGHT(@OutputPath, 1) = '\')
		SET @OutputPath = LEFT(@OutputPath, LEN(@OutputPath) - 1);

	IF(RIGHT(ISNULL(@CopyToPath, N''), 1) = '\')
		SET @CopyToPath = LEFT(@CopyToPath, LEN(@CopyToPath) - 1);

	DECLARE @outputFileName varchar(2000);
	SET @outputFileName = @OutputPath + '\' + CASE WHEN @AddServerNameToFileName = 1 THEN @@SERVERNAME + '_' ELSE '' END + N'Server_Configuration.txt';

	DECLARE @errors table ( 
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) 
	);

	DECLARE @xpCmdShellOutput table (
		result_id int IDENTITY(1,1) NOT NULL, 
		result nvarchar(MAX) NULL
	);

	-- Set up a 'translation' of the sproc call (for execution via xp_cmdshell): 
	DECLARE @sqlCommand varchar(MAX); 
	SET @sqlCommand = N'EXEC admindb.dbo.print_configuration;';

	DECLARE @command varchar(8000) = 'sqlcmd {0} -q "{1}" -o "{2}"';

	-- replace parameters: 
	SET @command = REPLACE(@command, '{0}', CASE WHEN UPPER(@@SERVICENAME) = 'MSSQLSERVER' THEN '' ELSE ' -S .\' + UPPER(@@SERVICENAME) END);
	SET @command = REPLACE(@command, '{1}', @sqlCommand);
	SET @command = REPLACE(@command, '{2}', @outputFileName);

	BEGIN TRY

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL; 

		IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 
			SET @errorDetails = N'';
			SELECT 
				@errorDetails = @errorDetails + [result] + @crlf + @tab
			FROM 
				@xpCmdShellOutput 
			ORDER BY 
				[result_id];

			SET @errorDetails = N'Unexpected problem while attempting to write configuration details to disk: ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

			INSERT INTO @errors (error) VALUES (@errorDetails);
		END
		
		-- Verify that the file was written as expected: 
		SET @command = 'for %a in ("' + @outputFileName + '") do @echo %~ta';
		DELETE FROM @xpCmdShellOutput; 

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DECLARE @timeStamp datetime; 
		SELECT @timeStamp = MAX(CAST([result] AS datetime)) FROM @xpCmdShellOutput WHERE [result] IS NOT NULL;

		IF DATEDIFF(MINUTE, @timeStamp, GETDATE()) > 2 BEGIN 
			SET @errorDetails = N'TimeStamp for [' + @outputFileName + N'] reads ' + CONVERT(nvarchar(30), @timeStamp, 120) + N'. Current Execution Time is: ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'. File writing operations did NOT throw an error, but time-stamp difference shows ' + @outputFileName + N' file was NOT written as expected.' ;
			
			INSERT INTO @errors (error) VALUES (@errorDetails);
		END;

		-- copy the file if/as needed:
		IF @CopyToPath IS NOT NULL BEGIN

			DELETE FROM @xpCmdShellOutput;
			SET @command = 'COPY "{0}" "{1}\"';

			SET @command = REPLACE(@command, '{0}', @outputFileName);
			SET @command = REPLACE(@command, '{1}', @CopyToPath);

			INSERT INTO @xpCmdShellOutput ([result])
			EXEC master.sys.[xp_cmdshell] @command;

			DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL OR [result] LIKE '%1 file(s) copied.%'; 

			IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 

				SET @errorDetails = N'';
				SELECT 
					@errorDetails = @errorDetails + [result] + @crlf + @tab
				FROM 
					@xpCmdShellOutput 
				ORDER BY 
					[result_id];

				SET @errorDetails = N'Unexpected problem while copying file from @OutputPath to @CopyFilePath : ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

				INSERT INTO @errors (error) VALUES (@errorDetails);
			END 
		END;

	END TRY 
	BEGIN CATCH
		SET @errorDetails = N'Unexpected Exception while executing command: [' + ISNULL(@command, N'#ERROR#') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

		INSERT INTO @errors (error) VALUES (@errorDetails);
	END CATCH

REPORTING: 
	IF EXISTS (SELECT NULL FROM @errors) BEGIN
		DECLARE @emailErrorMessage nvarchar(MAX) = N'The following errors were encountered: ' + @crlf + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + N'- ' + [error] + @crlf
		FROM 
			@errors
		ORDER BY 
			error_id;

		DECLARE @emailSubject nvarchar(2000);
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
	
		IF @edition <> 'EXPRESS' BEGIN;
			EXEC msdb.dbo.sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;		

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
    @DatabasesToExclude				nvarchar(MAX)	= NULL,
    @Priorities						nvarchar(MAX)	= NULL,
    @BackupsRootPath				nvarchar(MAX)	= N'[DEFAULT]',
    @RestoredRootDataPath			nvarchar(MAX)	= N'[DEFAULT]',
    @RestoredRootLogPath			nvarchar(MAX)	= N'[DEFAULT]',
    @RestoredDbNamePattern			nvarchar(40)	= N'{0}_test',
    @AllowReplace					nchar(7)		= NULL,				-- NULL or the exact term: N'REPLACE'...
    @SkipLogBackups					bit				= 0,
	@ExecuteRecovery				bit				= 1,
    @CheckConsistency				bit				= 1,
    @DropDatabasesAfterRestore		bit				= 0,				-- Only works if set to 1, and if we've RESTORED the db in question. 
    @MaxNumberOfFailedDrops			int				= 1,				-- number of failed DROP operations we'll tolerate before early termination.
    @OperatorName					sysname			= N'Alerts',
    @MailProfileName				sysname			= N'General',
    @EmailSubjectPrefix				nvarchar(50)	= N'[RESTORE TEST] ',
    @PrintOnly						bit				= 0
AS
    SET NOCOUNT ON;

    -- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
    IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN
        RAISERROR('S4 Table dbo.restore_log not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;
    
    IF OBJECT_ID('dbo.get_engine_version', 'FN') IS NULL BEGIN
        RAISERROR('S4 UDF dbo.get_engine_version not defined - unable to continue.', 16, 1);
        RETURN -1;
    END;

	IF OBJECT_ID('dbo.load_backup_files', 'P') IS NULL BEGIN 
		RAISERROR('S4 Stored Procedure dbo.load_backup_files not defined - unable to continue.', 16, 1);
        RETURN -1;
	END; 

	IF OBJECT_ID('dbo.load_header_details', 'P') IS NULL BEGIN 
		RAISERROR('S4 Stored Procedure dbo.load_header_details not defined - unable to continue.', 16, 1);
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

	IF @ExecuteRecovery = 0 AND @DropDatabasesAfterRestore = 1 BEGIN
		RAISERROR(N'@ExecuteRecovery cannot be set to false (0) when @DropDatabasesAfterRestore is set to true (1).', 16, 1);
		RETURN -5;
	END;

    IF @MaxNumberOfFailedDrops <= 0 BEGIN
        RAISERROR('@MaxNumberOfFailedDrops must be set to a value of 1 or higher.', 16, 1);
        RETURN -6;
    END;

    IF NULLIF(@AllowReplace, '') IS NOT NULL AND UPPER(@AllowReplace) <> N'REPLACE' BEGIN
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

    IF (@DatabasesToExclude IS NOT NULL) AND (UPPER(@DatabasesToRestore) <> N'[READ_FROM_FILESYSTEM]') BEGIN
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
    DECLARE @executeDropAllowed bit;
    DECLARE @failedDropCount int = 0;

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
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;
    
    EXEC dbo.check_paths @RestoredRootDataPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@RestoredRootDataPath (' + @RestoredRootDataPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    EXEC dbo.check_paths @RestoredRootLogPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@RestoredRootLogPath (' + @RestoredRootLogPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

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

    IF NOT EXISTS (SELECT NULL FROM @dbsToRestore) BEGIN
        RAISERROR('No Databases Specified to Restore. Please Check inputs for @DatabasesToRestore + @DatabasesToExclude and retry.', 16, 1);
        RETURN -20;
    END;

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
	DECLARE @fileList nvarchar(MAX); 
	DECLARE @backupName sysname;
	DECLARE @fileListXml nvarchar(MAX);

	DECLARE @logFilesToRestore table ( 
		id int IDENTITY(1,1) NOT NULL, 
		log_file sysname NOT NULL
	);
	DECLARE @currentLogFileID int = 0;

	DECLARE @restoredFiles table (
		ID int IDENTITY(1,1) NOT NULL, 
		[FileName] nvarchar(400) NOT NULL, 
		Detected datetime NOT NULL, 
		BackupCreated datetime NULL, 
		Applied datetime NULL, 
		BackupSize bigint NULL, 
		Compressed bit NULL, 
		[Encrypted] bit NULL
	); 

	DECLARE @backupDate datetime, @backupSize bigint, @compressed bit, @encrypted bit;

    -- Assemble a list of dbs (if any) that were NOT dropped during the last execution (only) - so that we can drop them before proceeding. 
    DECLARE @NonDroppedFromPreviousExecution table( 
        [Database] sysname NOT NULL, 
        RestoredAs sysname NOT NULL
    );

    DECLARE @LatestBatch uniqueidentifier;
    SELECT @LatestBatch = (SELECT TOP(1) execution_id FROM dbo.restore_log ORDER BY restore_test_id DESC);

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
    END;

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
	IF (SELECT admindb.dbo.get_engine_version()) >= 13.0 BEGIN
        ALTER TABLE #FileList ADD SnapshotURL nvarchar(360) NULL;
    END;

    DECLARE @command nvarchar(2000);

    OPEN restorer;

    FETCH NEXT FROM restorer INTO @databaseToRestore;
    WHILE @@FETCH_STATUS = 0 BEGIN
        
		-- reset every 'loop' through... 
        SET @statusDetail = NULL; 
        DELETE FROM @restoredFiles;
		
		SET @restoredName = REPLACE(@RestoredDbNamePattern, N'{0}', @databaseToRestore);
        IF (@restoredName = @databaseToRestore) AND (@RestoredDbNamePattern != '{0}') -- then there wasn't a {0} token - so set @restoredName to @RestoredDbNamePattern
            SET @restoredName = @RestoredDbNamePattern;  -- which seems odd, but if they specified @RestoredDbNamePattern = 'Production2', then that's THE name they want...

        IF @PrintOnly = 0 BEGIN
            INSERT INTO dbo.restore_log (execution_id, [database], restored_as, restore_start, error_details)
            VALUES (@executionID, @databaseToRestore, @restoredName, GETDATE(), '#UNKNOWN ERROR#');

            SELECT @restoreLogId = SCOPE_IDENTITY();
        END;

        -- Verify Path to Source db's backups:
        SET @sourcePath = @BackupsRootPath + N'\' + @databaseToRestore;
        EXEC dbo.check_paths @sourcePath, @isValid OUTPUT;
        IF @isValid = 0 BEGIN 
            SET @statusDetail = N'The backup path: ' + @sourcePath + ' is invalid;';
            GOTO NextDatabase;
        END;

        -- Determine how to respond to an attempt to overwrite an existing database (i.e., is it explicitly confirmed or... should we throw an exception).
        IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN
            
            -- if this is a 'failure' from a previous execution, drop the DB and move on, otherwise, make sure we are explicitly configured to REPLACE. 
            IF EXISTS (SELECT NULL FROM @NonDroppedFromPreviousExecution WHERE [Database] = @databaseToRestore AND RestoredAs = @restoredName) BEGIN
                SET @command = N'DROP DATABASE [' + @restoredName + N'];';
                
				IF @PrintOnly = 1 BEGIN
						PRINT N'-- ' + @command + N'   -- dropping target database because it SOMEHOW was not cleaned up during latest operation (immediately prior) to this restore test. (Could be that the db is still restoring...)';
				  END;
				ELSE BEGIN
					EXEC dbo.execute_uncatchable_command @command, 'DROP', @result = @outcome OUTPUT;
					SET @statusDetail = @outcome;
				END;
                IF @statusDetail IS NOT NULL BEGIN
                    GOTO NextDatabase;
                END;
              END;
            ELSE BEGIN
                IF ISNULL(@AllowReplace, '') <> N'REPLACE' BEGIN
                    SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
                    GOTO NextDatabase;
                END;
            END;
        END;

		-- Check for a FULL backup: 
		EXEC dbo.load_backup_files @DatabaseToRestore = @databaseToRestore, @SourcePath = @sourcePath, @Mode = N'FULL', @Output = @fileList OUTPUT;
		
		IF(NULLIF(@fileList,N'') IS NULL) BEGIN
			SET @statusDetail = N'No FULL backups found for database [' + @databaseToRestore + N'] found in "' + @sourcePath + N'".';
			GOTO NextDatabase;	
		END;

        -- Load Backup details/etc. 
		SELECT @backupName = @fileList;
		SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName;

		-- define the list of files to be processed:
		INSERT INTO @restoredFiles ([FileName], [Detected])
		SELECT 
			@backupName, 
			GETDATE(); -- detected (i.e., when this file was 'found' and 'added' for processing).  

        -- Query file destinations:
        SET @move = N'';
        SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

        IF @PrintOnly = 1 BEGIN
            PRINT N'-- ' + @command;
        END;

        BEGIN TRY 
            DELETE FROM #FileList;
            INSERT INTO #FileList -- shorthand syntax is usually bad, but... whatever. 
            EXEC sys.sp_executesql @command;
        END TRY
        BEGIN CATCH
            SELECT @statusDetail = N'Unexpected Error Restoring FileList: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            
            GOTO NextDatabase;
        END CATCH;
    
        -- Make sure we got some files (i.e. RESTORE FILELIST doesn't always throw exceptions if the path you send it sucks):
        IF ((SELECT COUNT(*) FROM #FileList) < 2) BEGIN
            SET @statusDetail = N'The backup located at [' + @pathToDatabaseBackup + N'] is invalid, corrupt, or does not contain a viable FULL backup.';
            GOTO NextDatabase;
        END ;
        
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
        END;

        CLOSE mover;
        DEALLOCATE mover;

        SET @move = LEFT(@move, LEN(@move) - 1); -- remove the trailing ", "... 

        -- IF we're going to allow an explicit REPLACE, start by putting the target DB into SINGLE_USER mode: 
        IF @AllowReplace = N'REPLACE' BEGIN
            
            -- only attempt to set to single-user mode if ONLINE (i.e., if somehow stuck in restoring... don't bother, just replace):
            IF EXISTS(SELECT NULL FROM sys.databases WHERE name = @restoredName AND state_desc = 'ONLINE') BEGIN

                BEGIN TRY 
                    SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName, N'[]') + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';

                    IF @PrintOnly = 1 BEGIN
                        PRINT @command;
                      END;
                    ELSE BEGIN
                        SET @outcome = NULL;
                        EXEC dbo.execute_uncatchable_command @command, 'ALTER', @result = @outcome OUTPUT;
                        SET @statusDetail = @outcome;
                    END;

                    -- give things just a second to 'die down':
                    WAITFOR DELAY '00:00:02';

                END TRY
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while setting target database: [' + @restoredName + N'] into SINGLE_USER mode to allow explicit REPLACE operation. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
                END CATCH

                IF @statusDetail IS NOT NULL
                GOTO NextDatabase;
            END;
        END;

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
            IF @PrintOnly = 1 BEGIN
                PRINT @command;
              END;
            ELSE BEGIN
                SET @outcome = NULL;
                EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

                SET @statusDetail = @outcome;
            END;
        END TRY 
        BEGIN CATCH
            SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
        END CATCH

        IF @statusDetail IS NOT NULL BEGIN
            GOTO NextDatabase;
        END;

		-- Update MetaData: 
		EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

		UPDATE @restoredFiles 
		SET 
			[Applied] = GETDATE(), 
			[BackupCreated] = @backupDate, 
			[BackupSize] = @backupSize, 
			[Compressed] = @compressed, 
			[Encrypted] = @encrypted
		WHERE 
			[FileName] = @backupName;
        
		-- Restore any DIFF backups if present:
		EXEC dbo.load_backup_files @DatabaseToRestore = @databaseToRestore, @SourcePath = @sourcePath, @Mode = N'DIFF', @LastAppliedFile = @backupName, @Output = @fileList OUTPUT;
		
		IF NULLIF(@fileList, N'') IS NOT NULL BEGIN
			SET @backupName = @fileList;
			SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName

            SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			INSERT INTO @restoredFiles ([FileName], [Detected])
			SELECT @backupName, GETDATE();

            BEGIN TRY
                IF @PrintOnly = 1 BEGIN
                    PRINT @command;
                  END;
                ELSE BEGIN
                    SET @outcome = NULL;
                    EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

                    SET @statusDetail = @outcome;
                END;
            END TRY
            BEGIN CATCH
                SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            END CATCH

            IF @statusDetail IS NOT NULL BEGIN
                GOTO NextDatabase;
            END;

			-- Update MetaData: 
			EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

			UPDATE @restoredFiles 
			SET 
				[Applied] = GETDATE(), 
				[BackupCreated] = @backupDate, 
				[BackupSize] = @backupSize, 
				[Compressed] = @compressed, 
				[Encrypted] = @encrypted
			WHERE 
				[FileName] = @backupName;
		END;


        -- Restore any LOG backups if specified and if present:
        IF @SkipLogBackups = 0 BEGIN
			
			-- reset values per every 'loop' of main processing body:
			DELETE FROM @logFilesToRestore;

			EXEC dbo.load_backup_files @DatabaseToRestore = @databaseToRestore, @SourcePath = @sourcePath, @Mode = N'LOG', @LastAppliedFile = @backupName, @Output = @fileList OUTPUT;
			INSERT INTO @logFilesToRestore ([log_file])
			SELECT result FROM dbo.[split_string](@fileList, N',');
			
			-- re-update the counter: 
			SET @currentLogFileID = ISNULL((SELECT MIN(id) FROM @logFilesToRestore), @currentLogFileID + 1);

			-- start a loop to process files while they're still available: 
			WHILE EXISTS (SELECT NULL FROM @logFilesToRestore WHERE [id] = @currentLogFileID) BEGIN

				SELECT @backupName = log_file FROM @logFilesToRestore WHERE id = @currentLogFileID;
				SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName;

				INSERT INTO @restoredFiles ([FileName], [Detected])
				SELECT @backupName, GETDATE();

                SET @command = N'RESTORE LOG ' + QUOTENAME(@restoredName, N'[]') + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';
                
                BEGIN TRY 
                    IF @PrintOnly = 1 BEGIN
                        PRINT @command;
                      END;
                    ELSE BEGIN
                        SET @outcome = NULL;
                        EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

                        SET @statusDetail = @outcome;
                    END;
                END TRY
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @backupName + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

                    -- this has to be closed/deallocated - or we'll run into it on the 'next' database/pass.
                    IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN;
                        CLOSE logger;
                        DEALLOCATE logger;
                    END;
                    
                END CATCH

				-- Update MetaData: 
				EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

				UPDATE @restoredFiles 
				SET 
					[Applied] = GETDATE(), 
					[BackupCreated] = @backupDate, 
					[BackupSize] = @backupSize, 
					[Compressed] = @compressed, 
					[Encrypted] = @encrypted
				WHERE 
					[FileName] = @backupName;

                IF @statusDetail IS NOT NULL BEGIN
                    GOTO NextDatabase;
                END;

				-- Check for any new files if we're now 'out' of files to process: 
				IF @currentLogFileID = (SELECT MAX(id) FROM @logFilesToRestore) BEGIN

					-- if there are any new log files, we'll get those... and they'll be added to the list of files to process (along with newer (higher) ids)... 
					EXEC dbo.load_backup_files @DatabaseToRestore = @databaseToRestore, @SourcePath = @sourcePath, @Mode = N'LOG', @LastAppliedFile = @backupName, @Output = @fileList OUTPUT;
					INSERT INTO @logFilesToRestore ([log_file])
					SELECT result FROM dbo.[split_string](@fileList, N',');
				END;

				-- increment: 
				SET @currentLogFileID = @currentLogFileID + 1;
			END;
        END;

        -- Recover the database:
		IF @ExecuteRecovery = 1 BEGIN
			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName, N'[]') + N' WITH RECOVERY;';

			BEGIN TRY
				IF @PrintOnly = 1 BEGIN
					PRINT @command;
				  END;
				ELSE BEGIN
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END;
			END TRY	
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH

			IF @statusDetail IS NOT NULL BEGIN
				GOTO NextDatabase;
			END;
		END;

        -- If we've made it here, then we need to update logging/meta-data:
        IF @PrintOnly = 0 BEGIN
            UPDATE dbo.restore_log 
            SET 
                restore_succeeded = 1, 
                restore_end = GETDATE(), 
                error_details = NULL
            WHERE 
                restore_test_id = @restoreLogId;
        END;

        -- Run consistency checks if specified:
        IF @CheckConsistency = 1 BEGIN

            SET @command = N'DBCC CHECKDB([' + @restoredName + N']) WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;'; -- outputting data for review/analysis. 

            IF @PrintOnly = 0 BEGIN 
                UPDATE dbo.restore_log
                SET 
                    consistency_start = GETDATE(),
                    consistency_succeeded = 0, 
                    error_details = '#UNKNOWN ERROR CHECKING CONSISTENCY#'
                WHERE
                    restore_test_id = @restoreLogId;
            END;

            BEGIN TRY 
                IF @PrintOnly = 1 
                    PRINT @command;
                ELSE BEGIN 
                    DELETE FROM ##DBCC_OUTPUT;
                    INSERT INTO ##DBCC_OUTPUT (Error, [Level], [State], MessageText, RepairLevel, [Status], [DbId], DbFragId, ObjectId, IndexId, PartitionId, AllocUnitId, RidDbId, RidPruId, [File], [Page], Slot, RefDbId, RefPruId, RefFile, RefPage, RefSlot, Allocation)
                    EXEC sp_executesql @command; 

                    IF EXISTS (SELECT NULL FROM ##DBCC_OUTPUT) BEGIN -- consistency errors: 
                        SET @statusDetail = N'CONSISTENCY ERRORS DETECTED against database ' + QUOTENAME(@restoredName, N'[]') + N'. Details: ' + @crlf;
                        SELECT @statusDetail = @statusDetail + MessageText + @crlf FROM ##DBCC_OUTPUT ORDER BY RowID;

                        UPDATE dbo.restore_log
                        SET 
                            consistency_end = GETDATE(),
                            consistency_succeeded = 0,
                            error_details = @statusDetail
                        WHERE 
                            restore_test_id = @restoreLogId;

                      END;
                    ELSE BEGIN -- there were NO errors:
                        UPDATE dbo.restore_log
                        SET
                            consistency_end = GETDATE(),
                            consistency_succeeded = 1, 
                            error_details = NULL
                        WHERE 
                            restore_test_id = @restoreLogId;

                    END;
                END;

            END TRY	
            BEGIN CATCH
                SELECT @statusDetail = N'Unexpected Exception while running consistency checks. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
                GOTO NextDatabase;
            END CATCH

        END;

        -- Drop the database if specified and if all SAFE drop precautions apply:
        IF @DropDatabasesAfterRestore = 1 BEGIN
            
            -- Make sure we can/will ONLY restore databases that we've restored in this session. 
            SELECT @executeDropAllowed = restore_succeeded FROM dbo.restore_log WHERE restored_as = @restoredName AND execution_id = @executionID;

            IF @PrintOnly = 1 AND @DropDatabasesAfterRestore = 1
                SET @executeDropAllowed = 1; 
            
            IF ISNULL(@executeDropAllowed, 0) = 0 BEGIN 

                UPDATE dbo.restore_log
                SET 
                    [dropped] = 'ERROR', 
                    error_details = error_details + @crlf + N'(NOTE: Database was NOT successfully restored - but WAS slated to be DROPPED as part of processing.)'
                WHERE 
                    restore_test_id = @restoreLogId;

                SET @executeDropAllowed = 1; 
            END;

            IF @executeDropAllowed = 1 BEGIN -- this is a db we restored (or tried to restore) in this 'session' - so we can drop it:
                SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName, N'[]') + N';';

                BEGIN TRY 
                    IF @PrintOnly = 1 
                        PRINT @command;
                    ELSE BEGIN
                        UPDATE dbo.restore_log 
                        SET 
                            [dropped] = N'ATTEMPTED'
                        WHERE 
                            restore_test_id = @restoreLogId;

                        EXEC sys.sp_executesql @command;

                        IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN
                            SET @statusDetail = N'Executed command to DROP database [' + @restoredName + N']. No exceptions encountered, but database still in place POST-DROP.';

                            GOTO NextDatabase;
                          END;
                        ELSE -- happy / expected outcome:
                            UPDATE dbo.restore_log
                            SET 
                                dropped = 'DROPPED'
                            WHERE 
                                restore_test_id = @restoreLogId;
                    END;

                END TRY 
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while attempting to DROP database [' + @restoredName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

                    UPDATE dbo.restore_log
                    SET 
                        dropped = 'ERROR'
                    WHERE 
                        restore_test_id = @restoredName;

                    GOTO NextDatabase;
                END CATCH
            END;

          END;
        ELSE BEGIN
            UPDATE dbo.restore_log 
            SET 
                dropped = 'LEFT ONLINE' -- same as 'NOT DROPPED' but shows explicit intention.
            WHERE
                restore_test_id = @restoreLogId;
        END;

		-- serialize restored file details and push into dbo.restore_log
		
		SELECT @fileListXml = (
			SELECT 
				ROW_NUMBER() OVER (ORDER BY ID) [@id],
				[FileName] [name], 
				BackupCreated [created],
				Detected [detected], 
				Applied [applied], 
				BackupSize [size], 
				Compressed [compressed], 
				[Encrypted] [encrypted]
			FROM 
				@restoredFiles 
			ORDER BY 
				ID
			FOR XML PATH('file'), ROOT('files')
		);

		IF @PrintOnly = 1
			PRINT @fileListXml; 
		ELSE BEGIN
			UPDATE dbo.[restore_log] 
			SET 
				restored_files = @fileListXml
			WHERE 
				[restore_test_id] = @restoreLogId;
		END;

        PRINT N'-- Operations for database [' + @restoredName + N'] completed successfully.' + @crlf + @crlf;

        -- If we made this this far, there have been no errors... and we can drop through into processing the next database... 
NextDatabase:

        -- Record any status details as needed:
        IF @statusDetail IS NOT NULL BEGIN

            IF @PrintOnly = 1 BEGIN
                PRINT N'ERROR: ' + @statusDetail;
              END;
            ELSE BEGIN
                UPDATE dbo.restore_log
                SET 
                    restore_end = GETDATE(),
                    error_details = @statusDetail
                WHERE 
                    restore_test_id = @restoreLogId;
            END;

            PRINT N'-- Operations for database [' + @restoredName + N'] failed.' + @crlf + @crlf;
        END;

        -- Check-up on total number of 'failed drops':
		IF @DropDatabasesAfterRestore = 1 BEGIN 
			SELECT @failedDropCount = COUNT(*) FROM admindb.dbo.[restore_log] WHERE [execution_id] = @executionID AND [dropped] IN ('ATTEMPTED', 'ERROR');

			IF @failedDropCount >= @MaxNumberOfFailedDrops BEGIN 
				-- we're done - no more processing (don't want to risk running out of space with too many restore operations.
				SET @earlyTermination = N'Max number of databases that could NOT be dropped after restore/testing was reached. Early terminatation forced to reduce risk of causing storage problems.';
				GOTO FINALIZE;
			END;
		END;

        FETCH NEXT FROM restorer INTO @databaseToRestore;
    END

    -----------------------------------------------------------------------------
FINALIZE:

    -- close/deallocate any cursors left open:
    IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN
        CLOSE restorer;
        DEALLOCATE restorer;
    END;

    IF (SELECT CURSOR_STATUS('local','mover')) > -1 BEGIN
        CLOSE mover;
        DEALLOCATE mover;
    END;

    IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN
        CLOSE logger;
        DEALLOCATE logger;
    END;

    -- Assemble details on errors - if there were any (i.e., logged errors OR any reason for early termination... 
    IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN

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
        IF NULLIF(@earlyTermination, '') IS NOT NULL BEGIN
            SET @emailErrorMessage = @emailErrorMessage + @tab + N'- ' + @earlyTermination;
        END;
    END;
    
    IF @emailErrorMessage IS NOT NULL BEGIN

        IF @PrintOnly = 1
            PRINT N'ERROR: ' + @emailErrorMessage;
        ELSE BEGIN
            SET @emailSubject = @emailSubjectPrefix + N' - ERROR';

            EXEC msdb..sp_notify_operator
                @profile_name = @MailProfileName,
                @name = @OperatorName,
                @subject = @emailSubject, 
                @body = @emailErrorMessage;
        END;
    END;

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
	


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_files','P') IS NOT NULL
	DROP PROC dbo.load_backup_files;
GO

CREATE PROC dbo.load_backup_files 
	@DatabaseToRestore			sysname,
	@SourcePath					nvarchar(400), 
	@Mode						sysname,				-- FULL | DIFF | LOG  
	@LastAppliedFile			nvarchar(400)			= NULL,	
	@Output						nvarchar(MAX)			OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @results table ([id] int IDENTITY(1,1), [output] varchar(500));

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	--PRINT @command
	INSERT INTO @results ([output])
	EXEC xp_cmdshell @command;

	-- High-level Cleanup: 
	DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';

	-- Mode Processing: 
	IF UPPER(@Mode) = N'FULL' BEGIN
		-- most recent full only: 
		DELETE FROM @results WHERE id <> (SELECT MAX(id) FROM @results WHERE [output] LIKE 'FULL%');
	END;

	IF UPPER(@Mode) = N'DIFF' BEGIN 
		-- start by deleting since the most recent file processed: 
		DELETE FROM @results WHERE id <= (SELECT id FROM @results WHERE [output] = @LastAppliedFile);

		-- now dump everything but the most recent DIFF - if there is one: 
		IF EXISTS(SELECT NULL FROM @results WHERE [output] LIKE 'DIFF%')
			DELETE FROM @results WHERE id <> (SELECT MAX(id) FROM @results WHERE [output] LIKE 'DIFF%'); 
		ELSE
			DELETE FROM @results;
	END;

	IF UPPER(@Mode) = N'LOG' BEGIN

		-- grab everything (i.e., ONLY t-log backups) since the most recently 
		DELETE FROM @results WHERE id <= (SELECT MAX(id) FROM @results WHERE [output] = @LastAppliedFile);
		DELETE FROM @results WHERE [output] NOT LIKE 'LOG%';
	END;


	SET @Output = N'';
	SELECT @Output = @Output + [output] + N',' FROM @results ORDER BY [id];

	IF ISNULL(@Output,'') <> ''
		SET @Output = LEFT(@Output, LEN(@Output) - 1);

	RETURN 0;
GO



-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.load_header_details','P') IS NOT NULL
	DROP PROC dbo.load_header_details;
GO

CREATE PROC dbo.load_header_details 
	@BackupPath			nvarchar(800), 
	@BackupDate			datetime		OUTPUT, 
	@BackupSize			bigint			OUTPUT, 
	@Compressed			bit				OUTPUT, 
	@Encrypted			bit				OUTPUT

AS
	SET NOCOUNT ON; 

	-- TODO: 
	--		make sure file/path exists... 

	CREATE TABLE #header (
		BackupName nvarchar(128) NULL, -- backups generated by S4 ALWAYS have this value populated - but it's NOT required by SQL Server (obviously).
		BackupDescription nvarchar(255) NULL, 
		BackupType smallint NOT NULL, 
		ExpirationDate datetime NULL, 
		Compressed bit NOT NULL, 
		Position smallint NOT NULL, 
		DeviceType tinyint NOT NULL, --
		Username nvarchar(128) NOT NULL, 
		ServerName nvarchar(128) NOT NULL, 
		DatabaseName nvarchar(128) NOT NULL,
		DatabaseVersion int NOT NULL, 
		DatabaseCreationDate datetime NOT NULL, 
		BackupSize numeric(20,0) NOT NULL, 
		FirstLSN numeric(25,0) NOT NULL, 
		LastLSN numeric(25,0) NOT NULL, 
		CheckpointLSN numeric(25,0) NOT NULL, 
		DatabaseBackupLSN numeric(25,0) NOT NULL, 
		BackupStartDate datetime NOT NULL, 
		BackupFinishDate datetime NOT NULL, 
		SortOrder smallint NULL, 
		[CodePage] smallint NOT NULL, 
		UnicodeLocaleID int NOT NULL, 
		UnicodeComparisonStyle int NOT NULL,
		CompatibilityLevel tinyint NOT NULL, 
		SoftwareVendorID int NOT NULL, 
		SoftwareVersionMajor int NOT NULL, 
		SoftwareVersionMinor int NOT NULL, 
		SoftwareVersionBuild int NOT NULL, 
		MachineName nvarchar(128) NOT NULL, 
		Flags int NOT NULL, 
		BindingID uniqueidentifier NOT NULL, 
		RecoveryForkID uniqueidentifier, 
		Collation nvarchar(128) NOT NULL, 
		FamilyGUID uniqueidentifier NOT NULL, 
		HasBulkLoggedData bit NOT NULL, 
		IsSnapshot bit NOT NULL, 
		IsReadOnly bit NOT NULL, 
		IsSingleUser bit NOT NULL, 
		HasBackupChecksums bit NOT NULL, 
		IsDamaged bit NOT NULL, 
		BeginsLogChain bit NOT NULL, 
		HasIncompleteMetaData bit NOT NULL, 
		IsForceOffline bit NOT NULL, 
		IsCopyOnly bit NOT NULL, 
		FirstRecoveryForkID uniqueidentifier NOT NULL, 
		ForkPointLSN numeric(25,0) NULL, 
		RecoveryModel nvarchar(60) NOT NULL, 
		DifferntialBaseLSN numeric(25,0) NULL, 
		DifferentialBaseGUID uniqueidentifier NULL, 
		BackupTypeDescription nvarchar(60) NOT NULL, 
		BackupSetGUIUD uniqueidentifier NULL, 
		CompressedBackupSize bigint NOT NULL
	);

	IF (SELECT admindb.dbo.get_engine_version()) >= 11.0 BEGIN
		-- columna added to 2012 and above:
		ALTER TABLE [#header]
			ADD Containment tinyint NOT NULL;
	END; 

	IF (SELECT admindb.dbo.get_engine_version()) >= 12.0 BEGIN
		-- columns added to 2014 and above:
		ALTER TABLE [#header]
			ADD 
				KeyAlgorithm nvarchar(32) NULL, 
				EncryptorThumbprint varbinary(20) NULL, 
				EncryptorType nvarchar(32) NULL
	END;

	DECLARE @command nvarchar(MAX); 

	SET @command = N'RESTORE HEADERONLY FROM DISK = N''{0}'';';
	SET @command = REPLACE(@command, N'{0}', @BackupPath);
	
	INSERT INTO [#header] 
	EXEC sp_executesql @command;

	-- Return Output Details: 
	SELECT 
		@BackupDate = [BackupFinishDate], 
		@BackupSize = CAST((ISNULL([CompressedBackupSize], [BackupSize])) AS bigint), 
		@Compressed = [Compressed], 
		@Encrypted = CASE WHEN EncryptorThumbprint IS NOT NULL THEN 1 ELSE 0 END
	FROM 
		[#header];

	RETURN 0;
GO







---------------------------------------------------------------------------
--- Diagnostics
---------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.list_processes','P') IS NOT NULL
	DROP PROC dbo.list_processes;
GO

CREATE PROC dbo.list_processes 
	@TopNRows								int			=	-1,		-- TOP is only used if @TopNRows > 0. 
	@OrderBy								sysname		= N'CPU',	-- CPU | DURATION | READS | WRITES | MEMORY
	@IncludePlanHandle						bit			= 1,		
	@IncludeIsolationLevel					bit			= 0,
	-- vNEXT				--@ShowBatchStatement					bit			= 0,		-- show outer statement if possible...
	-- vNEXT				---@ShowBatchPlan						bit			= 0,		-- grab a parent plan if there is one... 	
	-- vNEXT				--@DetailedBlockingInfo					bit			= 0,		-- xml 'blocking chain' and stuff... 
	@DetailedMemoryStats					bit			= 0,		-- show grant info... 
	-- vNEXT				--@DetailedTempDbStats					bit			= 0,		-- pull info about tempdb usage by session and such... 
	@ExcludeMirroringWaits					bit			= 1,		-- optional 'ignore' wait types/families.
	@ExcludeNegativeDurations				bit			= 1,		-- exclude service broker and some other system-level operations/etc. 
	-- vNEXT				--@ExcludeSOmeOtherSetOfWaitTypes		bit			= 1			-- ditto... 
	@ExcludeFTSDaemonProcesses				bit			= 1,
	@ExcludeSystemProcesses					bit			= 1,			-- spids < 50... 
	@ExcludeSelf							bit			= 1
AS 
	SET NOCOUNT ON; 

	CREATE TABLE #ranked (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[session_id] smallint NOT NULL,
		[cpu] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[duration] int NOT NULL,
		[memory] decimal(20,2) NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	SELECT {TOP}
		r.[session_id], 
		r.[cpu_time] [cpu], 
		r.[reads], 
		r.[writes], 
		r.[total_elapsed_time] [duration],
		ISNULL(CAST((g.granted_memory_kb / 1024.0) as decimal(20,2)),0) AS [memory]
	FROM 
		sys.[dm_exec_requests] r
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
	WHERE
		r.last_wait_type NOT IN(''BROKER_TO_FLUSH'',''HADR_FILESTREAM_IOMGR_IOCOMPLETION'', ''BROKER_EVENTHANDLER'', ''BROKER_TRANSMITTER'',''BROKER_TASK_STOP'', ''MISCELLANEOUS'' {ExcludeMirroringWaits} {ExcludeFTSWAITs} )
		{ExcludeSystemProcesses}
		{ExcludeSelf}
		{ExcludeNegative}
		{ExcludeFTS}
	{OrderBy};';

-- TODO: verify that aliased column ORDER BY operations work in versions of SQL Server prior to 2016... 
	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + LOWER(@OrderBy) + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + LOWER(@OrderBy) + N' DESC');
	END; 
		
	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND r.session_id > 50 ');
		END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses', N'');
	END;

	IF @ExcludeMirroringWaits = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N',''DBMIRRORING_CMD'',''DBMIRROR_EVENTS_QUEUE'', ''DBMIRROR_WORKER_QUEUE''');
		END;
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND r.session_id <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

	IF @ExcludeNegativeDurations = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'AND r.total_elapsed_time > 0 ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'');
	END; 

	IF @ExcludeFTSDaemonProcesses = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWAITs}', N', ''FT_COMPROWSET_RWLOCK'', ''FT_IFTS_RWLOCK'', ''FT_IFTS_SCHEDULER_IDLE_WAIT'', ''FT_IFTSHC_MUTEX'', ''FT_IFTSISM_MUTEX'', ''FT_MASTER_MERGE'', ''FULLTEXT GATHERER'' ');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'AND r.command NOT LIKE ''FT%'' ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWAITs}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'');
	END; 


--PRINT @topSQL;

	INSERT INTO [#ranked] ([session_id], [cpu], [reads], [writes], [duration], [memory])
	EXEC sys.[sp_executesql] @topSQL; 

	CREATE TABLE #detail (
		[row_number] int NOT NULL,
		[session_id] smallint NOT NULL,
		[blocked_by] smallint NULL,
		[isolation_level] varchar(14) NULL,
		[status] nvarchar(30) NOT NULL,
		[last_wait_type] nvarchar(60) NOT NULL,
		[command] nvarchar(32) NOT NULL,
		[granted_mb] decimal(20,2) NOT NULL,
		[requested_mb] decimal(20,2) NOT NULL,
		[ideal_mb] decimal(20,2) NOT NULL,
		[db_name] sysname NULL,
		[text] nvarchar(max) NULL,
		[cpu_time] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[elapsed_time] int NOT NULL,
		[wait_time] int NOT NULL,
		[program_name] sysname NULL,
		[host_name] sysname NULL,
		[percent_complete] real NOT NULL,
		[open_tran] int NOT NULL,
		[sql_handle] varbinary(64) NULL,
		[plan_handle] varbinary(64) NULL
	);

	INSERT INTO [#detail] ([row_number], [session_id], [blocked_by], [isolation_level], [status], [last_wait_type], [command], [granted_mb], [requested_mb], [ideal_mb], [db_name],
		 [cpu_time], [reads], [writes], [elapsed_time], [wait_time], [program_name], [host_name], [percent_complete], [open_tran], [sql_handle], [plan_handle])
	SELECT
		x.[row_number],
		r.session_id, 
		r.blocking_session_id [blocked_by],
		CASE s.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
		END isolation_level,
		r.[status],
		r.last_wait_type,
		r.command, 
		x.[memory] [granted_mb],
		ISNULL(CAST((g.requested_memory_kb / 1024.0) as decimal(20,2)),0) AS requested_mb,
		ISNULL(CAST((g.ideal_memory_kb  / 1024.0) as decimal(20,2)),0) AS ideal_mb,
		DB_NAME(r.database_id) [db_name],	
		--t.[text],
		x.[cpu] [cpu_time],
		x.reads,
		x.writes,
		x.[duration] [elapsed_time],
		r.wait_time,
		s.[program_name],
		s.[host_name],
		r.percent_complete,
		r.open_transaction_count [open_tran],
		r.[sql_handle],
		r.plan_handle
	FROM 
		sys.dm_exec_requests r
		INNER JOIN [#ranked] x ON r.[session_id] = x.[session_id]
		INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
	ORDER BY 
		x.[row_number]; 


	DECLARE @projectionSQL nvarchar(MAX) = N'
	SELECT 
		d.[session_id],
		d.[blocked_by],  -- vNext: this is either blocked_by or blocking_chain - which will be xml.. 
		{isolation_level}
		d.[command], 
		d.[status],
		d.[last_wait_type],
		{memory}
		d.[db_name],
		t.[text],  -- statement_text?
		--{batch_text} ??? 
		d.[cpu_time],
		d.[reads],
		d.[writes], 
		CASE WHEN d.[elapsed_time] < 0 
			THEN N''-'' + RIGHT(''000'' + CAST(([elapsed_time] / (1000 * 360) / 60) AS sysname), 3) + N'':'' + RIGHT(''00'' + CAST(([elapsed_time] / (1000 * 60) % 60) AS sysname), 2) + N'':'' + RIGHT(''00'' + CAST((([elapsed_time] / 1000) % 60) AS sysname), 2) + N''.'' + RIGHT(''000'' + CAST(([elapsed_time]) AS sysname), 3)
			ELSE RIGHT(''000'' + CAST(([elapsed_time] / (1000 * 360) / 60) AS sysname), 3) + N'':'' + RIGHT(''00'' + CAST(([elapsed_time] / (1000 * 60) % 60) AS sysname), 2) + N'':'' + RIGHT(''00'' + CAST((([elapsed_time] / 1000) % 60) AS sysname), 2) + N''.'' + RIGHT(''000'' + CAST(([elapsed_time]) AS sysname), 3)
		END [elapsed_time],
		RIGHT(''000'' + CAST(([wait_time] / (1000 * 360) / 60) AS sysname), 3) + N'':'' + RIGHT(''00'' + CAST(([wait_time] / (1000 * 60) % 60) AS sysname), 2) + N'':'' + RIGHT(''00'' + CAST((([wait_time] / 1000) % 60) AS sysname), 2) + N''.'' + RIGHT(''000'' + CAST(([wait_time]) AS sysname), 3) [wait_time],
		d.[program_name],
		d.[host_name],
		d.[percent_complete], 
		d.[open_tran], 
		{plan_handle}
		p.query_plan [batch_plan]
		--,{statement_plan} -- if i can get this working... 
	FROM 
		[#detail] d
		OUTER APPLY sys.dm_exec_sql_text(d.sql_handle) t
		OUTER APPLY sys.dm_exec_query_plan(d.plan_handle) p
	ORDER BY
		[row_number];'


	IF @IncludeIsolationLevel = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'd.[isolation_level],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'');
	END;

	IF @DetailedMemoryStats = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'd.[granted_mb], d.[requested_mb], d.[ideal_mb],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'd.[granted_mb],');
	END; 


	IF @IncludePlanHandle = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'd.[plan_handle],');
	  END; 
	ELSE BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'');
	END; 

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

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
		N'Compatibility should be ' + CAST(@serverVersion AS sysname) + N' but is currently set to ' + CAST(d.compatibility_level AS sysname) + N'.' + @crlf + @tab + @tab + N'To correct, execute: ALTER DATABASE' + QUOTENAME(d.[name], '[]') + N' SET COMPATIBILITY_LEVEL = ' + CAST(@serverVersion AS sysname) + N';' [issue]
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


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.process_alerts','P') IS NOT NULL
	DROP PROC dbo.process_alerts;
GO

CREATE PROC dbo.process_alerts 
	@ErrorNumber				int, 
	@Severity					int, 
	@Message					nvarchar(2048),
	@OperatorName				sysname					= N'Alerts',
	@MailProfileName			sysname					= N'General'
AS 
	SET NOCOUNT ON; 

	DECLARE @ignoredErrorNumbers TABLE ( 
		[error_number] int NOT NULL
	);

	INSERT INTO @ignoredErrorNumbers ([error_number])
	VALUES
	(7886) -- A read operation on a large object failed while sending data to the client. Example of a common-ish error you MAY wish to ignore, etc.  
	,(17806) -- SSPI handshake failure
	,(18056) -- The client was unable to reuse a session with SPID ###, which had been reset for connection pooling. The failure ID is 8. 
	--,(otherIdHere)
	--,(etc)
	;

	IF EXISTS (SELECT NULL FROM @ignoredErrorNumbers WHERE [error_number] = @ErrorNumber)
		RETURN 0; -- this is an ignored alert - we're done.

	DECLARE @body nvarchar(MAX); 
	
	SET @body = N'DATE/TIME: {0}

DESCRIPTION: {1}

ERROR NUMBER: {2}' ;

	SET @body = REPLACE(@body, '{0}', CONVERT(nvarchar(20), GETDATE(), 100));
	SET @body = REPLACE(@body, '{1}', @Message);
	SET @body = REPLACE(@body, '{2}', @ErrorNumber);

	DECLARE @subject nvarchar(256) = N'SQL Server Alert System: ''Severity {0}'' occurred on {1}';

	SET @subject = REPLACE(@subject, '{0}', @Severity);
	SET @subject = REPLACE(@subject, '{1}', @@SERVERNAME); 
	
	EXEC msdb.dbo.sp_notify_operator
		@profile_name = @MailProfileName, 
		@name = @OperatorName,
		@subject = @subject, 
		@body = @body;

	RETURN 0;

GO




/*

----------------------------------------------------------------------------------------------------------------------
-- Job Creation (Step 3):
--	NOTE: script below ASSUMES convention of 'Alerts' as operator to notify in case of problems... 

USE [msdb];
GO

BEGIN TRANSACTION;
	DECLARE @ReturnCode int;
	SELECT @ReturnCode = 0;
	IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'Monitoring' AND category_class=1) BEGIN
		EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'Monitoring';
		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;
	END;

	DECLARE @jobId BINARY(16);
	EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Process Alerts', 
			@enabled=1, 
			@notify_level_eventlog=0, 
			@notify_level_email=2, 
			@notify_level_netsend=0, 
			@notify_level_page=0, 
			@delete_level=0, 
			@description=N'NOTE: This job responds to alerts (and filters out specific error messages/ids) and therefore does NOT have a schedule.', 
			@category_name=N'Monitoring', 
			@owner_login_name=N'sa', 
			@notify_email_operator_name=N'Alerts', 
			@job_id = @jobId OUTPUT;
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

	EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
			@job_id=@jobId, 
			@step_name=N'Filter and Send Alerts', 
			@step_id=1, 
			@cmdexec_success_code=0, 
			@on_success_action=1, 
			@on_success_step_id=0, 
			@on_fail_action=2, 
			@on_fail_step_id=0, 
			@retry_attempts=0, 
			@retry_interval=0, 
			@os_run_priority=0, @subsystem=N'TSQL', 
			@command=N'DECLARE @ErrorNumber int, @Severity int;
SET @ErrorNumber = CONVERT(int, N''$(ESCAPE_SQUOTE(A-ERR))'');
SET @Severity = CONVERT(int, N''$(ESCAPE_NONE(A-SEV))'');

EXEC admindb.dbo.process_alerts 
	@ErrorNumber = @ErrorNumber, 
	@Severity = @Severity,
	@Message = N''$(ESCAPE_SQUOTE(A-MSG))'';', 
			@database_name=N'admindb', 
			@flags=0;
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1;
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	COMMIT TRANSACTION;
	GOTO EndSave;
	QuitWithRollback:
		IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
	EndSave:

GO


*/


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
	@PrintOnly				bit						= 0					-- output only to console - don't email alerts (for debugging/manual execution, etc.)
AS 
	SET NOCOUNT ON;

	---------------------------------------------
	-- Validation Checks: 
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
 
		IF @DatabaseMailProfile <> @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	----------------------------------------------
	-- Determine which server to run checks on. 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		server_name sysname, 
		sync_type sysname,
		[database_name] sysname
	)

	INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name])
	SELECT @localServerName [server_name], N'MIRRORED' sync_type, d.[name] [database_name] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;

	INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name])
	SELECT @localServerName [server_name], N'AG' [sync_type], d.[name] [database_name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_cluster_states hars ON d.replica_id = hars.replica_id;

	INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name])
	EXEC master.sys.sp_executesql N'SELECT @remoteServerName [server_name], N''MIRRORED'' sync_type, d.[name] [database_name] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;', N'@remoteServerName sysname', @remoteServerName = @remoteServerName;

	INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name])
	EXEC master.sys.sp_executesql N'SELECT @remoteServerName [server_name], N''AG'' [sync_type], d.[name] [database_name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_cluster_states hars ON d.replica_id = hars.replica_id;', N'@remoteServerName sysname', @remoteServerName = @remoteServerName;

	DECLARE @firstSyncedDB sysname; 
	SELECT @firstSyncedDB = (SELECT TOP (1) [database_name] FROM @synchronizingDatabases ORDER BY [database_name], server_name);

	-- if there are NO mirrored/AG'd dbs, then this job will run on BOTH servers at the same time (which seems weird, but if someone sets this up without mirrored dbs, no sense NOT letting this run). 
	IF @firstSyncedDB IS NOT NULL BEGIN 
		-- Check to see if we're on the primary or not. 
		IF (SELECT admindb.dbo.is_primary_database(@firstSyncedDB)) = 0 BEGIN 
			PRINT 'Server is Not Primary. Execution Terminating (but will continue on Primary).'
			RETURN 0; -- tests/checks are now done on the secondary
		END
	END 

	----------------------------------------------
	-- establish which jobs to ignore (if any):
	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredJobs, N',');

	----------------------------------------------
	-- create a container for output/differences. 
	CREATE TABLE #Divergence (
		row_id int IDENTITY(1,1) NOT NULL,
		[name] nvarchar(100) NOT NULL, 
		[description] nvarchar(300) NOT NULL
	);


	---------------------------------------------------------------------------------------------
	-- Process server-level jobs (jobs that aren't mapped to a Mirrored/AG'd database). 
	--		here we're just looking for differences in enabled states and/or differences between the job definitions/details from one server to the next. 
	CREATE TABLE #LocalJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
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
		[name] sysname, 
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
	INSERT INTO #LocalJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.[name], 'local') operator_name,
		ISNULL(sc.[name], 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
	WHERE
		sj.name NOT IN (SELECT [name] FROM #IgnoredJobs); 

	INSERT INTO #RemoteJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	EXEC master.sys.sp_executesql N'SELECT 
	sj.job_id, 
	sj.[name], 
	sj.[enabled], 
	sj.[description], 
	sj.start_step_id,
	sj.owner_sid, 
	sj.notify_level_email, 
	ISNULL(so.name, ''local'') operator_name,
	ISNULL(sc.name, ''local'') [category_name],
	ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
FROM 
	PARTNER.msdb.dbo.sysjobs sj
	LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
	LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id';

	DELETE FROM #RemoteJobs WHERE [name] IN (SELECT [name] FROM #IgnoredJobs);

	----------------------------------------------
	-- Process high-level details about each job
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		[name],
		N'Server-Level job exists on ' + @localServerName + N' only.'
	FROM 
		#LocalJobs 
	WHERE
		[name] NOT IN (SELECT [name] FROM #RemoteJobs)
		AND [name] NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName);

	INSERT INTO #Divergence ([name], [description])
	SELECT 
		[name], 
		N'Server-Level job exists on ' + @remoteServerName + N' only.'
	FROM 
		#RemoteJobs
	WHERE
		[name] NOT IN (SELECT [name] FROM #LocalJobs)
		AND [name] NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName);

	INSERT INTO #Divergence ([name], [description])
	SELECT 
		lj.[name], 
		N'Differences between Server-Level job details between servers (owner, enabled, category name, job-steps count, start-step, notification, etc)'
	FROM 
		#LocalJobs lj
		INNER JOIN #RemoteJobs rj ON rj.[name] = lj.[name]
	WHERE
		lj.category_name NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName) 
		AND rj.category_name NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName)
		AND 
		(
			lj.[enabled] <> rj.[enabled]
			OR lj.[description] <> rj.[description]
			OR lj.start_step_id <> rj.start_step_id
			OR lj.owner_sid <> rj.owner_sid
			OR lj.notify_level_email <> rj.notify_level_email
			OR lj.operator_name <> rj.operator_name
			OR lj.job_step_count <> rj.job_step_count
			OR lj.category_name <> rj.category_name
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
		INNER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name];

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
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM msdb.dbo.sysjobsteps
		WHERE job_id = @localJobID;

		INSERT INTO #RemoteJobSteps (step_id, [checksum])
		EXEC master.sys.sp_executesql N'SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM PARTNER.msdb.dbo.sysjobsteps
		WHERE job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

		IF @localCount <> @remoteCount
			INSERT INTO #Divergence ([name], [description]) 
			VALUES (
				@jobName, 
				N'Job Step Counts between servers are NOT the same.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				@jobName, 
				N'Job Step details between servers are NOT the same.'
			FROM 
				#LocalJobSteps ljs 
				INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
			WHERE	
				ljs.[checksum] <> rjs.[checksum];
		END;

		-- Now Check Schedules:
		DELETE FROM #LocalJobSchedules;
		DELETE FROM #RemoteJobSchedules;

		INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
		SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			msdb.dbo.sysjobschedules sjs
			INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @localJobID;

		INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
		EXEC master.sys.sp_executesql N'SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

		IF @localCount <> @remoteCount
			INSERT INTO #Divergence ([name], [description]) 
			VALUES (
				@jobName, 
				N'Job Schedule Counts between servers are different.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence ([name], [description])
			SELECT
				@jobName, 
				N'Job Schedule Details between servers are different.'
			FROM 
				#LocalJobSchedules ljs
				INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
			WHERE 
				ljs.[checksum] <> rjs.[checksum];

		END;

		FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;
	END;

	CLOSE server_level_checker;
	DEALLOCATE server_level_checker;

	---------------------------------------------------------------------------------------------
	-- Process Batch-Jobs. 

	-- Check on job details for batch-jobs:
	TRUNCATE TABLE #LocalJobs;
	TRUNCATE TABLE #RemoteJobs;

	DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
	SELECT DISTINCT 
		[database_name]
	FROM 
		@synchronizingDatabases
	ORDER BY 
		[database_name];

	DECLARE @currentMirroredDB sysname; 

	OPEN looper;
	FETCH NEXT FROM looper INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		TRUNCATE TABLE #LocalJobs;
		TRUNCATE TABLE #RemoteJobs;
		
		INSERT INTO #LocalJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		SELECT 
			sj.job_id, 
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.[name], 'local') operator_name,
			ISNULL(sc.[name], 'local') [category_name],
			ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			msdb.dbo.sysjobs sj
			LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.[name]) = UPPER(@currentMirroredDB)
			AND sj.[name] NOT IN (SELECT [name] FROM #IgnoredJobs);

		INSERT INTO #RemoteJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		EXEC master.sys.sp_executesql N'SELECT 
			sj.job_id, 
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.[name], ''local'') operator_name,
			ISNULL(sc.[name], ''local'') [category_name],
			ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
			LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.[name]) = UPPER(@currentMirroredDB);', N'@currentMirroredDB sysname', @currentMirroredDB = @currentMirroredDB;

		DELETE FROM #RemoteJobs WHERE [name] IN (SELECT [name] FROM #IgnoredJobs);

		------------------------------------------
		-- Now start comparing differences: 

		-- local  only:
	-- TODO: create separate checks/messages for jobs existing only on one server or the other AND the whole 'OR is disabled' on one server or the other). 
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[local].[name], 
			N'Job for database ' + @currentMirroredDB + N' exists on ' + @localServerName + N' only (or is set to a job category of ''Disabled'' on one server but not the other).'
		FROM 
			#LocalJobs [local]
			LEFT OUTER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name]
		WHERE 
			[remote].[name] IS NULL;

		-- remote only:
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[remote].[name], 
			N'Job for database ' + @currentMirroredDB + N' exists on ' + @remoteServerName + N' only (or is set to a job category of ''Disabled'' on one server but not the other).'
		FROM 
			#RemoteJobs [remote]
			LEFT OUTER JOIN #LocalJobs [local] ON [remote].[name] = [local].[name]
		WHERE 
			[local].[name] IS NULL;

		-- differences:
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[local].[name], 
			N'Job for database ' + @currentMirroredDB + N' is different between servers (owner, start-step, notification, etc).'
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [remote].[name] = [local].[name]
		WHERE
			[local].start_step_id <> [remote].start_step_id
			OR [local].owner_sid <> [remote].owner_sid
			OR [local].notify_level_email <> [remote].notify_level_email
			OR [local].operator_name <> [remote].operator_name
			OR [local].job_step_count <> [remote].job_step_count
			OR [local].category_name <> [remote].category_name;
		

		-- Process Batch-Job enabled states. There are three possible scenarios or situations to be aware of: 
		--		a) job.categoryname = 'a synchronizing db name] AND job.enabled = 0 on the PRIMARY (which it shouldn't be, because unless category is set to disabled, this job will be re-enabled post-failover). 
		--		b) job.categoryname = 'DISABLED' on the SECONDARY and job.enabled = 1... which is bad. Shouldn't be that way. 
		--		c) job.categoryname = 'a synchronizing db name' and job.enabled != to what should be set for the current role (i.e., enabled on PRIMARY and disabled on SECONDARY). 
		--			only local variant of scenario c = scenario a, and the remote/partner variant of c = scenario b. 

		IF (SELECT admindb.dbo.is_primary_database(@currentMirroredDB)) = 1 BEGIN 
			-- report on any mirroring jobs that are disabled on the primary:
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is disabled on ' + @localServerName + N' (PRIMARY). Following a failover, this job will be re-enabled on the secondary. To prevent job from being re-enabled following failovers, set job category to ''Disabled''.'
			FROM 
				#LocalJobs
			WHERE
				[name] NOT IN (SELECT [name] FROM #IgnoredJobs) 
				AND [enabled] = 0 
				AND [category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName);
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Job is enabled on ' + @remoteServerName + N' (SECONDARY), but the job''s category name is set to ''Disabled'' (meaning that this job WILL be disabled following a failover).'
			FROM 
				#RemoteJobs
			WHERE
				[name] NOT IN (SELECT [name] FROM #IgnoredJobs)
				AND [enabled] = 1 
				AND category_name IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName);
		  END 
		ELSE BEGIN -- otherwise, simply 'flip' the logic:
			-- report on any mirroring jobs that are disabled on the primary:
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is disabled on ' + @remoteServerName + N' (PRIMARY). Following a failover, this job will be re-enabled on the secondary. To prevent job from being re-enabled following failovers, set job category to ''Disabled''.'
			FROM 
				#RemoteJobs
			WHERE
				[name] NOT IN (SELECT [name] FROM #IgnoredJobs) 
				AND [enabled] = 0 
				AND [category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName); 		
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Job is enabled on ' + @localServerName + N' (SECONDARY), but the job''s category name is set to ''Disabled'' (meaning that this job WILL be disabled following a failover).'
			FROM 
				#LocalJobs
			WHERE
				[name] NOT IN (SELECT [name] FROM #IgnoredJobs)
				AND [enabled] = 1 
				AND category_name IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName); 

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
			[local].[name] 
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name];

		OPEN checker;
		FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;

		WHILE @@FETCH_STATUS = 0 BEGIN 
	
			-- check jobsteps first:
			DELETE FROM #LocalJobSteps;
			DELETE FROM #RemoteJobSteps;

			INSERT INTO #LocalJobSteps (step_id, [checksum])
			SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [detail]
			FROM msdb.dbo.sysjobsteps
			WHERE job_id = @localJobID;

			INSERT INTO #RemoteJobSteps (step_id, [checksum])
			EXEC master.sys.sp_executesql N'SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [detail]
			FROM PARTNER.msdb.dbo.sysjobsteps
			WHERE job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

			IF @localCount <> @remoteCount
				INSERT INTO #Divergence ([name], [description]) 
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
					ljs.[checksum] <> rjs.[checksum];
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
			EXEC master.sys.sp_executesql N'SELECT 
				ss.[name],
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				PARTNER.msdb.dbo.sysjobschedules sjs
				INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

			IF @localCount <> @remoteCount
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
					ljs.[checksum] <> rjs.[checksum];

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
			row_id;

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
 
		IF @DatabaseMailProfile <> @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END 

	IF OBJECT_ID('admindb.dbo.server_trace_flags', 'U') IS NULL BEGIN 
		RAISERROR('Table dbo.server_trace_flags is not present in master. Synchronization check can not be processed.', 16, 1);
		RETURN -6;
	END

	-- Start by updating dbo.server_trace_flags on both servers:
	TRUNCATE TABLE dbo.server_trace_flags; -- truncating and replacing nets < 1 page of data and typically around 0ms of CPU. 

	INSERT INTO dbo.server_trace_flags(trace_flag, [status], [global], [session])
	EXECUTE ('DBCC TRACESTATUS() WITH NO_INFOMSGS');

	-- Figure out which server this should be running on (and then, from this point forward, only run on the Primary);
	DECLARE @firstMirroredDB sysname; 
	SET @firstMirroredDB = (SELECT TOP 1 d.[name] FROM sys.databases d INNER JOIN sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL ORDER BY d.[name]); 

	-- if there are NO mirrored dbs, then this job will run on BOTH servers at the same time (which seems weird, but if someone sets this up without mirrored dbs, no sense NOT letting this run). 
	IF @firstMirroredDB IS NOT NULL BEGIN 
		-- Check to see if we're on the primary or not. 
		IF (SELECT dbo.is_primary_database(@firstMirroredDB)) = 0 BEGIN 
			PRINT 'Server is Not Primary.'
			RETURN 0; -- tests/checks are now done on the secondary
		END
	END 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	-- Just to make sure that this job (running on both servers) has had enough time to update server_trace_flags, go ahead and give everything 200ms of 'lag'.
	--	 Lame, yes. But helps avoid false-positives and also means we don't have to set up RPC perms against linked servers. 
	WAITFOR DELAY '00:00:00.200';

	CREATE TABLE #Divergence (
		rowid int IDENTITY(1,1) NOT NULL, 
		name nvarchar(100) NOT NULL, 
		[description] nvarchar(500) NOT NULL
	);

	---------------------------------------
	-- Server Level Configuration/Settings: 
	DECLARE @remoteConfig table ( 
		configuration_id int NOT NULL, 
		value_in_use sql_variant NULL
	);	

	INSERT INTO @remoteConfig (configuration_id, value_in_use)
	EXEC master.sys.sp_executesql N'SELECT configuration_id, value_in_use FROM PARTNER.master.sys.configurations;';

	INSERT INTO #Divergence ([name], [description])
	SELECT 
		N'ConfigOption: ' + [source].[name], 
		N'Server Configuration Option is different between ' + @localServerName + N' and ' + @remoteServerName + N'. (Run ''EXEC sp_configure;'' on both servers and/or run ''SELECT * FROM master.sys.configurations;'' on both servers.)'
	FROM 
		master.sys.configurations [source]
		INNER JOIN @remoteConfig [target] ON [source].[configuration_id] = [target].[configuration_id]
	WHERE 
		[source].value_in_use <> [target].value_in_use;

	---------------------------------------
	-- Trace Flags: 
	DECLARE @remoteFlags TABLE (
		trace_flag int NOT NULL, 
		[status] bit NOT NULL, 
		[global] bit NOT NULL, 
		[session] bit NOT NULL
	);
	
	INSERT INTO @remoteFlags ([trace_flag], [status], [global], [session])
	EXEC sp_executesql N'SELECT [trace_flag], [status], [global], [session] FROM PARTNER.admindb.dbo.server_trace_flags;';
	
	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(trace_flag AS nvarchar(5)), 
		N'TRACE FLAG is enabled on ' + @localServerName + N' only.'
	FROM 
		admindb.dbo.server_trace_flags 
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM @remoteFlags);

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(trace_flag AS nvarchar(5)), 
		N'TRACE FLAG is enabled on ' + @remoteServerName + N' only.'
	FROM 
		@remoteFlags
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM admindb.dbo.server_trace_flags);

	-- different values: 
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(x.trace_flag AS nvarchar(5)), 
		N'TRACE FLAG Enabled Value is different between both servers.'
	FROM 
		admindb.dbo.server_trace_flags [x]
		INNER JOIN @remoteFlags [y] ON x.trace_flag = y.trace_flag 
	WHERE 
		x.[status] <> y.[status]
		OR x.[global] <> y.[global]
		OR x.[session] <> y.[session];


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
	DECLARE @remoteMessages table (
		language_id smallint NOT NULL, 
		message_id int NOT NULL, 
		is_event_logged bit NOT NULL
	);

	INSERT INTO @remoteMessages (language_id, message_id, is_event_logged)
	EXEC sp_executesql N'SELECT language_id, message_id, is_event_logged FROM PARTNER.master.sys.messages WHERE message_id IN (1440, 1480);';

	INSERT INTO #Divergence (name, [description])
	SELECT
		N'ErrorMessage: ' + CAST(message_id AS nvarchar(20)), 
		N'The is_event_logged property for this message_id on ' + @remoteServerName + N' is NOT set to 1. Please run Mirroring Failover setup scripts.'
	FROM 
		@remoteMessages
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	---------------------------------------
	-- admindb versions: 
	DECLARE @localAdminDBVersion sysname;
	DECLARE @remoteAdminDBVersion sysname;

	SELECT @localAdminDBVersion = version_number FROM admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM admindb..version_history);
	EXEC sys.sp_executesql N'SELECT @remoteVersion = version_number FROM PARTNER.admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM PARTNER.admindb.dbo.version_history);', N'@remoteVersion sysname OUTPUT', @remoteVersion = @remoteAdminDBVersion OUTPUT;

	IF @localAdminDBVersion <> @remoteAdminDBVersion BEGIN
		INSERT INTO #Divergence (name, [description])
		SELECT 
			N'admindb versions are NOT synchronized',
			N'Admin db on ' + @localServerName + ' is ' + @localAdminDBVersion + ' while the version on ' + @remoteServerName + ' is ' + @remoteAdminDBVersion + '.';
	END;

	---------------------------------------
	-- Mirrored database ownership:
	IF @IgnoreMirroredDatabaseOwnership = 0 BEGIN 
		DECLARE @localOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL, 
			owner_sid varbinary(85) NULL
		);

		-- mirrored (local) dbs: 
		INSERT INTO @localOwners ([name], sync_type, owner_sid)
		SELECT d.[name], N'Mirrored' [sync_type], d.owner_sid FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL; 

		-- AG'd (local) dbs: 
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @localOwners ([name], sync_type, owner_sid)
			EXEC master.sys.sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM sys.databases WHERE replica_id IS NOT NULL;';  -- has to be dynamic sql - otherwise replica_id will throw an error during sproc creation... 
		END

		DECLARE @remoteOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL,
			owner_sid varbinary(85) NULL
		);

		-- Mirrored (remote) dbs:
		INSERT INTO @remoteOwners ([name], sync_type, owner_sid) 
		EXEC sp_executesql N'SELECT d.[name], ''Mirrored'' [sync_type], d.owner_sid FROM PARTNER.master.sys.databases d INNER JOIN PARTNER.master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL;';

		-- AG'd (local) dbs: 
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @localOwners ([name], sync_type, owner_sid)
			EXEC sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM sys.databases WHERE replica_id IS NOT NULL;';			
		END

		INSERT INTO #Divergence (name, [description])
		SELECT 
			N'Database: ' + [local].[name], 
			[local].sync_type + N' database owners are different between servers.'
		FROM 
			@localOwners [local]
			INNER JOIN @remoteOwners [remote] ON [local].[name] = [remote].[name]
		WHERE
			[local].owner_sid <> [remote].owner_sid;
	END

	---------------------------------------
	-- Linked Servers:
	DECLARE @IgnoredLinkedServerNames TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @IgnoredLinkedServerNames([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredLinkedServers, N',');

	DECLARE @remoteLinkedServers table ( 
		[server_id] int NOT NULL,
		[name] sysname NOT NULL,
		[location] nvarchar(4000) NULL,
		[provider_string] nvarchar(4000) NULL,
		[catalog] sysname NULL,
		[product] sysname NOT NULL,
		[data_source] nvarchar(4000) NULL,
		[provider] sysname NOT NULL,
		[is_remote_login_enabled] bit NOT NULL,
		[is_rpc_out_enabled] bit NOT NULL,
		[is_collation_compatible] bit NOT NULL,
		[uses_remote_collation] bit NOT NULL,
		[collation_name] sysname NULL,
		[connect_timeout] int NULL,
		[query_timeout] int NULL,
		[is_remote_proc_transaction_promotion_enabled] bit NULL,
		[is_system] bit NOT NULL,
		[lazy_schema_validation] bit NOT NULL
	);

	INSERT INTO @remoteLinkedServers ([server_id], [name], [location], provider_string, [catalog], product, [data_source], [provider], is_remote_login_enabled, is_rpc_out_enabled, is_collation_compatible, uses_remote_collation,
		 collation_name, connect_timeout, query_timeout, is_remote_proc_transaction_promotion_enabled, is_system, lazy_schema_validation)
	EXEC master.sys.sp_executesql N'SELECT [server_id], [name], [location], provider_string, [catalog], product, [data_source], [provider], is_remote_login_enabled, is_rpc_out_enabled, is_collation_compatible, uses_remote_collation, collation_name, connect_timeout, query_timeout, is_remote_proc_transaction_promotion_enabled, is_system, lazy_schema_validation FROM PARTNER.master.sys.servers;';

	-- local only:
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		N'Linked Server: ' + [local].[name],
		N'Linked Server exists on ' + @localServerName + N' only.'
	FROM 
		sys.servers [local]
		LEFT OUTER JOIN @remoteLinkedServers [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].server_id > 0 
		AND [local].[name] <> 'PARTNER'
		AND [local].[name] NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [remote].[name] IS NULL;

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [remote].[name],
		N'Linked Server exists on ' + @remoteServerName + N' only.'
	FROM 
		@remoteLinkedServers [remote]
		LEFT OUTER JOIN master.sys.servers [local] ON [local].[name] = [remote].[name]
	WHERE 
		[remote].server_id > 0 
		AND [remote].[name] <> 'PARTNER'
		AND [remote].[name] NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [local].[name] IS NULL;

	
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [local].[name], 
		N'Linkded server definitions are different between servers.'
	FROM 
		sys.servers [local]
		INNER JOIN @remoteLinkedServers [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].[name] NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND ( 
			[local].product <> [remote].product
			OR [local].[provider] <> [remote].[provider]
			-- Sadly, PARTNER is a bit of a pain/problem - it has to exist on both servers - but with slightly different versions:
			OR (
				CASE 
					WHEN [local].[name] = 'PARTNER' AND [local].[data_source] <> [remote].[data_source] THEN 0 -- non-true (i.e., non-'different' or non-problematic)
					ELSE 1  -- there's a problem (because data sources are different, but the name is NOT 'Partner'
				END 
				 = 1  
			)
			OR [local].[location] <> [remote].[location]
			OR [local].provider_string <> [remote].provider_string
			OR [local].[catalog] <> [remote].[catalog]
			OR [local].is_remote_login_enabled <> [remote].is_remote_login_enabled
			OR [local].is_rpc_out_enabled <> [remote].is_rpc_out_enabled
			OR [local].is_collation_compatible <> [remote].is_collation_compatible
			OR [local].uses_remote_collation <> [remote].uses_remote_collation
			OR [local].collation_name <> [remote].collation_name
			OR [local].connect_timeout <> [remote].connect_timeout
			OR [local].query_timeout <> [remote].query_timeout
			OR [local].is_remote_proc_transaction_promotion_enabled <> [remote].is_remote_proc_transaction_promotion_enabled
			OR [local].is_system <> [remote].is_system
			OR [local].lazy_schema_validation <> [remote].lazy_schema_validation
		);
		

	---------------------------------------
	-- Logins:
	DECLARE @ignoredLoginName TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredLoginName([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredLogins, N',');

	DECLARE @remotePrincipals table ( 
		[principal_id] int NOT NULL,
		[name] sysname NOT NULL,
		[sid] varbinary(85) NULL,
		[type] char(1) NOT NULL,
		[is_disabled] bit NULL
	);

	INSERT INTO @remotePrincipals (principal_id, [name], [sid], [type], is_disabled)
	EXEC master.sys.sp_executesql N'SELECT principal_id, [name], [sid], [type], is_disabled FROM PARTNER.master.sys.server_principals;';

	DECLARE @remoteLogins table (
		[name] sysname NOT NULL,
		[password_hash] varbinary(256) NULL
	);
	INSERT INTO @remoteLogins ([name], password_hash)
	EXEC master.sys.sp_executesql N'SELECT [name], password_hash FROM PARTNER.master.sys.sql_logins;';

	-- local only:
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		N'Login: ' + [local].[name], 
		N'Login exists on ' + @localServerName + N' only.'
	FROM 
		sys.server_principals [local]
	WHERE 
		principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S'
		AND [local].[name] NOT IN (SELECT [name] FROM @remotePrincipals WHERE principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S')
		AND [local].[name] NOT IN (SELECT [name] FROM @ignoredLoginName);

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Login: ' + [remote].[name], 
		N'Login exists on ' + @remoteServerName + N' only.'
	FROM 
		@remotePrincipals [remote]
	WHERE 
		principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S'
		AND [remote].[name] NOT IN (SELECT [name] FROM sys.server_principals WHERE principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S')
		AND [remote].[name] NOT IN (SELECT [name] FROM @ignoredLoginName);

	-- differences
	INSERT INTO #Divergence ([name], [description])
	SELECT
		N'Login: ' + [local].[name], 
		N'Login is different between servers. (Check SID, disabled, or password_hash (for SQL Logins).)'
	FROM 
		(SELECT p.[name], p.[sid], p.is_disabled, l.password_hash FROM sys.server_principals p LEFT OUTER JOIN sys.sql_logins l ON p.[name] = l.[name]) [local]
		INNER JOIN (SELECT p.[name], p.[sid], p.is_disabled, l.password_hash FROM @remotePrincipals p LEFT OUTER JOIN @remoteLogins l ON p.[name] = l.[name]) [remote] ON [local].[name] = [remote].[name]
	WHERE
		[local].[name] NOT IN (SELECT [name] FROM @ignoredLoginName)
		AND [local].[name] NOT LIKE '##MS%' -- skip all of the MS cert signers/etc. 
		AND (
			[local].[sid] <> [remote].[sid]
			--OR [local].password_hash <> [remote].password_hash  -- sadly, these are ALWAYS going to be different because of master keys/encryption details. So we can't use it for comparison purposes.
			OR [local].is_disabled <> [remote].is_disabled
		);

	---------------------------------------
	-- Endpoints? 
	--		[add if needed/desired.]

	---------------------------------------
	-- Server Level Triggers?
	--		[add if needed/desired.]

	---------------------------------------
	-- Other potential things to check/review:
	--		Audit Specs
	--		XEs 
	--		credentials/proxies
	--		service accounts (i.e., SQL Server and SQL Server Agent)
	--		perform volume maint-tasks, lock pages in memory... 
	--		etc...

	---------------------------------------
	-- Operators:
	-- local only

	DECLARE @remoteOperators table (
		[name] sysname NOT NULL,
		[enabled] tinyint NOT NULL,
		[email_address] nvarchar(100) NULL
	);

	INSERT INTO @remoteOperators ([name], [enabled], email_address)
	EXEC master.sys.sp_executesql N'SELECT [name], [enabled], email_address FROM PARTNER.msdb.dbo.sysoperators;';

	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [local].[name], 
		N'Operator exists on ' + @localServerName + N' only.'
	FROM 
		msdb.dbo.sysoperators [local]
		LEFT OUTER JOIN @remoteOperators [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[remote].[name] IS NULL;

	-- remote only
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [remote].[name], 
		N'Operator exists on ' + @remoteServerName + N' only.'
	FROM 
		@remoteOperators [remote]
		LEFT OUTER JOIN msdb.dbo.sysoperators [local] ON [remote].[name] = [local].[name]
	WHERE 
		[local].[name] IS NULL;

	-- differences (just checking email address in this particular config):
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [local].[name], 
		N'Operator definition is different between servers. (Check email address(es) and enabled.)'
	FROM 
		msdb.dbo.sysoperators [local]
		INNER JOIN @remoteOperators [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].[enabled] <> [remote].[enabled]
		OR [local].[email_address] <> [remote].[email_address];

	---------------------------------------
	-- Alerts:
	DECLARE @ignoredAlertName TABLE (
		entry_id int IDENTITY(1,1) NOT NULL,
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredAlertName([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredAlerts, N',');

	DECLARE @remoteAlerts table (
		[name] sysname NOT NULL,
		[message_id] int NOT NULL,
		[severity] int NOT NULL,
		[enabled] tinyint NOT NULL,
		[delay_between_responses] int NOT NULL,
		[notification_message] nvarchar(512) NULL,
		[include_event_description] tinyint NOT NULL,
		[database_name] nvarchar(512) NULL,
		[event_description_keyword] nvarchar(100) NULL,
		[job_id] uniqueidentifier NOT NULL,
		[has_notification] int NOT NULL,
		[performance_condition] nvarchar(512) NULL,
		[category_id] int NOT NULL
	);

	INSERT INTO @remoteAlerts ([name], message_id, severity, [enabled], delay_between_responses, notification_message, include_event_description, [database_name], event_description_keyword,
			job_id, has_notification, performance_condition, category_id)
	EXEC master.sys.sp_executesql N'SELECT [name], message_id, severity, [enabled], delay_between_responses, notification_message, include_event_description, [database_name], event_description_keyword, job_id, has_notification, performance_condition, category_id FROM PARTNER.msdb.dbo.sysalerts;';

	-- local only
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [local].[name], 
		N'Alert exists on ' + @localServerName + N' only.'
	FROM 
		msdb.dbo.sysalerts [local]
		LEFT OUTER JOIN @remoteAlerts [remote] ON [local].[name] = [remote].[name]
	WHERE
		[remote].[name] IS NULL
		AND [local].[name] NOT IN (SELECT [name] FROM @ignoredAlertName);

	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [remote].[name], 
		N'Alert exists on ' + @remoteServerName + N' only.'
	FROM 
		@remoteAlerts [remote]
		LEFT OUTER JOIN msdb.dbo.sysalerts [local] ON [remote].[name] = [local].[name]
	WHERE
		[local].[name] IS NULL
		AND [remote].[name] NOT IN (SELECT [name] FROM @ignoredAlertName);

	-- differences:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [local].[name], 
		N'Alert definition is different between servers.'
	FROM	
		msdb.dbo.sysalerts [local]
		INNER JOIN @remoteAlerts [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].[name] NOT IN (SELECT [name] FROM @ignoredAlertName)
		AND (
		[local].message_id <> [remote].message_id
		OR [local].severity <> [remote].severity
		OR [local].[enabled] <> [remote].[enabled]
		OR [local].delay_between_responses <> [remote].delay_between_responses
		OR [local].notification_message <> [remote].notification_message
		OR [local].include_event_description <> [remote].include_event_description
		OR [local].[database_name] <> [remote].[database_name]
		OR [local].event_description_keyword <> [remote].event_description_keyword
		-- JobID is problematic. If we have a job set to respond, it'll undoubtedly have a diff ID from one server to the other. So... we just need to make sure ID <> 'empty' on one server, while not on the other, etc. 
		OR (
			CASE 
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 0 -- no problem
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id <> N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem - one alert is 'empty' and the other is not. 
				WHEN [local].job_id <> N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem (inverse of above). 
				WHEN ([local].job_id <> N'00000000-0000-0000-0000-000000000000' AND [remote].job_id <> N'00000000-0000-0000-0000-000000000000') AND ([local].job_id <> [remote].job_id) THEN 0 -- they're both 'non-empty' so... we assume it's good
			END 
			= 1
		)
		OR [local].has_notification <> [remote].has_notification
		OR [local].performance_condition <> [remote].performance_condition
		OR [local].category_id <> [remote].category_id
		);

	---------------------------------------
	-- Objects in Master Database:  
	DECLARE @localMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	DECLARE @ignoredMasterObjects TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredMasterObjects([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredMasterDbObjects, N',');

	INSERT INTO @localMasterObjects ([object_name])
	SELECT [name] FROM master.sys.objects WHERE [type] IN ('U','V','P','FN','IF','TF') AND is_ms_shipped = 0 AND [name] NOT IN (SELECT [name] FROM @ignoredMasterObjects);
	
	DECLARE @remoteMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	INSERT INTO @remoteMasterObjects ([object_name])
	EXEC master.sys.sp_executesql N'SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;';
	DELETE FROM @remoteMasterObjects WHERE [object_name] IN (SELECT [name] FROM @ignoredMasterObjects);

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
		[location] sysname NOT NULL, 
		[object_name] sysname NOT NULL, 
		[type] char(2) NOT NULL,
		[hash] varbinary(MAX) NULL
	);

	INSERT INTO #Definitions ([location], [object_name], [type], [hash])
	SELECT 
		'local', 
		[name], 
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
		master.sys.objects o
		LEFT OUTER JOIN master.sys.sql_modules sm ON o.[object_id] = sm.[object_id]
		INNER JOIN @localMasterObjects x ON o.[name] = x.[object_name];

	DECLARE localtabler CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'local';

	DECLARE @currentObjectName sysname;
	DECLARE @checksum bigint = 0;

	OPEN localtabler;
	FETCH NEXT FROM localtabler INTO @currentObjectName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0;

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		SELECT @checksum = @checksum + [local].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.[name], c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM master.sys.columns c INNER JOIN master.sys.objects o ON o.object_id = c.object_id WHERE o.[name] = @currentObjectName
		) [local];

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'local';

		FETCH NEXT FROM localtabler INTO @currentObjectName;
	END 

	CLOSE localtabler;
	DEALLOCATE localtabler;

	INSERT INTO #Definitions ([location], [object_name], [type], [hash])
	EXEC master.sys.sp_executesql N'SELECT 
		''remote'', 
		o.[name], 
		[type], 
		CASE 
			WHEN [type] IN (''V'',''P'',''FN'',''IF'',''TF'') THEN 
				CASE
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
					ELSE HASHBYTES(''SHA1'', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		PARTNER.master.sys.objects o
		LEFT OUTER JOIN PARTNER.master.sys.sql_modules sm ON o.object_id = sm.object_id
		INNER JOIN (SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0) x ON o.[name] = x.[name];';

	DECLARE remotetabler CURSOR LOCAL FAST_FORWARD FOR
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'remote';

	OPEN remotetabler;
	FETCH NEXT FROM remotetabler INTO @currentObjectName; 

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0; -- otherwise, it'll get passed into sp_executesql with the PREVIOUS value.... 

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		EXEC master.sys.sp_executesql N'SELECT @checksum = ISNULL(@checksum,0) + [remote].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.[name], c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM PARTNER.master.sys.columns c INNER JOIN PARTNER.master.sys.objects o ON o.object_id = c.object_id WHERE o.[name] = @currentObjectName
		) [remote];', N'@checksum bigint OUTPUT, @currentObjectName sysname', @checksum = @checksum OUTPUT, @currentObjectName = @currentObjectName;

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
		[local].[hash] <> [remote].[hash];
	
	------------------------------------------------------------------------------
	-- Report on any discrepancies: 
	IF(SELECT COUNT(*) FROM #Divergence) > 0 BEGIN 

		DECLARE @subject nvarchar(300) = N'SQL Server Synchronization Check Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = N'The following synchronization issues were detected: ' + @crlf;

		SELECT 
			@message = @message + @tab + [name] + N' -> ' + [description] + @crlf
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


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.compare_jobs','P') IS NOT NULL
	DROP PROC dbo.compare_jobs;
GO

CREATE PROC dbo.compare_jobs 
	@TargetJobName			sysname = NULL, 
	@IgnoredJobs			nvarchar(MAX) = NULL,			-- technically, should throw an error if this is specified AND @TargetJobName is ALSO specified, but... instead, will just ignore '@ignored' if a specific job is specified. 
	@IgnoreEnabledState		bit = 0
AS
	SET NOCOUNT ON; 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	IF NULLIF(@TargetJobName,N'') IS NOT NULL BEGIN -- the request is for DETAILS about a specific job. 


		-- Make sure Job exists on Local and Remote: 
		CREATE TABLE #LocalJob (
			job_id uniqueidentifier, 
			[name] sysname
		);

		CREATE TABLE #RemoteJob (
			job_id uniqueidentifier, 
			[name] sysname
		);

		INSERT INTO #LocalJob (job_id, [name])
		SELECT 
			sj.job_id, 
			sj.[name]
		FROM 
			msdb.dbo.sysjobs sj
		WHERE
			sj.[name] = @TargetJobName;

		INSERT INTO #RemoteJob (job_id, [name])
		EXEC master.sys.sp_executesql N'SELECT 
			sj.job_id, 
			sj.[name]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
		WHERE
			sj.[name] = @TargetJobName;', N'@TargetJobName sysname', @TargetJobName = @TargetJobName;

		IF NOT EXISTS (SELECT NULL FROM #LocalJob lj INNER JOIN #RemoteJob rj ON rj.[name] = lj.name) BEGIN
			RAISERROR('Job specified by @TargetJobName does NOT exist on BOTH servers.', 16, 1);
			RETURN -2;
		END


		DECLARE @localJobId uniqueidentifier;
		DECLARE @remoteJobId uniqueidentifier;

		SELECT @localJobId = job_id FROM #LocalJob WHERE [name] = @TargetJobName;
		SELECT @remoteJobId = job_id FROM #RemoteJob WHERE [name] = @TargetJobName;

		DECLARE @remoteJob table (
			[server] sysname NULL,
			[name] sysname NOT NULL,
			[enabled] tinyint NOT NULL,
			[description] nvarchar(512) NULL,
			[start_step_id] int NOT NULL,
			[owner_sid] varbinary(85) NOT NULL,
			[notify_level_email] int NOT NULL,
			[operator_name] sysname NOT NULL,
			[category_name] sysname NOT NULL,
			[job_step_count] int NOT NULL
		);

		INSERT INTO @remoteJob ([server], [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		EXECUTE master.sys.sp_executesql N'SELECT 
			@remoteServerName [server],
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.name, ''local'') operator_name,
			ISNULL(sc.name, ''local'') [category_name],
			ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
			LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE 
			sj.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;


		-- Output top-level job details:
		WITH jobs AS ( 
			SELECT 
				@localServerName [server],
				sj.[name], 
				sj.[enabled], 
				sj.[description], 
				sj.start_step_id,
				sj.owner_sid, 
				sj.notify_level_email, 
				ISNULL(so.[name], 'local') operator_name,
				ISNULL(sc.[name], 'local') [category_name],
				ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
			FROM 
				msdb.dbo.sysjobs sj
				LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
				LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
			WHERE 
				sj.job_id = @localJobId

			UNION 

			SELECT 
				[server],
                [name],
                [enabled],
                [description],
                start_step_id,
                owner_sid,
                notify_level_email,
                operator_name,
                category_name,
                job_step_count
			FROM 
				@remoteJob
		)

		SELECT 
			'JOB' [type], 
			[server],
			[name],
			[enabled],
			[description],
			start_step_id,
			owner_sid,
			notify_level_email,
			operator_name,
			category_name,
			job_step_count
		FROM 
			jobs 
		ORDER BY 
			[name], [server];


		DECLARE @remoteJobSteps table (
			[step_id] int NOT NULL,
			[server] sysname NULL,
			[step_name] sysname NOT NULL,
			[subsystem] nvarchar(40) NOT NULL,
			[command] nvarchar(max) NULL,
			[on_success_action] tinyint NOT NULL,
			[on_fail_action] tinyint NOT NULL,
			[database_name] sysname NULL
		);

		INSERT INTO @remoteJobSteps ([step_id], [server], [step_name], [subsystem], [command], [on_success_action], [on_fail_action], [database_name])
		EXEC master.sys.sp_executesql N'SELECT 
			step_id, 
			@remoteServerName [server],
			step_name, 
			subsystem, 
			command, 
			on_success_action, 
			on_fail_action, 
			[database_name]
		FROM 
			PARTNER.msdb.dbo.sysjobsteps r
		WHERE 
			r.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;

		-- Job Steps: 
		WITH steps AS ( 
			SELECT 
				step_id, 
				@localServerName [server],
				step_name, 
				subsystem, 
				command, 
				on_success_action, 
				on_fail_action, 
				[database_name]
			FROM 
				msdb.dbo.sysjobsteps l
			WHERE 
				l.job_id = @localJobId

			UNION 

			SELECT 
				[step_id], 
				[server], 
				[step_name], 
				[subsystem], 
				[command], 
				[on_success_action], 
				[on_fail_action], 
				[database_name]
			FROM 
				@remoteJobSteps
		)

		SELECT 
			'JOB-STEP' [type],
			step_id, 
			[server],
			step_name, 
			subsystem, 
			command, 
			on_success_action, 
			on_fail_action, 
			[database_name]			
		FROM 
			steps
		ORDER BY 
			step_id, [server];


		DECLARE @remoteJobSchedules table (
			[server] sysname NULL,
			[name] sysname NOT NULL,
			[enabled] int NOT NULL,
			[freq_type] int NOT NULL,
			[freq_interval] int NOT NULL,
			[freq_subday_type] int NOT NULL,
			[freq_subday_interval] int NOT NULL,
			[freq_relative_interval] int NOT NULL,
			[freq_recurrence_factor] int NOT NULL,
			[active_start_date] int NOT NULL,
			[active_end_date] int NOT NULL,
			[active_start_time] int NOT NULL,
			[active_end_time] int NOT NULL
		);

		INSERT INTO @remoteJobSchedules ([server], [name], [enabled], [freq_type], [freq_interval], [freq_subday_type], [freq_subday_interval], [freq_relative_interval], [freq_recurrence_factor], [active_start_date], [active_end_date], [active_start_time], [active_end_time])
		EXEC master.sys.sp_executesql N'SELECT 
			@remoteServerName [server],
			ss.name,
			ss.[enabled], 
			ss.freq_type, 
			ss.freq_interval, 
			ss.freq_subday_type, 
			ss.freq_subday_interval, 
			ss.freq_relative_interval, 
			ss.freq_recurrence_factor, 
			ss.active_start_date, 
			ss.active_end_date,
			ss.active_start_time,
			ss.active_end_time
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE 
			sjs.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;	

		WITH schedules AS (

			SELECT 
				@localServerName [server],
				ss.[name],
				ss.[enabled], 
				ss.freq_type, 
				ss.freq_interval, 
				ss.freq_subday_type, 
				ss.freq_subday_interval, 
				ss.freq_relative_interval, 
				ss.freq_recurrence_factor, 
				ss.active_start_date, 
				ss.active_end_date, 
				ss.active_start_time,
				ss.active_end_time
			FROM 
				msdb.dbo.sysjobschedules sjs
				INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE 
				sjs.job_id = @localJobId

			UNION

			SELECT 
				[server],
                [name],
                [enabled],
                [freq_type],
                [freq_interval],
                [freq_subday_type],
                [freq_subday_interval],
                [freq_relative_interval],
                [freq_recurrence_factor],
                [active_start_date],
                [active_end_date],
                [active_start_time],
                [active_end_time]
			FROM 
				@remoteJobSchedules
		)

		SELECT 
			'SCHEDULE' [type],
			[name],
			[server],
			[enabled], 
			freq_type, 
			freq_interval, 
			freq_subday_type, 
			freq_subday_interval, 
			freq_relative_interval, 
			freq_recurrence_factor, 
			active_start_date, 
			active_end_date, 
			active_start_time,
			active_end_time
		FROM 
			schedules
		ORDER BY 
			[name], [server];

		-- bail, we're done. 
		RETURN 0;

	END;

	  -- If we're still here, we're looking at high-level details for all jobs (except those listed in @IgnoredJobs). 

	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM admindb.dbo.split_string(@IgnoredJobs, N',');

	CREATE TABLE #LocalJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
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
		[name] sysname, 
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
	EXEC master.sys.sp_executesql N'SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.name, ''local'') operator_name,
		ISNULL(sc.name, ''local'') [category_name],
		ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		PARTNER.msdb.dbo.sysjobs sj
		LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id;';

	DELETE FROM [#RemoteJobs] WHERE [name] IN (SELECT [name] FROM [#IgnoredJobs]);

	SELECT 
		N'ONLY ON ' + @LocalServerName [difference], * 
	FROM 
		#LocalJobs 
	WHERE
		[name] NOT IN (SELECT name FROM #RemoteJobs)
		AND [name] NOT IN (SELECT name FROM #IgnoredJobs)

	UNION SELECT 
		N'ONLY ON ' + @RemoteServerName [difference], *
	FROM 
		#RemoteJobs
	WHERE 
		[name] NOT IN (SELECT name FROM #LocalJobs)
		AND [name] NOT IN (SELECT name FROM #IgnoredJobs);


	WITH names AS ( 
		SELECT
			lj.[name]
		FROM 
			#LocalJobs lj
			INNER JOIN #RemoteJobs rj ON rj.[name] = lj.[name]
		WHERE
			(@IgnoreEnabledState = 0 AND (lj.[enabled] != rj.[enabled]))
			OR lj.start_step_id != rj.start_step_id
			OR lj.owner_sid != rj.owner_sid
			OR lj.notify_level_email != rj.notify_level_email
			OR lj.operator_name != rj.operator_name
			OR lj.job_step_count != rj.job_step_count
			OR lj.category_name != rj.category_name
	), 
	core AS ( 
		SELECT 
			@LocalServerName [server],
            lj.[name],
            lj.[enabled],
            lj.[description],
            lj.start_step_id,
            lj.owner_sid,
            lj.notify_level_email,
            lj.operator_name,
            lj.category_name,
            lj.job_step_count
		FROM 
			#LocalJobs lj 
		WHERE 
			lj.[name] IN (SELECT [name] FROM names)

		UNION SELECT 
			@RemoteServerName [server],
            rj.[name],
            rj.[enabled],
            rj.[description],
            rj.start_step_id,
            rj.owner_sid,
            rj.notify_level_email,
            rj.operator_name,
            rj.category_name,
            rj.job_step_count
		FROM 
			#RemoteJobs rj 
		WHERE 
			rj.[name] IN (SELECT [name] FROM names)
	)

	SELECT 
		[core].[server],
        [core].[name],
        [core].[enabled],
        [core].[description],
        [core].[start_step_id],
        [core].[owner_sid],
        [core].[notify_level_email],
        [core].[operator_name],
        [core].[category_name],
        [core].[job_step_count] 
	FROM
		core 
	ORDER BY 
		[name], [server];

	RETURN 0;
GO



-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.data_synchronization_checks','P') IS NOT NULL
	DROP PROC dbo.data_synchronization_checks;
GO

CREATE PROC dbo.data_synchronization_checks 
	@IgnoredDatabases						nvarchar(MAX)		= NULL,
	@SyncCheckSpanMinutes					int					= 10,  --MKC: might rename this @ExecutionFrequencyMinutes or... soemthing... 
	@TransactionDelayThresholdMS			int					= 8600,
	@AvgerageSyncDelayThresholdMS			int					= 2800,
	@EmailSubjectPrefix						nvarchar(50)		= N'[Data Synchronization Problems] ',
	@MailProfileName						sysname				= N'General',	
	@OperatorName							sysname				= N'Alerts',	
	@PrintOnly								bit						= 0
AS
	SET NOCOUNT ON;

	---------------------------------------------
	-- Validation Checks: 
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
 
		IF @DatabaseMailProfile <> @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	----------------------------------------------
	-- Determine which server to run checks on. 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		server_name sysname, 
		sync_type sysname,
		[database_name] sysname, 
		[role] sysname
	);

	-- Mirrored DBs:
	INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
	SELECT @localServerName [server_name], N'MIRRORED' sync_type, d.[name] [database_name], m.[mirroring_role_desc] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;

	-- AG'd DBs (2012 + only):
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE CAST(x.ProductMajorVersion AS int) >= '11') BEGIN
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		EXEC master.sys.[sp_executesql] N'SELECT @localServerName [server_name], N''AG'' [sync_type], d.[name] [database_name], hars.role_desc FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id;', N'@localServerName sysname', @localServerName = @localServerName;
	END;

	-- We're only interested in databases _on this server_ that are in a 'primary' state:
	DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'AG' AND [role] = N'SECONDARY';
	DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'MIRRORED' AND [role] = N'MIRROR';

	-- We're also not interested in any dbs we've been explicitly instructed to ignore: 
	DELETE FROM @synchronizingDatabases WHERE [database_name] IN (SELECT [result] FROM admindb.dbo.[split_string](@IgnoredDatabases, N','));

	IF NOT EXISTS (SELECT NULL FROM @synchronizingDatabases) BEGIN 
		PRINT 'Server is not currently the Primary for any (monitored) synchronizing databases. Execution terminating (but will continue on primary).';
		RETURN 0; -- successful execution (on the secondary) completed.
	END;

	----------------------------------------------
	DECLARE @errors TABLE (
		error_id int IDENTITY(1,1) NOT NULL,
		errorMessage nvarchar(MAX) NOT NULL
	);

	-- http://msdn.microsoft.com/en-us/library/ms366320(SQL.105).aspx
	DECLARE @output TABLE ( 
		[database_name] sysname,
		[role] int, 
		mirroring_state int, 
		witness_status int, 
		log_generation_rate int, 
		unsent_log int, 
		send_rate int, 
		unrestored_log int, 
		recovery_rate int,
		transaction_delay int,
		transactions_per_sec int, 
		average_delay int, 
		time_recorded datetime,
		time_behind datetime,
		local_time datetime
	);

	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @transdelay int;
	DECLARE @averagedelay int;

	----------------------------------------------
	-- Process Mirrored Databases: 
	DECLARE m_checker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@synchronizingDatabases
	WHERE 
		[sync_type] = N'MIRRORED'
	ORDER BY 
		[database_name];

	DECLARE @currentMirroredDB sysname;

	OPEN m_checker;
	FETCH NEXT FROM m_checker INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		DELETE FROM @output;
		SET @errorMessage = N'';

		-- Force an explicit update of the mirroring stats - so that we get the MOST recent details:
		EXEC msdb.sys.sp_dbmmonitorupdate @database_name = @currentMirroredDB;

		INSERT INTO @output
		EXEC msdb.sys.sp_dbmmonitorresults 
			@database_name = @currentMirroredDB,
			@mode = 0, -- just give us the last row - to check current status
			@update_table = 0;  -- This SHOULD be set to 1 - but can/will cause issues with 'nested' INSERT EXEC calls (i.e., a bit of a 'bug'). So... the previous call updates... and we just read the recently updated results. 
		
		IF (SELECT COUNT(*) FROM @output) < 1 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Monitoring not working correctly.'
				+ @crlf + @tab + @tab + N'Database Mirroring Monitoring Failure for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';
				
			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END; 

		IF (SELECT TOP(1) mirroring_state FROM @output) <> 4 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Mirroring Disabled'
				+ @crlf + @tab + @tab + N'Synchronization Failure for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END

		-- check on the witness if needed:
		IF EXISTS (SELECT mirroring_witness_state_desc FROM sys.database_mirroring WHERE database_id = DB_ID(@currentMirroredDB) AND NULLIF(mirroring_witness_state_desc, N'UNKNOWN') IS NOT NULL) BEGIN 
			IF (SELECT TOP(1) witness_status FROM @output) <> 1 BEGIN
				SET @errorMessage = N'Mirroring Failure - Witness Down'
					+ @crlf + @tab + @tab + N'Witness Failure. Witness is currently not enabled or monitoring for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';

				INSERT INTO @errors (errorMessage)
				VALUES (@errorMessage);
			END;
		END;

		-- now that we have the info, start working through various checks/validations and raise any alerts if needed: 

		-- make sure that metrics are even working - if we get any NULLs in transaction_delay/average_delay, 
		--		then it's NOT working correctly (i.e. it's somehow not seeing everything it needs to in order
		--		to report - and we need to throw an error):
		SELECT @transdelay = MIN(ISNULL(transaction_delay,-1)) FROM	@output 
		WHERE time_recorded >= DATEADD(n, 0 - @SyncCheckSpanMinutes, GETUTCDATE());

		DELETE FROM @output; 
		INSERT INTO @output
		EXEC msdb.sys.sp_dbmmonitorresults 
			@database_name = @currentMirroredDB,
			@mode = 1,  -- give us rows from the last 2 hours:
			@update_table = 0;

		IF @transdelay < 0 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Synchronization Metrics Unavailable'
				+ @crlf + @tab + @tab + N'Metrics for transaction_delay and average_delay unavailable for monitoring (i.e., SQL Server Mirroring Monitor is ''busted'') for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END;

		-- check for problems with transaction delay:
		SELECT @transdelay = MAX(ISNULL(transaction_delay,0)) FROM @output
		WHERE time_recorded >= DATEADD(n, 0 - @SyncCheckSpanMinutes, GETUTCDATE());
		IF @transdelay > @TransactionDelayThresholdMS BEGIN 
			SET @errorMessage = N'Mirroring Alert - Delays Applying Snapshot to Secondary'
				+ @crlf + @tab + @tab + N'Max Trans Delay of ' + CAST(@transdelay AS nvarchar(30)) + N' in last ' + CAST(@SyncCheckSpanMinutes as nvarchar(20)) + N' minutes is greater than allowed threshold of ' + CAST(@TransactionDelayThresholdMS as nvarchar(30)) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 

		-- check for problems with transaction delays on the primary:
		SELECT @averagedelay = MAX(ISNULL(average_delay,0)) FROM @output
		WHERE time_recorded >= DATEADD(n, 0 - @SyncCheckSpanMinutes, GETUTCDATE());
		IF @averagedelay > @AvgerageSyncDelayThresholdMS BEGIN 

			SET @errorMessage = N'Mirroring Alert - Transactions Delayed on Primary'
				+ @crlf + @tab + @tab + N'Max(Avg) Trans Delay of ' + CAST(@averagedelay AS nvarchar(30)) + N' in last ' + CAST(@SyncCheckSpanMinutes as nvarchar(20)) + N' minutes is greater than allowed threshold of ' + CAST(@AvgerageSyncDelayThresholdMS as nvarchar(30)) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 		

		FETCH NEXT FROM m_checker INTO @currentMirroredDB;
	END;

	CLOSE m_checker; 
	DEALLOCATE m_checker;

	
	----------------------------------------------
	-- Process AG'd Databases: 
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE CAST(x.ProductMajorVersion AS int) <= '10')
		GOTO REPORTING;

	DECLARE @downNodes nvarchar(MAX);
	DECLARE @currentAGName sysname;
	DECLARE @currentAGId uniqueidentifier;
	DECLARE @syncHealth tinyint;

	DECLARE @processedAgs table ( 
		agname sysname NOT NULL
	);

	DECLARE ag_checker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@synchronizingDatabases
	WHERE 
		[sync_type] = N'AG'
	ORDER BY 
		[database_name];

	DECLARE @currentAGdDatabase sysname; 

	OPEN ag_checker;
	FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN 
	
		SET @currentAGName = N'';
		SET @currentAGId = NULL;
		EXEC master.sys.sp_executesql N'SELECT @currentAGName = ag.[name], @currentAGId = ag.group_id FROM sys.availability_groups ag INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id INNER JOIN sys.databases d ON ar.replica_id = d.replica_id WHERE d.[name] = @currentAGdDatabase;', N'@currentAGdDatabase sysname, @currentAGName sysname OUTPUT, @currentAGId uniqueidentifier OUTPUT', @currentAGdDatabase = @currentAGdDatabase, @currentAGName = @currentAGName OUTPUT, @currentAGId = @currentAGId OUTPUT;

		IF NOT EXISTS (SELECT NULL FROM @processedAgs WHERE agname = @currentAGName) BEGIN
		
			-- Make sure there's an active primary:
-- TODO: in this new, streamlined, code... this check (at this point) is pointless. 
--		need to check this well before we get to the CURSOR for processing AGs, AG'd dbs... 
--			also, there might be a quicker/better way to get a 'list' of all dbs in a 'bad' (non-primary'd) state right out of the gate. 
--			AND, either way I slice it, i'll have to tackle this via sp_executesql - to account for lower-level servers. 
			--SELECT @primaryReplica = agstates.primary_replica
			--FROM sys.availability_groups ag 
			--LEFT OUTER JOIN sys.dm_hadr_availability_group_states agstates ON ag.group_id = agstates.group_id
			--WHERE 
			--	ag.[name] = @currentAGdDatabase;
			
			--IF ISNULL(@primaryReplica,'') = '' BEGIN 
			--	SET @errorMessage = N'MAJOR PROBLEM: No Replica is currently defined as the PRIMARY for Availability Group [' + @currentAG + N'].';

			--	INSERT INTO @errors (errorMessage)
			--	VALUES(@errorMessage);
			--END 
			

			-- Check on Status of all members:
			SET @downNodes = N'';
			EXEC master.sys.sp_executesql N'SELECT @downNodes = @downNodes +  member_name + N'','' FROM sys.dm_hadr_cluster_members WHERE member_state <> 1;', N'@downNodes nvarchar(MAX) OUTPUT', @downNodes = @downNodes OUTPUT; 
			IF LEN(@downNodes) > LEN(N'') BEGIN 
				SET @downNodes = LEFT(@downNodes, LEN(@downNodes) - 1); 
			
				SET @errorMessage = N'WARNING: The following WSFC Cluster Member Nodes are currently being reported as offline: ' + @downNodes + N'.';	

				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END

			-- Check on AG Health Status: 
			SET @syncHealth = 0;
			EXEC master.sys.sp_executesql N'SELECT @syncHealth = synchronization_health FROM sys.dm_hadr_availability_replica_states WHERE group_id = @currentAGId;', N'@currentAGId uniqueidentifier, @syncHealth tinyint OUTPUT', @currentAGId = @currentAGId, @syncHealth = @syncHealth OUTPUT;
			IF @syncHealth <> 2 BEGIN
				SELECT @errorMessage = N'WARNING: Current Health Status of Availability Group [' + @currentAGName + N'] Is Showing NON-HEALTHY.'
			
				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END; 

			-- Check on Synchronization Status of each db:
			SET @syncHealth = 0;
			EXEC master.sys.sp_executesql N'SELECT @syncHealth = synchronization_health FROM sys.dm_hadr_availability_replica_states WHERE group_id = @currentAGId;', N'@currentAGId uniqueidentifier, @syncHealth tinyint OUTPUT', @currentAGId = @currentAGId, @syncHealth = @syncHealth OUTPUT;
			IF @syncHealth <> 2 BEGIN
				SELECT @errorMessage = N'WARNING: The Synchronization Status for one or more Members of the Availability Group [' + @currentAGName + N'] Is Showing NON-HEALTHY.'
			
				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END;


			-- mark the current AG as processed (so that we don't bother processing multiple dbs (and getting multiple errors/messages) if/when they're all in the same AG(s)). 
			INSERT INTO @processedAgs ([agname])
			VALUES(@currentAGName);
		END;
		-- otherwise, we've already run checks on the availability group itself. 

		-- TODO: implement synchronization (i.e., lag/timing/threshold/etc.) logic per each synchronized database... (i.e., here).
		-- or... maybe this needs to be done per AG? not sure of what makes the most sense. 
		--		here's a link though: https://www.sqlshack.com/measuring-availability-group-synchronization-lag/
		--			NOTE: in terms of implementing 'monitors' for the above... the queries that Derik provides are all awesome. 
		--				Only... AGs don't work the same way as... mirroring. with mirroring, i can 'query' a set of stats captured over the last x minutes. and see if there have been any problems DURING that window... 
		--				with these queries... if there's not a problem this exact second... then... everything looks healthy. 
		--				so, there's a very real chance i might want to: 
		--					a) wrap up Derik's queries into a sproc that can/will dump metrics into a table within admindb... (and only keep them for a max of, say, 2 months?)
		--							err... actually, the sproc will have @HistoryRetention = '2h' or '2m' or whatever... (obviously not '2b')... 
		--					b) spin up a job that collects those stats (i.e., runs the job) every ... 30 seconds or someting tame but viable? 
		--					c) have this query ... query that info over the last n minutes... similar to what I'm doing to detect mirroring 'lag' problems.

		FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;
	END;


	CLOSE ag_checker;
	DEALLOCATE ag_checker;


REPORTING:
	-- 
	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';

		SET @errorMessage = N'The following errors were detected: ' + @crlf;

		SELECT @errorMessage = @errorMessage + @tab + N'- ' + errorMessage + @crlf
		FROM @errors
		ORDER BY error_id;

		IF @PrintOnly = 1 BEGIN
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @errorMessage;
		  END
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @Subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO



----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 7. Update version_history with details about current version (i.e., if we got this far, the deployment is successful. 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- TODO grab a ##{{S4VersionSummary}} as a value for @description and use that if there are already v4 deployments (or hell... maybe just use that and pre-pend 'initial install' if this is an initial install?)
DECLARE @CurrentVersion varchar(20) = N'4.8.2557.3';
DECLARE @VersionDescription nvarchar(200) = N'Streamlined Deployment System - Single File, auto build details.';
DECLARE @InstallType nvarchar(20) = N'Install. ';

IF EXISTS (SELECT NULL FROM dbo.[version_history] WHERE CAST(LEFT(version_number, 3) AS decimal(2,1)) >= 4)
	SET @InstallType = N'Update. ';

SET @VersionDescription = @InstallType + @VersionDescription;

-- Add current version info:
IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @CurrentVersion) BEGIN
	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@CurrentVersion, 'Initial Installation/Deployment.', GETDATE());
END;
GO

-----------------------------------
SELECT * FROM dbo.version_history;
GO
