# S4 Backups
S4 Backups were designed to provide:

- **Simplicity.** Streamlines the most commonly used features needed for backing up mission-critical databases into a set of simplified parameters that make automating backups of databases easy and efficient - while still vigorously ensuring disaster recovery best-practices.
- **Resiliency** Wraps execution with low-level error handling to prevent a failure in one operation (such as the failure to backup one database out of 10 specified) from 'cascading' into others and causing a 'chain' of operations from completing merely because an 'earlier' operation failed. 
- **Transparency** Usea (low-level) error-handling to log problems in a centralized logging table (for trend-analysis and improved troubleshooting) and send email alerts with concise details about each failure or problem encountered during execution so that DBAs can quickly ascertain the impact and severity of any errors incurred during execution without having to wade through messy 'debugging' and troubleshooting procedures.


## <a name="toc"></a>Table of Contents
- [Benefits of S4 Backups](#benefits)
- [Supported SQL Server Versions](#supported)
- [Deployment](#deployment)
- [Syntax](#syntax)
- [Remarks](#remarks)
- [Examples](#examples)
- [Best-Practices for SQL Server Backups](#best)
- [Setting up Automated Jobs](#jobs)

## <a name="benefits"></a>Benefits of S4 Backups
Key Benefits Provided by S4 Backups:

- **Simplicity, Resiliency, and Transparency.** Commonly needed features and capabilities - streamlined into a set of simple to use scripts. 
- **Streamlined Deployment and Management.** No dependencies on external DLLs, outside software, or additional components. Instead, S4 Backups are set of simple wrappers around native SQL Server Native Backup capabilities - designed to enable Simplicity, Resiliency, and Transparency when tackling backups.
- **Redundancy.** Designed to facilitate copying backups to multiple locations (i.e., on-box backups + UNC backups (backups of backups) - or 2x UNC backup locations, etc.)
- **Encryption.** Enable at-rest-encryption by leveraging SQL Server 2014's (+) NATIVE backup encryption (only available on Standard and Enteprise Editions).
- **Compression.** Leverages Backup Compression on all supported Versions and Editions of SQL Server (2008 R2+ Standard and Enterprise Editions) and transparently defaults to non-compressed backups for Express and Web Editions.
- **Logging and Trend Analysis.** Supports logging of operational backup metrics (timees for backups, file copying, etc.) for trend analysis and review.
- **Fault Tolerance.** Supports Mirrored and 'Simple 2-Node' (Failover only) Availability Group databases.

[Return to Table of Contents](#toc)

## <a name="supported"></a>Supported SQL Server Versions
**S4 Backups were designed to work with SQL Server 2008 and above.** 

S4 Backups were designed to work with all STAND-ALONE Editions of SQL Server (i.e., S4 scripts are not designed to work with Amazon RDS, Azure DB, or other 'streamlined' versions of SQL Server) greater than SQL Server 2008. However, features which aren't supported on some Editions (like Backup Encryption on Web/Express Editions) obviously can't be supported via S4 scripts (meaning that backups on Web and Express Editions will NOT be compressed). Likewise, SQL Express Editions can't send emails/alerts - so @OperatorName, @MailProfileName, and @EmailSubjectPrefix parameters are all ignored AND no alerts can/will be sent upon failures or errors from SQL Express Editions.

Because SQL Server 2017 Linux Editions do NOT support direct interaction (from within SQL Server via a 'command prompt') with the file-system), S4 Backup scripts are not currently supported on SQL Server 2017 for Linux (but are supported on Windows Installations).

S4 Backups have not (yet) been tested against case-sensitive SQL Servers.

***NOTE:** As with any SQL Server deployment, S4 Backup scripts are NOT suitable for use in backing up databases to NAS (Network Attached Storage) devices. SANs, Direct-Attached Disks, iSCSI (non-NAS), and other disk-configurations are viable, but the 'file-level' nature of NAS devices vs the block-level nature (of almost all other devices) required by SQL Server operations will cause non-stop problems and 'weird' device errors and failures when executing backups.*

[Return to Table of Contents](#toc)

## <a name="deployment"></a>Deployment

***NOTE:*** *S4 Scripts leverage OS-level functionality via xp_cmdshell - and deployment of S4 scripts in to your environment will enable xp_cmdshell (for SysAdmins only) if it is not previously enabled. There's sadly a LOT of FUD online about perceived perils of xp_cmdshell - which are addressed here: <a href="/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=master&encodedPath=About%2FNotes%2Fxp_cmdshell_notes.md"> xp_cmdshell_notes.md </a>.*

**To Deploy S4 Backups into new environment:**

* You will need to configure SQL Server Database Mail, enable the SQL Server Agent to use Database Mail for Notifications, and create a SQL Server Agent Operator. For more information, see the following, detailed, <a href="/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=master&encodedPath=About%2FNotes%2Fdatabase_mail.md">instructions for Database Mail configuration details</a>.
* Visit the <a href="/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment/Install">S4\Deployment\Install\ </a>folder and deploy/execute the latest install script (e.g., 4.0 or 4.5, etc. - whatever is the highest version) available. This will enable xp_cmdshell (for SysAdmin role members only) if needed, create an admindb database, and deploy all necessary scripts, objects, and other resources needed for full S4 Backup functionality. 

**To Upgrade (version 4.0+) S4 scripts in an existing environment to newer versions of S4 scripts:**
* Visit the <a href="/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment/Change~20Scripts">S4\Deployment\Upgrade\ </a> folder and deploy/execute the latest 4.x to ***4.[LatestVersionAvailable]*** script against your server (e.g., if you're currently running version 4.0 and the Upgrade folder contains a 4.x to 4.6.sql upgrade script, execute this script against your environment(s) and it will push all 4.1, 4.2, 4.3, etc. upgrades - up to the latest version indicated (by the file name) so that you have all changes and improvements represented in your environment(s).


***Note**: If you're in a Mirrored Environment or if your servers are hosting Availability Groups, you'll want to make sure to complete the steps listed above on both/all servers where backups will be managed.*

[Return to Table of Contents](#toc)

## <a name="syntax"></a>Syntax 

```sql
EXEC dbo.backup_databases
    @BackupType = '{ FULL|DIFF|LOG }', 
    @DatabasesToBackup = N'{ widgets,hr,sales,etc | [SYSTEM] | [USER] }', 
    [@DatabasesToExclude = N'list,of,dbs,to,not,restore, %wildcards_allowed%',] 
    [@Priorities = N'higher,priority,dbs,*,lower,priority,dbs, ]
    @BackupDirectory = N'{ X:\pathTo\Backups\Root | [DEFAULT] }', 
    [@CopyToBackupDirectory = N'',]
    @BackupRetention = { integer_value + m | h | d | w | b specifier }, 
    [@CopyToRetention = { integer_value + m | h | d | w | b specifier },]
    [@RemoveFilesBeforeBackup] = { 0 | 1 }, 
    [@EncryptionCertName = 'ServerCertName',] 
    [@EncryptionAlgorithm = '{ AES 256 | TRIPLE_DES_3KEY }',] 
    [@AddServerNameToSystemBackupPath = { 0 | 1 },] 
    [@AllowNonAccessibleSecondaries = { 0 | 1 },] 
    [@LogSuccessfulOutcomes = { 0 | 1 },] 
    [@OperatorName = NULL,]
    [@MailProfileName = NULL,] 
    [@EmailSubjectPrefix = N'',] 
    [@PrintOnly = { 0 | 1 }] 
	;
```

### Arguments
**@BackupType** = '{ FULL | DIFF | LOG }'

Required. The type of backup to perform (FULL backup, Differential backup, or Transaction-Log Backup). Permitted values are FULL | DIFF | LOG.

**@DatabasesToBackup** =  { list, of, databases, to, backup, by, name | [USER] | [SYSTEM] }

Required. Either a comma-delimited list of databases to backup by name (e.g., 'db1, dbXyz, Widgets') or a specialized token (enclosed in square-brackets) to specify that either [SYSTEM] databases should be backed up, or [USER] databases should be backed up. 


***NOTE:*** By default, the admindb is treated by S4 scripts as a [SYSTEM] database (instead of a [USER] database). If you wish/need to modify this behavior, you'll need to modify the @includeAdminDBAsSystemDatabase switch/variable in dbo.load_database_names (i.e., set it to 0 and it'll then be treated as a [USER] database instead of a [SYSTEM] database).

**[@DatabasesToExclude** = { 'list, of, database, names, to exclude, %wildcards_allowed%' } ]

Optional. Designed to work with [USER] (or [SYSTEM]) tokens (but also works with a specified list of databases). Removes any databases (found on server), from the list of DBs to backup.

Note that you can specify wild-cards for 'pattern matching' as a means of excluding entire groups of similarly named databases. For example, if you have a number of <dbname>_staging databases that you don't want to bother backing up, you can specify '%_staging' as an exclusion pattern (which will be processed via a LIKE expression) to avoid executing backups against all _staging databases.

**[@Priorities** = { 'higher, priority, dbs, *, lower, priority, dbs' } ]

Optional. Allows specification of priorities for backup operations (i.e., specification for order of operations). When NOT specified, dbs loaded (and then remaining after @DatabasesToExclude are processed) will be ranked/sorted alphabetically - which would be the SAME result as if @Priorities were set to the value of '*'. Which means that * is a token that specifies that any database not SPECIFICALLY specified via @Priorities (by name) will be sorted alphabetically. Otherwise, any db-names listed (and matched) BEFORE the * will be ordered (in the order listed) BEFORE any dbs processed alphabetically, and any dbs listed AFTER the * will be ordered (negatively - in the order specified) AFTER any dbs not matched. 

As an example, assume you have 7 databases, ProdA, Minor1, Minor1, Minor1, Minor1, and Junk, Junk2. Alphabetically, Junk, Junk2, and all 'minor' dbs would be processed before ProdA, but if you specified 'ProdA, *, Junk2, Junk', you'd see the databases processed/restored in the following order: ProdA, Minor1, Minor2, Minor3, Minor4, Junk2, Junk - because ProdA is specified before any dbs not explicitly mentioned/specified (i.e., those matching the token *), all of the 'Minor' databases are next - and are sorted/ranked alphabetically, and then Junk is specified BEFORE Junk - but after the * token - meaning that Junk is the last db listed and is therefore ranked LOWER than Junk2 (i.e., anything following * is sorted/ranked as defined and FOLLOWING the databases represented by *).

When @Priorities is defined as something like 'only, db,names', it will be treated as if you had specified the following: 'only,db,names,*' - meaning that the dbs you specified for @Priorities will be restored/tested in the order specified BEFORE all other (non-named) dbs. Otherwise, if you wish to 'de-prioritize' any dbs, you must specify * and then the names of any dbs that should be processed 'after' or 'later'.
  

**@BackupDirectory** = 'path-to-root-folder-for-backups'

Required. 
Default Value = N'[DEFAULT]'.
Specifies the path to the root folder where all backups defined by @DatabasesToBackup will be written. Must be a valid Windows Path - and can be either a local path or UNC path. 
IF the [DEFAULT] token is used, backup_database will request the default location for SQL Server Backups by querying the registry for the current SQL Server instance.

**[@CopyToBackupDirectory** = 'path-to-folder-for-COPIES-of-backups']

Optional - but highly recommended. When specified, backups (written to @BackupDirectory) will be copied to @CopyToBackupDirectory as part of the backup process. Must be a valid Windows path and, by design (though not enforced), should be an 'off-box' location for proper protection purposes. 
NOTE: The [DEFAULT] token (allowed for @BackupDirectory) is NOT supported here (it wouldn't make any sense anyhow). 

**@BackupRetenion* = { integer_value + m | h | d | w | b specifier }

Required. Specifies the amount of time (in m(inutes), h(ours), d(ays), or w(eeks)) that backups of the current type (i.e., @BackupType) should be retained or kept. May also be used to specify the specific number of b(ackups) to be retained instead of specifying a 'time threshold'. For example, if an @BackupType of 'LOG' is specified, and @BackupDirectory is set to 'D:\SQLBackups' is specified with a @BackupRetention of '24h' (i.e., 24h(ours)), then if database 'Widgets' is being backed up, dbo.backup_databases will then remove any .trn (transaction log backups) > 24 hours hold while keeping any transaction-log backups < 24 hours old. Similarly, if @BackupType were specified as 'FULL' and @BackupRetention were set to '2d' (2 days or the equivalent of 48h), then FULL backups of any database being processed > 48 hours (2 days) old would be removed, while any FULL backups newer than the specified threshold would be kept. 

Likewise, if you simply wish to keep a SPECIFIED number of backups - instead of relying upon dates, you can specify #b - where # is the number of backups you'd like to keep (of the current @BackupType being processed). So, for example, if you specified @BackupType = 'DIFF' and @BackupRetention = '1b' - you'd only be keeping the LATEST backup (assuming you remove backups AFTER creating them - because you'd first execute a DIFF backup, then remove all but the last #b(ackups) - or all but the last backup (which you had just taken). 


**NOTE:** *Retention details are only applied against the @BackupType being currently executed. For example,  T-Log backups with an @BackupRetention of '24h' will NOT remove FULL or DIFF backups for the same database (even in the same folder). (Retention ONLY works if when the database name AND backup type is an exact match.) Or, in other words, dbo.backup_databases does NOT 'remember' where your previous backups were stored and go out and delete any previous backups older than @BackupRetention. Instead, during retention processing, dbo.backup_databases will check the 'current' folder for any backups of @BackupType that are older than @BackupRetention and ONLY remove those files if/when the file-backup-names match those of the database being backed up, when the files are in the same folder, and if the backups themselves match the qualifiers stated in @BackupRetention.*

**[@CopyToRetention** = { integer_value + m | h | d | w | b specifier }]

This parameter is required if @CopyToBackupDirectory is specified. Otherwise, it works almost exactly like @BackupRetention (in terms of how files are evaluated and/or removed) EXCEPT that it provides a separate set of retention details for your backup copies. Or, in other words, you could specify a @BackupRetention of '24h' for your FULL backups of on-box backups (i.e., @BackupDirectory backups), and a value of '48h' (or whatever else) for your @CopyToRetention - meaning that 'local' backups of the type specified would be kept for 24 hours, while remote (off-box) backups were kept for 48 hours. 

**[@RemoveFilesBeforeBackup** = { 0 | 1 } ]
Optional. Default = 0 (false). When set to true (1), will attempt to delete any backups (and backup copies) matching @BackupRetention (and @CopyToBackupRetention) BEFORE executing the BACKUP + VERIFY commands. If there is a FAILURE during the process of removing older backups, the corresponding backup will be SKIPPED (as the expectation is that this parameter is set to 1 when available space may be at a premium and the database(s) being backed-up might be large enough to cause issues with disk-space otherwise).

**[@EncryptionCertName** = 'NameOfCertToUseForEncryption' ]

Optional. If specified, backup operation will attempt to use native SQL Server backup by attempting to encrypt the backup using the @EncryptionCertName (and @EncryptionAlgorithm) specified. If the specified Certificate Name is not found (or if the version of SQL Server is earlier than SQL Server 2014 or a non-supported edition (Express or Web) is specified), the backup operation will fail. 

**[@EncryptionAlgorith** = '{ AES_256 | TRIPLE_DES_3KEY }' ]

This parameter is required IF @EncryptionName is specified (otherwise it must be left blank or NULL). Recommended values are either AES_256 or TRIPLE_DES_3KEY. Supported values are any values supported by your version of SQL Server. (See the [Backup](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql) statement for more information.)

**[@AddServerNameToSystemBackupPath** = { 0 | 1 } ]

Optional. Default = 0 (false). For servers that are part of an AlwaysOn Availabilty Group or participating in a Mirroring topology, each server involved will have its own [SYSTEM] databases. When they're backed up to a centralized location (typically via the @CopyToBackupPath), there needs to be a way to differentiate backups from, say, the master database on SERVER1 from master databases backups from SERVER2. By flipping @AddServerNameToSystemBackupPath = 1, the full path for [SYSTEM] database backups will be: Path + db_name + server_name e.g., \\\backup-server\sql-backups\master\SERVER1\ - thus ensuring that system-level database backups from SERVER1 do NOT overwrite system-level database backups created/written by SERVER2 and vice-versa. 

**[@AllowNonAccessibleSecondaries** = { 0 | 1 } ]

Optional. Default = 0 (false). By default, once the databases in @DatabasesToBackup has been converted into a list of databases, this 'list' will be compared against all databases on the server that are in a STATE where they can be backed-up (databases participating in Mirroring, for example, might be in a RECOVERING state) and IF the 'list' of databases to backup then is found to contain NO databases, dbo.backup_databases will throw an error because it was instructed to backup databases but FOUND no databases to backup. However, IF @AllowNonAccessibleSecondaries is set to 1, then IF @DatabasesToBackup = 'db1,db2' and DB1 and DB2 are both, somehow, not in an online/backup-able state, dbo.backup_databases will find that NO databases should be backed up after initial processing, will 'see' that @AllowNonAccessibleSecondaries is set to 1 and rather than throwing an error, will terminate gracefully. 

**NOTE:** *@AllowNonAccessibleSecondaries should ONLY be set to true (1) when Mirroring or Availability Groups are in use and after carefully considering what could/would happen IF execution of backups did NOT 'fire' because the databases specified by @DatabasesToBackup were all found to be in a state where they could NOT be backed up.*

**[@LogSuccessfulOutcomes** = { 0 | 1 } ]

Optional. Default = 0 (false). By default, dbo.backup_databases will NOT log successful outcomes to the  dba_DatabaseBackups_log table (though any time there is an error or problem, details will be logged regardless of this setting). However, if @LogSuccessfulOutcomes is set to true, then succesful outcomes (i.e., those with no errors or problems) will also be logged into the dba_DatabaseBackups_Log table (which can be helpful for gathering metrics and extended details about backup operations if needed). 

**[@OperatorName** = 'sql-server-agent-operator-name-to-send-alerts-to' ]

Defaults to 'Alerts'. If 'Alerts' is not a valid Operator name specified/configured on the server, dbo.backup_databases will throw an error BEFORE attempting to backup databases. Otherwise, once this parameter is set to a valid Operator name, then if/when there are any problems during execution, this is the Operator that dbo.backup_databases will send an email alert to - with an overview of problem details. 

**[@MailProfileName** = 'name-of-mail-profile-to-use-for-alert-sending' ]

Deafults to 'General'. If this is not a valid SQL Server Database Mail Profile, dba_DatabaseBackups will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during backups. 

**[@EmailSubjectPrefix** = 'Email-Subject-Prefix-You-Would-Like-For-Backup-Alert-Messages' ]

Defaults to '[Database Backups ] ', but can be modified as desired. Otherwise, whenever an error or problem occurs during execution an email will be sent with a Subject that starts with whatever is specified (i.e., if you switch this to '--DB2 BACKUPS PROBLEM!!-- ', you'll get an email with a subject similar to '--DB2 BACKUPS PROBLEM!!-- Failed To complete' - making it easier to set up any rules or specialized alerts you may wish for backup-specific alerts sent by your SQL Server.

**[@PrintOnly** = { 0 | 1 } ]

Defaults to 0 (false). When set to true, processing will complete as normal, HOWEVER, no backup operations or other commands will actually be EXECUTED; instead, all commands will be output to the query window (and SOME validation operations will be skipped). No logging to dbo.backup_log will occur when @PrintOnly = 1. Use of this parameter (i.e., set to true) is primarily intended for debugging operations AND to 'test' or 'see' what dbo.backup_databases would do when handed a set of inputs/parameters.

[Return to Table of Contents](#toc)

## <a name="remarks"></a>Remarks

### Automated Backups vs Ad-Hoc Backups
S4 Backups were primarily designed to facilitate AUTOMATED backups - i.e., the regular backups executed on servers to provide disaster recovery options. S4 Backups (i.e., dbo.backup_databases) can be used for 'ad-hoc' backups if necessary **BUT S4 Backups do NOT allow for COPY_ONLY backups** - which could cause significant problems or issues for databases using DIFF backups. Ideally, if you need an AD-HOC backup, use the SSMS GUI or 'whip one up' from script and, in either case, always specify the COPY_ONLY option - as a general best practice. If you are not very familiar with T-SQL Backup commands, you COULD use dbo.backup_databases with the @PrintOnly = 1 switch set, then copy + paste + tweak the BACKUP command to provide a more meaningful backup name (i.e., dev_copy_for_xyz.BAK) AND interject the COPY_ONLY switch into the list of options specified after the WITH clause (i.e., WITH COMPRESSION, etc, COPY_ONLY, etc.).

### Order of Operations During Execution
During execution, the high-level order of operations within dbo.backup_databases is: 
- Validate Inputs
- Construct a list of databases to backup (based on @DatabasesToBackup and @DatabasesToExclude parameters)
- For each database to be backed up, the following operations are executed (in the following order):
- Construct and then EXECUTE a backup statement/command.
- Verify the backup (this is always done and can't be disabled within dbo.backup_databases).
- Copy the verified backup to the @CopyTo location (unless the backup was executed on a SQL Server Enterprise Edition server - in which case the MIRROR TO clause will have been used for 'copy' purposes).
- Remove expired backups from the @BackupsDirectory and @CopyToBackupsDirectory for the CURRENT database being processed.
- Copy the  backup to copy path (if/as specified).
- Remove expired backups from local AND from copy (explicit checks in both locations - see "Managing Different Retention Requirements for Different Databases" below for more info).
- Log any problems or issues and fire off email alerts if/when there are any problems with any aspect of execution defined above (other than validating inputs).

### Managing Different Retention Requirements for Different Databases
When processing backups for cleanup (i.e., evaluating vs retention times), dbo.backup_databases will ONLY execute:
- after completing a backup (if the backup fails, file-cleanup will NOT be processed - so that you don't have a set of backups fail over a long weekend and watch all of your existing (good) backups slowly get 'eaten' while no one was watching their inbox, etc.). 
- against the sub-folder for the database currently being processed. 

The secondary point / limitation is very important for purposes of addressing more 'complex' setups. Specifically, assume you have 4 (user) databases that you need to backup. Assume that 3 of them are of medium to 'meh' importance, but one is of SUCH critical importance you always want at least 3 days of FULL and T-LOG backups available for it - whereas, there isn't enough disk space to keep copies of the other 3 database for SUCH a long time (i.e., you can only 'manage' 2 days of backups for these databases). To this end, you would create DIFFERENT jobs for the 3x 'medium-important' jobs - with RetentionHours in/around the 48 hour mark - and distinct/different jobs (or at least steps or sets of commands) for your 'critical' database that would keep backups for 72 hours. As such, when @RetentionHours (or @CopyToRetention) were being processed against your 3 'medium' importance databases, ONLY files in the folders for these 3x databases will be considered for currently specified retention (and the backups for your 4th/Critical database will NOT be touched during execution). 

### Backup Copies - Enterprise Edition vs Other Editions
SQL Server Enterprise Edition Backups support a 'MIRROR TO' clause that allows backups to be mirrored (i.e., replicated) to multiple additional endpoints/destinations (folders) during execution. As such, if dbo.backup_databases is deployed to an Enterprise Edition SQL Server, it will use native/built-in MIRROR TO functionality to create backup copies. Otherwise, on all other Editions, 'copy' operations are executed by first executing the backup against the path specified by @BackupDirectory (and the sub-folder within that directory for the database being processed), the backup is then verified, and then xp_cmdshell (i.e., a command prompt) is then used to 'manually' copy files to @CopyToBackupDirectory + sub-folder for each database being processed. 

### Backup Encryption
S4 Backups 'wrap' native SQL Server Backup Encryption (i.e., there's nothing special about S4 Backups that could/would provide support for Backup Encryption OUTSIDE of what SQL Server already provides). As such, you will need SQL Server 2014 Standard or Enterprise Editions (encrytion is not supported on Web or Express Editions) or higher for Encryption Support. 

WARNING: If you configure your system for Encrypted Backups, make SURE to backup your Encryption Certificates - otherwise your backups WILL be useless should you lose your primary server in a disaster - and there is NO way to recover from this (not even a support call to Microsoft could help you in this case).

[Return to Table of Contents](#toc)

## <a name="examples"></a>Examples 

### A. FULL Backup of System Databases to an On-Box Location (Only)

The following example will backup all system databases (master, model, and msdb (there's no need to backup tempdb - nor can it be backed up)) to D:\SQLBackups. Once completed, there will be a new subfolder for each database backed up (i.e., D:\SQLBackups\master and D:\SQLBackups\model, etc.) IF there weren't folders already created with these names, and a new, FULL, backup of each database will be dropped into each respective folder. 

Further, any FULL backups of these databases that might have already been in this folder will be evaluated to review how old they are, and any that are > 48 hours old will be deleted - as per the @BackupRetention specification. 

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = 'FULL', 
    @DatabasesToBackup = N'[SYSTEM]', 
    @BackupDirectory = N'D:\SQLBackups', 
    @BackupRetention = '48h';
```

Note too that the example above contains, effectively, the minimum number of specified parameters required for execution (i.e., which DBs to backup, what TYPE of backup, a path, and a retention time). 

REMINDER: It's NEVER a good idea to backup databases to JUST the local-server. Doing so puts your backups and data on the SAME machine and if that machine crashes and can't be recovered, burns to the ground, or runs into other significant issues, you've just lost your data AND backups. 

### B. FULL Backup of System Databases - Locally and to a Network Share

The following example duplicates what was done in Example A, but also pushes copies of System Database backups to the 'Backup Server' (meaning that the path indicated will end up having sub-folders for each DB being backed up, with backups in each folder as expected). 

Note the following: 

- Unlike Example A, the paths specified in this execution end with a trailing slash (i.e., D:\SQLBackups\ instead of D:\SQLBackups). Either option is allowed, and paths will be normalized during execution. 
- Local backups (those in D:\SQLBackups) will be kept for 48 hours, while those on the backup server (where we can assume there is more disk space in this example) will be kept for 72 hours - showing that it's possible to specify different backup retention rates for @BackupDirectory and @CopyToBackupDirectory folders. 

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[SYSTEM]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h'; -- longer retention than 'on-box' backups
```

### C. Full Backup of All User Databases - Locally and to a Network Share

The following example is effectively identical to Example B, only, in this example, all user datbases are being specified - by use of the [USER] token. Once execution is complete:

- A folder will be created for each (user) database on the server where this code is executed - if a folder didn't already exist. 
- A new FULL backup will be added to the respective folder for each database. 
- Copies of these changes will be mirrored to the @CopyToBackupDirectory (i.e., a new sub-folder per each DB and a FULL backup per each database/folder). 
- Retention rates (per database) will be processed against each-subfolder found at @BackupDirectory and each subfolder found at @CopyToBackupDirectory. 

Note, however, that the only tangible change between this example and Example B is that @DatabaseToBackup has been set to backup [USER] databases. 

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```

### D. Full Backup of User Databases - Excluding explicitly specified databases

This example executes identically to Example C - except the databases Widgets, Billing, and Monitoring will NOT be backed up (if they're found on the server). Note that excluded database names are comma-delimited, and that spaces between db-names do not matter (they can be present or not). Likewise, if you specify the name of a database that does NOT exist as an exclusion, no error will be thrown and any databases OTHER than those explicitly excluded will be backed up as specified. 

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @DatabasesToExclude = N'Widgets, Billing,Monitoring', 
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```
### E. Explicitly Specifying Database Names for Backup Selection

Assume you've already set up a nightly job to tackle FULL backups of all user databases (and that you've got T-LOG backups configured as well), but have 2x larger databases that require a DIFF backup at various points during the day (say noon and 4PM) in order to allow restore-operations to complete in a timely fashion (due to high-volumes of transactional modifications during the day). 

In such a case you wouldn't want to specify [USER] (if you've got, say 12 user databases total) for which databases to backup. Instead, you'd simply want to specify the names of the databases to backup via @DatabasesToBackup. (And note that database names are comma-delimited - where spaces between db-names are optional (i.e., won't cause problems)). 

In the following example, @BackupType is specified as DIFF (i.e., a DIFFERENTIAL backup), and only two databases are specifically specified (Shipments and ProcessingProd) - meaning that these two databases are the only databases that will be backed-up (with a DIFF backup). As with all other backups, the DIFF backups for this execution will be dropped into sub-folders per each database.

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'DIFF', 
    @DatabasesToBackup = N'Shipments, ProcessingProd',
    @DatabasesToExclude = N'Widgets, Billing,Monitoring', 
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```

### F. Setting up Transaction-Log Backups

In the following example, Transaction-log backups are targeted (i.e., @BackType = 'LOG'). As with other backups, these will be dropped into sub-folders corresponding to the names of each database to be backed-up. In this case, rather than explicitly specifying the names of databases to backup, this example specifies the [USER] token for @DatabasesToBackup. During execution, this means that dbo.backup_databases will create a list of all databases in FULL or BULK-LOGGED Recovery Mode (databases in SIMPLE mode cannot have their Transaction Logs backed up and will be skipped), and will execute a transaction log backup for said databases. (In this way, if you've got, say, 3x production databases running in FULL recovery mode, and a handful of dev, testing, or stage databases that are also on your server but which are set to SIMPLE recovery, only the databases in FULL/BULK-LOGGED recovery mode will be targetted. Or, in other words, [USER] is 'smart' and will only target databases whose transaction logs can be backed up when @BackupType = 'LOG'.)

Notes:
- If all of your databases (i.e., on a given server) are in SIMPLE recovery mode, attempting to execute with an @BackupType of 'LOG' will throw an error - because it won't find ANY transaction logs to backup. 
- In the example below, @BackupRetention has been set to 49 (hours). Previous examples have used 'clean multiples' of 24 hour periods (i.e., days) - but there's no 'rule' about how many hours can be specified - other than that this value cannot be 0 or NULL. (And, by setting the value to 'somewhat arbitrary' values like 25 hours instead of 24 hours, you're ensuring that if a set of backups 'go long' in terms of execution time, you'll always have a full 24 hours + a 1 hour backup worth of backups and such.)


```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```


### G. Using a Certificate to Encrypt Backups

The following example is effectively identical to Example D - except that the name of a Certificate has been supplied - along with an encryption algorithm, to force SQL Server to create encrypted backups. When encrypting backups:
- You must create the Certificate being used for encryption BEFORE attempting backups (see below for more info). 
- You must specify a value for both @EncryptionCertName and @EncryptionAlgorithm.
- Unless this is a 'one-off' backup (that you're planning on sharing with someone/etc.), if you're going to encrypt any of your backups, you'll effectively want to encrypt all of your backups (i.e., if you encrypt your FULL backups, make sure that any DIFF and T-LOG backups are also being encrypted). 
- While encryption is great, you MUST make sure to backup your Encryption Certificate (which requires a Private Key file + password for backup) OR you simply won't be able to recover your backups on your server if something 'bad' happens and your server needs to be rebuilt or on any other server (i.e., smoke and rubble contingency plans) without being able to 'recreate' the certificate used for encryption. 

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '49h', 
    @CopyToRetention = '72h';
    @EncryptionCertName = N'BackupsEncryptionCert', 
    @EncryptionAlgorithm = N'AES_256';
```

For more information on Native support for Encrypted Backups (and for a list of options to specify for @EncryptionAlgorithm), make sure to visit Microsoft's official documentation providing and overview and best-practices for [Backup Encryption](https://docs.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-encryption), and also view the [BACKUP command page](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql) where any of the options specified as part of the ALGORITHM 'switch' are values that can be passed into @EncryptionAlgorith (i.e., exactly as defined within the SQL Server Docs).

### H. Accounting for System and User Databases on Mirrored / Availability Group Servers

If your databases are mirrored or part of AlwaysOn Availability Groups, you pick up a couple of additional challenges:
- While you obviously want to keep backing up your (user) databases, they will typically only be 'accessible' for backups on or from the 'primary' server only (unless you're running a multi-server node that is licensed for read-only secondaries (which aren't fully supported by dbo.backup_databases at this time)) - meaning that you'll want to create jobs on 'both' of your servers that run at the same time, but you only want them to TRY and execute a backup against the 'primary' replica/copy of your database at a time (otherwise, if you try to kick off a FULL or T-LOG backup against a 'secondary' database you'll get an error). 
- Since your (user) backups can 'jump' from one server to another (via failover), 'on-box' backups might not always provide a full backup chain (i.e., you might kick off FULL backups on SERVERA, run on that server for another 4 hours, then a failover will force operations on to SERVERB - where things will run for a few hours and then you may or may not fail back; but, in either case: neither the backups on SERVERA or SERVERB have the 'full backup chain' - so off-box copies of your backups are WAY more important than they normally are. In fact, you MIGHT want to consider setting @BackupDirectory to being a UNC share and @CopyToBackupDirectory to being an additional 'backup' UNC share (on a different host) - as the backups on either SERVERA or SERVERB both run the risk of never actually being a 'true' chain of viable backups). 
- System backups also run into a couple of issues. Since the master database, for example, keeps details on which databases, logins, linked servers, and other key bits of data are configured or enabled on a specific server, you'll want to create nightly (at least) backups of your system databases for both servers. However, if you specify a backup path of \\\\ServerX\SQLBackups as the path for your FULL [SYSTEM] backups on both SERVERA and SERVERB, each of them will try to create a new subfolder called master (for the master database, and then model for the model db, and so on), and drop in new FULL bakups for their own, respective, master databases. dbo.backup_databases will use a 'uniquifier' in the names of both of these master database backups - so they won't overwrite each other, but... if you were to ever need these backups, you'd have NO IDEA which of the two FULL backups (taken at effectively the same time) would be for SERVERA or for SERVERB. To address, the @AddServerNameToSystemBackupsPath switch has been added to dbo.backup_databases and, when set to 1, will result in a path for system-database backups that further splits backups into sub-folders for the server names. 

**Examples**

The following example is almost the exact same as Example A, except that on-box backups are no-longer being used (backups are being pushed to a UNC share instead), AND the @AddServerNameToSystemBackupsPath switch has been specified and set to 1 (it's set to 0 by default - or when not explicitly included):

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = 'FULL', 
    @DatabasesToBackup = N'[SYSTEM]', 
    @BackupDirectory = N'\\SharedBackups\SQLServer\', 
    @BackupRetention = '48h',
    @AddServerNameToSystemBackupPath = 1;
```

Without @AddServerNameToSystemBackupsPath being specified, the master database (for example) in the example execution above would be dropped into the following path/folder: \\\\SharedBackups\SQLServer\master - whereas, with the value set to 1 (true), the following path (assuming that the server this code was executing on was called SQL1) would be used instead: \\\\SharedBackups\SQLserver\master\SQL1\ - and, if the same code was also executed from a server named SQL2, a \SQL2\ sub-directory would be created as well. 

In this way, it ends up being much easier to determine which server any system-database backups come from (as each server needs its OWN backups - unlike user databases which are mirrored or part of an AG (or not on both boxes) - which don't need this same distinction). 

In the following example, which is essentially the same as Example C, FULL backups of system databases are being sent to 2x different UNC shares AND the @AllowNonAccessibleSecondaries option has been flipped/set to 1 (true) - which means that if there are (for example) 2x user databases being shared between SQL1 and SQL2 (either by mirroring or Availability Groups) and BOTH of these databases are active/accessible on SQL1 but not accessible on SQL2, the code below can/will run on BOTH servers (at the same time) without throwing any errors - because it will run on SQL1 and execute backups, and when it runs on SQL2 it'll detect that none of the [USER] databases are in a state that allows backups and then SEE that @AllowNonAccessibleSecondaries is set to 1 (true) and assume that the reason there are no databases to backup is because they're all secondaries. (Otherwise, without this switch set, if it had found no databases to backup, it would throw an error and raise an alert about finding no databases that it could backup.)

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'\\SharedBackups\SQLServer\', 
    @CopyToBackupDirectory = N'\\BackupServer\CYABackups\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
    @AllowNonAccessibleSecondaries = 1;
```

### H. Forcing dbo.backup_databases to Log Backup Details on Successful Outcomes

By default, dbo.backup_databases will ONLY log information to master.dbo.dba_DatabaseBackups_Log table IF there's an error, exception, or other problem executing backups or managing backup-copies or cleanup of older backups. Otherwise - if everything completes without any issues - dbo.backup_databases will NOT log information to the dbo.backups_log logging table. 

This can, however, be changed (per execution) so that successful execution details are logged - as per this example (which is identical to Example C - except that details on each database backed up will be logged - along with info on copy operations, etc.):

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h'; 
    @LogSuccessfulOutcomes = 1;
```


### I. Modifying Alerting Information

By default, dbo.backup_databases is configured to send to the 'Alerts' Operator via a Mail Profile called 'General'. This was done to support 'convention over configuration' - while still enabling options for configuration should they be needed. As such, the following example is an exact duplicate of Example C, only it has been set to use a Mail Profile called 'DbMail', modify the prefix for the Subject-line in any emails alerts sent (i.e., they'll start with '!! BACKUPS !! - ' instead of the default of '[Database Backups] '), and the email will be sent to the operator called 'DBA' instead of 'Alerts'. Otherwise, everything will execute as expected. (And, of course, an email/alert will ONLY go out if there are problems encountered during the execution listed below.)

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h'; 
    @OperatorName = N'DBA',
    @MailProfileName = N'DbMail',
    @EmailSubjectPrefix = N'!! BACKUPS !! - ';
```

NOTE that dbo.backup_databases will CHECK the @OperatorName and @MailProfileName to make sure they are valid (whether explicitly provided or when provided by default) - and will throw an error BEFORE attempting to execute backups if either is found to be non-configured/valid on the server. 

### J. Printing Commands Instead of Executing Commands

By default, dbo.backup_databases will create and execute backup, file-copy, and file-cleanup commands as part of execution. However, it's possible (and highly-recommended) to view WHAT dbo.backup_databases WOULD do if invoked with a set of parameters INSTEAD of executing the commands. Or, in other words, dbo.backup_databases can be configured to output the commands it would execute - without executing them. (Note that in order for this to work, SOME validation checks and NO logging (to dbo.dba_DatabaseBackups_Log) will occur.) 

To see what dbo.backup_databases would do (which is very useful in setting up backup jobs and/or when making (especially complicated) changes) rather than let it execute, simply set the @PrintOnly parameter to 1 (true) and execute - as in the example below (which is identical to Example C - except that commands will be 'spit out' instead of executed):

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
    @PrintOnly = 1; -- don't execute. print commands instead...
```

[Return to Table of Contents](#toc)

## <a name="best"></a>Best-Practices for SQL Server Backups

For background and insights into how SQL Server Backups work, the following, free, videos can be very helpful in bringing you up to speed: 

- [SQL Server Backups Demystified.](http://www.sqlservervideos.com/video/backups-demystified/) 
- [SQL Server Logging Essentials.](http://www.sqlservervideos.com/video/logging-essentials/)
- [Understanding Backup Options.](http://www.sqlservervideos.com/video/backup-options/)
- [SQL Server Backup Best Practices.](http://www.sqlservervideos.com/video/sqlbackup-best-practices/)

Otherwise, some highly-simplified best-practices for automating SQL Server backups are as follows:
- **Concerns about 'Resource Overhead' Associated with Backups.** Generally speaking, backups do NOT consume as many resources as most people initially fear - so they shouldn't be 'feared' or 'used sparingly'. (Granted, FULL backups against larger databases CAN put some stress/strain on the IO subsystem - so they should be taken off-hours or 'at night' as much as possible. Likewise, DIFF backups (which can be taken 'during the day' and at periods of high-load (to decrease how much time is required to restore databases in a disater) CAN consume some resources during the day when taken, but this needs typically slight negative needs to be contrasted with the positive/win of being able to restore databases more quickly in the case of certain types of disaster. Otherwise, when executed regularly (i.e., every 5 to 10 minutes), Transaction Log backups typically don't consume more resources than some 'moderate queries' that could be running on your systems and NEED to be executed regularly to ensure you have options and capabilities to recover from disasters. In short, humans are wired for scarcity; forget that and be 'eager' with your backups, then watch for any perf issues and address/react accordingly (instead of fearing that backups might cause problems - as it is guaranteed that a LACK of proper/timely backups will cause WAY more problems when an emergency occurs.)
- **FULL Backups - Recommendations and Frequency of Backups.** All databases, including dev/testing/stating databases, should typically see a FULL backup every day. The exception would be LARGE databases (i.e., databases typically above/beyond 1TB in size - where it might make more sense to execute FULL backups on weekends, and execute DIFF backups nightly), or dev/test databases in SIMPLE recovery mode that don't see much activity and could 'lose a week' (or multiple days/whatever) of backups without causing ANY problems. As such, you should typically create a nightly job that executes FULL backups of all [SYSTEM] databases (see Example B) and another, distinct, job that executes FULL backups of [USER] databases (see Example C below). Then, if you've got some (user) databases you're SURE you don't care about AND that you can recreate if needed, then you can exclude these using @DatabasesToExclude.
- **A Primary Role for DIFF Backups.** Once FULL backups of all (key/important and even important-ish) databases have been addressed (i.e., you've created jobs for them), you may want to consider setting up DIFF backups DURING THE DAY to address 'vectored' backups of larger and VERY HEAVILY used databases - as a means of decreasing recovery times in a disaster. For example, if you've got a 300GB database that sees a few thousand transactions per minute (or more), and generates MBs or 10s of MBs of (compressed) T-LOG backups every 5 or 10 minutes when T-Log backups are run, then if you run into a disaster at, say, 3PM, you're going to have to restore a FULL Backup for this database plus a LOT of transactional activity - which CAN take a large amount of time. Therefore, if you've got specific RTOs in place, one means of 'boosting' recovery times is to 'interject' DIFF backups at key periods of the day. So, for example, if you took a FULL backup at 2AM, and DIFF backups at 8AM, Noon, and 4PM, then ran into a disaster at 3PM, you'd restore the 2AM FULL + the Noon DIFF (which would let you buypass 10 hours of T-Log backups) to help speed up execution. As such, if something like this makes sense in your environment, make sure to review the examples (below), and then pay special attention to Example E - which showcases how to specify that specific databases should be targeted for DIFF backups. 
- **Recommendations for Transaction Log Backups.** Otherwise, in terms of Transaction Log backups, these SHOULD be executed every 10 minutes at least - and as frequently as every 3 minutes (on very heavily used systems).On some systems, you may want or need T-Log backups running 24 hours/day (i.e., transactional coverage all the time). On other (less busy systems), you might want to only run Transaction Log backups between, say, 4AM (when early users start using the system) until around 10PM when you're confident the last person in the office will always, 100%, be gone. Again, though, T-Log backups don't consume many resources - so, when in doubt: just run T-Log backups (they don't hurt anything). **Likewise, do NOT worry about T-Log backups 'overlapping' or colliding with your FULL / DIFF backups; if they're set to run at the same time, SQL Server is smart and won't allow anything to break (or throw errors) NOR will it allow for any data loss or problems.** Otherwise, as defined elsewhere, when a @BackupType of 'LOG' is specified, dbo.backup_databases will backup the transaction logs of ALL (user) databases not set to SIMPLE recovery mode. As such, if you are CONFIDENT that you do NOT want transaction log backups of specific databases (dev, test, or 'read-only' databases that never change OR where you 100% do NOT care about the loss of transactional data), then you should 'flip' those databases to SIMPLE recovery so that they're not having their T-Logs backed up.
- **Recommendations for Backup Storage Locations.** In terms of storage or WHERE you put your backups, there are a couple of rules of thumb. **First, it is NEVER good enough to keep your ONLY backups on the same server (i.e., disks) as your data. Doing so means that a crash or failure of your disks or system will take down your data and your backups.** As such, you should ALWAYS make sure to have off-box copies or backups of your databases (which is why the @CopyToBackupDirectory and @CopyToRetention parameters exist). Arguably, you can and even SHOULD (in many - but not all) then ALSO have copies of your backups on-box (i.e., in addition to off-box copies). And the reason for this is that off-box backups are for hardware disasters - situations where a server catches fire or something horrible happens to your IO subsystem - whereas on-box backups are very HELPFUL (but not 100% required) for data-corruption issues (i.e., problems where you run into phsyical corruption or logical corruption) where your hardware is FINE - because on-box backups mean that you can start up restore operations immediately and from local disk (which is usually - but not always) faster than disk stored 'off box' and somewhere on the network. Again, though, the LOGICAL priority is to keep off-box backups first (usually with a longer retention rate as off-box backup locations typically tend to have greater storage capacity) and then to keep on-box 'copy' backups locally as a 'plus' or 'bonus' whenever possible OR whenever required by SLAs (i.e., RTOs). Note, however, that while this is the LOGICAL desired outcome, it's typically a better practice (for speed and resiliency purposes) to write/create backups locally (on-box) and then copy them off-box (i.e., to a network location) after they've been created locally. As such, many of the examples in this documentation point or allude to having backups on-box first (the @BackupDirectory) and the 'copy' location second (i.e., @CopyToBackupDirectory). 
- **Organizing Backups.** Another best practice with backups, is how to organize or store them. Arguably, you could simply create a single folder and drop all backups (of all types and for all databases) into this folder as a 'pig pile' - and SQL Server would have no issues with being able to restore backups of your databases (if you were to use the GUI). However, humans would likely have a bit of a hard time 'sorting' through all of these backups as things would be a mess. An optimal approach is to, instead, create a sub-folder for each database, where you will then store all FULL, DIFF, and T-LOG backups for each database so that all backups for a given database are in a single folder. With this approach, it's very easy to quickly 'sort' backups by time-stamp to get a quick view of what backups are available and roughly how long they're being retained. This is a VERY critical benefit in situations where you can't or do NOT want to use the SSMS GUI to restore backups - or in situations where you're restoring backups after a TRUE disaster (where the backup histories kept in the msdb are lost - or where you're on brand new hardware). Furthermore, the logic in S4 Restore scripts is designed to be 'pointed' at a folder or path (for a given database name) and will then 'traverse' all files in the folder to restore the most recent FULL backup, then restore the most recent DIFF backup (since the FULL) if one exists, and conclude by restoring all T-LOG backups since the last FULL or DIFF (i.e., following the backup chain) to complete restore a database up until the point of the last T-LOG backup (or to generate a list of commands that would be used - via the @PrintOnly = 1 option - so that you can use this set of scripts to easily create a point-in-time recovery script). Accordingly, dbo.backup_databases takes the approach of assuming that the paths specified by @BackupDirectory and/or @CopyToBackupDirectory are 'root' locations and will **ALWAYS** create child directories (if not present) for each database being backed up. (NOTE that if you're in the situation where you don't have enough disk space for ALL of your backups to exist on the same disk or network share, you can create 2 or more backup disks/locations (e.g., you could have D:\SQLBackups and N:\SQLBackups (or 2x UNC locations, etc.)) and then assign each database to a specific disk/location as needed - to 'spread' your backups out over different locations. If you do this, you MIGHT want to create 2x different jobs per each backup type (i.e., 2x jobs for FULL backups and 2x jobs for T-Log Backups) - each with its own corresponding job name (e.g. "Primary Databases.FULL Backups" and "Secondary Databases.FULL Backups"); or you might simply have a SINGLE job per backup type (UserDatabases.FULL Backups and UserDatabases.LOG Backups) and for each job either have 2x job-steps (one per each path/location) or have a single job step that first backups up a list of databases to the D:\ drive, and then a separate/distinct execution of dbo.backup_databases below the first execution (i.e., 2x calls to dbo.backup_databases in the same job step) that then backs up a differen set of databases to the N:\ drive. 
- **Backup Retention Times.* In terms of retention times, there are two key considerations. First: backups are not the same thing as archives; archives are for legal/forensic and other purposes - whereas backups are for disaster recovery. Technically, you can create 'archives' via SQL Server backups without any issues (and dbo.backup_databases is perfectly suited to this use) - but if you're going to use dbo.backup_databases for 'archive' backups, make sure to create a new / distinct job with an explicit name (e.g., "Monthly Archive Backups"), give it a dedicated schedule - instead of trying to get your existing, nightly (for example) job that tackles FULL backups of your user databases to somehow do 'dual duty'. However, be aware that dbo.backup_databases does NOT create (or allow for) COPY_ONLY backups - so IF YOU ARE USING DIFF backups against the databases being archived, you will want to make sure that IF you are creating archive backups, that you create those well before normal NIGHTLY backups so that when your normal, nightly, backups execute you're not breaking your backup chain. Otherwise, another option for archival backups is simply to have an automated process simply 'zip out' to your backup locations at a regularly scheduled point and 'grab' and COPY an existing FULL backup to a safe location. Otherwise, the second consideration in terms of retention is that, generally, the more backups you can keep the better (to a point - i.e., usually anything after 2 - 4 days isn't ever going to be used - because if you're doing things correctly (i.e., regular DBCC/Consistency checks and routinely (daily) verifying your backups by RESTORING them, you should never need much more that 1 - 2 days' worth of backups to recover from any disaster). Or, in other words, any time you can keep roughly 1-2 days of backups 'on-box', that is typically great/ideal as it will let you recovery from corruption problems should the occur - in the fastest way possible; likewise, if you can keep 2-3 days of backups off-box, that'll protect against hardware and other major system-related disasters. If you're NOT able to keep at least 2 days of backups somewhere, it's time to talk to management and get more space.
- **The Need for OFF-SITE Backups.**Finally, S4 Backups are ONLY capable of creating and managing SQL Server Backups. And, while dbo.backup_databases is designed and optimized for creating off-box backups, off-box backups (alone), aren't enough of a contingency plan for most companies - because while they will protect against situations where youl 100% lose your SQL Server (where the backups were made), they won't protect against the loss of your entire data-center or some types of key infrastructure (the SAN, etc.). Consequently, in addition to ensuring that you have off-box backups, you will want to make sure that you are regularly copying your backups off-site. (Products like [CloudBerry Server Backup](https://www.cloudberrylab.com/backup/windows-server.aspx) are cheap and make it very easy and affordable to copy backups off-site every 5 minutes or so with very little effort. Arguably, however, you'll typically WANT to run any third party (off site) backups OFF of your off-box location rather than on/from your SQL Server - to decrease disk, CPU, and network overhead. However, if you ONLY have a single SQL Server, go ahead and run backups (i.e., off-site backups) from your SQL Server (and get a more powerful server if needed) as it's better to have off-site backups.)

[Return to Table of Contents](#toc)

## <a name="jobs"></a>Setting Up Scheduled Backups using S4 Backups
As S4 Backups were designed for automation (i.e., regularly scheduled backups), the following section provides some high-level guidance and 'comprehensive' examples on how to schedule jobs for all different types of databases. 

### Creating Jobs
For all Editions of SQL Server, the process for defining and creating jobs uses the same workflow. However, SQL Server Express Editions do NOT have a SQL Server Agent and cannot, therefore, use SQL Server Agent Jobs (i.e., schedule tasks with built-in capabilities for alerting/etc) for execution and will need to use the Windows Task Scheduler (or a 3rd party scheduler) to kick of .bat or .ps1 commands instead. 

Otherwise, the basic order of operations (or workflow) for creating scheduled backups is as follows:
- Read through the guidelines below BEFORE actually creating and implementing any actual job steps.
- Start with any SLAs (RPOs or RTOs) you may have governing how much data-loss and down-time for key/critical databases can be tolerated. 
- Evaluate all other non-critical databases for backup needs and put any non-important databases into SIMPLE recovery mode and/or remove from your production servers as much as possible. 
- Review backup retention requirements for all databases. (Typically, the best option is to try and keep all types of dbs (important/critical and then non-import/dev/testing) for roughly the same duration. However, if you are constrained for disk space, you may have to pick 'favorite' or more important databases which will have LONGER backup retention times AT THE EXPENSE of shorter retention times for LESS important databases.
- Create different logical 'groupings' of your databases as needed. Ideally you want as FEW groupings or types of databases as possible (i.e., System and User databases is a common convention). However, if some of your databases are drastically more important/critical than others, you might want to break up user databases into two groups: "Critical" and "Normal", and drop databases into these groups as needed. 
- Start by setting up a job to execute FULL backups of your System databases. Typically, retention times of 2 - 3 days for system databases are more than fine. 
- Then set up a job for FULL backups of any 'super' critical  - with corresponding retention rates defined as needed. Make sure you're copying these backups off-box (either via the @CopyToBackupDirectory or by a regularly-running 3rd party solution/etc.)
- If one of your 'super' critical databases is under very heavy load during periods of the day and you have TESTED and found out that you cannot restore from a FULL + all T-LOGs (since FULL) and recover within RTOs, then you'll need to create DIFF backups for this 'group' of databases at key intervals (i.e., every 4 hours from 10AM until 6PM - or whatever makes sense).
- Once you've addressed FULL + DIFF backups for any critical or super important databases, you can then address FULL backups for any less important (i.e., medium importance) and lower-importance databases as needed. 
- After you've figured out what your needs for 'critical', normal, and low-importance databases are (in terms of FULL and/or DIFF backups), try to CONSOLIDATE needs as much as you can. For example, if you have 5 databases, 2 of which are dev/test databases that aren't that important, 2 of which are production databases, and one of which is a mission-critical (used like crazy) database of utmost importance, you can (in most cases) consolidate the FULL + DIFF backups for ALL 5 of these databases into just two jobs: a job that tackles FULL backups of ALL user databases at, say, 4AM every morning (which will execute full backups of your 2 dev/testing databases and of your 3x production databases), and then a second job (with a name like "<BigDbName>.DIFF Backups" - or "HighVolume.DIFF Backups" if you've got 2 or more high-volume DBs that require DIFF backups) that executes DIFF backups every 3 hours starting at 10AM and running until 5PM - or whatever makes sense. 
- Once you have FULL + DIFF backups tackled, you should typically ONLY EVER need to create a SINGLE job to tackle Transaction Log backups - across all (non-SIMPLE Recovery Mode) databases. So, in the example above, if you've got 5x databases (2 that are dev/test, 2 that are important, and 1 that is critical), after you had created 2 jobs (one for FULL, one for DIFFs), you'd then create a single job for T-Log backups (i.e., "User Databases.LOG Backups") that was set to run every 3 - 10 minutes (depending up on RPOs) which would be configured to execute LOG backups - meaning that when executed, this job would 'skip-past' your 2x dev/testing databases (because they're in SIMPLE recovery mode), then backup the T-Logs for your 3x production databases.

In short, make sure to plan things out a bit before you start creating jobs or executing backups. A little planning and preparation will to a long way - and, don't expect to get things perfect on your first try; you may need to monitor things for a few days (see how much disk you end up using for backups/etc.) and then 'course-correct' or even potentially 'blow everything away and start over'. Or, in other words, S4 backups weren't designed to make backups a 'brain-dead' operation that wouldn't require any planning or monitoring on your part - but they WERE created to make it very easy for you to make changes or 'tear-down and re-create' backup routines and schedules without much effort involved in the actual CODING and configuration needed to get things 'just right'.

### Addressing Customized Backup Requirements
On very simple systems you can quite literally create two jobs and be done:
- One that executes a FULL backup of all databases nightly. 
- One that executes LOG backups of all (non-SIMPLE recovery) databases every x minutes. 

However, even to do something like thise, you would run into the problem that while dbo.backup_databases will let you specify [USER] as a way to backup all user databases and [SYSTEM] to backup all system databases, there is NOT an [ALL] token that targets all databases (this is by design). As such, for your first 'job' listed above, you'd have 3x actual options for how you wanted to tackle the need for processing FULL backups of all databases. 

1. You could actually create 2x jobs instead of just a single Job - e.g., "System Databases.FULL Backups" and "User Databases.FULL Backups". For jobs processing System Backups, this is actually the best/recommended practice (it makes it very clear in looking at the Jobs listed in your SQL Server Agent that you're executing FULL backups of System databases (and user DBs as well). (For situations where you need to execute different options for user databases - one of the other two options below typically makes more sense).
2. You 'stick' with using a single SQL Server Agent Job, but spin up 2x different Job Steps within the Job - i.e., a Job_Step called "System Databases" and an additional Job-Step called "User Databases". The BENEFIT of this approach is that you end up with just a single job (less 'clutter') and your backups will not only execute under the same schedule - but they'll run serially (i.e., system backups will take as long as needed, and - without skipping a beat - user database backups will then kick off) - which is great if you've have smaller maintenance windows. NEGATIVES of this approach are that you MUST take care to make sure that if the first Job-Step fails, the job itself does NOT quit (reporting failure), but goes to the next Job-Step (so that a 'simple' failure to backup, say, the model database (for some odd reason), doesn't prevent you from at least TRYING to backup one of your critical or even important databases.
3. You could 'stick' with both a single job AND a single-job step - by simply 'dropping' 2x (or more) calls to dbo.backup_databases within the same job step. While this works, it comes with 2 negatives: a) while dbo.backup_databases is designed to run without throwing exceptions when an error occurs during backups, IF a major problem happens in your first execution, the second call to dbo.backup_databases may not fire and b) it's easy for things to get a bit cluttered and 'confusing' fast. As such, option 2 (different Job Steps within the same job) is usually the best option for addressing 'customizations' or special needs within backups for user databases. 


Otherwise, key reasons why you might want to address customized backup requirements would include things like: 
- Situations where you might have different backup locations on the same server (i.e., smaller volumes/disks/folders that can't handle ALL of your backups to the same, single, location). In situations like this, you're better of creating a single job for all of your FULL backups for user databases (e.g., "User Databases.FULL Backups") and then doing the same for LOG backups (e.g., "User Databases.LOG Backups") and then for each job, creating 2 or more job steps - to handle backups for databases being written to the N drive (for example), and then a follow-up Job Step for databases backed up to the S drive, and so on. 
- Situations where you have different retention times for different databases - either for DR purposes or because of disk space constraints. 

But, in each case where you must 'customize' or specialize specific settings or details, you typically want to try and 'consolidate' as many separate yet RELATED operations into as few jobs as possible - as doing so makes it much easier to find a job when problems happen (i.e., if you have 6x different "FULL backup" jobs for 6 or more databases, it'll take you a bit longer to find and troubleshoot WHICH one of those jobs had a problem if a problem happens AND you'll have WAY more schedules to juggle). Likewise, you typically want as FEW schedules to manage as possible - both because it makes it easier to troubleshoot problems AND because then you're not playing 'swiss cheese meets complex maintenance requirements' and trying to 'plug' various tasks into a large number of time-slots and the likes - and then constantly having to adjust and 'shuffle' schedules around when dbs start getting larger and backups take increasingly more and more time (causing 'collisions' with other jobs). 

### Testing Execution Details 
Once you've figured out what you want to set up in terms of jobs/schedules and the likes, you should TEST the specific configuraitons you're looking at pulling off - to make sure everything will work as expected. 

As a best practice, start with creating a call to dbo.backup_databases that will tackle backups of your System databases. Specifically, copy + paste the code from Example A into SSMS, point the @BackupDirectory at a viable path on your server, and then append @PrintOnly = 1 to the end of the list of parameters and execute. Then review the commands generated and you can even copy/paste one of the BACKUP commands if you'd like and try to execute it (it'll likely fail on a server where dbo.backup_databases hasn't run before - because it'll be trying to write to a subfolder that hasn't been created yet). Then, once you've reviewed the commands being generated, remove the @PrintOnly = 1 parameter (remove it instead of setting it 0), and execute. 

At this point, if you haven't configured something correctly - or are missing dependencies, dbo.backup_databases will throw an ERROR and will not continue operations. 

Otherwise, if everything looks like it has been configured correctly, execution will complete and if there are errors, you'll see that an email message has been queued - and you can query admindb.dbo.backup_log for information (check the ErrorDetails column - or just wait for an email).

If backup execution completed as follows, then make sure to specify an @CopyToBackupDirectory and a corresponding value for @CopyToRetention - and any other parameters as you'll need for your production backups, and then create a new SQL Server Agent Job to execute the commands as you have configured them. 

Then repeat the process for all of the other backup operations that you'll need - where (for each job or set of differences you define) you can always 'test' or visualize outcomes by setting @PrintOnly = 1, and then REMOVING this statement before copy/pasting details into a SQL Server Agent Job. 

### Recommendations for Creating Automated Backup Jobs
The following recommendations will help make it easier to manage SQL Server Agent Jobs that have been created for implementing automated backups. 

#### Job Names
Job names should obviously make it easy to spot what kind of backups are being handled. Examples for different Job names include the following:
- SystemDatabases.FULL Backups
- UserDatabases.FULL Backups
- UserDatabases.DIFF Backups
- UserDatabases.LOG Backups

Other generalizations/abstractions, like "PriorityDatabases.FULL Backups" equally make sense - the key recommendation is simply to have as few distinct jobs as truly needed, and to make sure the names of each job clearly indicates the job's purpose and what is being done within the job. (Then, of course, make sure that only commands relating to the Job's name are deployed/executed within a specific job - i.e., don't 'piggy back' some DIFF backups into a job whose name denotes FULL backups (create a distinct job instead).)

#### Job Categories
Job Categories are not important to job outcome or execution. If you'd like to create specialized Job Category Names for your backup jobs (i.e., like "Backups"), you can do so by right-clicking on the SQL Server Agent > Jobs node, and selecting "Manage Job Categories" - where you can then add (or remove) Job Category names as desired. 

![](https://git.overachiever.net/content/images/s4_doc_images/backups_jobcategories.gif)

#### Job Ownership
When creating jobs, it is a best practice to always make sure the job owner is 'sa' - rather than MACHINE\username or DOMAIN\username - to help provide better continuity of execution through machine/domain rename operations, and other considerations. 

[SQL Server Tip: Assign Ownership of Jobs to the SysAdmin Account](http://sqlmag.com/blog/sql-server-tip-assign-ownership-jobs-sysadmin-account).


#### Job Steps
As with Job Names, job step names should be descripive as well (even if there's a bit of overlap/repetition between the job name and given job-step name in cases where a job only has a single job-step). 

Likewise, for automated backups, Job Steps should be set to execute within the **admindb** database. 

![](https://git.overachiever.net/content/images/s4_doc_images/backups_jobstep1.gif)


#### Jobs with Multiple Job Steps
When you need to create SQL Server Agent Jobs with multiple Job Steps, you can do so by creating a job (as normal), adding a New/First step, and then adding as many 'New' job steps as you would like. Once you're done adding job steps, however, SSMS will have set up the "On Success" and "On Failure" outcomes of each job-step as outlined in the screenshot below: 

![](https://git.overachiever.net/content/images/s4_doc_images/backups_jobstep_multi.gif)

To fix/address, this, you'll need to edit EACH job step, switch to the Advanced tab per each Job step, and switch the "On failure action" to "Go to the next step" from the dropdown - on all steps OTHER than the LAST step defined. 

![](https://git.overachiever.net/content/images/s4_doc_images/backups_jobstep_onfail.gif)


#### Scheduling Jobs
When setting up Job Schedules for a job, it's usually best to keep things as simple as possible and only use a single schedule per job (though, you can definitely use more than one schedule if you're 100% confident that what you're doing makes sense (there's rarely ever a need to have multiple schedules for the same types of backups)). 

Furthermore, when scheduling jobs, you'll always want to pay attention to the 3 areas outlined in the screenshot below:
1. This is always set to recurring - by default - so you'll usually never NEED to modify this. 
2. Make sure you configure the option needed (i.e., most of the time this'll be Daily).
3. Occurs once vs Occurs every... are important options/specifications as well. 

![](https://git.overachiever.net/content/images/s4_doc_images/backups_schedule.gif)

#### Notifications
While dbo.backup_databases is designed to raise an error/alert (via email) any time a problem is encountered during execution, its possible that a BUG within dbo.backup_databases (or with some of the parameters/inputs you may have specified) will cause the job to NOT execute as expected. As such, 

### Step-By-Step - An Extended Example
Mia has the following databases and environment: 
- 2x testing databases: test1 and test2. 
- 1x 300GB critical database: ProdA. 
- 2x 10 - 20GB important databases: db1 and db2
- Enough disk space for all of her data and log files. 
- 500GB of backup space on N:\ in N:\SQLBackups
- 100GB of backup space on S:\ in S:\Scratch\Backups
- 800GB of backup space on \\\\Backup-Server\ProdSQL\

Assume that FULL backups of test1, test2, db1, and db2 consume an AVERAGE of 15GB each - or ~60GB total space - per day. 

Likewise, assume that FULL backups of ProdA consume ~140GB each (growing by about 1GB every 2 weeks).

Then, assume that T-Log backups for db1 and db2 consume around ~5GB (for both DBs) of space each day, whereas T-Logs for ProdA consume around 20GB of space per day. 

Mia is still working with management to come up with RPOs and RTOs that everyone can agree upon, but until she hears otherwise, she's going to execute T-LOG backups every 5 minutes, doesn't need DIFF backups of ProdA, and will execute FULL backups of all databases daily. 

To do facilitate this, she does the following. 

First, she defines the following call to dbo.backup_databases - for her System Databases:

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[SYSTEM]',
    @BackupDirectory = N'S:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```

She then creates a new Job, "System Databases.FULL Backups", sets it to be owned by 'sa', copies/pastes the code above into a single job step ("FULL Backup of System Databases"), sets it to execute every night at 7PM (which captures most changes made by admins during a 'work day') and where the few SECONDS it'll take to execute System backups won't even be noticed. She also sets the Notification tab to Notify "Alerts" if the job fails (in case there's a bug in dbo.backup_databases rather than a problem that might encountered while executing backups that would be 'trapped'). 

Second, she opts to set up a single Job for FULL user database backups - but she's going to need 2x Job Steps to account for the fact that she'll have to push ProdA to the N:\ drive and keep all other DBs on the S:\ drive - to avoid problems with space. 

So, she creates a new Job, "User Databases.FULL Backups", sets the owner to SA, configures it to Notify Alerts on failure, and schedules the job to run at 2AM every day. 

Next, she configures a call to dbo.backup_databases for JUST ProdA - as follows: 

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'ProdA',
    @BackupDirectory = N'N:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '72h', 
    @CopyToRetention = '96h';
```

And then she drops that into the first/initial Job Step for her job - with a name of "Full backups of ProdA - to N:\", and then copies/pastes in the code from above. 

Then, she configures a separate call to dbo.backup_databases for all other user databases - which she does by specifying [USER] for @DatabasesToBackup and 'ProdA' for @DatabasesToExclude. She also sets different (lesser) retention times - both for local AND off-box backups to conserve space and to FAVOR backups of ProdA over the other 'less important' databases:

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @DatabasesToExclude = N'ProdA',
    @BackupDirectory = N'S:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '48h', 
    @CopyToRetention = '48h';
```

With the call to dbo.backup_databases configured, she adds a new (second) Job Step to "User Databases.FULL Backups" called "Full Backups of all other dbs to S:\" and copies/pastes the code from above. Then, since she has 2 distinct Job-steps configured, she then switches to the Advanced Properties for her first job step (Full Backups of ProdA - to N:\), and ensures that the "On success action" as well as the "On failure actions" are BOTH set to the "Go to the next step" option - so that errors occur during execution of backups for ProdA, backups for all other (user) databases will attempt to execute.

Finally, she needs to create a Job to tackle transaction log backups - which'll run every 5 minutes and backup logs for all user databases that aren't in SIMPLE recovery mode. If she were able to push these T-LOG backups to the same location (locally and off-box), she'd just need a single job-step to pull this off. However, in this example scenario, we're assuming that she needs to push T-LOG backups for ProdA to the N:\ drive and T-LOG backups of her other User databases to the S:\ drive - and then copy those backups to \\\\BackupServer\ProdSQL\ - where she'll keep copies of the ProdA database longer than those of the other databases (i.e., db1 and db2). To do this, she first creates a call to dbo.backup_databases to address the log backups for the ProdA database:

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'ProdA',
    @BackupDirectory = N'N:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```

Then, she does the 'inverse' for her other databases - by specifying [USER] for @DatabasesToBackup and 'ProdA' for @DatabasesToExclude - and then changing paths and retention times as needed:

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'[USER]',
    @DatabasesToExclude = N'ProdA',
    @BackupDirectory = N'S:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '24h', 
    @CopyToRetention = '48h';
```

With these tasks complete, she then creates a new job ("User Databases.LOG Backups"), sets the owner to 'sa', schedules the job to run every 5 minutes - starting a 4:00 AM and running the rest of the day (i.e., until midnight), specifies that the job should notify her upon failure, pastes in the commands above into 2 distinct Job Steps (one for ProdA, the other for the other databases), and then makes sure that Job Step 1 will always "Go to the next step" after successful or failed executions. 

At this point, she's effectively done - other than monitoring how much space the backups take over the next few days, and then periodically testing the backups (i.e., via full-blown restore operations), to make sure they're meeting her RPOs and RTOs (instead of waiting to see what kinds of coverage/outcome she gets AFTER a disaster occurs - assuming her untested backups even work at that point).

[Return to Table of Contents](#toc)

## Troubleshooting Common Backup Problems

### Backup Folder Permissions
In order for SQL Server to write backups to a specific folder (on-box or out on the network), you will need to make sure that the Service Account under which SQL Server runs has access to the folder(s) in question. 

To determine which account your SQL Server is running under, launch the SQL Server Configuration Manager, then, on the SQL Server Services tab, find the MSSQLSERVER service (or the service that corresponds to your named instance if you're not on the default SQL Server instance), then double-click on the service to review Log On information. 

![](https://git.overachiever.net/content/images/s4_doc_images/backups_services.gif)

Whatever username is specified in the Log On details - is the Windows account name that your SQL Server (instance) is executing under - and will be the account that will need access to any folders or locations where you might be writing backups. 

***NOTE:** If you're currently running SQL Server as NT SERVICE\MSSQLSERVER you CAN provide this specific 'user' access to any folder on your LOCAL machine, but likely won't be able to grant said account permissions on your UNC backup targets/shares. (Likewise, if you're running as any type of built-in or local service account, this account will NOT have the ability to access off-box resources at all.) In cases where you are not able to assign built-in or system-local-only accounts permissions against off-box resources, you'll need to change the account that your SQL Server is running under. On a domain, create a new Domain user (with membership in NO groups other than 'users') - and then use the SQL Server Configuration Manager to change the Log on credentials accordingly - then restart your SQL Server service for the changes to take effect. If you're in a workgroup, you'll need to create a user with the exact same username and password on your local SQL Server and any 'remote' servers it might need to access - and then you'll be able to run SQL Server as, say, DBSERVER1\sql_service (after making changes on the Log On tab in the SQL Server Configuration Manager) and you'll be able to grant local backup permissions (i.e., against - say, D:\SQLBackups) to DBSERVER1\sql_service AND assign permissions on your 'backups server' to something like BACKUPSERVER\sql_server and, as long as the username and password on BOTH machines are identical, Windows will be able to use NTLM permissions within a workgroup to control access.* 

***NOTE:** On many SQL Server 2012 and above instances of SQL Server, any folders (on-box) that you wish to have SQL Server write backups to, will also need to have the NT SERVICE\MSSQLSERVER 'built-in' account granted modify or full control permissions before backups will be able to be written.*

[Return to Table of Contents](#toc)