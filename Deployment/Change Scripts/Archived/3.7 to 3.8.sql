

/*

	Primary Changes: 
		- Schema Changes to dba_DatabaseBackups_Log to account for resiliency with backups. 
		- Modifications to dba_BackupDatabases to add resiliency and RETRY logic with @CopyTo operations. 



*/



-----------------------------------------------------------------------------------------------------------
-- BackupsLog:
-----------------------------------------------------------------------------------------------------------

USE [master];
GO

IF OBJECT_ID('dbo.dba_DatabaseBackups_Log','U') IS NOT NULL BEGIN

	DECLARE @version sysname; 
	SELECT @version = CAST([value] AS sysname) FROM sys.extended_properties WHERE major_id = OBJECT_ID('dbo.dba_DatabaseBackups_Log') AND [name] = 'Version';

	DECLARE @targetVersion sysname = N'3.8.3.16708';

	IF @version IS NULL BEGIN
		-- make sure any previously named/defined objects that should have been removed/nuked are gone: 
		IF OBJECT_ID('dbo.dba_DatabaseRestore_CheckPaths','P') IS NOT NULL
			DROP PROC dbo.dba_DatabaseRestore_CheckPaths;

		-- bind meta-data:
		EXEC sys.sp_addextendedproperty
			@name = 'Version',
			@value = @targetVersion,
			@level0type = 'Schema',
			@level0name = 'dbo',
			@level1type = 'Table',
			@level1name = 'dba_DatabaseBackups_Log';
			
	  END;
	ELSE BEGIN
		
		-- Execute changes to bring this table into line with new schema:
		BEGIN TRAN;

			SELECT * 
			INTO #DatabasesBackup_Log
			FROM dbo.dba_DatabaseBackups_Log;

			DROP TABLE dbo.dba_DatabaseBackups_Log;
		
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
				CopySucceeded bit NULL, 
				CopySeconds int NULL, 
				FailedCopyAttempts int NULL, 
				CopyDetails nvarchar(MAX) NULL,
				ErrorDetails nvarchar(MAX) NULL, 
				CONSTRAINT PK_dba_DatabaseBackups_Log PRIMARY KEY CLUSTERED (BackupId)
			);

			SET IDENTITY_INSERT dbo.dba_DatabaseBackups_Log ON;
			INSERT INTO dbo.dba_DatabaseBackups_Log (ExecutionId, BackupDate, [Database], BackupType, BackupPath, CopyToPath, BackupStart, BackupEnd, BackupSucceeded, VerificationCheckStart, VerificationCheckEnd, 
				VerificationCheckSucceeded, CopySucceeded, CopySeconds, FailedCopyAttempts, ErrorDetails)
			SELECT 
				ExecutionId, 
				BackupDate, 
				[Database],
				BackupType, 
				BackupPath, 
				CopyToPath, 
				BackupStart, 
				BackupEnd, 
				BackupSucceeded, 
				VerificationCheckStart, 
				VerificationCheckEnd, 
				VerificationCheckSucceeded, 
				CASE WHEN CopyDetails LIKE '%SUCCESS.' THEN 1 ELSE 0 END CopySucceeded, 
				DATEDIFF(SECOND, CAST((SUBSTRING(CopyDetails, 13, 19)) as datetime), CAST((SUBSTRING(CopyDetails, 49, 19)) as datetime)),
				0 FailedCopyAttempts, 
				ErrorDetails
			FROM 
				#DatabasesBackup_Log;

			SET IDENTITY_INSERT dbo.dba_DatabaseBackups_Log OFF;

			DROP TABLE #DatabasesBackup_Log;


		COMMIT;  

		-- update the property etc:
		IF @version != @targetVersion BEGIN;
			
			EXEC sys.sp_dropextendedproperty
			    @name = 'Version',
			    @level0type = 'Schema',
			    @level0name = 'dbo',
			    @level1type = 'Table',
			    @level1name = 'dba_DatabaseBackups_Log';

			EXEC sys.sp_addextendedproperty
			    @name = 'Version',
			    @value = @targetVersion,
			    @level0type = 'Schema',
			    @level0name = 'dbo',
			    @level1type = 'Table',
			    @level1name = 'dba_DatabaseBackups_Log';

				-- do anything else needed... 

		END;

		-- do anything that needs to be done in here... 
	END;

  END;
ELSE BEGIN

	-- create and bind meta-data: 
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
		CopySucceeded bit NULL, 
		CopySeconds int NULL, 
		FailedCopyAttempts int NULL, 
		CopyDetails nvarchar(MAX) NULL,
		ErrorDetails nvarchar(MAX) NULL, 
		CONSTRAINT PK_dba_DatabaseBackups_Log PRIMARY KEY CLUSTERED (BackupId)
	);

	EXEC sys.sp_addextendedproperty
		@name = 'Version',
		@value = @targetVersion,
		@level0type = 'Schema',
		@level0name = 'dbo',
		@level1type = 'Table',
		@level1name = 'dba_DatabaseBackups_Log';

	PRINT 'TABLE dbo.dba_DatabaseBackups_Log Created';

END;

GO



-- Sprocs to Add / Update (i.e., once I'm done with all changes):

-- dba_LoadDatabases
-- dba_SplitString (UDF)
-- db_BackupDatabases

