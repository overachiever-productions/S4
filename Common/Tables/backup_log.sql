
/*
	
	DEPENDENCIES:
		- None. 

	NOTES:
		- Each time dbo.dba_BackupDatabases is run, it creates a new 'ExecutionId' (i.e., a GUID) to 'mark' all operations that happen
			within the same execution. (Granted, time-stamps could be used to more or less figure this out, but the ExecutionId was
			designed to make this more obvious and easier to figure out. 

	KNOWN ISSUES:
		- None. 

	CAVEATS:
		- As currently defined, this script will DROP dbo.dba_DatabaseBackups_Log IF it already exists. 


	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple

*/


USE [admindb];
GO

-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

IF OBJECT_ID('dbo.backup_log','U') IS NULL BEGIN
	CREATE TABLE dbo.backup_log  (
		backup_id int IDENTITY(1,1) NOT NULL,
		execution_id uniqueidentifier NOT NULL,
		backup_date date NOT NULL CONSTRAINT DF_backup_log_log_date DEFAULT (GETDATE()),
		[database] sysname NOT NULL, 
		backup_type sysname NOT NULL,
		backup_path nvarchar(1000) NOT NULL, 
		copy_path nvarchar(1000) NULL, 
		backup_start datetime NOT NULL, 
		backup_end datetime NULL, 
		backup_succeeded bit NOT NULL CONSTRAINT DF_backup_log_backup_succeeded DEFAULT (0), 
		verification_start datetime NULL, 
		verification_end datetime NULL, 
		verification_succeeded bit NULL, 
		copy_succeeded bit NULL, 
		copy_seconds int NULL, 
		failed_copy_attempts int NULL, 
		copy_details nvarchar(MAX) NULL,
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_backup_log PRIMARY KEY CLUSTERED (backup_id)
	);	
END;