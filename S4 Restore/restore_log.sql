
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

USE [admindb];
GO

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN

	CREATE TABLE dbo.restore_log  (
		restore_test_id int IDENTITY(1,1) NOT NULL,
		execution_id uniqueidentifier NOT NULL,
		test_date date NOT NULL CONSTRAINT DF_restore_log_test_date DEFAULT (GETDATE()),
		[database] sysname NOT NULL, 
		restored_as sysname NOT NULL, 
		restore_start datetime NOT NULL, 
		restore_end datetime NULL, 
		restore_succeeded bit NOT NULL CONSTRAINT DF_restore_log_restore_succeeded DEFAULT (0), 
		consistency_start datetime NULL, 
		consistency_end datetime NULL, 
		consistency_succeeded bit NULL, 
		dropped varchar(20) NOT NULL CONSTRAINT DF_restore_log_dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_restore_log PRIMARY KEY CLUSTERED (restore_test_id)
	);

END;