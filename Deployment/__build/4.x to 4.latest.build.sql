--##OUTPUT: ..\Updates

/*

	UPDATES 
		(List of specific/disting 'updates' or 'patches' defined in this script):
		- 4.2.0.16786. Rollup of multiple 4.1 and 4.1.x changes - includding initial addition of monitoring scripts and upgrades/changes to backup removal processes to address bugs with 'synchronized' host servers and system databases, etc. 


	CHANGELOG:
		(List of all changes since 4.0). 

		- 4.1.0.16761. BugFix: Optimizing logic in dbo.[remove_backups] to account for mirrored and AG'd backups of system databases (i.e., server-name in backup path). 
		- 4.1.0.16763. Updating documentation for dbo.backup_databases. Integrating @ServerNameInSystemBackupPath into [backup_databases].
		- 4.1.0.16764. Integrated file-removal for mirrored servers/hosts into change and deployment scripts. 
		- 4.1.1.16773. Modifying + testing load_database_names and backup_databases to be able to ignore HADR checks if/when server version < 11.0. 
		- 4.1.1.16780. High-level planning and specifications planning for additional code/sproc to test RPOs and 'staleness' of restored (or non-restored) data as part of regular restore test outcomes. 
		- 4.1.2.16785. Hours writing and testing query to provide 'lambda' query capabilities for testing both restore-test validation (data-stale/fresh concerns) and RPOs (as well as RTOs) under smoke and rubble testing scenarios. 
		- 4.2.0.16786. Initial addition of monitoring scripts (verify_backup_execution and verify_database_activity) + rollup of changes. 
		---> ROLLUP: 4.2.0.16786.
		- 4.x.x.x. etc... 



	NOTES:
		- It's effectively impossible to 'intelligently' process changes in the script below (via T-SQL 'as is'). Because, if we, say a) check for @version = suchAndSuch and if it's not found, then try to run a bunch of code... 
			then that CODE will be a bunch of IF/ELSE statements that create/drop sprocs UDFs and the likes and... ultimately which have gobs of their own logic in place. In other words we can't say: 
					IF @something = true BEGIN
							IF OBJECT_ID('Something') IS NOT NULL 
								DROP Something;
							GO 

							CREATE PROC 
								@here
							AS 
								lots of complex 
								logic
								and branching 

							and the likes

								RETURN;
							GO
					END; -- end the IF... 

			To get around that, the only REAL option is... object drop/create statements would have to be wrapped in 'ticks' and run via sp_executesql... which... sucks. 


			So. intead, this script/approach takes a hybrid approach that'll have to work until... it no longer works. Which is: 
				- check for and push any DML and or even SOME DDL (modifications to tables and such) changes within IF blocks per each rollup/release defined. 
				- Add meta-data to the version_history table about any changes. 
				- bundle up ALL scripts/changes since 4.0 until the LATEST version of the code and... put those at the 'bottom' of this script. 
					(which means that the idea/approach here is: a) drop/recreate ALL objects to the VERY latest version and b) 'iterate' over each major rollup/update and push and meta-data about said rollup into the history ALL while having a 'chance' to push any 
						DDL changes and such that would be dependent on each rollup/release. 

*/


USE [master];
GO

-- 4.2.0.16786
IF OBJECT_ID('dba_VerifyBackupExecution', 'P') IS NOT NULL BEGIN
	-- 
	PRINT 'Older version of dba_VerifyBackupExecution found. Check for jobs to replace/update... '
	DROP PROC dbo.dba_VerifyBackupExecution;
END;

-- 4.4.1.16836
-- cleanup of any previous/older system objects in the master database:
--IF OBJECT_ID('dbo.dba_traceflags','U') IS NOT NULL
--	DROP TABLE dbo.dba_traceflags;
--GO


USE [admindb];
GO

----------------------------------------------------------------------------------------
-- Latest Rollup/Version:
DECLARE @targetVersion varchar(20) = '4.6.5.16870';
IF NOT EXISTS(SELECT NULL FROM dbo.version_history WHERE version_number = @targetVersion) BEGIN
	
	PRINT N'Deploying v' + @targetVersion + N' Updates.... ';

	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@targetVersion, 'Update. Job-sync, Server-sync, and data-sync checks completed.', GETDATE());

END;


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Deploy latest code / code updates:

---------------------------------------------------------------------------
-- Common Code:
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: Common\check_paths.sql

-----------------------------------
--##INCLUDE: Common\execute_uncatchable_command.sql

-----------------------------------
--##INCLUDE: Common\load_database_names.sql

-----------------------------------
--##INCLUDE: Common\split_string.sql

-----------------------------------
--##INCLUDE: Common\load_default_path.sql


---------------------------------------------------------------------------
-- Backups:
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Backups\Utilities\remove_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Backups\backup_databases.sql


---------------------------------------------------------------------------
-- Restores:
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Restore\restore_databases.sql

-----------------------------------
--##INCLUDE: S4 Restore\Tools\copy_database.sql

---------------------------------------------------------------------------
--- Monitoring
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_backup_execution.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\verify_database_configurations.sql


---------------------------------------------------------------------------
-- Monitoring (HA):
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\is_primary_database.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\job_synchronization_checks.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\respond_to_db_failover.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\server_synchronization_checks.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\server_trace_flags.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\verify_job_states.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\compare_jobs.sql

-----------------------------------
--##INCLUDE: S4 Monitoring\High Availability\data_synchronization_checks.sql

---------------------------------------------------------------------------
-- Display Versioning info:
SELECT * FROM dbo.version_history;
GO
