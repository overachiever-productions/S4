--##OUTPUT: \\Deployment\Updates

/*

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


USE [admindb];
GO

----------------------------------------------------------------------------------------
-- Latest Rollup/Version:
DECLARE @targetVersion varchar(20) = '4.7.0.16942';
IF NOT EXISTS(SELECT NULL FROM dbo.version_history WHERE version_number = @targetVersion) BEGIN
	
	PRINT N'Deploying v' + @targetVersion + N' Updates.... ';

	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@targetVersion, 'Update. Dynamic retrieval of backup files during restore operations.', GETDATE());

	-- confirm that restored_files is present: 
	IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.restore_log') AND [name] = N'restored_files') BEGIN

		BEGIN TRANSACTION
			ALTER TABLE dbo.restore_log
				DROP CONSTRAINT DF_restore_log_test_date;

			ALTER TABLE dbo.restore_log
				DROP CONSTRAINT DF_restore_log_restore_succeeded;
			
			ALTER TABLE dbo.restore_log
				DROP CONSTRAINT DF_restore_log_dropped;
			
			CREATE TABLE dbo.Tmp_restore_log
				(
				restore_test_id int NOT NULL IDENTITY (1, 1),
				execution_id uniqueidentifier NOT NULL,
				test_date date NOT NULL,
				[database] sysname NOT NULL,
				restored_as sysname NOT NULL,
				restore_start datetime NOT NULL,
				restore_end datetime NULL,
				restore_succeeded bit NOT NULL,
				restored_files xml NULL,
				consistency_start datetime NULL,
				consistency_end datetime NULL,
				consistency_succeeded bit NULL,
				dropped varchar(20) NOT NULL,
				error_details nvarchar(MAX) NULL
				)  ON [PRIMARY];
			
			ALTER TABLE dbo.Tmp_restore_log ADD CONSTRAINT
				DF_restore_log_test_date DEFAULT (getdate()) FOR test_date;
			
			ALTER TABLE dbo.Tmp_restore_log ADD CONSTRAINT
				DF_restore_log_restore_succeeded DEFAULT ((0)) FOR restore_succeeded;
			
			ALTER TABLE dbo.Tmp_restore_log ADD CONSTRAINT
				DF_restore_log_dropped DEFAULT ('NOT-DROPPED') FOR dropped;
			
			SET IDENTITY_INSERT dbo.Tmp_restore_log ON;
			
				 EXEC('INSERT INTO dbo.Tmp_restore_log (restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details)
					SELECT restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details FROM dbo.restore_log WITH (HOLDLOCK TABLOCKX)')
			
			SET IDENTITY_INSERT dbo.Tmp_restore_log OFF;
			
			DROP TABLE dbo.restore_log;
			
			EXECUTE sp_rename N'dbo.Tmp_restore_log', N'restore_log', 'OBJECT' ;
			
			ALTER TABLE dbo.restore_log ADD CONSTRAINT
				PK_restore_log PRIMARY KEY CLUSTERED 
				(
				restore_test_id
				) WITH( STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY];

			
		COMMIT;

	END;


	-- execute UTC to local conversion:
	DECLARE @currentVersion decimal(2,1); 
	SELECT @currentVersion = MAX(CAST(LEFT(version_number, 3) AS decimal(2,1))) FROM [dbo].[version_history];

	IF @currentVersion < 4.7 BEGIN 
		PRINT 'doing';

	END;

END;


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Deploy latest code / code updates:


---------------------------------------------------------------------------
-- Common Code:
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: Common\get_engine_version.sql

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

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\print_logins.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\script_server_logins.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\print_configuration.sql

-----------------------------------
--##INCLUDE: S4 Backups\Configuration\script_server_configuration.sql


---------------------------------------------------------------------------
-- Restores:
---------------------------------------------------------------------------

-----------------------------------
--##INCLUDE: S4 Restore\restore_databases.sql

-----------------------------------
--##INCLUDE: S4 Restore\Tools\copy_database.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_backup_files.sql

-----------------------------------
--##INCLUDE: S4 Restore\Utilities\load_header_details.sql

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

