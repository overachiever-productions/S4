--##OUTPUT: \\Deployment
--##NOTE: This is a build file only (i.e., it stores upgade/install directives + place-holders for code to drop into admindb, etc.)
/*

	REFERENCE:
		- License, documentation, and source code at: 
			https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639

	NOTES:
		- This script will either install/deploy S4 version ##{{S4version}} or upgrade a PREVIOUSLY deployed version of S4 to ##{{S4version}}.
		- This script will create a new, admindb, if one is not already present on the server where this code is being run.

	Deployment Steps/Overview: 
		1. Create admindb if not already present.
		2. Create core S4 tables (and/or ALTER as needed + import data from any previous versions as needed). 
		3. Cleanup any code/objects from previous versions of S4 installed and no longer needed. 
		4. Deploy S4 version ##{{S4version}} code to admindb (overwriting any previous versions). 
		5. Report on current + any previous versions of S4 installed. 

*/

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 1. Create admindb if/as needed: 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SET NOCOUNT ON;

USE [master];
GO

IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
	CREATE DATABASE [admindb];  -- TODO: look at potentially defining growth size details - based upon what is going on with model/etc. 

	ALTER AUTHORIZATION ON DATABASE::[admindb] TO sa;

	ALTER DATABASE [admindb] SET RECOVERY SIMPLE;  -- i.e., treat like master/etc. 
END;
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 2. Core Tables:
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

-----------------------------------
--##INCLUDE: Common\tables\backup_log.sql

-----------------------------------
--##INCLUDE: Common\tables\restore_log.sql

-----------------------------------
--##INCLUDE: Common\tables\settings.sql

-----------------------------------
--##INCLUDE: Common\tables\alert_responses.sql

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 3. Cleanup and remove objects from previous versions (start by creating/adding dbo.drop_obsolete_objects)
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: Common\internal\drop_obsolete_objects.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- master db objects:
------------------------------------------------------------------------------------------------------------------------------------------------------

DECLARE @obsoleteObjects xml = CONVERT(xml, N'
<list>
    <entry schema="dbo" name="dba_DatabaseBackups_Log" type="U" comment="older table" />
    <entry schema="dbo" name="dba_DatabaseRestore_Log" type="U" comment="older table" />
    <entry schema="dbo" name="dba_SplitString" type="TF" comment="older UDF" />
    <entry schema="dbo" name="dba_CheckPaths" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_ExecuteAndFilterNonCatchableCommand" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_LoadDatabaseNames" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_RemoveBackupFiles" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_BackupDatabases" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_RestoreDatabases" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_VerifyBackupExecution" type="P" comment="older sproc" />

    <entry schema="dbo" name="dba_DatabaseBackups" type="P" comment="Potential FORMER versions of basic code (pre 1.0)." />
    <entry schema="dbo" name="dba_ExecuteNonCatchableCommand" type="P" comment="Potential FORMER versions of basic code (pre 1.0)." />
    <entry schema="dbo" name="dba_RestoreDatabases" type="P" comment="Potential FORMER versions of basic code (pre 1.0)." />
    <entry schema="dbo" name="dba_DatabaseRestore_CheckPaths" type="P" comment="Potential FORMER versions of HA monitoring (pre 1.0)." />
    
    <entry schema="dbo" name="dba_AvailabilityGroups_HealthCheck" type="P" comment="Potential FORMER versions of HA monitoring (pre 1.0)." />
    <entry schema="dbo" name="dba_Mirroring_HealthCheck" type="P" comment="Potential FORMER versions of HA monitoring (pre 1.0)." />
    
    <entry schema="dbo" name="dba_FilterAndSendAlerts" type="P" comment="FORMER version of alert filtering.">
        <notification>
            <content>NOTE: dbo.dba_FilterAndSendAlerts was dropped from master database - make sure to change job steps/names as needed.</content>
            <heading>WARNING - Potential Configuration Changes Required (alert filtering)</heading>
        </notification>
    </entry>
    <entry schema="dbo" name="dba_drivespace_checks" type="P" comment="FORMER disk monitoring alerts.">
        <notification>
            <content>NOTE: dbo.dba_drivespace_checks was dropped from master database - make sure to change job steps/names as needed.</content>
            <heading>WARNING - Potential Configuration Changes Required (disk-space checks)</heading>
        </notification>
    </entry>
</list>');

EXEC dbo.drop_obsolete_objects @obsoleteObjects, N'master';
GO

------------------------------------------------------------------------------------------------------------------------------------------------------
-- admindb objects:
------------------------------------------------------------------------------------------------------------------------------------------------------

DECLARE @olderObjects xml = CONVERT(xml, N'
<list>
    <entry schema="dbo" name="server_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
        <check>
            <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%server_synchronization_checks%''</statement>
            <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.server_synchronization_checks were found. Please update to call dbo.verify_server_synchronization instead.</warning>
        </check>
    </entry>
    <entry schema="dbo" name="job_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
        <check>
            <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%job_synchronization_checks%''</statement>
            <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.job_synchronization_checks were found. Please update to call dbo.verify_job_synchronization instead.</warning>
        </check>
    </entry>
    <entry schema="dbo" name="data_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
        <check>
            <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%data_synchronization_checks%''</statement>
            <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.data_synchronization_checks were found. Please update to call dbo.verify_data_synchronization instead.</warning>
        </check>
    </entry>

    <entry schema="dbo" name="load_database_names" type="P" comment="v5.2 - S4-52, S4-78, S4-87 - changing dbo.load_database_names to dbo.list_databases." />
    
    <entry schema="dbo" name="get_time_vector" type="P" comment="v5.6 Vector Standardization (cleanup)." />
    <entry schema="dbo" name="get_vector" type="P" comment="v5.6 Vector Standardization (cleanup)." />
    <entry schema="dbo" name="get_vector_delay" type="P" comment="v5.6 Vector Standardization (cleanup)." />

    <entry schema="dbo" name="load_databases" type="P" comment="v5.8 refactor/changes." />

    <entry schema="dbo" name="script_server_logins" type="P" comment="v6.2 refactoring." />
    <entry schema="dbo" name="print_logins" type="P" comment="v6.2 refactoring." />
    <entry schema="dbo" name="script_server_configuration" type="P" comment="v6.2 refactoring." />
    <entry schema="dbo" name="print_configuration" type="P" comment="v6.2 refactoring." />

    <entry schema="dbo" name="respond_to_db_failover" type="P" comment="v6.5 refactoring (changed to dbo.process_synchronization_failover)" />

	<entry schema="dbo" name="server_trace_flags" type="U" comment="v6.6 - Direct Query for Trace Flags vs delayed/table-checks." />
</list>');

EXEC dbo.drop_obsolete_objects @olderObjects, N'admindb';
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 4. Deploy new/updated code.
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [admindb];
GO

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Advanced S4 Error-Handling Capabilities:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: Common\Setup\enable_advanced_capabilities.sql

-----------------------------------
--##INCLUDE: Common\Setup\disable_advanced_capabilities.sql

-----------------------------------
--##INCLUDE: Common\Setup\verify_advanced_capabilities.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Common and Utilities:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: Common\get_engine_version.sql

-----------------------------------
--##INCLUDE: Common\split_string.sql

-----------------------------------
--##INCLUDE: Common\Internal\check_paths.sql

-----------------------------------
--##INCLUDE: Common\Internal\load_default_path.sql

-----------------------------------
--##INCLUDE: Common\Internal\load_default_setting.sql

-----------------------------------
--##INCLUDE: Common\Internal\shred_resources.sql

-----------------------------------
--##INCLUDE: Common\Internal\is_system_database.sql

-----------------------------------
--##INCLUDE: Common\Internal\parse_vector.sql

-----------------------------------
--##INCLUDE: Common\Internal\translate_vector.sql

-----------------------------------
--##INCLUDE: Common\Internal\translate_vector_delay.sql

-----------------------------------
--##INCLUDE: Common\Internal\translate_vector_datetime.sql

-----------------------------------
--##INCLUDE: Common\Internal\verify_alerting_configuration.sql

-----------------------------------
--##INCLUDE: Common\list_databases_matching_token.sql

-----------------------------------
--##INCLUDE: Common\Internal\replace_dbname_tokens.sql

-----------------------------------
--##INCLUDE: Common\Internal\format_sql_login.sql

-----------------------------------
--##INCLUDE: Common\Internal\format_windows_login.sql

-----------------------------------
--##INCLUDE: Common\list_databases.sql

-----------------------------------
--##INCLUDE: Common\format_timespan.sql

-----------------------------------
--##INCLUDE: S4 Utilities\count_matches.sql

-----------------------------------
--##INCLUDE: S4 Utilities\kill_connections_by_hostname.sql

-----------------------------------
--##INCLUDE: Common\execute_uncatchable_command.sql

-----------------------------------
--##INCLUDE: Common\execute_command.sql

-----------------------------------
--##INCLUDE: Common\Internal\establish_directory.sql

-----------------------------------
--##INCLUDE: Common\Internal\load_backup_database_names.sql

-----------------------------------
--##INCLUDE: S4 Utilities\shred_string.sql

-----------------------------------
--##INCLUDE: S4 Tools\print_long_string.sql

-----------------------------------
--##INCLUDE: Common\Internal\get_executing_dbname.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Backups:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Backups\Utilities\remove_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Backups\backup_databases.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Configuration:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Configuration\script_login.sql

-----------------------------------
--##INCLUDE: S4 Configuration\script_logins.sql

-----------------------------------
--##INCLUDE: S4 Configuration\export_server_logins.sql

-----------------------------------
--##INCLUDE: S4 Configuration\script_configuration.sql

-----------------------------------
--##INCLUDE: S4 Configuration\export_server_configuration.sql

-----------------------------------
--##INCLUDE: S4 Configuration\Setup\enable_alerts.sql

-----------------------------------
--##INCLUDE: S4 Configuration\Setup\enable_alert_filtering.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Restores:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_header_details.sql

-----------------------------------
--##INCLUDE: S4 Restore\restore_databases.sql

-----------------------------------
--##INCLUDE: S4 Restore\Tools\copy_database.sql

-----------------------------------
--##INCLUDE: S4 Restore\apply_logs.sql

-----------------------------------
--##INCLUDE: S4 Restore\Reports\list_recovery_metrics.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Performance
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Performance\list_processes.sql

-----------------------------------
--##INCLUDE: S4 Performance\list_transactions.sql

-----------------------------------
--##INCLUDE: S4 Performance\list_collisions.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Monitoring
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_backup_execution.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_database_configurations.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_drivespace.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\process_alerts.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\monitor_transaction_durations.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Maintenance
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Maintenance\check_database_consistency.sql

-----------------------------------
--##INCLUDE: S4 Maintenance\Automated Log Shrinking\list_logfile_sizes.sql

-----------------------------------
--##INCLUDE: S4 Maintenance\Automated Log Shrinking\shrink_logfiles.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Tools
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Tools\normalize_text.sql

-----------------------------------
--##INCLUDE: S4 Tools\extract_statement.sql

-----------------------------------
--##INCLUDE: S4 Tools\extract_waitresource.sql

-----------------------------------
--##INCLUDE: S4 Tools\is_xml_empty.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
--- SQL Server Agent Jobs
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Jobs\list_running_jobs.sql

-----------------------------------
--##INCLUDE: S4 Jobs\is_job_running.sql

-----------------------------------
--##INCLUDE: S4 Jobs\translate_program_name_to_agent_job.sql

-----------------------------------
--##INCLUDE: S4 Jobs\get_last_job_completion.sql

-----------------------------------
--##INCLUDE: S4 Jobs\get_last_job_completion_by_session_id.sql

------------------------------------------------------------------------------------------------------------------------------------------------------
-- High-Availability (Setup, Monitoring, and Failover):
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 High Availability\server_trace_flags.sql

-----------------------------------
-- v6.6 Changes to PARTNER (if present):
IF EXISTS (SELECT NULL FROM sys.servers WHERE UPPER([name]) = N'PARTNER' AND [is_linked] = 1) BEGIN 
	IF NOT EXISTS (SELECT NULL FROM sys.[sysservers] WHERE UPPER([srvname]) = N'PARTNER' AND [rpc] = 1) BEGIN
        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc', 
	        @optvalue = N'true';		

		PRINT N'Enabled RPC on PARTNER (for v6.6+ compatibility).';
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.[sysservers] WHERE UPPER([srvname]) = N'PARTNER' AND [rpcout] = 1) BEGIN
        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc out', 
	        @optvalue = N'true';
			
		PRINT N'Enabled RPC_OUT on PARTNER (for v6.6+ compatibility).';
	END;
END;

-----------------------------------
--##INCLUDE: S4 High Availability\list_synchronizing_databases.sql

-----------------------------------
--##INCLUDE: S4 High Availability\is_primary_server.sql

-----------------------------------
--##INCLUDE: S4 High Availability\is_primary_database.sql

-----------------------------------
--##INCLUDE: S4 High Availability\compare_jobs.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Failover\process_synchronization_failover.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Failover\verify_job_states.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\Internal\populate_trace_flags.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\Internal\verify_online.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\Internal\verify_partner.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\verify_job_synchronization.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\verify_server_synchronization.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Monitoring\verify_data_synchronization.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Setup & Configuration\add_synchronization_partner.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Setup & Configuration\add_failover_processing.sql

-----------------------------------
--##INCLUDE: S4 High Availability\Setup & Configuration\verify_synchronization_setup.sql

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
-- 5. Update version_history with details about current version (i.e., if we got this far, the deployment is successful). 
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