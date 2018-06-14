--##OUTPUT: \\Deployment\Install\
--##NOTE: This is a build/file (instructions for compiling a full deployment/upgrade script). Check Install and Upgrades folders for output.

/*

	NOTES:
		- This script assumes that there MAY (or may NOT) be older S4 scripts on the server and, if found, will migrate data (backup and restore logs) and cleanup/remove older code from masterdb.  

	TODO: 
		- If xp_cmdshell ends up being enabled, drop a link to S4 documentation on what it is, why it's needed, and why it's not the security risk some folks on interwebs make it out to be. 

*/



USE [master];
GO

IF EXISTS (SELECT NULL FROM sys.configurations WHERE [name] = N'xp_cmdshell' AND value_in_use = 0) BEGIN;

	PRINT 'NOTE: Enabling xp_cmdshell for use by SysAdmin role-members only.';

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



USE [master];
GO

IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
	CREATE DATABASE [admindb];  -- TODO: look at potentially defining growth size details - based upon what is going on with model/etc. 

	ALTER AUTHORIZATION ON DATABASE::[admindb] TO sa;

	ALTER DATABASE [admindb] SET RECOVERY SIMPLE;  -- i.e., treat like master/etc. 
END;
GO

USE [admindb];
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- create and populate version history info:
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


DECLARE @CurrentVersion varchar(20) = N'4.7.2556.1';

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
	END
END;


-- Add current version info:
IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @CurrentVersion) BEGIN
	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@CurrentVersion, 'Initial Installation/Deployment.', GETDATE());
END;

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Setup and Copy info from backup and restore logs... 
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

-- copy over data from previous deployments if present. 
-- NOTE: done in a separate check to help keep things idempotent... i.e., if there's an error/failure AFTER creating the table... we wouldn't branch to this logic again IF it's part of the table creation.
IF @objectId IS NOT NULL BEGIN 
		
	PRINT 'Importing Previous Data.... ';
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
		BackupID NOT IN (SELECT backup_id FROM dbo.backup_log);

	SET IDENTITY_INSERT dbo.backup_log OFF;
END


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

-- copy over data as needed:
SELECT @objectId = [object_id] FROM master.sys.objects WHERE [name] = 'dba_DatabaseRestore_Log';
IF @objectId IS NOT NULL BEGIN;

	-- v4.7.0.16942 - convert restore_log datetimes from UTC to local... 
	DECLARE @hoursDiff int; 
	SELECT @hoursDiff = DATEDIFF(HOUR, GETDATE(), GETUTCDATE());

	PRINT 'Importing Previous Data.... ';
	SET IDENTITY_INSERT dbo.restore_log ON;

	INSERT INTO dbo.restore_log (restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, 
		consistency_start, consistency_end, consistency_succeeded, dropped, error_details)
	SELECT 
		RestorationTestId,
        ExecutionId,
        TestDate,
        [Database],
        RestoredAs,
        DATEADD(HOUR, 0 - @HoursDiff, RestoreStart) RestoreStart,
		DATEADD(HOUR, 0 - @HoursDiff, RestoreEnd) RestoreEnd,
        RestoreSucceeded,
        DATEADD(HOUR, 0 - @HoursDiff, ConsistencyCheckStart) ConsistencyCheckStart,
        DATEADD(HOUR, 0 - @HoursDiff, ConsistencyCheckEnd) ConsistencyCheckEnd,
        ConsistencyCheckSucceeded,
        Dropped,
        ErrorDetails
	FROM 
		master.dbo.dba_DatabaseRestore_Log
	WHERE 
		RestorationTestId NOT IN (SELECT restore_test_id FROM dbo.restore_log);

	SET IDENTITY_INSERT dbo.restore_log OFF;

END


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Cleanup and Remove any/all previous code from the master database:

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
	SELECT 'NOTE: dbo.dba_FilterAndSendAlerts was dropped from master database - make sure to change job steps/names as needed.' [WARNING - Potential Configuration Changes Required];
END;
GO


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Deploy new code:

---------------------------------------------------------------------------
-- Common Code:
---------------------------------------------------------------------------

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


---------------------------------------------------------------------------
-- Backups:
---------------------------------------------------------------------------

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


---------------------------------------------------------------------------
-- Restores:
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Restore\restore_databases.sql

-----------------------------------
--##INCLUDE: S4 Restore\Tools\copy_database.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_header_details.sql

---------------------------------------------------------------------------
--- Diagnostics
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Diagnostics\Performance\list_processes.sql

---------------------------------------------------------------------------
--- Monitoring
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_backup_execution.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_database_configurations.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\process_alerts.sql

---------------------------------------------------------------------------
-- Monitoring (HA):
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\is_primary_database.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\job_synchronization_checks.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\respond_to_db_failover.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\server_synchronization_checks.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\server_trace_flags.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\verify_job_states.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\compare_jobs.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\data_synchronization_checks.sql


---------------------------------------------------------------------------
-- Display Versioning info:
SELECT * FROM dbo.version_history;
GO

