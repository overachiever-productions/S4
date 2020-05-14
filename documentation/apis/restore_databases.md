![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.restore_databases

# dbo.restore_databases

## Table of Contents
- [Overview](#overview)
    - [Rationale]()
    - [Benefits of S4 Restore]()
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)


[README](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedPath=README.md) > [S4 APIs](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedPath=Documentation%2FAPIS.md) > dbo.restore_databases

# dbo.restore_databases

## Overview
**APPLIES TO:** :heavy_check_mark: SQL Server 2008 / 2008 R2 :heavy_check_mark: SQL Server 2012+ :grey_exclamation: SQL Server Express / Web

:heavy_check_mark: Windows :o: Linux :o: Amazon RDS :grey_question: Azure

**S4 CONVENTIONS:** [Advanced-Capabilities](/x/link-here), [Alerting](etc), [@PrintOnly](etc), [Backup Names](xxx), and [Tokens](etc)

### Rationale

S4 Restore was designed to provide:
- **Simplicity**. Streamlines the non-trivial process of testing backups (by restoring them) through a set of simplified commands and operations that remove the tedium and complexity from restore operations - while still facilitating best-practices for testing and recovery purposes.
- Streamline the non-trivial process of verifying backups - by restoring them through a streamlined and simplified set of commands
- **Recovery**. While S4 Restore was primarily designed for regular (automated) testing of backups, it can be used for disaster recovery purposes to restore backups to the most recent recovery point available by walking through FULL + DIFF + TLOG backups and applying the most recent backups of all applicable backup files available. 
- **Transparency**. Use of (low-level) error-handling to log problems into a centralized logging table (for trend-analysis and improved trouble-shooting) and send email alerts with concise details about each failure or problem encountered during execution so that DBAs can quickly ascertain the impact and severity of problems without having to wade through messy 'debugging' and troubleshooting.

### Benefits of S4 Restore
Key Benefits provided by S4 Restore:
- **Simplicity, Recovery, and Transparency.** Commonly needed features and capabilities for restoring SQL Server backups - with none of the hassles or headaches. 
- **Peace of Mind.** The only real way to know if backups are viable is to restore them. S4 Restore removes the mystery by making it easy to regularly restore (i.e., test) backups of critical SQL Server databases.
- **Automation.** Easily Automate Execution of S4 Restore commands to set up regular (nightly) restore tests for continued, ongoing protection and coverage. 
- **Instrumentation.**  After setting up regular restore-check jobs, you can easily query metrics about the duration for restore operations (and consistency checks) for trend-analysis and to help ensure RTO compliance.
- **Portability.** Easy setup and configuration - with no dependency on 'outside' resources (other than access to your backup files), S4 is easy to deploy and use pretty much anywhere.

[Return to Table of Contents](#table-of-contents)

## Syntax

```sql

EXEC admindb.dbo.restore databases 
    @DatabasesToRestore = N'[ {READ_FROM_FILESYSTEM} | list,of,db-names,to,restore ]' ],
    [@DatabasesToExclude = N'list,of,dbs,to,not,restore, %wildcards_allowed%', ]
    [@Priorities = N'higher,priority,dbs,*,lower,priority,dbs, ]
    @BackupsRootPath = N'[ \\server\path-to-backups | {DEFAULT} ]', 
    @RestoredRootDataPath = N'[ D:\SQLData | {DEFAULT} ]', 
    @RestoredRootLogPath = N'[ L:\SQLLogs | {DEFAULT} ]', 
    [@RestoredDbNamePattern = N'{0}_test', ] 
    [@AllowReplace = N'', ] 
    [@SkipLogBackups = NULL, ] 
    [@CheckConsistency = [ 0 | 1 ], ] 
    [@DropDatabasesAfterRestore = [ 0 | 1 ], ]
    [@MaxNumberOfFailedDrops = 2, ]
    [@OperatorName = N'{DEFAULT}', ] 
    [@MailProfileName = N'{DEFAULT}', ] 
    [@EmailSubjectPrefix = N'', ] 
    [@PrintOnly = [ 0 | 1 ] ]   

;
```

### Arguments
**@DatabasesToRestore** = N'[ {READ_FROM_FILESYSTEM} | comma,delimited, list-of-db-names, to restore ]'  
**REQUIRED.** 
You can either pass in the specialized 'token': [READ_FROM_FILESYSTEM] - which indicates that dbo.restore_databases will treat the names of (first-level) sub-FOLDERS within @BackupsRootPath as a list of databases to attempt to restore (i.e., if you have 3 folders, one called X, one called Y, and another called widgets, setting @BackupsRootPath to {READ_FROM_FILESYSTEM} would cause it to try and restore the databases: X, Y, and widgets). When using this token, you will typically want to explicitly exclude a number of databases using the @DatabasesToExclude parameter. Otherwise, if you don't want to 'read' in a list of databases to restore, you can simply specify a comma-delimited list of database names (e.g., 'X, Y,widgets') - where spaces between database-names can be present or not. 

Otherwise, for every database listed, dba_RestoreBackups will look for a sub-folder with a matching name in @BackupsRootPath and attempt to restore any backups (with a matching-name) present. 

**[@DatabasesToExclude** = 'list,of,dbs,to,not,attempt,restore,against, %wildcards_allowed%' ]  
OPTIONAL. May ONLY be populated when `@DatabasesToRestore` is set to `'{READ_FROM_FILESYSTEM}'` (as a means of explicitly ignoring or 'skipping' certain folders and/or databases). Otherwise, if you don't want a specific database restored, then don't list it in @DatabasesToRestore.

Note that you can also specify wildcards, or 'patterns' for database names that you wish to skip or avoid - i.e., if you don't want to attempt to restore multiple databases defined as <db_name>_stage, then you can specify '%_stage%' as an option for exclusion - and any databases matching this pattern (via a LIKE evaluation) will be excluded.

**[@Priorities** = N'higher, priority, dbs, *, lower, priority, dbs' ]  
OPTIONAL. Allows specification of priorities for restore/test operations (i.e., specification for order of operations). When NOT specified, dbs loaded (and then remaining after @DatabasesToExclude are processed) will be ranked/sorted alphabetically - which would be the SAME result as if @Priorities were set to the value of '*'. Which means that * is a token that specifies that any database not SPECIFICALLY specified via @Priorities (by name) will be sorted alphabetically. Otherwise, any db-names listed (and matched) BEFORE the * will be ordered (in the order listed) BEFORE any dbs processed alphabetically, and any dbs listed AFTER the * will be ordered (negatively - in the order specified) AFTER any dbs not matched. 

As an example, assume you have 7 databases, ProdA, Minor1, Minor1, Minor1, Minor1, and Junk, Junk2. Alphabetically, Junk, Junk2, and all 'minor' dbs would be processed before ProdA, but if you specified 'ProdA, *, Junk2, Junk', you'd see the databases processed/restored in the following order: ProdA, Minor1, Minor2, Minor3, Minor4, Junk2, Junk - because ProdA is specified before any dbs not explicitly mentioned/specified (i.e., those matching the token *), all of the 'Minor' databases are next - and are sorted/ranked alphabetically, and then Junk is specified BEFORE Junk - but after the * token - meaning that Junk is the last db listed and is therefore ranked LOWER than Junk2 (i.e., anything following * is sorted/ranked as defined and FOLLOWING the databases represented by *).

When @Priorities is defined as something like 'only, db,names', it will be treated as if you had specified the following: 'only,db,names,*' - meaning that the dbs you specified for @Priorities will be restored/tested in the order specified BEFORE all other (non-named) dbs. Otherwise, if you wish to 'de-prioritize' any dbs, you must specify * and then the names of any dbs that should be processed 'after' or 'later'.

**@BackupsRootPath** = N'path-to-folder-acting-as-root-of-backup-files'  
REQUIRED. S4 Restore uses the convention that all backups for a single, given, database should be in a seperate/dedicated folder. As such, you should backup all of your databases to D:\SQLBackups\ and each database's backups are then written into distinct sub-folders. (This is the same convention that S4 Backup uses.)  
DEFAULT = N'{DEFAULT}'.

IF the [DEFAULT] token is used, restore_databases will request the default location for SQL Server Backups by querying the registry for the current SQL Server instance.

**@RestoredRootDataPath** = N'[ folder-you-want-data-files-restored-to | {DEFAULT} ]'  
DEFAULTED. S4 Restore will push (or relocate) .mdf and .ndf file into the path specified by @RestoredRootDataPath when restoring databases (regardless of the original path for these files pre-backup). If you need to try and use different paths for different databases (i.e., you don't have enough space on a specific drive to restore a number of your key databases), you'll need to set up multiple calls/executions against dbo.restore_databases with a different set of @DatabasesToRestore specified - and with different @RestoredRootDataPath (and/or @RestoredRootLogPath) values specified between each different call or execution. 

IF the {DEFAULT} token is used, restore_databases will request the default location for SQL Server Data Files by querying the registry for the current SQL Server instance.
DEFAULT = N'{DEFAULT}'.

**@RestoredRootLogPath** = N'[ folder-you-want-log-files-restored-to | {DEFAULT} ]'  
DEFAULTED. Can be the exact same value as @RestoredRootDataPath (i.e., data and log files can be restored to the same folder if/as needed) - but is provided as a seperate configurable option to allow restore of logs and data files to different drives/paths when needed as well. (Neither approach is necessarily better - and an 'optimal' configuration/setup will depend upon disk capacities and performance-levels.)

IF the {[}DEFAULT} token is used, restore_databases will request the default location for SQL Server Log Files by querying the registry for the current SQL Server instance.
DEFAULT = N'{DEFAULT}'.

**[@RestoredDbNamePattern]** = 'naming-pattern-with-{0}-as-current-db-name-placeholder']  
DEFAULTED. Defaults to '{0}_test'. As any database to be restored is processed, the pattern (or name) specified by this argument will be used for the RESTORED databasename - and if the {0} token is present, then {0} will be replaced with the ORIGINAL name of the database being restored. For example, assume you are restoring a SINGLE database named 'production'. If you specify nothing for this parameter, the restored database will default to 'production_test', whereas if you were to set @RestoredDbNamePattern to 'Fred', the database would be restored as 'Fred'. (Obviously, if you're restoring MULTIPLE databases and specify 'Fred' you'll run into problems IF you've allowed previous 'Fred' instances to exist and/or haven't specified that @AllowReplace should replace each 'Fred' as processed.) Otherwise, if you set @RestoredDbNamePattern to something like 'MayRestoreTestOf_{0}' and process multiple databases - such as Production, Stage, and Testing, you would end up with 3x databases restored as 'MayRestoreTestOf_production', 'MayRestoreTestOf_stage', 'MayRestoreTestOf_testing' - and so on.

Optional. When specified, the value of @RestoredDbNameSuffix will be appended to the end of the name of the database being restored. For example, if you have specified that you want to restore the Billing, Widgets, and Tracking databases (via @DatabasesToRestore) and have specified a @RestoredDbNameSuffix of '_test', these databases would be restored as Billing_Test, Widgets_Test, and Tracking_Test. This option is primarily provided for scenarios where you will be doing 'on-box' restore testing (i.e., running nightly jobs ON your production server and restoring copies of your production databases to make sure the backups are good) - so that you don't have to worry about naming collisions or other issues while running restore tests.  
DEFAULT = N'{DEFAULT}'.


[**@AllowReplace** = [ NULL | N'REPLACE' ] ]  
DEFAULTED. Defaults to NULL. When specified (i.e., when the exact value for this parameter is set to the text 'REPLACE'), if you are attempting to restore, say, the 'Widgets' database and a database by that name ALREADY exists on the server, this command WILL force that existing database to be dropped and overwritten. (And note that even if the 'target' database is in use, dbo.restore_databases WILL kick all users out of the target database, DROP it, and then RESTORE over the top of it.) As such, be sure to use this particular option with extreme caution. Further, note that if you are restoreing the 'Widgets' database and have specified a @RestoredDbNameSuffix of '_test' and a database called Widgets_test exists on your server, that database WILL be overwritten if @AllowReplace is set to N'REPLACE'. 
DEFAULT = NULL.

> ***NOTE:** This parameter is an ADVANCED parameter - designed to facilitate use in scenarios where nightly restore operations are used BOTH to test backups AND push a copy of a production database 'down' to a dev/test server (by means of a restore operation) - which, in turn, is why the option to 'REPLACE' an existing (and even potentially in-use) database exists. Please see the warning below before contemplating and/or using this parameter.*

> ***WARNING:** Please make sure to read-through and thoroughly understand the ramifications of the @AllowReplace parameter before using it in production. Furthermore, you should always 'test out' how this parameter will work out by setting @PrintOnly to 1 whenever you are thinking of using this option - so that you can SEE what execution would, otherwise, do to your system.* 

**[@SkipLogBackups** = [ 0 | 1 ] ]  
OPTIONAL. By default, dbo.restore_databases will find and apply the most recent FULL backup, the most recent DIFF backup (if present), and then all T-LOG backups since the most recent FULL or DIFF backup applied. By setting @SkipLogBackups to 1 (true), dbo.restore_databases will NOT apply any transaction logs. 

This is an advanced option and is really only useful for 'downlevel' situations - or scenarios where you're restoring copies of backups to a dev/test server and do NOT care about verifying that your T-LOG backups are viable (nor do you care about seeing roughly how long they take to restore).   
DEFAULT = 0 (false (don't skip T-LOG backups)).

**[@CheckConsistency** = [ 0 | 1 ] ]  
OPTIONAL. When using dbo.restore_databases to check/validate your backups, you will always want to check consistency - to help verify that no corruption problems or issues have crept into your backups (i.e., into your production databases - where corruption is actually 'copied' into your backups) and/or to ensure that you aren't somehow encountering corruption issues on the RESTORED databases you're creating for testing (as repeated issues with corruption on your restored databases vs the 'originals' would typically indicate a problem with the storage subsystem on your 'failover' or 'test' server - meaning that it likely wouldn't be viable as server for disaster recovery purposes). 

This is an an advanced option, and is really only useful for 'downlevel' situations - or scenarios where you're restoring copies of backups to a dev/test server and do NOT care about verifying the integrity of your backups/restored databases as part of execution.   
DEFAULT = 1 (true).

**[@DropDatabasesAfterRestore** = [ 0 | 1 ] ]   
DEFAULTED. When EXPLICITLY set to 1 (true), once dbo.restore_databases has restored a database specified for restore - and after it has run consistency checks (if specified for execution), it will then DROP the restored (i.e., copy) database to clear-up space for further operations and/or to make subsequent operations easier to configure (i.e., if you execute nightly restore-tests of 3x production databases, check consistency against them, and then drop them (one-by-one - as they're restored then checked), you won't have to worry about setting 'REPLACE' for subsequent executions (i.e., the next night) and you'll be 'cleaning up' disk space along the way as well.) 

This is an advanced option and has a built-in 'fail-safe' in the sense that this option can/will ONLY be applied to databases with a name that was successfully RESTORED during current execution (i.e., DROP commands against a specific database will be checked against a list of databases that were already restored during the CURRENT execution of dbo.restore_databases - and if the db-name specified is not found, it can't/won't be dropped).  
DEFAULT = 0 (false).

**[@MaxNumberOfFailedDrops** = integer-value ]  
OPTIONAL. When @DropDatabasesAfterRestore is set to 1 (true), each database to be restored will be restored, checked for consistency (if specified), and then dropped - before moving on to the next database to restore + test, and so on. If, for whatever reason, dbo.restore_databases is NOT able to DROP a database after restoring + checking it, it will increment an internal counter - for the number of 'failed DROP operations'. Once that value exceeds the specified value for @MaxNumberOfFailedDrops, then dbo.restore_databases will TERMINATE execution. 

This is an advanced option, and is primarily designed to prevent 'on-box' restore tests (i.e., test where you're restoring copies of production databases in a 'side by side' fashion out on your same production servers - usually for licensing purposes) from running your production systems out of disk by 'blindly' just restoring more and more databases in production while not (for whatever reason) 'cleaning up along the way'.   
DEFAULT = 2.

[**@OperatorName** = N'{DEFAULT}' ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.]

[**@MailProfileName** = N'{DEFAULT}' ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.]

[**@EmailSubjectPrefix** = N'Text Here' ]
[This also needs a 'standarized-ish' doc blurb... only, there IS a value here that'll be different per each sproc/etc. (And, eventually, these can/will be changed via dbo.Settings as an option as well - i.e., sproc_name_email_alert_prefix (as the key ... with a specified value)))]

[**@PrintOnly** = { 0 | 1} ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.] 

Defaults to 0 (false). When set to 1 (true), processing will complete as normal, HOWEVER, no restore operations or other commands will actually be EXECUTED; instead, all commands will be output to the query window (and SOME validation operations will be skipped). No logging to dba_DatabaseRestore_Log will occur when @PrintOnly = 1. Use of this parameter (i.e., set to true) is primarily intended for debugging operations AND to 'test' or 'see' what dbo.restore_databases would do when handed a set of inputs/parameters.

[Return to Table of Contents](#table-of-contents)

### Remarks  <a name="remarks"></a>
#### Intended Usage Scenarios

S4 Restore was primarily designed for use in the following automated and ad-hoc scenarios. 
- **Regular On-Box Tests.** For smaller organizations with just one SQL Server, validation of will take place on the same SQL Server as where the backups are taken. To this end, S4 Restore was designed to restore one database at a time (i.e., when more than one database is specified for verification), check it for consistency, log statistics about the duration/outcome of both operations, and then DROP the restored database before proceeding to the next database to test - to avoid running out of disk-space. Likewise, in this situation, if you have a database called "WidgetsProd", S4 Restore enables you to assign a 'suffix' to the name of the database you're restoring (i.e., "_test" - so that you'll restore "WidgetsProd" as "WidgetsProd_test") to avoid any potential concerns with collisions. 
- **Regular Off-Box Tests.** In more complicated environments, backups can/will be created on one server, copied off-box to a shared location (or a location in the cloud), and restore testing can be tackled on a totally unrelated server that is 'linked' to the 'source' server merely by having copies of the backups of the databases from that server - which can be regularly scheduled for testing/restores. In situations like this, it also makes sense to configure S4 to 'drop' databases after restoring them - so that restore tests the next time they're run (i.e., the next day) don't 'collide' with databases 'left behind' after testing. Under this use-case, it's typically not necessary to add a 'suffix' to restored database names (i.e., the "WidgetsProd" database backed up on SERVERA can easily be restored to CLOUDX without any worries about name/database collisions).
- **Regular Development Environment Refreshment.** If developers need to have regularly refreshed copies of production database put into a location where they can then use them throughout the day for dev/testing purposes, S4 Restore is best used with a special, advanced, configuration option that lets it REPLACE existing databases during restore operations. For example, the first time the "WidgetsProd" database is restored to a DEV server it can be restored as "WidgetsProd" (or with a suffix as "WidgetsProd_Nightly" - or whatever else makes sense) and is NOT dropped after restoration (and consistency checks if configured). Instead, the database 'stays around' and is usable by devs until the next time an S4 Restore operation is executed (i.e., each night at, say, 2AM) - at which point the DEV 'copy' of prod is OVERWRITTEN/REPLACED with a fresh copy of the database from PROD. (NOTE, many devs like to keep their dev/working environments a bit 'stale' - or refreshed every few days/weeks/whatever. A BETTER approach, however, is to FORCE a restore of the 'dev' database nightly (from production), which requires developers to keep track of any changes they're working on (over, say, the period of a few days while they're making changes or adding new features) within scripts that they will then run 'each day' against the new/refreshed copy of their dev database - to bring that database 'up to speed' with their changes. Benefits from this approach are that devs have to keep track of all changes, they're re-testing them daily (and will detect any collisions with changes OTHER devs may have pushed into production), really long-running changes are something they're likely to look into changing sooner rather than later (i.e., performance optimizations), and dev changes that get 'put on hold' for weeks on end are easier to both 'pick up' (thanks to 'change scripts') when needed AND deployment is easier because something that a developer changed 3 weeks ago doesn't get 'missed' when deployment of their changes to production are ready.)
- **Smoke and Rubble Disaster Recovery.** S4 Restore can be used for 'smoke and rubble' disaster recovery purposes. Which is to say, if you've got (hopefully up-to-date) off-site copies of your production database backups, you can simply 'point' S4 Restore at the folder containing the backups for one or more databases (each of which needs to be in its own sub-folder - by convention), provide a few parameters, and then let S4 Restore spin-up copies of each specified database as a means of automating the disaster recovery restoration process on new/different hardware from your primary server(s). 
- **Ad-Hoc Restore Operations.** S4 Restore can also be used to quickly 'spin up' the restoration of specified databases for 'quick' recovery or review purposes - or it can also be used as a tool to generate the scripts that would be used to restore a targeted database (or databases) - and then, rather than having S4 execute the commands itself, it will 'spit them out' for you to copy, paste, tweak and execute as desired.

#### Conventions and Concerns
[TODO: move into conventions and/or best-practices documentation.]
S4 Restore was designed to allow regular, recurring, tests of SQL Server Backups - by means of executing full-blown RESTORE operations against targeted databases/backups (or, in other words, the only REAL way to know if backups are valid is to VERIFY them by means of a restore). However, while dbo.restore_databases was designed to make it easy to restore one or more databases on a recurring schedule, there are some concerns, considerations, conventions you will need to be aware of. 
- **Conventions.** S4 Restore is built around the idea that SQL Server backups will be stored in one or more 'root' folders (e.g., F:\SQLBackups or \\\\BackupServer\SQLBackups) where the backups (FULL, DIFF, and T-LOG) are stored in sub-folders per each database. So, if you've got a Widgets database and a Billing database that you're backing up, these would end up in F:\SQLBackups\Widgets and F:\SQLBackups\Billing respectively (or \\\\BackupServer\SQLBackups\Widgets and \\\\BackupServer\SQLBackups\Billing respectively). With this convention in place, dbo.restore_databases does NOT 'interrogate' each backup file found per database-sub-folder. Instead, it relies upon the naming conventions defined within S4 Backup (of [Type]_name_info.[ext] - where [Type] is the text FULL, DIFF, or LOG (depending upon backup type) and [ext] is the extension (.bak for FULL/DIFF backups and .trn for LOG backups) + timestamps associated with the files to determine which (i.e., the most recent) FULL + DIFF (if any) backups to restore and then which T-LOG backups to restore from the most recent FULL and DIFF (if present). In short, if you use S4 Backup, then S4 Restore will work just fine and without issue (i.e., just 'point it' at the folder(s) containing your SQL Server backups - that you wish to restore) - whereas if you're using other solutions for backups, you may need to 'tweak' those (or dbo.restore_databases) to enable naming conventions that will work as needed.
- **Recurring Execution.** S4 was designed to be run daily (or even more frequently if needed) to help ensure that backups are valid (by restoring them). This means that if you schedule exection of Restore Operations nightly (a best-practice), then you'll either have to DROP each database after it is restored + tested/checked each night or, you'll have to specify that databases with names matching those that you'll be restoring are dropped and then OVERWRITTEN on subsequent executions (i.e., the next days). Typically, specifying that you want to explicitly DROP + OVERWRITE a database is a 'spooky' proposition. In fact, this option is only provided in S4 Restore to address down-level dev-restore operations - and is accomplished via the @AllowReplace parameter. Otherwise, see the [Intended Usage Scenarios](#scenarios) section of this document for info on how @DropDatabasesAfterRestore is a BETTER option for nightly restore tests - as it restores databases (checks them if specified), and then drops them before proceeding to the next database to restore (both cleaning up disk space/resources AND making it so you don't have to use the @AllowReplace parameter - which is a non-trivial parameter).


#### Additional Warnings about the @AllowReplace Parameter

In addition to the warnings specified in the [Syntax](#syntax) section of this document, the primary worry or concern about using the @AllowReplace parameter is that SysAdmins who might, otherwise, be inclined to use copy + paste + tweak semantics to modify a job or create a new restore/test job from an existing job MIGHT inadvertently copy from a job where this value is set to 'REPLACE' - which could mean (if someone is not paying attention), that a job could be accidentally set up to DROP running production databases and replace them with restored 'copies' of the database that do NOT include TAIL-END-OF-THE-LOG backups (i.e., you would 100% be missing transactions in this scenario - in addition to incurring potentially significant down-time). 

In short, only use the @AllowReplace parameter for down-level Development Refresh scenarios and ONLY when you're very confident of what can/will happen with the parameters you've specified.

#### Order of Operations During Execution
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
- Once processing of all databases in @DatabasesToRestore is complete, dbo.restore_databases will send an email to @OperatorName if any problems or issues were encountered along the way. 

#### Considerations for Copying Production Databases into Development
While it is a best-practice to provide developers with development, testing, and staging environments that exactly match those of production, there are two primary considerations that should always be addressed when regularly copying production databases 'down-level' into development, testing, or staging environments:
- **Security of Sensitive Data.** If Production Databases contain sensitive data, a common technique for dealing with this is to a) restore copies of backups into dev/testing, and then b) run scripts to 'scramble' data after it has been restored (i.e., typically during early morning or when devs aren't typically active). However, for highly sensitive data (i.e., some forms of HIPAA or PCI data) it's important to call out that 'scrambling' data may NOT be enough (scrambling may make data 'unreadable' to the casual observer, but hackers CAN in some cases easily figure out how values were 'shifted' and/or they can also use relationships between some types of 'scrambled' data and publically accessible info to 'reconstitute' sensitive PII in many cases. As such, scrambling MAY not be enough protection (in which case you'll need a different solution - i.e., simulated dev/test/staging environments with 100% bogus data that still a) exactly matches the schema and code found in production and b) has similar cardinality and distribution details as in prod for perf-testing needs). Otherwise, in some other cases - where scrambling MAY be enough, you MIGHT need to a) Backup on production, b) restore to a staging environment (that only restricted users (DBAs) have access to), c) scramble the data THERE, and then d) back it up from staging, and e) restore to dev/test environments - to avoid the potential for a restore to happen, but a 'script error' during 'scrambling' to leave sensitive unscrambled to devs. (And, while you might think your devs don't care about being exposed to sensitive info, the reality is that exposing honest devs to sensitive info means that they can then, potentially, be accused of STEALING that info if/when it is found to have gone missing - so you're NOT doing them any favors if you think the occasional failure or hiccup won't be a big deal - because you're exposing them to significant, potential, liability and accusations.)
- **Ensure Proper Sequestration of Environments.** When Dev (and/ore Staging + Testing) Environments mirror those of production, **MAKE SURE** that you are not using the same credentials (logins + passwords - or Windows Accounts) to allow access to dev/testing environments and production. Ideally, Production should be in its own Domain, and dev/testing/staging environments should be in different domains - meaning that if your applications and services are using Integrated (Windows) authentication, you should be using logins like PROD\WebServerX to access prod and DEV\TestWebServerX to access dev databases. Or, if you're using SQL Server Auth for your applications/services, make sure to fully distinguish login names and use ENTIRELY different passwords - i.e., WebAppXX_PROD for production access and WebApp_DEV for dev access. **FAILURE to follow this convention can result in situations where devs or sysadmins copy/paste configuration and connection info from one environment to the next, FORGET to 'repoint' a connection string from production to dev, and then allow devs to 'go to work' against a PRODUCTION system - without realizing they're making changes in production.**

[Return to Table of Contents](#table-of-contents)

### Examples <a name="Examples"></a>
[TODO: some of these details should PROBABLY end up in the RESTOREs.md doc for best-practices.]

#### A. Configuring a Simplified Execution.
The following example showcases a simplified execution of S4 Restore:

```sql
EXEC admindb.dbo.restore databases 
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

#### B. Simplified Execution - Dropping Databases after Restore + Checks
The following execution is, effectively, identical to Example A - except that the Billing_test and Widgets_test databases will be dropped AFTER being restored and AFTER checked for consistency (i.e., if backups are found for the Billing database, they'll be restored as the Billing_test database, the Billing_test database will be checked for consistency, and after that check is complete, dba_RestoreDatabases will DROP Billing_test, then start working on processing backups for the Widgets database, and so on).

```sql
EXEC admindb.dbo.restore databases 
    @DatabasesToRestore = N'Billing,Widgets', 
    @BackupsRootPath = N'\\server\path-to-backups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'L:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test', 
	@DropDatabasesAfterRestore = 1;
```

Note that @DropDatabasesAfterRestore DEFAULTs to 0 (false), but you'll usually want it set to 1 (true) for most automation scenarios (i.e., to 'clean-up' for subsequent operations (the next day) and to avoid 'burning up' disk space in some environments). 

#### C. Configuration for Nightly, On-Box, Tests of Production Databases.
Assume you've got a Hosted SQL Server with 4x production datababases: db1, db2, db3, and PriorityA. You've scheduled regular backups with S4 Backup, and are regularly (i.e., every 10 minutes), copying backups to the Cloud - but you want to make sure your backups are viable. To do this, you don't have an other SQL Server, so you'll need to restore databases on the SAME server where the backups are taken (i.e., out on production SQL Server). To do this, you obviously can't overwrite your production databases - so you'll need to restore, say, PriorityA as something else (like PriorityA_test). Further, while db1, db2, and db3 each are roughly 20GB in size, PriorityA is, let's pretend, 200GB in size - and you currently only have around 300GB of 'free' disk space on your server. That's technically enough to restore copies of everything - but, then you'll be hitting a point where you've only got 40GB of free space. Happily, S4 helps address this via the @DropDatabasesAfterRestore - meaning that each database will be restored, checked, then dropped - so that the 'max' amount of disk used while running restore tests against all databases will be just 200GB (i.e., the size of your largest database). Further, in situations where you may have MORE databases to check than free space (i.e., multi-tenant solutions where you might have 200 databases of different sizes - all of which might weigh in at 1TB but where you only have .5TB of 'free space'), the @MaxNumberOfFailedDrops will prevent restore operations from running you out of disk if you somehow restore multiple (larger-ish) databases but, somehow, aren't able to get them to DROP after they're tested (i.e., execution will continue after failure to DROP databases but ONLY until the @MaxNumberOfFailedDrops value is exceeded). 

In such a scenario, you'd spin up something similar to the following - and configure it to run (via a SQL Server Agent Job) at, say, 3AM every morning: 

```sql
EXEC admindb.dbo.restore databases 
    @DatabasesToRestore = N'PriorityA,db1,db2,db3', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'D:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1;
```

[TODO... finish documenting the above details... ]

#### D. Nightly, Off-Box, Restore Tests.
Assume you've got multiple SQL Servers, each with different databases - used for various purposes. Then assume you've got a server where you can run backup tests (this could be one of your 'less loaded' production servers, a specifically configured 'restore server' that MIGHT be used as a failover/contingency server (as a CYA option in cases where HA options/solutions somehow don't work as expected, or whatever) - where you can regularly (i.e., nightly) test your backups. 

Then assume that for each production server, you've got a 'backup-target' server - with sub-folders for each server/host - to put its own databases into. So, that, for example, you've got backup folders out on your 'backup server'/UNC share that look similar to the following: 
- \\\\backup-server\ClusterA\
- \\\\backup-server\ProdC\
- \\\\backup-server\PigPile\

Assume that ClusterA has mission-critical databases deployed to it, ProdC has important databases, and PigPile has various smaller (i.e., 3rd party and 'departmental'/internal) dbs. Further, assume that PigPile has TBs of storage - i.e., enough to run restore checks of all production databases. To accomplish restore tests of backup from ALL 3 different servers, you'll need 3x different/distinct jobs (as dba_RestoreDatabases, by convention, only searches for backups in @BackupsRootPath + '\' + db_name for backups - and can't, therefore, be configured to just use \\\\backup-server\ as the 'root' path). While this might initially seem like a pain, this actually comes with one significant (by design) benefit - which is that you can customize the subject of the email Subject you'll get when problems/issues occur during restore operations - from one server to the next. 

To address this scenario/need, you'd spin up 3x distinct calls to dba_RestoreDatabases - as follows: 

```sql
-- Restore Operations for ClusterA:
EXEC admindb.dbo.restore databases 
    @DatabasesToRestore = N'Inventory,Catalog,Sales,Support', 
    @BackupsRootPath = N'\\\\backup-server\ClusterA\', 
    @RestoredRootDataPath = N'N:\Nearline-Restore\', 
    @RestoredRootLogPath = N'N:\Nearline-Restore2\', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1, 
    @EmailSubjectPrefix = N'!!Cluster Restore Tests - ';


-- Restore Operations for ProdC:
EXEC admindb.dbo.restore databases 
    @DatabasesToRestore = N'AccountingTools,ERPNNS,db2,db3', 
    @BackupsRootPath = N'\\\\backup-server\ProdC\', 
    @RestoredRootDataPath = N'N:\Nearline-Restore\', 
    @RestoredRootLogPath = N'N:\Nearline-Restore2\', 
    @RestoredDbNameSuffix = N'_test', 
    @DropDatabasesAfterRestore = 1, 
    @EmailSubjectPrefix = N'Prod Restore Tests - ';


-- Restore Operations for PigPile:
EXEC admindb.dbo.restore databases 
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

#### E. Restoring Copies of Production Databases to Dev Environments
In this example, we'll assume that the Tribeca database is a key production database that needs to be copied 'down' to a dev server nightly. In this case, we DO NOT want to 'drop' databases after they're restored, and we also want to let developers know that this is a regularly refreshed copy of the database - so we'll append the word "NightlyDev" to this database as part of the restore process:

```sql
-- Restore Operations for ClusterA:
EXEC admindb.dbo.restore databases 
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

#### F. Using S4 Restore For Disaster Recovery
While Fault Tolerance (i.e., Mirroring, Availability Groups, or a Failover Cluster Instance) are the best ways to protect against down-time, there can be situations where you might need to recover one or more databases 100% from backups - which can be easily facilitated by S4 Restore (even though support for this need is NOT a substitute for Highly Available/Fault-Tolerant systems or other types of Disaster Recovery planning and contingencies).

***WARNING:** Whenever you're trying to recover production databases (in a disaster recovery scenario) 'purely' from backups, you want to do everything possible to try and obtain a 'tail-of-the-log' backup - or capture any/all transactions in your Transaction Log that have NOT been backed up since your last (successful) Transaction Log backup. Otherwise, if you FAIL to execute these backups (when they are possible) you run the risk of losing data (or having a terrible time manually pushing it 'back into place after the fact' IF you managed to (later on) recover this data). So, always try to execute (and then copy or make-available) any 'tail-of-the-log' backups to S4 Restore BEFORE you start using S4 Restore for recovery purposes.*

In the following example, we'll assume that a Startup company had a hosted SQL Server with 3x databases needed for their application - that they were executing regular backups (i.e., FULL backups nightly and T-Log backups of all 3 databases every 5 minutes) - and that these backups were being pushed up to 'the cloud' every 5 minutes (i.e., being copied off box). Then, for whatever reason, we'll assume that a major disaster occured - not only did their hosting company have a serious crash that resulted in the loss of the Virtual Server this company was using, but it's going to take 20+ hours for them to have something 'in place' for recovery. As such, this startup decides to provision a new server with a different hosting compay, copy/deploy their apps and such and then copy down the backups 'from the cloud' into a folder called D:\RestoredCloudBackups\SQL (where there will be a sub-folder for each of the 3x different production databases) and they're now ready to spin up restore operations of their databases - to bring them into production. To do this, they would run something similar to the following: 

```sql
EXEC admindb.dbo.restore databases 
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

#### G. Using S4 Restore for Ad-Hoc Restore Operations or to Generate Restore Statements
If you'd like to see what S4 Restore will do against a particular set of commands - without having those commands executed, simply flip the @PrintOnly parameter to 1 (true) and execute dba_RestoreDatabases after specifying whatever parameters are needed. For example, the code below is effectively identical to that in Example A, but because @PrintOnly is specified, dba_RestoreDatabases won't actually execute any code, but will - instead - simply 'spit out' the commands it would have (otherwise) executed:

```sql
EXEC admindb.dbo.restore databases 
    @DatabasesToRestore = N'Billing,Widgets', 
    @BackupsRootPath = N'\\server\path-to-backups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'L:\SQLLogs', 
    @RestoredDbNameSuffix = N'_test'
    @PrintOnly = 1;
```

Use of the @PrintOnly command can be helpful for troubleshooting and/or testing (i.e., to see what commands would be issued when using more advanced commands like @AllowReplace) - or it can be used to generate a set of statements that you could then copy + paste + tweak to suit any specific needs you might have (i.e., like a Point In Time Recovery Operation - which is NOT supported by S4 Restore).

[Return to Table of Contents](#table-of-contents)

### See Also
- [TODO:] [best practices for such and such]()
- [TODO:] [related code/functionality]()

[Return to Table of Contents](#table-of-contents)

[Return to README](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedPath=README.md)

<style>
    div.stub { display: none; }
</style>