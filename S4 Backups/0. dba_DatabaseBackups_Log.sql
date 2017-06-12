
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



USE master;
GO


IF OBJECT_ID('dbo.dba_DatabaseBackups_Log','U') IS NOT NULL
	DROP TABLE dbo.dba_DatabaseBackups_Log;
GO

-- Version 3.3.0.16581
-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

CREATE TABLE dbo.dba_DatabaseBackups_Log  (
	BackupId int IDENTITY(1,1) NOT NULL,
	ExecutionId uniqueidentifier NOT NULL,
	BackupDate date NOT NULL CONSTRAINT DF_dba_DatabaseBackups_Log_Date DEFAULT (GETDATE()),
	[Database] sysname NOT NULL, 
	BackupType sysname NOT NULL,
	BackupPath nvarchar(1000) NOT NULL, 
	CopyToPath nvarchar(1000) NULL, 
	BackupStart datetime NOT NULL, 
	BackupEnd datetime NULL, 
	BackupSucceeded bit NOT NULL CONSTRAINT DF_dba_DatabaseBackups_Log_BackupSucceeded DEFAULT (0), 
	VerificationCheckStart datetime NULL, 
	VerificationCheckEnd datetime NULL, 
	VerificationCheckSucceeded bit NULL, 
	CopyDetails nvarchar(300) NULL, 
	ErrorDetails nvarchar(MAX) NULL, 
	CONSTRAINT PK_dba_DatabaseBackups_Log PRIMARY KEY CLUSTERED (BackupId)
);
GO