﻿![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

# Change Log
  
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