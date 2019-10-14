# S4

<span style="font-size: 26px">**S**imple **S**QL **S**erver **S**cripts -> **S4**</span>

## TABLE OF CONTENTS
  
> ### <i class="fa fa-random"></i> Work in Progress  
> S4 documentation is a work in progress. Any content [surrounded by square brackets] represents a DRAFT version of documentation.

- [License](#license)
- [Requirements](#requirements)
- [Setup](#setup)
    - [Step By Step Installation Instructions](#step-by-step-installation)
    - [Enabling Advanced S4 Features](#enabling-advanced-s4-features)
    - [Updating S4](#updates)
    - [Removing S4](#removing)
- [S4 Features and Benefits](#features-and-benefits)
    - [S4 BACKUPs](#simplified-and-robust-backups) 
    - [Automated RESTORE Tests](#simplified-restore-operations-and-automated-restore-testing)
    - [Performance Monitoring](#performance-monitoring)
    - [S4 Utilities](#utilities)
- [APIs](#apis)
- [S4 Conventions](#s4-conventions)
    - [Backup Conventions](#backup-conventions)
    - [Database Name Tokens](database-name-tokens)
    - [Alerting](#alerting-conventions)
- [S4 Best Practices](#s4-best-practices)

## License

[MIT LICENSE](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=master&encodedPath=LICENSE)

## Requirements
**SQL Server Requirements:**

- SQL Server 2012+. *(MOST (but not all) S4 functionality ALSO works with SQL Server 2008 / SQL Server 2008 R2.)* 
- Some advanced functionality does not work on Express and/or Web Versions of SQL Server.
- Windows Server Only. (Not yet tested on Azure/Linux.)

**Setup Requirements:**
- To deploy, you'll need the ability to run T-SQL scripts against your server and create a database.
- Advanced error handling (for backups and other automation) requires xp_cmdshell to be enabled - as per the steps outlined in [Enabling Advanced S4 Features](#enabling-advanced-s4-features).
- SMTP (SQL Server Database Mail) for advanced S4 automation and alerts.

## SETUP 
**Setup is trivial:** run a [T-SQL script ](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) "e.g.7.0.3042.sql" against your target server and S4 will create a new `[admindb]` database - as the new home for all S4 code and functionality.  

Advanced S4 automation and error handling requires a server-level change - which has to be explicitly enabled via the step outlined in [Enabling Advanced S4 Features](#enabling-advanced-s4-features). 

Once deployed, it's easy to [keep S4 updated](#updates) - just grab new releases of the deployment file, and run them against your target server (where they'll see your exising deployment and update code as needed).

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
Meh. There's a lot of [FUD](https://en.wikipedia.org/wiki/Fear,_uncertainty_and_doubt) out there about enabling xp_cmdshell on your SQL Server. *Security is NEVER something to take lightly, but xp_cmdshell isn't a security concern* - running a SQL Server with ELEVATED PERMISSIONS is a security concern. xp_cmdshell merely allows the SQL Server Service account to interact with the OS much EASIER than would otherwise be possible without xp_cmdshell enabled. 

To checkup-on/view current S4 advanced functionality and configuration settings, run the following: 

```sql
    EXEC dbo.verifiy_advanced_capabilities;
    GO
```

**Note that S4 ships with Advanced Capabilities DISABLED by default.**

[For more information on WHY xp_cmdshell makes lots of sense to use for 'advanced' capabilities AND to learn more about why xp_cmdshell is NOT the panic-attack many assume it to be, make sure to check on [link to CONVENTIONS - where Advanced Functionality is covered].]

[Return to Table of Contents](#table-of-contents)

### UPDATES
Keeping S4 up-to-date is simple - just grab and run the `latest-release.sql` file against your target server.

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

4. Done. 

(If you want to re-install, simply re-run the original setup instructions.)

[Return to Table of Contents](#table-of-contents)

## FEATURES AND BENEFITS
The entire point of S4 is to simplify common DBA and other administrative tasks - by 'weaponizing' commonly-needed operations into a set of standardized scripts. 

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
        @CopyToDirectory = N'\\backup-server\SQLBackups',  
        @BackupRetention = N'2 backups',   -- most recent 2x DIFF backups
        @CopyToRetention = N'2 days';
    GO
```

For more information, see API documentation for [dbo.backup_databases](?encodedPath=Documentation%2Fapis%2Fbackup_databases.md) and be sure to check out documented [best-practices for BACKUPS](?encodedPath=Documentation%2Fbest-practices%2FBACKUPS.md) as well. 

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

For more info, see API documentation for [dbo.restore_databases](?encodedPath=Documentation%2Fapis%2restore_databases.md) and be sture to checkout documented [best-practices for RESTORE operations](?encodedPath=Documentation%2Fbest-practices%2FBACKUPs.md) as well.

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
- x
- y
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

For specific details, see the following: 
- [SQL Server Audit Signature Monitoring and Verification](?encodedPath=Documentation%2FAPIS.md#sql-server-audit-signature-monitoring-and-verification)
- [SQL Server BACKUPs and Utilities](?encodedPath=Documentation%2FAPIS.md#sql-server-backups-and-utilities)
- [SQL Server Configuration Utilities](?encodedPath=Documentation%2FAPIS.md#sql-server-configuration-utilities)
- [High Availability Configuration, Monitoring, and Management](?encodedPath=Documentation%2FAPIS.md#high-availability-configuration,-monitoring,-and-management)
- [SQL Server Agent Jobs](?encodedPath=Documentation%2FAPIS.md#sql-server-agent-jobs)
- [SQL Server Maintenance](?encodedPath=Documentation%2FAPIS.md#sql-server-maintenance)
- [Monitoring](?encodedPath=Documentation%2FAPIS.md#monitoring)
- [Performance](?encodedPath=Documentation%2FAPIS.md#performance)
- [RESTORE Operations and Utilities](?encodedPath=Documentation%2FAPIS.md#restore-operations-and-utilities)
- [Tools and Utilities](?encodedPath=Documentation%2FAPIS.md#tools-and-utilities)   

[Return to Table of Contents](#table-of-contents)

## USING S4 Conventions
S4 favors convention over configuration. [TODO: find a link that does a good job of explaining what this means i.e., it attempts to address the most commonly-used and most-commonly needed configuration options and 'choices' by means of standardized/conventionalized defaults - yet, still allows customization (explicit configuration) of key or core configuration choices.]

[To accomodate conventions based on standards/etc. as well as address a few internal paradigms/problem-solving-somethings, S4 explicitly defines and uses the following conventions - which are key to understand and be familiar with if/when using them as production management tools.] 
[NOTE: this'll be a TOC, but it'll link out to the CONVENTIONS.md page which'll cover as many of these conventions as needed in that .md and if/when a convention is more 'complex'... that convention will get its own .md page for further clarification/context.]

- [S4 Conventions 'Home Page'](?encodedPath=Documentation%2FCONVENTIONS.md)

[Return to Table of Contents](#table-of-contents)

## S4 BEST PRACTICES
A key goal of S4 is to enable best-practices execution in 'weaponized' form - or best-practices implementations in codified, easy-to-use, re-usable, code or modules. 
  
That said, [lots of complex things 'wrapped up' and made easy - meaning that there's some background info and context/understanding that should be in place before/when-using S4 in a production environment. To that end, best practices are effectively like 'essays' outlining SQL Server best practices for key/critical concerns - but adapted to and explicitly for implementation via S4 functionality and with an S4 'flavor' or spin.]

- [Best-Practices 'Home Page'](&encodedPath=Documentation%2FBESTPRACTICES.md)


[Return to Table of Contents](#table-of-contents)

<style>
    div.stub { display: none; }
</style>