# S4 Backups
While SQL Server's Native Backup capabilities provide a huge degree of flexibility and fine-tuning, the vast majority of SQL Server database backups only need a very streamlined and simplified subset of all of those options and capabilities. 

As such, S4 Backups address the following primary concerns:

- **Simplicity.** Streamline the most commonly used features needed for backing up mission-critical databases into a set of simplified parameters that make automating backups of databases easy and efficient - while still vigorously ensuring disaster recovery best-practices.
- **Resiliency** Wrap execution handling with low-level exception and error handling routines that prevent a failure in one operation (such as the failure to backup one database out of 10 specified) from 'cascading' into others and causing a 'chain' of operations from completing merely because an 'earlier' operation failed. 
- **Transparency** Use the same low-level exception and error-handling routines designed to make backups more resilient to log problems in a centralized logging table (for trend-analysis and improved troubleshooting) and send email alerts with concise details about each failure or problem encountered during execution so that DBAs can quickly ascertain the impact and severity of any errors or problems incurred (without having to wade through messy 'debugging' and troubleshooting procedures just to figure out what happened).


## Table of Contents
- [Benefits of S4 Backups](#benefits)
- [Supported SQL Server Versions](#supported)
- [Deployment](#deployment)
- [Syntax](#syntax)
- [Remarks](#remarks)
- [Examples](#examples)
- [Setting up Automated Jobs](#setting-up-automated-jobs)

## <a name="benefits"></a>Benefits of S4 Backups
Key Benefits Provided by S4 Backups:

- Simplicity, Resiliency, and Transparency: commonly needed and used SQL Server functionality - in simple to use and manage scripts. 
- Streamlined Deployment and Management. No dependencies on external DLLs, outside software, or additional components. Instead, S4 Backups are set of simple wrappers around native SQL Server Native Backup capabilities - designed to enable Simplicity, Resiliency, and Transparency when tackling backups.
- Designed to facilitate copying backups to multiple locations (i.e., on-box backups + UNC backups (backups of backups) - or 2x UNC backup locations, etc.)
- Enable at-rest-encryption by leveraging SQL Server 2014's (+) NATIVE backup encryption (only available on Standard and Enteprise Editions).
- Leverages Backup Compression on all supported Versions and Editions of SQL Server (2008 R2+ Standard and Enterprise Editions) and transparently defaults to non-compressed backups for Express and Web Editions.
- Supports logging of operational backup metrics (timees for backups, file copying, etc.) for trend analysis and review.
- Supports Mirrored and 'Simple 2-Node' (Failover only) Availability Group databases.

## <a name="supported"></a>Supported SQL Server Versions
S4 Backups were designed to work with SQL Server 2008 and above. 

S4 Backups were also designed to work with all Editions of SQL Server - though features which aren't supported on some Editions (like Backup Encryption on Web/Express Editions) obviously won't work. Likewise, SQL Express Editions can't send emails/alerts - so @OperatorName, @MailProfileName, and @EmailSubjectPrefix parameters are all ignored AND no alerts can/will be sent upon failures or errors from SQL Express Editions.

S4 Backups have not (yet) been tested against case-sensitive SQL Servers.

***NOTE:** As with any SQL Server deployment, S4 Backup scripts are NOT suitable for use in backing up databases to NAS (Network Attached Storage) devices. SANs, Direct-Attached Disks, iSCSI (non-NAS), and other disk-configurations are viable, but the 'file-level' nature of NAS devices vs the block-level nature (of almost all other devices) required by SQL Server operations will cause non-stop problems and 'weird' device errors and failures when executing backups.*

## Deployment

info on how to deploy... 
- sp_cmdshell... 
- common
- table
- sproc..
- done... recommend review notes and examples... 

## Syntax 

```sql
EXEC dbo.dba_BackupDatabases
    @BackupType = '{ FULL|DIFF|LOG }', 
    @DatabasesToBackup = N'{ widgets,hr,sales,etc } | [SYSTEM] | [USER] }', 
    [@DatabasesToExclude = N'',] 
    @BackupDirectory = N'd:\sqlbackups', 
    [@CopyToBackupDirectory = N'',]
    @BackupRetentionHours = int-retention-hours, 
    [@CopyToRetentionHours = int-retention-hours,]
    [@EncryptionCertName = 'ServerCertName',] 
    [@EncryptionAlgorithm = '{ AES 256 | TRIPLE_DES_3KEY }',] 
    [@AddServerNameToSystemBackupPath = { 0 | 1 },] 
    [@AllowNonAccessibleSecondaries = { 0 | 1 },] 
    [@LogSuccessfulOutcomes = { 0 | 1 },] 
    [@OperatorName = NULL,]
    [@MailProfileName = NULL,] 
    [@EmailSubjectPrefix = N'',] 
    [@PrintOnly = NULL] 
	;
```

### Arguments
**@BackupType** = '{ FULL | DIFF | LOG }'

Required. The type of backup to perform (FULL backup, Differential backup, or Transaction-Log Backup). Permitted values are FULL | DIFF | LOG.

**@DatabasesToBackup** =  { list, of, databases, to, backup, by, name | [USER] | [SYSTEM] }

Required. Either a comma-delimited list of databases to backup by name (e.g., 'db1, dbXyz', 'Widgets') or a specialized token (enclosed in square-brackets) to specify that either [SYSTEM] databases should be backed up, or [USER] databases should be backed up. 

**[@DatabasesToExclude** = 'list, of, database, names, to exclude' ]

Optional. Designed to work with [USER] (or [SYSTEM]) tokens (but also works with a specified list of databases). Removes any databases (found on server), from the list of DBs to backup. 

**@BackupDirectory** = 'path-to-root-folder-for-backups'

Required. Specifies the path to the root folder where all backups defined by @DatabasesToBackup will be written. Must be a valid Windows Path - and can be either a local path or UNC path. 

**[@CopyToBackupDirectory]** = 'path-to-folder-for-COPIES-of-backups']

Optional. When specified, backups (written to @BackupDirectory) will be copied to @CopyToBackupDirectory as part of the backup process. Must be a valid Windows path and, by design (though not enforced), should be an 'off-box' location for proper protection purposes. 

**@BackupRetenionHours** = integer-hours-to-retain-backups

Required. Must be greater than 0. Specifies the amount of time, in hours, that backups of the current type (i.e., @BackupType) should be retained or kept. For example, if an @BackupType of 'LOG' is specified and an @BackupDirectory of 'D:\Backups' is specified along with a @BackupRetentionHours value of 24 (hours), then if database 'Widgets' is being backed up, dba_BackupDatabases will then remove any .trn (transaction log backups) > 24 hours old while keeping any (transaction-log) backups < 24 hours old. 

**NOTE:** *Retention details are only applied against the @BackupType being currently executed. For example,  T-Log backups with an @BackupRetentionHours of 24 hours will NOT remove FULL or DIFF backups for the same database (even in the same folder) - and only if/when the name of the database is matched AND only when the same @BackupDirectory for the previous backups is specified as the backups being currently executed. Or, in other words, dba_BackupDatabases does NOT 'remember' where your previous backups were stored and go out and delete any previous backups older than @BackupRetentionHours. Instead, after each database is backed up, dba_BackupDatabases will check the 'current' folder for any backups of @BackupType that are older than @BackupRetentionHours and ONLY remove those files if/when the file-backup-names match those of the database being backed up, when the files are in the same folder, and if the backups themselves are older than @BackupRetentionHours.*

**[@CopyToRetentionHours] = integer-hours-to-retain-COPIES-of-backups]

This parameter is required if @CopyToBackupDirectory is specified. Otherwise, it works almost exactly like @BackupRetentionHours (in terms of how files are evaluated and/or removed) BUT provides a separate set of retention details for your backup copies. Or, in other words, you could specify a @BackupRetentionHours of 24 for your FULL backups of on-box backups (i.e., @BackupDirectory backups), and a value of 48 (or whatever else) for your @CopyToRetentionHours - meaning that 'local' backups of the type specified would be kept for 24 hours, while remote (off-box) backups were kept for 48 hours. 


**[@EncryptionCertName]** = 'NameOfCertToUseForEncryption'

Optional. If specified, backup operation will attempt to use native SQL Server backup by attempting to encrypt the backup using the @EncryptionCertName (and @EncryptionAlgorithm) specified. If the specified Certificate Name is not found (or if the version of SQL Server is earlier than SQL Server 2014 or a non-supported edition (Express or Web) is specified), the backup operation will fail. 

**[@EncryptionAlgorith]** = '{ AES_256 | TRIPLE_DES_3KEY }'

This parameter is required IF @EncryptionName is specified (otherwise it must be left blank or NULL). Recommended values are either AES_256 or TRIPLE_DES_3KEY. Supported values are any values supported by your version of SQL Server. (See the [Backup](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql) statement for more information.)

**[@AddServerNameToSystemBackupPath]** = { 0 | 1 }

Optional. Default = 0 (false). For servers that are part of an AlwaysOn Availabilty Group or participating in a Mirroring topology, each server involved will have its own [SYSTEM] databases. When they're backed up to a centralized location (typically via the @CopyToBackupPath), there needs to be a way to differentiate backups from, say, the master database on SERVER1 from master databases backups from SERVER2. By flipping @AddServerNameToSystemBackupPath = 1, the full path for [SYSTEM] database backups will be: Path + db_name + server_name e.g., \\backup-server\sql-backups\master\SERVER1\ - thus ensuring that system-level database backups from SERVER1 do NOT overwrite system-level database backups created/written by SERVER2 and vice-versa. 

**[@AllowNonAccessibleSecondaries]** = { 0 | 1 } 

Optional. Default = 0 (false). By default, once the databases in @DatabasesToBackup has been converted into a list of databases, this 'list' will be compared against all databases on the server that are in a STATE where they can be backed-up (databases participating in Mirroring, for example, might be in a RECOVERING state) and IF the 'list' of databases to backup then is found to contain NO databases, dba_BackupDatabases will throw an error because it was instructed to backup databases but FOUND no databases to backup. However, IF @AllowNonAccessibleSecondaries is set to 1, then IF @DatabasesToBackup = 'db1,db2' and DB1 and DB2 are both, somehow, not in an online/backup-able state, dba_BackupDatabases will find that NO databases should be backed up after initial processing, will 'see' that @AllowNonAccessibleSecondaries is set to 1 and rather than throwing an error, will terminate gracefully. 

**NOTE:** *@AllowNonAccessibleSecondaries should ONLY be set to true (1) when Mirroring or Availability Groups are in use and after carefully considering what could/would happen IF execution of backups did NOT 'fire' because the databases specified by @DatabasesToBackup were all found to be in a state where they could NOT be backed up.*

**[@LogSuccessfulOutcomes]** = { 0 | 1 }

Optional. Default = 0 (false). By default, dba_BackupDatabases will NOT log successful outcomes to the  dba_DatabaseBackups_log table (though any time there is an error or problem, details will be logged regardless of this setting). However, if @LogSuccessfulOutcomes is set to true, then succesful outcomes (i.e., those with no errors or problems) will also be logged into the dba_DatabaseBackups_Log table (which can be helpful for gathering metrics and extended details about backup operations if needed). 

**[@OperatorName** = 'sql-server-agent-operator-name-to-send-alerts-to' ]

Defaults to 'Alerts'. If 'Alerts' is not a valid Operator name specified/configured on the server, dba_BackupDatabases will throw an error BEFORE attempting to backup databases. Otherwise, once this parameter is set to a valid Operator name, then if/when there are any problems during execution, this is the Operator that dba_BackupDatabases will send an email alert to - with an overview of problem details. 

**[@MailProfileName]** = 'name-of-mail-profile-to-use-for-alert-sending']

Deafults to 'General'. If this is not a valid SQL Server Database Mail Profile, dba_DatabaseBackups will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during backups. 

**[@EmailSubjectPrefix** = 'Email-Subject-Prefix-You-Would-Like-For-Backup-Alert-Messages']

Defaults to '[Database Backups ] ', but can be modified as desired. Otherwise, whenever an error or problem occurs during execution an email will be sent with a Subject that starts with whatever is specified (i.e., if you switch this to '--DB2 BACKUPS PROBLEM!!-- ', you'll get an email with a subject similar to '--DB2 BACKUPS PROBLEM!!-- Failed To complete' - making it easier to set up any rules or specialized alerts you may wish for backup-specific alerts sent by your SQL Server.

**[@PrintOnly** = { 0 | 1 }]

Defaults to 0 (false). When set to true, processing will complete as normal, HOWEVER, no backup operations or other commands will actually be EXECUTED; instead, all commands will be output to the query window (and SOME validation operations will be skipped). No logging to dba_BackupDatabases_Log will occur when @PrintOnly = 1. Use of this parameter (i.e., set to true) is primarily intended for debugging operations AND to 'test' or 'see' what dba_BackupDatabases would do when handed a set of inputs/parameters.


## Remarks

### General Best-Practices for SQL Server Backups

For background and insights into how SQL Server Backups work, the following, free, videos can be very helpful in bringing you up to speed: 

- [SQL Server Backups Demystified.](http://www.sqlservervideos.com/video/backups-demystified/) 
- [SQL Server Logging Essentials.](http://www.sqlservervideos.com/video/logging-essentials/)
- [Understanding Backup Options.](http://www.sqlservervideos.com/video/backup-options/)
- [SQL Server Backup Best Practices.](http://www.sqlservervideos.com/video/sqlbackup-best-practices/)

Otherwise, some highly-simplified best-practices for automating SQL Server backups are as follows:
- Generally speaking, backups do NOT consume as many resources as most people initially fear - so they shouldn't be 'feared' or 'used sparingly'. (Granted, FULL backups against larger databases CAN put some stress/strain on the IO subsystem - so they should be taken off-hours or 'at night' as much as possible. Likewise, DIFF backups (which can be taken 'during the day' and at periods of high-load (to decrease how much time is required to restore databases in a disater) CAN consume some resources during the day when taken, but this needs typically slight negative needs to be contrasted with the positive/win of being able to restore databases more quickly in the case of certain types of disaster. Otherwise, when executed regularly (i.e., every 5 to 10 minutes), Transaction Log backups typically don't consume more resources than some 'moderate queries' that could be running on your systems and NEED to be executed regularly to ensure you have options and capabilities to recover from disasters. In short, humans are wired for scarcity; forget that and be 'eager' with your backups, then watch for any perf issues and address/react accordingly (instead of fearing that backups might cause problems - as it is guaranteed that a LACK of proper/timely backups will cause WAY more problems when an emergency occurs.)
- All databases, including dev/testing/stating databases, should typically see a FULL backup every day. The exception of exclusion would be VERY LARGE databases (i.e., databases > 1TB start being consired LARGE (not necessarily VERY LARGE) database and start to fall outside the scope of [Branded Name] Backups), OR dev/test databases in SIMPLE recovery mode that don't see much activity and could 'lose a week' (or multiple days/whatever) of backups without causing ANY problems. As such, you should typically create a nightly job that executes FULL backups of all [SYSTEM] databases (see Example B - below) and another, distinct, job that executes FULL backups of [USER] databases (see Example C below). Then, if you've got some (user) databases you're SURE you don't care about AND that you can recreate if needed, then you can exclude these using @DatabasesToExclude.
- Once FULL backups of all (key/important and even important-ish) databases have been addressed (i.e., you've created jobs for them), you may want to consider setting up DIFF backups DURING THE DAY to address 'vectored' backups of larger and VERY HEAVILY used databases - as a means of decreasing recovery times in a disaster. For example, if you've got a 300GB database that sees a few thousand transactions per minute (or more), and generates MBs or 10s of MBs of (compressed) T-LOG backups every 5 or 10 minutes when T-Log backups are run, then if you run into a disaster at, say, 3PM, you're going to have to restore a FULL Backup for this database plus a LOT of transactional activity - which CAN take a large amount of time. Therefore, if you've got specific RTOs in place, one means of 'boosting' recovery times is to 'interject' DIFF backups at key periods of the day. So, for example, if you took a FULL backup at 2AM, and DIFF backups at 8AM, Noon, and 4PM, then ran into a disaster at 3PM, you'd restore the 2AM FULL + the Noon DIFF (which would let you buypass 10 hours of T-Log backups) to help speed up execution. As such, if something like this makes sense in your environment, make sure to review the examples (below), and then pay special attention to Example E - which showcases how to specify that specific databases should be targeted for DIFF backups. 
- Otherwise, in terms of Transaction Log backups, these SHOULD be executed every 10 minutes at least - and as frequently as every 3 minutes (on very heavily used systems).On some systems, you may want or need T-Log backups running 24 hours/day (i.e., transactional coverage all the time). On other (less busy systems), you might want to only run Transaction Log backups between, say, 4AM (when early users start using the system) until around 10PM when you're confident the last person in the office will always, 100%, be gone. Again, though, T-Log backups don't consume many resources - so, when in doubt: just run T-Log backups (they don't hurt anything). **Likewise, do NOT worry about T-Log backups 'overlapping' or colliding with your FULL / DIFF backups; if they're set to run at the same time, SQL Server is smart and won't allow anything to break (or throw errors) NOR will it allow for any data loss or problems.** Otherwise, as defined elsewhere, when a @BackupType of 'LOG' is specified, dba_BackupDatabases will backup the transaction logs of ALL (user) databases not set to SIMPLE recovery mode. As such, if you are CONFIDENT that you do NOT want transaction log backups of specific databases (dev, test, or 'read-only' databases that never change OR where you 100% do NOT care about the loss of transactional data), then you should 'flip' those databases to SIMPLE recovery so that they're not having their T-Logs backed up.
- In terms of storage or WHERE you put your backups, there are a couple of rules of thumb. **First, it is NEVER good enough to keep your ONLY backups on the same server (i.e., disks) as your data. Doing so means that a crash or failure of your disks or system will take down your data and your backups.** As such, you should ALWAYS make sure to have off-box copies or backups of your databases (which is why the @CopyToBackupDirectory and @CopyToRetentionHours parameters exist). Arguably, you can and even SHOULD (in many - but not all) then ALSO have copies of your backups on-box (i.e., in addition to off-box copies). And the reason for this is that off-box backups are for hardware disasters - situations where a server catches fire or something horrible happens to your IO subsystem - whereas on-box backups are very HELPFUL (but not 100% required) for data-corruption issues (i.e., problems where you run into phsyical corruption or logical corruption) where your hardware is FINE - because on-box backups mean that you can start up restore operations immediately and from local disk (which is usually - but not always) faster than disk stored 'off box' and somewhere on the network. Again, though, the LOGICAL priority is to keep off-box backups first (usually with a longer retention rate as off-box backup locations typically tend to have greater storage capacity) and then to keep on-box 'copy' backups locally as a 'plus' or 'bonus' whenever possible OR whenever required by SLAs (i.e., RTOs). Note, however, that while this is the LOGICAL desired outcome, it's typically a better practice (for speed and resiliency purposes) to write/create backups locally (on-box) and then copy them off-box (i.e., to a network location) after they've been created locally. As such, many of the examples in this documentation point or allude to having backups on-box first (the @BackupDirectory) and the 'copy' location second (i.e., @CopyToBackupDirectory). 
- Another best practice with backups, is how to organize or store them. Arguably, you could simply create a single folder and drop all backups (of all types and for all databases) into this folder as a 'pig pile' - and SQL Server would have no issues with being able to restore backups of your databases (if you were to use the GUI). However, humans would likely have a bit of a hard time 'sorting' through all of these backups as things would be a mess. An optimal approach is to, instead, create a sub-folder for each database, where you will then store all FULL, DIFF, and T-LOG backups for each database so that all backups for a given database are in a single folder. With this approach, it's very easy to quickly 'sort' backups by time-stamp to get a quick view of what backups are available and roughly how long they're being retained. This is a VERY critical benefit in situations where you can't or do NOT want to use the SSMS GUI to restore backups - or in situations where you're restoring backups after a TRUE disaster (where the backup histories kept in the msdb are lost - or where you're on brand new hardware). Furthermore, the logic in [Branded Name] Restore-Tests is designed to be 'pointed' at a folder or path (for a given database name) and will then 'traverse' all files in the folder to restore the most recent FULL backup, then restore the most recent DIFF backup (since the FULL) if one exists, and conclude by restoring all T-LOG backups since the last FULL or DIFF (i.e., following the backup chain) to complete restore a database up until the point of the last T-LOG backup (or to generate a list of commands that would be used - via the @PrintOnly = 1 option - so that you can use this set of scripts to easily create a point-in-time recovery script). Accordingly, dba_BackupDatabases takes the approach of assuming that the paths specified by @BackupDirectory and/or @CopyToBackupDirectory are 'root' locations and will **ALWAYS** create child directories (if not present) for each database being backed up. (NOTE that if you're in the situation where you don't have enough disk space for ALL of your backups to exist on the same disk or network share, you can create 2 or more backup disks/locations (e.g., you could have D:\SQLBackups and N:\SQLBackups (or 2x UNC locations, etc.)) and then assign each database to a specific disk/location as needed - to 'spread' your backups out over different locations. If you do this, you MIGHT want to create 2x different jobs per each backup type (i.e., 2x jobs for FULL backups and 2x jobs for T-Log Backups) - each with its own corresponding job name (e.g. "Primary Databases.FULL Backups" and "Secondary Databases.FULL Backups"); or you might simply have a SINGLE job per backup type (UserDatabases.FULL Backups and UserDatabases.LOG Backups) and for each job either have 2x job-steps (one per each path/location) or have a single job step that first backups up a list of databases to the D:\ drive, and then a separate/distinct execution of dba_BackupDatabases below the first execution (i.e., 2x calls to dba_BackupDatabases in the same job step) that then backs up a differen set of databases to the N:\ drive. 
- In terms of retention times, there are two key considerations. First: backups are not the same thing as archives; archives are for legal/forensic and other purposes - whereas backups are for disaster recovery. Technically, you can create 'archives' via SQL Server backups without any issues (and dba_BackupDatabases is perfectly suited to this use) - but if you're going to use dba_BackupDatabase for 'archive' backups, make sure to create a new / distinct job with an explicit name (e.g., "Monthly Archive Backups"), give it a dedicated schedule - instead of trying to get your existing, nightly (for example) job that tackles FULL backups of your user databases to somehow do 'dual duty'. However, be aware that dba_BackupDatabases does NOT create (or allow for) COPY_ONLY backups - so IF YOU ARE USING DIFF backups against the databases being archived, you will want to make sure that IF you are creating archive backups, that you create those well before normal NIGHTLY backups so that when your normal, nightly, backups execute you're not breaking your backup chain. Otherwise, another option for archival backups is simply to have an automated process simply 'zip out' to your backup locations at a regularly scheduled point and 'grab' and COPY an existing FULL backup to a safe location. Otherwise, the second consideration in terms of retention is that, generally, the more backups you can keep the better (to a point - i.e., usually anything after 2 - 4 days isn't ever going to be used - because if you're doing things correctly (i.e., regular DBCC/Consistency checks and routinely (daily) verifying your backups by RESTORING them, you should never need much more that 1 - 2 days' worth of backups to recover from any disaster). Or, in other words, any time you can keep roughly 1-2 days of backups 'on-box', that is typically great/ideal as it will let you recovery from corruption problems should the occur - in the fastest way possible; likewise, if you can keep 2-3 days of backups off-box, that'll protect against hardware and other major system-related disasters. If you're NOT able to keep at least 2 days of backups somewhere, it's time to talk to management and get more space.
- Finally, [Branded Name] Backups are ONLY capable of creating and managing SQL Server Backups. And, while dba_BackupDatabases is designed and optimized for creating off-box backups, off-box backups (alone), aren't enough of a contingency plan for most companies - because while they will protect against situations where youl 100% lose your SQL Server (where the backups were made), they won't protect against the loss of your entire data-center or some types of key infrastructure (the SAN, etc.). Consequently, in addition to ensuring that you have off-box backups, you will want to make sure that you are regularly copying your backups off-site. (Products like [CloudBerry Server Backup](https://www.cloudberrylab.com/backup/windows-server.aspx) are cheap and make it very easy and affordable to copy backups off-site every 5 minutes or so with very little effort. Arguably, however, you'll typically WANT to run any third party (off site) backups OFF of your off-box location rather than on/from your SQL Server - to decrease disk, CPU, and network overhead. However, if you ONLY have a single SQL Server, go ahead and run backups (i.e., off-site backups) from your SQL Server (and get a more powerful server if needed) as it's better to have off-site backups.)


### S4 Backup Specifics
dba_BackupDatabases was primarily designed to facilitate automated backups - i.e., regular backups executed on the server for disaster recovery purposes. It can, of course, be used to execute 'ad-hoc' backups if or when needed BUT does NOT (currently) allow COPY-ONLY backups (which isn't an issue unless your environment makes regular use of DIFFERENTIAL backups for speed or other recovery-purpose needs).

The order of operations (within dba_BackupDatabases) is:

- Validate Inputs
- Construct a List of Databases to Backup (based on @DatabasesToBackup and @DatabasesToExclude parameters)
- Then, for each database to be backed up, the following operations are executed (in the following order):
- Construct and the execute a backup. 
- Copy backup to copy path (if/as specified).
- Remove expired backups from local AND from copy (explicit checks in both locations).
- send email alert on any errors or problems (code is designed to (ideally) not crash or stop execution upon error, but to keep going and report all errors at end of execution - that way if one db backup fails or a copy operation fails, or there's an issue with removing an older file, all other operations will/should (ideally) complete as expected).

Need to make all of this stuff be as succinct as possible: (i.e., the stuff on folder expectations/conventions - and... that it's still possible to put 'reallyBigDB' on the N drive or whatever... if needed - but that all backups of a single db should/typically... go to the same folder - other-wise @Retention params simply can't work)
[dba_BackupDatabases assumes that all SQL Server backups will (typically) be stored in a shared folder - i.e., something like D:\SQLBackups\ - meaning that dba_BackupDatabases will, by design, create a sub-folder for each database being backed up... 
All @BackupType backups for any given/specified database SHOULD be stored in the same folder (though nothing within this solution - or SQL Server in general - will enforce this recommendation). ]

[stuff about backups - i.e., on-box vs off-box and the need for both or, at least: the need for off-box. So, if NOT using on-box AND off-box, path for @BackupDirectory should be a UNC share - to ensure that backups are stored off-box and NOT on the same machine/VM as the database files themselves.]

[info on how @CopyToBackupDirectory will use Enterprise Edition stuff when ... it's enterprise edtiion -otherwise, the process is: backup, verify, then use xp_cmdshell to execute a copy operation... ]

Native SQL Server Encryption requires SQL Server 2014 and above. See the following link for more details: 

[WARNING:] If using native encryption, backup cert needs to be backed up and details securely stored in a safe place. 

[if you've got multiple databases (i.e., say 20) and you're executing t-log backups every 5 minutes (for example) that's 288 * 20 = or 5760 rows/day added to the dba_backups_log tble if @LogSuccessfulOutcomes is set to 0. That's actually NOT much in terms of data (about xyz data/day)... but this can add up quickly... ]

It is HIGHLY recommended that before scheduling any jobs using dba_BackupDatabases, that you FIRST specify the parameters for dba_BackupDatabases as you think you would like them, and then flip @PrintOnly to 1, and run a 'debug output' pass of the sproc - to verify that you're processing all of the databases you would expect to be processing, and that all paths and other configured steps are defined exactly as desired. Then, once you've got things working as expected, **MAKE SURE TO SET @PrintOnly = 0** (or simply remove it entirely), and then copy/paste your configured parameters into a SQL Server Agent Job Step for automated execution

## Examples 

### A. FULL Backup of System Databases to an On-Box Location (Only)

The following example will backup all system databases (master, model, and msdb (there's no need to backup tempdb - nor can it be backed up)) to D:\SQLBackups. Once completed, there will be a new subfolder for each database backed up (i.e., D:\SQLBackups\master and D:\SQLBackups\model, etc.) IF there weren't folders already created with these names, and a new, FULL, backup of each database will be dropped into each respective folder. 

Further, any FULL backups of these databases that might have already been in this folder will be evaluated to review how old they are, and any that are > 48 hours old will be deleted - as per the @BackupRetentionHours specification. 

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = 'FULL', 
    @DatabasesToBackup = N'[SYSTEM]', 
    @BackupDirectory = N'D:\SQLBackups', 
    @BackupRetentionHours = 48;
```

Note too that the example above contains, effectively, the minimum number of specified parameters required for execution (i.e., which DBs to backup, what TYPE of backup, a path, and a retention time). 

REMINDER: It's NEVER a good idea to backup databases to JUST the local-server. Doing so puts your backups and data on the SAME machine and if that machine crashes and can't be recovered, burns to the ground, or runs into other significant issues, you've just lost your data AND backups. 

### B. FULL Backup of System Databases - Locally and to a Network Share

The following example duplicates what was done in Example A, but also pushes copies of System Database backups to the 'Backup Server' (meaning that the path indicated will end up having sub-folders for each DB being backed up, with backups in each folder as expected). 

Note the following: 

- Unlike Example A, the paths specified in this execution end with a trailing slash (i.e., D:\SQLBackups\ instead of D:\SQLBackups). Either option is allowed, and paths will be normalized during execution. 
- Local backups (those in D:\SQLBackups) will be kept for 48 hours, while those on the backup server (where we can assume there is more disk space in this example) will be kept for 72 hours - showing that it's possible to specify different backup retention rates for @BackupDirectory and @CopyToBackupDirectory folders. 

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[SYSTEM]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72; -- longer retention than 'on-box' backups
```

### C. Full Backup of All User Databases - Locally and to a Network Share

The following example is effectively identical to Example B, only, in this example, all user datbases are being specified - by use of the [USER] token. Once execution is complete:

- A folder will be created for each (user) database on the server where this code is executed - if a folder didn't already exist. 
- A new FULL backup will be added to the respective folder for each database. 
- Copies of these changes will be mirrored to the @CopyToBackupDirectory (i.e., a new sub-folder per each DB and a FULL backup per each database/folder). 
- Retention rates (per database) will be processed against each-subfolder found at @BackupDirectory and each subfolder found at @CopyToBackupDirectory. 

Note, however, that the only tangible change between this example and Example B is that @DatabaseToBackup has been set to backup [USER] databases. 

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72;
```

### D. Full Backup of User Databases - Excluding explicitly specified databases

This example executes identically to Example C - except the databases Widgets, Billing, and Monitoring will NOT be backed up (if they're found on the server). Note that excluded database names are comma-delimited, and that spaces between db-names do not matter (they can be present or not). Likewise, if you specify the name of a database that does NOT exist as an exclusion, no error will be thrown and any databases OTHER than those explicitly excluded will be backed up as specified. 

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @DatabasesToExclude = N'Widgets, Billing,Monitoring', 
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72;
```
### E. Explicitly Specifying Database Names for Backup Selection

Assume you've already set up a nightly job to tackle FULL backups of all user databases (and that you've got T-LOG backups configured as well), but have 2x larger databases that require a DIFF backup at various points during the day (say noon and 4PM) in order to allow restore-operations to complete in a timely fashion (due to high-volumes of transactional modifications during the day). 

In such a case you wouldn't want to specify [USER] (if you've got, say 12 user databases total) for which databases to backup. Instead, you'd simply want to specify the names of the databases to backup via @DatabasesToBackup. (And note that database names are comma-delimited - where spaces between db-names are optional (i.e., won't cause problems)). 

In the following example, @BackupType is specified as DIFF (i.e., a DIFFERENTIAL backup), and only two databases are specifically specified (Shipments and ProcessingProd) - meaning that these two databases are the only databases that will be backed-up (with a DIFF backup). As with all other backups, the DIFF backups for this execution will be dropped into sub-folders per each database.

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'DIFF', 
    @DatabasesToBackup = N'Shipments, ProcessingProd',
    @DatabasesToExclude = N'Widgets, Billing,Monitoring', 
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72;
```

### F. Setting up Transaction-Log Backups

In the following example, Transaction-log backups are targeted (i.e., @BackType = 'LOG'). As with other backups, these will be dropped into sub-folders corresponding to the names of each database to be backed-up. In this case, rather than explicitly specifying the names of databases to backup, this example specifies the [USER] token for @DatabasesToBackup. During execution, this means that dba_BackupDatabases will create a list of all databases in FULL or BULK-LOGGED Recovery Mode (databases in SIMPLE mode cannot have their Transaction Logs backed up and will be skipped), and will execute a transaction log backup for said databases. (In this way, if you've got, say, 3x production databases running in FULL recovery mode, and a handful of dev, testing, or stage databases that are also on your server but which are set to SIMPLE recovery, only the databases in FULL/BULK-LOGGED recovery mode will be targetted. Or, in other words, [USER] is 'smart' and will only target databases whose transaction logs can be backed up when @BackupType = 'LOG'.)

Notes:
- If all of your databases (i.e., on a given server) are in SIMPLE recovery mode, attempting to execute with an @BackupType of 'LOG' will throw an error - because it won't find ANY transaction logs to backup. 
- In the example below, @BackupRetentionHours has been set to 49 (hours). Previous examples have used 'clean multiples' of 24 hour periods (i.e., days) - but there's no 'rule' about how many hours can be specified - other than that this value cannot be 0 or NULL. (And, by setting the value to 'somewhat arbitrary' values like 25 hours instead of 24 hours, you're ensuring that if a set of backups 'go long' in terms of execution time, you'll always have a full 24 hours + a 1 hour backup worth of backups and such.)


```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 49, 
    @CopyToRetentionHours = 72;
```


### G. Using a Certificate to Encrypt Backups

The following example is effectively identical to Example D - except that the name of a Certificate has been supplied - along with an encryption algorithm, to force SQL Server to create encrypted backups. When encrypting backups:
- You must create the Certificate being used for encryption BEFORE attempting backups (see below for more info). 
- You must specify a value for both @EncryptionCertName and @EncryptionAlgorithm.
- Unless this is a 'one-off' backup (that you're planning on sharing with someone/etc.), if you're going to encrypt any of your backups, you'll effectively want to encrypt all of your backups (i.e., if you encrypt your FULL backups, make sure that any DIFF and T-LOG backups are also being encrypted). 
- While encryption is great, you MUST make sure to backup your Encryption Certificate (which requires a Private Key file + password for backup) OR you simply won't be able to recover your backups on your server if something 'bad' happens and your server needs to be rebuilt or on any other server (i.e., smoke and rubble contingency plans) without being able to 'recreate' the certificate used for encryption. 

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 49, 
    @CopyToRetentionHours = 72, 
    @EncryptionCertName = N'BackupsEncryptionCert', 
    @EncryptionAlgorithm = N'AES_256';
```

For more information on Native support for Encrypted Backups (and for a list of options to specify for @EncryptionAlgorithm), make sure to visit Microsoft's official documentation providing and overview and best-practices for [Backup Encryption](https://docs.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-encryption), and also view the [BACKUP command page](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql) where any of the options specified as part of the ALGORITHM 'switch' are values that can be passed into @EncryptionAlgorith (i.e., exactly as defined within the SQL Server Docs).

### H. Accounting for System and User Databases on Mirrored / Availability Group Servers

If your databases are mirrored or part of AlwaysOn Availability Groups, you pick up a couple of additional challenges:
- While you obviously want to keep backing up your (user) databases, they will typically only be 'accessible' for backups on or from the 'primary' server only (unless you're running a multi-server node that is licensed for read-only secondaries (which aren't fully supported by dba_BackupDatabases at this time)) - meaning that you'll want to create jobs on 'both' of your servers that run at the same time, but you only want them to TRY and execute a backup against the 'primary' replica/copy of your database at a time (otherwise, if you try to kick off a FULL or T-LOG backup against a 'secondary' database you'll get an error). 
- Since your (user) backups can 'jump' from one server to another (via failover), 'on-box' backups might not always provide a full backup chain (i.e., you might kick off FULL backups on SERVERA, run on that server for another 4 hours, then a failover will force operations on to SERVERB - where things will run for a few hours and then you may or may not fail back; but, in either case: neither the backups on SERVERA or SERVERB have the 'full backup chain' - so off-box copies of your backups are WAY more important than they normally are. In fact, you MIGHT want to consider setting @BackupDirectory to being a UNC share and @CopyToBackupDirectory to being an additional 'backup' UNC share (on a different host) - as the backups on either SERVERA or SERVERB both run the risk of never actually being a 'true' chain of viable backups). 
- System backups also run into a couple of issues. Since the master database, for example, keeps details on which databases, logins, linked servers, and other key bits of data are configured or enabled on a specific server, you'll want to create nightly (at least) backups of your system databases for both servers. However, if you specify a backup path of \\\\ServerX\SQLBackups as the path for your FULL [SYSTEM] backups on both SERVERA and SERVERB, each of them will try to create a new subfolder called master (for the master database, and then model for the model db, and so on), and drop in new FULL bakups for their own, respective, master databases. dba_BackupDatabases will use a 'uniquifier' in the names of both of these master database backups - so they won't overwrite each other, but... if you were to ever need these backups, you'd have NO IDEA which of the two FULL backups (taken at effectively the same time) would be for SERVERA or for SERVERB. To address, the @AddServerNameToSystemBackupsPath switch has been added to dba_BackupDatabases and, when set to 1, will result in a path for system-database backups that further splits backups into sub-folders for the server names. 

**Examples**

The following example is almost the exact same as Example A, except that on-box backups are no-longer being used (backups are being pushed to a UNC share instead), AND the @AddServerNameToSystemBackupsPath switch has been specified and set to 1 (it's set to 0 by default - or when not explicitly included):

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = 'FULL', 
    @DatabasesToBackup = N'[SYSTEM]', 
    @BackupDirectory = N'\\SharedBackups\SQLServer\', 
    @BackupRetentionHours = 48,
    @AddServerNameToSystemBackupPath = 1;
```

Without @AddServerNameToSystemBackupsPath being specified, the master database (for example) in the example execution above would be dropped into the following path/folder: \\\\SharedBackups\SQLServer\master - whereas, with the value set to 1 (true), the following path (assuming that the server this code was executing on was called SQL1) would be used instead: \\\\SharedBackups\SQLserver\master\SQL1\ - and, if the same code was also executed from a server named SQL2, a \SQL2\ sub-directory would be created as well. 

In this way, it ends up being much easier to determine which server any system-database backups come from (as each server needs its OWN backups - unlike user databases which are mirrored or part of an AG (or not on both boxes) - which don't need this same distinction). 

In the following example, which is essentially the same as Example C, FULL backups of system databases are being sent to 2x different UNC shares AND the @AllowNonAccessibleSecondaries option has been flipped/set to 1 (true) - which means that if there are (for example) 2x user databases being shared between SQL1 and SQL2 (either by mirroring or Availability Groups) and BOTH of these databases are active/accessible on SQL1 but not accessible on SQL2, the code below can/will run on BOTH servers (at the same time) without throwing any errors - because it will run on SQL1 and execute backups, and when it runs on SQL2 it'll detect that none of the [USER] databases are in a state that allows backups and then SEE that @AllowNonAccessibleSecondaries is set to 1 (true) and assume that the reason there are no databases to backup is because they're all secondaries. (Otherwise, without this switch set, if it had found no databases to backup, it would throw an error and raise an alert about finding no databases that it could backup.)

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'\\SharedBackups\SQLServer\', 
    @CopyToBackupDirectory = N'\\BackupServer\CYABackups\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72,
    @AllowNonAccessibleSecondaries = 1;
```

### H. Forcing dba_BackupDatabases to Log Backup Details on Successful Outcomes

By default, dba_BackupDatabases will ONLY log information to master.dbo.dba_DatabaseBackups_Log table IF there's an error, exception, or other problem executing backups or managing backup-copies or cleanup of older backups. Otherwise - if everything completes without any issues - dba_BackupDatabases will NOT log information to the dbo.dba_DatabaseBackups_Log logging table. 

This can, however, be changed (per execution) so that successful execution details are logged - as per this example (which is identical to Example C - except that details on each database backed up will be logged - along with info on copy operations, etc.):

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72, 
    @LogSuccessfulOutcomes = 1;
```


### I. Modifying Alerting Information

By default, dba_BackupDatabases is configured to send to the 'Alerts' Operator via a Mail Profile called 'General'. This was done to support 'convention over configuration' - while still enabling options for configuration should they be needed. As such, the following example is an exact duplicate of Example C, only it has been set to use a Mail Profile called 'DbMail', modify the prefix for the Subject-line in any emails alerts sent (i.e., they'll start with '!! BACKUPS !! - ' instead of the default of '[Database Backups] '), and the email will be sent to the operator called 'DBA' instead of 'Alerts'. Otherwise, everything will execute as expected. (And, of course, an email/alert will ONLY go out if there are problems encountered during the execution listed below.)

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72, 
    @OperatorName = N'DBA',
    @MailProfileName = N'DbMail',
    @EmailSubjectPrefix = N'!! BACKUPS !! - ';
```

NOTE that dba_BackupDatabases will CHECK the @OperatorName and @MailProfileName to make sure they are valid (whether explicitly provided or when provided by default) - and will throw an error BEFORE attempting to execute backups if either is found to be non-configured/valid on the server. 

### J. Printing Commands Instead of Executing Commands

By default, dba_BackupDatabases will create and execute backup, file-copy, and file-cleanup commands as part of execution. However, it's possible (and highly-recommended) to view WHAT dba_BackupDatabases WOULD do if invoked with a set of parameters INSTEAD of executing the commands. Or, in other words, dba_BackupDatabases can be configured to output the commands it would execute - without executing them. (Note that in order for this to work, SOME validation checks and NO logging (to dbo.dba_DatabaseBackups_Log) will occur.) 

To see what dba_BackupDatabases would do (which is very useful in setting up backup jobs and/or when making (especially complicated) changes) rather than let it execute, simply set the @PrintOnly parameter to 1 (true) and execute - as in the example below (which is identical to Example C - except that commands will be 'spit out' instead of executed):

```sql
EXEC master.dbo.dba_BackupDatabases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetentionHours = 48, 
    @CopyToRetentionHours = 72,
    @PrintOnly = 1; -- don't execute. print commands instead...
```


## Setting Up Scheduled Backups using dba_BackupDatabases

[high-level overview of the process of a) figuring out what you want/need in terms of COVERAGE (i.e., frequency + retention) then... creating individual jobs for system FULL, then user FULLs + DIFFs + TLOGs. 

Recommendations for DISTINCT jobs per each backup/type. Don't use house-boats or 'dual load' things. Create a single job per each type of thing... i.e., assuming such and such scneario would create 3x jobs... 1 for system/FULL, 1 for FULL user... 1 for t-log of all dbs - every 5 or 10 minutes. Later... if found that need job for larger DB to do a DIFF at, say, 2PM and 4PM to keep up with heavy tx volume, create a new/distinct job for it to do DIFF backups of the one db... 

SHOW examples of the job-step for all of the above... 

Recommendations about JOB NAMES ... 

other recommendations/etc. 

]
