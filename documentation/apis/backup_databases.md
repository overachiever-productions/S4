![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > backup_databases

# dbo.backup_databases

## Table of Contents
- [Overview](#overview)
    - [Rationale](#rationale)
    - [Benefits of S4 Backups](#benefits-of-s4-backups)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview
**APPLIES TO:** :heavy_check_mark: SQL Server 2008 / 2008 R2 :heavy_check_mark: SQL Server 2012+ :grey_exclamation: SQL Server Express / Web

:heavy_check_mark: Windows :o: Linux :o: Amazon RDS :grey_question: Azure

**S4 CONVENTIONS:** [Advanced-Capabilities](#), [Alerting](#), [@PrintOnly](#), [Backup Names](#), [Vectors](#), and [{Tokens}](#)


### Rationale
S4 Backups were designed to provide:

- **Simplicity.** Streamlines the most commonly used features needed for backing up mission-critical databases into a set of simplified parameters that make automating backups of databases easy and efficient - while still vigorously ensuring disaster recovery best-practices.
- **Resiliency** Wraps execution with low-level error handling to prevent a failure in one operation (such as the failure to backup one database out of 10 specified) from 'cascading' into others and causing a 'chain' of operations from completing merely because an 'earlier' operation failed. 
- **Transparency** Uses (low-level) error-handling to log problems in a centralized logging table (for trend-analysis and improved troubleshooting) and send email alerts with concise details about each failure or problem encountered during execution so that DBAs can quickly ascertain the impact and severity of any errors incurred during execution without having to wade through messy 'debugging' and troubleshooting procedures.

### Benefits of S4 Backups
Key Benefits Provided by S4 Backups:

- **Simplicity, Resiliency, and Transparency.** Commonly needed features and capabilities - streamlined into a set of simple to use scripts. 
- **Streamlined Deployment and Management.** No dependencies on external DLLs, outside software, or additional components. Instead, S4 Backups are set of simple wrappers around native SQL Server Native Backup capabilities - designed to enable Simplicity, Resiliency, and Transparency when tackling backups.
- **Redundancy.** Designed to facilitate copying backups to multiple locations (i.e., on-box backups + UNC backups (backups of backups) - or 2x UNC backup locations, etc.)
- **Encryption.** Enable at-rest-encryption by leveraging SQL Server 2014's (+) NATIVE backup encryption (only available on Standard and Enteprise Editions).
- **Compression.** Leverages Backup Compression on all supported Versions and Editions of SQL Server (2008 R2+ Standard and Enterprise Editions) and transparently defaults to non-compressed backups for Express and Web Editions.
- **Logging and Trend Analysis.** Supports logging of operational backup metrics (timees for backups, file copying, etc.) for trend analysis and review.
- **Fault Tolerance.** Supports Mirrored and 'Simple 2-Node' (Failover only) Availability Group databases.

## Syntax
```sql

    EXEC dbo.backup_databases
        @BackupType = '[ FULL | DIFF | LOG ]', 
        @DatabasesToBackup = N'[ widgets,hr,sales,etc | [ {SYSTEM} | {USER} ] | {ALL} ]', 
        [@DatabasesToExclude = N'list,of, dbs,to,not,restore,%wildcards_supported%', ] 
        [@Priorities = N'higher,priority,dbs,*,lower,priority,dbs, ]
        @BackupDirectory = N'[ D:\PathTo\BackupsRoot\ | {DEFAULT} ]', 
        [@CopyToBackupDirectory = N'\\OffBoxLocation\Path\BackupsRoot\', ]
        @BackupRetention = N'<vector>', 
        [@CopyToRetention = N'<vector>', ]
        [@RemoveFilesBeforeBackup] = [ 0 | 1 ], ]
        [@EncryptionCertName = 'ServerCertName', ] 
        [@EncryptionAlgorithm = '[ AES 256 | TRIPLE_DES_3KEY ]', ] 
        [@AddServerNameToSystemBackupPath = [ 0 | 1 ], ] 
        [@AllowNonAccessibleSecondaries = [ 0 | 1 ], ] 
        [@Directives = N'advanced, directives, here', ]
        [@LogSuccessfulOutcomes = [ 0 | 1 ], ] 
        [@OperatorName = N'{DEFAULT}', ]
        [@MailProfileName = N'{DEFAULT}', ] 
        [@EmailSubjectPrefix = N'{DEFAULT}', ] 
        [@PrintOnly = [ 0 | 1 ] ] 
    ;

```

### Arguments
**@BackupType** `= N'[ FULL | DIFF | LOG ]'`  
The type of backup to perform. Permitted values include `FULL` | `DIFF` | `LOG` - but only a single value may be specified at any given time.

**@DatabasesToBackup** `=  N'list, of, databases, to, backup, by, name | [ {USER} | {SYSTEM} | {ALL} ]'`  
Either a comma-delimited list of databases to backup by name (e.g., 'db1, dbXyz, Widgets') or a specialized token (enclosed in square-brackets) to specify, for example, that either `{SYSTEM}` databases should be backed up, or `{USER}` databases should be backed up. 

> ### :label: **NOTE:** 
> *By default, the `admindb` is treated by S4 scripts as a `{SYSTEM}` database (instead of a `{USER}` database). To modify this convention, add or update the `admindb_is_system_db` (as a `setting_type` of `UNIQUE`) in the `dbo.settings` table - setting the value to 0 if you wish the `[admindb]` to be treated like a `{USER}` database. Otherwise, if this key is NOT present, `[admindb]` is treated as a `{SYSTEM}` database.*

[**@DatabasesToExclude** `= N'list, of, database, names, to exclude, %wildcards_allowed%'`]  
Designed to work with `{USER}` (or `{SYSTEM}`) tokens (but also works with a specified list of databases). Removes any databases (found on server), from the list of DBs to backup.

> ### :bulb: **TIP:**
> Note that you can specify wild-cards for 'pattern matching' as a means of excluding entire groups of similarly named databases. For example, if you have a number of `<dbname>_staging` databases that you don't want to bother backing up, you can specify `'%_staging'` as an exclusion pattern (which will be processed via a LIKE expression) to avoid executing backups against all _staging databases.

[**@Priorities** = `N'higher, priority, dbs, *, lower, priority, dbs'` ]  
Allows specification of priorities for backup operations (i.e., specification for order of operations). When NOT specified, dbs loaded (and then remaining after `@DatabasesToExclude` are processed) will be ranked/sorted alphabetically - which would be the SAME result as if `@Priorities` were set to the value of `'*'`. Which means that `*` is a token that specifies that any database not SPECIFICALLY specified via `@Priorities` (by name) will be sorted alphabetically. Otherwise, any db-names listed (and matched) BEFORE the `*` will be ordered (in the order listed) BEFORE any dbs processed alphabetically, and any dbs listed AFTER the `*` will be ordered (negatively - in the order specified) AFTER any dbs not matched. 

As an example, assume you have 7 databases, ProdA, Minor1, Minor1, Minor1, Minor1, Junk, and Junk2. Alphabetically, Junk, Junk2, and all 'minor' dbs would be processed before ProdA, but if you specified `'ProdA, *, Junk2, Junk'`, you'd see the databases processed/restored in the following order: `ProdA, Minor1, Minor2, Minor3, Minor4, Junk2, Junk` - because `ProdA` is specified before any dbs not explicitly mentioned/specified (i.e., those matching the token *), all of the `'Minor'` databases are next - and are sorted/ranked alphabetically, and then Junk is specified BEFORE `Junk` - but after the `*` token - meaning that `Junk` is the last db listed and is therefore ranked LOWER than `Junk2` (i.e., anything following `*` is sorted/ranked as defined and FOLLOWING the databases represented by *).

When `@Priorities` is defined as something like 'only, db,names', it will be treated as if you had specified the following: `'only,db,names,*'` - meaning that the dbs you specified for `@Priorities` will be restored/tested in the order specified BEFORE all other (non-named) dbs. Otherwise, if you wish to 'de-prioritize' any dbs, you must specify `*` and then the names of any dbs that should be processed 'after' or 'later'.
  
**@BackupDirectory** = `N'path-to-root-folder-for-backups'`  
Specifies the path to the root folder where all backups defined by `@DatabasesToBackup` will be written. Must be a valid Windows Path - and can be either a local path or UNC path. 
IF the {DEFAULT} token is used, backup_database will request the default location for SQL Server Backups by querying the registry for the current SQL Server instance.  
`DEFAULT = N'{DEFAULT}'`.

[**@CopyToBackupDirectory** = `N'path-to-folder-for-COPIES-of-backups'`]  
**Optional - but HIGHLY recommended.** When specified, backups (written to `@BackupDirectory`) will be copied to `@CopyToBackupDirectory` as part of the backup process. Must be a valid Windows path and, by design (though not enforced), should be an 'off-box' location for proper protection purposes. 

> ### :label: **NOTE:** 
> The `{DEFAULT}` token (allowed for` @BackupDirectory`) is NOT supported here (it wouldn't make any sense anyhow). 

> ### :bulb: **TIP:**
> While SQL Server Enterprise Edition natively supports `MIRROR_TO` syntax, `dbo.backup_databaes` does not (anymore) use this functionality if/when Enterprise Edition is detected - because `MIRROR_TO` functionality makes retry logic harder and removes the ability to provide time/metrics into how long network file-copies take. 

**@BackupRetenion** `= N'<vector>'`  
~~Specifies the amount of time (in m(inutes), h(ours), d(ays), or w(eeks)) that backups of the current type (i.e., `@BackupType`) should be retained or kept. May also be used to specify the specific number of b(ackups) to be retained instead of specifying a 'time threshold'. For example, if an `@BackupType` of 'LOG' is specified, and `@BackupDirectory` is set to `'D:\SQLBackups'` is specified with a `@BackupRetention` of '24h' (i.e., 24h(ours)), then if database `'Widgets'` is being backed up, `dbo.backup_databases` will then remove any .trn (transaction log backups) > 24 hours hold while keeping any transaction-log backups < 24 hours old. Similarly, if `@BackupType` were specified as 'FULL' and `@BackupRetention` were set to '2d' (2 days or the equivalent of 48h), then FULL backups of any database being processed > 48 hours (2 days) old would be removed, while any FULL backups newer than the specified threshold would be kept.~~ 

~~Likewise, if you simply wish to keep a SPECIFIED number of backups - instead of relying upon dates, you can specify #b - where # is the number of backups you'd like to keep (of the current @BackupType being processed). So, for example, if you specified @BackupType = 'DIFF' and @BackupRetention = '1b' - you'd only be keeping the LATEST backup (assuming you remove backups AFTER creating them - because you'd first execute a DIFF backup, then remove all but the last #b(ackups) - or all but the last backup (which you had just taken).~~ 

> ### :bulb: **TIP:** 
> *Retention details are only applied against the `@BackupType` being currently executed. For example,  T-Log backups with an `@BackupRetention` of '24h' will NOT remove `FULL` or `DIFF` backups for the same database (even in the same folder). (Retention ONLY works if when the database name AND backup type is an exact match.) Or, in other words, `dbo.backup_databases` does NOT 'remember' where your previous backups were stored and go out and delete any previous backups older than `@BackupRetention`. Instead, during retention processing, `dbo.backup_databases` will check the 'current' folder for any backups of `@BackupType` that are older than `@BackupRetention` and ONLY remove those files if/when the file-backup-names match those of the database being backed up, when the files are in the same folder, and if the backups themselves match the qualifiers stated in `@BackupRetention`.*

[**@CopyToRetention** `= N'<vector>'` ]  
This parameter is **required if** `@CopyToBackupDirectory` is specified. Otherwise, it works almost exactly like `@BackupRetention` (in terms of how files are evaluated and/or removed) EXCEPT that it provides a separate set of retention details for your backup copies. Or, in other words, you could specify a `@BackupRetention` of '24 hours' for your `FULL` backups of on-box backups (i.e., `@BackupDirectory` backups), and a value of '48 hours' (or whatever else) for your `@CopyToRetention` - meaning that 'local' backups of the type specified would be kept for 24 hours, while remote (off-box) backups were kept for 48 hours. 

[**@RemoveFilesBeforeBackup** `= [ 0 | 1 ]` ]  
When set to `1` (true), will attempt to delete any backups (and backup copies) matching `@BackupRetention` (and `@CopyToBackupRetention`) BEFORE executing the BACKUP + VERIFY commands. If there is a FAILURE during the process of removing older backups, the corresponding backup will be SKIPPED (as the expectation is that this parameter is set to `1` when available space may be at a premium and the database(s) being backed-up might be large enough to cause issues with disk-space otherwise).  
`DEFAULT = 0` (false).

[**@EncryptionCertName** `= N'NameOfCertToUseForEncryption'` ]  
If specified, backup operation will attempt to use native SQL Server backup by attempting to encrypt the backup using the `@EncryptionCertName` (and `@EncryptionAlgorithm`) specified. If the specified Certificate Name is not found (or if the version of SQL Server is earlier than SQL Server 2014 or a non-supported edition (Express or Web) is specified), the backup operation will fail.  
`DEFAULT = NULL`.

[**@EncryptionAlgorith** `= N'[ AES_256 | TRIPLE_DES_3KEY ]'` ]  
This parameter is required IF `@EncryptionName` is specified (otherwise it must be left blank or NULL). Recommended values are either `AES_256` or `TRIPLE_DES_3KEY`. Supported values are any values supported by your version of SQL Server. (See the [Backup](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql) statement for more information.)  
`DEFAULT = N'AES_256'`.

[**@AddServerNameToSystemBackupPath** `= [ 0 | 1 ]` ]  
For servers that are part of an AlwaysOn Availabilty Group or participating in a Mirroring topology, each server involved will have its own `{SYSTEM}` databases. When they're backed up to a centralized location (typically via the `@CopyToBackupPath`), there needs to be a way to differentiate backups from, say, the master database on `SERVER1` from master databases backups from `SERVER2`. By setting `@AddServerNameToSystemBackupPath = 1`, the full path for `{SYSTEM}` database backups will be: `Path + db_name + server_name` e.g., `\\backup-server\sql-backups\master\SERVER1\` - thus ensuring that system-level database backups from `SERVER1` do NOT overwrite system-level database backups created/written by `SERVER2` and vice-versa.  
`DEFAULT = 0` (false).

[**@AllowNonAccessibleSecondaries** `= [ 0 | 1 ]` ]  
By default, once the databases in `@DatabasesToBackup` has been converted into a list of databases, this 'list' will be compared against all databases on the server that are in a STATE where they can be backed-up (databases participating in Mirroring, for example, might be in a RECOVERING state) and IF the 'list' of databases to backup then is found to contain NO databases, `dbo.backup_databases` will throw an error because it was instructed to backup databases but FOUND no databases to backup. However, IF `@AllowNonAccessibleSecondaries` is set to `1`, then IF `@DatabasesToBackup = 'db1,db2'` and `DB1` and `DB2` are both, somehow, not in an online/backup-able state, `dbo.backup_databases` will find that NO databases should be backed up after initial processing, will 'see' that `@AllowNonAccessibleSecondaries` is set to `1` and rather than throwing an error, will terminate gracefully.  
`DEFAULT = 0` (false).

> ### :bulb: **TIP:**
> *@AllowNonAccessibleSecondaries should ONLY be set to `1` (true) when Mirroring or Availability Groups are in use and after carefully considering what could/would happen IF execution of backups did NOT 'fire' because the databases specified by `@DatabasesToBackup` were all found to be in a state where they could NOT be backed up.*

[**@Directives** `= N'optional, directives, specified, as, desired'` ]    
Allows 'advanced' directives to be specified as part of the executed backup operation. Currently supported S4 directives include: 

- `COPY_ONLY` - which directs the creation of `COPY_ONLY` backups (i.e., do not reset DIFF markers) - just as with 'normal' T-SQL Backup Syntax. 
- `FILE:logical_file_name` - which directs that ONLY the `logical_file_name` specified should be backed up - vs the entire database.
- `FILEGROUP: filegroup_name` - which directs that only files belonging to the `filegroup_name` be included in the backup - vs the entire database.

`DEFAULT = NULL`.

[**@LogSuccessfulOutcomes** `= [ 0 | 1 ]` ]  
By default, `dbo.backup_databases` will NOT log successful outcomes to the  `dbo.backups_log` table (though any time there is an error or problem, details will be logged regardless of this setting). However, if `@LogSuccessfulOutcomes` is set to true, then succesful outcomes (i.e., those with no errors or problems) will also be logged into the `dbo.backups_log` table (which can be helpful for gathering metrics and extended details about backup operations if needed).  
`DEFAULT = 0` (false).

[**@OperatorName** `= N'{DEFAULT}'` ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.]

[**@MailProfileName** = `N'{DEFAULT}'` ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.]

[**@EmailSubjectPrefix** `= N'Text Here'` ]
[This also needs a 'standarized-ish' doc blurb... only, there IS a value here that'll be different per each sproc/etc. (And, eventually, these can/will be changed via dbo.Settings as an option as well - i.e., sproc_name_email_alert_prefix (as the key ... with a specified value)))]

[**@PrintOnly** `= { 0 | 1}` ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.] 

[Return to Table of Contents](#table-of-contents)

## Remarks 
### Automated Backups vs Ad-Hoc Backups
S4 Backups were primarily designed to facilitate AUTOMATED backups - i.e., the regular backups executed on servers to provide disaster recovery options. S4 Backups (i.e., `dbo.backup_databases`) can be used for 'ad-hoc' backups if necessary (just make sure to use the COPY_ONLY directive when/where this would make sense - to avoid problems with DIFF backups).

In many cases, if you need and ad-hoc backup (in addition to making sure to specify `@Directives = N'COPY_ONLY'`), it is typically a good idea to specify `@PrintOnly = 1`, have `dbo.backup_databases` then 'spit out' they syntax for the backup you need - at which point you can then review this syntax and then run it manually as needed. 

### Order of Operations During Execution
During execution, the high-level order of operations within `dbo.backup_databases` is: 
- Validate Inputs
- Construct a list of databases to backup (based on `@DatabasesToBackup` and `@DatabasesToExclude` parameters) + Prioritize said list of database according to any `@Priorities` values specified. 
- For each database to be backed up, the following operations are executed (in the following order):
    - Construct and then EXECUTE a backup statement/command.
    - Verify the backup (this is always done and can't be disabled within dbo.backup_databases).
    - Copy the verified backup to the `@CopyTo` location.
    - Remove expired backups from the `@BackupsDirectory` and `@CopyToBackupsDirectory` for the CURRENT database being processed.
    - Remove expired backups from local AND from copy (explicit checks in both locations - see "Managing Different Retention Requirements for Different Databases" below for more info).
    - Log any problems or issues and fire off email alerts if/when there are any problems with any aspect of execution defined above (other than validating inputs).
- Once all databases to 'process' have been processed, `dbo.backup_databases` will then report on any errors/problems via alerts and, log any requisite data into the `dbo.backup_log` table as needed. 

### Managing Different Retention Requirements for Different Databases
When processing backups for cleanup (i.e., evaluating vs retention times), `dbo.backup_databases` will ONLY execute:
- after completing a backup (if the backup fails, file-cleanup will NOT be processed - so that you don't have a set of backups fail over a long weekend and watch all of your existing (good) backups slowly get 'eaten' while no one was watching their inbox, etc.). 
- against the sub-folder for the database currently being processed. 

The secondary point / limitation is very important for purposes of addressing more 'complex' setups. Specifically, assume you have 4 (user) databases that you need to backup. Assume that 3 of them are of medium to 'meh' importance, but one is of SUCH critical importance you always want at least 3 days of FULL and T-LOG backups available for it - whereas, there isn't enough disk space to keep copies of the other 3 database for SUCH a long time (i.e., you can only 'manage' 2 days of backups for these databases). To this end, you would create DIFFERENT jobs for the 3x 'medium-important' jobs - with `RetentionHours` in/around the 48 hour mark - and distinct/different jobs (or at least steps or sets of commands) for your 'critical' database that would keep backups for 72 hours. As such, when `@RetentionHours` (or `@CopyToRetention`) were being processed against your 3 'medium' importance databases, ONLY files in the folders for these 3x databases will be considered for currently specified retention (and the backups for your 4th/Critical database will NOT be touched during execution). 

### Backup Encryption
S4 Backups 'wrap' native SQL Server Backup Encryption (i.e., there's nothing special about S4 Backups that could/would provide support for Backup Encryption OUTSIDE of what SQL Server already provides). As such, you will need SQL Server 2014 Standard or Enterprise Editions (encrytion is not supported on Web or Express Editions) or higher for Encryption Support. 

> ### :zap: **WARNING:** 
> If you configure your system for Encrypted Backups, make SURE to backup your Encryption Certificates - otherwise your backups WILL be useless should you lose your primary server in a disaster - and there is NO way to recover from this (not even a support call to Microsoft could help you in this case).

[Return to Table of Contents](#table-of-contents)

## Examples
### A. FULL Backup of System Databases to an On-Box Location (Only)

The following example will backup all system databases (master, model, and msdb (there's no need to backup tempdb - nor can it be backed up)) to `D:\SQLBackups`. Once completed, there will be a new subfolder for each database backed up (i.e., `D:\SQLBackups\master` and `D:\SQLBackups\model`, etc.) IF there weren't folders already created with these names, and a new, `FULL`, backup of each database will be dropped into each respective folder. 

Further, any `FULL` backups of these databases that might have already been in this folder will be evaluated to review how old they are, and any that are > 48 hours old will be deleted - as per the `@BackupRetention` specification. 

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = 'FULL', 
    @DatabasesToBackup = N'{SYSTEM}', 
    @BackupDirectory = N'D:\SQLBackups', 
    @BackupRetention = '48 hours';
    
```

Note too that the example above contains, effectively, the minimum number of specified parameters required for execution (i.e., which DBs to backup, what TYPE of backup, a path, and a retention time). 

> ### :zap: **WARNING:** 
> It's NEVER a good idea to backup databases to JUST the local-server. Doing so puts your backups and data on the SAME machine and if that machine crashes and can't be recovered, burns to the ground, or runs into other significant issues, you've just lost your data AND backups. 

### B. FULL Backup of System Databases - Locally and to a Network Share

The following example duplicates what was done in Example A, but also pushes copies of System Database backups to the 'Backup Server' (meaning that the path indicated will end up having sub-folders for each DB being backed up, with backups in each folder as expected). 

Note the following: 

- Unlike Example A, the paths specified in this execution end with a trailing slash (i.e., `D:\SQLBackups\` instead of `D:\SQLBackups`). **Either option is supported**, and paths will be normalized during execution. 
- Local backups (those in D`:\SQLBackups`) will be kept for 48 hours, while those on the backup server (where we can assume there is more disk space in this example) will be kept for 72 hours - showing that it's possible to specify different backup retention rates for `@BackupDirectory` and `@CopyToBackupDirectory` folders. 

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{SYSTEM}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours'; -- longer retention than 'on-box' backups
    
```

### C. Full Backup of All User Databases - Locally and to a Network Share

The following example is effectively identical to Example B, only, in this example, all user datbases are being specified - by use of the `{USER}` token. 

Once execution is complete:
- A folder will be created for each (user) database on the server where this code is executed - if a folder didn't already exist. 
- A new FULL backup will be added to the respective folder for each database. 
- Copies of these changes will be mirrored to the `@CopyToBackupDirectory` (i.e., a new sub-folder per each DB and a `FULL` backup per each database/folder). 
- Retention rates (per database) will be processed against each-subfolder found at `@BackupDirectory` and each subfolder found at `@CopyToBackupDirectory`. 

Note, however, that the only tangible change between this example and Example B is that `@DatabaseToBackup` has been set to backup `{USER}` databases. 

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
    
```

### D. Full Backup of User Databases - Excluding explicitly specified databases

This example executes identically to Example C - except the databases `Widgets`, `Billing`, and `Monitoring` will **NOT** be backed up (if they're found on the server). Note that excluded database names are comma-delimited, and that spaces between db-names do not matter (they can be present or not). Likewise, if you specify the name of a database that does NOT exist as an exclusion, no error will be thrown and any databases OTHER than those explicitly excluded will be backed up as specified. 

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{USER}',
    @DatabasesToExclude = N'Widgets, Billing,Monitoring', 
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours';
    
```
### E. Explicitly Specifying Database Names for Backup Selection

Assume you've already set up a nightly job to tackle `FULL` backups of all user databases (and that you've got `T-LOG` backups configured as well), but have 2x larger databases that require a `DIFF` backup at various points during the day (say noon and 4PM) in order to allow restore-operations to complete in a timely fashion (due to high-volumes of transactional modifications during the day). 

In such a case you wouldn't want to specify `{USER}` (if you've got, say 12 user databases total) for which databases to backup. Instead, you'd simply want to specify the names of the databases to backup via `@DatabasesToBackup`. (And note that database names are comma-delimited - where spaces between db-names are optional (i.e., won't cause problems)). 

In the following example, `@BackupType` is specified as `DIFF` (i.e., a `DIFFERENTIAL` backup), and only two databases are specifically specified (`Shipments` and `ProcessingProd`) - meaning that these two databases are the only databases that will be backed-up (with a `DIFF` backup). As with all other backups, the `DIFF` backups for this execution will be dropped into sub-folders per each database - and then copied off-box as well.

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'DIFF', 
    @DatabasesToBackup = N'Shipments, ProcessingProd',
    @DatabasesToExclude = N'Widgets, Billing,Monitoring', 
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours';
    
```

### F. Setting up Transaction-Log Backups

In the following example, Transaction-log backups are targeted (i.e., `@BackType = 'LOG'`). As with other backups, these will be dropped into sub-folders corresponding to the names of each database to be backed-up. In this case, rather than explicitly specifying the names of databases to backup, this example specifies the `{USER}` token for `@DatabasesToBackup`.

During execution, this means that `dbo.backup_databases` will create a list of all databases in `FULL` or `BULK-LOGGED` Recovery Mode (databases in `SIMPLE` mode cannot have their Transaction Logs backed up and will be skipped), and will execute a transaction log backup for said databases. (In this way, if you've got, say, 3x production databases running in FULL recovery mode, and a handful of dev, testing, or stage databases that are also on your server but which are set to `SIMPLE` recovery, only the databases in `FULL`/`BULK-LOGGED` recovery mode will be targetted. Or, in other words, `{USER}` is 'smart' and will only target databases whose transaction logs can be backed up when `@BackupType = 'LOG'`.)

Notes:
- If all of your databases (i.e., on a given server) are in `SIMPLE` recovery mode, attempting to execute with an `@BackupType` of 'LOG' will throw an error - because it won't find ANY transaction logs to backup. 
- In the example below, `@BackupRetention` has been set to 49 (hours). Previous examples have used 'clean multiples' of 24 hour periods (i.e., days) - but there's no 'rule' about how many hours can be specified - other than that this value cannot be 0 or NULL. (And, by setting the value to 'somewhat arbitrary' values like 25 hours instead of 24 hours, you're ensuring that if a set of backups 'go long' in terms of execution time, you'll always have a full 24 hours + a 1 hour backup worth of backups and such.)


```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours';
    
```


### G. Using a Certificate to Encrypt Backups

The following example is effectively identical to Example D - except that the name of a Certificate has been supplied - along with an encryption algorithm, to force SQL Server to create encrypted backups. When encrypting backups:
- You must create the Certificate being used for encryption BEFORE attempting backups (see below for more info). 
- You must specify a value for both `@EncryptionCertName` and `@EncryptionAlgorithm`.
- Unless this is a 'one-off' backup (that you're planning on sharing with someone/etc.), if you're going to encrypt any of your backups, you'll effectively want to encrypt all of your backups (i.e., if you encrypt your `FULL` backups, make sure that any `DIFF` and `T-LOG` backups are also being encrypted). 
- While encryption is great, you MUST make sure to backup your Encryption Certificate (which requires a Private Key file + password for backup) OR you simply won't be able to recover your backups on your server if something 'bad' happens and your server needs to be rebuilt or on any other server (i.e., smoke and rubble contingency plans) without being able to 'recreate' the certificate used for encryption. 

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '49 hours', 
    @CopyToRetention = '72 hours';
    @EncryptionCertName = N'BackupsEncryptionCert', 
    @EncryptionAlgorithm = N'AES_256';
    
```

For more information on Native support for Encrypted Backups (and for a list of options to specify for @EncryptionAlgorithm), make sure to visit Microsoft's official documentation providing and overview and best-practices for [Backup Encryption](https://docs.microsoft.com/en-us/sql/relational-databases/backup-restore/backup-encryption), and also view the [BACKUP command page](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql) where any of the options specified as part of the ALGORITHM 'switch' are values that can be passed into @EncryptionAlgorith (i.e., exactly as defined within the SQL Server Docs).

### H. Accounting for System and User Databases on Mirrored / Availability Group Servers

If your databases are Mirrored or part of AlwaysOn Availability Groups, you pick up a couple of additional challenges:
- While you obviously want to keep backing up your (user) databases, they will typically only be 'accessible' for backups on or from the 'primary' server only (unless you're running a multi-server node that is licensed for read-only secondaries (which aren't fully supported by dbo.backup_databases at this time)) - meaning that you'll want to create jobs on 'both' of your servers that run at the same time, but you only want them to TRY and execute a backup against the 'primary' replica/copy of your database at a time (otherwise, if you try to kick off a `FULL` or `T-LOG` backup against a 'secondary' database you'll get an error). 
- Since your (user) backups can 'jump' from one server to another (via failover), 'on-box' backups might not always provide a full backup chain (i.e., you might kick off `FULL` backups on `SERVERA`, run on that server for another 4 hours, then a failover will force operations on to `SERVERB` - where things will run for a few hours and then you may or may not fail back; but, in either case: neither the backups on `SERVERA` or `SERVERB` have the 'full backup chain' - so off-box copies of your backups are WAY more important than they normally are. In fact, you MIGHT want to consider setting `@BackupDirectory` to being a UNC share and `@CopyToBackupDirectory` to being an additional 'backup' UNC share (on a different host) - as the backups on either `SERVERA` or `SERVERB` both run the risk of never actually being a 'true' chain of viable backups). 
- System backups also run into a couple of issues. Since the master database, for example, keeps details on which databases, logins, linked servers, and other key bits of data are configured or enabled on a specific server, you'll want to create nightly (at least) backups of your system databases for both servers. However, if you specify a backup path of `\\ServerX\SQLBackups` as the path for your `FULL` `{SYSTEM}` backups on both `SERVERA` and `SERVERB`, each of them will try to create a new subfolder called master (for the master database, and then model for the model db, and so on), and drop in new FULL bakups for their own, respective, master databases. `dbo.backup_databases` will use a 'uniquifier' in the names of both of these master database backups - so they won't overwrite each other, but... if you were to ever need these backups, you'd have NO IDEA which of the two FULL backups (taken at effectively the same time) would be for `SERVERA` or for `SERVERB`. To address, the `@AddServerNameToSystemBackupsPath` switch has been added to `dbo.backup_databases` and, when set to `1`, will result in a path for system-database backups that further splits backups into sub-folders for the server names. 

[Return to Table of Contents](#table-of-contents)

**Examples**

The following example is almost the exact same as Example A, except that on-box backups are no-longer being used (backups are being pushed to a UNC share instead), AND the `@AddServerNameToSystemBackupsPath` switch has been specified and set to `1` (it's set to `0` by default - or when not explicitly included):

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = 'FULL', 
    @DatabasesToBackup = N'{SYSTEM}', 
    @BackupDirectory = N'\\SharedBackups\SQLServer\', 
    @BackupRetention = '48 hours',
    @AddServerNameToSystemBackupPath = 1;
    
```

Without `@AddServerNameToSystemBackupsPath` being specified, the master database (for example) in the example execution above would be dropped into the following path/folder: `\\SharedBackups\SQLServer\master` - whereas, with the value set to `1` (true), the following path (assuming that the server this code was executing on was called `SQL1`) would be used instead: `\\SharedBackups\SQLserver\master\SQL1\` - and, if the same code was also executed from a server named `SQL2`, a `\SQL2\` sub-directory would be created as well. 

In this way, it ends up being much easier to determine which server any system-database backups come from (as each server needs its OWN backups - unlike user databases which are mirrored or part of an AG (or not on both boxes) - which don't need this same distinction). 

In the following example, which is essentially the same as Example C, `FULL` backups of system databases are being sent to 2x different UNC shares AND the `@AllowNonAccessibleSecondaries` option has been flipped/set to `1` (true) - which means that if there are (for example) 2x user databases being shared between `SQL1` and `SQL2` (either by mirroring or Availability Groups) and BOTH of these databases are active/accessible on SQL1 but not accessible on `SQL2`, the code below can/will run on BOTH servers (at the same time) without throwing any errors - because it will run on `SQL1` and execute backups, and when it runs on `SQL2` it'll detect that none of the `{USER}` databases are in a state that allows backups and then SEE that `@AllowNonAccessibleSecondaries` is set to `1` (true) and assume that the reason there are no databases to backup is because they're all secondaries. (Otherwise, without this switch set, if it had found no databases to backup, it would throw an error and raise an alert about finding no databases that it could backup.)

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'\\SharedBackups\SQLServer\', 
    @CopyToBackupDirectory = N'\\BackupServer\CYABackups\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours';
    @AllowNonAccessibleSecondaries = 1;
    
```

### I. Forcing dbo.backup_databases to Log Backup Details on Successful Outcomes

By default, `dbo.backup_databases` will ONLY log information to `admindb.dbo.backups_log` table IF there's an error, exception, or other problem executing backups or managing backup-copies or cleanup of older backups. Otherwise - if everything completes without any issues - `dbo.backup_databases` will NOT log information to the `dbo.backups_log` logging table. 

This can, however, be changed (per execution) so that successful execution details are logged - as per this example (which is identical to Example C - except that details on each database backed up will be logged - along with info on copy operations, etc.):

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours'; 
    @LogSuccessfulOutcomes = 1;
    
```


### J. Modifying Alerting Information

By default, dbo.backup_databases is configured to send to the 'Alerts' Operator via a Mail Profile called 'General'. This was done to support 'convention over configuration' - while still enabling options for configuration should they be needed. As such, the following example is an exact duplicate of Example C, only it has been set to use a Mail Profile called 'DbMail', modify the prefix for the Subject-line in any emails alerts sent (i.e., they'll start with '!! BACKUPS !! - ' instead of the default of '[Database Backups] '), and the email will be sent to the operator called 'DBA' instead of 'Alerts'. Otherwise, everything will execute as expected. (And, of course, an email/alert will ONLY go out if there are problems encountered during the execution listed below.)

```sql

EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours'; 
    @OperatorName = N'DBA',
    @MailProfileName = N'DbMail',
    @EmailSubjectPrefix = N'!! BACKUPS !! - ';
    
```

NOTE that `dbo.backup_databases` will CHECK the `@OperatorName` and `@MailProfileName` to make sure they are valid (whether explicitly provided or when provided by default) - and will throw an error BEFORE attempting to execute backups if either is found to be non-configured/valid on the server. 

### K. Printing Commands Instead of Executing Commands

By default, `dbo.backup_databases` will create and execute backup, file-copy, and file-cleanup commands as part of execution. However, it's possible (and highly-recommended) to view WHAT `dbo.backup_databases` WOULD do if invoked with a set of parameters INSTEAD of executing the commands. Or, in other words, `dbo.backup_databases` can be configured to output the commands it would execute - without executing them. (Note that in order for this to work, SOME validation checks and NO logging (to `dbo.backup_log`) will occur.) 

To see what` dbo.backup_databases` would do (which is very useful in setting up backup jobs and/or when making (especially complicated) changes) rather than let it execute, simply set the `@PrintOnly` parameter to `1` (true) and execute - as in the example below (which is identical to Example C - except that commands will be 'spit out' instead of executed):

```sql

EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'{USER}',
    @BackupDirectory = N'D:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\SQLBackups\ServerName\', 
    @BackupRetention = '48 hours', 
    @CopyToRetention = '72 hours';
    @PrintOnly = 1; -- don't execute. print commands instead...
    
```

[Return to Table of Contents](#table-of-contents)

### See Also  
- [Best Practices for Managing SQL Server Backups with S4](/documentation/best-practices/backups.md)
- [dbo.restore_databases](/documentation/apis/restore_databases.md)

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.sproc_name