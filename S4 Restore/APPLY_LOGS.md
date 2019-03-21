# S4 Apply Logs
S4 Apply Logs was designed for two primary purposes: 
- to streamline and simplify SQL Server Log Shipping as well as 
- help simplify the process of either mirroring databases or putting them into Available Groups. 

**NOTE:** *S4's dbo.apply_logs relies VERY heavily upon other/existing S4 conventions - to the point where this stored procedure can only be used in conjunction with backups restored by S4's dbo.restore_databases.* 


## Table of Contents 
- Intended Usage Scenarios
- Syntax
- Remarks
- Examples

## Intended Usage Scenarios 
S4 Apply Logs functionality is intented to be used in conjunction with both: 
- **dbo.backup_databases** - which creates and stores backups according to naming conventions used by S4 functionality)
- **dbo.restore_databases** - which 'initializes' databases into a RESTORING (i.e., NON-RECOVERED) state, such that additional Transaction Log Backups can be applied when or as needed - and which also LOGS T-LOG meta-data into the dbo.restore_log table to enable 'vectoring' for additionally applied files processing.

### Use dbo.apply_logs to:
- Vastly simplify the process of 'seeding' databases for mirroring (or for manual setup prior to enlisting within Availability Groups) - especially when attempting to 'seed' or mirror multiple databases more or less concurrently.
- Facilitate on-site or off-site 'Log Shipped' DR servers. After initializing databases for 'log shipping' needs, execution of dbo.apply_logs can be configured within a SQL Server Agent job to periodically check for and apply logs - as well as raise alerts when logs have not been applied within a specified time-frame. 
- Enable STANDBY Reporting Servers by allowing log-shipping processes to be automated while also enabling databases to be dropped into STANDBY mode when logs are NOT being applied. (As logs are being applied, any/all users in the STANDBY database will be kicked-out so that T-LOG backups can be applied.)

**NOTE:** *Off-site log-shipping will obviously require some sort of file-copy/synchronization process to copy/move files from backup locations at the primary site to the secondary site. Assuming network connectivity, this process can be easily tackled with Windows Distributed File System Replication, scripted/scheduled file-copy operations, or even managed by means of 3rd party solutions including things like Dropbox and any other file-synchronization/delivery tools. dbo.apply_logs does NOT address these file copy operations and assumes they'll be handled prior to requests to apply_logs.* 

## How it Works
dbo.apply_logs needs to be configured with the root-path for where SQL Server backups can be restored - using S4 conventions (i.e., a root folder for backups, with a sub-folder defined for each distinct database - with all backups belonging to each distinct database being stored in its respective folder). Once executed, dbo.apply_logs will determine which databases it has been directed to apply logs against, then check their 'backup folders' for log files that can or could be applied. Any new T-LOG backups that have 'appeared' in the backups folder since the last successful application of T-LOG backups previously will then be restored - in order, against their respective database or databases. Errors along the way will be logged and alerts will then be sent to specified operators - while subsequent calls/attempts to execute dbo.apply_logs will then keep RETRYING any files that haven't been applied. Upon successful application of logs, dbo.apply_logs will drop meta-data about which files have been applied in the admindb.dbo.restore_log table - so that future log application attempts/executions won't attempt to restore logs that have already been applied.

**NOTE:** *This is slightly different than how SQL Server's 'native log shipping works' - as SQL Server's approach will copy/move T-LOG files from one directory to another as a means of keeping 'track' of which files have been applied - whereas dbo.apply_logs uses meta-data stored in the admindb.dbo.restore_log instead.* 

## Syntax 

```sql
EXEC admindb.dbo.[apply_logs]
    @SourceDatabases = N'{ list,of,db-names,to,apply-logs-against }', 
    [@Priorities = N'higher,priority,dbs,*,lower,priority,dbs, ]
    @BackupsRootPath = N'{ \\server\path-to-backups | [DEFAULT] }', 
    @TargetDbMappingPattern = N'{ {0} | {0}_shipped, {0}_etc }, 
    [@RecoveryType = N'{ NORECOVERY | STANDBY | RECOVERY }',]
    [@StaleAlertThreshold = N' integer_value + s | m | h | d specifier ', ]
    [@AlertOnStaleOnly = { 0 | 1 }],
    [@OperatorName = N'Alerts', ]
    [@MailProfileName = N'General', ]
    [@EmailSubjectPrefix = N'[APPLY LOGS] - ',] 
    [@PrintOnly = { 0 | 1 }]
```

Arguments

**@SourceDatabases** = N'comma,delimited, list-of-db-names, to target, for log application'

REQUIRED. A comma-delimited list of the names you would like to have T-Log applied against. For example, if @SourceDatabases were set to the value N'Widgets, Accounting, Inventory', then dbo.apply_logs would attempt to find and apply logs for databases named Widgets, Accounting, and Inventory in the @BackupsRootPath directory (i.e., in specific sub-folders per each database). 

Spaces between comma-delimited database names are optional and will be ignored. 

**NOTE:** *While dbo.restore_databases will allow the [READ_FROM_FILESYSTEM] token to dynamically determine which databases to attempt to restore, dbo.apply_logs does NOT allow this token - and databases to be targetted for T-LOG application must, therefore, be explicitly named or defined within @SourceDatabases.*

[**@Priorities** = { 'higher, priority, dbs, *, lower, priority, dbs' } ]

Optional. Allows specification of priorities for the order in which T-LOG backups should be applied when multiple databases are being processed. The * is a token/symbol representing the databases specified in @SourceDatabases - and ordered alphabetically. Database names explicitly defined before the * token will be processed first (in order of specification), and any defined after the * token will be processed last (in order of specification). For example, assume that @SourceDatabases is set to N'dbA, dbC, dbD, dbK, dbN, dbR, dbX'. If @Priorities is NOT specified, the databases listed in @SourceDatabases will be processed in alphabetical order. However, suppose that dbX is a priority database, and that dbD and dbC are lower-priority databases. If @Priorities is set to N'dbX, *, dbD, dbC', then the processing order for T-LOG backup application will be against the dbX database first, then against all databases specified in @SourceDatabases but NOT explicitly defined in @Priorities - in alphabetical order (e.g., dbA, dbK, dbN, dbR), and then the lower-priority databases specified after the * token - in order of specification - i.e., dbD second-to-last, and dbC processed last. 

**@BackupsRootPath** = 'path-to-location-of-folder-containing-sub-folders-with-backups-of-each-db'

Required. Default value is set as N'[DEFAULT]' - indicating the specialized S4 token representing that dbo.apply_logs should look in the 'default' backups folder specified by the current SQL Server instance where code is being executed. 

If the [DEFAULT] is not specified, @BackupsRootPath must be a viable path pointing to the ROOT directory where sub-folders (per each database to be processed) are defined and 'loaded' with T-LOG backups to be applied. 

**@TargetDbMappingPattern** = N'naming-pattern-with-{0}-as-sourcedb-name-placeholder'

Required. {0} is a token representing the name of the SOURCE database being restored. So, if @SourceDatabases was set to N'dbN, dbX', and @TargetDbMappingPattern was set to N'{0}', then dbo.apply_logs will look for log files FROM the dbN that can be applied to a database called dbN that is currently in RESTORING or STANDBY mode - and then do the same for dbX. However, if @TargetDbMappingPattern were, instead, set to N'{0}_shipped', then dbo.apply_logs would STILL look for backups from the dbN and dbX folders/databases (i.e., Source databases) - but would only attempt to try and restore them to databases in the RESTORING/STANDBY state with the names of dbN_shipped and dbX_shipped ONLY. 

***NOTE:** The token {0} does not have to be used (when you are processing operations against a single datbase). For example, assume that @DatabasesToRestore is set to N'Widgets', you could then specify the value of N'CandyCanes' for @TargetDbMappingPattern and dbo.apply_logs would look for T-Log backups for/from the Widgets database and ONLY attempt to apply those to a database named 'CandyCanes' - if it were found in the RESTORING/STANDBY state. (Note, of course, that if you were trying to process multiple databases in this fashion, the hard-coded value specified would clearly cause problems - hence the need for an {0} token or place-holder.)*

[**@RecoveryType** = N' { NORECOVERY | STANDBY | RECOVERY } ']

Optional. Defaults to NORECOVERY. 

Defines what state databases specified in @SourceDatabases should be left when processing is complete (REGARDLESS of whether log files were found and/or applied).

**NORECOVERY** - allows additional T-LOG backups to be applied and/or enables databases to be enlisted in Mirroring Sessions or Availability Groups. 

**STANDBY** - also allows for additional T-LOG backups to be applied, but also leaves the target database in read-only (STANDBY) mode - allowing reporting and other read-only access. (NOTE that when new/additional T-LOG backups need to be applied, any users/logins in the target database will be evicted to allow new transactions to be applied to the target database; once application of logs is complete, dbs targetted with the @RecoveryType of 'STANDBY' will be put back into STANDBY/read-only mode.)

**RECOVERY** - completes the restoring process (no more T-LOG backups may be applied and databases may no longer be added to Mirroring/AG sessions) - and kicks-off the RECOVERY process - which rolls all non-completed transactions out of the target database, verifies that all completed transactions have been consistently/durably applied, and then brings the target database online for active use (read/write).


**WARNING: *Specifying an @RecoveryType of 'RECOVERY' will cause targetted databases to be RECOVERED - or brought OUT of a state where additional T-Log backups can be applied - meaning that target databases will not be able to participate in log-shipping or act as read-only standby servers anymore. Likewise, RECOVERED databases cannot be 'joined' to Mirroring sessions or Availability Groups.***

[**@StaleAlertThreshold** = N'{ integer_value + s | m | h | d specifier }'',]

Optional. Defaults to NULL. 

When set to NULL, 'stale alerts' will NOT be handled or raised. 

Otherwise, this parameter defines how long data in the databases being processed can 'go' without having T-LOG data successfully applied BEFORE warnings will be raised. Time allowed before a database is considered stale is specified by means of a specific, integer, value + the corresponding specifier for s[econds], m[inutes], h[ours], or d[ays] desired (e.g., N'3h' would represent 3 hours, whereas 195s would represent 195 seconds).

[**@AlertOnStaleOnly** = { 0 | 1 }]

Optional. Defaults to 0. 

When set to true, dbo.apply_logs will NOT send alerts if/when errors are encountered during execution UNLESS the @StaleAlertThreshold has ALSO been triggered. Likewise, even if there are NO errors but the @StaleAlertThreshold has been reached/triggered, then alerts will be raised. The purpose of this functionality is to optionally avoid any/all minor hiccups or errors that can/will occassionally happen when applying transaction logs - while still allowing admins to make sure that data is not 'getting stale' because of either failures during the apply process OR due to a failure to create and/or copy/move databases to a location where the secondary can apply them.

[**@OperatorName** = 'sql-server-agent-operator-name-to-send-alerts-to' ]

Defaults to 'Alerts'. 

If 'Alerts' is not a valid Operator name specified/configured on the server, dbo.apply_logs will throw an error BEFORE attempting to apply logs. Otherwise, once this parameter is set to a valid Operator name, then if/when there are any problems during execution, this is the Operator that dbo.apply_logs will send an email alert to - with an overview of problem details.

[**@MailProfileName** = 'name-of-mail-profile-to-use-for-alert-sending' ]

Deafults to 'General'. If this is not a valid SQL Server Database Mail Profile, dba_DatabaseBackups will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during backups.

[**@PrintOnly** = { 0 | 1} ]

Optional. Defaults to 0. 
When set to true, dbo.apply_logs will NOT execute any of the commands it would normally execute during processing. Instead, commands are printed to the console only. This optional parameter is useful when attempting 'what if' operations to see how processing might look/behave (without making any changes), and can be helpful in debugging or even some types of disaster recovery scenarios.

## Remarks 

### Licensing

As of SQL Server 2012 and above, the use of Software Assurance (SA) licensing and Service Provider Licensing Agreement (SPLA) licensing allows for a 'buy one, get one free' approach to SQL Server licensing - assuming that the 'free' license you get or apply is 
- used ONLY as a failover/fault-tolerant secondary server (i.e., disaster purposes only - and it doesn't matter if you're devoting this license to a log-shipping solution, mirrored/AG'd solution, or a Failover Clustered Instance BUT you can't use this 'free'/failover license on more than 1 host).
- the Secondary/Failover server has equal-to or LESS-than hardware and 'capacity' available to it than the Primary. 
- No reporting, off-loading, or other types of usage (other than DR/DR-testing) can be done on the 'free' server/license. 
- If you failover to this secondary and/or opt to bring it into production, you must then remove the load from your previous primary (i.e., it's now the secondary), OR fully license this new server within 30 days if you are no longer using this box (or a combination of 2 boxes) for solely primary/failover usage. 

Translation: 
- If you're using dbo.apply_logs for failover/log-shipping and/or other DR-related purposes - just make sure you're not using > 1 'free' or failover license total for each licensed server in operation.
- If you're going to use dbo.apply_logs to provide reporting or other off-load operations, this is a scale-out usage and will require a dedicated SQL Server license for the target server (at which point, you'll pick up a new 'free' license to apply elsewhere if/when using SPLA or SA licenses). 

### Complexity

Log shipping involves a moderate amount of complexity. Backups on/from the primary database have to be happening at regular/scheduled intervals, T-Log backup files will usually need to be moved from one server to another, and the 'application' of logs is therefore dependent upon multiple processes to work in conjunction and without any 'hiccups' to consistently remain effective. 

dbo.apply_logs attempts to account for this by making 'apply' operations idempotent (thanks to how SQL Server Log files can be applied multiple times without problems/issues) and by enabling users of dbo.apply_logs to set up alerts/notifications for different types or instances of failure. Consequently, if there is a slight to moderate degree of 'inconsistency' or a few too many 'hiccups' with the processes involved in getting files or applying files to the secondary, you may want to (after verifying that T-Log backups are happening correctly on your primary and are not being compromised), configure executions of dbo.apply_logs to only allow if/when a certain amount of time has passed since the LAST successful application of logs - via the **@AlertOnStaleOnly** parameter (in conjunction with the **@StaleAlertThreshold** parameter to specify the amount of time tolerated before a target database is considered stale (out of sync) or potentially in danger of violating SLAs).

## Examples

***NOTE:** In the following examples, it is assumed that all backups (FULL/DIFF and T-LOG) will be stored in the D:\SQLBackups folder - on all secondary/target servers. (S4's dbo.backup_databases can copy backups from one box to another but if that can't be used or you're pushing backups between environments or off-site, you'll need to find/create another mechanism that allows the secondary to have access to up-to-date backups copied from production for execution to work (and, of course, the path to these backups in your environment may obviously be different)).*

NOTE: All uses of dbo.apply_logs will require a target database that has already been put in either a NORECOVERY (i.e. 'restoring') or STANDBY status. Further, owing to conventions used for the tracking of which T-LOG backup files have been applied, dbo.apply_logs requires that database that will be targeted for log-application MUST be initially put into the NORECOVERY state by means of executing dbo.restore_databases (so that there's a clear indication in S4 logs/history of where LSNs for this target database start).

### A. 'Seeding' a single database for mirroring or participation in an Availability Group

In the following example, dbo.restore_backups is used to start the process of seeding a database - with the assumption that the restore process itself will take a long-enough amount of time that the 'target' and source will be 'out of sync' with each other enough that Mirroring or AG enlistment cannot be done without the application of additional logs. (Though, just note that dbo.restore_databases will continue to look for and apply logs when restoring databases so, typically, when 'seeding' a single database, the use of dbo.apply_logs should not, normally, be needed. Or, in other words, the example below is slightly contrived to help showcase an 'easy' usage of dbo.apply_logs.)

To initiate the process, a new database will need to be spun up, have all available logs applied, and be left in the NORECOVERY state, as per the following example: 

```sql
EXEC [admindb].dbo.[restore_databases]
    @DatabasesToRestore = N'LargeDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'D:\SQLLogs',
    @RestoredDbMappingPattern = N'{0}', 
    -- @AllowReplace = N'', 
    @SkipLogBackups = 0, 
    @ExecuteRecovery = 0, 
    @CheckConsistency = 0, 
    @DropDatabasesAfterRestore = 0, 
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General';
```

Important details about the example above:
- @RestoredDbMappingPattern has been set to '{0}' (this is actually the default so not necessary other than instructive purposes here) - meaning that the database named 'LargeDB' will be restored on the current/target server with the exact-same name (i.e., 'LargerDB') - as will be needed to enable Mirroring or participation in an AG. 
- @SkipLogBackups has been set to 0 - or false (we want all T-Log backups available applied to this database as part of the restore/setup process). 
- @ExecuteRecovery has been set to 0/false - meaning the database will NOT be brought online (recovered) after the restore process is complete. This is essential, as a database can only have log-files applied when in the NORECOVERY mode (or when in STANDBY mode). 
- @CheckConsistency has been set to 0/false - there's no way we could check the consistency of this database if it hasn't been restored. 
- @DropDatabasesAfterRestore has been set to 0/false. Because dbo.restore_databases can be used for testing, it provides the option to drop databases after they've been used for restore / validation operations as an optional way to save space on 'test' servers. 


Assuming successful completion of the above, subsequent T-LOG backups (i.e., those created after the database above has been restored (but not recovered) on the target server) can be applied using a command similar to the following: 

```sql
EXEC [admindb].dbo.[apply_logs]
    @SourceDatabases = N'LargeDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @TargetDbMappingPattern = N'{0}, 
	@RecoveryType = 'NORECOVERY', 
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General', 
    @EmailSubjectPrefix = N'[ApplyLogs - LargeDb] ';
```

In the example above, dbo.apply_logs will attempt to apply logs against a database with the name of 'LargeDB' (i.e., as per the @TargetDbMappingPattern of '{0}') - but only with T-LOG backups from 'LargeDB' (i.e., the @SourceDatabases value) - and only from T-Log backups found by looking in the sub-folders found in D:\SQLBackups (by means of S4 conventions). 

Likewise, the 'target' database will NOT be recovered (i.e., @RecoveryType = N'NORECOVERY') - meaning that additional T-LOG backups could be applied later OR that this database could then be enlisted in a mirroring session or AG within the next few minutes of so. 


### A. 'Seeding' multiple databases for Mirroring or AGs

Following on the previous example, a more realistic use of dbo.apply_logs would be a scenario where you needed to 'seed' multiple databases for enlistment in either a mirroring session or an availability group. (Where the idea is that if you are restoring, say, 4 databases the first restored database may have grown cold/stale by the amount of time that it takes to restore subsequent databases - to the point where dbo.apply_logs is being used to 'top-off' or 'update' transactional activity on the target databases so that they can all be brought into Mirroring\AGs with less manual effort.)

Restoring Multiple Databases: 

```sql
EXEC [admindb].dbo.[restore_databases]
    @DatabasesToRestore = N'widgetDB, LargeDB, supportDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'D:\SQLLogs',
    @RestoredDbMappingPattern = N'{0}', 
    -- @AllowReplace = N'', 
    @SkipLogBackups = 0, 
    @ExecuteRecovery = 1, 
    @CheckConsistency = 0, 
    @DropDatabasesAfterRestore = 0, 
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General';
```

In the code above, the only thing that has changed from the previous example is the number of databases to be restored - meaning that when this process is completed, there will be three 'new' databases on the target server - all in the 'restoring' (NORECOVERY) state: widgetDB, LargerDb, and supportDB). 

From this point, logs can be applied to all 3 databases via the following command:

```sql
EXEC [admindb].dbo.[apply_logs]
    @SourceDatabases = N'widgetDB, LargeDb, supportDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredDbNamePattern = N'{0}', 
	@RecoveryType = 'NORECOVERY', 
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General', 
    @EmailSubjectPrefix = N'[ApplyLogs ] ';
```


At which point, all 3 databases should now be sufficiently 'synchronized' to allow them to be added to Mirroring Sessions or Availability Groups as needed.

### C. Setting up a luke-warm backup (i.e., Log Shipping)
In the following example, widgetDB, LargeDB, and supportDB will be 'shipped' to a secondary/offsite server for DR purposes. 

This will start (on the off-site/secondary) server with the exact same commands from the example above: 


```sql
EXEC [admindb].dbo.[restore_databases]
    @DatabasesToRestore = N'widgetDB, LargeDB, supportDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'D:\SQLLogs',
    @RestoredDbMappingPattern = N'{0}', 
    -- @AllowReplace = N'', 
    @SkipLogBackups = 0, 
    @ExecuteRecovery = 1, 
    @CheckConsistency = 0, 
    @DropDatabasesAfterRestore = 0, 
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General';
```

Which will leave all 3 databases in a state where they can have additional logs applied. Application, in turn, will look almost identical to the 'seeding' example above - with some key changes made: 

```sql
EXEC [admindb].dbo.[apply_logs]
    @SourceDatabases = N'widgetDB, LargeDb, supportDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredDbNamePattern = N'{0}', 
	@RecoveryType = 'NORECOVERY', 
	@StaleAlertThreshold = N'21m', 
    @AlertOnStaleOnly = 1,
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General', 
    @EmailSubjectPrefix = N'[Offsite DR Copies ] ';
```

The specific changes made above are:
- the @EmailSubjectPrefix has been changed - to something that will be better suited to providing a better subject-line when alerts are raised indicating problems with the 'offsite' DR dbs. 
- The @StaleAlertThreshold has been added and set to the value of 21m[inutes] - meaning that in addition to providing alerts if/when there are problems during log application, dbo.apply_logs will now make sure that backups applied against these offsite databases have not, somehow, 'stopped' or become busted (in terms of either being created or being synchronized to the off-site location) such that if an applied T-Log backup wasn't created at least 21 minutes ago, a 'stale warning' will be raised and sent. 
- The @AlertOnStaleOnly parameter has been set to true. This overrides normal/default behavior that will alert when any problems (errors) are encountered when attempting to apply Transaction Logs on the 'secondary' databases - meaning that these errors won't be raised and won't cause 'noise' if/when there are occasional hiccups with, say, an execution here or there - but which get 'resolved' the next time the code was run (i.e., maybe there was an error reading a T-LOG file because it was actually being WRITEN to the box when dbo.apply_logs tried to use it, etc.). However, if a series of failures continue - while no alerts will be raised for those alerts, DBAs will be notified if/when a log hasn't been successfully applied in at least 21 minutes. And, when this alert is sent it will NOT strip any error info but will, instead, simply include the stale-warnings and then append/attach information about any errors that may have occurred. 

#### Automation
With the above apply_logs commands defined, the next step would be to create a SQL Server Agent Job on the offsite/secondary box that runs say, every 2 minutes (assuming T-Log backups are created/copied every 5 minutes) - at which point dbo.apply_logs will simply 'look for' and apply any non-applied logs every time it runs and then alert/notify if it's been > 21 minutes since the last creation date of the last successfully applied T-LOG. 


Benefits of this approach - compared to those provided by SQL Server's native log shipping capabilities are: 
- If you're using Mirroring or Availability Groups as an HA solution, SQL Server Log Shipping expects to be able to create jobs that manage T-LOG backup execution, push those backups from a 'static' location to another defined/static, and then apply them via another job. The problem here, of course, is that T-LOG backups could concievably be getting written/created on either the primary OR the secondary server in an HA topology - which complicates the process of determining when and where to run the T-LOG backup (i.e., creation) job. 
- With S4 apply_logs, T-LOG backups for shipped databases need only be put in a centralized location (which is a best practice for HA/Mirroring configurations anyhow) - and then copied (by means of other processes or synchonization methods outside of SQL Server) to the secondary location - at which point they can be applied as they arrive and when found by the apply_logs process as it 'wakes' periodically to apply logs. 


### D. Off-Loading data to a Reporting Server

In the following example, there's a need to 'ship' the widgetDB and the LargeDB to a second/additional (fully licensed) server to allow off-loading of read-only reporting capabilities. 

Further, to provent even the potential of there being a 'mix-up' with db connection strings, (in addition to requiring different logins from the production (read/write) database vs the reporting (read-only) databases), different database names will also be used - specifically, widgetDB_reporting and LargeDB_reporting. 

To accomplish the name mapping and to initialize, or set up this process, the following code would be used:


```sql
EXEC [admindb].dbo.[restore_databases]
    @DatabasesToRestore = N'widgetDB, LargeDB', 
    @BackupsRootPath = N'D:\SQLBackups', 
    @RestoredRootDataPath = N'D:\SQLData', 
    @RestoredRootLogPath = N'D:\SQLLogs',
    @RestoredDbNamePattern = N'{0}_reporting', 
    -- @AllowReplace = N'', 
    @SkipLogBackups = 0, 
    @ExecuteRecovery = 1, 
    @CheckConsistency = 0, 
    @DropDatabasesAfterRestore = 0, 
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General';
```


Note, in the example above, that the @TargetDbMappingPattern has been set to '{0}_reporting' - which will simply append '_reporting' to the names of all (i.e., both) databases being restored. 

Likewise, when dbo.apply_logs is configured, it will need to account for this mapping by means of the following: 

```sql
EXEC [admindb].dbo.[apply_logs]
    @SourceDatabases = N'widgetDB, LargeDb',
    @Priorities = N'LargeDB, *',
    @BackupsRootPath = N'D:\SQLBackups', 
    @TargetDbMappingPattern = N'{0}_reporting', 
	@RecoveryType = N'STANDBY', 
	@StaleAlertThreshold = N'124m', 
    @AlertOnStaleOnly = 1,
    @OperatorName = N'Alerts', 
    @MailProfileName = N'General', 
    @EmailSubjectPrefix = N'[Reporting DB Sync ] ';
```

Or, as can be seen in the example above, @SourceDatabases (the names of the dbs/folders to check for T-LOG backups) remains the same as the 'source' databases, while @TargetDbMappingPattern value is defined to address/define the mapping {0} to {0}_reporting. 

Other key changes: 
- the @EmailSubjectPrefix has been updated to a value that provides better context for when alerts are raised. 
- the @RecoveryType parameter has been switched to N'STANDBY' - meaning that the widgetDB_reporting, and LargeDB_reporting databases will be left in STANDBY/read-only mode when T-Logs are not being applied. (NOTE that when dbo.apply_logs runs and starts to apply logs against a specific database, it will kick the target database into SINGLE_USER mode (kicking out all other users/logins) then push the database back into NORECOVERY mode so that T-Logs can be applied as needed; if no applicable T-LOGs are found, dbs will NOT be modified - i.e., the process of 'disconnecting' users will only occur if/when there are matching T-LOG backups to apply.)
- the @StaleAlertThreshold value has been set to 120 minutes (or 2 hours and 4 minutes).
- the @Priorities parameter has been set to process the LargeDB first - and any/all other databases afterwards. (With only 2 databases being restored this could have just as easily been defined as 'LargeDB, widgetDB' - but when defined as shown in the example above, the addition of MORE databases to 'ship' for reporting purposes (i.e., added to @SourceDatabases) would still ensure that LargeDB would be processed first and any DBs, thereafter, that are not explictly mentioned in the @Priorities parameter would then be processed in alphabetical order. 

#### Automation

With the code configured above, a SQL Server Agent job could be created on the 'target' server to run, say, every 60 minutes - and apply any logs. Assuming T-LOG backups are happening, say, every 5 or 10 minutes on the source databases (and being copied to the folder defined in @BackupsRootPath), a number of T-LOG backups would 'pile up' on the target server but, in favor of not evicting users to apply those T-LOGs when they 'show up', they would 'sit' until, say, the top of the hour when all pending/available T-Log backkups would then be applied - and the database then pushed back into STANDBY mode. Assuming that a single one of these operations failed (i.e., errors happened), reporting users would now be seeing data > 60 minutes old. However, as configured above (i.e., @StaleAlertThreshold set to 124 minutes), if the subsequent execution of dbo.apply_logs (plus a 4 minute 'buffer') were to somehow fail as well, then an alert would be raised (otherwise, if the 2nd execution was successful no alerts would be raised). 




