[README](?encodedPath=README.md) > S4 APIs

## S4 APIs

> ### <i class="fa fa-random"></i> Work in Progress
> Most public S4 APIs/Modules have NOT been fully documented (yet). Those that have been documented, have a link to their 'full' documentation page. 

### TABLE OF CONTENTS

- [SQL Server Audit Signature Monitoring and Verification](#sql-server-audit-signature-monitoring-and-verification)
- [SQL Server BACKUPs and Utilities](#sql-server-backups-and-utilities)
- [SQL Server Configuration Utilities](#sql-server-configuration-utilities)
- [High Availability Configuration, Monitoring, and Management](#high-availability-configuration,-monitoring,-and-management)
- [SQL Server Agent Jobs](#sql-server-agent-jobs)
- [SQL Server Maintenance](#sql-server-maintenance)
- [Monitoring](#monitoring)
- [Performance](#performance)
- [RESTORE Operations and Utilities](#restore-operations-and-utilities)
- [Tools and Utilities](#tools-and-utilities)


### SQL Server Audit Signature Monitoring and Verification
Keep an eye on your audit specifications and definitions - by means of periodic checkups to verify that audit details and 'signatures' haven't changed: 

- **dbo.generate_audit_signature:** Generate a HASH that defines core details for a specified Audit.
- **dbo.generate_specification_signature:** Generate a HASH for audit specification details.
- **dbo.verify_audit_configuration:** Verify that previously generated HASH of audit matches CURRENT audit configuration.
- **dbo.verify_specification_configuration:** Verify that previously generated HASH of an audit specification matches the current/real-time HASH of the same audit specification.

### SQL Server Backups and Utilities

- **[dbo.backup_databases](?encodedPath=Documentation%2Fapis%2Fbackup_databases.md):** Execute and easily automate backups. **Make sure to check [Best Practices documentation](?encodedPath=Documentation%2Fbest-practices%2FBACKUPS.md) on SQL Server Backups as well.**
- **dbo.remove_backup_files:** Helper function used by dbo.backup_databases to remove older/expired backups - but can be used 'manually' to cleanup older/expired backups as needed. 

### SQL Server Configuration Utilities 
- **dbo.script_configuration:** Print/Dump server-level configuration details and settings to the console. 
- **dbo.script_database_configuration:** Print/Dump database-level configuration/settings/details to the console. 
- **dbo.script_login:** Script a single, specific, SQL Server Login - along with its SID, hashed password, and a specifier for what to do if the Login already exists on the target server where the script will be run. 
- **dbo.script_logins:** 'Mass' login scripting functionality; can target all logins on server and/or by specific databases.
- **dbo.export_server_configuration:** Wrapper for dbo.script_configuration - which allows OUTPUT to be saved to a flat-file on the server (great for period 'dumps' of configuration settings).
- **dbo.export_server_logins:** Wrapper for dbo.script_logins - that dumps ALL logins to a specified flat file (great as a nightly DR protection - just make sure to control access to the output file as needed).

### SQL Server High-Availability Configuration, Monitoring, and Management

#### Meta-Data and 'Helper' capabilities:
- **dbo.is_primary_server:** returns true if the FIRST (alphabetically) synchronized database on a specified server is the primary database in a Mirroring or AG configuration.
- **dbo.is_primary_database:** returns true if specified database (name) is the primary.
- **dbo.list_synchronizing_databases:** Provides a list of all databases being Mirrored or Participating in an Availability Group as Replicas. 

#### Availability Setup and Configuration Tools
- **dbo.add_synchronization_partner:** Create/Define a PARTNER setup as a Linked Server Definition - for server, job, and data-synchronization checks. 
- **dbo.add_failover_processing:** Add/Create SQL Server Agent Job (and underlying code) to respond to SQL Server Failover operations (Mirroring and/or AG).
- **dbo.process_synchronization_failover:** Stored procedure executed when Mirroring or AG failover occurs (i.e., code defined for execution via execution of dbo.add_failover_processing).
- **dbo.verify_synchronization_setup:** 'Checklist' to ensure that HA configurations are correctly defined and setup for synchronization (Mirroring or AGs).

#### Availability Group and Mirroring Managgement Tools
- **dbo.seed_synchronization:** [not yet implemented.]
- **dbo.execute_manual_failover:** [not yet implemented.]
- **dbo.suspend_synchronization:** [not yet implemented.]
- **dbo.resume_synchronization:** [not yet implemented.]

#### Server Synchronization and Monitoring
- **dbo.compare_jobs:** Diagnostic which can be used to report on high-level diffferences between jobs on `PARTNER` servers - or to report on low-level details about a specific/individual job. (Useful when troubleshooting job-synchronization alerts/problems.)
- **dbo.verify_server_synchronization:** Ensure that logins, Trace Flags, Configuration Settings, and other CORE server-level details are identical between `PARTNER` servers in a Mirroring or AG configuration.
- **dbo.verify_job_synchronzization:** Verify that SQL Server Agent Jobs are identically defined between `PARTNER` servers and/or that their enabled/disabled states properly corresponde to whether the databases being targeted are the primary or secondary database. 
- **dbo.verify_data_synchronization:** Verify overall AG or Mirroring topology health and check on transactional and other types of lag/delay between `PARTNER` servers. 


### SQL Server Agent Jobs
- **dbo.list_running_jobs:** See all SQL Server Agent Jobs currently running or that WERE running during a specified start/end time. (Great for troubleshooting hiccups and other 'perf' problems - to see what jobs were running at/around the time of the problems 'after the fact'.)
- **dbo.get_last_job_completion:** Grab the last completion time for a specified SQL Server Agent Job. 
- **dbo.translate_program_name_to_agent_job:** Translate running SQL Server Agent Jobs (which use GUIDs for identification via their connection-strings) into the names / steps of the SQL Server Agent Jobs being executed.

### SQL Server Maintenance Routines
- **dbo.check_database_consistency:** High-level wrapper for DBCC CHECKDATABASE - but optimized for automated (unattended) execution by means of advanced S4 error handling (i.e., capture of raw/underlying problems and errors).
- **dbo.resize_transaction_logs:** Automate or manually kick-off transaction log resizing (primarily for multi-tenant systems).

### Monitoring
- **dbo.monitor_transaction-durations:** Set up alerts for long-running operations and/or long-running transactions that are locking/blocking.
- **dbo.process_alerts:** Intercept SQL Server Agent Alerts (via a JOB) and filter/exclude any 'noise' alerts for Severity 17+ alerts. 
- **dbo.verify_backup_execution:** Make sure that FULL and T-LOG (for FULL/Bulk-Logged Recovery) databases have been executed within a set/timely fashion. 
- **dbo.verify_database_activity:** Make sure that 'something is happening' inside of specified/target databases - or, in other words, make sure your apps/users are able to access and use specific databases as needed. 
- **dbo.verify_database_configuration:** Ensure that databases on your server aren't getting 'dumbed down' by means of auto-shrinks, down-level compatibility, and other core/critical configurations checks/settings.
- **dbo.verify_drivespace:** Easily set up alerts for when FREE disk space drops below thresholds that you specify.

### Performance
- **dbo.list_processes:** Get a live look of queries and operations that are consuming resources on your server - in real time. (Similar to TOP command in Linux - but for SQL Server and with lots of powerful context that can be very helpful for troubleshooting performance and other production-level problems.)
- **dbo.list_parallel_processes:** Just like dbo.list_processes - but ONLY reports on queries and operations running in parallel (i.e., using multiple threads) - and provides additional insight into thread/task usage and counts. 
- **dbo.list_collisions:** Like dbo.list_processes - but ONLY reports on operations that are blocking or blocked - along with more complex blocking-chain details than dbo.list_processes.
- **dbo.list_transactions:** Live-view of all 'in-flight' transactions along with (optional) detailed metrics about resources being used and held.

### Restore Operations and Utilities
- **[dbo.restore_databases](?encodedPath=Documentation%2Fapis%2Frestore_databases.md):** sdffsd
- **[dbo.apply_logs](?encodedPath=Documentation%2Fapis%2Fverify_database_configurations.md):** dfwsfsd
- **dbo.copy_database:** Leverages S4's dbo.backup_database + dbo.restore_database to create a simple 'wrapper' that enables quick and easy 'copies' of databases to be created 'on the fly' - ideal for multi-tenant use/scenarios (as dbo.copy_database also kicks off a FULL backup as part of the 'copy' process).
- **dbo.list_recovery_metrics:** Each time dbo.restore_databases is run, it stores meta-data about restore times, included files (i.e., the name/size of each .bak + .trn included as part of the backup), corruption checks, and other metrics/statistics - which can be queried to get a quick and accurate sense of compliance with SLAs.

### Tools And Utilities
- **[dbo.list_databases](?encodedPath=Documentation%2Fapis%2Flist_databases):** Core component of S4 functionality - as it provides easy-to-manage techniques for getting lists of various TYPEs of databases (based on states/statuses/locations/etc.)
- **dbo.split_string:** Performance optimized string-splitting functionality - that ensures proper sort/output order - and, optionally, allows trim() operations against split-ed values.
- **dbo.extract_statement:** Given a specific database_id, object_id, and T-SQL Stack start/end statement offsets, this S4 module will grab the exact T-SQL statement being executed from within a module (i.e., sproc, UDF, trigger, etc.). 
- **dbo.extract_waitresource:** Given a specific WAIT_RESOURCE, this S4 module will translate/fetch explicit details about the resource in question. (Helpful when troubleshooting locking/blocking problems and/or deadlocks).
- **dbo.is_xml_empty:** Detecting 'empty' is harder than you might initially think. It's not rocket-surgery, but it does warrant some easily re-usable logic to make detection easier.
- **dbo.normalize_text:** Parameterize or normalize T-SQL text/statements.
- **dbo.print_long_string:** Bypass the 4000 char limit of PRINT to 'spit out' long text. 
- **dbo.count_matches:** Returns the number of times a target-text appears in a larger text. 
- **dbo.kill_connections_by_hostname:** For misbehaving or problematic hosts. 
- **dbo.shred_string:** Allows multi-dimension 'string splits' - i.e., not just splitting into rows, but with columns also. 
- **dbo.shred_string_to_xml:** As above, but outputs into XML - to help allow hacks/bypasses of Nested Insert EXEC problems.


[Return to Table of Contents](#table-of-contents)

[Return to README](?encodedPath=README.md)