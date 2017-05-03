
/*

	DEPENDENCIES 
		- None - technically. However, all code associated with dba_RestoreDatabases is heavily dependent upon the CONVENTIONS (i.e., FULL/DIFF/LOG file names)
			used/defined in dba_BackupDatabases. 

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple	

	TODO:
		- Add Extended Property with Version # so that any FUTURE changes to table can be calculated as ALTER statements vs DROP/CREATE (to preserve existing data).
				
*/

USE master;
GO

IF OBJECT_ID('dbo.dba_DatabaseRestore_Log','U') IS NOT NULL
	DROP TABLE dbo.dba_DatabaseRestore_Log;
GO

	-- Version 3.0.2.16541	
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

CREATE TABLE dbo.dba_DatabaseRestore_Log  (
	RestorationTestId int IDENTITY(1,1) NOT NULL,
	ExecutionId uniqueidentifier NOT NULL,
	TestDate date NOT NULL CONSTRAINT DF_dba_DatabaseRestore_Log_Date DEFAULT (GETDATE()),
	[Database] sysname NOT NULL, 
	[RestoredAs] sysname NOT NULL, 
	RestoreStart datetime NOT NULL, 
	RestoreEnd datetime NULL, 
	RestoreSucceeded bit NOT NULL CONSTRAINT DF_dba_DatabaseRestore_Log_RestoreSucceeded DEFAULT (0), 
	ConsistencyCheckStart datetime NULL, 
	ConsistencyCheckEnd datetime NULL, 
	ConsistencyCheckSucceeded bit NULL, 
	Dropped varchar(20) NOT NULL CONSTRAINT DF_dba_DatabaseRestore_Log_Dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
	ErrorDetails nvarchar(MAX) NULL, 
	CONSTRAINT PK_dba_DatabaseRestore_Log PRIMARY KEY CLUSTERED (RestorationTestId)
);