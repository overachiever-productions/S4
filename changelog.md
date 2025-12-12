![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

# Change Log

## [12.8] - 2025-12-11 
xxxx

### Fixed
- Full overhaul of logic within `dbo.apply_logs`; fixed issues with erroneous 'duplicates' reported and generally fixed overall processing so that this sproc is now quite solid/dependable. 

### Added
- Addition of `dbo.execute_per_database` - which does what it says and will eventually be used (backhauled) into gobs of existing diagnostics that can/will run per database. 
- New `APPLY_DIFF` functionality now supported for `dbo.restore_databases` - which allows a DIFF to be applied to a restored FULL which hasn't, yet (obviously), had a DIFF applied. (Primarily designed to simplify DR scenarios (allows RESTORE of FULLs as soon as they're downloaded to a DR/smoke-&-rubble box without having to 'wait' for DIFFs - which can be applied later; but works EQUALLY well for migrations). 
- Along with the above, there's now a new `EXCLUDE_DIFF` directive option for `@Directives` within `dbo.restore_databases` (allowing option to SKIP/EXCLUDE diffs). 
- Added `dbo.preferred_secondary` (UDF) for use in helping EXTERNAL applications know which secondary to pull backups from when backups are being used for non-prod needs. 
- Addition of `dbo.targeted_databases` as new 'filter' sproc (will eventually replace `dbo.list_databases`). Importantly, this NEW sproc allows WILDCARDs in target DB names - i.e., patterns vs just-hard-coded names (while still allowing `{tokens}` as well). NOTE: This also replaces `dbo.load_databases` - in fact, ti's effectively just a rename + some tweaks. 
- A smattering of new diagnostics sprocs including: 
    - `dbo.vlf_counts`
    - `dbo.compute_details`
    - `dbo.querystore_details`
    - `dbo.filtered_index_obstacles`
    - `dbo.escalated_server_permissions`
    - `dbo.disabled_constraints`
- Addition of additional 'smells' identification within `dbo.database_details`.

### Changed
- Full overhaul of Per-DB Migrations 'Scripts' - into 2x sprocs (Initialize (on 'old' server) and Finalize (on new server)) to simplify migration of databases between servers. 
- Removed the `@AllowReplace` parameter for `dbo.restore_databases`. The parameter is now called `@IfTargetExists` and allows values in the form of `{ THROW | APPLY_DIFF | REPLACE }` (where `THROW` is the DEFAULT behavior and `REPLACE` still 100% has to be correctly typed, and then 'replaces' just as `@AllowReplace` used to).
- `dbo.backup_databases` is now better able to address 'contained' (AG) system databases.

### Known Issues
- Code Library functionality mostly works. Consider it (still) to be an alpha or early beta. Needs documentation and some additional testing. Biggest issue is that granting permissions to SQL Server to interact with PLA roles requires a RESTART of SQL Server / SQL Server Agent (which needs some guidance), etc. 
- `dbo.filtered_index_obstacles` needs some hefty documentation - consider it an alpha/eary-beta release. 

## [12.6] - 2025-09-30
Incremental updates and mods; Initial Introduction of Code Library Framework.

### Fixed 
- Deployment bugs/errors with `dbo.numbers` table. 

### Improved 
- Additional improvements and mods to synchronization setup for deployment of code to PARTNER servers. 
- Tweaks (non-NULLable columns) for storaged of blocked process reports. 
- Overhaul/rewrite of `dbo.list_databases` via NEW sproc: `dbo.load_database_names` - which allows targeting/exclusions via `@Databases` (instead of @Target and @Exclusions) + (finally) allows wildcard support (while continuing support for `{TOKEN}`s). 

### Added 
- New sproc: `dbo.execute_per_database` - allows execution of code per all and/or specified `@Databases`.
- Initial addition of Code Library functionality - i.e., ability to deploy serialized code from/via `admindb.dbo.code_library` (including code-signed .ps1 files) - to simplify Data Collector set and other OS-level (Windows) interactions. 
- New troubleshooting sproc/helper: `dbo.translate_characters` - simple routine to spit out each char in a string with position (index), current value/char, ASCII, and UNICoDE values for help with debugging/troubleshooting string-matching and evaluation logic.
- Diagnostic sproc: `dbo.database_details` - work in progress, but provides high-level details about databases. 

### Known Issues
- Code Library Functionality is not currently suppported pre-SQL Server 2016 (i.e., use of `COMPRESS()` function will cause errors during attempts to install).

## [12.4] - 2025-09-03
Miscellaneous Improvements and AG / HA Optimizations.

### Fixed 
- Orchestration Problem with location of `dbo.get_engine_version()` during setup/deployment. Was previously 'lower' in execution order, causing ugly bugs/problems with NEW deployments. 
- Perf fix for `dbo.index_metrics` (previous code wasn't correctly predicating for specified TABLE names via `sys.dm_db_index_physical_stats()` causing operations to (obviously) take FOREVER on larger DBs.)
- Multiple fixes and improvements for ('internal') `dbo.numbers` table - including checks to verify whether populated or not. 

### Improved
- AG Setup Sprocs (`dbo.add_synchronization_partner`, `dbo.create_sync_check_jobs`, and `dbo.process_synchronization_failover`) all bolstered/improved to address issues with non-idempotentcy in some environments/scenarios. 

### Added
- `dbo.check_database_consistency` now LOGS outcome / details to `dbo.corruption_check_history` table. 
- **High-level** metrics for DBCC checks (logged into `dbo.corruption_check_history`) via `dbo.corruption_check_analytics` (an Inline Function). 
- INITIAL logic for addition of `@DotIncludeFile` for PowerShell operations (5.1 and Core) against `dbo.execute_command` and `dbo.execute_powershell`. (Initial = works well, but not fully integrated with 'code library' functionality - coming soon-ish.)

### Changed
- Minor, internal, tweaks/cleanup to `@ExecutionType` operators for PowerShell/Pwsh operations. SHOULD be transparent to callers. 

## [12.2] - 2025-05-23
Miscellaneous bug-fixes and minor improvements to backups.

### Known Issues
- Creation of numbers-table (`dbo.numbers`) is currently 'lazy' and does NOT enable `DATA_COMPRESSION` for SQL Server 2016 SP1 + instances. (It only enables for SQL Server 2017+.)

### Fixed 
- Bug-fix to address problems with RPO Violations erroneously reporting 'gaps' caused by DIFF backups. 
- Corrected issue with IO latency (percent-of-percent load/distribution) percentages not totaling 100%.
- Corrected duplicate exclusion for filtered alerts against 17828 (17821) and 17836 (17832).

### Improved 
- `dbo.backup_databases` No longer requires `@OffsiteRetention` to be specified. Instead, it defaults to the value of `N'{INFINITE}` (which is the only value/option currently specified.)

### Added 
- Initial implementation of Base64 encoding functionality. (Primarily for calls into PowerShell.)
- Initial functionality to allow 'arbitrary' `@EventStoreTarget` parameters for Blocked Processes and Large-SQL Reports/Reporting-Logic.
- Initial addition of common/standardized predicates for all Event Store Reports.
- `dbo.script_targetdb_migration_template` now has (initial) options for DIRECTIVES during restore, and can specify `@IgnoredOrphans` (primarily to address orphans in source environment).
- Initial addition of `dbo.core_predicates` for use (going forward) as single (DRY) location for all common predication logic (logins, databases, hosts, statements, etc.).
- EARLY logic/functionality to allow offsite backups to be pushed to Backblaze (i.e., `B2` and `S3` are now both supported for offsite backups).

### Changed 
- Refactored `dbo.view_querystore_consumers` to `dbo.querystore_consumers`.
- `dbo.verify_database_configurations` now attempts to switch (user) databases to FULL recovery. 
- FULL refactoring of scripting for job-states and logins into 2x distinct (for each) scripts that can disable all (with exclusions) jobs/logins and (different/stand-alone) scripts to script logins / job enabled details. 
- FULL rewrite of `dbo.kill_blocking_processes` to standardize identification, enable alerts and/or KILL operations, and facilitate simplified/streamlined capture - along with options to specify COMMON predicates. 
- `dbo.backup_databases` no longer attempts to execute T-LOG backups against `READ_ONLY` databases.


## [12.1] - 2024-10-15
Bug-Fixes for Restore Operations + Additional Tweaks and Improvements.

### Fixed 
- Bug-Fix for problem with RESTORE operations checking for LSN 'overlap' being TOO aggressive and causing RESTORE HEADER errors due to "collisions" with T-LOG backups (.trns) being actively written. (Fix was to add lower and UPPER bounds to .trns needing LSN checks.)
- Bug-Fix for `RESTORE HEADER is terminating abnormally` errors - caused by similar issue (i.e., overly-agressive LSN-checks for overlaps) to problem with RESTORE tests failing. 
- Corrected BUG with `dbo.help_index` which was preventing included columns from being displayed (i.e., results were always `NULL` - even if/when included columns were present as part of index definition).
- Miscellaneous, minor, bug-fixes for CASE-SENSITIVE servers. 
- Major performance improvements for RESTORE operations against T-LOGs (improved performance for enumerating and identifying T-LOGs for application). 
- Minor bug-fix for file-path lengths of backup files.

### Added
- Addition of option to specify `N'{INFINITE}` retention for local/copy-to backups (previously was ONLY allowed for S3/Offsite backups) - to help lay foundation for option to enable immatable backups (ransomware protection).
- New sproc: `dbo.kill_long_running_processes` - similar to `dbo.kill_blocking_processes` (only can simply target longer-running processes that AREN'T blocking) - as a stop-gap for applications that 'leak' connections. Can be targetted with white-listed app, user, host, db, etc. or black-listed attributes (or combinations thereof).
- New IGNORE (defaults) responses for Alerts against error IDs `17835`, `4014`, `17826`, etc.
- Improved / Updated logic to manage 'cadence' of blocked_process reporting/gaps (between events).
- New dbo.numbers table to help offset SOME performance issues with larger strings and `dbo.split_string()`;
- Initial functionality to report on SLA violations (RPOs) for scenarios where T-LOG backups execute at cadences in excess of specified RPOs (e.g., assume that RPOs are 10 minutes and T-LOG backups are scheduled to run every 10 minutes but on SOME busy/heavily-used (typically multi-tenant) systems a few T-LOG backup jobs a day take 12-14 minutes to run - at this point, RPOs have been violated; new functionality now makes this visible during restore-tests.)
- `dbo.kill_blocking_processes` now ignores any/all `DBCC` commands (similar logic added to `dbo.kill_longrunning_processes`).

### Changed 
- `dbo.format_timespan()` used to ONLY format timespans in the format of `HHH:MM:ss.mmmm` - which caused some 'janky' ('wrapping' vs overflow) problems when a timespan was > 1000 hours. New logic uses `HHH:MM:ss.mmmm` for first a few days' worth of hours, then switches to N.N days/weeks/months/years for simplified summaries.
- Major overhaul / rewrite of alerting logic for `dbo.restore_databases` - to make PROBLEMS much more obvious via email alerts AND to ensure that alerts, notifications, and warnings are formatted, ordered, and given SUBJECT-LINEs that make corruption, failures, and RPO violations much more obvious.
- Overhaul of core logic/workflows for setup of EventStore sessions. 
- `dbo.parse_backup_filename_timestamp()` now uses built-in T-SQL `STRING_SPLIT()` for better performance (against SINGLE char 'splittors') than `admindb.dbo.split_string()` UDF on SQL Server 130+ servers.
- Major overhaul and standardization of EventStore reports - standardized 'templates', @parameters, etc. 
- Explicit `DISABLE_BROKER` for/against the `admindb`. 

### Known Issues

## [12.0] - 2024-05-04 
Improved DB Restore Capabilities/Options + Initial Addition of EventStore Functionality.

### Fixed 
- Major overhaul of restore-logic within `dbo.restore_databases` and associated 'helpers' to address MULTIPLE different causes of 'LSN too recent' errors caused during restores due to T-LOG and FULL/DIFF backups being executed at same time and/or at 'overlapping' times.
- Major overhaul of logic within `dbo.help_index` to leverage functionality/logic from within `dbo.list_index_metrics` (to avoid DRY and improve index context/info/outputs) - along with significant performance tweaks and improvements. Initial functionality for scripting/dumping index definitions (via `dbo.script_indexes` - which isn't QUITE done yet).
- Fixed bug within `dbo.execute_command` causing some ugly issues with PowerShell execution, etc. 

### Added 
- New Directives for `dbo.backup_databases` including `TAIL_OF_LOG` (for DR), `FINAL` (for migrations), and `KEEP_ONLINE`.
- New Directive (`STOPAT`) for `dbo.restore_databases` to more easily facilitate Point-In-Time Restore Operations (DR).
- Additional filters (exclusions) for `dbo.kill_blocking_processes` - to allow 'white-listing' of databases, hosts, logins, etc. 
- INITIAL checkin/addition of EventStore core functionalilty (settings and ETL functionality) + some INITIAL reports.
- Additional wrappers for setup/validation of installation + configuration of AWS.Tools.S3 PowerShell modules and functionality to allow offsite backups to AWS S3 via `dbo.backup_databases`.
- Option to force databases to use RCSI in `dbo.verify_database_configuration`.
- (Finally) added `dbo.extract_waitresource` to source-control (this is leveraged heavily for Deadlock and Blocked Process extraction).
- Added `report_io_latency_percent_of_percent` report (to growing list of capacity planning reports).
- Added `dbo.extract_dynamic_code_lines` for debugging + error-handling-context when working with dynamic SQL. 

### Changed 
- Overhaul of `dbo.script_sourcedb_migration_template` to leverage new BACKUP directives. 
- Rewrite of `dbo.print_long_string` - to avoid dumb logic problems that added addition/spurious CRLF into outputs. 
- Minor tweak to `dbo.restore_databases` to avoid overfilling SQL Server Agent job history with "success" messages during restore-tests against larger numbers of target databases.
- Minor perf improvement for `dbo.restore_databases` (via `dbo.load_backup_files`) to improve stability/performance of operations against larger numbers of LOG files. 
- Removed 'old school' sprocs/functionality for XE Session translation + reporting. (All to be replaced by EventStore functionality - as the 'old school' stuff was great-ish, but a SUPER big pain to manage and not at all documented.)
- Minor tweak to `dbo.extract_code_lines` to improve readability/formatting of outputs. 

### Known Issues 
- EventStore functionality is NOT quite ready for prime-time. It's NOT documented and relies heavily upon conventions (which only exist in Mike's head) - and still needs some overall tuning/optimization, refactoring, and consolidation of overall functionality. 

## [11.1] - 2023-08-29 
New Utilities + Functionality & Bug Fixes. 

### Fixed 
- Case-Sensitive collation fixes for off-box copies of backups. 
- Bug fix for `dbo.translate_blockedprocesses_trace`. (Fixed issues of looking for either blocked_process.xel or blocked_processes.xel - with a simple wildcard.)
- Bug-fix for `dbo.list_orphaned_users` - to improve filter/exclusion logic. 

### Added 
- Distinction between RPO tests and 'sanity checks' for restore-tests. 
- Ability to allow sync-checks from SECONDARY servers (if @PrintOnly = 1).
- Initial logic and underlying funcs/utilities for XESTORE capabilities. 
- Initila logic / utilities for configuration of S3 backup capabilities (not ready for prime-time yet).
- Logic to extract SQL Server Agent job step BODY (command) by job-name and step-name. 
- Utility to list plans FORCE'd by Query Store. 
- Full-blown support for server-level roles during server-synchronization checks + utility to script/dump server-level role (permissions and members).
- New diagnostic utility - `dbo.list_login_permissions` to show HIGH-LEVEL role-membership by login PER database. 
- Updated/Improved Migration Utilities - to script (dump) and disable/re-enabled logins and jobs. 
- New utility for KILL-ing runaway queries: 'dbo.kill_connections_by_statement'. 

### Changed 
- Renamed `dbo.fix_orphaned_logins` to `dbo.fix_orphaned_users` (logins don't get orphaned, users do).
- Coalesed `dbo.list_index_metrics` and `dbo.help_index` down into SINGLE set of shared logic to avoid DRY violations. 
- OFFSITE retention switched from `'infinite'` to `'{INFINITE}'` - i.e., to make 'infinite retention' a token. 

### Known Issues 
- There are some odd perf issues (in some environments) with `dbo.help_index` - where it can take a while to return results. 
- S3 Backup 'helpers' need more work. 

## [11.0] - 2023-05-17 
New features, capabilities, and functionality + bug-fixes.

### Fixed 
- `dbo.verify_job_synchronization` can now address 'startup' schedules.

### Added 
- `dbo.kill_blocking_processes` adds white-listing functionality/filters - i.e., can ONLY kill lead-blockers if/when they're in a white-listed set of logins/apps/etc. (Exclusions still supercede inclusions.)
- `dbo.kill_blocking_processes` adds LOGGING table/functionality - i.e., snapshot of blocking problems is logged to the `admindb` any/every time a blocked process is killed. 
- Time-Zone related helpers/funcs. 
- Initial functionality (attempts) for right-aligning numeric data in reports/etc. via `dbo.format_number`;
- Advanced option to always force retention/cleanup on secondaries. 
- Initial release of 'weaponized' functionality to fix/drop orphans via `dbo.fix_orphaned_logins` and `dbo.drop_orphaned_users`;

### Changed
- `dbo.list_top` now provides option to control 'inner' TOP(X) as a parameter.
- Major overhaul of Time-Zone translation functionality for XE traces (extraction/transformation and options for setting @TimeZone when running views/reports).
- Improved visibility for backup TYPES (full, diff, log) via failure alerts/emails.

## [10.3] - 2023-02-17
Bug-fixes for backup/restore operations + introduction of some new diagnostics/reports.

### Fixed 
- Bug-Fix to address removal of T-LOGs when `READ_FROM_FILESYSTEM` specified in cleanup via `dbo.load_backup_database_names`.
- Corrected typo with # of GBs free in `dbo.verify_drivespace`.
- Bug-Fix for errors with backup file-names 'outside' of S4 conventions. No longer 'breaks' file cleanup.
- Bug-Fix to address erroneous REPORTING of applied logs via `dbo.apply_logs`. Now correctly outputs/reports the actual files applied. 
- Bug-Fix for `dbo.kill_blocking_processes` - to remove NULL + @otherText that wiped out summary of KILL'd process(es).
- Logic to prevent `dbo.kill_resource_governor_connections` from executing KILL SELF when 'self' not in a targetted pool/workloadgroup. 
- Bug-fix to logic preventing error alerts/emails from failure to DROP databases during restore-tests.


### Added 
- Option to update to INDIRECT CHECKPOINTs via migration template scripts.
- Early release of 2x plan_cache extraction diagnostics. 
- RESTORE HEADER ONLY support for SQL Server 2022. 
- Initial introduction of (PowerShell) logic to extract kernel % usage times within `dbo.verify_cpu_thresholds`.
- Initial release of 2x HEAP diagnostics. 
- Initial release of 2x Resource Governor metrics/reports. 

### Changed 
- Streamlining CPU + IO + memory counter-extraction for Capacity Planning. 
- Full rewrite of `dbo.verify_job_synchronization`.
- Full rewrite of `dbo.script_logins` - to VASTLY simplify functionality (i.e., no longer cares about logins by DB, orphans, etc. - just scripts logins).

## [10.2] - 2022-08-16
Improved Backups/Restores; New Utilities and Bug-Fixes.

### Fixed 
- Bug-fix for missing file/function (`dbo.transient_error_occurred`) from 10.1 build. 
- Bug-fix for `dbo.execute_command` - to address `-S` definition for named server instances.
- Case-Sensitive Server Collation fixes. 

### Added
- Short-circuiting logic for `dbo.kill_blocking_processes` to avoid some bugs and optimize potential lookups/processing. 
- Added small number of files to git that SHOULD have already been added.
- Initial Addition of `@JobCategoryMapping` for job-category mappings/ignore-options for Synchronized Job Checks.

## [10.1] - 2022-07-14
Improved Backups/Restores; New Utilities and Bug-Fixes.

### Fixed 
- MAJOR: Fix for 'Conversion failed when converting date and/or time from character string.' when attempting to execute `dbo.restore_databases` or run `dbo.apply_logs` against 'non-conventional' file-names (i.e., files with markers or with ad-hoc names).
- Improved handling of error conditions within `dbo.view_largergrant_problems`.

### Added
- `dbo.list_top` - Light-weight "Top CPU Consumers (right this second)" sproc to address scenarios where `dbo.list_processes` encounters locking/blocking or is slow. 
- `dbo.kill_blocking_processes` - Ugly 'hack' to enable periodic or automated cleanup (KILL) of applications that LEAK connections to prevent major concurrency problems against active workloads. 
- New `@Directive` for `dbo.restore_databases` that enables `PRESERVE_FILENAMES` for side-by-side migrations (from one disk/server to another) easier when using `dbo.restore_databases`.
- `dbo.view_querystore_consumers` - to enable easy extraction of 'worst' queries via Query Store (not much different than using the GUI - but provides scripted access AND is MUCH faster than Query Store extraction on OLDER versions of SQL Server).
- `dbo.view_querystore_counts` - Aggregated counts/reports for performance analysis.
- `dbo.list_collisions` now includes an `is_system` column.
- Additional meta-data (stats/etc) extraction/handling for `dbo.extract_waitresource`.
- Initial addition of `dbo.alter_jobstep_body` - 'helper' func to make mass/scripted modification of job-steps easier and/or to help facilitiate job-synchronization between servers. 
- `dbo.dump_module_code` - helper func to script/dump all matches from `sys.sql_modules` across multiple/all databases. 
- `dbo.extract_matches` - helper func for identifying multiple matches (by position) of a search-term within a given string/block-of-text.

### Changed
- Major overhaul of 'internal' logic/processing via `dbo.execute_command` to allow for better error-handling and outcome-reporting of executed operations. 
- Improved error handling/storage (output) of `dbo.check_database_consistency`.
- Transient error-handling within `dbo.restore_databases` to address issues with 'hiccups' or file-in-use errors when attempting to restore backups. 
- Improved error-handling within `dbo.backup_databases` to simplify troubleshooting of common backup errors/problems. 
- Improved logging of errors/problems during backups via addition of backup_history_entry and backup_history_detail handling. 

## [9.1] - 2021-09-07
Minor Bug Fixes. 

### Fixed
- Minor Tweak to `dbo.create_server_certificate` to prevent error/exception when `@PrintOnly = 1` for testing/scoping.
- Verified that `dbo.script_logins` can/does/will process WINDOWS GROUP Logins without issues. 


### Added
- Initial addition of 3x new sprocs useful in creation/definition of dev/test databases and/or in QA environments: `dbo.prevent_user_access`, `dbo.script_security_mappings`, `dbo.import_security_mappgings`. NON-documented. 

## [9.0] - 2021-08-12 
Improved RPO/RTO monitoring metrics for synchronized databases. 

### Changed 
- Minor improvements to `dbo.create_consistency_checks` and `dbo.create_index_maintenance_jobs`. 
- Full overhaul of `dbo.verify_data_synchronization` to address issues with red-herring alerts for low-use AG/synchronized databases.

### Added
- `dbo.verify_drivespace` now allows notifications based on percentage of disk used vs just GBs free.
- `dbo.count_rows` - simple helper utility using sys.partitions to allow quick row-counts of target tables.
- `dbo.extract_code_context` - helper utility to extract all matches of `@TargetPattern` in sys.sql_modules and display matches + before/after lines of code. 
  
## [8.8.3652] - 2021-06-14

### Changed
- Numerous modifications to setup/configuration scripts (sprocs) to allow better idempotent deployment in conjunction with Proviso.
- Tweak to `dbo.restore_databases` and supporting logic (sprocs) to address 'ties' for time-stamp overlap of FULL/DIFF backups and T-LOG backups to use EARLY T-LOGs vs favoring attempt to try and grab more 'recent' options. (In conjunction with bug-fixe listed below.)

### Fixed 
- Bug-fix for object parsing + identification in 'other' databases. 
- Initial bug-fix for Error 4326 LSN 'too early' problems when automating restore of T-LOGs created concurrent with previous FULL/DIFF backup. (Subsequent fix will address this problem via inspection of LSNs vs simply 'swallowing' errors with 'too early' issues and applying next T-LOGs.)

### Added 
- Initial options for scripting db file movement via `dbo.script_dbfile_movement_template` to allow streamlined movement of files without detaching databases. 
- Sproc to kill Resource Governor connections in pools/workload-groups OTHER than default/internal + ability to 'kill self'. 
- Initial addition of Capacity Planning logic and routines in the form of `translate_xxx_counters` + `report_xxx_percent_of_percent_load` and other similar analytics/metrics-assessment routines. 
- Initial addition of idiom for batched_operations. 
- New XE view: `dbo.view_largegrant_problems` to display/rank 'worst' grant problems from extracted/translated XE traces. 
  
## [8.7.3614] - 2021-05-07

### Changed
- Signature (parameters) change to `dbo.enable_alert_filtering` to now allow only `{ SEVERITY | IO | SEVERITY_AND_IO }` vs the option for `{ALL}` previously - which wasn't even implemented (i.e., previous implementation was not only 'odd' but a bug.).
- Ginormous hack/work-around within `dbo.enable_alert_filtering` to address ugly bug in SqlServer Powershell's (latest 21.x or whatever) Invoke-SqlCmd NOT 'obeying' the -DisableParameters switch. 
- Minor tweak to `dbo.list_cpu_history` to allow `@LastNMinutesOnly` (for use in metrics collection/capture).


## [8.6.3591] - 2021-04-14

### Changed 
- `dbo.list_collisions` now included `host_process_id` to better help with tracking down locking/blocking root-causers. 
- `dbo.process_synchronization_failover` now 'calls into' `dbo.process_synchronization_status` to allow 'forking' of logic for failovers AND server-startups to be processed by the same root logic. 

### Fixed 
- Bug-fixes for removal of backup files to account for host-name in path of backups for system databases.
- Minor bug fixes for case sensitivity collations/servers. 

### Added 
- Initial addition of idioms and blueprints (blueprints are 'more weaponized' idioms - in the form of code that generates idiomatic sprocs/etc.).
- Diagnostics to extract and report on large-grants from XE trace. 
- New stored procedure: `dbo.list_cpu_history` - simplifies extraction of last 256 mins of CPU usage by means of calling a single sproc. 
- Reporting / Email Alerts possible via initial addition of `dbo.verify_cpu_thresholds`. 
- Initial implementation of `dbo.verify_ple_thresholds`. 
- Initial addition of `dbo.verify_dev_configurations` - as logic to execute with SQL Server Agent jobs on a dev server - i.e., to verify SIMPLE recovery/etc. 
- Initial addition of `dbo.process_synchronization_server_start`.

## [8.5.3502] - 2021-01-15

### Changed 
- `dbo.restore_databases` now allows-for > 1 .ndf file during restore-tests and DR restores. Previous logic was limited to treating any/all .ndf files as <db_name>.ndf which didn't work.
- `dbo.restore_databases` and `dbo.apply_logs` both now use the COMPLETION time-stamp of the backup file most-recently restored INSTEAD of the time-stamp associated with the file-name itself - correcting `“The log in this backup set terminates at LSNXXXX, which is too early to apply to the database…”` errors. 
- `dbo.apply_logs` now performs additional checks BEFORE attempting to restore databases against dbs that might be already ONLINE or that haven't been set up for additional RESTORE operations (i.e., it's been made more user-friendly).
- Major overhaul of post-restore cleanup logic in dbo.restore_databases for scenarios where @DropDatabasesAfterRestore is true. New logic queries dbo.restore_log against source db-name, restored (target) db-name, execution id, AND the timestamp of the target db's creation to ensure that S4 is ONLY dropping dbs created during restore tests, then uses more-aggressive techniques to force/ensure that target dbs are dropped. 

### Fixed
- Corrected bug in `dbo.restore_databases` that assumed that database files (mdf, ldf, ndf) would ALWAYS be in format of `<db_name>.<ext>`. This older oversight (leaning too heavily upon convention) could/would result in attempts to restore test/'copy' database files 'over the top' of production files (which would obviously fail) because file-name creation logic for non-DR restores would be a simple question of REPLACE() against source db-name to 'new' db-name (which won't work on a DB named, say, `Widgets` if the mdf for said database is `Gears.mdf` and so on).
- Removed last vestiges of `xp_deletefile` (found in `dbo.remove_backup_files`) - which should prevent problems with leaked file-handles causing 'lock ups' against Windows directories (for backup files).
- Bug-Fixes to problems with error, warning, and status/output reporting in `dbo.apply_logs`.



## [8.4.3491] - 2021-01-04  

### Added  
- Added processing to add new Job-Step for Regular History Cleanup (via `dbo.manage_server_history`) to address cleanup of stale/orphaned SQL Server Agent job histories via call to `dbo.clear_stale_jobsactivity` (added v8.3).


### Fixed  
- Invalid `@Mode` value (OUTPUT vs LIST) specified in `dbo.remove_backup_files` - causing problems with cleanup of backups on v8.3.
- Corrected bug with apostrophe in SQL Server Login-names causing problems with IF EXISTS checks in `dbo.script_login` (and associated sprocs) via changes to formatting UDFs.


## [8.3.3479] - 2020-12-23

### Added 
- Initial addition of XE (log/data) transforms and views for blocked-processes and deadlocks. 
- Diagnostic query in the form of `extract_code_lines` which will extract the line (and surrounding lines) of code from a sproc/udf/trigger throwing errors (i.e., if when an error says something like "xyz error - line 345 of sproc N", you can punch in that line-number and the name of sproc (N) and see the exact lines of code as they exist on the server (vs trying to guess based on scripting of object and/or any scripts you might have).)

### Changed 
- `load_backup_files` no longer uses `xp_deletfile` anymore. This sproc is/was undocumented and consistently ran into problems if/when backup files were 0 byte or had other formatting errors preventing them from being legit backup files. (Which, obviously, is/was a problem and was (or should be) detected by regular restore tests - but then, a few days later, if/when there was an issue, 'cleanup' would throw additional errors.). 
- AlwaysOn_health XE is now enabled + configured for auto-start whenever `add_synchronization_partner` is run (i.e., if we're going to be running HA configs, makes sense to ensure these diagnostics are running). 

### Fixed 
- Bugfix/correction of RPO warnings and math/calculations within `dbo.restore_databases` - to provide better insight into SLA violations during restore-tests.
- `list_nonaccessible_databases` correctly added to S4 build (was missing from previous build file). 
- `list_nonaccessible_databases`, and configuration/setup helpers in the form of `manage_server_history`, and `create_xxx_jobs`-type sprocs have been back-ported to work with SQL Server 2008, 2008R2, 2012, and 2014 instances.


## [8.2.3410.1] - 2020-10-15

### Added
- Initial implementation of 'wrapper' logic to handle creation, backup, and restore of server-level (backup encryption, TDE, etc.) certificates.

### Changed
- File-Path normalization has now been abstracted into `dbo.normalize_file_path` (primarily for 'internal' use - to avoid DRY violations).
- Minor modifications to migration templates/script-generation.

### Fixed  
- Corrected problem with sporadic errors in automated log-shrink operations.
- Bug-fix to enable > 1 .ndf file during restore via `dbo.restore_databases`
### Secured.
- Miscellaneous fixes to address case-sensitive instances.
- Bug-fixes to `dbo.print_long_string` to help with scenarios where scripting/dumping 10s of thousands of logins via `dbo.script_logins`.
- Corrected issues with state-management and reporting within `dbo.apply_logs`. 


## [8.1.3282.1] - 2020-06-08

### Added 
- Source/Target migration-generation templates for moving and/or upgrading SQL Server databases.
- Capacitity Planning Analysis/Reporting sprocs: `dbo.report_io_percent_of_percent_load` and `dbo.report_cpu_percent_of_percent_load` - providing extrapolated usage/planning metrics.
- Linguist Directives - to 'point' github at using T-SQL as repo language (instead of MySQL).


### Fixed 
- Cleaned-up/Fixed documentation links. 
- Bug with IO metrics analysis/calculations (Capacity Planning).
- Bug in `dbo.export_server_configuration` - update to internal/source naming calls. 
- MAJOR fix to `dbo.script_logins` - to address problems with servers having > 10K logins hitting 'buffer' overloads (and `PRINT`ing blank output).
- Bug-Fixes for dbo.restore_databases - to address databases with underscores in names and other problems.

### Changed
- Additional cleanup/re-organization of Utilities vs Tools + migration of some more commonly-used 'utility-like' routines into Common/Internal.


## [8.0.3247.1] - 2020-05-05

### Added 
- Disaster Recovery Documentation (Best Practices for DR with S4).
- **Initial** introduction of `dbo.help_index` (extremely weak/place-holder only) and `dbo.list_index_metrics` (aggregation bug/issue with leaf-level nodes of IXes causing 'duplicates'). - Addition of `dbo.update_server_name`;
- Initial addition of a changelog (this piglet). 

### Changed
- **Full Rewrite of Documentation.**
- Build Output - latest version of S4 will now always be `admindb_latest.sql` - though a `<version.marker.build>.marker.md` file will also always be output to `\Deployment` directory to provide 'at a glance' insight into latest version. 

### Fixed 
- Bug-Fix for `@Retention` of `1b[ackup(s)]` (corrected parsing error).
- Minor configuration bug in `dbo.create_index_maintenance_job`s.


## [7.9.3208.1] - 2020-03-27

### Added
- Initial introduction of `dbo.configure_tempdb` for IaC configurations - along with internal helpers for REMOVAL of 'surplus' tempdb data files. 
- Addition of `dbo.refresh_code` as simplified 'wrapper' for executing 'all' against `sp_refreshview` and `sp_refreshsqlmodule`. 

### Changed
- `dbo.create_sync_check_jobs` now creates all sync-check jobs as `Disabled`. 

### Fixed
- `dbo.configure_instance` now includes` @OptimizeForAdHocWorkloads` (vs requiring an additional/'manual' call to sp_configure).
- Fixed issue with `dbo.create_backup_jobs` creating DIFF jobs for FULL backups. 