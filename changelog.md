![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

# Change Log

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