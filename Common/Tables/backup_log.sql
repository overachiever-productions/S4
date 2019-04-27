/*

	NOTES:
		- Each time dbo.backup_database is run, if there are any errors or problems, they'll be logged into this table. 
            Otherwise, if @LogSuccessfulOutcomes = 1, then it'll also log details for successful operations as well. 
                (But the default is to NOT log info on successful backups.) 
        
        - Each execution of dbo.backup_databases will defined an execution_id (GUID) to make it more obvious which iteration/generation
            related operations were handled in... 

*/

USE [admindb];
GO

-- {copyright}

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

---------------------------------------------------------------------------
-- Copy previous log data (v3 and below) if this is a new v4 install. 
---------------------------------------------------------------------------

DECLARE @objectId int;
SELECT @objectId = [object_id] FROM master.sys.objects WHERE [name] = N'dba_DatabaseBackups_Log';

IF @objectId IS NOT NULL BEGIN 
		
	DECLARE @loadSQL nvarchar(MAX) = N'
    SELECT 
		BackupId,
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
        CopyDetails,
		0,     --FailedCopyAttempts,
        ErrorDetails
	FROM 
		master.dbo.dba_DatabaseBackups_Log
	WHERE 
		BackupId NOT IN (SELECT backup_id FROM dbo.backup_log); ';


	SET IDENTITY_INSERT dbo.backup_log ON;

	    INSERT INTO dbo.backup_log (backup_id, execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, verification_start,  
		    verification_end, verification_succeeded, copy_details, failed_copy_attempts, error_details)
	    EXEC sp_executesql @loadSQL;

	SET IDENTITY_INSERT dbo.backup_log OFF;
END;