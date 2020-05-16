![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > S4 Conventions

# S4 Conventions

> ### :label: **NOTE:** 
> *Aspects of this document are not yet even to 'working-draft' stages and are, instead, merely place-holders.*

## TABLE OF CONTENTS
- [Overview and Philosophy](#overview-and-philosophy)
    - [Convention over Configuration](#convention-over-configuration)
    - [Failures and Error Handling](#failures-and-error-handling)
    - [Alerting and Notifications](#alerting-and-notifications)
- [Logical Conventions](#logcial-conventions)
    - [SQL Server Backups and Sub-Directories Per Each Database](#xxx) 
    - [HA Job Synchronization Conventions](#ha-job-synchronization-conventions)
    - [S4 Version History](#s4-version-history) 
    
- [Functional Conventions](#functional-conventions)
    - [@PrintOnly](#printonly)
    - [`<vectors>`](#vectors)
    - [{TOKENS}](#tokens)
    - [{DEFAULTS}](#defaults)
    - [File Path Specifications](#file-path_specifications)
    - [Alerting and Database Mail Conventions](#alerting-and-database-mail-conventions)
    - [Advanced Capabilities / Advanced Error Handling](#advanced-capabilities)
    - [PROJECT or RETURN Modules](#project-or-return)
    - [XE Data Mappings, Extraction, and TraceViews Conventions](#xe-database-mappings)
    - [Database Mapping Redirects](#)
    - [@Modes](#modes)
    - [Domains](#domains)
    - [Lists](#lists)

- [Coding Conventions](#coding-conventions)
    - [SQL Server Agent Job Management Conventions](#)
    - [HA Coding Conventions](#)
    - [Process BUS functionality](#)
    - [S4 Coding Standards](#)

## Overview and Philosophy
S4 skews heavily towards the following philosophical ideals:
- Convention over Configuration
- Fail Fast, Fail Responsibly, Fail Safe (a must, when dealing with data), and Fail Minimally. 
- Avoid Silent Failures while Favoring Signal over Noise 

Details on each of the philisophical ideals listed above are futher clarified below.

### Convention over Configuration  
S4 favors [convention over configuration](https://en.wikipedia.org/wiki/Convention_over_configuration). This is most apparent relative to defaults associated with notifications and alerts, standardized default `@Parameters` for most S4 modules (which attempt to default to the most-commonly-used configuration value or setting), and storage paths + filenames for SQL Server backups.

#### Example of the Benefits of Convention over Configuration
By way of an example of the benefits of convention over configuration, here's an example execution of `dbo.list_processes` - with ALL parameters specified: 

```sql 

EXEC admindb.dbo.[list_processes]
	@TopNRows = 50,
	@OrderBy = N'CPU',
	@ExcludeMirroringProcesses = 1,
	@ExcludeNegativeDurations = 1,
	@ExcludeBrokerProcesses = 1,
	@ExcludeFTSDaemonProcesses = 1,
	@ExcludeSystemProcesses = 0,
	@ExcludeSelf = 0,
	@IncludePlanHandle = 0,
	@IncludeIsolationLevel = 1,
	@IncludeBlockingSessions = 1,
	@IncudeDetailedMemoryStats = 1,
	@IncludeExtendedDetails = 1,
	@IncludeTempdbUsageDetails = 1,
	@ExtractCost = 1;

```

In this case, the majority of parameters/arguments for [`dbo.list_processes`](/documentation/apis/list_processes.md) are obviously simple bit-flags - most of which default to a value of `1` - as that's going to be the most-commonly used 'configuration'. 

By the same token, given that the default for so many of these parameters will typically 'make sense' for execution purposes, the following execution of `dbo.list_processes` leverages convention over configuration (i.e., standardized, 'most sensible', defaults) such that the following code ends up being dramatically easier to 'punch in' and execute: 

```sql 

EXEC admindb.dbo.[list_processes];

```

Granted, in the execution above, the `@TopNRows` value will default to a value of `-1` (vs `50` from the example above) - meaning that it'll pull back ALL rows instead of a TOP N rows. Likewise, the call above does NOT include results from the calling/executing spid or from system processes - as the defaults for `@ExcludeSystemProcesses` and `@ExcludeSelf` are both `1` for `dbo.list_processes`. 

As such, to more faithfully replicate the first example, a better approximation would be the following: 

```sql

EXEC admindb.dbo.[list_processes]
	@ExcludeSystemProcesses = 0,
	@ExcludeSelf = 0;
	
```

Though, again, note that the above 'call' isn't identical to the first example - due to the differences for `@TopNRows` from the explicitly set version vs the defaults. Instead, this example is a 'good enough' execution - where the minimal amount of effort has been expended to achieve 'close enough' results without having to specify every, single, parameter or input. 

But, still, this example implementation of convention over configuration helps highlight how a better understanding and knowledge of how S4 defaults and conventions work can result in a lot less typing and 'work' on the part of users. 

### Failures and Error Handling
S4 favors the following conventions relative to failures and errors.

- **Fail Fast.** Most S4 routines associated with automation (backups, restore-tests, and other maintenance routines) explicitly strive to 'fail early' - meaning that if/when they're mis-configured (set to use illegal or non-valid arguments or parameters), they'll throw exceptions immediately. This can make initial configuration of automation routines a bit more tedious - but helps decrease the potential for 'gotcha' problems and 'surprises' further on. 
- **Fail Responsibly.** S4 code strives to **favor caller-inform** vs caller-beware or caller-confuse.
- **Fail Safe.** S4 routines are designed to work in production environments - where data loss or 'accidents' can be expensive. As such, S4 code is designed to require explicit directives around anything scary (like restoring datbases 'over the top' or existing databases) and/or is designed to attempt to minimize the impact of any and all exceptions that occur during processing.
- **Fail Minimally.** S4 code strives for resiliency. When processing batch operations (i.e., working against one or more larger sets of operations - like backing up multiple databases), S4 code strives to ensure that a single failure (against, say, a backup for a single database) does NOT crash or terminate the entire process or batch-operation. Instead, TRY-CATCH and other advanced-error-handling techniques are used to 'catch' errors during processing, gather context and information for later reporting, and 'move on' to the next operation in the batch - reporting upon all errors and problems once an attempt has been made to process all targets of the batch operation.

### Alerting and Notifications  
Automation isn't very helpful if it either silently 'breaks' (or stops working) and/or automation routines throw errors that either don't provide much context OR require you to drop what you're doing immediately to determine if what you're seeing is a critical problem or something that can wait. As such, one of the key goals of S4 is to try and provide enough 'at a glance' context and error-info as possible whenever errors and problems are encountered. 

To this end, S4 favors the following conventions and paradigms relative to alerting and notifications. 

- **Avoid Silent Failures.** Automation created around the use of S4 code/procedures should be put into SQL Server Agent Jobs in most cases - and said jobs should, in turn, be set to raise alerts or notifications if/when the jobs fail - as a standard SQL Server Best Practice. In similar manner, S4 code also strives to detect, capture, and gracefully handle exceptions during processing as well.

- **Favor Signal over Noise.** While it's better to know that there are problems vs being 'surprised' later on (when you pro-actively go to check on automation routines) - only to find that automation has 'silently failed', no one likes an inbox full of alerts. As such, S4 strives to favor signal over noise by decreasing the number of potential alerts whenever possible. (Otherwise, human nature is to set up 'inbox rules' for noisy alerts - meaning that if/when they finally report something important, no one is really 'watching'). 
    
[Return to Table of Contents](#table-of-contents)  

## Logical Conventions 
The following conventions are 'logical' or represent, primarily, philosophical approaches to interacting with with SQL Server - that have been 'baked into' S4 code and modules as assumptions and/or 'de-facto' standards. 

### SQL Server Backups and Sub-Directories Per Each Database
[  
Place-Holder. In short: the convention used by S4 backups (and restores) is that ALL SQL Server Backups for databases 'should' be stored in a single directory - with a distinct sub-directory per EACH database defined (which then holds ALL of the FULL, DIFF, and LOG backups for said database). For example, `D:\SQLBackups` would be, by convention, the 'root' directory where SQL Server backups are kept for a given server. Then, if backups are put into play (i.e., created) for both user databases on a server (`Widgets` and `Marketing`), then S4 conventions would define, create, and expect all backups for the `Widgets` database to be in the `D:\SQLBackups\Widgets\` directory with all backups for the `Marketing` database to be in the `D:\SQLBackups\Marketing\` directory. 

Reasons: 
1. This convention makes it a lot easier to find/evaluate ALL backups for a given database in a disaster recovery scenario.
2. In smoke-and-rubble DR scenarios, having access to database backups by database (as opposed to by FILE type) means that if you're downloading backups on to a new environment (in a hurry), you can more readily determine which database backups to grab based on database priority and file-types (i.e., grabbing the last FULL + DIFF and any T-LOGs for the `Widgets` database is a lot easier if `Widgets` is the main priority and you can easily see time-stamps (as part of the name) for each backup of the `Widgets` database - to allow you to prioritize those downloads first. 
3. 'Silo-ing' each databases' backups into a single, isolated, folder makes cleanup of older backups easier and safer. 

]

### HA Job Synchronization Conventions
*[DOCUMENTATION PENDING.]*

### S4 Version History
S4 is designed to be updated regularly. An overview of the installation history - along within information about the most recently installed version of S4 on a given SQL Server instance can be retrieved by running the following query: 

```sql 

SELECT * FROM admindb.dbo.version_history;

```

To this end: 
- [Can always get the latest version of S4/admindb via the [latest release page] - using instructions on [updates] page.]
- [Each time admindb_latest.sql is run against an environment - either as an initial install or as part of an update, it will do the following: 
    1. bring local db 'up to speed' to latest version. 
    2. Drop a new row into admindb.dbo.version_history 
]


## Functional Conventions  
Functional Conventions represent standardized ways to interact with S4 modules and operations via a set of commonly-used parameter definitions or concepts/conventions.

### @PrintOnly
Given that a large number of S4 routines are aimed at automation of processes that could or would be 'scary if misconfigured', a large number of S4 routines provide a `@PrintOnly` parameter which typically defaults to a value of `0` (false). In a small number of routines, a value of `1` (true) actually makes much more sense as the default. 

*[NOTE: in many cases ... setting @PrintOnly to 1 will skip/bypass many of the parameter input checks... like for @Operator, @MailProfile, etc... (this is by design: since we won't be emailing... no sense in evaluating those.).]*

*[Examples of how/why.]*

### `<Vectors>`
[A number of S4 routines need to allow-for and/or specify 'time-spans' or other 'vectored differences from now' values - for things like retention rates (for older backups), how frequently to run/poll for certain types of automation checks, and so on. 

As such, rather than defining parameters for these needs as something along the lines of `@RetentionHours` which thereby limits retention 'inputs' or values to hours (which probably works just fine in most scenarios) or dropping to something like `@RetentionMinutes` - which provides better flexibility - but at the 'cost' of incurring *60 multipliers to all values, S4 commonly makes use of `<vectors>` or 'natural-language' time-span specifiers. 

For example, in the case of specifying Retention (i.e., how long backups should be kept), instead of defining 'hard-coded' time-spans as part of the parameter name, `dbo.backup_databases` provides a simple `@Retention` parameter - with a data-type of nvarchar(MAX) - which allows for the following, natural-language, values or inputs (all of which, below, are valid): 
- `N'1 hour'`
- `N'28 hours'`
- `N'28h'`  (`hour`, `hours`, `h` are all treated equally)
- `N'2 weeks'` or `N'2w'`
- `N'5days'`, `N'5 days'`, `N'5d'`
and... so on. 

This convention makes it MUCH easier to spot, at a glance, how 'long' or how 'frequently' something should be run or removed, and so on - by rendering the values in natural (English-Only) language. ]

#### N Backups as an Exception
There is one 'exception' to `<vectors>` being time-related - which is that for `dbo.backup_databases`' `@Retention` paramter an additional 'class' or 'type' of natural language inputs can be specified: the number of backups to keep. 

For example, if I'm creating a set of automation routines (i.e., jobs) for creating backups and do NOT wish to keep FULL backups of my `Widgets` database for a specific time-span or period-of-time but wish, instead, to only keep the most-recent 2x backups, I would specify the `@Retention` value as `N'2b'` or `N'2 backups'` instead of something like `N'2 days'`. 

### {TOKENS}
[
S4 uses `{TOKENS}` to make working with 'classes' or 'types' of databases (and other objects/collections-of-objects) easier. 

'Out of the box', S4 ships with the following `{TOKENs}`: 
- `{ALL}` - as expected, this means 'all databases' (or 'ALL' of any other collection being worked with).
- `{SYSTEM}` - represents only SQL Server's system databases - which always include the `master`, `model`, and `msdb` databases - along with the `tempdb` whenever it makes sense (i.e., when specifying `{SYSTEM}` for the `@DatabasesToBackup` parameter, `dbo.backup_databases` obviously won't try to backup the `tempdb`). Similarly, the `resource` database is also treated as a `{SYSTEM}` database and if a replication-level `distribution` database is present, it too will be treated as a `{SYSTEM}` database. Finally, by convention, the `admindb` is also treated as a `{SYSTEM}` database - though this can be overridden.
- `{USER}` - the opposite of `{SYSTEM}` - i.e., user-databases - which is commonly then 'paired' with `@DatabasesToExclude` inputs to then 'strip out' or remove dbs (or wild-cards for db-names) specified by the exclusions from the list of all other user databases. 
- `{READ_FROM_FILESYSTEM}` - a specialized token that, as the name implies, means that when running restore-operations (either for DR purposes or, more commonly, automated backup-validation/testing), the 'list' of databases to restore or process should be pulled from the file-system - using S4's convention of treating each child/sub-folder in a given backup directory as if it should contain backups for a given database. 

Importantly, S4 can also allow for the creation of user-defined, or custom, tokens as well - such as arbitrarily named tokens like `{DEV}` or `{MISSION_CRITICAL}` and so on. At present, this functionality is viable and tested/supported - but not documented. To get a sense for what's involved (it's not hard), take a look at `dbo.list_databases_matching_tokens` to see how it works with 'out of the box' tokens and how it looks for and would process any other tokens present during processing. 

]

### {DEFAULT}
Technically speaking, the `{DEFAULT}` convention is really just an extension of the capabilities offered by `{TOKENS}` - just limited in scope to typically scalar values - where S4's adherence to [Convention Over Configuration](#convention-over-configuration) means that `{DEFAULT}` values can be explicitly defined as input parameters as an explicit way to signal the DESIRE to use conventional defaults vs explicit configuration. 

[For example... the `@BackupDirectory` parameter for `dbo.backup_databases`. By convention, `dbo.backup_databases` will check the default location specified at the SQL Server Instance level for the path at which Backups should be stored (set during installation and/or managed via SSMS by right-clicking on the Server, selecting Properties, and setting paths as desired in the Database Settings tab.)

If desired, `@BackupDirectory` COULD be left empty/NULL - which would have the same behavior - i.e.,  S4 will check server-settings for the 'default' backup directory - and use that if defined (and throw an error if the path is not set or is set but non-valid). However, by specifying that `@BackupDirectory = N'{DEFAULT}'` makes it clear that the intended behavior is to use this 'lookup and use the conventionally defined data' functionality rather than, say, what would be implied if `@BackupDirectory` were set to `N'D:\SQLBackups\'`. 

Take-Away: The KEY thing here is to know that S4 attempts in many cases (backups, restores, alerting, etc.) to use conventions that define commonly-used/specified parameters to avoid the need to 'hard-code' values into S4 calls as a means of helping ensure that S4 automation routines stay more resilient and easier to manage over time.

]

### File Path Specifications
[
*S4 uses convention of trying to use defined 'default' paths defined in SQL Server (registry) for data, log, and backup. If these aren't set (or aren't valid... throw an error) and, of course, you can change these...  ]

NOTE: paths provided in S4 can have \ or skip trailing slashes in path names... (file names - obviously not)... S4 normalizes all paths... so if D:\SQLBackups is your preference, good on you; or if you prefer D:\SQLBackups\ good on you - equally (life's too short to have to remember pathing conventions).*
]

### Alerting and Database Mail Conventions
[
PLACE HOLDER: 

2 Key Options for Implementation: 
- Default Implementation is that S4 (by convention) 'expects' or 'anticipates' that `@MailProfileName` will always be `N'General'` and that the `@OperatorName` for alerts will always be `N'Alerts'`. With that in mind... `dbo.configure_database_mail` makes it easy to set up SQL Server's Database Mail on NEW instances/deployments with these conventions 'baked in'. 

- Otherwise, there are two other, main, options/approaches: 
a. explicitly specify values (i.e., whatever makes sense in YOUR environment - based on what you've already set up) for `@MailProfileName` and `@OperatorName` per each call/execution of a sproc that REQUIRES these values. 

or 
b. (This functionality is 100% pending (i.e., NOT YET DONE)), run something like `dbo.define_database_mail_mappings` and specify the 'defaults' that you want to use for `@MailProfileName` and `@OperatorName` at a 'global' level - at which point the values that you specify become 'your' defaults (i.e., any S4 routine that then either sees values of `N'{DEFAULT}'` for either of these params OR doesn't see these params explicitly defined, will then a) look for defaults defined in `dbo.settings` and b) use those if present... otherwise, if defaults aren't EXPLICITLY defined, it'll c) use `General` and `Alerts` then, d) EITHER way (i.e., no matter where it gets those 'values' - input params, defaults, or 'conventions'), it'll then CHECK whatever was 'resolved' before proceeding so that we 'fail fast' during configuration/setup. 

]

### Advanced Capabilities / Advanced Error Handling
[
PLACE HOLDER:

- Example of how TRY-CATCH within SQL Server (up to at least SQL Server 2019) FAILS to handle (catch) a number of key exception types - especially those related to backups/restores and other 'maintenance type' operations. 

- Showcase how xp_cmdshell ends up being an odd, but... interestingly enough... powerful work-around to this problem. (One of the big 'wins' from this is ... that it lends itself REALLY well to retry-logic when implemented correctly.)
(i.e., the above 2x 'details' are the rationale for why 'advanced error handling' exists and is implemented the way it is.)

- Conventions around enabling/disabling - i.e., xp_cmdshell and some of the info defined in the setup.md documentation + links to the 3x sprocs defined for advanced capabilities review/management.
]

### PROJECT or RETURN Modules
[A bit of an S4 'oddity' - but quite helpful. In short, given that S4 routines are designed for DBAs and/or for automation, there are technically 2 primary ways that a number of S4 routines can be called or executed: a) by a DBA at the 'command-line' - running in iterative/real-time fashion or b) by other S4 routines that need to 'consume' the output of a given block of S4 code - and then iterate-over or work-with said output to work on additional processing rules and or other implementation details relative to automation.

Or, stated differently, `PROJECT or RETURN` sprocs can primarily be called/executed with two types or primary forms of output: 
- They can 'spit output' into the normal console (SSMS output window, etc). 
Or 
- They can provide output in the form of an `@Output` parameter for use in API-centric calls.

An example is `dbo.script_login` - which can be called iteratively by a DBA who needs an ad-hoc/one-off definition of a specific login - as follows: 

```sql 

EXEC [admindb].dbo.[script_login]
	@LoginName = N'Bilbo',
	@BehaviorIfLoginExists = N'ALTER';
	
```

And which will then 'print' the output of `dbo.script_login` out to the console. 

However, since `dbo.script_login` can be used to 'dump' or output large lists/chains of logins to a flat-file as a type of backup (which is exactly what `dbo.export_logins` does), programatic access to `dbo.script_logins` can also be executed as follows (by defining an @Output parameter and ensuring that it's value is NULL - either by EXPLICITLY setting it to NULL or by implicitly leaving it unassigned): 

```sql

DECLARE @loginDefinition nvarchar(MAX);
EXEC [admindb].dbo.[script_login]
	@LoginName = N'Bilbo',
	@BehaviorIfLoginExists = N'ALTER', 
	@Output = @loginDefinition OUTPUT;


IF @loginDefinition IS NULL 
	PRINT 'ruh row!';
ELSE 
	PRINT @loginDefinition;
	
```

Where, in the case of the example above, IF the `Bilbo` login exists, it will end up being assigned to the `@loginDefinition` parameter because the value of `@loginDefinition` is implicityly `NULL`; 

#### Requirements for Implementing the `PROJECT or RETURN` Convention
To implement the `RETURN` aspect of this convention you must do the following: 
1. Create an `@Output` parameter (`@loginDefinition` in the above example). 
2. Either leave your `@Output` variable UNINITIALIZED or EXPLICITLY set the value to `NULL`. (e.g., if you specified: `DECLARE @output nvarchar(max) = N'';` a non-NULL value has been set, and the `RETURN` convention will be bypassed in favor of `PROJECT`). 
3. Assign the `@Output` parameter of the S4 sproc you are calling (by convention, this parameter is (or should) always be called `@Output`)) to YOUR output paramter (i.e., in the example above, `@Output = @loginDefinition` accomplishes this task), 
4. Ensure that your output parameter has been explicitly defined as a T-SQL `OUTPUT` parameter (i.e., `@Output = @loginDefinition OUTPUT;`).

]

### XE Data Mappings, Extraction, and TraceViews Conventions
*[DOCUMENTATION PENDING.]*

### Database Mapping Redirects
*[DOCUMENTATION PENDING.]*

### @Modes
A number of S4 stored procedures and functions (especially those that are `SELECT` or 'query' heavy) leverage the convention of using a `@Mode' (or other functionally similar parameter - but with a different name) to enable specify different processing outcomes or excution processing rules. 

For example, `dbo.refresh_code` provides a `@Mode` parameter that enables or directs 3 modes of operation - or 'targets' that refresh operations can use: `VIEWS`, `MODULES`, or `VIEWS_AND_MODULES` (i.e., one option, or the other, or both). 

In a similar fashion, `dbo.script_login` (and associated/similar functions) provide an `@BehaviorIfLoginExists` parameter which controls what kind of output/projection to provide when scripting a target login: `NONE` (don't use IF-Checks), `ALTER` (script an If-Check + ALTER clause as part of the output), or `DROP_AND_CREATE` (script an IF-Check with a DROP + CREATE clause as part of the output). 

Technically speaking, the @Modes convention is a VERY light-weight convention with little impact (whether you know about this convention or not won't radically impact your use of S4 one way or the other).

### Domains
[Effectively an extension of `@Modes` - in the sense of easily query-able meta-data defining the domain ('full-list of options') for a given `@Mode` (or `@Mode-Like`) parameter - to make chosing between options that much easier while 'in the trenches'.]

### Lists
*[DOCUMENTATION PENDING.]*

## Coding Conventions 

### Procedure Naming

### HA Coding Conventions

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md)