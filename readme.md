![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

# S4 - Simple SQL Server Scripts    

## Table of Contents
- [License](#license)
- [Change Log](/changelog.md)
- [Installing S4](#installing-s4)
    - [Step-by-Step Installation Instructions and FAQs](/documenation/setup.md#step-by-step-installation-instructions)
    - [Enabling Advanced S4 Features](/documenation/setup.md#enabling-advanced-S4-features) 
    - [Common Questions and Concerns about enabling xp_cmdshell](/documenation/setup.md#common-questions-and-concerns-about-enabling-xp_cmdshell)
    - [Keeping S4 Updated](/documenation/setup.md#updating-S4)
    - [Removing S4](/documenation/setup.md#removing-S4)
- [S4 Features and Benefits](#features-and-benefits)
    - [Simplified and Robust Backups](#simplified-and-robust-backups) 
    - [Automated RESTORE Tests](#simplified-restore-operations-and-automated-restore-testing)
    - [Simplfied Disaster Recovery](#simplified-disaster-recovery)
    - [Performance Monitoring](#performance-monitoring-and-workload-insights)
    - [Capacity Planning Resources](#capacity-planning-resources)
    - [S4 Utilities](#utilities)
    - [Tools and Templates](#tools-and-templates)
- [Best-Practices Guidance and Documentation](#best-practices-guidance-and-documentation)
- [APIs](#apis)
    - [SQL Server BACKUPs and Utilities](/documentation/apis.md#sql-server-backups-and-utilities)
    - [SQL Server Configuration Utilities](/documentation/apis.md#sql-server-configuration-utilities)
    - [High Availability Configuration, Monitoring, and Management](/documentation/apis.md#high-availability-configuration,-monitoring,-and-management)
    - [SQL Server Agent Jobs](/documentation/apis.md#sql-server-agent-jobs)
    - [SQL Server Maintenance](/documentation/apis.md#sql-server-maintenance)
    - [Monitoring](/documentation/apis.md#monitoring)
    - [Performance](/documentation/apis.md#performance)
    - [RESTORE Operations and Utilities](/documentation/apis.md#restore-operations-and-utilities)
    - [Tools and Utilities](/documentation/apis.md#tools-and-utilities) 
    - [SQL Server Audit Signature Monitoring and Verification](/documentation/apis.md#sql-server-audit-signature-monitoring-and-verification)
- [S4 Conventions](#s4-conventions)

> ### :label: **NOTE:** 
> S4 documentation is a work in progress. Any content *[surrounded by square brackets]* represents a DRAFT version of documentation.

## License 

[MIT LICENSE](/LICENSE)

## Change Log

[ChangeLog](#/changelog.md)

## Installing S4

### Simplified Installation
1. Grab the `admindb_latest.sql` file from the [S4 releases directory](https://github.com/overachiever-productions/s4/releases/latest) 
2. Run or execute `admindb_latest.sql` against your environment (you'll need SysAdmin permissions - and executing `admindb_latest.sql` will create a new database, the `admindb`.)
3. Many of the [key benefits or features of S4](#features-and-benefits) require that you enable advanced-error-handling-functionality (which is facilitated largely by enabling [xp_cmdshell](/documentation/notes/xp_cmdshell.md)). Once you've installed/deployed S4 into your environment, you can enable advanced functionality by running the following command: 

```sql****
    EXEC admindb.dbo.enable_advanced_capabilities;
    GO
```
4. Additionally, many advanced S4 capabilities that relate to automating SQL Server tasks and operations (backups, restore-tests, and other types of maintenance) require access to SQL Server [Database Mail profiles and operators](/documentation/notes/database_mail.md) to ensure that any probelms or issues encountered during execution are correctly surfaced (rather than allowing silent failures). Defining which Database Mail Profiles and SQL Server Agent Operators to use for these routines can either be done in one-off (per execution/call) fashion, or these details can be set (or defaulted) at server-level means by means of configuration and/or convention.

### Additional Installation, Update, and Removal Topics
- [Step-by-Step Installation Instructions and FAQs](/documenation/setup.md#step-by-step-installation-instructions)
- [Enabling Advanced S4 Features](/documenation/setup.md#enabling-advanced-S4-features) 
- [Common Questions and Concerns about enabling xp_cmdshell](/documenation/setup.md#common-questions-and-concerns-about-enabling-xp_cmdshell)
- [Keeping S4 Updated](/documenation/setup.md#updating-S4)
- [Removing S4](/documenation/setup.md#removing-S4)
- [Installation via PowerShell](/documenation/setup.md#installation-via-powershell)

[Return to Table of Contents](#table-of-contents)

## Features and Benefits
S4 simplifies DBA and other administrative tasks by 'weaponizing' commonly-needed operations into a set of standardized scripts and tooling. 

### Simplified and Robust Backups 
S4 backup functionality streamlines the most-commonly used parts of the T-SQL BACKUP command into a simplified interface that provides simplified setup/management, enables easy automation (with high-context error details and alerts), and integration 'cleanup' or retention policies - all through a simplified interface. 

On a SQL Server with the following user databases: `[Billing]`, `[Customers]`, `[Products]`, `[Questionaires]`, and `[Widgets]`, 

The following call to S4 Backups will do the following: 
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

Similarly, the following command will ONLY execute DIFF backups of the `[Billing]` and `[Widgets]` databases - keeping only the last 2x backups issued locally - while pushing off-box copies of these same DIFF backups that will be kept for 96 hours: 
```sql 
    EXEC admindb.dbo.backup_databases
        @BackupType = N'DIFF',
        @Targets = N'Billing, Widgets',  
        @BackupDirectory = N'D:\SQLBackups',
        @CopyToDirectory = N'\\backup-server\SQLBackups',  
        @BackupRetention = N'2 backups',   -- most recent 2x DIFF backups
        @CopyToRetention = N'4 days';
    GO
```

For more information, see API documentation for [dbo.backup_databases](/documentation/apis/backup-databases.md) and be sure to check out  [S4's documented best-practices for BACKUPS](/documentation/best-practices/backups.md) as well. 

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

For more info, see API documentation for [dbo.restore_databases](/documentation/apis/restore-databases.md) and be sture to checkout  [S4's documented best-practices for RESTORE operations](/documentation/best-practices/restores.md) as well.  

### Simplified Disaster Recovery
As tooling designed for DBAs, S4 focuses heavily on Disaster Recovery - both in terms of the necessary tools, techniques, and best-practices to help detect and alert for disasters as they unfold and in terms of tools designed to provide best-of-breed capabilities for responding to disasters when they occur. 

For more information, see [Best Practices documentation for Leveraging S4 to help with Disaster Recovery](/documentation/best-practices/disaster_recovery.md)

### Performance Monitoring and Workload Insights 
S4 Includes a number of performance diagnostics that can be used in real-time to determine exactly what is using system resources and/or causing problems at a given moment. 

Examples include: 

- **[dbo.list_processes](/documentation/apis/list_processes.md):** Similar to a Linux 'Top' command - but for SQL Server, and with gobs of context and details about current resource consumers and potential problems.  
- **[dbo.list_collisions](/documentation/apis/list_collisions.md):** Similar to dbo.list_processes - but ONLY includes sessions that are blocking or blocking - i.e., collisions. 
- **[dbo.list_transactions](/documentation/apis/list_transactions.md):** Detailed information about in-flight transactions as they occur in real-time. 

### System Monitoring and Alerting
S4 includes a number of monitoring and alerting capabilities - to let administrators know about potential or looming problems. 

Examples include: 

- **dbo.verify_drivespace:** Define alerts to let you know when free space drops below arbitrary values that you define. 
- **dbo.monitor_transaction_durations:** Get notifications if/when long-running transactions are causing locking/blocking problems or exceeding duration thresholds that you define. 
- **dbo.verify_database_configurations:** Make sure that all datbases on your production system are configured for best-practices usage (i.e., no auto-shrink enabled, CHECKSUM only, and no down-level compat levels) and recieve alerts if/when specified or target databases change from defined norms and/or when new, non-compliant, databases are added. 

### HA Configuration, Monitoring, and Alerting
*[Section/Documentation Pending. However, see [High Availability Configuration, Monitoring, and Management](/documentation/apis.md#high-availability-configuration,-monitoring,-and-management) APIs documentation for more insights on what's available.]*

### Capacity Planning Resources 
[Documentation Pending.]

### Utilities
S4 was primarily built to facilitate the automation of backups, restores, and disaster recovery testing - but contains a number of utilities that can be used to make many typical administrative T-SQL Tasks easier. 

#### String Manipulation Utilities
For example, a simple helper function to count the number of times a specific string of text occurs in a larger/target string:
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
```

And, of course, no library would be complete without a string_split() function: 
```sql
------------------------------------------------------------------------
-- dbo.split_string
------------------------------------------------------------------------
-- perf-optimized string splits - that maintain 'order' and enable trimming of white space: 
SELECT admindb.dbo.split_string('this is the string     to split', 'the', 1);

```


Another, trivial, helper function provides the ability to print the ENTIRETY of strings longer than 4K bytes in size (helpful when debugging dynamic SQL or other 'blobs' of text):

```sql
------------------------------------------------------------------------
-- dbo.print_long_string
------------------------------------------------------------------------
-- T-SQL's PRINT command truncates at 4000 characters - tedious if you're trying to see a longer string
EXEC admindb.dbo.print_long_string
    @nvarcharMaxWithLongerTextThatYouWantToPrintForWhateverReason;

```

Or the ability to format timespans - via milliseconds:

```sql 
------------------------------------------------------------------------
-- dbo.format_timespan
------------------------------------------------------------------------
-- easily convert Milliseconds (i.e., DATEDIFF(MILLISECOND, @start, @end) ) to human-readable timespans:
SELECT dbo.format_timespan(147894); -- 000:02:27.894;
```

#### Security and Management Utilities
Ever been burned by how SSMS does a terrible job of scripting logins? (It bypasses the password and doesn't even BOTHER with the SID.) 

S4's `script_login` routine provides a clean and easy way to script both SQL and Windows Logins - providing the option to specify what kind of syntax to generate for 'if-checks' or evaluations to execute on the target server. 


```sql 
------------------------------------------------------------------------
-- dbo.script_login
------------------------------------------------------------------------
EXEC admindb.dbo.script_login
    @LoginName = N'WebApp-Login', 
    @BehaviorIfExists = N'CREATE_AND_DROP';

```

For example, the output of the command above is as follows: 

```sql

IF NOT EXISTS (SELECT NULL FROM [master].[sys].[server_principals] WHERE [name] = 'WebApp-Login') BEGIN 
    CREATE LOGIN [WebApp-Login] WITH 
	 	PASSWORD = 0x020092F37399BEAB41CA530245ADDEA17A25F03D4AC5640D8347D0FEA9A1ADB3F38844A46C2F52C70BE6554126A1641B2562A42D3CDD4DE206B8C670A8A838717E835A2814DF HASHED
	 ,SID = 0x700D2F2541B1A04DA69A7EAA70649D1C
	 ,DEFAULT_DATABASE = [master]
	 ,CHECK_EXPIRATION = OFF
	 ,CHECK_POLICY = OFF;  
  END;
ELSE BEGIN
 	DROP LOGIN [WebApp-Login];

	CREATE LOGIN [WebApp-Login] WITH  
	 	PASSWORD = 0x020092F37399BEAB41CA530245ADDEA17A25F03D4AC5640D8347D0FEA9A1ADB3F38844A46C2F52C70BE6554126A1641B2562A42D3CDD4DE206B8C670A8A838717E835A2814DF HASHED
	 ,SID = 0x700D2F2541B1A04DA69A7EAA70649D1C
	 ,DEFAULT_DATABASE = [master]
	 ,CHECK_EXPIRATION = OFF
	 ,CHECK_POLICY = OFF; 
END;

```

Where the @BehaviorIfLoginExists of `DROP_AND_CREATE` generates IF-CHECKS that will drop/recreate the login if it's found on the target server (vs the options of `ALTER` and `NONE` (no IF-checks)). 

Further, S4's `dbo.script_logins` can be easily used to dump/export (output) ALL logins within a given database - or all logins on a server via syntax that makes it easy to specify which Databases to target and exclude and/or which logins/users to exclude as well: 

```sql

EXEC admindb.dbo.[script_logins]
	@TargetDatabases = N'{USER}',  -- target all USER dbs.
	@ExcludedDatabases = N'Billing',
	@ExcludedLogins = N'sa',
	@ExcludedUsers = N'DEV\web-app',
	@ExcludeMSAndServiceLogins = 1,
	@BehaviorIfLoginExists = N'ALTER',
	@DisablePolicyChecks = 1,
	@DisableExpiryChecks = 1,
	@ForceMasterAsDefaultDB = 1;
	
```

### Security Diagnostics
[Documentation Pending.]

### Configuration Scripting and Backups 
[Documentation Pending.]

### Tools and Templates 
[Documentation Pending.]

[Return to Table of Contents](#table-of-contents)

## Best-Practices Guidance and Documentation
A key goal of S4 is to enable best-practices execution in 'weaponized' form - or best-practices implementations in codified, easy-to-use, re-usable, code or modules. 
  
That said, [lots of complex things 'wrapped up' and made easy - meaning that there's some background info and context/understanding that should be in place before/when-using S4 in a production environment. To that end, best practices are effectively like 'essays' outlining SQL Server best practices for key/critical concerns - but adapted to and explicitly for implementation via S4 functionality and with an S4 'flavor' or spin.]

- [Best-Practices Documenation](/documenation/best-practices.md)

[Return to Table of Contents](#table-of-contents)

## APIs
The majority of S4 functionality is made accessible via a number of 'public' modules (sprocs and UDFs) that are designed to be used either in stand-along scenarios (e.g., BACKUPs or some forms or perf-monitoring), as re-usable logic/functionality that can easily be integrated into your own administrative routines and functions (like generating lists of specific types of databases, or as part of a QA/DEV provisioning process, etc.).

For specific details, see the following: 
- [SQL Server Audit Signature Monitoring and Verification](/documentation/apis.md#sql-server-audit-signature-monitoring-and-verification)
- [SQL Server BACKUPs and Utilities](/documentation/apis.md#sql-server-backups-and-utilities)
- [SQL Server Configuration Utilities](/documentation/apis.md#sql-server-configuration-utilities)
- [High Availability Configuration, Monitoring, and Management](/documentation/apis.md#high-availability-configuration,-monitoring,-and-management)
- [SQL Server Agent Jobs](/documentation/apis.md#sql-server-agent-jobs)
- [SQL Server Maintenance](/documentation/apis.md#sql-server-maintenance)
- [Monitoring](/documentation/apis.md#monitoring)
- [Performance](/documentation/apis.md#performance)
- [RESTORE Operations and Utilities](/documentation/apis.md#restore-operations-and-utilities)
- [Tools and Utilities](/documentation/apis.md#tools-and-utilities) 

[Return to Table of Contents](#table-of-contents)

## S4 Conventions
S4 favors [convention over configuration](https://en.wikipedia.org/wiki/Convention_over_configuration) - or the notion of 'sensible' defaults. This allows for S4 to be as simple and easy as possible to use (out of the box), while still allowing it to address customized or specialized scenarios and needs. 

To accomodate `convention over configuration` as well as to address other common problems and scenarios, S4 explicitly defines and uses the fullowing conventions:

- [S4 Conventions](/documentation/conventions.md)

[Return to Table of Contents](#table-of-contents)