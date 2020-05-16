![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[README](/readme.md) > S4 APIs

# S4 - APIs

> :zap: **Work in Progress:** Full API documentation currently represents a work-in-progress. 

## Table of Contents

- [SQL Server BACKUPs and Utilities](#sql-server-backups-and-utilities)
- [RESTORE Operations and Utilities](#restore-operations-and-utilities)
- [Performance Monitoring and Diagnostics](#performance-monitoring-and-diagnostics)
- [SQL Server Configuration Utilities](#sql-server-configuration-utilities)
- [High Availability Configuration, Monitoring, and Management](#high-availability-configuration-monitoring-and-management)
- [SQL Server Agent Jobs](#sql-server-agent-jobs)
- [SQL Server Maintenance](#sql-server-maintenance-routines)
- [Monitoring](#monitoring)
- [SQL Server Audit Signature Monitoring and  Verification](#sql-server-audit-signature-monitoring-and-verification)
- [T-SQL Utilities](#t-sql-utilities)
- [SQL Server Resources and Tools](#sql-server-resources-and-tools)

## SQL Server Backups and Utilities

- **[dbo.backup_databases](/documentation/apis/backup_databases.md)** - Easily execute and AUTOMATE SQL Server backups.
    - Make sure to check [Best Practices documentation on SQL Server Backups](/documentation/best-practices/backups.md)  as well.
- **dbo.remove_backup_files** - Helper function used by `dbo.backup_databases` to remove older/expired backups - but can be used manually to cleanup older/expired backups as needed.

[Return to Table of Contents](#table-of-contents)

## Restore Operations and Utilities

- **[dbo.restore_databases](/documentation/apis/restore_databases.md)** - Complex functionality and capabilities - all rolled into a simple and easy to use routine to make automated and manual restores trivial.
- **[dbo.apply_logs](/documentation/apis/apply_logs.md)** - A full-blown replacement for SQL Server's Native Log Shipping - to provide easier setup/automation while providing more options/configuration.
- **dbo.copy_database** - Leverages S4's `dbo.backup_database` + `dbo.restore_database` to create a simple 'wrapper' that enables quick and easy 'copies' of databases to be created 'on the fly' - ideal for multi-tenant use/scenarios (as `dbo.copy_database` also kicks off a FULL backup as part of the 'copy' process).
- **dbo.list_recovery_metrics** - Each time `dbo.restore_databases` is run, it stores meta-data about restore times, included files (i.e., the name/size of each .bak + .trn included as part of the backup), corruption checks, and other metrics/statistics - which can be queried to get a quick and accurate sense of compliance with SLAs.

[Return to Table of Contents](#table-of-contents)

## Performance Monitoring and Diagnostics

- **dbo.list_processes** - Get a live look at queries and operations that are consuming resources on your server - in real time. (Similar to TOP command in Linux - but for SQL Server and with lots of powerful context that can be very helpful for troubleshooting performance and other production-level problems.)
- **dbo.list_parallel_processes** - Just like `dbo.list_processes` - but ONLY reports on queries and operations running in parallel (i.e., using multiple threads) - and provides additional insight into thread/task usage and counts. 
- **dbo.list_collisions** - Like `dbo.list_processes` - but ONLY reports on operations that are blocking or blocked - along with more complex blocking-chain details than `dbo.list_processes`.
- **dbo.list_transactions** - Live-view of all 'in-flight' transactions along with (optional) detailed metrics about resources being used and held.

[Return to Table of Contents](#table-of-contents)

## SQL Server Configuration Utilities

### Setup and Configuration
- **dbo.configure_database_mail** - Easily configure SQL Server Database mail via a single script.
- **dbo.enable_alerts** - Easily set up IO/Corruption and/or Severity 17+ Alerts. 
- **dbo.enable_alert_filtering** - Easily configure defined alerts to be routed into a stored procedure that will allow for filters/easy-removal of 'noise' alerts you don't want to see anymore. 
- **dbo.enable_disk_monitoring** - Set up a regularly executing job to alert if/when available disk drops below a specified threshold. 
- **dbo.manage_server_history** - Automate the creation of a weekly job to truncate job-history, backup-history, mail-history, FT-crawl logs (optional), and cycle SQL and SQL Agent logs. 

### Dump / Export of Existing Configuration
- **dbo.script_server_configuration** - Print/Dump server-level configuration details and settings to the console. 
- **dbo.script_database_configuration** - Print/Dump database-level configuration/settings/details to the console. 
- **dbo.script_login** - Script a single, specific, SQL Server Login - along with its SID, hashed password, and a specifier for what to do if the Login already exists on the target server where the script will be run. 
- **dbo.script_logins** - 'Mass' login scripting functionality; can target all logins on server and/or by specific databases.
- **dbo.export_server_configuration** - Wrapper for `dbo.script_configuration` - which allows OUTPUT to be saved to a flat-file on the server (great for period 'dumps' of configuration settings) - and copied off-box (for DR protection purposes).
- **dbo.export_server_logins** - Wrapper for `dbo.script_logins` - that dumps ALL logins to a specified flat file (great as a nightly DR protection - just make sure to control access to the output file as needed).

[Return to Table of Contents](#table-of-contents)

## High-Availability Configuration, Monitoring, and Management

### Meta-Data and 'Helper' capabilities:
- **dbo.is_primary_server** - rReturns true if the FIRST (alphabetically) synchronized database on a specified server is the primary database in a Mirroring or AG configuration.
- **dbo.is_primary_database** - Returns true if specified database (name) is the primary.
- **dbo.list_synchronizing_databases** - Provides a list of all databases being Mirrored or Participating in an Availability Group as Replicas. 

### Availability Setup and Configuration Tools
- **dbo.add_synchronization_partner** - Create/Define a PARTNER setup as a Linked Server Definition - for server, job, and data-synchronization checks. 
- **dbo.add_failover_processing** - Add/Create SQL Server Agent Job (and underlying code) to respond to SQL Server Failover operations (Mirroring and/or AG).
- **dbo.process_synchronization_failover** - Stored procedure executed when Mirroring or AG failover occurs (i.e., code defined for execution via execution of `dbo.add_failover_processing`).
- **dbo.verify_synchronization_setup** - 'Checklist' to ensure that HA configurations are correctly defined and setup for synchronization (Mirroring or AGs).

### Server Synchronization and Monitoring
- **dbo.compare_jobs** - Diagnostic which can be used to report on high-level diffferences between jobs on `PARTNER` servers - or to report on low-level details about a specific/individual job. (Useful when troubleshooting job-synchronization alerts/problems.)
- **dbo.verify_server_synchronization** - Ensure that logins, Trace Flags, Configuration Settings, and other CORE server-level details are identical between `PARTNER` servers in a Mirroring or AG configuration.
- **dbo.verify_job_synchronzization** - Verify that SQL Server Agent Jobs are identically defined between `PARTNER` servers and/or that their enabled/disabled states properly corresponde to whether the databases being targeted are the primary or secondary database. 
- **dbo.verify_data_synchronization** - Verify overall AG or Mirroring topology health and check on transactional and other types of lag/delay between `PARTNER` servers. 

[Return to Table of Contents](#table-of-contents)

## SQL Server Agent Jobs
- **dbo.list_running_jobs** - See all SQL Server Agent Jobs currently running or that WERE running during a specified start/end time. (Great for troubleshooting hiccups and other 'perf' problems - to see what jobs were running at/around the time of the problems 'after the fact'.)
- **dbo.get_last_job_completion:** Grab the last completion time for a specified SQL Server Agent Job. 
- **dbo.translate_program_name_to_agent_job** - Translate running SQL Server Agent Jobs (which use GUIDs for identification via their connection-strings) into the names / steps of the SQL Server Agent Jobs being executed.

[Return to Table of Contents](#table-of-contents)

## SQL Server Maintenance Routines
- **dbo.check_database_consistency** - High-level wrapper for `DBCC CHECKDATABASE` - but optimized for automated (unattended) execution by means of advanced S4 error handling (i.e., capture of raw/underlying problems and errors).
- **dbo.resize_transaction_logs** - Automate or manually kick-off transaction log resizing (primarily for multi-tenant systems).

[Return to Table of Contents](#table-of-contents)

## Monitoring
- **dbo.monitor_transaction-durations** - Set up alerts for long-running operations and/or long-running transactions that are locking/blocking.
- **dbo.process_alerts** - Intercept SQL Server Agent Alerts (via a JOB) and filter/exclude any 'noise' alerts for Severity 17+ alerts. 
- **dbo.verify_backup_execution** - Make sure that FULL and T-LOG (for FULL/Bulk-Logged Recovery) databases have been executed within a set/timely fashion. 
- **dbo.verify_database_activity** - Make sure that 'something is happening' inside of specified/target databases - or, in other words, make sure your apps/users are able to access and use specific databases as needed. 
- **dbo.verify_database_configuration** - Ensure that databases on your server aren't getting 'dumbed down' by means of auto-shrinks, down-level compatibility, and other core/critical configurations checks/settings.
- **dbo.verify_drivespace** - Easily set up alerts for when FREE disk space drops below thresholds that you specify.

[Return to Table of Contents](#table-of-contents)


## SQL Server Audit Signature Monitoring and Verification

Keep an eye on your audit specifications and definitions - by means of periodic checkups to verify that audit details and 'signatures' haven't changed: 

- **dbo.generate_audit_signature** - Generate a HASH that defines core details for a specified Audit.
- **dbo.generate_specification_signature** - Generate a HASH for audit specification details.
- **dbo.verify_audit_configuration** - Verify that previously generated HASH of audit matches CURRENT audit configuration.
- **dbo.verify_specification_configuration** - Verify that previously generated HASH of an audit specification matches the current/real-time HASH of the same audit specification.

[Return to Table of Contents](#table-of-contents)

## T-SQL Utilities
Within S4, Utilities are defined as small/light-weight scripts that are smaller in scope that Tools. In short, S4 Utilities are primarily just 'helper' sprocs and functions (UDFs) - designed to make common T-SQL and other DBA-related tasks easier to manage.
- **[dbo.list_databases](/documentation/apis/list_databases.md)** - Core component of S4 functionality - as it provides easy-to-manage techniques for getting lists of various TYPEs of databases (based on states/statuses/locations/etc.)
- **dbo.split_string** - Performance optimized string-splitting functionality - that ensures proper sort/output order - and, optionally, allows trim() operations against split-ed values.
- **dbo.extract_statement** - Given a specific database_id, object_id, and T-SQL Stack start/end statement offsets, this S4 module will grab the exact T-SQL statement being executed from within a module (i.e., sproc, UDF, trigger, etc.). 
- **dbo.extract_waitresource** - Given a specific WAIT_RESOURCE, this S4 module will translate/fetch explicit details about the resource in question. (Helpful when troubleshooting locking/blocking problems and/or deadlocks).
- **dbo.is_xml_empty** - Detecting 'empty' is harder than you might initially think. It's not rocket-surgery, but it does warrant some easily re-usable logic to make detection easier.
- **dbo.normalize_text** - Parameterize or normalize T-SQL text/statements.
- **dbo.print_long_string** - Bypass the 4000 char limit of PRINT to 'spit out' long text. 
- **dbo.count_matches** - Returns the number of times a target-text appears in a larger text. 
- **dbo.kill_connections_by_hostname** - For misbehaving or problematic hosts. 
- **dbo.shred_string** - Allows multi-dimension 'string splits' - i.e., not just splitting into rows, but with columns also. 
- **dbo.shred_string_to_xml** - As above, but outputs into XML - to help allow hacks/bypasses of `Nested Insert EXEC` problems.

[Return to Table of Contents](#table-of-contents)

## SQL Server Resources and Tools
In addition to native T-SQL functionality and utilities (lighter-weight scripts and 'helpers'), S4 also provides a few higher-level 'tools' - partial or full-blown 'solutions' keyed at specific tasks. 
- **[EmergencyStart-SQLServer.ps1](/documentation/apis/emergency_start_sql_server.md)** - PowerShell script to simplify the process of starting SQL Server from the command-line (for disaster-recovery and other emergency administrative needs).
- **SQL Server Continuity Validation** - Revamp/rewrite of [SQLContinuitySIM](https://www.sqlserveraudits.com/tools/sql-continuity-sim) - (Rewrite Pending...)
- **SQL Server Replication Schema Parser** - Revamp/rewrite of [SQL Server Replication Schema Options Parser](https://www.sqlserveraudits.com/tools/replication-schema-options-parser) (Rewrite Pending... )

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md)