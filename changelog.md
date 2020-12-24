![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

# Change Log

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