# S4 Restore
S4 Restore was designed to provide:
- **Simplicity**. Streamlines the non-trivial process of testing backups (by restoring them) through a set of simplified commands and operations that remove the tedium and complexity from restore operations - while still facilitating best-practices for testing and recovery purposes.
- Streamline the non-trivial process of verifying backups - by restoring them through a streamlined and simplified set of commands
- **Recovery**. While S4 Restore was primarily designed for regular (automated) testing of backups, it can be used for disaster recovery purposes to restore backups to the most recent recovery point available by walking through FULL + DIFF + TLOG backups and applying the most recent backups of all applicable backup files available. 
- **Transparency**. Use of (low-level) error-handling to log problems into a centralized logging table (for trend-analysis and improved trouble-shooting) and send email alerts with concise details about each failure or problem encountered during execution so that DBAs can quickly ascertain the impact and severity of problems without having to wade through messy 'debugging' and troubleshooting.

## <a name="toc"></a>Table of Contents
- [Benefits of S4 Restore](#benefits)
- [Intended Usage Scenarios](#scenarios)
- [Supported SQL Server Versions](#supported)
- [Deployment](#deployment)
- [Syntax](#syntax)
- [Remarks](#remarks)
- [Examples](#examples)

## <a name="benefits"></a>Benefits of S4 Restore
Key Benefits provided by S4 Restore:
- **Simplicity, Recovery, and Transparency.** Commonly needed features and capabilities for restoring SQL Server backups - with none of the hassles or headaches. 
- **Peace of Mind.** The only real way to know if backups are viable is to restore them. S4 Restore removes the mystery by making it easy to regularly restore (i.e., test) backups of critical SQL Server databases.
- **Automation.** Easily Automate Execution of S4 Restore commands to set up regular (nightly) restore tests for continued, ongoing protection and coverage. 
- **Instrumentation.**  After setting up regular restore-check jobs, you can easily query metrics about the duration for restore operations (and consistency checks) for trend-analysis and to help ensure RTO compliance.
- **Portability.** Easy setup and configuration - with no dependency on 'outside' resources (other than access to your backup files), S4 is easy to deploy and use pretty much anywhere.

[Return to Table of Contents](#toc)

## <a name="scenarios"></a>Intended Usage Scenarios

S4 Restore was primarily designed for use in the following automated and ad-hoc scenarios. 
- **Regular On-Box Tests.** For smaller organizations with just one SQL Server, validation of will take place on the same SQL Server as where the backups are taken. To this end, S4 Restore was designed to restore one database at a time (i.e., when more than one database is specified for verification), check it for consistency, log statistics about the duration/outcome of both operations, and then DROP the restored database before proceeding to the next database to test - to avoid running out of disk-space. Likewise, in this situation, if you have a database called "WidgetsProd", S4 Restore enables you to assign a 'suffix' to the name of the database you're restoring (i.e., "_test" - so that you'll restore "WidgetsProd" as "WidgetsProd_test") to avoid any potential concerns with collisions. 
- **Regular Off-Box Tests.** In more complicated environments, backups can/will be created on one server, copied off-box to a shared location (or a location in the cloud), and restore testing can be tackled on a totally unrelated server that is 'linked' to the 'source' server merely by having copies of the backups of the databases from that server - which can be regularly scheduled for testing/restores. In situations like this, it also makes sense to configure S4 to 'drop' databases after restoring them - so that restore tests the next time they're run (i.e., the next day) don't 'collide' with databases 'left behind' after testing. Under this use-case, it's typically not necessary to add a 'suffix' to restored database names (i.e., the "WidgetsProd" database backed up on SERVERA can easily be restored to CLOUDX without any worries about name/database collisions).
- **Regular Development Environment Refreshment.** If developers need to have regularly refreshed copies of production database put into a location where they can then use them throughout the day for dev/testing purposes, S4 Restore is best used with a special, advanced, configuration option that lets it REPLACE existing databases during restore operations. For example, the first time the "WidgetsProd" database is restored to a DEV server it can be restored as "WidgetsProd" (or with a suffix as "WidgetsProd_Nightly" - or whatever else makes sense) and is NOT dropped after restoration (and consistency checks if configured). Instead, the database 'stays around' and is usable by devs until the next time an S4 Restore operation is executed (i.e., each night at, say, 2AM) - at which point the DEV 'copy' of prod is OVERWRITTEN/REPLACED with a fresh copy of the database from PROD. (NOTE, many devs like to keep their dev/working environments a bit 'stale' - or refreshed every few days/weeks/whatever. A BETTER approach, however, is to FORCE a restore of the 'dev' database nightly (from production), which requires developers to keep track of any changes they're working on (over, say, the period of a few days while they're making changes or adding new features) within scripts that they will then run 'each day' against the new/refreshed copy of their dev database - to bring that database 'up to speed' with their changes. Benefits from this approach are that devs have to keep track of all changes, they're re-testing them daily (and will detect any collisions with changes OTHER devs may have pushed into production), really long-running changes are something they're likely to look into changing sooner rather than later (i.e., performance optimizations), and dev changes that get 'put on hold' for weeks on end are easier to both 'pick up' (thanks to 'change scripts') when needed AND deployment is easier because something that a developer changed 3 weeks ago doesn't get 'missed' when deployment of their changes to production are ready.)
- **Smoke and Rubble Disaster Recovery.** S4 Restore can be used for 'smoke and rubble' disaster recovery purposes. Which is to say, if you've got (hopefully up-to-date) off-site copies of your production database backups, you can simply 'point' S4 Restore at the folder containing the backups for one or more databases (each of which needs to be in its own sub-folder - by convention), provide a few parameters, and then let S4 Restore spin-up copies of each specified database as a means of automating the disaster recovery restoration process on new/different hardware from your primary server(s). 
- **Ad-Hoc Restore Operations.** S4 Restore can also be used to quickly 'spin up' the restoration of specified databases for 'quick' recovery or review purposes - or it can also be used as a tool to generate the scripts that would be used to restore a targeted database (or databases) - and then, rather than having S4 execute the commands itself, it will 'spit them out' for you to copy, paste, tweak and execute as desired.

[Return to Table of Contents](#toc)

## <a name="supported"></a>Supported SQL Server Versions
**S4 Restore was designed to work with SQL Server 2008 and above.** 

S4 Restore will work on all stand-alone versions of SQL Server (i.e., it won't work on SQL Azure, or Amazon RDS instances) greater than SQL Sever 2008. Currently, it is not configured to work on SQL Express Editions (due to the fact that dba_RestoreDatabases will check-for and attempt to validate Database Mail and OperatorName + MailProfile parameters before execution - and will attempt to send emails upon encountering problems - none of which is supported by SQL Server Express.)

Currently, S4 Backups is only supported on SQL Server Versions and Editions (sans SQL Server Express Editions) running on Windows (Linux is not yet supported).

[Return to Table of Contents](#toc)


## <a name="deployment"></a>Deployment
To deploy S4 Restore into your environment:
- You will need to enable xp_cmdshell if it isn't already enabled. (See below for more information.)
- You will aso need to have configured Database Mail, enabled the SQL Server Agent to use Database Mail for notifications, and have created a SQL Server Agent Operator. (See below for more information.)
- From the **S4 'common'** folder, locate and then open + execute dba_ExecuteAnFilterNonCatchableCommand.sql against your target server.
- From the **S4 'common'** folder, locate and then open + execute dba_CheckPaths.sql against your target server. 
- From the **S4 'Common'** folder, locate and then open + execute dba_SplitString.sql against your target server.
- From the **S4 'Common'** folder, locate and then open + execute dba_LoadDatabaseNames against your target server.
- From the **S4 Restore** folder, locate and then open + execute the 0. dba_DatabaseRestore_Log.sql script against your target server. 
- From the **S4 Restore** folder, locate and then open + execute the 1. dba_RestoreDatabases.sql script against your target server. 

Once you're completed the steps above, everything you need will be deployed and ready for use.

### Notes on xp_cmdshell

There's a lot of false information online about the use of xp_cmdshell. However, while enabling xp_cmdshell for anyone OUTSIDE of the SysAdmin fixed server-role WOULD be a bad idea, this both semi-difficult to do (i.e., it takes some explicit steps), and is NOT what is required for S4 backups to execute. Instead, S4 Backups simply need xp_cmdshell enabled for SysAdmins - which will give Admins (or SQL Server Agent jobs running with elevated permissions), the ability to, effectively, open up a command-shell on the host SQL Server and execute commands against that shell WITH the permissions granted to your SQL Server Engine/Service. Or, in other words, xp_cmdshell allows SysAdmins to run arbitrary Windows commands (in effect giving them a 'DOS prompt') with whatever permissions are afforded to the SQL Server Service itself. When configured securely and correctly, the number of permissions available to a SQL Server Service are VERY limited by default - and are typically restricted to folders explicitly defined during setup or initial configuration (i.e., SQL Server will obviously need permissions to access the Program Files\SQL Server\ directory, the folders for data and log files, and any folders you've defined for SQL Server to use as backups; further, if you're pushing backups off-box (which you should be doing), you'll need to be using a least-privilege Domain Account - which will need to be granted read/write permissions against your targeted network shares for SQL Server backups). 

In short, the worst that a SysAdmin can do with xp_cmdshell enabled is... the same they could do without it enabled (i.e., they could drop/destroy all of your databases and backups (if they are so inclined to do or if they're careless and their access to the server is somehow compromised) - but there is NO elevation of privilege that comes from having xp_cmdshell enabled - period. 

To check to see if xp_cmdshell is enabled, run the following against your server: 

```sql
-- 1 = enabled, 0 = not-enabled:
SELECT name, value_in_use FROM sys.configurations WHERE name = 'xp_cmdshell';
```

If it's not enabled, you'll then need to see if advanced configuration options are enabled or not (as 'flipping' xp_cmdshell on/off is an advanced configuration option). To do this, run the following against your server: 

```sql
-- 1 = enabled, 0 = not-enabled:
SELECT name, value_in_use FROM sys.configurations WHERE name = 'show advanced options';
```

If you need to enable advanced configuration options, run the following:

```sql
USE master;
GO

EXEC sp_configure 'show advanced options', 1;
GO
```

Once you execute the command above, SQL Server will notify you that the command succeeded, but that you need to run a RECONFIGURE command before the change will be applied. To force SQL Server to re-read configuration information, run the following command: 

```sql
RECONFIGURE;
```

**WARNING:** While the configuration options specified in these setup docs will NOT cause a dump of your plan cache, OTHER configuration changes can/will force a dump of your plan cache (which can cause MAJOR performance issues and problems on heavily used servers). As such:
- Be careful with the use of RECONFIGURE (i.e., don't ever treat it lightly). 
- If you're 100% confident that no OTHER changes to the server's configuration are PENDING a RECONFIGURE command, go ahead and run reconfigure as needed to complete setup. 
- If there's any doubt and you're on a busy system, wait until non-peak hours before running a RECONFIGURE command.

To check if there are any changes pending on your server, you can run the following (and if the only configuration setting listed is for xp_cmdshell, then you can run RECONFIGURE without any worries):

```sql
-- note that 'min server memory(MB)' will frequently show up in here
--		if so, you can ignore it... 
SELECT name, value, value_in_use 
FROM sys.configurations
WHERE value != value_in_use;
```

Otherwise, once advanced configuration options are enabled, if you need to enable xp_cmdshell, run the following against your server:

```sql
USE master;
GO

EXEC sp_configure 'xp_cmdshell', 1;
GO
```

Once you've run that, you will need to run a RECONFIGURE statement (as outlined above) BEFORE the change will 'take'. (See instructions above AND warnings - then execute when/as possible.)

### Notes on Setting up Database Mail

For more information on setting up and configuring Database Mail, see the following post: [Configuring and Troubleshooting Database Mail](http://sqlmag.com/blog/configuring-and-troubleshooting-database-mail-sql-server). 

Then, once you've enabled Database Mail (and ensured that your SQL Server Agent - which isn't supported on Express Editions), you'll also need to create a new Operator. To create a new Operator:
- In SSMS, connect to your server. 
- Expand the SQL Server Agent > Operators node. 
- Right click on the Operators node and select the "New Operator..." menu option. 
- Provide a name for the operator (i.e., "Alerts"), then specify an email address (or, ideally, an ALIAS when sending to one or more people) in the "E-mail name" filed, then click OK. (All of the scheduling and time stuff is effectively for Pagers (remember those) - and can be completely ignored). 
- Go back into your SQL Server Agent properties (as per the article linked above), and specify that the Operator you just created will be the Fail Safe Operator - on the "Alerts System" page/tab. 
- 
For more information and best practices on setting up Operator (email addresses), see the following: [Database Mail Tip: Notifying Operators vs Sending Emails](http://sqlmag.com/blog/sql-server-database-mail-notifying-operators-vs-sending-emails).

**NOTE:** *By convention S4 Backups are written to use a Mail Profile name of "General" and an Operator Name of "Alerts" - but you can easily configure backups to use any profile name and/or operator name.*

[Return to Table of Contents](#toc)

## <a name="syntax"></a>Syntax 

```sql
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = {N'[READ_FROM_FILESYSTEM]' | N'list,of,db-names,to,restore' },
    [@DatabasesToExclude = N'list,of,dbs,to,not,restore, %wildcards_allowed%',]
    @BackupsRootPath = N'\\server\path-to-backups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'L:\SQLLogs', 
    [@RestoredDbNameSuffix = N'',] 
    [@AllowReplace = N'',] 
    [@SkipLogBackups = NULL,] 
    [@CheckConsistency = { 0 | 1 },] 
    [@DropDatabasesAfterRestore = { 0 | 1 },]
    [@MaxNumberOfFailedDrops = 0,]
    [@OperatorName = NULL,] 
    [@MailProfileName = NULL,] 
    [@EmailSubjectPrefix = N'',] 
    [@PrintOnly = { 0 | 1 }] 
;
```

### Arguments

**@DatabasesToRestore** = { [READ_FROM_FILESYSTEM] | 'comma,delimited, list-of-db-names, to restore' }

Required. You can either pass in the specialized 'token': [READ_FROM_FILESYSTEM] - which indicates that dba_RestoreDatabases will treat the names of (first-level) sub-FOLDERS within @BackupsRootPath as a list of databases to attempt to restore (i.e., if you have 3 folders, one called X, one called Y, and another called widgets, setting @BackupsRootPath to [READ_FROM_FILESYSTEM] would cause it to try and restore the databases: X, Y, and widgets). When using this token, you will typically want to explicitly exclude a number of databases using the @DatabasesToExclude parameter. Otherwise, if you don't want to 'read' in a list of databases to restore, you can simply specify a comma-delimited list of database names (e.g., 'X, Y,widgets') - where spaces between database-names can be present or not. 

Otherwise, for every database listed, dba_RestoreBackups will look for a sub-folder with a matching name in @BackupsRootPath and attempt to restore any backups (with a matching-name) present. 

**[@DatabasesToExclude** = 'list,of,dbs,to,not,attempt,restore,against, %wildcards_allowed%']
Optional. ONLY allowed to be populated when @DatabasesToRestore is set to '[READ_FROM_FILESYSTEM]' (as a means of explicitly ignoring or 'skipping' certain folders and/or databases). Otherwise, if you don't want a specific database restored, then don't list it in @DatabasesToRestore.

Note that you can also specify wildcards, or 'patterns' for database names that you wish to skip or avoid - i.e., if you don't want to attempt to restore multiple databases defined as <db_name>_stage, then you can specify '%_stage%' as an option for exclusion - and any databases matching this pattern (via a LIKE evaluation) will be excluded.

**@BackupsRootPath** = 'path-to-location-of-folder-containing-sub-folders-with-backups-of-each-db'

Required. S4 Restore uses the convention that all backups for a single, given, database should be in a seperate/dedicated folder. As such, you should backup all of your databases to D:\SQLBackups\ and each database's backups are then written into distinct sub-folders. (This is the same convention that S4 Backup uses.) 

**@RestoredRootDataPath** = 'path-to-folder-where-you-want-data-files-restored'

Required. S4 Restore will push (or relocate) .mdf and .ndf file into the path specified by @RestoredRootDataPath when restoring databases (regardless of the original path for these files pre-backup). If you need to try and use different paths for different databases (i.e., you don't have enough space on a specific drive to restore a number of your key databases), you'll need to set up multiple calls/executions against dba_RestoreDatabases with a different set of @DatabasesToRestore specified - and with different @RestoredRootDataPath (and/or @RestoredRootLogPath) values specified between each different call or execution. 

**@RestoredRootLogPath** = 'path-to-folder-where-you-want-log-files-restored'

Required. Can be the exact same value as @RestoredRootDataPath (i.e., data and log files can be restored to the same folder if/as needed) - but is provided as a seperate configurable option to allow restore of logs and data files to different drives/paths when needed as well. (Neither approach is necessarily better - and an 'optimal' configuration/setup will depend upon disk capacities and performance-levels.)

**[@RestoredDbNameSuffix]** = 'name-of-suffix-you-wish-to-append-to-restored-db-name']

Optional. When specified, the value of @RestoredDbNameSuffix will be appended to the end of the name of the database being restored. For example, if you have specified that you want to restore the Billing, Widgets, and Tracking databases (via @DatabasesToRestore) and have specified a @RestoredDbNameSuffix of '_test', these databases would be restored as Billing_Test, Widgets_Test, and Tracking_Test. This option is primarily provided for scenarios where you will be doing 'on-box' restore testing (i.e., running nightly jobs ON your production server and restoring copies of your production databases to make sure the backups are good) - so that you don't have to worry about naming collisions or other issues while running restore tests.

[**@AllowReplace** = { NULL | 'REPLACE' }]

Optional. Defaults to NULL. When specified (i.e., when the exact value for this parameter is set to the text 'REPLACE'), if you are attempting to restore, say, the 'Widgets' database and a database by that name ALREADY exists on the server, this command WILL force that existing database to be dropped and overwritten. (And note that even if the 'target' database is in use, dba_RestoreDatabases WILL kick all users out of the target database, DROP it, and then RESTORE over the top of it.) As such, be sure to use this particular option with extreme caution. Further, note that if you are restoreing the 'Widgets' database and have specified a @RestoredDbNameSuffix of '_test' and a database called Widgets_test exists on your server, that database WILL be overwritten if @AllowReplace is set to 'REPLACE'. 

***NOTE:** This parameter is an ADVANCED parameter - designed to facilitate use in scenarios where nightly restore operations are used BOTH to test backups AND push a copy of a production database 'down' to a dev/test server (by means of a restore operation) - which, in turn, is why the option to 'REPLACE' an existing (and even potentially in-use) database exists. Please see the warning below before contemplating and/or using this parameter.*

***WARNING:** Please make sure to read-through and thoroughly understand the ramifications of the @AllowReplace parameter before using it in production. Furthermore, you should always 'test out' how this parameter will work out by setting @PrintOnly to 1 whenever you are thinking of using this option - so that you can SEE what execution would, otherwise, do to your system.* 

**[@SkipLogBackups** = { 0 | 1 }]

Optional. Defaults to 0 (false). By default, dba_RestoreDatabases will find and apply the most recent FULL backup, the most recent DIFF backup (if present), and then all T-LOG backups since the most recent FULL or DIFF backup applied. By setting @SkipLogBackups to 1 (true), dba_RestoreDatabases will NOT apply any transaction logs. 

This is an advanced option and is really only useful for 'downlevel' situations - or scenarios where you're restoring copies of backups to a dev/test server and do NOT care about verifying that your T-LOG backups are viable (nor do you care about seeing roughly how long they take to restore). 

**[@CheckConsistency** = { 0 | 1} ]

Optional. Defaults to 1 (true). When using dba_RestoreDatabases to check/validate your backups, you will always want to check consistency - to help verify that no corruption problems or issues have crept into your backups (i.e., into your production databases - where corruption is actually 'copied' into your backups) and/or to ensure that you aren't somehow encountering corruption issues on the RESTORED databases you're creating for testing (as repeated issues with corruption on your restored databases vs the 'originals' would typically indicate a problem with the storage subsystem on your 'failover' or 'test' server - meaning that it likely wouldn't be viable as server for disaster recovery purposes). 

This is an an advanced option, and is really only useful for 'downlevel' situations - or scenarios where you're restoring copies of backups to a dev/test server and do NOT care about verifying the integrity of your backups/restored databases as part of execution. 

**[@DropDatabasesAfterRestore** = { 0 | 1 } ]

Optional. Defaults to 0 (false). When set to 1 (true), once dba_RestoreDatabases has restored a database specified for restore - and after it has run consistency checks (if specified for execution), it will then DROP the restored (i.e., copy) database to clear-up space for further operations and/or to make subsequent operations easier to configure (i.e., if you execute nightly restore-tests of 3x production databases, check consistency against them, and then drop them (one-by-one - as they're restored then checked), you won't have to worry about setting 'REPLACE' for subsequent executions (i.e., the next night) and you'll be 'cleaning up' disk space along the way as well.) 

This is an advanced option and has a built-in 'fail-safe' in the sense that this option can/will ONLY be applied to databases with a name that was successfully RESTORED during current execution (i.e., DROP commands against a specific database will be checked against a list of databases that were already restored during the CURRENT execution of dba_RestoreDatabases - and if the db-name specified is not found, it can't/won't be dropped).

**[@MaxNumberOfFailedDrops** = integer-value]

Optional. Defaults to a value of 1 (i.e., only 1x failed DROP operations will be allowed). When @DropDatabasesAfterRestore is set to 1 (true), each database to be restored will be restored, checked for consistency (if specified), and then dropped - before moving on to the next database to restore + test, and so on. If, for whatever reason, dba_RestoreDatabases is NOT able to DROP a database after restoring + checking it, it will increment an internal counter - for the number of 'failed DROP operations'. Once that value exceeds the specified value for @MaxNumberOfFailedDrops, then dba_RestoreDatabases will TERMINATE execution. 

This is an advanced option, and is primarily designed to prevent 'on-box' restore tests (i.e., test where you're restoring copies of production databases in a 'side by side' fashion out on your same production servers - usually for licensing purposes) from running your production systems out of disk by 'blindly' just restoring more and more databases in production while not (for whatever reason) 'cleaning up along the way'. 

**[@OperatorName** = 'sql-server-agent-operator-name-to-send-alerts-to' ]

Defaults to 'Alerts'. If 'Alerts' is not a valid Operator name specified/configured on the server, dba_RestoreDatabases will throw an error BEFORE attempting to restore databases. Otherwise, once this parameter is set to a valid Operator name, then if/when there are any problems during execution, this is the Operator that dba_RestoreDatabases will send an email alert to - with an overview of problem details. 

**[@MailProfileName]** = 'name-of-mail-profile-to-use-for-alert-sending']

Deafults to 'General'. If this is not a valid SQL Server Database Mail Profile, dba_RestoreBackups will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during restore + validation operations. 

**[@EmailSubjectPrefix** = 'Email-Subject-Prefix-You-Would-Like-For-Restore-Testing-Alert-Messages']

Defaults to '[RESTORE TEST ] ', but can be modified as desired. Otherwise, whenever an error or problem occurs during execution an email will be sent with a Subject that starts with whatever is specified (i.e., if you switch this to '--DB2 RESTORE-TEST PROBLEMS!!-- ', you'll get an email with a subject similar to '--DB2 RESTORE-TEST PROBLEMS!!-- Failed To complete' - making it easier to set up any rules or specialized alerts you may wish for backup-testing-specific alerts sent by your SQL Server.

**[@PrintOnly** = { 0 | 1 }]

Defaults to 0 (false). When set to 1 (true), processing will complete as normal, HOWEVER, no restore operations or other commands will actually be EXECUTED; instead, all commands will be output to the query window (and SOME validation operations will be skipped). No logging to dba_DatabaseRestore_Log will occur when @PrintOnly = 1. Use of this parameter (i.e., set to true) is primarily intended for debugging operations AND to 'test' or 'see' what dba_RestoreDatabases would do when handed a set of inputs/parameters.

[Return to Table of Contents](#toc)

## <a name="remarks"></a>Remarks

### Conventions and Concerns

S4 Restore was designed to allow regular, recurring, tests of SQL Server Backups - by means of executing full-blown RESTORE operations against targeted databases/backups (or, in other words, the only REAL way to know if backups are valid is to VERIFY them by means of a restore). However, while dba_RestoreDatabases was designed to make it easy to restore one or more databases on a recurring schedule, there are some concerns, considerations, conventions you will need to be aware of. 
- **Conventions.** S4 Restore is built around the idea that SQL Server backups will be stored in one or more 'root' folders (e.g., F:\SQLBackups or \\\\BackupServer\SQLBackups) where the backups (FULL, DIFF, and T-LOG) are stored in sub-folders per each database. So, if you've got a Widgets database and a Billing database that you're backing up, these would end up in F:\SQLBackups\Widgets and F:\SQLBackups\Billing respectively (or \\\\BackupServer\SQLBackups\Widgets and \\\\BackupServer\SQLBackups\Billing respectively). With this convention in place, dba_RestoreDatabases does NOT 'interrogate' each backup file found per database-sub-folder. Instead, it relies upon the naming conventions defined within S4 Backup (of [Type]_name_info.[ext] - where [Type] is the text FULL, DIFF, or LOG (depending upon backup type) and [ext] is the extension (.bak for FULL/DIFF backups and .trn for LOG backups) + timestamps associated with the files to determine which (i.e., the most recent) FULL + DIFF (if any) backups to restore and then which T-LOG backups to restore from the most recent FULL and DIFF (if present). In short, if you use S4 Backup, then S4 Restore will work just fine and without issue (i.e., just 'point it' at the folder(s) containing your SQL Server backups - that you wish to restore) - whereas if you're using other solutions for backups, you may need to 'tweak' those (or dba_RestoreDatabases) to enable naming conventions that will work as needed.
- **Recurring Execution.** S4 was designed to be run daily (or even more frequently if needed) to help ensure that backups are valid (by restoring them). This means that if you schedule exection of Restore Operations nightly (a best-practice), then you'll either have to DROP each database after it is restored + tested/checked each night or, you'll have to specify that databases with names matching those that you'll be restoring are dropped and then OVERWRITTEN on subsequent executions (i.e., the next days). Typically, specifying that you want to explicitly DROP + OVERWRITE a database is a 'spooky' proposition. In fact, this option is only provided in S4 Restore to address down-level dev-restore operations - and is accomplished via the @AllowReplace parameter. Otherwise, see the [Intended Usage Scenarios](#scenarios) section of this document for info on how @DropDatabasesAfterRestore is a BETTER option for nightly restore tests - as it restores databases (checks them if specified), and then drops them before proceeding to the next database to restore (both cleaning up disk space/resources AND making it so you don't have to use the @AllowReplace parameter - which is a non-trivial parameter).


### Additional Warnings about the @AllowReplace Parameter

In addition to the warnings specified in the [Syntax](#syntax) section of this document, the primary worry or concern about using the @AllowReplace parameter is that SysAdmins who might, otherwise, be inclined to use copy + paste + tweak semantics to modify a job or create a new restore/test job from an existing job MIGHT inadvertently copy from a job where this value is set to 'REPLACE' - which could mean (if someone is not paying attention), that a job could be accidentally set up to DROP running production databases and replace them with restored 'copies' of the database that do NOT include TAIL-END-OF-THE-LOG backups (i.e., you would 100% be missing transactions in this scenario - in addition to incurring potentially significant down-time). 

In short, only use the @AllowReplace parameter for down-level Development Refresh scenarios and ONLY when you're very confident of what can/will happen with the parameters you've specified.

### Order of Operations During Execution
During execution, the high-level order of operations within dba_RestoreDatabase is: 
- Validate Inputs.
- Verify that @BackupsRootPath is a valid path (and is accessible to SQL Server).
- Construct a list of databases to backup - from @DatabasesToRestore.
- **For each database to be restored, the following operations are executed (in order):**
- Create the DatabaseName for the database to be restored using the name specified in @DatabasesToRestore (for the current DB) + any info in @RestoredDbNameSuffix. 
- Checks to see if a database matching the 'restore-name' exists - and TERMINATES restore operations for the database in question unless @AllowReplace is configured for overwrite operations. 
- Builds a list of files (most recent FULL + most recent DIFF (if present) + all T-Logs since the most recent FULL/DIFF if @SkipLogBackups is not set to 1 (true)). 
- Builds RESTORE statements - with MOVE options specified - to move data and log files to @RestoredRootDataPath and @RestoredRootLogPath parameters as specified. 
- Begins working through restore operations as needed (i.e., FULL will always be done - or an error is thrown, then a DIFF is added - if present, and T-LOG backups if applicable AND configured for restore). 
- Logs meta-data (duration and outcome) info about the RESTORE operation - once complete (or errors if there are problems encountered).
- Executes DBCC CHECKDB() if @CheckConsistency is set to 1 (true). Logs duration and outcome info - or errors - upon completion. 
- Drops the restored database if @DropDatabasesAfterRestore is set to 1 (true). 
- Moves on to processing the next database, and so on. 
- Once processing of all databases in @DatabasesToRestore is complete, dba_RestoreDatabases will send an email to @OperatorName if any problems or issues were encountered along the way. 

### Considerations for Copying Production Databases into Development
While it is a best-practice to provide developers with development, testing, and staging environments that exactly match those of production, there are two primary considerations that should always be addressed when regularly copying production databases 'down-level' into development, testing, or staging environments:
- **Security of Sensitive Data.** If Production Databases contain sensitive data, a common technique for dealing with this is to a) restore copies of backups into dev/testing, and then b) run scripts to 'scramble' data after it has been restored (i.e., typically during early morning or when devs aren't typically active). However, for highly sensitive data (i.e., some forms of HIPAA or PCI data) it's important to call out that 'scrambling' data may NOT be enough (scrambling may make data 'unreadable' to the casual observer, but hackers CAN in some cases easily figure out how values were 'shifted' and/or they can also use relationships between some types of 'scrambled' data and publically accessible info to 'reconstitute' sensitive PII in many cases. As such, scrambling MAY not be enough protection (in which case you'll need a different solution - i.e., simulated dev/test/staging environments with 100% bogus data that still a) exactly matches the schema and code found in production and b) has similar cardinality and distribution details as in prod for perf-testing needs). Otherwise, in some other cases - where scrambling MAY be enough, you MIGHT need to a) Backup on production, b) restore to a staging environment (that only restricted users (DBAs) have access to), c) scramble the data THERE, and then d) back it up from staging, and e) restore to dev/test environments - to avoid the potential for a restore to happen, but a 'script error' during 'scrambling' to leave sensitive unscrambled to devs. (And, while you might think your devs don't care about being exposed to sensitive info, the reality is that exposing honest devs to sensitive info means that they can then, potentially, be accused of STEALING that info if/when it is found to have gone missing - so you're NOT doing them any favors if you think the occasional failure or hiccup won't be a big deal - because you're exposing them to significant, potential, liability and accusations.)
- **Ensure Proper Sequestration of Environments.** When Dev (and/ore Staging + Testing) Environments mirror those of production, **MAKE SURE** that you are not using the same credentials (logins + passwords - or Windows Accounts) to allow access to dev/testing environments and production. Ideally, Production should be in its own Domain, and dev/testing/staging environments should be in different domains - meaning that if your applications and services are using Integrated (Windows) authentication, you should be using logins like PROD\WebServerX to access prod and DEV\TestWebServerX to access dev databases. Or, if you're using SQL Server Auth for your applications/services, make sure to fully distinguish login names and use ENTIRELY different passwords - i.e., WebAppXX_PROD for production access and WebApp_DEV for dev access. **FAILURE to follow this convention can result in situations where devs or sysadmins copy/paste configuration and connection info from one environment to the next, FORGET to 'repoint' a connection string from production to dev, and then allow devs to 'go to work' against a PRODUCTION system - without realizing they're making changes in production.**

[Return to Table of Contents](#toc)

## <a name="examples"></a>Examples 

### A. Configuring a Simplified Execution.
The following example showcases a simplified execution of S4 Restore:

```sql
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'Billing,Widgets', 
    @BackupsRootPath = N'\\server\path-to-backups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'L:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test';
```

By executing the code above, S4 Restore will do the following:
- Attempt to Restore copies of the Billing and Widgets databases - as Billing_test and Widgets_test. 
- Push data and log files for each of the databases above to D:\SQLData and L:\SQLLogs. 
- Use Transaction Logs (if present) during the restore operations for both databases (as @SkipLogBackups defaults to 0).
- Execute Consistency Checks against both databases after they're restored (as @CheckConsistency defaults to 1). 
- Log information about restore duration + outcome and consistency check durations + outcome for both databases into master.dbo.dba_DatabaseRestore_Log. 
- Send an email if there were any problems encountered during Restore of consistency check operations (for either database). 

Further, in the above example, if there aren't any backups for the Billing database found, RESTORE operations for Billing_test will obviously fail - and will be logged into dba_DatabaseRestore_Log, but dba_RestoreDatabases will NOT terminate execution upon failure to restore or check a database - instead, it logs info, then moves on to the next database - meaning that if backups for the Widgets database exist, Widgets_test will be restored and checked. Then, once all operations are complete, a summary of errors/problems encountered (i.e., no backups found for Billing) will be emailed. 

### B. Simplified Execution - Dropping Databases after Restore + Checks
The following execution is, effectively, identical to Example A - except that the Billing_test and Widgets_test databases will be dropped AFTER being restored and AFTER checked for consistency (i.e., if backups are found for the Billing database, they'll be restored as the Billing_test database, the Billing_test database will be checked for consistency, and after that check is complete, dba_RestoreDatabases will DROP Billing_test, then start working on processing backups for the Widgets database, and so on).

```sql
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'Billing,Widgets', 
    @BackupsRootPath = N'\\server\path-to-backups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'L:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test', 
	@DropDatabasesAfterRestore = 1;
```

Note that @DropDatabasesAfterRestore DEFAULTs to 0 (false), but you'll usually want it set to 1 (true) for most automation scenarios (i.e., to 'clean-up' for subsequent operations (the next day) and to avoid 'burning up' disk space in some environments). 

### C. Configuration for Nightly, On-Box, Tests of Production Databases.
Assume you've got a Hosted SQL Server with 4x production datababases: db1, db2, db3, and PriorityA. You've scheduled regular backups with S4 Backup, and are regularly (i.e., every 10 minutes), copying backups to the Cloud - but you want to make sure your backups are viable. To do this, you don't have an other SQL Server, so you'll need to restore databases on the SAME server where the backups are taken (i.e., out on production SQL Server). To do this, you obviously can't overwrite your production databases - so you'll need to restore, say, PriorityA as something else (like PriorityA_test). Further, while db1, db2, and db3 each are roughly 20GB in size, PriorityA is, let's pretend, 200GB in size - and you currently only have around 300GB of 'free' disk space on your server. That's technically enough to restore copies of everything - but, then you'll be hitting a point where you've only got 40GB of free space. Happily, S4 helps address this via the @DropDatabasesAfterRestore - meaning that each database will be restored, checked, then dropped - so that the 'max' amount of disk used while running restore tests against all databases will be just 200GB (i.e., the size of your largest database). Further, in situations where you may have MORE databases to check than free space (i.e., multi-tenant solutions where you might have 200 databases of different sizes - all of which might weigh in at 1TB but where you only have .5TB of 'free space'), the @MaxNumberOfFailedDrops will prevent restore operations from running you out of disk if you somehow restore multiple (larger-ish) databases but, somehow, aren't able to get them to DROP after they're tested (i.e., execution will continue after failure to DROP databases but ONLY until the @MaxNumberOfFailedDrops value is exceeded). 

In such a scenario, you'd spin up something similar to the following - and configure it to run (via a SQL Server Agent Job) at, say, 3AM every morning: 

```sql
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'PriorityA,db1,db2,db3', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'D:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1;
```

sdflksajfal

### D. Nightly, Off-Box, Restore Tests.
Assume you've got multiple SQL Servers, each with different databases - used for various purposes. Then assume you've got a server where you can run backup tests (this could be one of your 'less loaded' production servers, a specifically configured 'restore server' that MIGHT be used as a failover/contingency server (as a CYA option in cases where HA options/solutions somehow don't work as expected, or whatever) - where you can regularly (i.e., nightly) test your backups. 

Then assume that for each production server, you've got a 'backup-target' server - with sub-folders for each server/host - to put its own databases into. So, that, for example, you've got backup folders out on your 'backup server'/UNC share that look similar to the following: 
- \\\\backup-server\ClusterA\
- \\\\backup-server\ProdC\
- \\\\backup-server\PigPile\

Assume that ClusterA has mission-critical databases deployed to it, ProdC has important databases, and PigPile has various smaller (i.e., 3rd party and 'departmental'/internal) dbs. Further, assume that PigPile has TBs of storage - i.e., enough to run restore checks of all production databases. To accomplish restore tests of backup from ALL 3 different servers, you'll need 3x different/distinct jobs (as dba_RestoreDatabases, by convention, only searches for backups in @BackupsRootPath + '\' + db_name for backups - and can't, therefore, be configured to just use \\\\backup-server\ as the 'root' path). While this might initially seem like a pain, this actually comes with one significant (by design) benefit - which is that you can customize the subject of the email Subject you'll get when problems/issues occur during restore operations - from one server to the next. 

To address this scenario/need, you'd spin up 3x distinct calls to dba_RestoreDatabases - as follows: 

```sql
-- Restore Operations for ClusterA:
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'Inventory,Catalog,Sales,Support', 
    @BackupsRootPath = N'\\\\backup-server\ClusterA\', 
    @RestoredRootDataPath = N'N:\Nearline-Restore\', 
    @RestoredRootLogPath = N'N:\Nearline-Restore2\', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1, 
    @EmailSubjectPrefix = N'!!Cluster Restore Tests - ';


-- Restore Operations for ProdC:
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'AccountingTools,ERPNNS,db2,db3', 
    @BackupsRootPath = N'\\\\backup-server\ProdC\', 
    @RestoredRootDataPath = N'N:\Nearline-Restore\', 
    @RestoredRootLogPath = N'N:\Nearline-Restore2\', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1, 
    @EmailSubjectPrefix = N'Prod Restore Tests - ';


-- Restore Operations for PigPile:
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'demo,CRM_SSV,HRapp, EngineeringSamples', 
    @BackupsRootPath = N'\\\\backup-server\PigPile\', 
    @RestoredRootDataPath = N'N:\Nearline-Restore\', 
    @RestoredRootLogPath = N'N:\Nearline-Restore2\', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1, 
    @EmailSubjectPrefix = N'PigPile DB Restore Tests - ';
    
```

Note that in the examples above, each distinct execution targets a different 'root' folder for @BackupsRootPath, and has a correspondingly different 'subject line' for alerts or errors. Otherwise, all other parameters are the same (i.e., all data files and logs will be restored to the same locations/etc.).

It's also important to call out that if the Inventory and Catalog databases on ClusterA are high-enough volume databases (i.e., in terms of transactions) that DIFF backups are used for these databases to meet RTOs, but DIFF backups aren't used elsewhere and, likewise, if we assume that (for whatever reason), the EngineeringSamples database on PigPile is in SIMPLE recovery mode (i.e., no T-LOG backups), dba_RestoreDatabases will transparently handle restoration of all of these databases without any problems (i.e., it looks for the most recent FULL (and throws an error if there isn't one), then it will attempt to restore a DIFF file (the most recent available) if present, and then (optionally) will attempt to restore T-LOG backups since the most recent FULL or DIFF restore if @SkipLogBackups is set to 0 (false) AND if there are files available). 

***NOTE:** In situations where you need to spin up more than 1x distinct call to dba_RestoreDatabases, the best approach is to either put these into different SQL Server Agent Jobs (which can cause problems with scheduling if you'd like multiple operations to execute during roughly the same 'maintenance window' - because you'll have to figure out roughly how long each 'job' will take and then 'pad' schedules accordingly) OR to use a single SQL Server Agent Job and spin up distinct Job Steps per each explicit exeuction/need. Using a single job provides the benefit of letting operations run serially - e.g., in the example above, CLUSTERA databases would be restored/tested, then those from PRODC would be restored/tested, and then databases from PIGPILE would be restored/tested - all in a 'back to back' arrangement that would take however long needed - and which wouldn't require 'juggling' of different schedules and 'windows' for one job to (hopefully) complete, then an other, and so on. As such, multiple executions (for whatever reasons), usually make sense when tackled within the same SQL Server Agent Job. HOWEVER, when you take this approach, you will usually want to ENSURE that if a failure or problem occurs during execution during one Job Step, the "On failure action" for that Job Step is to "Go to the next step" - rather than terminating execution for the entire Job and reporting an error (which is the default). For more information/guidance on this concern, see the documentation for S4 Backups - in the section entitled "Setting up Scheduled Backups using S4 Backups".*

### E. Restoring Copies of Production Databases to Dev Environments
In this example, we'll assume that the Tribeca database is a key production database that needs to be copied 'down' to a dev server nightly. In this case, we DO NOT want to 'drop' databases after they're restored, and we also want to let developers know that this is a regularly refreshed copy of the database - so we'll append the word "NightlyDev" to this database as part of the restore process:

```sql
-- Restore Operations for ClusterA:
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'Tribeca', 
    @BackupsRootPath = N'\\\\backup-server\Prod\', 
    @RestoredRootDataPath = N'N:\DevSQLData\', 
    @RestoredRootLogPath = N'S:\DevSQLLogs\', 
    @RestoredDbNameSuffix = N'NightlyDev', -- yields: TribecaNightlyDev
    @DropDatabasesAfterRestore = 0, -- defaults to 0
    @EmailSubjectPrefix = N'Nightly Dev Refresh - ';
```

Note that, in this example, we're NOT skipping T-LOG bakups (we want to both give devs the 'most recent' copy of production data available when this process runs AND verify that T-LOG backups are working (i.e., that they can be applied/restored when used)). Likewise, while we COULD 'skip' consistency checks for this database, we're not doing that. 

In a real-world scenario, where doing a 'nightly' refresh, you will USUALLY need to create a 'complex' SQL Server Agent Job that will do the following:
- Restore the target database(s) using dba_RestoreDatabases (as per the example above) - in a single Job Step.
- Remove any 'orphaned users' (i.e., PROD\AppServer or AppServer_Prod), and then create new users (and bind them to local logins - e.g., for DEV\AppServer or AppServer_Dev) within an additional SQL Server Job Step. 
- Possibly scramble any sensitive info (in an additional Job Step).
- Change any 'config' information stored in the DATABASE itself (in a specific Job Step).
- etc. 

When creating 'complex' jobs for down-level restore purposes, it is a best-practice to put each specific, distinct, task into its own Job Step (that way when something 'bad' happens along the way, you know exactly what 'stage' of the process broke-down and can easily 'restart' the process from that exact (failed) Job Step once you've corrected whatever is causing problems). 

### F. Using S4 Restore For Disaster Recovery
While Fault Tolerance (i.e., Mirroring, Availability Groups, or a Failover Cluster Instance) are the best ways to protect against down-time, there can be situations where you might need to recover one or more databases 100% from backups - which can be easily facilitated by S4 Restore (even though support for this need is NOT a substitute for Highly Available/Fault-Tolerant systems or other types of Disaster Recovery planning and contingencies).

***WARNING:** Whenever you're trying to recover production databases (in a disaster recovery scenario) 'purely' from backups, you want to do everything possible to try and obtain a 'tail-of-the-log' backup - or capture any/all transactions in your Transaction Log that have NOT been backed up since your last (successful) Transaction Log backup. Otherwise, if you FAIL to execute these backups (when they are possible) you run the risk of losing data (or having a terrible time manually pushing it 'back into place after the fact' IF you managed to (later on) recover this data). So, always try to execute (and then copy or make-available) any 'tail-of-the-log' backups to S4 Restore BEFORE you start using S4 Restore for recovery purposes.*

In the following example, we'll assume that a Startup company had a hosted SQL Server with 3x databases needed for their application - that they were executing regular backups (i.e., FULL backups nightly and T-Log backups of all 3 databases every 5 minutes) - and that these backups were being pushed up to 'the cloud' every 5 minutes (i.e., being copied off box). Then, for whatever reason, we'll assume that a major disaster occured - not only did their hosting company have a serious crash that resulted in the loss of the Virtual Server this company was using, but it's going to take 20+ hours for them to have something 'in place' for recovery. As such, this startup decides to provision a new server with a different hosting compay, copy/deploy their apps and such and then copy down the backups 'from the cloud' into a folder called D:\RestoredCloudBackups\SQL (where there will be a sub-folder for each of the 3x different production databases) and they're now ready to spin up restore operations of their databases - to bring them into production. To do this, they would run something similar to the following: 

```sql
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'Customers,Products,Sales', 
    @BackupsRootPath = N'D:\RestoredCloudBackups\SQL', 
    @RestoredRootDataPath = N'D:\SQLData\', 
    @RestoredRootLogPath = N'D:\SQLData\', 
    @RestoredDbNameSuffix = NULL, -- restore with 'prod' name
    @DropDatabasesAfterRestore = 0, -- don't drop
    @CheckConsistency = 0; -- skip (for now) in interest of expediency
```

Note that in this case, they're NOT dropping the databases after recovery (that'd be dumb), they're also NOT running Consistency Checks as PART of their disaster recovery process (their DBA will kick those off within an hour or so of things being backup and running - but since the goal here/now is to get things operational as quickly as possible, we're not going to 'wait' for consistency checks of one restored database to 'delay' restoring the next database and so on). 

Finally, since this is a disaster scenario, we're also assuming that this startup DID lose (or potentially lost) SOME transactions - i.e., the crash of their Virtual host with their former host was so 'out of the blue' that while they did have a T-LOG backup execute just seconds before everything 'melted down', this Log Backup file did NOT 'make it off box' before the crash, meaning that they stand to lose up to ~ 10 minutes of transactions per each database. (So they'll have to notify customers accordingly.) Otherwise, if the 'crash' had somehow been 'more controlled' or had they had some sort of warning, they MIGHT have been able to execute a 'tail-of-the-log-back' and, had they successfully pulled that off, they would want to put that T-LOG backup into the folder (per each db) with their other T-LOG backups, so that dba_RestoreBackups would 'see' and apply this T-LOG backup as part of the restore process.

### G. Using S4 Restore for Ad-Hoc Restore Operations or to Generate Restore Statements
If you'd like to see what S4 Restore will do against a particular set of commands - without having those commands executed, simply flip the @PrintOnly parameter to 1 (true) and execute dba_RestoreDatabases after specifying whatever parameters are needed. For example, the code below is effectively identical to that in Example A, but because @PrintOnly is specified, dba_RestoreDatabases won't actually execute any code, but will - instead - simply 'spit out' the commands it would have (otherwise) executed:

```sql
EXEC master.dbo.dba_RestoreDatabases 
    @DatabasesToRestore = N'Billing,Widgets', 
    @BackupsRootPath = N'\\server\path-to-backups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'L:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test'
    @PrintOnly = 1;
```

Use of the @PrintOnly command can be helpful for troubleshooting and/or testing (i.e., to see what commands would be issued when using more advanced commands like @AllowReplace) - or it can be used to generate a set of statements that you could then copy + paste + tweak to suit any specific needs you might have (i.e., like a Point In Time Recovery Operation - which is NOT supported by S4 Restore).

[Return to Table of Contents](#toc)