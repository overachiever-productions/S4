﻿# S4

<span style="font-size: 26px">**S**imple **S**QL **S**erver **S**cripts -> **S4**</span>

## TABLE OF CONTENTS
  
> ### <i class="fa fa-random"></i> Work in Progress  
> This documentation is a work in progress. Any content [surrounded by square brackets] represents a DRAFT version of documentation.

- [License](#license)
- [Requirements](#requirements)
- [Setup](#setup)
    - [Step By Step Installation Instructions](#step-by-step-installation)
    - [Enabling Advanced S4 Features](#enabling-advanced-s4-features)
    - [Updating S4](#updates)
    - [Removing S4](#removing)
- [S4 Features and Benefits](#features-and-benefits)
    - [S4 Backups](#simplified-and-robust-backups) 
    - [Automated Restore Tests](#simplified-restore-operations-and-automated-restore-testing)
    - [Performance Monitoring](#performance-monitoring)
    - [S4 Utilities](#utilities)
    - [Using S4 Conventions](#using-s4-conventions)
- [S4 Best Practices](#s4-best-practices)

## License

[MIT LICENSE](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=master&encodedPath=LICENSE)

## Requirements
**SQL Server Requirements:**

- SQL Server 2012+.
- MOST (but not all) S4 functionality works with SQL Server 2008 / SQL Server 2008 R2. 
- Some advanced functionality does not work on Express and/or Web Versions of SQL Server.
- Windows Server Only. (Not yet tested on Azure/Linux.)

**Setup Requirements:**
- To deploy, you'll need the ability to run T-SQL scripts against your server and create a database.
- Advanced error handling (for backups and other automation) requires xp_cmdshell to be enabled - as per the steps outlined in [Enabling Advanced S4 Features](#enabling-advanced-s4-features).
- SMTP (SQL Server Database Mail) for advanced S4 automation and alerts.

## SETUP 
Setup is trivial: run a [T-SQL script "e.g.7.0.3042.sql"](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) against your target server and S4 will create a new `[admindb]` database - as the new home for all S4 code and functionality.  

Advanced S4 automation and error handling requires a server-level change - which has to be explicitly enabled via the step outlined in [Enabling Advanced S4 Features](#enabling-advanced-s4-features). 

Once deployed, it's easy to [keep S4 updated](#updating-s4) - just grab new releases of the deployment file, and run them against your target server (where they'll see your exising deployment and update code as needed).

If (for whatever reason) you no longer want/need S4, you can 'Undo' advanced functionality via the instructions found in [Removing S4](#removing-s4) - and then DROP the `[admindb]` database.

### Steb By Step Installation
To deploy S4:
1. Grab the `latest-release.sql` S4 deployment script. By convention, the LATEST version of S4 will be available in the [\Deployment\ ](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) folder - and will be the only T-SQL file present (e.g., 5.5.2816.2.sql - as per the screenshot below).

![](https://assets.overachiever.net/s4/images/install_get_latest_file.gif)

2. Execute the contents of the `latest-version.sql` (e.g., "5.5.2816.2.sql") file against your target server. 
3. The script will do everything necessary to create a new database (the `[admindb]`) and populate it with all S4 entities and code needed.
4. At script completion, information about the current version(s) installed on your server instance will be displayed 

![](https://assets.overachiever.net/s4/images/install_install_completed.gif)

> #### <i class="fa fa-bolt"></i> Existing Deployments
> *If S4 has **already** been deployed to your target SQL Server Instance, the deployment script will detect this and simply UPDATE all code in the [admindb] to the latest version - adding a new entry into admindb.dbo.version_history.* 

### Enabling Advanced S4 Features
Once S4 has been deployed (i.e., after the admindb has been created), to deploy advanced error-handling features, simply run the following: 

```sql
    EXEC [admindb].dbo.[enable_advanced_capabilities];
    GO
```
#### Common Questions and Concerns about enabling xp_cmdshell 
Meh. There's a lot of [FUD](https://en.wikipedia.org/wiki/Fear,_uncertainty_and_doubt) out there about enabling xp_cmdshell on your SQL Server. *Security is NEVER something to take lightly, but xp_cmdshell isn't a security concern - having a SQL Server running with ELEVATED PERMISSIONS is a security concern.* xp_cmdshell merely allows the SQL Server Service account to interact with the OS much EASIER than would otherwise be possible without xp_cmdshell enabled. 

To checkup-on/view current S4 advanced functionality and configuration settings, run the following: 

```sql
    EXEC dbo.verifiy_advanced_capabilities;
    GO
```

**Note that S4 ships with Advanced Capabilities DISABLED by default.**

[For more information on WHY xp_cmdshell makes lots of sense to use for 'advanced' capabilities AND to learn more about why xp_cmdshell is NOT the panic-attack many assume it to be, make sure to check on [link to CONVENTIONS - where Advanced Functionality is covered].]

[Return to Table of Contents](#table-of-contents)

### UPDATES
Keeping S4 up-to-date is simple - just grab and run the latest-release.sql file against your target server.

To Update S4: 
1. Grab the `latest-release.sql` S4 deployment script. By convention, the LATEST version of S4 will be available in the [\Deployment\ ](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) folder - and will be the only T-SQL file present (e.g., "5.6.2831.1.sql" - as per the screenshot below).

![](https://assets.overachiever.net/s4/images/install_update_latest_file.gif)

2. Execute this script (e.g., "5.6.2831.1.sql") against your target server.
3. The `latest-release.sql` script will deploy all of the latest and greatest S4 goodness. 
4. Upon completion, the update/deployment script will output information about all versions installed on your target server instance:

![](https://assets.overachiever.net/s4/images/install_update_completed.gif)

### Removing S4
To remove S4:
1. If you have enabled advanced capabilities (and WANT/NEED xp_cmdshell to be disabled as part of the cleanup process), you'll need to run the following code to disable them (please do this BEFORE DROP'ing the `[admindb]` database):   
```  
    EXEC admindb.dbo.disable_advanced_capabilities;  
    GO  
```

2. Review and disable any SQL Server Agent jobs that may be using S4 functionality or capabilities (automated database restore-tests, disk space checks/alerts, HA failover, etc.). 
3. Drop the `[admindb]` database: 
```
    USE [master];  
    GO   

    DROP DATABASE [admindb];  
    GO
```

4. Done. (If you want to re-install, simply re-run the original setup instructions.)

[Return to Table of Contents](#table-of-contents)

## FEATURES AND BENEFITS
The entire point of S4 is to simplify common DBA and other administrative tasks - by 'weaponizing' commonly-executed commands and operations into a set of standardized scripts. 

### Simplified and Robust Backups
S4 backup functionality streamlines the most-commonly used parts of the T-SQL BACKUP command into a simplified interface that provides simplified setup/management, enables easy automation (with high-context error details and alerts), and integration 'cleanup' or retention policies - all through a simplified interface. 

On a SQL Server with the following user databases: `[Billing]`, `[Customers]`, `[Products]`, `[Questionaires]`, and `[Widgets]`, 

S4 Backups will do the following: 
- Backup ALL of the databases listed above - excluding the `[Questionaires]` database.
- Ensure that the `[Widgets]` database is backed up first, and that `[Customers]` is last. 
- Only retain the last 2x days' (i.e., 48 hours') worth of FULL backups for the DBs indicated. 
```sql 
    EXEC admindb.dbo.backup_databases
        @BackupType = N'FULL',
        @Targets = N'{USER}', 
        @ExcludedDatabases = N'Questio%', 
        @Priorities = N'Widgets, *, Customers', 
        @BackupDirectory = N'D:\SQLBackups',
        @BackupRetention = N'2 days';
    GO
```

Similarly, the following command will ONLY execute DIFF backups of the `[Billing]` and `[Widgets]` databases - keeping only the last 2x backups issued locally - while pushing off-box copies of these same DIFF backups that will be kept for 48 hours: 
```sql 
    EXEC admindb.dbo.backup_databases
        @BackupType = N'DIFF',
        @Targets = N'Billing, Widgets',  
        @BackupDirectory = N'D:\SQLBackups',
        @CopyToDirectory = N'\\backup-server\SQLBackups'
        @BackupRetention = N'2 backups',   -- most recent 2x DIFF backups
        @CopyToRetention = N'2 days';
    GO
```

[For more information, see API documentation for dbo.backup_databases and be sure to check out best-practices and conventions info on blah blah blah.] 

### Simplified Restore Operations and Automated Restore-Testing
With a standardized convention defining how SQL Server Backups are stored (i.e., implemented via dbo.backup_databases), RESTORE operations become trivial. 

The following command will run FULL restore operations (FULL + DIFF (if present) and ALL T-LOGs avaialable) against all backups found in the @BackupsRootPath (e.g., D:\SQLBackups) for 'side-by-side' restore-verification tests (i.e., Billing will be restored as Billing_justChecking), run corruption checks, and then DROP each database (each database is processed serially) after testing and report on any problems or errors: 
```sql 
    EXEC admindb.dbo.restore_databases
        @DatabasesToRestore = N'{READ_FROM_FILE_SYSTEM}, -- treat each sub-folder as 'db'
        @BackupsRootPath = N'D:\SQLBackups', -- would find billing, customers, widgets, etc... 
        @RestoredRootDataPath = N'X:\TestDataSpace', 
        @RestoredLogDataPath = N'Y:\TestLogSpace', 
        @RestoredDbNamePattern = N'{0}_justChecking', 
        @SkipLogBackups = 0, 
        @CheckConsistency = 1, 
        @DropDatabasesAfterRestore = 1; -- don't 'run out of disk space'. 
    GO
```

Similarly, the following command could be used to REPLACE nightly dev/test databases - pulled from production and restored into DEV/QA - for use by developers as a staging sandbox: 
```
    EXEC admindb.dbo.dbo.restore_databases 
        @DatabasesToRestore = N'Billing, Customers, Widgets', 
        @Priorities = N'Widgets, Billing, Customers', 
        @BackupsRootPath = N'\\Prod-Backups-Server\SQLBackups', 
        @RestoredRootDataPath = N'D:\DevDatabases',
        @RestoredRootLogPath = N'D:\DevDatabases', 
        @SkipLogBackups = 0, 
        @CheckConsistency = 0, 
        @RestoredDbNamePattern = N'{0}_NightlyDevAndQACopy', 
        @AllowReplace = N'REPLACE',  -- WARNING: overwrites existing databases.
        @DropDatabasesAfterRestore = 0;  -- keep in place for use by devs... 
    GO
```

[For more info, see the explicit details for dbo.restore_databases and the best-practices guidelines and documentation for RESTOREs/etc.]

<div class="stub">### Listing Databases
[common to need lists of DBs to iterate over ... or to tackle - especially if/when need to remove certain kinds, define a priority/order/etc. ... all has been codified into a highly extensible sproc in the form of dbo.list_databases - which adheres to DB token-naming convention.]
</div>

### Performance Monitoring
S4 Includes a number of performance diagnostics that can be used in real-time to determine exactly what is using system resources and/or causing problems at a given moment. 

Examples include: 

- **dbo.list_processes:** Similar to a Linux 'Top' command - but for SQL Server, and with gobs of context and details about current resource consumers and potential problems.  
- **dbo.list_collisions:** Similar to dbo.list_processes - but ONLY includes sessions that are blocking or blocking - i.e., collisions. 
- **dbo.list_transactions:** Detailed information about in-flight transactions as they occur in real-time. 

### System Monitoring and Alerting
S4 includes a number of monitoring and alerting capabilities - to let administrators know about potential or looming problems. 

Examples include: 

- **dbo.verify_drivespace:** Define alerts to let you know when free space drops below arbitrary values that you define. 
- **dbo.monitor_transaction_durations:** Get notifications if/when long-running transactions are causing locking/blocking problems or exceeding duration thresholds that you define. 
- **dbo.verify_database_configurations:** Make sure that all datbases on your production system are configured for best-practices usage (i.e., no auto-shrink enabled, CHECKSUM only, and no down-level compat levels) and recieve alerts if/when specified or target databases change from defined norms and/or when new, non-compliant, databases are added. 

<div class="stub">
### HA Configuration, Monitoring, and Alerting

</div>

### S4 Utilities 
S4 was primarily built to facilitate the automation of backups, restores, and disaster recovery testing - but contains a number of utilities that can be used to make many typical administrative T-SQL Tasks easier. 
```sql
------------------------------------------------------------------------
-- dbo.count_matches
------------------------------------------------------------------------
-- count the number of times a space character is found:
SELECT admindb.dbo.[count_matches](N'There are five spaces in here.', N' ');  -- 5

-- or, determine the number of times the LEN() function exists in a sproc definition:
SELECT 
	admindb.dbo.[count_matches]([definition], N'LEN(')
FROM 
	admindb.sys.[sql_modules]
WHERE 
	[object_id] = OBJECT_ID('dbo.count_matches');

-- can also be used for evaluation/branching:
IF (SELECT admindb.dbo.count_matches(@someVariable, 'targetText') > 0) BEGIN 
    PRINT 'the string ''targetText'' _WAS_ found... '
END;

------------------------------------------------------------------------
-- dbo.print_long_string
------------------------------------------------------------------------
-- T-SQL's PRINT command truncates at 4000 characters - tedious if you're trying to see a longer string
EXEC admindb.dbo.print_long_string @nvarcharMaxWithLongerTextThatYouWantToPrintForWhateverReason;

------------------------------------------------------------------------
-- dbo.split_string
------------------------------------------------------------------------
-- perf-optimized string splits - that maintain 'order' and enable trim: 
SELECT admindb.dbo.split_string('this is the string to split', 'the', @trimValues);

------------------------------------------------------------------------
-- dbo.format_timespan
------------------------------------------------------------------------
-- easily convert Milliseconds (i.e., DATEDIFF(MILLISECOND, @start, @end) ) to human-readable timespans:
SELECT dbo.format_timespan(147894); -- 000:02:27.894;
```

<div class="stub">
### Security Diagnostics 

### Config 'dumps' etc... 
</div>

[Return to Table of Contents](#table-of-contents)

## APIs
The majority of S4 functionality is made accessible via a number of 'public' modules (sprocs and UDFs) that are designed to be used either in stand-along scenarios (e.g., BACKUPs or some forms or perf-monitoring), as re-usable logic/functionality that can easily be integrated into your own administrative routines and functions (like generating lists of specific types of databases, or as part of a QA/DEV provisioning process, etc.).

**NOTE:** *Not ALL S4 code has currently been documented. Specifically, 'internally used' and 'helper' code remains largely undocumented at this point.* 

### SQL Server Audit Signature Monitoring and Verification
Keep an eye on your audit specifications and definitions - by means of periodic checkups to verify that audit details and 'signatures' haven't changed: 

- **dbo.generate_audit_signature:** Generate a HASH that defines core details for a specified Audit.
- **dbo.generate_specification_signature:** Generate a HASH for audit specification details.
- **dbo.verify_audit_configuration:** Verify that previously generated HASH of audit matches CURRENT audit configuration.
- **dbo.verify_specification_configuration:** Verify that previously generated HASH of an audit specification matches the current/real-time HASH of the same audit specification.

### SQL Server Backups and Utilities

- **dbo.backup_databases:** Execute and easily automate backups. [Make sure to check Best Practices documentation on SQL Server Backups as well.]
- dbo.remove_backup_files: Helper function used by dbo.backup_databases to remove older/expired backups - but can be used 'manually' to cleanup older/expired backups as needed. 

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
- **dbo.restore_databases:** sdffsd
- **dbo.apply_logs:** dfwsfsd
- **dbo.copy_database:** Leverages S4's dbo.backup_database + dbo.restore_database to create a simple 'wrapper' that enables quick and easy 'copies' of databases to be created 'on the fly' - ideal for multi-tenant use/scenarios (as dbo.copy_database also kicks off a FULL backup as part of the 'copy' process).
- **dbo.list_recovery_metrics:** Each time dbo.restore_databases is run, it stores meta-data about restore times, included files (i.e., the name/size of each .bak + .trn included as part of the backup), corruption checks, and other metrics/statistics - which can be queried to get a quick and accurate sense of compliance with SLAs.

### Tools And Utilities
- **dbo.extract_statement:** sdflksdflksd 
- **dbo.extract_waitresource:** sdfsdf
- **dbo.is_xml_empty:** Detecting 'empty' is harder than you might initially think. It's not rocket-surgery, but it does warrant some easily re-usable logic to make detection easier.
- **dbo.normalize_text:** Parameterize or normalize T-SQL text/statements.
- **dbo.print_long_string:** Bypass the 4000 char limit of PRINT to 'spit out' long text. 
- **dbo.count_matches:** Returns the number of times a target-text appears in a larger text. 
- **dbo.kill_connections_by_hostname:** For misbehaving or problematic hosts. 
- **dbo.shred_string:** Allows multi-dimension 'string splits' - i.e., not just splitting into rows, but with columns also. 
- **dbo.shred_string_to_xml:** As above, but outputs into XML - to help allow hacks/bypasses of Nested Insert EXEC problems. 


[Return to Table of Contents](#table-of-contents)

## USING S4 Conventions
[intro about conventions and then.... lists of conventions goes here... ]

<div class="stub" meta="this is content 'pulled' from setup - that now belongs in CONVENTIONS - because advanced error handling is a major convention">[LINK to CONVENTIONS about how S4 doesn't want to just 'try' things and throw up hands if/when there's an error. it strives for caller-inform. So that troubleshooting is easy and natural - as DBAs/admins will have immediate access to specific exceptions and errors - without having to spend tons of time debugging and so on... ]

#### TRY / CATCH Fails to Catch All Exceptions in SQL Server
[demonstrate this by means of an example - e.g., backup to a drive that doesn't exist... and try/catch... then show the output... of F5/execution.]

[To get around this, have to enable xp_cmdshell - to let us 'shell out' to the SQL Server's own shell and run sqlcmd with the command we want to run... so that we can capture all output/details as needed.] 

[example of dbo.execute_command (same backup statement as above - but passed in as a command) - and show the output - i.e., we TRAPPED the error (with full details).]

[NOTE about how all of this is ... yeah, a pain, but there's no other way. Then... xp_cmdshell is native SQL Server and just fine.]


For more detailed information, see [Notes about xp_cmdshell](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2Fxp_cmdshell_notes.md)</div>


[Return to Table of Contents](#table-of-contents)

## S4 BEST PRACTICES
A key goal of S4 is to enable best-practices execution in 'weaponized' form - or best-practices implementations in codified, easy-to-use, re-usable, code or modules. 
  
That said, [lots of complex things 'wrapped up' and made easy - meaning that there's some background info and context/understanding that should be in place before/when-using S4 in a production environment. To that end, best practices are effectively like 'essays' outlining SQL Server best practices for key/critical concerns - but adapted to and explicitly for implementation via S4 functionality and with an S4 'flavor' or spin.]

<div class="stub">[make sure that HA docs/links have a reference to these two sites/doc-sources: 

- [SQL Server Biz Continuity](https://docs.microsoft.com/en-us/sql/database-engine/sql-server-business-continuity-dr?view=sql-server-2017)

- [Windows Server Failover Clustering DOCS](https://docs.microsoft.com/en-us/windows-server/failover-clustering/failover-clustering-overview)

]</div>

[Return to Table of Contents](#table-of-contents)
<style>
    div.stub { display: none; }
</style>