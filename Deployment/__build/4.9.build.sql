--##OUTPUT: \\Deployment
--##NOTE: This is a build/file (instructions for compiling a full deployment/upgrade script). Check Install and Upgrades folders for output.

/*

	REFERENCE:
		- License, documentation, and source code at: 
			https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
			username: s4
			password: simple

	NOTES:
		- This script will either install/deploy S4 version ##{{S4version}} or upgrade a PREVIOUSLY deployed version of S4 to ##{{S4version}}.
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
		6. Deploy S4 version ##{{S4version}} code to admindb (overwriting any previous versions). 
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

DECLARE @CurrentVersion varchar(20) = N'##{{S4version}}';

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

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Common Code:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: Common\get_engine_version.sql

-----------------------------------
--##INCLUDE: Common\check_paths.sql

-----------------------------------
--##INCLUDE: Common\execute_uncatchable_command.sql

-----------------------------------
--##INCLUDE: Common\load_database_names.sql

-----------------------------------
--##INCLUDE: Common\split_string.sql

-----------------------------------
--##INCLUDE: Common\load_default_path.sql

-----------------------------------
--##INCLUDE: Common\format_timespan.sql

-----------------------------------
--##INCLUDE: Common\get_time_vector.sql


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Backups:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Backups\Utilities\remove_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Backups\backup_databases.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\print_logins.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\script_server_logins.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\print_configuration.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\script_server_configuration.sql


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Restores:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Restore\restore_databases.sql

-----------------------------------
--##INCLUDE: S4 Restore\Tools\copy_database.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_header_details.sql

-----------------------------------
--##INCLUDE: S4 Restore\Reports\list_recovery_metrics.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Performance
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Performance\list_processes.sql

-----------------------------------
--##INCLUDE: S4 Performance\list_transactions.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Monitoring
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_backup_execution.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_database_configurations.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\process_alerts.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\monitor_transaction_durations.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- High-Availability (Setup, Monitoring, and Failover):
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 High Availability\is_primary_database.sql

-----------------------------------
--##INCLUDE: S4 High Availability\server_trace_flags.sql

-----------------------------------
--##INCLUDE: S4 High Availability\compare_jobs.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Failover\respond_to_db_failover.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Failover\verify_job_states.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\job_synchronization_checks.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\server_synchronization_checks.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\data_synchronization_checks.sql



------------------------------------------------------------------------------------------------------------------------------------------------------
-- Auditing:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Audits\Utilities\generate_audit_signature.sql

-----------------------------------
--##INCLUDE: S4 Audits\Utilities\generate_specification_signature.sql

-----------------------------------
--##INCLUDE: S4 Audits\Monitoring\verify_audit_configuration.sql

-----------------------------------
--##INCLUDE: S4 Audits\Monitoring\verify_specification_configuration.sql

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 7. Update version_history with details about current version (i.e., if we got this far, the deployment is successful). 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DECLARE @CurrentVersion varchar(20) = N'##{{S4version}}';
DECLARE @VersionDescription nvarchar(200) = N'##{{S4version_summary}}';
DECLARE @InstallType nvarchar(20) = N'Install. ';

IF EXISTS (SELECT NULL FROM dbo.[version_history] WHERE CAST(LEFT(version_number, 3) AS decimal(2,1)) >= 4)
	SET @InstallType = N'Update. ';

SET @VersionDescription = @InstallType + @VersionDescription;

-- Add current version info:
IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @CurrentVersion) BEGIN
	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@CurrentVersion, @VersionDescription, GETDATE());
END;
GO

-----------------------------------
SELECT * FROM dbo.version_history;
GO