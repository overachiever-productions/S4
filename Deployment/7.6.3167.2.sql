/*

	REFERENCE:
		- License, documentation, and source code at: 
			https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639

	NOTES:
		- This script will either install/deploy S4 version 7.6.3167.2 or upgrade a PREVIOUSLY deployed version of S4 to 7.6.3167.2.
		- This script will create a new, admindb, if one is not already present on the server where this code is being run.

	Deployment Steps/Overview: 
		1. Create admindb if not already present.
		2. Create core S4 tables (and/or ALTER as needed + import data from any previous versions as needed). 
		3. Cleanup any code/objects from previous versions of S4 installed and no longer needed. 
		4. Deploy S4 version 7.6.3167.2 code to admindb (overwriting any previous versions). 
		5. Report on current + any previous versions of S4 installed. 

*/

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 1. Create admindb if/as needed: 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SET NOCOUNT ON;

USE [master];
GO

IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'admindb') BEGIN
	CREATE DATABASE [admindb];  -- TODO: look at potentially defining growth size details - based upon what is going on with model/etc. 

	ALTER AUTHORIZATION ON DATABASE::[admindb] TO sa;

	ALTER DATABASE [admindb] SET RECOVERY SIMPLE;  -- i.e., treat like master/etc. 
END;
GO

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 2. Core Tables:
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [admindb];
GO

IF OBJECT_ID('version_history', 'U') IS NULL BEGIN

	CREATE TABLE dbo.version_history (
		version_id int IDENTITY(1,1) NOT NULL, 
		version_number varchar(20) NOT NULL, 
		[description] nvarchar(200) NULL, 
		deployed datetime NOT NULL CONSTRAINT DF_version_info_deployed DEFAULT GETDATE(), 
		CONSTRAINT PK_version_info PRIMARY KEY CLUSTERED (version_id)
	);

	EXEC sys.sp_addextendedproperty
		@name = 'S4',
		@value = 'TRUE',
		@level0type = 'Schema',
		@level0name = 'dbo',
		@level1type = 'Table',
		@level1name = 'version_history';
END;

DECLARE @CurrentVersion varchar(20) = N'7.6.3167.2';

-- Add previous details if any are present: 
DECLARE @version sysname; 
DECLARE @objectId int;
DECLARE @createDate datetime;
SELECT @objectId = [object_id], @createDate = create_date FROM master.sys.objects WHERE [name] = N'dba_DatabaseBackups_Log';
SELECT @version = CAST([value] AS sysname) FROM master.sys.extended_properties WHERE major_id = @objectId AND [name] = 'Version';

IF NULLIF(@version,'') IS NOT NULL BEGIN
	IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @version) BEGIN
		INSERT INTO dbo.version_history (version_number, [description], deployed)
		VALUES ( @version, N'Found during deployment of ' + @CurrentVersion + N'.', @createDate);
	END;
END;
GO

-----------------------------------
USE [admindb];
GO

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

IF OBJECT_ID('dbo.backup_log','U') IS NULL BEGIN
	CREATE TABLE dbo.backup_log  (
		backup_id int IDENTITY(1,1) NOT NULL,
		execution_id uniqueidentifier NOT NULL,
		backup_date date NOT NULL CONSTRAINT DF_backup_log_log_date DEFAULT (GETDATE()),
		[database] sysname NOT NULL, 
		backup_type sysname NOT NULL,
		backup_path nvarchar(1000) NOT NULL, 
		copy_path nvarchar(1000) NULL, 
		offsite_path nvarchar(1000) NULL,
		backup_start datetime NOT NULL, 
		backup_end datetime NULL, 
		backup_succeeded bit NOT NULL CONSTRAINT DF_backup_log_backup_succeeded DEFAULT (0), 
		verification_start datetime NULL, 
		verification_end datetime NULL, 
		verification_succeeded bit NULL, 
		copy_succeeded bit NULL, 
		copy_seconds int NULL, 
		copy_details nvarchar(MAX) NULL,
		failed_copy_attempts int NULL, 
		offsite_succeeded bit NULL, 
		offsite_seconds int NULL, 
		offsite_details nvarchar(MAX) NULL,
		failed_offsite_attempts int NULL,
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_backup_log PRIMARY KEY CLUSTERED (backup_id)
	);	
END;
GO

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
GO


---------------------------------------------------------------------------
-- v7.5+ Tracking for OffSite Copies of backups.
---------------------------------------------------------------------------
IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.backup_log') AND [name] = N'offsite_path') BEGIN 
	BEGIN TRAN;	
	
		IF OBJECT_ID('DF_backup_log_log_date') IS NOT NULL BEGIN
			ALTER TABLE dbo.backup_log
				DROP CONSTRAINT DF_backup_log_log_date;
		END;

		IF OBJECT_ID('DF_backup_log_backup_succeeded') IS NOT NULL BEGIN
			ALTER TABLE dbo.backup_log
				DROP CONSTRAINT DF_backup_log_backup_succeeded;
		END;

		CREATE TABLE dbo.Tmp_backup_log (
			backup_id int NOT NULL IDENTITY (1, 1),
			execution_id uniqueidentifier NOT NULL,
			backup_date date NOT NULL,
			[database] sysname NOT NULL,
			backup_type sysname NOT NULL,
			backup_path nvarchar(1000) NOT NULL,
			copy_path nvarchar(1000) NULL,
			offsite_path nvarchar(1000) NULL,
			backup_start datetime NOT NULL,
			backup_end datetime NULL,
			backup_succeeded bit NOT NULL,
			verification_start datetime NULL,
			verification_end datetime NULL,
			verification_succeeded bit NULL,
			copy_succeeded bit NULL,
			copy_seconds int NULL,
			failed_copy_attempts int NULL,
			copy_details nvarchar(MAX) NULL,
			offsite_succeeded bit NULL,
			offsite_seconds int NULL,
			failed_offsite_attempts int NULL,
			offsite_details nvarchar(MAX) NULL,
			error_details nvarchar(MAX) NULL
		);

		ALTER TABLE dbo.Tmp_backup_log ADD CONSTRAINT
			DF_backup_log_log_date DEFAULT (GETDATE()) FOR backup_date;

		ALTER TABLE dbo.Tmp_backup_log ADD CONSTRAINT
			DF_backup_log_backup_succeeded DEFAULT (0) FOR backup_succeeded;

		SET IDENTITY_INSERT dbo.Tmp_backup_log ON;

			INSERT INTO dbo.Tmp_backup_log (backup_id, execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, verification_start, verification_end, verification_succeeded, copy_succeeded, copy_seconds, failed_copy_attempts, copy_details, error_details)
			EXEC sp_executesql N'SELECT backup_id, execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, verification_start, verification_end, verification_succeeded, copy_succeeded, copy_seconds, failed_copy_attempts, copy_details, error_details FROM dbo.backup_log; ';

		SET IDENTITY_INSERT dbo.Tmp_backup_log OFF;

		DROP TABLE dbo.backup_log;
		
		EXECUTE sp_rename N'dbo.Tmp_backup_log', N'backup_log', 'OBJECT';

		ALTER TABLE dbo.backup_log ADD CONSTRAINT
			PK_backup_log PRIMARY KEY CLUSTERED (backup_id);

	COMMIT;
END;


-----------------------------------
USE [admindb];
GO

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

IF OBJECT_ID('dbo.restore_log', 'U') IS NULL BEGIN

	CREATE TABLE dbo.restore_log  (
		restore_id int IDENTITY(1,1) NOT NULL,                                                                      -- restore_test_id until v.9                         
		execution_id uniqueidentifier NOT NULL,                                                                     -- restore_id until v 4.9            
		operation_date date NOT NULL CONSTRAINT DF_restore_log_operation_date DEFAULT (GETDATE()),
		operation_type varchar(20) NOT NULL CONSTRAINT DF_restore_log_operation_type DEFAULT ('RESTORE-TEST'),      -- added v 4.9
		[database] sysname NOT NULL, 
		restored_as sysname NOT NULL, 
		restore_start datetime NOT NULL,                                                                            -- UTC until v 4.7
		restore_end datetime NULL,                                                                                  -- UTC until v 4.7
		restore_succeeded bit NOT NULL CONSTRAINT DF_restore_log_restore_succeeded DEFAULT (0), 
		restored_files xml NULL,                                                                                    -- added v 4.6.9
		[recovery] varchar(10) NOT NULL CONSTRAINT DF_restore_log_recovery DEFAULT ('RECOVERED'),                   -- added v 4.9
		consistency_start datetime NULL,                                                                            -- UTC until v 4.7
		consistency_end datetime NULL,                                                                              -- UTC until v 4.7
		consistency_succeeded bit NULL, 
		dropped varchar(20) NOT NULL CONSTRAINT DF_restore_log_dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
		error_details nvarchar(MAX) NULL, 
		CONSTRAINT PK_restore_log PRIMARY KEY CLUSTERED (restore_id)
	);

    -- Copy previous log data (v3 and below) if this is a new (> v4) install... 
    DECLARE @objectId int;
    SELECT @objectId = [object_id] FROM master.sys.objects WHERE [name] = 'dba_DatabaseRestore_Log';
    IF @objectId IS NOT NULL BEGIN;

        DECLARE @importSQL nvarchar(MAX) = N'
        INSERT INTO dbo.restore_log (
            restore_id, 
            execution_id, 
            operation_date, 
            [database], 
            restored_as, 
            restore_start, 
            restore_end, 
            restore_succeeded, 
		    consistency_start, 
            consistency_end, 
            consistency_succeeded, 
            dropped, 
            error_details
        )
	    SELECT 
		    RestorationTestId,
            ExecutionId,
            TestDate,
            [Database],
            RestoredAs,
            RestoreStart,
		    RestoreEnd,
            RestoreSucceeded,
            ConsistencyCheckStart,
            ConsistencyCheckEnd,
            ConsistencyCheckSucceeded,
            Dropped,
            ErrorDetails
	    FROM 
		    master.dbo.dba_DatabaseRestore_Log
	    WHERE 
		    RestorationTestId NOT IN (SELECT restore_test_id FROM dbo.restore_log); ';


	    PRINT 'Importing Previous Data from restore log.... ';
	    SET IDENTITY_INSERT dbo.restore_log ON;

            EXEC sys.[sp_executesql] @importSQL;

	    SET IDENTITY_INSERT dbo.restore_log OFF;

    END;

END;
GO

---------------------------------------------------------------------------
-- v4.6 Make sure the admindb.dbo.restore_log.restored_files column exists ... 
---------------------------------------------------------------------------
IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.restore_log') AND [name] = N'restored_files') BEGIN

	BEGIN TRANSACTION;
        
        IF OBJECT_ID(N'DF_restore_log_operation_date') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_operation_date;
        END

        IF OBJECT_ID(N'DF_restore_log_test_date') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_test_date;       -- old/former name... 
        END

        IF OBJECT_ID(N'DF_restore_log_operation_type') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_operation_type;
        END

        IF OBJECT_ID(N'DF_restore_log_restore_succeeded') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_restore_succeeded;
        END;

        IF OBJECT_ID(N'DF_restore_log_recovery') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_recovery;
        END;
		
        IF OBJECT_ID(N'DF_restore_log_dropped') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_dropped;
        END;
			
		CREATE TABLE dbo.Tmp_restore_log (
		    restore_id int IDENTITY(1,1) NOT NULL,                                                                      -- restore_test_id until v4.9                         
		    execution_id uniqueidentifier NOT NULL,                                                                     -- restore_id until v 4.9            
		    operation_date date NOT NULL CONSTRAINT DF_restore_log_operation_date DEFAULT (GETDATE()),
		    operation_type varchar(20) NOT NULL CONSTRAINT DF_restore_log_operation_type DEFAULT ('RESTORE-TEST'),      -- added v 4.9
		    [database] sysname NOT NULL, 
		    restored_as sysname NOT NULL, 
		    restore_start datetime NOT NULL,                                                                            -- UTC until v 4.7
		    restore_end datetime NULL,                                                                                  -- UTC until v 4.7
		    restore_succeeded bit NOT NULL CONSTRAINT DF_restore_log_restore_succeeded DEFAULT (0), 
		    restored_files xml NULL,                                                                                    -- added v 4.6.9
		    [recovery] varchar(10) NOT NULL CONSTRAINT DF_restore_log_recovery DEFAULT ('RECOVERED'),                   -- added v 4.9
		    consistency_start datetime NULL,                                                                            -- UTC until v 4.7
		    consistency_end datetime NULL,                                                                              -- UTC until v 4.7
		    consistency_succeeded bit NULL, 
		    dropped varchar(20) NOT NULL CONSTRAINT DF_restore_log_dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
		    error_details nvarchar(MAX) NULL, 
		);
			
		SET IDENTITY_INSERT dbo.Tmp_restore_log ON;
			
				INSERT INTO dbo.Tmp_restore_log (restore_id, execution_id, operation_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details)
                EXEC sp_executesql N'SELECT restore_test_id, execution_id, test_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details FROM dbo.restore_log;';
			
		SET IDENTITY_INSERT dbo.Tmp_restore_log OFF;
			
		DROP TABLE dbo.restore_log;
			
		EXECUTE sp_rename N'dbo.Tmp_restore_log', N'restore_log', 'OBJECT' ;
			
		ALTER TABLE dbo.restore_log ADD CONSTRAINT
			PK_restore_log PRIMARY KEY CLUSTERED (restore_id) ON [PRIMARY];
			
	COMMIT;
END;
GO

---------------------------------------------------------------------------
-- v4.7 Process UTC to local time change 
---------------------------------------------------------------------------
DECLARE @currentVersion decimal(2,1); 
SELECT @currentVersion = MAX(CAST(LEFT(version_number, 3) AS decimal(2,1))) FROM [dbo].[version_history];

IF @currentVersion IS NOT NULL AND @currentVersion < 4.7 BEGIN 

	DECLARE @hoursDiff int; 
	SELECT @hoursDiff = DATEDIFF(HOUR, GETDATE(), GETUTCDATE());

	DECLARE @command nvarchar(MAX) = N'
	UPDATE dbo.[restore_log]
	SET 
		[restore_start] = DATEADD(HOUR, 0 - @hoursDiff, [restore_start]), 
		[restore_end] = DATEADD(HOUR, 0 - @hoursDiff, [restore_end]),
		[consistency_start] = DATEADD(HOUR, 0 - @hoursDiff, [consistency_start]),
		[consistency_end] = DATEADD(HOUR, 0 - @hoursDiff, [consistency_end])
	WHERE 
		[restore_id] > 0;
	';

	EXEC sp_executesql 
		@stmt = @command, 
		@params = N'@hoursDiff int', 
		@hoursDiff = @hoursDiff;

	PRINT 'Updated dbo.restore_log.... (UTC shift)';
END;
GO

---------------------------------------------------------------------------
-- v4.9 Add recovery column + rename first two table columns:
---------------------------------------------------------------------------
IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.restore_log') AND [name] = N'recovery') BEGIN 

	BEGIN TRANSACTION;

        IF OBJECT_ID(N'DF_restore_log_operation_date') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_operation_date;
        END

        IF OBJECT_ID(N'DF_restore_log_test_date') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_test_date;       -- old/former name... 
        END

        IF OBJECT_ID(N'DF_restore_log_operation_type') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_operation_type;
        END

        IF OBJECT_ID(N'DF_restore_log_restore_succeeded') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_restore_succeeded;
        END;

        IF OBJECT_ID(N'DF_restore_log_recovery') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_recovery;
        END;
		
        IF OBJECT_ID(N'DF_restore_log_dropped') IS NOT NULL BEGIN
		    ALTER TABLE dbo.restore_log
			    DROP CONSTRAINT DF_restore_log_dropped;
        END;

		CREATE TABLE dbo.Tmp_restore_log (
		    restore_id int IDENTITY(1,1) NOT NULL,                                                                      -- restore_test_id until v.9                         
		    execution_id uniqueidentifier NOT NULL,                                                                     -- restore_id until v 4.9            
		    operation_date date NOT NULL CONSTRAINT DF_restore_log_operation_date DEFAULT (GETDATE()),
		    operation_type varchar(20) NOT NULL CONSTRAINT DF_restore_log_operation_type DEFAULT ('RESTORE-TEST'),      -- added v 4.9
		    [database] sysname NOT NULL, 
		    restored_as sysname NOT NULL, 
		    restore_start datetime NOT NULL,                                                                            -- UTC until v 4.7
		    restore_end datetime NULL,                                                                                  -- UTC until v 4.7
		    restore_succeeded bit NOT NULL CONSTRAINT DF_restore_log_restore_succeeded DEFAULT (0), 
		    restored_files xml NULL,                                                                                    -- added v 4.6.9
		    [recovery] varchar(10) NOT NULL CONSTRAINT DF_restore_log_recovery DEFAULT ('RECOVERED'),                   -- added v 4.9
		    consistency_start datetime NULL,                                                                            -- UTC until v 4.7
		    consistency_end datetime NULL,                                                                              -- UTC until v 4.7
		    consistency_succeeded bit NULL, 
		    dropped varchar(20) NOT NULL CONSTRAINT DF_restore_log_dropped DEFAULT 'NOT-DROPPED',   -- Options: NOT-DROPPED, ERROR, ATTEMPTED, DROPPED
		    error_details nvarchar(MAX) NULL, 
		);

		SET IDENTITY_INSERT dbo.Tmp_restore_log ON;
			
				INSERT INTO dbo.Tmp_restore_log (restore_id, execution_id, operation_date, [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details)
                EXEC sp_executesql N'SELECT restore_test_id [restore_id], execution_id, test_date [operation_date], [database], restored_as, restore_start, restore_end, restore_succeeded, consistency_start, consistency_end, consistency_succeeded, dropped, error_details FROM dbo.restore_log';
			
		SET IDENTITY_INSERT dbo.Tmp_restore_log OFF;
			
		DROP TABLE dbo.restore_log;
			
		EXECUTE sp_rename N'dbo.Tmp_restore_log', N'restore_log', 'OBJECT' ;

		ALTER TABLE dbo.restore_log ADD CONSTRAINT
			PK_restore_log PRIMARY KEY CLUSTERED (restore_id) ON [PRIMARY];

	COMMIT; 
END;
GO

-- v4.9 (standardize/cleanup):
UPDATE dbo.[restore_log] 
SET 
	[dropped] = 'LEFT-ONLINE'
WHERE 
	[dropped] = 'LEFT ONLINE';
GO

---------------------------------------------------------------------------
-- v5.0 - expand dbo.restore_log.[recovery]. S4-86.
---------------------------------------------------------------------------
IF EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.restore_log') AND [name] = N'recovery' AND [max_length] = 10) BEGIN
	BEGIN TRAN;

		ALTER TABLE dbo.[restore_log]
			ALTER COLUMN [recovery] varchar(15) NOT NULL; 

		ALTER TABLE dbo.[restore_log]
			DROP CONSTRAINT [DF_restore_log_recovery];

		ALTER TABLE dbo.[restore_log]
			ADD CONSTRAINT [DF_restore_log_recovery] DEFAULT ('NON-RECOVERED') FOR [recovery];

	COMMIT;
END;
GO

---------------------------------------------------------------------------
-- v6.1+
---------------------------------------------------------------------------
-- S4-195- BUG: these changes may have been missed during previous updates:
IF OBJECT_ID(N'DF_restore_log_test_date') IS NOT NULL BEGIN
	ALTER TABLE dbo.restore_log DROP CONSTRAINT DF_restore_log_test_date;
END;

IF OBJECT_ID(N'DF_restore_log_operation_date') IS NULL BEGIN 
    ALTER TABLE dbo.[restore_log] ADD CONSTRAINT DF_restore_log_operation_date DEFAULT (GETDATE()) FOR [operation_date];
END;
GO

-- streamline default text: 
IF EXISTS (SELECT NULL FROM sys.[default_constraints] WHERE [name] = N'DF_restore_log_operation_type' AND [definition] <> '(''RESTORE-TEST'')') BEGIN 
    IF OBJECT_ID(N'DF_restore_log_operation_date') IS NOT NULL BEGIN
		ALTER TABLE dbo.restore_log DROP CONSTRAINT DF_restore_log_operation_type;
    END    

    IF OBJECT_ID(N'DF_restore_log_operation_date') IS NOT NULL BEGIN
        ALTER TABLE dbo.restore_log ADD CONSTRAINT DF_restore_log_operation_type DEFAULT 'RESTORE-TEST' FOR [operation_type];

        UPDATE dbo.[restore_log] SET [operation_type] = 'RESTORE-TEST' WHERE [operation_type] = 'RESTORE_TEST';
    END;
END;
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.settings','U') IS NULL BEGIN

	CREATE TABLE dbo.settings (
		setting_id int IDENTITY(1,1) NOT NULL,
		setting_type sysname NOT NULL CONSTRAINT CK_settings_setting_type CHECK ([setting_type] IN (N'UNIQUE', N'COMBINED')),
		setting_key sysname NOT NULL, 
		setting_value sysname NOT NULL,
		comments nvarchar(200) NULL,
		CONSTRAINT PK_settings PRIMARY KEY NONCLUSTERED (setting_id)
	);

	CREATE CLUSTERED INDEX CLIX_settings ON dbo.[settings] ([setting_key], [setting_id]);
  END;
ELSE BEGIN 

	IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.settings') AND [name] = N'setting_id') BEGIN 

		BEGIN TRAN
			SELECT 
				IDENTITY(int, 1, 1) [row_id], 
				setting_key, 
				setting_value 
			INTO 
				#settings
			FROM 
				dbo.[settings];

			DROP TABLE dbo.[settings];

			CREATE TABLE dbo.settings (
				setting_id int IDENTITY(1,1) NOT NULL,
				setting_type sysname NOT NULL CONSTRAINT CK_settings_setting_type CHECK ([setting_type] IN (N'UNIQUE', N'COMBINED')),
				setting_key sysname NOT NULL, 
				setting_value sysname NOT NULL,
				comments nvarchar(200) NULL,
				CONSTRAINT PK_settings PRIMARY KEY NONCLUSTERED (setting_id)
			);

            CREATE CLUSTERED INDEX CLIX_settings ON dbo.[settings] ([setting_key], [setting_id]);

            DECLARE @insertFromOriginal nvarchar(MAX) = N'INSERT INTO dbo.settings (setting_type, setting_key, setting_value) 
			SELECT 
				N''UNIQUE'' [setting_type], 
				[setting_key], 
				[setting_value]
			FROM 
				[#settings]
			ORDER BY 
				[row_id]; ';

            EXEC sp_executesql @insertFromOriginal;
			
		COMMIT;

        IF OBJECT_ID(N'tempdb..#settings') IS NOT NULL 
            DROP TABLE [#settings];
	END;
END;
GO

-- 6.0: 'legacy enable' advanced S4 error handling from previous versions if not already defined: 
IF EXISTS (SELECT NULL FROM dbo.[version_history]) BEGIN

	IF NOT EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN
		INSERT INTO dbo.[settings] (
			[setting_type],
			[setting_key],
			[setting_value],
			[comments]
		)
		VALUES (
			N'UNIQUE', 
			N'advanced_s4_error_handling', 
			N'1', 
			N'Legacy Enabled (i.e., pre-v6 install upgraded to 6/6+)' 
		);
	END;
END;


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.alert_responses','U') IS NULL BEGIN

	CREATE TABLE dbo.alert_responses (
		alert_id int IDENTITY(1,1) NOT NULL, 
		message_id int NOT NULL, 
		response nvarchar(2000) NOT NULL, 
		is_s4_response bit NOT NULL CONSTRAINT DF_alert_responses_s4_response DEFAULT (0),
		is_enabled bit NOT NULL CONSTRAINT DF_alert_responses_is_enabled DEFAULT (1),
		notes nvarchar(1000) NULL, 
		CONSTRAINT PK_alert_responses PRIMARY KEY NONCLUSTERED ([alert_id])
	);

	CREATE CLUSTERED INDEX CLIX_alert_responses_by_message_id ON dbo.[alert_responses] ([message_id]);

	SET NOCOUNT ON;

	INSERT INTO [dbo].[alert_responses] ([message_id], [response], [is_s4_response], [notes])
	VALUES 
	(7886, N'[IGNORE]', 1, N'A read operation on a large object failed while sending data to the client. Example of a common-ish error you MAY wish to ignore, etc. '), 
	(17806, N'[IGNORE]', 1, N'SSPI handshake failure '),  -- TODO: configure for '[ALLOW # in (span)]'
	(18056, N'[IGNORE]', 1, N'The client was unable to reuse a session with SPID ###, which had been reset for connection pooling. The failure ID is 8. ');			-- TODO: configure for '[ALLOW # in (span)]'

END;
GO


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 3. Cleanup and remove objects from previous versions (start by creating/adding dbo.drop_obsolete_objects and other core 'helper' code)
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.get_engine_version','FN') IS NOT NULL
	DROP FUNCTION dbo.get_engine_version;
GO

CREATE FUNCTION dbo.get_engine_version() 
RETURNS decimal(4,2)
AS
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN 
		DECLARE @output decimal(4,2);
		
		DECLARE @major sysname, @minor sysname, @full sysname;
		SELECT 
			@major = CAST(SERVERPROPERTY('ProductMajorVersion') AS sysname), 
			@minor = CAST(SERVERPROPERTY('ProductMinorVersion') AS sysname), 
			@full = CAST(SERVERPROPERTY('ProductVersion') AS sysname); 

		IF @major IS NULL BEGIN
			SELECT @major = LEFT(@full, 2);
			SELECT @minor = REPLACE((SUBSTRING(@full, LEN(@major) + 2, 2)), N'.', N'');
		END;

		SET @output = CAST((@major + N'.' + @minor) AS decimal(4,2));

		RETURN @output;
	END;
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.split_string','TF') IS NOT NULL
	DROP FUNCTION dbo.split_string;
GO

CREATE FUNCTION dbo.split_string(@serialized nvarchar(MAX), @delimiter nvarchar(20), @TrimResults bit)
RETURNS @Results TABLE (row_id int IDENTITY NOT NULL, result nvarchar(MAX))
	--WITH SCHEMABINDING
AS 
	BEGIN

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	IF NULLIF(@serialized,'') IS NOT NULL AND DATALENGTH(@delimiter) >= 1 BEGIN
		IF @delimiter = N' ' BEGIN 
			-- this approach is going to be MUCH slower, but works for space delimiter... 
			DECLARE @p int; 
			DECLARE @s nvarchar(MAX);
			WHILE CHARINDEX(N' ', @serialized) > 0 BEGIN 
				SET @p = CHARINDEX(N' ', @serialized);
				SET @s = SUBSTRING(@serialized, 1, @p - 1); 
			
				INSERT INTO @Results ([result])
				VALUES(@s);

				SELECT @serialized = SUBSTRING(@serialized, @p + 1, LEN(@serialized) - @p);
			END;
			
			INSERT INTO @Results ([result])
			VALUES (@serialized);

		  END; 
		ELSE BEGIN

			DECLARE @MaxLength int = LEN(@serialized) + LEN(@delimiter);

			WITH tally (n) AS ( 
				SELECT TOP (@MaxLength) 
					ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
				FROM sys.all_objects o1 
				CROSS JOIN sys.all_objects o2
			)

			INSERT INTO @Results ([result])
			SELECT 
				SUBSTRING(@serialized, n, CHARINDEX(@delimiter, @serialized + @delimiter, n) - n) [result]
			FROM 
				tally 
			WHERE 
				n <= LEN(@serialized) AND
				LEN(@delimiter) <= LEN(@serialized) AND
				RTRIM(LTRIM(SUBSTRING(@delimiter + @serialized, n, LEN(@delimiter)))) = @delimiter
			ORDER BY 
				 n;
		END;

		IF @TrimResults = 1 BEGIN
			UPDATE @Results SET [result] = LTRIM(RTRIM([result])) WHERE DATALENGTH([result]) > 0;
		END;

	END;

	RETURN;
END

GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.get_s4_version','FN') IS NOT NULL
	DROP FUNCTION dbo.[get_s4_version];
GO

CREATE FUNCTION dbo.[get_s4_version](@DefaultValueIfNoHistoryPresent varchar(20))
RETURNS decimal(3,1)
AS
    
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
    BEGIN; 
    	
		DECLARE @output decimal(3,1); 
		DECLARE @currentVersion varchar(20);

		SELECT 
			@currentVersion = [version_number] 
		FROM 
			dbo.[version_history] 
		WHERE 
			version_id = (SELECT TOP 1 [version_id] FROM dbo.[version_history] ORDER BY [version_id] DESC);

		IF @currentVersion IS NULL 
			SET @currentVersion = @DefaultValueIfNoHistoryPresent;
			
		DECLARE @majorMinor varchar(10) = N'';
		SELECT @majorMinor = @majorMinor + [result] + CASE WHEN [row_id] = 1 THEN N'.' ELSE '' END FROM dbo.[split_string](@currentVersion, N'.', 1) WHERE [row_id] < 3 ORDER BY [row_id];

		SET @output = CAST(@majorMinor AS decimal(3,1));

    	RETURN @output;
    END;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.drop_obsolete_objects','P') IS NOT NULL
	DROP PROC dbo.drop_obsolete_objects;
GO

CREATE PROC dbo.drop_obsolete_objects
    @Directives         xml             = NULL, 
    @TargetDatabae      sysname         = NULL,
    @PrintOnly          bit             = 0
AS 
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    IF @Directives IS NULL BEGIN 
        PRINT '-- Attempt to execute dbo.drop_obsolete_objects - but @Directives was NULL.';
        RETURN -1;
    END; 

    DECLARE @typeMappings table ( 
        [type] sysname, 
        [type_description] sysname 
    ); 

    INSERT INTO @typeMappings (
        [type],
        [type_description]
    )
    VALUES
        ('U', 'TABLE'),
        ('V', 'VIEW'),
        ('P', 'PROCEDURE'),
        ('FN', 'FUNCTION'),
        ('IF', 'FUNCTION'),
        ('TF', 'FUNCTION'),
        ('D', 'CONSTRAINT'),
        ('SN', 'SYNONYM');

    DECLARE @command nvarchar(MAX) = N'';
    DECLARE @current nvarchar(MAX);
    DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
    DECLARE @tab nchar(1) = NCHAR(9);

    DECLARE walker CURSOR LOCAL FAST_FORWARD FOR
    SELECT 
        ISNULL([data].[entry].value('@schema[1]', 'sysname'), N'dbo') [schema],
        [data].[entry].value('@name[1]', 'sysname') [object_name],
        UPPER([data].[entry].value('@type[1]', 'sysname')) [type],
        [data].[entry].value('@comment[1]', 'sysname') [comment], 
        [data].[entry].value('(check/statement/.)[1]', 'nvarchar(MAX)') [statement], 
        [data].[entry].value('(check/warning/.)[1]', 'nvarchar(MAX)') [warning], 
        [data].[entry].value('(notification/content/.)[1]', 'nvarchar(MAX)') [content], 
        [data].[entry].value('(notification/heading/.)[1]', 'nvarchar(MAX)') [heading] 

    FROM 
        @Directives.nodes('//entry') [data] ([entry]);

    DECLARE @template nvarchar(MAX) = N'
{comment}IF OBJECT_ID(''{schema}.{object}'', ''{type}'') IS NOT NULL {BEGIN}
    DROP {object_type_description} [{schema}].[{object}]; {StatementCheck} {Notification}{END}';

    DECLARE @checkTemplate nvarchar(MAX) = @crlf + @crlf + @tab + N'IF EXISTS ({statement})
        PRINT ''{warning}''; ';
    DECLARE @notificationTemplate nvarchar(MAX) = @crlf + @crlf + @tab + N'SELECT ''{content}}'' AS [{heading}];';

    DECLARE @schema sysname, @object sysname, @type sysname, @comment sysname, 
        @statement nvarchar(MAX), @warning nvarchar(MAX), @content nvarchar(200), @heading nvarchar(200);

    DECLARE @typeType sysname;
    DECLARE @returnValue int;

    OPEN [walker];
    FETCH NEXT FROM [walker] INTO @schema, @object, @type, @comment, @statement, @warning, @content, @heading;

    WHILE @@FETCH_STATUS = 0 BEGIN
    
        SET @typeType = (SELECT [type_description] FROM @typeMappings WHERE [type] = @type);

        IF NULLIF(@typeType, N'') IS NULL BEGIN 
            RAISERROR(N'Undefined OBJECT_TYPE slated for DROP/REMOVAL in dbo.drop_obsolete_objects.', 16, 1);
            SET @returnValue = -1;

            GOTO Cleanup;
        END;
        
        IF NULLIF(@object, N'') IS NULL OR NULLIF(@type, N'') IS NULL BEGIN
            RAISERROR(N'Error in dbo.drop_obsolete_objects. Attributes name and type are BOTH required.', 16, 1);
            SET @returnValue = -5;
            
            GOTO Cleanup;
        END;

        SET @current = REPLACE(@template, N'{schema}', @schema);
        SET @current = REPLACE(@current, N'{object}', @object);
        SET @current = REPLACE(@current, N'{type}', @type);
        SET @current = REPLACE(@current, N'{object_type_description}', @typeType);

        IF NULLIF(@comment, N'') IS NOT NULL BEGIN 
            SET @current = REPLACE(@current, N'{comment}', N'-- ' + @comment + @crlf);
          END;
        ELSE BEGIN 
            SET @current = REPLACE(@current, N'{comment}', N'');
        END;

        DECLARE @beginEndRequired bit = 0;

        IF NULLIF(@statement, N'') IS NOT NULL BEGIN
            SET @beginEndRequired = 1;
            SET @current = REPLACE(@current, N'{StatementCheck}', REPLACE(REPLACE(@checkTemplate, N'{statement}', @statement), N'{warning}', @warning));
          END;
        ELSE BEGIN 
            SET @current = REPLACE(@current, N'{StatementCheck}', N'');
        END; 

        IF (NULLIF(@content, N'') IS NOT NULL) AND (NULLIF(@heading, N'') IS NOT NULL) BEGIN
            SET @beginEndRequired = 1;
            SET @current = REPLACE(@current, N'{Notification}', REPLACE(REPLACE(@notificationTemplate, N'{content}', @content), N'{heading}', @heading));
          END;
        ELSE BEGIN
            SET @current = REPLACE(@current, N'{Notification}', N'');
        END;

        IF @beginEndRequired = 1 BEGIN 
            SET @current = REPLACE(@current, N'{BEGIN}', N'BEGIN');
            SET @current = REPLACE(@current, N'{END}', @crlf + N'END;');
          END;
        ELSE BEGIN 
            SET @current = REPLACE(@current, N'{BEGIN}', N'');
            SET @current = REPLACE(@current, N'{END}', N'');
        END; 

        SET @command = @command + @current + @crlf;

        FETCH NEXT FROM [walker] INTO @schema, @object, @type, @comment, @statement, @warning, @content, @heading;
    END;

Cleanup:
    CLOSE [walker];
    DEALLOCATE [walker];

    IF @returnValue IS NOT NULL BEGIN 
        RETURN @returnValue;
    END;

    IF NULLIF(@TargetDatabae, N'') IS NOT NULL BEGIN 
        SET @command = N'USE ' + QUOTENAME(@TargetDatabae) + N';' + @crlf + N'' + @command;
    END;

    IF @PrintOnly = 1
        PRINT @command;
    ELSE 
        EXEC sys.[sp_executesql] @command; -- by design: let it throw errors... 

    RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- master db objects:
------------------------------------------------------------------------------------------------------------------------------------------------------

DECLARE @obsoleteObjects xml = CONVERT(xml, N'
<list>
    <entry schema="dbo" name="dba_DatabaseBackups_Log" type="U" comment="older table" />
    <entry schema="dbo" name="dba_DatabaseRestore_Log" type="U" comment="older table" />
    <entry schema="dbo" name="dba_SplitString" type="TF" comment="older UDF" />
    <entry schema="dbo" name="dba_CheckPaths" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_ExecuteAndFilterNonCatchableCommand" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_LoadDatabaseNames" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_RemoveBackupFiles" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_BackupDatabases" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_RestoreDatabases" type="P" comment="older sproc" />
    <entry schema="dbo" name="dba_VerifyBackupExecution" type="P" comment="older sproc" />

    <entry schema="dbo" name="dba_DatabaseBackups" type="P" comment="Potential FORMER versions of basic code (pre 1.0)." />
    <entry schema="dbo" name="dba_ExecuteNonCatchableCommand" type="P" comment="Potential FORMER versions of basic code (pre 1.0)." />
    <entry schema="dbo" name="dba_RestoreDatabases" type="P" comment="Potential FORMER versions of basic code (pre 1.0)." />
    <entry schema="dbo" name="dba_DatabaseRestore_CheckPaths" type="P" comment="Potential FORMER versions of HA monitoring (pre 1.0)." />
    
    <entry schema="dbo" name="dba_AvailabilityGroups_HealthCheck" type="P" comment="Potential FORMER versions of HA monitoring (pre 1.0)." />
    <entry schema="dbo" name="dba_Mirroring_HealthCheck" type="P" comment="Potential FORMER versions of HA monitoring (pre 1.0)." />
    
    <entry schema="dbo" name="dba_FilterAndSendAlerts" type="P" comment="FORMER version of alert filtering.">
        <notification>
            <content>NOTE: dbo.dba_FilterAndSendAlerts was dropped from master database - make sure to change job steps/names as needed.</content>
            <heading>WARNING - Potential Configuration Changes Required (alert filtering)</heading>
        </notification>
    </entry>
    <entry schema="dbo" name="dba_drivespace_checks" type="P" comment="FORMER disk monitoring alerts.">
        <notification>
            <content>NOTE: dbo.dba_drivespace_checks was dropped from master database - make sure to change job steps/names as needed.</content>
            <heading>WARNING - Potential Configuration Changes Required (disk-space checks)</heading>
        </notification>
    </entry>
</list>');

EXEC dbo.drop_obsolete_objects @obsoleteObjects, N'master';
GO

------------------------------------------------------------------------------------------------------------------------------------------------------
-- admindb objects:
------------------------------------------------------------------------------------------------------------------------------------------------------

DECLARE @olderObjects xml = CONVERT(xml, N'
<list>
    <entry schema="dbo" name="server_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
        <check>
            <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%server_synchronization_checks%''</statement>
            <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.server_synchronization_checks were found. Please update to call dbo.verify_server_synchronization instead.</warning>
        </check>
    </entry>
    <entry schema="dbo" name="job_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
        <check>
            <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%job_synchronization_checks%''</statement>
            <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.job_synchronization_checks were found. Please update to call dbo.verify_job_synchronization instead.</warning>
        </check>
    </entry>
    <entry schema="dbo" name="data_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
        <check>
            <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%data_synchronization_checks%''</statement>
            <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.data_synchronization_checks were found. Please update to call dbo.verify_data_synchronization instead.</warning>
        </check>
    </entry>

    <entry schema="dbo" name="load_database_names" type="P" comment="v5.2 - S4-52, S4-78, S4-87 - changing dbo.load_database_names to dbo.list_databases." />
    
    <entry schema="dbo" name="get_time_vector" type="P" comment="v5.6 Vector Standardization (cleanup)." />
    <entry schema="dbo" name="get_vector" type="P" comment="v5.6 Vector Standardization (cleanup)." />
    <entry schema="dbo" name="get_vector_delay" type="P" comment="v5.6 Vector Standardization (cleanup)." />

    <entry schema="dbo" name="load_databases" type="P" comment="v5.8 refactor/changes." />

    <entry schema="dbo" name="script_server_logins" type="P" comment="v6.2 refactoring." />
    <entry schema="dbo" name="print_logins" type="P" comment="v6.2 refactoring." />
    <entry schema="dbo" name="script_server_configuration" type="P" comment="v6.2 refactoring." />
    <entry schema="dbo" name="print_configuration" type="P" comment="v6.2 refactoring." />

    <entry schema="dbo" name="respond_to_db_failover" type="P" comment="v6.5 refactoring (changed to dbo.process_synchronization_failover)" />

	<entry schema="dbo" name="server_trace_flags" type="U" comment="v6.6 - Direct Query for Trace Flags vs delayed/table-checks." />
</list>');

EXEC dbo.drop_obsolete_objects @olderObjects, N'admindb';
GO

-----------------------------------
-- v7.0+ - Conversion of [tokens] to {tokens}. (Breaking Change - Raises warnings/alerts via SELECT statements). 
IF (SELECT admindb.dbo.get_s4_version('7.6.3167.2')) < 7.0 BEGIN

	-- Replace any 'custom' token definitions in dbo.settings: 
	DECLARE @tokenChanges table (
		setting_id int NOT NULL, 
		old_setting_key sysname NOT NULL, 
		new_setting_key sysname NOT NULL 
	);

	UPDATE [dbo].[settings]
	SET 
		[setting_key] = REPLACE(REPLACE([setting_key], N']', N'}'), N'[', N'{')
	OUTPUT 
		[Deleted].[setting_id], [Deleted].[setting_key], [Inserted].[setting_key] INTO @tokenChanges
	WHERE 
		[setting_key] LIKE N'~[%~]' ESCAPE '~';


	IF EXISTS (SELECT NULL FROM @tokenChanges) BEGIN 

		SELECT 
			N'WARNING: dbo.settings.setting_key CHANGED from pre 7.0 [token] syntax to 7.0+ {token} syntax' [WARNING], 
			[setting_id], 
			[old_setting_key], 
			[new_setting_key]
		FROM 
			@tokenChanges
	END;

	-- Raise alerts/warnings about any Job-Steps on the server with old-style [tokens] instead of {tokens}:
	DECLARE @oldTokens table ( 
		old_token_id int IDENTITY(1,1) NOT NULL, 
		token_pattern sysname NOT NULL, 
		is_custom bit DEFAULT 1
	); 

	INSERT INTO @oldTokens (
		[token_pattern], [is_custom]
	)
	VALUES
		(N'%~[ALL~]%', 0),
		(N'%~[SYSTEM~]%', 0),
		(N'%~[USER~]%', 0),
		(N'%~[READ_FROM_FILESYSTEM~]%', 0), 
		(N'%~[READ_FROM_FILE_SYSTEM~]%', 0), 
		(N'%~[DEFAULT~]%', 0);

	INSERT INTO @oldTokens (
		[token_pattern]
	)
	SELECT DISTINCT
		N'%~' + REPLACE([setting_key], N']', N'~]') + N'%'
	FROM 
		[admindb].[dbo].[settings] 
	WHERE 
		[setting_key] LIKE '~[%~]' ESCAPE '~';

	WITH matches AS ( 
		SELECT 
			js.[job_id], 
			js.[step_id], 
			js.[command], 
			js.[step_name],
			x.[token_pattern]
		FROM 
			[msdb].dbo.[sysjobsteps] js 
			INNER JOIN @oldTokens x ON js.[command] LIKE x.[token_pattern] ESCAPE N'~'
		WHERE 
			js.[subsystem] = N'TSQL'
	)

	SELECT 
		N'WARNING: SQL Server Agent Job-Step uses PRE-7.0 [tokens] which should be changed to {token} syntax instead.' [WARNING],
		j.[name] [job_name], 
		--	j.[job_id], 
		CAST(m.[step_id] AS sysname) + N' - ' + m.[step_name] [Job-Step-With-Invalid-Token],
		N'TASK: Manually Replace ' + REPLACE(REPLACE(m.[token_pattern], N'~', N''), N'%', N'') 
			+ N' with ' + REPLACE(REPLACE(( ( REPLACE(REPLACE(m.[token_pattern], N'~', N''), N'%', N'') ) ), N']', N'}'), N'[', N'{') + '.' [Task-To-Execute-Manually]
		--m.[command]
	FROM 
		[matches] m 
		INNER JOIN [msdb].dbo.[sysjobs] j ON m.[job_id] = j.[job_id];

END;

----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 4. Deploy new/updated code.
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [admindb];
GO

------------------------------------------------------------------------------------------------------------------------------------------------------
-- Advanced S4 Error-Handling Capabilities:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.enable_advanced_capabilities','P') IS NOT NULL
	DROP PROC dbo.enable_advanced_capabilities;
GO

CREATE PROC dbo.enable_advanced_capabilities

AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @xpCmdShellValue bit; 
	DECLARE @xpCmdShellInUse bit;
	DECLARE @advancedS4 bit = 0;
	
	SELECT 
		@xpCmdShellValue = CAST([value] AS bit), 
		@xpCmdShellInUse = CAST([value_in_use] AS bit) 
	FROM 
		sys.configurations 
	WHERE 
		[name] = 'xp_cmdshell';

	IF EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN 
		SELECT 
			@advancedS4 = CAST([setting_value] AS bit) 
		FROM 
			dbo.[settings] 
		WHERE 
			[setting_key] = N'advanced_s4_error_handling';
	END;

	-- check to see if enabled first: 
	IF @advancedS4 = 1 AND @xpCmdShellInUse = 1 BEGIN
		PRINT 'Advanced S4 error handling (ability to use xp_cmdshell) already/previously enabled.';
		GOTO termination;
	END;

	IF @xpCmdShellValue = 1 AND @xpCmdShellInUse = 0 BEGIN 
		RECONFIGURE;
		SET @xpCmdShellInUse = 1;
	END;

	IF @xpCmdShellValue = 0 BEGIN

        IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'show advanced options' AND [value_in_use] = 0) BEGIN
            EXEC sp_configure 'show advanced options', 1; 
            RECONFIGURE;
        END;

		EXEC sp_configure 'xp_cmdshell', 1; 
		RECONFIGURE;

		SELECT @xpCmdShellValue = 1, @xpCmdShellInUse = 1;
	END;

	IF @advancedS4 = 0 BEGIN 
		IF EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN
			UPDATE dbo.[settings] 
			SET 
				[setting_value] = N'1', 
				[comments] = N'Manually enabled on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.'  
			WHERE 
				[setting_key] = N'advanced_s4_error_handling';
		  END;
		ELSE BEGIN 
			INSERT INTO dbo.[settings] (
				[setting_type],
				[setting_key],
				[setting_value],
				[comments]
			)
			VALUES (
				N'UNIQUE', 
				N'advanced_s4_error_handling', 
				N'1', 
				N'Manually enabled on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.' 
			);
		END;
		SET @advancedS4 = 1;
	END;

termination: 
	SELECT 
		@xpCmdShellValue [xp_cmdshell.value], 
		@xpCmdShellInUse [xp_cmdshell.value_in_use],
		@advancedS4 [advanced_s4_error_handling.value];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.disable_advanced_capabilities','P') IS NOT NULL
	DROP PROC dbo.disable_advanced_capabilities
GO

CREATE PROC dbo.disable_advanced_capabilities

AS 
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @xpCmdShellValue bit; 
	DECLARE @xpCmdShellInUse bit;
	DECLARE @advancedS4 bit = 0;
	DECLARE @errorMessage nvarchar(MAX);
		
	SELECT 
		@xpCmdShellValue = CAST([value] AS bit), 
		@xpCmdShellInUse = CAST([value_in_use] AS bit) 
	FROM 
		sys.configurations 
	WHERE 
		[name] = 'xp_cmdshell';

	IF EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN 

		SELECT 
			@advancedS4 = CAST([setting_value] AS bit) 
		FROM 
			dbo.[settings] 
		WHERE 
			[setting_key] = N'advanced_s4_error_handling';
	END;

	BEGIN TRY 
		IF @xpCmdShellValue = 1 OR @xpCmdShellInUse = 1 BEGIN
			EXEC sp_configure 'xp_cmdshell', 0; 
			RECONFIGURE;	
			
			SELECT @xpCmdShellValue = 0, @xpCmdShellInUse = 0;
		END;

		IF EXISTS (SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN
			IF @advancedS4 = 1 BEGIN 
				UPDATE dbo.[settings]
				SET 
					[setting_value] = N'0', 
					[comments] = N'Manually DISABLED on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.' 
				WHERE 
					[setting_key] = N'advanced_s4_error_handling';
			  END;
			ELSE BEGIN
				INSERT INTO dbo.[settings] (
					[setting_type],
					[setting_key],
					[setting_value],
					[comments]
				)
				VALUES (
					N'UNIQUE', 
					N'advanced_s4_error_handling', 
					N'1', 
					N'Manually DISABLED on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.' 
				);
			END;
			SET @advancedS4 = 0;
		END;

	END TRY
	BEGIN CATCH 
		SELECT @errorMessage = N'Unhandled Exception: ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END CATCH

	SELECT 
		@xpCmdShellValue [xp_cmdshell.value], 
		@xpCmdShellInUse [xp_cmdshell.value_in_use],
		@advancedS4 [advanced_s4_error_handling.value];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_advanced_capabilities','P') IS NOT NULL
	DROP PROC dbo.verify_advanced_capabilities;
GO

CREATE PROC dbo.verify_advanced_capabilities
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @xpCmdShellInUse bit;
	DECLARE @advancedS4 bit;
	DECLARE @errorMessage nvarchar(1000);
	
	SELECT 
		@xpCmdShellInUse = CAST([value_in_use] AS bit) 
	FROM 
		sys.configurations 
	WHERE 
		[name] = 'xp_cmdshell';

	SELECT 
		@advancedS4 = CAST([setting_value] AS bit) 
	FROM 
		dbo.[settings] 
	WHERE 
		[setting_key] = N'advanced_s4_error_handling';

	IF @xpCmdShellInUse = 1 AND ISNULL(@advancedS4, 0) = 1
		RETURN 0;
	
	RAISERROR(N'Advanced S4 error handling capabilities are NOT enabled. Please consult S4 setup documentation and execute admindb.dbo.enable_advanced_capabilities;', 16, 1);
	RETURN -1;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Common and Utilities:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.check_paths','P') IS NOT NULL
	DROP PROC dbo.check_paths;
GO

CREATE PROC dbo.check_paths 
	@Path				nvarchar(MAX),
	@Exists				bit					OUTPUT
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	SET @Exists = 0;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @command nvarchar(2000) = N'IF EXIST "' + @Path + N'" ECHO EXISTS';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @command;

	IF EXISTS (SELECT NULL FROM @results WHERE [output] = 'EXISTS')
		SET @Exists = 1;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.load_default_path','FN') IS NOT NULL
	DROP FUNCTION dbo.load_default_path;
GO

CREATE FUNCTION dbo.load_default_path(@PathType sysname) 
RETURNS nvarchar(4000)
AS
BEGIN
 
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @output sysname;

	IF UPPER(@PathType) = N'BACKUPS'
		SET @PathType = N'BACKUP';

	IF UPPER(@PathType) = N'LOGS'
		SET @PathType = N'LOG';

	DECLARE @valueName nvarchar(4000);

	SET @valueName = CASE @PathType
		WHEN N'BACKUP' THEN N'BackupDirectory'
		WHEN N'DATA' THEN N'DefaultData'
		WHEN N'LOG' THEN N'DefaultLog'
		ELSE N''
	END;

	IF @valueName = N''
		RETURN 'Error. Invalid @PathType Specified.';

	EXEC master..xp_instance_regread
		N'HKEY_LOCAL_MACHINE',  
		N'Software\Microsoft\MSSQLServer\MSSQLServer',  
		@valueName,
		@output OUTPUT, 
		'no_output';

	-- account for older versions and/or values not being set for data/log paths: 
	IF @output IS NULL BEGIN 
		IF @PathType = 'DATA' BEGIN 
			EXEC master..xp_instance_regread
				N'HKEY_LOCAL_MACHINE',  
				N'Software\Microsoft\MSSQLServer\MSSQLServer\Parameters',  
				N'SqlArg0',  -- try grabbing service startup parameters instead: 
				@output OUTPUT, 
				'no_output';			

			IF @output IS NOT NULL BEGIN 
				SET @output = SUBSTRING(@output, 3, 255)
				SET @output = SUBSTRING(@output, 1, LEN(@output) - CHARINDEX('\', REVERSE(@output)))
			  END;
			ELSE BEGIN
				SELECT @output = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)); -- likely won't provide any data if we didn't get it previoulsy... 
			END;
		END;

		IF @PathType = 'LOG' BEGIN 
			EXEC master..xp_instance_regread
				N'HKEY_LOCAL_MACHINE',  
				N'Software\Microsoft\MSSQLServer\MSSQLServer\Parameters',  
				N'SqlArg0',  -- try grabbing service startup parameters instead: 
				@output OUTPUT, 
				'no_output';			

			IF @output IS NOT NULL BEGIN 
				SET @output = SUBSTRING(@output, 3, 255)
				SET @output = SUBSTRING(@output, 1, LEN(@output) - CHARINDEX('\', REVERSE(@output)))
			  END;
			ELSE BEGIN
				SELECT @output = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)); -- likely won't provide any data if we didn't get it previoulsy... 
			END;
		END;
	END;

	RETURN @output;
END;
GO




-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_default_setting','P') IS NOT NULL
	DROP PROC dbo.load_default_setting;
GO

CREATE PROC dbo.load_default_setting
	@SettingName			sysname	                    = NULL, 
	@Result					sysname			            = N''       OUTPUT			-- NOTE: Non-NULL for PROJECT or REPLY convention
AS
	SET NOCOUNT ON; 
	
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	DECLARE @output sysname; 

    SET @output = (SELECT TOP 1 [setting_value] FROM dbo.settings WHERE UPPER([setting_key]) = UPPER(@SettingName) ORDER BY [setting_id] DESC);

    -- load convention 'settings' if nothing has been explicitly set: 
    IF @output IS NULL BEGIN
        DECLARE @conventions table ( 
            setting_key sysname NOT NULL, 
            setting_value sysname NOT NULL
        );

        INSERT INTO @conventions (
            [setting_key],
            [setting_value]
        )
        VALUES 
		    (N'DEFAULT_BACKUP_PATH', (SELECT dbo.[load_default_path](N'BACKUP'))),
		    (N'DEFAULT_DATA_PATH', (SELECT dbo.[load_default_path](N'LOG'))),
		    (N'DEFAULT_LOG_PATH', (SELECT dbo.[load_default_path](N'DATA'))),
		    (N'DEFAULT_OPERATOR', N'Alerts'),
		    (N'DEFAULT_PROFILE', N'General');            

        SELECT @output = [setting_value] FROM @conventions WHERE [setting_key] = @SettingName;

    END;

    IF @Result IS NULL 
        SET @Result = @output; 
    ELSE BEGIN 
        DECLARE @dynamic nvarchar(MAX) = N'SELECT @output [' + @SettingName + N'];';  
        
        EXEC sys.sp_executesql 
            @dynamic, 
            N'@output sysname', 
            @output = @output;
    END;
    
    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO 


IF OBJECT_ID('dbo.shred_resources','IF') IS NOT NULL
	DROP FUNCTION dbo.shred_resources;
GO

CREATE FUNCTION dbo.shred_resources(@resources xml)
RETURNS TABLE 
AS 
  RETURN	
	
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	SELECT 
		[resource].value('resource_identifier[1]', 'sysname') [resource_identifier], 
		[resource].value('@database[1]', 'sysname') [database], 
		[resource].value('(transaction/@transaction_id)[1]', 'bigint') transaction_id,
		[resource].value('(transaction/@request_mode)[1]', 'sysname') lock_mode, 
		[resource].value('(transaction/@reference_count)[1]', 'int') reference_count,
		[resource].value('lock_owner_address[1]', 'sysname') [lock_owner_address], 
		[resource].query('.') [resource_data]
	FROM 
		@resources.nodes('//resource') [XmlData]([resource]);

GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.is_system_database','FN') IS NOT NULL
	DROP FUNCTION dbo.is_system_database;
GO

CREATE FUNCTION dbo.is_system_database(@DatabaseName sysname) 
	RETURNS bit
AS 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN 
		DECLARE @output bit = 0;
		DECLARE @override sysname; 

		IF UPPER(@DatabaseName) IN (N'MASTER', N'MSDB', N'MODEL')
			SET @output = 1; 

		IF UPPER(@DatabaseName) = N'TEMPDB'  -- not sure WHY this would ever be interrogated, but... it IS a system database.
			SET @output = 1;
		
		IF UPPER(@DatabaseName) = N'ADMINDB' BEGIN -- by default, the [admindb] is treated as a system database (but this can be overwritten as a setting in dbo.settings).
			SET @output = 1;

			SELECT @override = setting_value FROM dbo.settings WHERE setting_key = N'admindb_is_system_db';

			IF @override = N'0'	-- only overwrite if a) the setting is there/defined AND the setting's value = 0 (i.e., false).
				SET @output = 0;
		END;

		IF UPPER(@DatabaseName) = N'DISTRIBUTION' BEGIN -- same with the distribution database... 
			SET @output = 1;
			
			SELECT @override = setting_value FROM dbo.settings WHERE setting_key = N'distribution_is_system_db';

			IF @override = N'0'	-- only overwrite if a) the setting is there/defined AND the setting's value = 0 (i.e., false).
				SET @output = 0;
		END;

		RETURN @output;
	END; 
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.parse_vector','P') IS NOT NULL
	DROP PROC dbo.parse_vector;
GO

CREATE PROC dbo.parse_vector
	@Vector									sysname					, 
	@ValidationParameterName				sysname					= NULL,
	@ProhibitedIntervals					sysname					= NULL,				-- by default, ALL intervals are allowed... 
	@IntervalType							sysname					OUT, 
	@Value									bigint					OUT, 
	@Error									nvarchar(MAX)			OUT
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	SET @ValidationParameterName = ISNULL(NULLIF(@ValidationParameterName, N''), N'@Vector');
	IF @ValidationParameterName LIKE N'@%'
		SET @ValidationParameterName = REPLACE(@ValidationParameterName, N'@', N'');

	DECLARE @intervals table ( 
		[key] sysname NOT NULL, 
		[interval] sysname NOT NULL
	);

	INSERT INTO @intervals ([key],[interval]) 
	SELECT [key], [interval] 
	FROM (VALUES 
			(N'B', N'BACKUP'), (N'BACKUP', N'BACKUP'),
			(N'MILLISECOND', N'MILLISECOND'), (N'MS', N'MILLISECOND'), (N'SECOND', N'SECOND'), (N'S', N'SECOND'),(N'MINUTE', N'MINUTE'), (N'M', N'MINUTE'), 
			(N'N', N'MINUTE'), (N'HOUR', N'HOUR'), (N'H', 'HOUR'), (N'DAY', N'DAY'), (N'D', N'DAY'), (N'WEEK', N'WEEK'), (N'W', N'WEEK'),
			(N'MONTH', N'MONTH'), (N'MO', N'MONTH'), (N'QUARTER', N'QUARTER'), (N'Q', N'QUARTER'), (N'YEAR', N'YEAR'), (N'Y', N'YEAR')
	) x ([key], [interval]);

	SET @Vector = LTRIM(RTRIM(UPPER(REPLACE(@Vector, N' ', N''))));
	DECLARE @boundary int, @intervalValue sysname, @interval sysname;
	SET @boundary = PATINDEX(N'%[^0-9]%', @Vector) - 1;

	IF @boundary < 1 BEGIN 
		SET @Error = N'Invalid Vector format specified for parameter @' + @ValidationParameterName + N'. Format must be in ''XX nn'' or ''XXnn'' format - where XX is an ''integer'' duration (e.g., 72) and nn is an interval-specifier (e.g., HOUR, HOURS, H, or h).';
		RETURN -1;
	END;

	SET @intervalValue = LEFT(@Vector, @boundary);
	SET @interval = UPPER(REPLACE(@Vector, @intervalValue, N''));

	IF @interval LIKE '%S' AND @interval NOT IN ('S', 'MS')
		SET @interval = LEFT(@interval, LEN(@interval) - 1); 

	IF NOT @interval IN (SELECT [key] FROM @intervals) BEGIN
		SET @Error = N'Invalid interval specifier defined for @' + @ValidationParameterName + N'. Valid interval specifiers are { [MILLISECOND(S)|MS] | [SECOND(S)|S] | [MINUTE(S)|M|N] | [HOUR(S)|H] | [DAY(S)|D] | [WEEK(S)|W] | [MONTH(S)|MO] | [QUARTER(S)|Q] | [YEAR(S)|Y] }';
		RETURN -10;
	END;

	--  convert @interval to a sanitized version of itself:
	SELECT @interval = [interval] FROM @intervals WHERE [key] = @interval;

	-- check for prohibited intervals: 
	IF NULLIF(@ProhibitedIntervals, N'') IS NOT NULL BEGIN 
		-- delete INTERVALS based on keys - e.g., if ms is prohibited, we don't want to simply delete the MS entry - we want to get all 'forms' of it (i.e., MS, MILLISECOND, etc.)
		DELETE FROM @intervals WHERE [interval] IN (SELECT [interval] FROM @intervals WHERE UPPER([key]) IN (SELECT UPPER([result]) FROM dbo.[split_string](@ProhibitedIntervals, N',', 1)));
		
		IF @interval NOT IN (SELECT [interval] FROM @intervals) BEGIN
			SET @Error = N'The interval-specifier [' + @interval + N'] is not permitted in this operation type. Prohibited intervals for this operation are: ' + @ProhibitedIntervals + N'.';
			RETURN -30;
		END;
	END;

	SELECT 
		@IntervalType = @interval, 
		@Value = CAST(@intervalValue AS bigint);

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector','P') IS NOT NULL
	DROP PROC dbo.translate_vector;
GO

CREATE PROC dbo.translate_vector
	@Vector									sysname						= NULL, 
	@ValidationParameterName				sysname						= NULL, 
	@ProhibitedIntervals					sysname						= NULL,								
	@TranslationDatePart					sysname						= N'MILLISECOND',					-- The 'DATEPART' value you want to convert BY/TO. Allowed Values: { MILLISECONDS | SECONDS | MINUTES | HOURS | DAYS | WEEKS | MONTHS | YEARS }
	@Output									bigint						= NULL		OUT, 
	@Error									nvarchar(MAX)				= NULL		OUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------

	-- convert @TranslationDatePart to a sanitized version of itself:
	IF @TranslationDatePart IS NULL OR @TranslationDatePart NOT IN ('MILLISECOND', 'SECOND', 'MINUTE', 'HOUR', 'DAY', 'MONTH', 'YEAR') BEGIN 
		SET @Error = N'Invalid @TranslationDatePart value specified. Allowed values are: { [MILLISECOND(S)|MS] | [SECOND(S)|S] | [MINUTE(S)|M|N] | [HOUR(S)|H] | [DAY(S)|D] | [WEEK(S)|W] | [MONTH(S)|MO] | [YEAR(S)|Y] }.';
		RETURN -12;
	END;

	IF @ProhibitedIntervals IS NULL
		SET @ProhibitedIntervals = N'BACKUP';

	IF dbo.[count_matches](@ProhibitedIntervals, N'BACKUP') < 1
		SET @ProhibitedIntervals = @ProhibitedIntervals + N', BACKUP';

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @interval sysname;
	DECLARE @duration bigint;

	EXEC dbo.parse_vector 
		@Vector = @Vector, 
		@ValidationParameterName  = @ValidationParameterName, 
		@ProhibitedIntervals = @ProhibitedIntervals, 
		@IntervalType = @interval OUTPUT, 
		@Value = @duration OUTPUT, 
		@Error = @errorMessage OUTPUT; 

	IF @errorMessage IS NOT NULL BEGIN 
		SET @Error = @errorMessage;
		RETURN -10;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @now datetime = GETDATE();
	
	BEGIN TRY 

		DECLARE @command nvarchar(400) = N'SELECT @difference = DATEDIFF(' + @TranslationDatePart + N', @now, (DATEADD(' + @interval + N', ' + CAST(@duration AS sysname) + N', @now)));'
		EXEC sp_executesql 
			@command, 
			N'@now datetime, @difference bigint OUTPUT', 
			@now = @now, 
			@difference = @Output OUTPUT;

	END TRY 
	BEGIN CATCH
		SELECT @Error = N'EXCEPTION: ' + CAST(ERROR_MESSAGE() AS sysname) + N' - ' + ERROR_MESSAGE();
		RETURN -30;
	END CATCH

	RETURN 0;
GO	


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector_delay','P') IS NOT NULL
	DROP PROC dbo.translate_vector_delay;
GO

CREATE PROC dbo.translate_vector_delay
	@Vector								sysname     	= NULL, 
	@ParameterName						sysname			= NULL, 
	@Output								sysname			= NULL		OUT, 
	@Error								nvarchar(MAX)	= NULL		OUT
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @difference int;

	EXEC dbo.translate_vector 
		@Vector = @Vector, 
		@ValidationParameterName = @ParameterName,
		@ProhibitedIntervals = N'DAY,WEEK,MONTH,QUARTER,YEAR',  -- days are overkill for any sort of WAITFOR delay specifier (that said, 38 HOURS would work... )  
		@Output = @difference OUTPUT, 
		@Error = @Error OUTPUT;

	IF @difference > 187200100 BEGIN 
		RAISERROR(N'@Vector can not be > 52 Hours when defining a DELAY value.', 16, 1);
		RETURN -2;
	END; 

	IF @Error IS NOT NULL BEGIN 
		RAISERROR(@Error, 16, 1); 
		RETURN -5;
	END;
	
	SELECT @Output = RIGHT(dbo.[format_timespan](@difference), 12);

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO 

IF OBJECT_ID('dbo.translate_vector_datetime','P') IS NOT NULL
	DROP PROC dbo.translate_vector_datetime;
GO

CREATE PROC dbo.translate_vector_datetime
	@Vector									sysname						= NULL, 
	@Operation								sysname						= N'ADD',		-- Allowed Values are { ADD | SUBTRACT }
	@ValidationParameterName				sysname						= NULL, 
	@ProhibitedIntervals					sysname						= NULL,	
	@Output									datetime					OUT, 
	@Error									nvarchar(MAX)				OUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	IF UPPER(@Operation) NOT IN (N'ADD', N'SUBTRACT') BEGIN 
		RAISERROR('Valid operations (values for @Operation) are { ADD | SUBTRACT }.', 16, 1);
		RETURN -1;
	END;

	IF @ProhibitedIntervals IS NULL
		SET @ProhibitedIntervals = N'BACKUP';

	IF dbo.[count_matches](@ProhibitedIntervals, N'BACKUP') < 1
		SET @ProhibitedIntervals = @ProhibitedIntervals + N', BACKUP';

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @interval sysname;
	DECLARE @duration bigint;

	EXEC dbo.parse_vector 
		@Vector = @Vector, 
		@ValidationParameterName  = @ValidationParameterName, 
		@ProhibitedIntervals = @ProhibitedIntervals, 
		@IntervalType = @interval OUTPUT, 
		@Value = @duration OUTPUT, 
		@Error = @errorMessage OUTPUT; 

	IF @errorMessage IS NOT NULL BEGIN 
		SET @Error = @errorMessage;
		RETURN -10;
	END;

	DECLARE @sql nvarchar(2000) = N'SELECT @timestamp = DATEADD({0}, {2}{1}, GETDATE());';
	SET @sql = REPLACE(@sql, N'{0}', @interval);
	SET @sql = REPLACE(@sql, N'{1}', @duration);

	IF UPPER(@Operation) = N'ADD'
		SET @sql = REPLACE(@sql, N'{2}', N'');
	ELSE 
		SET @sql = REPLACE(@sql, N'{2}', N'0 - ');

	DECLARE @ts datetime;

	BEGIN TRY 
		
		EXEC sys.[sp_executesql]
			@sql, 
			N'@timestamp datetime OUT', 
			@timestamp = @ts OUTPUT;

	END TRY
	BEGIN CATCH 
		SELECT @Error = N'EXCEPTION: ' + CAST(ERROR_MESSAGE() AS sysname) + N' - ' + ERROR_MESSAGE();
		RETURN -30;
	END CATCH

	SET @Output = @ts;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_alerting_configuration','P') IS NOT NULL
	DROP PROC dbo.[verify_alerting_configuration];
GO

CREATE PROC dbo.[verify_alerting_configuration]
	@OperatorName						    sysname									= N'{DEFAULT}',
	@MailProfileName					    sysname									= N'{DEFAULT}'
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    DECLARE @output sysname;

    IF UPPER(@OperatorName) = N'{DEFAULT}' OR (NULLIF(@OperatorName, N'') IS NULL) BEGIN 
        SET @output = NULL;
        EXEC dbo.load_default_setting 
            @SettingName = N'DEFAULT_OPERATOR', 
            @Result = @output OUTPUT;

        SET @OperatorName = @output;
    END;

    IF UPPER(@MailProfileName) = N'{DEFAULT}' OR (NULLIF(@MailProfileName, N'') IS NULL) BEGIN
        SET @output = NULL;
        EXEC dbo.load_default_setting 
            @SettingName = N'DEFAULT_PROFILE', 
            @Result = @output OUTPUT;   
            
        SET @MailProfileName = @output;
    END;
	
    -- Operator Check:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be via email if encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalid Operator Name Specified.', 16, 1);
			RETURN -4;
		END;
	END;

	-- Profile Check:
	DECLARE @DatabaseMailProfile nvarchar(255);
	EXEC master.dbo.xp_instance_regread 
        N'HKEY_LOCAL_MACHINE', 
        N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', 
        @param = @DatabaseMailProfile OUT, 
        @no_output = N'no_output';
 
	IF @DatabaseMailProfile != @MailProfileName BEGIN
		RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
		RETURN -5;
	END; 

    RETURN 0;
GO


-----------------------------------
USE	[admindb];
GO

IF OBJECT_ID('dbo.list_databases_matching_token','P') IS NOT NULL
	DROP PROC dbo.list_databases_matching_token;
GO

CREATE PROC dbo.list_databases_matching_token	
	@Token								sysname			= N'{DEV}',					-- { [DEV] | [TEST] }
	@SerializedOutput					xml				= N'<default/>'	    OUTPUT
AS 

	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	
	IF NOT @Token LIKE N'{%}' BEGIN 
		RAISERROR(N'@Token names must be ''wrapped'' in {curly brackets] (and must also be defined in dbo.setttings).', 16, 1);
		RETURN -5;
	END;

	-----------------------------------------------------------------------------
	-- Processing:
	DECLARE @tokenMatches table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	);

	IF UPPER(@Token) IN (N'{ALL}', N'{SYSTEM}', N'{USER}') BEGIN
		-- define system databases - we'll potentially need this in a number of different cases...
		DECLARE @system_databases TABLE ( 
			[entry_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		); 	
	
		INSERT INTO @system_databases ([database_name])
		SELECT N'master' UNION SELECT N'msdb' UNION SELECT N'model';		

		-- Treat admindb as {SYSTEM} if defined as system... : 
		IF (SELECT dbo.is_system_database('admindb')) = 1 BEGIN
			INSERT INTO @system_databases ([database_name])
			VALUES ('admindb');
		END;

		-- same with distribution database - but only if present:
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = 'distribution') BEGIN
			IF (SELECT dbo.is_system_database('distribution')) = 1  BEGIN
				INSERT INTO @system_databases ([database_name])
				VALUES ('distribution');
			END;
		END;

		IF UPPER(@Token) IN (N'{ALL}', N'{SYSTEM}') BEGIN 
			INSERT INTO @tokenMatches ([database_name])
			SELECT [database_name] FROM @system_databases; 
		END; 

		IF UPPER(@Token) IN (N'{ALL}', N'{USER}') BEGIN 
			INSERT INTO @tokenMatches ([database_name])
			SELECT [name] FROM sys.databases
			WHERE [name] NOT IN (SELECT [database_name] COLLATE SQL_Latin1_General_CP1_CI_AS  FROM @system_databases)
				AND LOWER([name]) <> N'tempdb'
			ORDER BY [name];
		 END; 

	  END; 
	ELSE BEGIN
		
		-- 'custom token'... 
		DECLARE @tokenDefs table (
			row_id int IDENTITY(1,1) NOT NULL,
			pattern sysname NOT NULL
		); 

		INSERT INTO @tokenDefs ([pattern])
		SELECT 
			[setting_value] 
		FROM 
			dbo.[settings]
		WHERE 
			[setting_key] = @Token
		ORDER BY 
			[setting_id];

		IF NOT EXISTS (SELECT NULL FROM @tokenDefs) BEGIN 
			DECLARE @errorMessage nvarchar(2000) = N'No filter definitions were defined for token: ' + @Token + '. Please check dbo.settings for ' + @Token + N' settings_key(s) and/or create as needed.';
			RAISERROR(@errorMessage, 16, 1);
			RETURN -1;
		END;
	
		INSERT INTO @tokenMatches ([database_name])
		SELECT 
			d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS [database_name]
		FROM 
			sys.databases d
			INNER JOIN @tokenDefs f ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE f.[pattern] 
		ORDER BY 
			f.row_id, d.[name];
	END;

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY... 

		SELECT @SerializedOutput = (SELECT 
			[row_id] [database/@id],
			[database_name] [database]
		FROM 
			@tokenMatches
		ORDER BY 
			[row_id] 
		FOR XML PATH(''), ROOT('databases'));		

		RETURN 0;
	END;

    -- otherwise (if we're still here) ... PROJECT:
	SELECT 
		[database_name]
	FROM 
		@tokenMatches 
	ORDER BY 
		[row_id];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.replace_dbname_tokens','P') IS NOT NULL
	DROP PROC dbo.replace_dbname_tokens;
GO

CREATE PROC dbo.replace_dbname_tokens
	@Input					nvarchar(MAX), 
	@AllowedTokens			nvarchar(MAX)		= NULL,			-- When NON-NULL overrides lookup of all DEFINED token types in dbo.settings (i.e., where the setting_key is like [xxx]). 			
	@Output					nvarchar(MAX)		OUTPUT
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 


	-----------------------------------------------------------------------------
	-- processing: 
	IF NULLIF(@AllowedTokens, N'') IS NULL BEGIN

		SET @AllowedTokens = N'';
		
		WITH aggregated AS (
			SELECT 
				UPPER(setting_key) [token], 
				COUNT(*) [ranking]
			FROM 
				dbo.[settings] 
			WHERE 
				[setting_key] LIKE '{%}'
			GROUP BY 
				[setting_key]

			UNION 
			
			SELECT 
				[token], 
				[ranking] 
			FROM (VALUES (N'{ALL}', 1000), (N'{SYSTEM}', 999), (N'{USER}', 998)) [x]([token], [ranking])
		) 

		SELECT @AllowedTokens = @AllowedTokens + [token] + N',' FROM [aggregated] ORDER BY [ranking] DESC;

		SET @AllowedTokens = LEFT(@AllowedTokens, LEN(@AllowedTokens) - 1);
	END;

	DECLARE @tokensToProcess table (
		row_id int IDENTITY(1,1) NOT NULL, 
		token sysname NOT NULL
	); 

	INSERT INTO @tokensToProcess ([token])
	SELECT [result] FROM dbo.[split_string](@AllowedTokens, N',', 1) ORDER BY [row_id];

	-- now that allowed tokens are defined, make sure any tokens specified within @Input are defined in @AllowedTokens: 
	DECLARE @possibleTokens table (
		token sysname NOT NULL
	);

	INSERT INTO @possibleTokens ([token])
	SELECT [result] FROM dbo.[split_string](@Input, N',', 1) WHERE [result] LIKE N'%{%}' ORDER BY [row_id];

	IF EXISTS (SELECT NULL FROM @possibleTokens WHERE [token] NOT IN (SELECT [token] FROM @tokensToProcess)) BEGIN
		RAISERROR('Undefined database-name token specified in @Input. Please ensure that custom database-name tokens are defined in dbo.settings.', 16, 1);
		RETURN -1;
	END;

	DECLARE @intermediateResults nvarchar(MAX) = @Input;
	DECLARE @currentToken sysname;
	DECLARE @databases xml;
	DECLARE @serialized nvarchar(MAX);

	DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT token FROM @tokensToProcess ORDER BY [row_id];

	OPEN walker; 
	FETCH NEXT FROM walker INTO @currentToken;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @databases = NULL;
		SET @serialized = N'';

		EXEC dbo.list_databases_matching_token 
			@Token = @currentToken, 
			@SerializedOutput = @databases OUTPUT; 		

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@databases.nodes('//database') [data]([row])
		) 
		
		SELECT 
			@serialized = @serialized + [database_name] + ', '
		FROM 
			[shredded] 
		ORDER BY 
			[row_id];

		IF NULLIF(@serialized, N'') IS NOT NULL
			SET @serialized = LEFT(@serialized, LEN(@serialized) -1); 

		SET @intermediateResults = REPLACE(@intermediateResults, @currentToken, @serialized);


		FETCH NEXT FROM walker INTO @currentToken;
	END;

	CLOSE walker;
	DEALLOCATE walker;

	SET @Output = @intermediateResults;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.format_sql_login','FN') IS NOT NULL
	DROP FUNCTION dbo.format_sql_login;
GO

CREATE FUNCTION dbo.format_sql_login (
    @Enabled                          bit,                                  -- IF NULL the login will be DISABLED via the output/script.
    @BehaviorIfLoginExists            sysname         = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
    @Name                             sysname,                              -- always required.
    @Password                         varchar(256),                         -- NOTE: while not 'strictly' required by ALTER LOGIN statements, @Password is ALWAYS required for dbo.format_sql_login.
    @SID                              varchar(100),                         -- only processed if this is a CREATE or a DROP/CREATE... 
    @DefaultDatabase                  sysname         = N'master',          -- have to specify DEFAULT for this to work... obviously
    @DefaultLanguage                  sysname         = N'{DEFAULT}',       -- have to specify DEFAULT for this to work... obviously
    @CheckExpriration                 bit             = 0,                  -- have to specify DEFAULT for this to work... obviously
    @CheckPolicy                      bit             = 0                   -- have to specify DEFAULT for this to work... obviously
)
RETURNS nvarchar(MAX)
AS 
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    BEGIN 
        DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
        DECLARE @newAtrributeLine sysname = @crlf + NCHAR(9) + N' ';

        DECLARE @output nvarchar(MAX) = N'-- ERROR scripting login. ' + @crlf 
            + N'--' + NCHAR(9) + N'Parameters @Name and @Password are both required.' + @crlf
            + N'--' + NCHAR(9) + '   Supplied Values: @Name -> [{Name}], @Password -> [{Password}].'
        
        IF NULLIF(@BehaviorIfLoginExists, N'') IS NULL 
            SET @BehaviorIfLoginExists = N'NONE';

        IF UPPER(@BehaviorIfLoginExists) NOT IN (N'NONE', N'ALTER', N'DROP_AND_CREATE')
            SET @BehaviorIfLoginExists = N'NONE';

        IF (NULLIF(@Name, N'') IS NULL) OR (NULLIF(@Password, N'') IS NULL) BEGIN 
            SET @output = REPLACE(@output, N'{name}', ISNULL(NULLIF(@Name, N''), N'#NOT PROVIDED#'));
            SET @output = REPLACE(@output, N'{Password}', ISNULL(NULLIF(@Password, N''), N'#NOT PROVIDED#'));

            GOTO Done;
        END;        
        
        DECLARE @attributes sysname = N'{PASSWORD}{SID}{DefaultDatabase}{DefaultLanguage}{CheckExpiration}{CheckPolicy};';
        DECLARE @alterAttributes sysname = REPLACE(@attributes, N'{SID}', N'');

        DECLARE @template nvarchar(MAX) = N'
IF NOT EXISTS (SELECT NULL FROM [master].[sys].[server_principals] WHERE [name] = ''{Name}'') BEGIN 
    CREATE LOGIN [{Name}] WITH {Attributes} {Disable} {ElseClause} {SidReplacementDrop}{CreateOrAlter} {Attributes2} {Disable2}
END; ';
        -- Main logic flow:
        IF UPPER(@BehaviorIfLoginExists) = N'NONE' BEGIN 
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', N'');
            SET @template = REPLACE(@template, N'{ElseClause}', N'');
            SET @template = REPLACE(@template, N'{CreateOrAlter}', N''); 
                
            SET @template = REPLACE(@template, N'{Attributes2}', N'');
            SET @template = REPLACE(@template, N'{Disable2}', N'');

        END;

        IF UPPER(@BehaviorIfLoginExists) = N'ALTER' BEGIN 
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', N'');

            SET @template = REPLACE(@template, N'{ElseClause}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN' + @crlf);
            SET @template = REPLACE(@template, N'{CreateOrAlter}', NCHAR(9) + N'ALTER LOGIN [{Name}] WITH ');
            SET @template = REPLACE(@template, N'{Attributes2}', @alterAttributes);
            SET @template = REPLACE(@template, N'{Disable2}', N'{Disable}');
        END;

        IF UPPER(@BehaviorIfLoginExists) = N'DROP_AND_CREATE' BEGIN 
            SET @template = REPLACE(@template, N'{ElseClause}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN' + @crlf);
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', NCHAR(9) + N'DROP LOGIN ' + QUOTENAME(@Name) + N';' + @crlf + @crlf);
            SET @template = REPLACE(@template, N'{CreateOrAlter}', NCHAR(9) + N'CREATE LOGIN [{Name}] WITH '); 
            
            SET @template = REPLACE(@template, N'{Attributes2}', @attributes);
            SET @template = REPLACE(@template, N'{Disable2}', N'{Disable}');
        END;
  
        -- initialize output with basic details:
        SET @template = REPLACE(@template, N'{Attributes}', @attributes);
        SET @output = REPLACE(@template, N'{Name}', @Name);

        IF (@Password LIKE '0x%') --AND (@Password NOT LIKE '%HASHED')
            SET @Password = @Password + N' HASHED';
        ELSE 
            SET @Password = N'''' + @Password + N'''';
        
        SET @output = REPLACE(@output, N'{PASSWORD}', @newAtrributeLine + NCHAR(9) + N'PASSWORD = ' + @Password);

        IF NULLIF(@SID, N'') IS NOT NULL BEGIN 
            SET @output = REPLACE(@output, N'{SID}', @newAtrributeLine + N',SID = ' + @SID);
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{SID}', N'');
        END;

        -- Defaults:
        IF NULLIF(@DefaultDatabase, N'') IS NOT NULL BEGIN 
            SET @output = REPLACE(@output, N'{DefaultDatabase}', @newAtrributeLine + N',DEFAULT_DATABASE = ' + QUOTENAME(@DefaultDatabase));
            END; 
        ELSE BEGIN
            SET @output = REPLACE(@output, N'{DefaultDatabase}', N'');
        END;

        IF NULLIF(@DefaultLanguage, N'') IS NOT NULL BEGIN 
            IF UPPER(@DefaultLanguage) = N'{DEFAULT}'
                SELECT @DefaultLanguage = [name] FROM sys.syslanguages WHERE 
                    [langid] = (SELECT [value_in_use] FROM sys.[configurations] WHERE [name] = N'default language');

            SET @output = REPLACE(@output, N'{DefaultLanguage}', @newAtrributeLine + N',DEFAULT_LANGUAGE = ' + QUOTENAME(@DefaultLanguage));
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{DefaultLanguage}', N'');
        END;

        -- checks:
        IF @CheckExpriration IS NULL BEGIN 
            SET @output = REPLACE(@output, N'{CheckExpiration}', N'');
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{CheckExpiration}', @newAtrributeLine + N',CHECK_EXPIRATION = ' + CASE WHEN @CheckExpriration = 1 THEN N'ON' ELSE 'OFF' END);
        END;

        IF @CheckPolicy IS NULL BEGIN 
            SET @output = REPLACE(@output, N'{CheckPolicy}', N'');
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{CheckPolicy}', @newAtrributeLine + N',CHECK_POLICY = ' + CASE WHEN @CheckPolicy = 1 THEN N'ON' ELSE 'OFF' END);
        END;

        -- enabled:
        IF ISNULL(@Enabled, 0) = 0 BEGIN -- default secure (i.e., if we don't get an EXPLICIT enabled, disable... 
            SET @output = REPLACE(@output, N'{Disable}', @crlf + @crlf + NCHAR(9) + N'ALTER LOGIN ' + QUOTENAME(@Name) + N' DISABLE;');
            END;
        ELSE BEGIN
            SET @output = REPLACE(@output, N'{Disable}', N'');
        END;

Done:

        RETURN @output;
    END;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.format_windows_login', 'FN') IS NOT NULL DROP FUNCTION [dbo].[format_windows_login];
GO

CREATE	FUNCTION [dbo].[format_windows_login] (
	@Enabled bit, -- IF NULL the login will be DISABLED via the output/script.
	@BehaviorIfLoginExists sysname = N'NONE', -- { NONE | ALTER | DROP_ANCE_CREATE }
	@Name sysname, -- always required.
	@DefaultDatabase sysname = N'master', -- have to specify DEFAULT for this to work... obviously
	@DefaultLanguage sysname = N'{DEFAULT}' -- have to specify DEFAULT for this to work... obviously
)
RETURNS nvarchar(MAX)
AS

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

BEGIN

	SET @Enabled = ISNULL(@Enabled, 0);
	SET @DefaultDatabase = NULLIF(@DefaultDatabase, N'');
	SET @DefaultLanguage = NULLIF(@DefaultLanguage, N'');
	SET @BehaviorIfLoginExists = ISNULL(NULLIF(@BehaviorIfLoginExists, N''), N'NONE');
	
	IF UPPER(@BehaviorIfLoginExists) NOT IN (N'NONE', N'ALTER', N'DROP_AND_CREATE') SET @BehaviorIfLoginExists = N'NONE';

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @newAtrributeLine sysname = @crlf + NCHAR(9) + NCHAR(9);

	DECLARE @output nvarchar(MAX) = N'-- ERROR scripting login. ' + @crlf + N'--' + NCHAR(9) + N'Parameter @Name is required.';

	IF (NULLIF(@Name, N'') IS NULL) BEGIN
		-- output is already set/defined.
		GOTO Done;
	END;

	IF (UPPER(@BehaviorIfLoginExists) = N'ALTER') AND (@DefaultDatabase IS NULL) AND (@DefaultLanguage IS NULL) BEGIN
		-- if these values are EXPLICITLY set to NULL (vs using the defaults), then we CAN'T run an alter - the statement would be: "ALTER LOGIN [principal\name];" ... which no worky. 
		SET @BehaviorIfLoginExists = N'DROP_AND_CREATE';
	END;

	DECLARE @attributesPresent bit = 1;
	IF @DefaultDatabase IS NULL AND @DefaultLanguage IS NULL 
		SET @attributesPresent = 0;

	DECLARE @createAndDisable nvarchar(MAX) = N'CREATE LOGIN [{Name}] FROM WINDOWS{withAttributes};{disable}';

	IF @Enabled = 0  
		SET @createAndDisable = REPLACE(@createAndDisable, N'{disable}', @crlf + @crlf + NCHAR(9) + N'ALTER LOGIN ' + QUOTENAME(@Name) + N' DISABLE;');
	ELSE 
		SET @createAndDisable = REPLACE(@createAndDisable, N'{disable}', N'');
		
	IF @attributesPresent = 1 BEGIN 
		DECLARE @attributes nvarchar(MAX) = N' WITH';

		IF @DefaultDatabase IS NOT NULL BEGIN
			SET @attributes = @attributes + @newAtrributeLine + N'DEFAULT_DATABASE = ' + QUOTENAME(@DefaultDatabase);
		END;

		IF @DefaultLanguage IS NOT NULL BEGIN 
			
			IF UPPER(@DefaultLanguage) = N'{DEFAULT}'
				SELECT
					@DefaultLanguage = [name]
				FROM
					[sys].[syslanguages]
				WHERE
					[langid] = (
					SELECT [value_in_use] FROM [sys].[configurations] WHERE [name] = N'default language'
				);

			IF @DefaultDatabase IS NULL 
				SET @attributes = @attributes + @newAtrributeLine + N'DEFAULT_LANGUAGE = ' + QUOTENAME(@DefaultLanguage)
			ELSE 
				SET @attributes = @attributes +  @newAtrributeLine + N',DEFAULT_LANGUAGE = ' + QUOTENAME(@DefaultLanguage)
		END;

		SET @createAndDisable = REPLACE(@createAndDisable, N'{withAttributes}', @attributes);
	  END
	ELSE BEGIN
		SET @createAndDisable = REPLACE(@createAndDisable, N'{withAttributes}', N'');
	END;

	DECLARE @flowTemplate nvarchar(MAX) = N'
IF NOT EXISTS (SELECT NULL FROM [master].[sys].[server_principals] WHERE [name] = ''{Name}'') BEGIN 
	{createAndDisable}{else}{alterOrCreateAndDisable}
END; ';

	SET @output = REPLACE(@flowTemplate, N'{createAndDisable}', @createAndDisable);

	IF UPPER(@BehaviorIfLoginExists) = N'NONE' BEGIN
		SET @output = REPLACE(@output, N'{else}', N'');
		SET @output = REPLACE(@output, N'{alterOrCreateAndDisable}', N'');
	END;

	IF UPPER(@BehaviorIfLoginExists) = N'ALTER' BEGIN
		SET @output = REPLACE(@output, N'{else}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN ');

		SET @createAndDisable = REPLACE(@createAndDisable, N'CREATE', N'ALTER');
		SET @createAndDisable = REPLACE(@createAndDisable, N' FROM WINDOWS', N'');

		SET @output = REPLACE(@output, N'{alterOrCreateAndDisable}', @crlf + NCHAR(9) + @createAndDisable);
	END;


	IF UPPER(@BehaviorIfLoginExists) = N'DROP_AND_CREATE' BEGIN
		SET @output = REPLACE(@output, N'{else}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN ');

		SET @createAndDisable = @crlf + NCHAR(9) + N'DROP LOGIN [{Name}];' + @crlf + @crlf + NCHAR(9) + @createAndDisable;

		SET @output = REPLACE(@output, N'{alterOrCreateAndDisable}', @crlf + NCHAR(9) + @createAndDisable);
	END;

	SET @output = REPLACE(@output, N'{Name}', @Name);

Done:

	RETURN @output;

END;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.script_sql_login','P') IS NOT NULL
	DROP PROC dbo.script_sql_login;
GO

CREATE PROC dbo.script_sql_login
    @LoginName                              sysname,       
    @BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
	@DisableExpiryChecks					bit						= 0, 
    @DisablePolicyChecks					bit						= 0,
	@ForceMasterAsDefaultDB					bit						= 0, 
	@IncludeDefaultLanguage					bit						= 0,
    @Output                                 nvarchar(MAX)           = ''        OUTPUT
AS 
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    IF NULLIF(@LoginName, N'') IS NULL BEGIN 
        RAISERROR('@LoginName is required.', 16, 1);
        RETURN -1;
    END;

    DECLARE @enabled bit, @name sysname, @password nvarchar(2000), @sid nvarchar(1000); 
    DECLARE @defaultDB sysname, @defaultLang sysname, @checkExpiration bit, @checkPolicy bit;

    SELECT 
        @enabled = CASE WHEN [is_disabled] = 1 THEN 0 ELSE 1 END,
        @name = [name],
        @password = N'0x' + CONVERT(nvarchar(2000), [password_hash], 2),
        @sid = N'0x' + CONVERT(nvarchar(1000), [sid], 2),
        @defaultDB = [default_database_name],
        @defaultLang = [default_language_name],
        @checkExpiration = [is_expiration_checked], 
        @checkPolicy = [is_policy_checked]
    FROM 
        sys.[sql_logins]
    WHERE 
        [name] = @LoginName;

    IF @name IS NULL BEGIN 
        IF @Output IS NULL 
            SET @Output = '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';
        ELSE 
            PRINT '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';

        RETURN -2;
    END;

    ---------------------------------------------------------
    -- overrides:
    IF @ForceMasterAsDefaultDB = 1 
        SET @defaultDB = N'master';

    IF @DisableExpiryChecks = 1 
        SET @checkExpiration = 0;

    IF @DisablePolicyChecks = 1 
        SET @checkPolicy = 0;

	IF @IncludeDefaultLanguage = 0
		SET @defaultLang = NULL;

    ---------------------------------------------------------
    -- load output:
    DECLARE @formatted nvarchar(MAX);
    SELECT @formatted = dbo.[format_sql_login](
        @enabled, 
        @BehaviorIfLoginExists,
        @name, 
        @password, 
        @sid, 
        @defaultDB,
        @defaultLang, 
        @checkExpiration, 
        @checkPolicy
     );

    IF @Output IS NULL BEGIN 
        SET @Output = @formatted;
        RETURN 0;
    END;

    PRINT @formatted;
    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.script_windows_login','P') IS NOT NULL
	DROP PROC dbo.[script_windows_login];
GO

CREATE PROC dbo.[script_windows_login]
    @LoginName                              sysname,       
    @BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
	@ForceMasterAsDefaultDB					bit						= 0, 
	@IncludeDefaultLanguage					bit						= 0,
    @Output                                 nvarchar(MAX)           = ''        OUTPUT

AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	DECLARE @enabled bit, @name sysname;
	DECLARE @defaultDB sysname, @defaultLang sysname;

	SELECT 
        @enabled = CASE WHEN [is_disabled] = 1 THEN 0 ELSE 1 END,
        @name = [name],
        @defaultDB = [default_database_name],
        @defaultLang = [default_language_name]
	FROM 
		sys.[server_principals] 
	WHERE 
		[name] = @LoginName;


    IF @name IS NULL BEGIN 
        IF @Output IS NULL 
            SET @Output = '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';
        ELSE 
            PRINT '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';

        RETURN -2;
    END;	

    ---------------------------------------------------------
    -- overrides:
    IF @ForceMasterAsDefaultDB = 1 
        SET @defaultDB = N'master';

	IF @IncludeDefaultLanguage = 0
		SET @defaultLang = NULL;

    ---------------------------------------------------------
    -- load output:
    DECLARE @formatted nvarchar(MAX);
	SELECT @formatted = dbo.[format_windows_login](
		@enabled, 
		@BehaviorIfLoginExists, 
		@name,
		@defaultDB, 
		@defaultLang
	);

    IF @Output IS NULL BEGIN 
        SET @Output = @formatted;
        RETURN 0;
    END;

    PRINT @formatted;
    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.create_agent_job','P') IS NOT NULL
	DROP PROC dbo.[create_agent_job];
GO

CREATE PROC dbo.[create_agent_job]
	@TargetJobName							sysname, 
	@JobCategoryName						sysname					= NULL, 
	@AddBlankInitialJobStep					bit						= 1, 
	@OperatorToAlertOnErrorss				sysname					= N'Alerts',
	@OverWriteExistingJobDetails			bit						= 0,					-- NOTE: Initially, this means: DROP/CREATE. Eventually, this'll mean: repopulate the 'guts' of the job if/as needed... 
	@JobID									uniqueidentifier		OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	DECLARE @existingJob sysname; 
	SELECT 
		@existingJob = [name]
	FROM 
		msdb.dbo.sysjobs
	WHERE 
		[name] = @TargetJobName;

	IF @existingJob IS NOT NULL BEGIN 
		IF @OverWriteExistingJobDetails = 1 BEGIN 
			-- vNEXT: for now this just DROPs/CREATEs a new job. While that makes sure the config/details are correct, that LOSEs job-history. 
			--			in the future, another sproc will go out and 'gut'/reset/remove ALL job-details - leaving just a 'shell' (the job and its name). 
			--				at which point, we can then 'add' in all details specified here... so that: a) the details are correct, b) we've kept the history. 
			EXEC msdb..sp_delete_job 
			    @job_name = @TargetJobName,
			    @delete_history = 1,
			    @delete_unused_schedule = 1; 
		  END;
		ELSE BEGIN
			RAISERROR('Unable to create job [%s] - because it already exists. Set @OverwriteExistingJobs = 1 or manually remove existing job/etc.', 16, 1, @TargetJobName);
			RETURN -5;
		END;
	END;

	-- Ensure that the Job Category exists:
	IF NULLIF(@JobCategoryName, N'') IS NULL 
		SET @JobCategoryName = N'[Uncategorized (Local)'; 

	IF NOT EXISTS(SELECT NULL FROM msdb..syscategories WHERE [name] = @JobCategoryName) BEGIN 
		EXEC msdb..sp_add_category 
			@class = N'JOB',
			@type = 'LOCAL',  
		    @name = @JobCategoryName;
	END;

	-- Create the Job:
	SET @JobID = NULL;  -- nasty 'bug' with sp_add_job: if @jobID is NOT NULL, it a) is passed out bottom and b) if a JOB with that ID already exists, sp_add_job does nothing. 
	
	EXEC msdb.dbo.sp_add_job
		@job_name = @TargetJobName,                     
		@enabled = 1,                         
		@description = N'',                   
		@category_name = @JobCategoryName,                
		@owner_login_name = N'sa',             
		@notify_level_eventlog = 0,           
		@notify_level_email = 2,              
		@notify_email_operator_name = @OperatorToAlertOnErrorss,   
		@delete_level = 0,                    
		@job_id = @JobID OUTPUT;

	EXEC msdb.dbo.[sp_add_jobserver] 
		@job_id = @jobId, 
		@server_name = N'(LOCAL)';


	IF @AddBlankInitialJobStep = 1 BEGIN
		EXEC msdb..sp_add_jobstep
			@job_id = @jobId,
			@step_id = 1,
			@step_name = N'Initialize Job History',
			@subsystem = N'TSQL',
			@command = N'/* 

  SQL Server Agent Job History can NOT be shown until the first 
  Job Step is complete. This step is a place-holder. 

*/',
			@on_success_action = 3,		-- go to the next step
			@on_fail_action = 3,		-- go to the next step. Arguably, should be 'quit with failure'. But, a) this shouldn't fail and, b) we don't CARE about this step 'running' so much as we do about SUBSEQUENT steps.
			@database_name = N'admindb',
			@retry_attempts = 0;

	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO 

IF OBJECT_ID('dbo.list_databases','P') IS NOT NULL
	DROP PROC dbo.list_databases
GO

CREATE PROC dbo.list_databases
	@Targets								nvarchar(MAX)	= N'{ALL}',		-- {ALL} | {SYSTEM} | {USER} | {READ_FROM_FILESYSTEM} | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions								nvarchar(MAX)	= NULL,			-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities								nvarchar(MAX)	= NULL,			-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@ExcludeClones							bit				= 1, 
	@ExcludeSecondaries						bit				= 1,			-- exclude AG and Mirroring secondaries... 
	@ExcludeSimpleRecovery					bit				= 0,			-- exclude databases in SIMPLE recovery mode
	@ExcludeReadOnly						bit				= 0,			
	@ExcludeRestoring						bit				= 1,			-- explicitly removes databases in RESTORING and 'STANDBY' modes... 
	@ExcludeRecovering						bit				= 1,			-- explicitly removes databases in RECOVERY, RECOVERY_PENDING, and SUSPECT modes.
	@ExcludeOffline							bit				= 1				-- removes ANY state other than ONLINE.

AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF NULLIF(@Targets, N'') IS NULL BEGIN
		RAISERROR('@Targets cannot be null or empty - it must either be the specialized token {ALL}, {SYSTEM}, {USER}, or a comma-delimited list of databases/folders.', 16, 1);
		RETURN -1;
	END

	IF ((SELECT dbo.[count_matches](@Targets, N'{ALL}')) > 0) AND (UPPER(@Targets) <> N'{ALL}') BEGIN
		RAISERROR(N'When the Token {ALL} is specified for @Targets, no ADDITIONAL db-names or tokens may be specified.', 16, 1);
		RETURN -1;
	END;

	IF (SELECT dbo.[count_matches](@Exclusions, N'{READ_FROM_FILESYSTEM}')) > 0 BEGIN 
		RAISERROR(N'The {READ_FROM_FILESYSTEM} is NOT a valid exclusion token.', 16, 1);
		RETURN -2;
	END;

	IF (SELECT dbo.[count_matches](@Targets, N'{READ_FROM_FILESYSTEM}')) > 0 BEGIN 
		RAISERROR(N'@Targets may NOT be set to (or contain) {READ_FROM_FILESYSTEM}. The {READ_FROM_FILESYSTEM} token is ONLY allowed as an option/token for @TargetDatabases in dbo.restore_databases and dbo.apply_logs.', 16, 1);
		RETURN -3;
	END;

	IF ((SELECT dbo.[count_matches](@Exclusions, N'{SYSTEM}')) > 0) AND ((SELECT dbo.[count_matches](@Targets, N'{ALL}')) > 0) BEGIN
		RAISERROR(N'{SYSTEM} can NOT be specified as an Exclusion when @Targets is (or contains) {ALL}. Replace {ALL} with {USER} for @Targets and remove {SYSTEM} from @Exclusions instead (to load all databases EXCEPT ''System'' Databases.', 16, 1);
		RETURN -5;
	END;

	IF ((SELECT dbo.[count_matches](@Exclusions, N'{USER}')) > 0) AND ((SELECT dbo.[count_matches](@Targets, N'{ALL}')) > 0) BEGIN
		RAISERROR(N'{USER} can NOT be specified as an Exclusion when @Targets is (or contains) {ALL}. Replace {ALL} with {SYSTEM} for @Targets and remove {USER} from @Exclusions instead (to load all databases EXCEPT ''User'' Databases.', 16, 1);
		RETURN -6;
	END;

	IF ((SELECT dbo.[count_matches](@Exclusions, N'{USER}')) > 0) OR ((SELECT dbo.[count_matches](@Exclusions, N'{ALL}')) > 0) BEGIN 
		RAISERROR(N'@Exclusions may NOT be set to {ALL} or {USER}.', 16, 1);
		RETURN -7;
	END;


	-----------------------------------------------------------------------------
	-- Initialize helper objects:
	DECLARE @topN int = (SELECT COUNT(*) FROM sys.databases) + 100;

	SELECT TOP (@topN) IDENTITY(int, 1, 1) as N 
    INTO #Tally
    FROM sys.columns;

	DECLARE @deserialized table (
		[row_id] int NOT NULL, 
		[result] sysname NOT NULL
	); 

    DECLARE @target_databases TABLE ( 
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	DECLARE @system_databases TABLE ( 
		[entry_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 	



	-- load system databases - we'll (potentially) need these in a few evaluations (and avoid nested insert exec): 
	DECLARE @serializedOutput xml = '';
	EXEC dbo.[list_databases_matching_token]
	    @Token = N'{SYSTEM}',
	    @SerializedOutput = @serializedOutput OUTPUT;
	
	WITH shredded AS ( 
		SELECT 
			[data].[row].value('@id[1]', 'int') [row_id], 
			[data].[row].value('.[1]', 'sysname') [database_name]
		FROM 
			@serializedOutput.nodes('//database') [data]([row])
	)
	 
	INSERT INTO @system_databases ([database_name])
	SELECT [database_name] FROM [shredded] ORDER BY [row_id];
		
	-----------------------------------------------------------------------------
	-- Account for tokens: 
	DECLARE @tokenReplacementOutcome int;
	DECLARE @replacedOutput nvarchar(MAX);
	IF @Targets LIKE N'%{%}%' BEGIN 
		EXEC @tokenReplacementOutcome = dbo.replace_dbname_tokens 
			@Input = @Targets, 
			@Output = @replacedOutput OUTPUT;

		IF @tokenReplacementOutcome <> 0 GOTO ErrorCondition;

		SET @Targets = @replacedOutput;
	END;

	 -- If not a token, then try comma delimitied: 
	 IF NOT EXISTS (SELECT NULL FROM @target_databases) BEGIN
	
		INSERT INTO @deserialized ([row_id], [result])
		SELECT [row_id], CAST([result] AS sysname) [result] FROM dbo.[split_string](@Targets, N',', 1);

		IF EXISTS (SELECT NULL FROM @deserialized) BEGIN 
			INSERT INTO @target_databases ([database_name])
			SELECT [result] FROM @deserialized ORDER BY [row_id];
		END;
	 END;

	-----------------------------------------------------------------------------
	-- Remove Exclusions: 
	IF @ExcludeClones = 1 BEGIN 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE source_database_id IS NOT NULL);		
	END;

	IF @ExcludeSecondaries = 1 BEGIN 

		DECLARE @synchronized table ( 
			[database_name] sysname NOT NULL
		);

		-- remove any mirrored secondaries: 
		INSERT INTO @synchronized ([database_name])
		SELECT d.[name] 
		FROM sys.[databases] d 
		INNER JOIN sys.[database_mirroring] dm ON d.[database_id] = dm.[database_id] AND dm.[mirroring_guid] IS NOT NULL
		WHERE UPPER(dm.[mirroring_role_desc]) <> N'PRINCIPAL';

		-- dynamically account for any AG'd databases:
		IF (SELECT dbo.get_engine_version()) >= 11.0 BEGIN		
			CREATE TABLE #hadr_names ([name] sysname NOT NULL);
			EXEC sp_executesql N'INSERT INTO #hadr_names ([name]) SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc <> ''PRIMARY'';'	

			INSERT INTO @synchronized ([database_name])
			SELECT [name] FROM #hadr_names;
		END

		-- Exclude any databases that aren't operational: (NOTE, this excluding all dbs that are non-operational INCLUDING those that might be 'out' because of Mirroring, but it is NOT SOLELY trying to remove JUST mirrored/AG'd databases)
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [database_name] FROM @synchronized);
	END;

	IF @ExcludeSimpleRecovery = 1 BEGIN 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([recovery_model_desc]) = 'SIMPLE');
	END; 

	IF @ExcludeReadOnly = 1 BEGIN
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE [is_read_only] = 1)
	END;

	IF @ExcludeRestoring = 1 BEGIN
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([state_desc]) = 'RESTORING');		

		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE [is_in_standby] = 1);
	END; 

	IF @ExcludeRecovering = 1 BEGIN 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([state_desc]) IN (N'RECOVERY', N'RECOVERY_PENDING', N'SUSPECT'));
	END;
	 
	IF @ExcludeOffline = 1 BEGIN -- all states OTHER than online... 
		DELETE FROM @target_databases 
		WHERE [database_name] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER([state_desc]) = N'OFFLINE');
	END;

	-- Exclude explicit exclusions: 
	IF NULLIF(@Exclusions, '') IS NOT NULL BEGIN;
		
		DELETE FROM @deserialized;

		-- Account for tokens: 
		IF @Exclusions LIKE N'%{%}%' BEGIN 
			EXEC @tokenReplacementOutcome = dbo.replace_dbname_tokens 
				@Input = @Exclusions, 
				@Output = @replacedOutput OUTPUT;
			
			IF @tokenReplacementOutcome <> 0 GOTO ErrorCondition;

			SET @Exclusions = @replacedOutput;
		END;

		INSERT INTO @deserialized ([row_id], [result])
		SELECT [row_id], CAST([result] AS sysname) [result] FROM dbo.[split_string](@Exclusions, N',', 1);

		-- note: delete on BOTH = and LIKE... 
		DELETE t 
		FROM @target_databases t
		INNER JOIN @deserialized d ON (t.[database_name] = d.[result]) OR (t.[database_name] LIKE d.[result]);
	END;

	-----------------------------------------------------------------------------
	-- Prioritize:
	IF ISNULL(@Priorities, '') IS NOT NULL BEGIN;

		-- Account for tokens: 
		IF @Priorities LIKE N'%{%}%' ESCAPE N'~' BEGIN 
			EXEC @tokenReplacementOutcome = dbo.replace_dbname_tokens 
				@Input = @Priorities, 
				@Output = @replacedOutput OUTPUT;

			IF @tokenReplacementOutcome <> 0 GOTO ErrorCondition;
		
			SET @Priorities = @replacedOutput;
		END;		

		DECLARE @prioritized table (
			priority_id int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		);

		INSERT INTO @prioritized ([database_name])
		SELECT [result] FROM dbo.[split_string](@Priorities, N',', 1) ORDER BY [row_id];
				
		DECLARE @alphabetized int;
		SELECT @alphabetized = priority_id FROM @prioritized WHERE [database_name] = '*';

		IF @alphabetized IS NULL
			SET @alphabetized = (SELECT MAX(entry_id) + 1 FROM @target_databases);

		DECLARE @prioritized_targets TABLE ( 
			[entry_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL
		); 

		WITH core AS ( 
			SELECT 
				t.[database_name], 
				CASE 
					WHEN p.[database_name] IS NULL THEN 0 + t.entry_id
					WHEN p.[database_name] IS NOT NULL AND p.priority_id <= @alphabetized THEN -32767 + p.priority_id
					WHEN p.[database_name] IS NOT NULL AND p.priority_id > @alphabetized THEN 32767 + p.priority_id
				END [prioritized_priority]
			FROM 
				@target_databases t 
				LEFT OUTER JOIN @prioritized p ON t.[database_name] LIKE p.[database_name]
		) 

		INSERT INTO @prioritized_targets ([database_name])
		SELECT 
			[database_name]
		FROM core 
		ORDER BY 
			core.prioritized_priority;

		DELETE FROM @target_databases;
		INSERT INTO @target_databases ([database_name])
		SELECT [database_name] 
		FROM @prioritized_targets
		ORDER BY entry_id;
	END;

	-----------------------------------------------------------------------------
	-- project: 
	SELECT 
		[database_name] 
	FROM 
		@target_databases
	ORDER BY 
		[entry_id];

	RETURN 0;

ErrorCondition:
	RETURN -1;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.format_timespan','FN') IS NOT NULL
	DROP FUNCTION dbo.format_timespan;
GO

CREATE FUNCTION dbo.format_timespan(@Milliseconds bigint)
RETURNS sysname
WITH RETURNS NULL ON NULL INPUT
AS
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	BEGIN

		DECLARE @output sysname;

		IF @Milliseconds IS NULL OR @Milliseconds = 0	
			SET @output = N'000:00:00.000';

		IF @Milliseconds > 0 BEGIN
			SET @output = RIGHT('000' + CAST(@Milliseconds / 3600000 as sysname), 3) + N':' + RIGHT('00' + CAST((@Milliseconds / (60000) % 60) AS sysname), 2) + N':' + RIGHT('00' + CAST(((@Milliseconds / 1000) % 60) AS sysname), 2) + N'.' + RIGHT('000' + CAST((@Milliseconds) AS sysname), 3)
		END;

		IF @Milliseconds < 0 BEGIN
			SET @output = N'-' + RIGHT('000' + CAST(ABS(@Milliseconds / 3600000) as sysname), 3) + N':' + RIGHT('00' + CAST(ABS((@Milliseconds / (60000) % 60)) AS sysname), 2) + N':' + RIGHT('00' + CAST((ABS((@Milliseconds / 1000) % 60)) AS sysname), 2) + N'.' + RIGHT('000' + CAST(ABS((@Milliseconds)) AS sysname), 3)
		END;


		RETURN @output;
	END;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.count_matches','FN') IS NOT NULL
	DROP FUNCTION dbo.count_matches;
GO

CREATE FUNCTION dbo.count_matches(@input nvarchar(MAX), @pattern sysname) 
RETURNS int 
AS 
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN 
		DECLARE @output int = 0;

		DECLARE @actualLength int = LEN(@input); 
		DECLARE @replacedLength int = LEN(CAST(REPLACE(@input, @pattern, N'') AS nvarchar(MAX)));
		DECLARE @patternLength int = LEN(@pattern);  

		IF @replacedLength < @actualLength BEGIN 
		
			-- account for @pattern being 1 or more spaces: 
			IF @patternLength = 0 AND DATALENGTH(LTRIM(@pattern)) = 0 
				SET @patternLength = DATALENGTH(@pattern) / 2;
			
			IF @patternLength > 0
				SET @output =  (@actualLength - @replacedLength) / @patternLength;
		END;
		
		RETURN @output;
	END; 
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.kill_connections_by_hostname','P') IS NOT NULL
	DROP PROC dbo.kill_connections_by_hostname;
GO

CREATE PROC dbo.kill_connections_by_hostname
	@HostName				sysname, 
	@Interval				sysname			= '3 seconds', 
	@MaxIterations			int				= 5, 

-- TODO: Add error-handling AND reporting... along with options to 'run silent' and so on... 
--		as in, there are going to be some cases where we automate this, and it should raise errors if it can't kill all spids owned by @HostName... 
--			and, at other times... we won't necessarily care... (and just want the tool to do 'ad hoc' kills of a single host-name - without having to have all of the 'plumbing' needed for Mail Profiles, Operators, Etc... 
	@PrintOnly				int				= 0
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	IF UPPER(HOST_NAME()) = UPPER(@HostName) BEGIN 
		RAISERROR('Invalid HostName - You can''t KILL spids owned by the host running this stored procedure.', 16, 1);
		RETURN -1;
	END;

	DECLARE @waitFor sysname
	DECLARE @error nvarchar(MAX);

	EXEC dbo.[translate_vector_delay]
	    @Vector = @Interval,
	    @ParameterName = N'@Interval',
	    @Output = @waitFor OUTPUT,
	    @Error = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1);
		RETURN -10;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 	
	DECLARE @statement nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	DECLARE @currentIteration int = 0; 
	WHILE (@currentIteration < @MaxIterations) BEGIN
		
		SET @statement = N''; 

		SELECT 
			@statement = @statement + N'KILL ' + CAST(session_id AS sysname) + N';'  + @crlf
		FROM 
			[master].sys.[dm_exec_sessions] 
		WHERE 
			[host_name] = @HostName;
		
		IF @PrintOnly = 1 BEGIN 
			PRINT N'--------------------------------------';
			PRINT @statement; 
			PRINT @crlf;
			PRINT N'WAITFOR DELAY ' + @waitFor; 
			PRINT @crlf;
			PRINT @crlf;
		  END; 
		ELSE BEGIN 
			EXEC (@statement);
			WAITFOR DELAY @waitFor;
		END;

		SET @currentIteration += 1;
	END; 

	-- then... report on any problems/errors.

	RETURN 0;
GO	


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NOT NULL
	DROP PROC dbo.execute_uncatchable_command;
GO

CREATE PROC dbo.execute_uncatchable_command
	@Statement				varchar(4000), 
	@FilterType				varchar(20), 
	@Result					varchar(4000)			OUTPUT	
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Dependencies:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:

	IF @FilterType NOT IN (N'BACKUP',N'RESTORE',N'CREATEDIR',N'ALTER',N'DROP',N'DELETEFILE', N'UN-STANDBY') BEGIN;
		RAISERROR('Configuration Error: Invalid @FilterType specified.', 16, 1);
		SET @Result = 'Configuration Problem with dbo.execute_uncatchable_command.';
		RETURN -1;
	END 

	DECLARE @filters table (
		filter_text varchar(200) NOT NULL, 
		filter_type varchar(20) NOT NULL
	);

	INSERT INTO @filters (filter_text, filter_type)
	VALUES 
	-- BACKUP:
	('Processed % pages for database %', 'BACKUP'),
	('BACKUP DATABASE successfully processed % pages in %','BACKUP'),
	('BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %', 'BACKUP'),
	('BACKUP LOG successfully processed % pages in %', 'BACKUP'),
	('BACKUP DATABASE...FILE=<name> successfully processed % pages in % seconds %).', 'BACKUP'), -- for file/filegroup backups
	('The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %', 'BACKUP'),  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 

	-- RESTORE:
	('RESTORE DATABASE successfully processed % pages in %', 'RESTORE'),
	('RESTORE LOG successfully processed % pages in %', 'RESTORE'),
	('Processed % pages for database %', 'RESTORE'),
    ('DBCC execution completed. If DBCC printed error messages, contact your system administrator.', 'RESTORE'),  --  if CDC has been enabled (even if we're NOT running KEEP_CDC), recovery will throw in some sort of DBCC operation... 

		-- whenever there's a patch or upgrade...
	('Converting database % from version % to the current version %', 'RESTORE'), 
	('RESTORE DATABASE ... FILE=<name> successfully processed % pages in % seconds %).', N'RESTORE'),  -- partial recovery operations... 
	('Database % running the upgrade step from version % to version %.', 'RESTORE'),

	-- CREATEDIR:
	('Command(s) completed successfully.', 'CREATEDIR'), 

	-- ALTER:
	('Command(s) completed successfully.', 'ALTER'),
	('Nonqualified transactions are being rolled back. Estimated rollback completion%', 'ALTER'), 

	-- DROP:
	('Command(s) completed successfully.', 'DROP'),

	-- DELETEFILE:
	('Command(s) completed successfully.','DELETEFILE'),

	-- UN-STANDBY (i.e., pop a db out of STANDBY and into NORECOVERY... 
	('RESTORE DATABASE successfully processed % pages in % seconds%', 'UN-STANDBY'),
	('Command(s) completed successfully.', N'UN-STANDBY')

	-- add other filters here as needed... 
	;

	DECLARE @delimiter nchar(4) = N' -> ';

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @command varchar(2000) = 'sqlcmd {0} -q "' + REPLACE(@Statement, @crlf, ' ') + '"';

	-- Account for named instances:
	DECLARE @serverName sysname = '';
	IF @@SERVICENAME <> N'MSSQLSERVER'
		SET @serverName = N' -S .\' + @@SERVICENAME;
		
	SET @command = REPLACE(@command, '{0}', @serverName);

	--PRINT @command;

	INSERT INTO #Results (result)
	EXEC master.sys.xp_cmdshell @command;

	DELETE r
	FROM 
		#Results r 
		INNER JOIN @filters x ON x.filter_type = @FilterType AND r.RESULT LIKE x.filter_text;

	IF EXISTS (SELECT NULL FROM #Results WHERE result IS NOT NULL) BEGIN;
		SET @Result = '';
		SELECT @Result = @Result + result + @delimiter FROM #Results WHERE result IS NOT NULL ORDER BY result_id;
		SET @Result = LEFT(@Result, LEN(@Result) - LEN(@delimiter));
	END

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.execute_command','P') IS NOT NULL
	DROP PROC dbo.execute_command;
GO

CREATE PROC dbo.execute_command
	@Command								nvarchar(MAX), 
	@ExecutionType							sysname						= N'EXEC',							-- { EXEC | SQLCMD | SHELL | PARTNER }
	@ExecutionAttemptsCount					int							= 2,								-- TOTAL number of times to try executing process - until either success (no error) or @ExecutionAttemptsCount reached. a value of 1 = NO retries... 
	@DelayBetweenAttempts					sysname						= N'5s',
	@IgnoredResults							nvarchar(2000)				= N'[COMMAND_SUCCESS]',				--  'comma, delimited, list of, wild%card, statements, to ignore, can include, [tokens]'. Allowed Tokens: [COMMAND_SUCCESS] | [USE_DB_SUCCESS] | [ROWS_AFFECTED] | [BACKUP] | [RESTORE] | [SHRINKLOG] | [DBCC] ... 
    @PrintOnly                              bit                         = 0,
	@Results								xml							OUTPUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	IF @ExecutionAttemptsCount <= 0 SET @ExecutionAttemptsCount = 1;

    IF @ExecutionAttemptsCount > 0 

    IF UPPER(@ExecutionType) NOT IN (N'EXEC', N'SQLCMD', N'SHELL', N'PARTNER') BEGIN 
        RAISERROR(N'Permitted @ExecutionType values are { EXEC | SQLCMD | SHELL | PARTNER }.', 16, 1);
        RETURN -2;
    END; 

	-- if @ExecutionType = PARTNER, make sure we have a PARTNER entry in sys.servers... 


	-- for SQLCMD, SHELL, and PARTNER... final 'statement' needs to be varchar(4000) or less. 


    -- validate @DelayBetweenAttempts (if required/present):
    IF @ExecutionAttemptsCount > 1 BEGIN
	    DECLARE @delay sysname; 
	    DECLARE @error nvarchar(MAX);
	    EXEC dbo.[translate_vector_delay]
	        @Vector = @DelayBetweenAttempts,
	        @ParameterName = N'@DelayBetweenAttempts',
	        @Output = @delay OUTPUT, 
	        @Error = @error OUTPUT;

	    IF @error IS NOT NULL BEGIN 
		    RAISERROR(@error, 16, 1);
		    RETURN -5;
	    END;
    END;

	-----------------------------------------------------------------------------
	-- Processing: 


	DECLARE @filters table (
		filter_type varchar(20) NOT NULL, 
		filter_text varchar(2000) NOT NULL
	); 
	
	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[USE_DB_SUCCESS]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('USE_DB_SUCCESS', 'Changed database context to ''%');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[USE_DB_SUCCESS]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[COMMAND_SUCCESS]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('COMMAND_SUCCESS', 'Command(s) completed successfully.');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[COMMAND_SUCCESS]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[ROWS_AFFECTED]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('ROWS_AFFECTED', '% rows affected)%');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[ROWS_AFFECTED]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[BACKUP]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('BACKUP', 'Processed % pages for database %'),
			('BACKUP', 'BACKUP DATABASE successfully processed % pages in %'),
			('BACKUP', 'BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %'),
			('BACKUP', 'BACKUP LOG successfully processed % pages in %'),
			('BACKUP', 'BACKUP DATABASE...FILE=<name> successfully processed % pages in % seconds %).'), -- for file/filegroup backups
			('BACKUP', 'The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %');  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[BACKUP]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[RESTORE]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('RESTORE', 'RESTORE DATABASE successfully processed % pages in %'),
			('RESTORE', 'RESTORE LOG successfully processed % pages in %'),
			('RESTORE', 'Processed % pages for database %'),
			('RESTORE', 'Converting database % from version % to the current version %'),    -- whenever there's a patch or upgrade... 
			('RESTORE', 'Database % running the upgrade step from version % to version %.'),	-- whenever there's a patch or upgrade... 
			('RESTORE', 'RESTORE DATABASE ... FILE=<name> successfully processed % pages in % seconds %).'),  -- partial recovery operations... 
            ('RESTORE', 'DBCC execution completed. If DBCC printed error messages, contact your system administrator.');  -- if CDC was enabled on source (even if we don't issue KEEP_CDC), some sort of DBCC command fires during RECOVERY.
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[RESTORE]', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[SINGLE_USER]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('SINGLE_USER', 'Nonqualified transactions are being rolled back. Estimated rollback completion%');
					
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[SINGLE_USER]', N'');
	END;

	INSERT INTO @filters ([filter_type], [filter_text])
	SELECT 'CUSTOM', [result] FROM dbo.[split_string](@IgnoredResults, N',', 1) WHERE LEN([result]) > 0;

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @result nvarchar(MAX);
	DECLARE @resultDetails table ( 
		result_id int IDENTITY(1,1) NOT NULL, 
		execution_time datetime NOT NULL DEFAULT (GETDATE()),
		result nvarchar(MAX) NOT NULL
	);

	DECLARE @xpCmd varchar(2000);
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @serverName sysname = '';
    DECLARE @execOutput int;

	IF UPPER(@ExecutionType) = N'SHELL' BEGIN
        SET @xpCmd = CAST(@Command AS varchar(2000));
    END;
    
    IF UPPER(@ExecutionType) IN (N'SQLCMD', N'PARTNER') BEGIN
        SET @xpCmd = 'sqlcmd {0} -q "' + REPLACE(CAST(@Command AS varchar(2000)), @crlf, ' ') + '"';
    
        IF UPPER(@ExecutionType) = N'SQLCMD' BEGIN 
		
		    IF @@SERVICENAME <> N'MSSQLSERVER'  -- Account for named instances:
			    SET @serverName = N' -S .\' + @@SERVICENAME;
		
		    SET @xpCmd = REPLACE(@xpCmd, '{0}', @serverName);
	    END; 

	    IF UPPER(@ExecutionType) = N'PARTNER' BEGIN 
		    SELECT @serverName = REPLACE([data_source], N'tcp:', N'') FROM sys.servers WHERE [name] = N'PARTNER';

		    SET @xpCmd = REPLACE(@xpCmd, '{0}', ' -S' + @serverName);
	    END; 
    END;
	
	DECLARE @ExecutionAttemptCount int = 0; -- set to 1 during first exectuion attempt:
	DECLARE @succeeded bit = 0;
    
ExecutionAttempt:
	
	SET @ExecutionAttemptCount = @ExecutionAttemptCount + 1;
	SET @result = NULL;

	BEGIN TRY 

		IF UPPER(@ExecutionType) = N'EXEC' BEGIN 
			
            SET @execOutput = NULL;

            IF @PrintOnly = 1 
                PRINT @Command 
            ELSE 
			    EXEC @execOutput = sp_executesql @Command; 

            IF @execOutput = 0
                SET @succeeded = 1;

		  END; 
		ELSE BEGIN 
			DELETE FROM #Results;

            IF @PrintOnly = 1
                PRINT @xpCmd 
            ELSE BEGIN
			    INSERT INTO #Results (result) 
			    EXEC master.sys.[xp_cmdshell] @xpCmd;

-- v6.5
-- don't delete... either: a) update to set column treat_as_handled = 1 or... b) just use a sub-select/filter in the following query... or something. 
--  either way, the idea is: 
--              we capture ALL output - and spit it out for review/storage/auditing/trtoubleshooting and so on. 
---                 but .. only certain outputs are treated as ERRORS or problems... 
			    DELETE r
			    FROM 
				    #Results r 
				    INNER JOIN @filters x ON (r.[result] LIKE x.[filter_text]) OR (r.[result] = x.[filter_text]);

			    IF EXISTS(SELECT NULL FROM [#Results] WHERE [result] IS NOT NULL) BEGIN 
				    SET @result = N'';
				    SELECT 
					    @result = @result + [result] + CHAR(13) + CHAR(10)
				    FROM 
					    [#Results] 
				    WHERE 
					    [result] IS NOT NULL
				    ORDER BY 
					    [result_id]; 
									
			      END;
			    ELSE BEGIN 
				    SET @succeeded = 1;
			    END;
            END;
		END;

	END TRY

	BEGIN CATCH 
		SET @result = N'EXCEPTION: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
	END CATCH;
	
	IF @result IS NOT NULL BEGIN 
		INSERT INTO @resultDetails ([result])
		VALUES 
			(@result);
	END; 

	IF @succeeded = 0 BEGIN 
		IF @ExecutionAttemptCount < @ExecutionAttemptsCount BEGIN 
			WAITFOR DELAY @delay; 
			GOTO ExecutionAttempt;
		END;
	END;  

	IF EXISTS(SELECT NULL FROM @resultDetails) BEGIN
		SELECT @Results = (SELECT 
			[result_id] [result/@id],  
            [execution_time] [result/@timestamp], 
            [result]
		FROM 
			@resultDetails 
		ORDER BY 
			[result_id]
		FOR XML PATH(''), ROOT('results'));
	END; 

	IF @succeeded = 1
		RETURN 0;

	RETURN 1;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.establish_directory','P') IS NOT NULL
	DROP PROC dbo.establish_directory;
GO

CREATE PROC dbo.establish_directory
    @TargetDirectory                nvarchar(100), 
    @PrintOnly                      bit                     = 0,
    @Error                          nvarchar(MAX)           OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN 
        SET @Error = N'The @TargetDirectory parameter for dbo.establish_directory may NOT be NULL or empty.';
        RETURN -1;
    END; 

    -- Normalize Path: 
    IF @TargetDirectory LIKE N'%\' OR @TargetDirectory LIKE N'%/'
        SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

    SET @Error = NULL;

    DECLARE @exists bit; 
    IF @PrintOnly = 1 BEGIN 
        SET @exists = 1;
         PRINT '-- Target Directory Check Requested for: [' + @TargetDirectory + N'].';
      END; 
    ELSE BEGIN 
        EXEC dbo.[check_paths] 
            @Path = @TargetDirectory, 
            @Exists = @exists OUTPUT;
    END;

    IF @exists = 1            
        RETURN 0; -- short-circuit. directory already exists.
    
    -- assume that we can/should be able to BUILD the path if it doesn't already exist: 
    DECLARE @command nvarchar(1000) = N'if not exist "' + @TargetDirectory + N'" mkdir "' + @TargetDirectory + N'"'; -- windows

    DECLARE @Results xml;
    DECLARE @outcome int;
    EXEC @outcome = dbo.[execute_command]
        @Command = @command, 
        @ExecutionType = N'SHELL',
        @ExecutionAttemptsCount = 1,
        @IgnoredResults = N'',
        @PrintOnly = @PrintOnly,
        @Results = @Results OUTPUT;

    IF @outcome = 0 
        RETURN 0;  -- success. either the path existed, or we created it (with no issues).
    
    SELECT @Error = CAST(@Results.value(N'(/results/result)[1]', N'nvarchar(MAX)') AS nvarchar(MAX));
    SET @Error = ISNULL(@Error, N'#S4_UNKNOWN_ERROR#');

    RETURN -1;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_database_names','P') IS NOT NULL
	DROP PROC dbo.load_backup_database_names;
GO

CREATE PROC dbo.load_backup_database_names 
	@TargetDirectory				sysname				= N'{DEFAULT}',		
	@SerializedOutput				xml					= N'<default/>'					OUTPUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	-- EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF UPPER(@TargetDirectory) = N'{DEFAULT}' BEGIN
		SELECT @TargetDirectory = dbo.load_default_path('BACKUP');
	END;

	IF @TargetDirectory IS NULL BEGIN;
		RAISERROR('@TargetDirectory must be specified - and must point to a valid path.', 16, 1);
		RETURN - 10;
	END

	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN
		RAISERROR(N'Specified @TargetDirectory is invalid - check path and retry.', 16, 1);
		RETURN -11;
	END;

	-----------------------------------------------------------------------------
	-- load databases from path/folder names:
	DECLARE @target_databases TABLE ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 

	DECLARE @directories table (
		row_id int IDENTITY(1,1) NOT NULL, 
		subdirectory sysname NOT NULL, 
		depth int NOT NULL
	);

    INSERT INTO @directories (subdirectory, depth)
    EXEC master.sys.xp_dirtree @TargetDirectory, 1, 0;

    INSERT INTO @target_databases ([database_name])
    SELECT subdirectory FROM @directories ORDER BY row_id;

	-- NOTE: if @AddServerNameToSystemBackupPath was added to SYSTEM backups... then master, model, msdb, etc... folders WILL exist. (But there won't be FULL_<dbname>*.bak files in those subfolders). 
	--		In this sproc we WILL list any 'folders' for system databases found (i.e., we're LISTING databases - not getting the actual backups or paths). 
	--		However, in dbo.restore_databases if the @TargetPath + N'\' + @dbToRestore doesn't find any files, and @dbToRestore is a SystemDB, we'll look in @TargetPath + '\' + @ServerName + '\' + @dbToRestore for <backup_type>_<db_name>*.bak/.trn etc.)... 

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY... 
		SELECT @SerializedOutput = (SELECT 
			[row_id] [database/@id],
			[database_name] [database]
		FROM 
			@target_databases
		ORDER BY 
			[row_id] 
		FOR XML PATH(''), ROOT('databases'));

		RETURN 0;
	END; 

	-----------------------------------------------------------------------------
	-- otherwise, project:

	SELECT 
		[database_name]
	FROM 
		@target_databases
	ORDER BY 
		[row_id];

	RETURN 0;
GO




-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.shred_string','P') IS NOT NULL
	DROP PROC dbo.shred_string
GO

CREATE PROC dbo.shred_string
	@Input						nvarchar(MAX), 
	@RowDelimiter				nvarchar(10) = N',', 
	@ColumnDelimiter			nvarchar(10) = N':'
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @rows table ( 
		[row_id] int,
		[result] nvarchar(200)
	);

	INSERT INTO @rows ([row_id], [result])
	SELECT [row_id], [result] 
	FROM [dbo].[split_string](@Input, @RowDelimiter, 1);

	DECLARE @columnCountMax int = 0;

	SELECT 
		@columnCountMax = 1 + MAX(dbo.count_matches([result], @ColumnDelimiter)) 
	FROM 
		@rows;

	--SELECT @columnCountMax;
	--SELECT * FROM @rows;

	--DECLARE @pivoted table ( 
	CREATE TABLE #pivoted (
		row_id int NOT NULL, 
		[column_id] int NOT NULL, 
		[result] sysname NULL
	);

	DECLARE @currentRow nvarchar(200); 
	DECLARE @currentRowID int = 1;

	SET @currentRow = (SELECT [result] FROM @rows WHERE [row_id] = @currentRowID);
	WHILE (@currentRow IS NOT NULL) BEGIN 

		INSERT INTO #pivoted ([row_id], [column_id], [result])
		SELECT @currentRowID, row_id, [result] FROM [dbo].[split_string](@currentRow, @ColumnDelimiter, 1);

		SET @currentRowID = @currentRowID + 1;
		SET @currentRow = (SELECT [result] FROM @rows WHERE [row_id] = @currentRowID);
	END; 

	DECLARE @sql nvarchar(MAX) = N'
	WITH tally AS ( 
		SELECT TOP (@columnCountMax)
			ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
		FROM sys.all_objects o1 
	), 
	transposed AS ( 
		SELECT
			p.row_id,
			CAST(N''column_'' AS varchar(20)) + RIGHT(CAST(''00'' AS varchar(20)) + CAST(t.n AS varchar(20)), 2) [column_name], 
			p.[result]
		FROM 
			#pivoted p
			INNER JOIN [tally] t ON p.[column_id] = t.n 
	)

	SELECT 
		[row_id], 
		{columns}
	FROM 
		(
			SELECT 
				t.row_id, 
				t.column_name, 
				t.result 
			FROM 
				[transposed] t
			--ORDER BY 
			--	t.[row_id], t.[column_name]
		) x 
	PIVOT ( MAX([result]) 
		FOR [column_name] IN ({columns})		
	) p; ';

	DECLARE @columns nvarchar(200) = N'';

	WITH tally AS ( 
		SELECT TOP (@columnCountMax)
			ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
		FROM sys.all_objects o1 
	)

	SELECT @columns = @columns + N'[' + CAST(N'column_' AS varchar(20)) + RIGHT(CAST('00' AS varchar(20)) + CAST(t.n AS varchar(20)), 2) + N'], ' FROM tally t;
	SET @columns = LEFT(@columns, LEN(@columns) - 1);

	SET @sql = REPLACE(@sql, N'{columns}', @columns); 

	EXEC [sys].[sp_executesql]
		@stmt = @sql, 
		@params = N'@columnCountMax int', 
		@columnCountMax = @columnCountMax;


	RETURN 0;

GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.print_long_string','P') IS NOT NULL
	DROP PROC dbo.print_long_string;
GO

CREATE PROC dbo.print_long_string 
	@Input				nvarchar(MAX)
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @totalLen int;
	SELECT @totalLen = LEN(@Input);

	IF @totalLen < 4000 BEGIN 
		PRINT @Input;
		RETURN 0; -- done
	END 

	DECLARE @chunkLocation int = 0;
	DECLARE @substring nvarchar(4000);

	WHILE @chunkLocation <= @totalLen BEGIN 
		SET @substring = SUBSTRING(@Input, @chunkLocation, 4000);
		
		PRINT @substring;

		SET @chunkLocation += 4000;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.get_executing_dbname','P') IS NOT NULL
	DROP PROC dbo.[get_executing_dbname];
GO

CREATE PROC dbo.[get_executing_dbname]
    @ExecutingDBName                sysname         = N''      OUTPUT		-- note: NON-NULL default for RETURN or PROJECT convention... 
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    DECLARE @output sysname;
    DECLARE @resultCount int;
    DECLARE @options table (
        [db_name] sysname NOT NULL 
    ); 

    INSERT INTO @options ([db_name])
    SELECT 
        DB_NAME([resource_database_id]) [db_name]
        -- vNext... if I can link these (or any other columns) to something/anything in sys.dm_os_workers or sys.dm_os_tasks or ... anything ... 
        --      then I could 'know for sure'... 
        --          but, lock_owner_address ONLY maps to sys.dm_os_waiting_tasks ... and... we're NOT waiting... (well, the CALLER is not waiting).
        --, [lock_owner_address]
        --, [request_owner_lockspace_id]
    FROM 
        sys.[dm_tran_locks]
    WHERE 
        [request_session_id] = @@SPID
        AND [resource_database_id] <> DB_ID('admindb');
        
    SET @resultCount = @@ROWCOUNT;
    
    IF @resultCount > 1 BEGIN 
        RAISERROR('Could not determine executing database-name - multiple schema locks (against databases OTHER than admindb) are actively held by the current session_id.', 16, 1);
        RETURN -1;
    END;
    
    IF @resultCount < 1 BEGIN
        SET @output = N'admindb';
      END;
    ELSE BEGIN 
        SET @output = (SELECT TOP 1 [db_name] FROM @options);
    END;

    IF @ExecutingDBName IS NULL BEGIN 
		SET @ExecutingDBName = @output;
      END;
    ELSE BEGIN 
        SELECT @output [executing_db_name];
    END;

    RETURN 0; 
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_id_for_normalized_name','P') IS NOT NULL
	DROP PROC dbo.[load_id_for_normalized_name];
GO

CREATE PROC dbo.[load_id_for_normalized_name]
	@TargetName						sysname, 
	@ParameterNameForTarget			sysname			= N'@Target',
	@NormalizedName					sysname			OUTPUT, 
	@ObjectID						int				OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
	DECLARE @targetObjectId int;
	DECLARE @sql nvarchar(MAX);

	SELECT 
		@targetDatabase = PARSENAME(@TargetName, 3), 
		@targetSchema = ISNULL(PARSENAME(@TargetName, 2), N'dbo'), 
		@targetObjectName = PARSENAME(@TargetName, 1);
	
	IF @targetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		
		IF @targetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. Please use dbname.schemaname.objectname qualified names.', 16, 1, @ParameterNameForTarget);
			RETURN -5;
		END;
	END;

	SET @sql = N'SELECT @targetObjectId = [object_id] FROM [' + @targetDatabase + N'].sys.objects WHERE schema_id = SCHEMA_ID(@targetSchema) AND [name] = @targetObjectName; ';

	EXEC [sys].[sp_executesql]
		@sql, 
		N'@targetSchema sysname, @targetObjectName sysname, @targetObjectId int OUTPUT', 
		@targetSchema = @targetSchema, 
		@targetObjectName = @targetObjectName, 
		@targetObjectId = @targetObjectId OUTPUT;

	IF @targetObjectId IS NULL BEGIN 
		RAISERROR(N'Invalid Table Name specified for %s. Please use dbname.schemaname.objectname qualified names.', 16, 1, @ParameterNameForTarget);
		RETURN -10;
	END;

	SET @ObjectID = @targetObjectId;
	SET @NormalizedName = QUOTENAME(@targetDatabase) + N'.' + QUOTENAME(@targetSchema) + N'.' + QUOTENAME(@targetObjectName);

	RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Backups:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('[dbo].[remove_backup_files]','P') IS NOT NULL
	DROP PROC [dbo].[remove_backup_files];
GO

CREATE PROC [dbo].[remove_backup_files] 
	@BackupType							sysname,									-- { ALL|FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),								-- { {READ_FROM_FILESYSTEM} | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,						-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000) = N'{DEFAULT}',				-- { path_to_backups }
	@Retention							nvarchar(10),								-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@ServerNameInSystemBackupPath		bit = 0,									-- for mirrored servers/etc.
	@SendNotifications					bit	= 0,									-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
    @Output								nvarchar(MAX) = N'default' OUTPUT,			-- When explicitly set to NULL, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@PrintOnly							bit = 0 									-- { 0 | 1 }
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN;
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN;
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;
	
	IF ((@PrintOnly = 0) OR (NULLIF(@Output, N'default') IS NULL)) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN; 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN;
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@TargetDirectory) = N'{DEFAULT}' BEGIN
		SELECT @TargetDirectory = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG', 'ALL') BEGIN;
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	SET @Retention = LTRIM(RTRIM(REPLACE(@Retention, N' ', N'')));

	DECLARE @retentionType char(1);
	DECLARE @retentionValue bigint;
	DECLARE @retentionError nvarchar(MAX);
	DECLARE @retentionCutoffTime datetime; 

	IF UPPER(@Retention) = N'INFINITE' BEGIN 
		PRINT N'-- INFINITE retention detected. Terminating cleanup process.';
		RETURN 0; -- success
	END;

	IF UPPER(@Retention) LIKE 'B%' OR UPPER(@Retention) LIKE '%BACKUP%' BEGIN 
		-- Backups to be kept by # of backups NOT by timestamp
		DECLARE @boundary int = PATINDEX(N'%[^0-9]%', @Retention)- 1;

		IF @boundary < 1 BEGIN 
			SET @retentionError = N'Invalid Vector format specified for parameter @Retention. Format must be in ''XX nn'' or ''XXnn'' format - where XX is an ''integer'' duration (e.g., 72) and nn is an interval-specifier (e.g., HOUR, HOURS, H, or h).';
			RAISERROR(@retentionError, 16, 1);
			RETURN -1;
		END;

		BEGIN TRY

			SET @retentionValue = CAST((LEFT(@Retention, @boundary)) AS int);
		END TRY
		BEGIN CATCH
			SET @retentionValue = -1;
		END CATCH

		IF @retentionValue < 0 BEGIN 
			RAISERROR('Invalid @Retention value specified. Number of Backups specified was formatted incorrectly or < 0.', 16, 1);
			RETURN -25;
		END;

		SET @retentionType = 'b';
	  END;
	ELSE BEGIN 

		EXEC dbo.[translate_vector_datetime]
		    @Vector = @Retention, 
		    @Operation = N'SUBTRACT', 
		    @ValidationParameterName = N'@Retention', 
		    @ProhibitedIntervals = N'BACKUP', 
		    @Output = @retentionCutoffTime OUTPUT, 
		    @Error = @retentionError OUTPUT;

		IF @retentionError IS NOT NULL BEGIN 
			RAISERROR(@retentionError, 16, 1);
			RETURN -26;
		END;
	END;

	DECLARE @routeInfoAsOutput bit = 0;
	IF @Output IS NULL
		SET @routeInfoAsOutput = 1; 

	IF @PrintOnly = 1 AND @routeInfoAsOutput = 1 BEGIN
		IF @retentionType = 'b'
			PRINT '-- Retention specification is to keep the last ' + CAST(@retentionValue AS sysname) + ' backup(s).';
		ELSE 
			PRINT '-- Retention specification is to remove backups older than [' + CONVERT(sysname, @retentionCutoffTime, 120) + N'].';
	END;

	-- normalize paths: 
	IF(RIGHT(@TargetDirectory, 1) = '\')
		SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

	-- verify that path exists:
	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		RAISERROR('Invalid @TargetDirectory specified - either the path does not exist, or SQL Server''s Service Account does not have permissions to access the specified directory.', 16, 1);
		RETURN -10;
	END

	-----------------------------------------------------------------------------
	SET @Output = NULL;

	DECLARE @excludeSimple bit = 0;

	IF @BackupType = N'LOG'
		SET @excludeSimple = 1;

	-- If the {READ_FROM_FILESYSTEM} token is specified, replace {READ_FROM_FILESYSTEM} in @DatabasesToRestore with a serialized list of db-names pulled from @BackupRootPath:
	IF ((SELECT dbo.[count_matches](@DatabasesToProcess, N'{READ_FROM_FILESYSTEM}')) > 0) BEGIN
		DECLARE @databases xml = NULL;
		DECLARE @serialized nvarchar(MAX) = '';

		EXEC dbo.[load_backup_database_names]
		    @TargetDirectory = @TargetDirectory,
		    @SerializedOutput = @databases OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@databases.nodes('//database') [data]([row])
		) 

		SELECT 
			@serialized = @serialized + [database_name] + N','
		FROM 
			shredded 
		ORDER BY 
			row_id;

		SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);

        SET @databases = NULL;
		EXEC dbo.load_backup_database_names
			@TargetDirectory = @TargetDirectory, 
			@SerializedOutput = @databases OUTPUT;

		SET @DatabasesToProcess = REPLACE(@DatabasesToProcess, N'{READ_FROM_FILESYSTEM}', @serialized); 
	END;

	DECLARE @targetDirectories table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [directory_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDirectories ([directory_name])
	EXEC dbo.list_databases
	    @Targets = @DatabasesToProcess,
	    @Exclusions = @DatabasesToExclude,
		@ExcludeSimpleRecovery = @excludeSimple;

	-----------------------------------------------------------------------------
	-- Account for backups of system databases with the server-name in the path:  
	IF @ServerNameInSystemBackupPath = 1 BEGIN
		
		-- simply add additional/'duplicate-ish' directories to check for anything that's a system database:
		DECLARE @serverName sysname = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 

		-- and, note that IF we hand off the name of an invalid directory (i.e., say admindb backups are NOT being treated as system - so that D:\SQLBackups\admindb\SERVERNAME\ was invalid, then xp_dirtree (which is what's used to query for files) will simply return 'empty' results and NOT throw errors.
		INSERT INTO @targetDirectories (directory_name)
		SELECT 
			directory_name + @serverName 
		FROM 
			@targetDirectories
		WHERE 
			directory_name IN (N'master', N'msdb', N'model', N'admindb'); 

	END;

	-----------------------------------------------------------------------------
	-- Process files for removal:

	DECLARE @currentDirectory sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @targetPath nvarchar(512);
	DECLARE @outcome varchar(4000);
	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @file nvarchar(512);

	DECLARE @files table (
		id int IDENTITY(1,1),
		subdirectory nvarchar(512), 
		depth int, 
		isfile bit
	);

	DECLARE @lastN table ( 
		id int IDENTITY(1,1) NOT NULL, 
		original_id int NOT NULL, 
		backup_name nvarchar(512), 
		backup_type sysname
	);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL
	);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		directory_name
	FROM 
		@targetDirectories
	ORDER BY 
		[entry_id];

	OPEN processor;

	FETCH NEXT FROM processor INTO @currentDirectory;

	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @targetPath = @TargetDirectory + N'\' + @currentDirectory;

		SET @errorMessage = NULL;
		SET @outcome = NULL;

		IF @retentionType = 'b' BEGIN -- Remove all backups of target type except the most recent N (where N is @retentionValue).
			
			-- clear out any state from previous iterations.
			DELETE FROM @files;
			DELETE FROM @lastN;

			SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

			IF @PrintOnly = 1 AND @routeInfoAsOutput = 1
				PRINT N'--' + @command;

			INSERT INTO @files (subdirectory, depth, isfile)
			EXEC sys.sp_executesql @command;

			-- Remove non-matching files/entries:
			DELETE FROM @files WHERE isfile = 0; -- remove directories.

			IF @BackupType IN ('LOG', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'LOG'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'LOG%.trn'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN
					DELETE FROM @files WHERE subdirectory NOT LIKE '%.trn';  -- if we're NOT doing all, then remove DIFF and FULL backups... 
				END;
			END;

			IF @BackupType IN ('FULL', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'FULL'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'FULL%.bak'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN 
					DELETE FROM @files WHERE subdirectory NOT LIKE 'FULL%.bak'; -- if we're NOT doing all, then remove all non-FULL backups...  
				END
			END;

			IF @BackupType IN ('DIFF', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'DIFF'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'DIFF%.bak'
				ORDER BY 
					id DESC;

					IF @BackupType != 'ALL' BEGIN 
						DELETE FROM @files WHERE subdirectory NOT LIKE 'DIFF%.bak'; -- if we're NOT doing all, the remove non-DIFFs so they won't be nuked.
					END
			END;
			
			-- prune any/all files we're supposed to keep: 
			DELETE x 
			FROM 
				@files x 
				INNER JOIN @lastN l ON x.id = l.original_id AND x.subdirectory = l.backup_name;

			-- and delete all, enumerated, files that are left:
			DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT subdirectory FROM @files ORDER BY id;

			OPEN nuker;
			FETCH NEXT FROM nuker INTO @file;

			WHILE @@FETCH_STATUS = 0 BEGIN;

				-- reset per each 'grab':
				SET @errorMessage = NULL;
				SET @outcome = NULL

				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), GETDATE(), 120), ' ', 'T') + ''', 0;';

				IF @PrintOnly = 1 AND @routeInfoAsOutput = 1
					PRINT @command;
				ELSE BEGIN; 

					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting backup [' + @file + N'] from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					END CATCH

				END;

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END

				FETCH NEXT FROM nuker INTO @file;

			END;

			CLOSE nuker;
			DEALLOCATE nuker;
		  END;
		ELSE BEGIN -- Any backups older than @RetentionCutoffTime are removed. 

			IF @BackupType IN ('LOG', 'ALL') BEGIN;
			
				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + ''', N''trn'', N''' + REPLACE(CONVERT(nvarchar(20), @retentionCutoffTime, 120), ' ', 'T') + ''', 1;';

				IF @PrintOnly = 1 AND @routeInfoAsOutput = 1
					PRINT @command;
				ELSE BEGIN 
					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;

						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting older LOG backups from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					END CATCH;				
				END

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + N' [Command: ' + @command + N']';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END
			END

			IF @BackupType IN ('FULL', 'DIFF', 'ALL') BEGIN;

				-- start by clearing any previous values:
				DELETE FROM @files;
				SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

				IF @PrintOnly = 1 AND @routeInfoAsOutput = 1
					PRINT N'--' + @command;

				INSERT INTO @files (subdirectory, depth, isfile)
				EXEC sys.sp_executesql @command;

				DELETE FROM @files WHERE isfile = 0; -- remove directories.
				DELETE FROM @files WHERE subdirectory NOT LIKE '%.bak'; -- remove (from processing) any files that don't use the .bak extension. 

				-- If a specific backup type is specified ONLY target that backup type:
				IF @BackupType != N'ALL' BEGIN;
				
					IF @BackupType = N'FULL'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'FULL%';

					IF @BackupType = N'DIFF'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'DIFF%';
				END

				DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
				SELECT subdirectory FROM @files WHERE isfile = 1 AND subdirectory NOT LIKE '%.trn' ORDER BY id;

				OPEN nuker;
				FETCH NEXT FROM nuker INTO @file;

				WHILE @@FETCH_STATUS = 0 BEGIN;

					-- reset per each 'grab':
					SET @errorMessage = NULL;
					SET @outcome = NULL

					SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), @retentionCutoffTime, 120), ' ', 'T') + ''', 0;';

					IF @PrintOnly = 1 AND @routeInfoAsOutput = 1
						PRINT @command;
					ELSE BEGIN; 

						BEGIN TRY
							EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
							IF @outcome IS NOT NULL 
								SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

						END TRY 
						BEGIN CATCH
							SET @errorMessage = ISNULL(@errorMessage, '') +  N'Error deleting DIFF/FULL Backup with command: [' + ISNULL(@command, '##NOT SET YET##') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
						END CATCH

					END;

					IF @errorMessage IS NOT NULL BEGIN;
						SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

						INSERT INTO @errors ([error_message])
						VALUES (@errorMessage);
					END

					FETCH NEXT FROM nuker INTO @file;
				END;

				CLOSE nuker;
				DEALLOCATE nuker;

		    END
		END;

		FETCH NEXT FROM processor INTO @currentDirectory;
	END

	CLOSE processor;
	DEALLOCATE processor;

	-----------------------------------------------------------------------------
	-- Cleanup:
	IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
		CLOSE nuker;
		DEALLOCATE nuker;
	END;

	-----------------------------------------------------------------------------
	-- Error Reporting:
	DECLARE @errorInfo nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	IF EXISTS (SELECT NULL FROM @errors) BEGIN;
		
		-- format based on output type (output variable or email/error-message), then 'raise, return, or send'... 
		IF @routeInfoAsOutput = 1 BEGIN;
			SELECT @errorInfo = @errorInfo + [error_message] + N', ' FROM @errors ORDER BY error_id;
			SET @errorInfo = LEFT(@errorInfo, LEN(@errorInfo) - 2);

			SET @Output = @errorInfo;
		  END
		ELSE BEGIN;

			SELECT @errorInfo = @errorInfo + @tab + N'- ' + [error_message] + @crlf + @crlf
			FROM 
				@errors
			ORDER BY 
				error_id;

			IF (@SendNotifications = 1) AND (@Edition != 'EXPRESS') BEGIN;
				DECLARE @emailSubject nvarchar(2000);
				SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

				SET @errorInfo = N'The following errors were encountered: ' + @crlf + @errorInfo;

				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @errorInfo;				
			END

			-- this is being executed as a stand-alone job (most likely) so... throw the output into the job's history... 
			PRINT @errorInfo;  
			
			RAISERROR(@errorMessage, 16, 1);
			RETURN -100;
		END
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.remove_offsite_backup_files','P') IS NOT NULL
	DROP PROC dbo.[remove_offsite_backup_files];
GO

CREATE PROC dbo.[remove_offsite_backup_files]
	@BackupType							sysname,														-- { ALL|FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),													-- { {READ_FROM_FILESYSTEM} | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600)				= NULL,								-- { NULL | name1,name2 }  
	@OffSiteBackupPath					nvarchar(2000)				= NULL,								-- { path_to_backups }
	@OffSiteRetention					nvarchar(10),													-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@ServerNameInSystemBackupPath		bit							= 0,								-- for mirrored servers/etc.
	@SendNotifications					bit							= 0,								-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname						= N'Alerts',		
	@MailProfileName					sysname						= N'General',
	@EmailSubjectPrefix					nvarchar(50)				= N'[OffSite Backups Cleanup ] ',
    @Output								nvarchar(MAX)				= N'default' OUTPUT,				-- When explicitly set to NULL, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@PrintOnly							bit							= 0 								-- { 0 | 1 }

AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	IF UPPER(@OffSiteRetention) = N'INFINITE' BEGIN 
		PRINT N'-- INFINITE retention detected. Terminating off-site cleanup process.';
		RETURN 0; -- success
	END;

	PRINT N'NON-INFINITE Retention-cleanup off OffSite Backup Copies is not yet implemented.';
	
	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.backup_databases','P') IS NOT NULL
	DROP PROC dbo.backup_databases;
GO

CREATE PROC dbo.backup_databases 
	@BackupType							sysname,																-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(MAX),															-- { {SYSTEM} | {USER} |name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX)							= NULL,							-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX)							= NULL,							-- { higher,priority,dbs,*,lower,priority,dbs } - where * represents dbs not specifically specified (which will then be sorted alphabetically
	@BackupDirectory					nvarchar(2000)							= N'{DEFAULT}',					-- { {DEFAULT} | path_to_backups }
	@CopyToBackupDirectory				nvarchar(2000)							= NULL,							-- { NULL | path_for_backup_copies } NOTE {PARTNER} allowed as a token (if a PARTNER is defined).
	@OffSiteBackupPath					nvarchar(2000)							= NULL,							-- e.g., N'S3:\\bucket-name\path\'
	@BackupRetention					nvarchar(10),															-- [DOCUMENT HERE]
	@CopyToRetention					nvarchar(10)							= NULL,							-- [DITTO: As above, but allows for diff retention settings to be configured for copied/secondary backups.]
	@OffSiteRetention					nvarchar(10)							= NULL,							-- { vector | n backups | infinite }
	@RemoveFilesBeforeBackup			bit										= 0,							-- { 0 | 1 } - when true, then older backups will be removed BEFORE backups are executed.
	@EncryptionCertName					sysname									= NULL,							-- Ignored if not specified. 
	@EncryptionAlgorithm				sysname									= NULL,							-- Required if @EncryptionCertName is specified. AES_256 is best option in most cases.
	@AddServerNameToSystemBackupPath	bit										= 0,							-- If set to 1, backup path is: @BackupDirectory\<db_name>\<server_name>\
	@AllowNonAccessibleSecondaries		bit										= 0,							-- If review of @DatabasesToBackup yields no dbs (in a viable state) for backups, exception thrown - unless this value is set to 1 (for AGs, Mirrored DBs) and then execution terminates gracefully with: 'No ONLINE dbs to backup'.
	@Directives							nvarchar(400)							= NULL,							-- { COPY_ONLY | FILE:logical_file_name | FILEGROUP:file_group_name }  - NOTE: NOT mutually exclusive. Also, MULTIPLE FILE | FILEGROUP directives can be specified - just separate with commas. e.g., FILE:secondary, FILE:tertiarty. 
	@LogSuccessfulOutcomes				bit										= 0,							-- By default, exceptions/errors are ALWAYS logged. If set to true, successful outcomes are logged to dba_DatabaseBackup_logs as well.
	@OperatorName						sysname									= N'Alerts',
	@MailProfileName					sysname									= N'General',
	@EmailSubjectPrefix					nvarchar(50)							= N'[Database Backups ] ',
	@PrintOnly							bit										= 0								-- Instead of EXECUTING commands, they're printed to the console only. 	
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = N'WEB';

		IF @@VERSION LIKE '%Workgroup Edition%' SET @Edition = N'WORKGROUP';
	END;
	
	IF @Edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF (@PrintOnly = 0) AND (@Edition != 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@BackupDirectory) = N'{DEFAULT}' BEGIN
		SELECT @BackupDirectory = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@BackupDirectory, N'') IS NULL BEGIN
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG') BEGIN
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	IF UPPER(@DatabasesToBackup) = N'{READ_FROM_FILESYSTEM}' BEGIN
		RAISERROR('@DatabasesToBackup may NOT be set to the token {READ_FROM_FILESYSTEM} when processing backups.', 16, 1);
		RETURN -9;
	END

-- TODO: I really need to validate retention details HERE... i.e., BEFORE we start running backups. 
--		not sure of the best way to do that - i.e., short of copy/paste of the logic (here and there).

-- honestly, probably makes the most sense to push validation into a scalar UDF. the UDF returns a string/error or NULL (if there's nothing wrong). That way, both sprocs can use the validation details easily. 

	--IF (DATEADD(MINUTE, 0 - @fileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN 
	--	 RAISERROR('Invalid @BackupRetentionHours - greater than or equal to NOW.', 16, 1);
	--	 RETURN -10;
	--END;

	--IF NULLIF(@CopyToBackupDirectory, '') IS NOT NULL BEGIN
	--	IF (DATEADD(MINUTE, 0 - @copyToFileRetentionMinutes, GETDATE())) >= GETDATE() BEGIN
	--		RAISERROR('Invalid @CopyToBackupRetentionHours - greater than or equal to NOW.', 16, 1);
	--		RETURN -11;
	--	END;
	--END;

	IF (SELECT dbo.[count_matches](@CopyToBackupDirectory, N'{PARTNER}')) > 0 BEGIN 

		IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = N'PARTNER') BEGIN
			RAISERROR('THe {PARTNER} token can only be used in the @CopyToBackupDirectory if/when a PARTNER server has been registered as a linked server.', 16, 1);
			RETURN -20;
		END;

		DECLARE @partnerName sysname; 
		EXEC sys.[sp_executesql]
			N'SET @partnerName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE [is_linked] = 0 ORDER BY [server_id]);', 
			N'@partnerName sysname OUTPUT', 
			@partnerName = @partnerName OUTPUT;

		SET @CopyToBackupDirectory = REPLACE(@CopyToBackupDirectory, N'{PARTNER}', @partnerName);
	END;

	IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
		IF (CHARINDEX(N'[', @EncryptionCertName) > 0) OR (CHARINDEX(N']', @EncryptionCertName) > 0) 
			SET @EncryptionCertName = REPLACE(REPLACE(@EncryptionCertName, N']', N''), N'[', N'');
		
		-- make sure the cert name is legit and that an encryption algorithm was specified:
		IF NOT EXISTS (SELECT NULL FROM master.sys.certificates WHERE name = @EncryptionCertName) BEGIN
			RAISERROR('Certificate name specified by @EncryptionCertName is not a valid certificate (not found in sys.certificates).', 16, 1);
			RETURN -15;
		END;

		IF NULLIF(@EncryptionAlgorithm, '') IS NULL BEGIN
			RAISERROR('@EncryptionAlgorithm must be specified when @EncryptionCertName is specified.', 16, 1);
			RETURN -15;
		END;
	END;

	DECLARE @isCopyOnlyBackup bit = 0;
	DECLARE @fileOrFileGroupDirective nvarchar(2000) = '';

	IF NULLIF(@Directives, N'') IS NOT NULL BEGIN
		SET @Directives = LTRIM(RTRIM(@Directives));
		
		IF UPPER(@Directives) = N'COPY_ONLY' SET @Directives = N'COPY_ONLY:';  -- yeah, it's a hack... but meh.

		DECLARE @allDirectives table ( 
			row_id int NOT NULL, 
			directive_type	sysname NOT NULL, 
			logical_name sysname NULL 
		);

		INSERT INTO @allDirectives ([row_id], [directive_type], [logical_name])
		EXEC dbo.[shred_string]
			@input = @Directives, 
			@rowDelimiter = N',', 
			@columnDelimiter = N':';

		IF NOT EXISTS (SELECT NULL FROM @allDirectives WHERE (UPPER([directive_type]) = N'COPY_ONLY') OR (UPPER([directive_type]) = N'FILE') OR (UPPER([directive_type]) = N'FILEGROUP')) BEGIN
			RAISERROR(N'Invalid @Directives value specified. Permitted values are { COPY_ONLY | FILE:logical_name | FILEGROUP:group_name } only.', 16, 1);
			RETURN -20;
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE UPPER([directive_type]) = N'COPY_ONLY') BEGIN 
			IF UPPER(@BackupType) = N'DIFF' BEGIN
				-- NOTE: COPY_ONLY DIFF backups won't throw an error (in SQL Server) but they're a logical 'fault' - hence the S4 warning: https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql?view=sql-server-2017
				RAISERROR(N'Invalid @Directives value specified. COPY_ONLY can NOT be specified when @BackupType = DIFF. Only FULL and LOG backups may be COPY_ONLY (and should be used only for one-off testing or other specialized needs.', 16, 1);
				RETURN -21;
			END; 

			SET @isCopyOnlyBackup = 1;
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE (UPPER([directive_type]) = N'FILE') OR (UPPER([directive_type]) = N'FILEGROUP')) BEGIN 

			SELECT 
				@fileOrFileGroupDirective = @fileOrFileGroupDirective + directive_type + N' = ''' + [logical_name] + N''', '
			FROM 
				@allDirectives
			WHERE 
				(UPPER([directive_type]) = N'FILE') OR (UPPER([directive_type]) = N'FILEGROUP')
			ORDER BY 
				row_id;

			SET @fileOrFileGroupDirective = NCHAR(13) + NCHAR(10) + NCHAR(9) + LEFT(@fileOrFileGroupDirective, LEN(@fileOrFileGroupDirective) -1) + NCHAR(13) + NCHAR(10)+ NCHAR(9) + NCHAR(9);
		END;
	END;

	IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
		IF @OffSiteBackupPath NOT LIKE 'S3::%' BEGIN 
			RAISERROR('S3 Backups are the only OffSite Backup Types currently supported. Please use the format S3::bucket-name:path\sub-path', 16, 1);
			RETURN -200;
		END;
	END;

	-----------------------------------------------------------------------------
	DECLARE @excludeSimple bit = 0;

	IF UPPER(@BackupType) = N'LOG'
		SET @excludeSimple = 1;

	-- Determine which databases to backup:
	DECLARE @targetDatabases table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDatabases ([database_name])
	EXEC dbo.list_databases
	    @Targets = @DatabasesToBackup,
	    @Exclusions = @DatabasesToExclude,
		@Priorities = @Priorities,
		-- NOTE: @ExcludeSecondaries, @ExcludeRecovering, @ExcludeRestoring, @ExcludeOffline ALL default to 1 - meaning that, for backups, we want the default (we CAN'T back those databases up no matter how much we want). (Well, except for secondaries...hmm).
		@ExcludeSimpleRecovery = @excludeSimple;

	-- verify that we've got something: 
	IF (SELECT COUNT(*) FROM @targetDatabases) <= 0 BEGIN
		IF @AllowNonAccessibleSecondaries = 1 BEGIN
			-- Because we're dealing with Mirrored DBs, we won't fail or throw an error here. Instead, we'll just report success (with no DBs to backup).
			PRINT 'No ONLINE databases available for backup. BACKUP terminating with success.';
			RETURN 0;

		   END; 
		ELSE BEGIN
			PRINT 'Usage: @DatabasesToBackup = {SYSTEM}|{USER}|dbname1,dbname2,dbname3,etc';
			RAISERROR('No databases specified for backup.', 16, 1);
			RETURN -20;
		END;
	END;

	IF @BackupDirectory = @CopyToBackupDirectory BEGIN
		RAISERROR('@BackupDirectory and @CopyToBackupDirectory can NOT be the same directory.', 16, 1);
		RETURN - 50;
	END;

	-- normalize paths: 
	IF(RIGHT(@BackupDirectory, 1) = N'\')
		SET @BackupDirectory = LEFT(@BackupDirectory, LEN(@BackupDirectory) - 1);

	IF(RIGHT(ISNULL(@CopyToBackupDirectory, N''), 1) = N'\')
		SET @CopyToBackupDirectory = LEFT(@CopyToBackupDirectory, LEN(@CopyToBackupDirectory) - 1);

	IF(RIGHT(ISNULL(@OffSiteBackupPath, N''), 1) = N'\')
		SET @OffSiteBackupPath = LEFT(@OffSiteBackupPath, LEN(@OffSiteBackupPath) - 1);

	IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
		DECLARE @s3BucketName sysname; 
		DECLARE @s3KeyPath sysname;
		DECLARE @s3FullFileKey sysname;
		DECLARE @s3fullOffSitePath sysname;

		DECLARE @s3Parts table (row_id int NOT NULL, result nvarchar(MAX) NOT NULL);

		INSERT INTO @s3Parts (
			[row_id],
			[result]
		)
		SELECT [row_id], [result] FROM dbo.[split_string](REPLACE(@OffSiteBackupPath, N'S3::', N''), N':', 1)

		SELECT @s3BucketName = [result] FROM @s3Parts WHERE [row_id] = 1;
		SELECT @s3KeyPath = [result] FROM @s3Parts WHERE [row_id] = 2;
	END;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- meta-data:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @operationStart datetime;
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @copyMessage nvarchar(MAX);
	DECLARE @currentOperationID int;

	DECLARE @currentDatabase sysname;
	DECLARE @backupPath nvarchar(2000);
	DECLARE @copyToBackupPath nvarchar(2000);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @serverName sysname;
	DECLARE @extension sysname;
	DECLARE @now datetime;
	DECLARE @timestamp sysname;
	DECLARE @offset sysname;
	DECLARE @backupName sysname;
	DECLARE @encryptionClause nvarchar(2000);
	DECLARE @copyStart datetime;
	DECLARE @outcome varchar(4000);

	DECLARE @offSiteCopyStart datetime;
	DECLARE @offSiteCopyMessage nvarchar(MAX);

	DECLARE @command nvarchar(MAX);

	-- Begin the backups:
	DECLARE backups CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name] 
	FROM 
		@targetDatabases
	ORDER BY 
		[entry_id];

	OPEN backups;

	FETCH NEXT FROM backups INTO @currentDatabase;
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @errorMessage = NULL;
		SET @copyMessage = NULL;
		SET @outcome = NULL;
		SET @currentOperationID = NULL;

-- TODO: Full details here: https://overachieverllc.atlassian.net/browse/S4-107
-- TODO: this logic is duplicated in dbo.list_databases. And, while we NEED this check here ... the logic should be handled in a UDF or something - so'z there aren't 2x locations for bugs/issues/etc. 
		-- start by making sure the current DB (which we grabbed during initialization) is STILL online/accessible (and hasn't failed over/etc.): 
		DECLARE @synchronized table ([database_name] sysname NOT NULL);
		INSERT INTO @synchronized ([database_name])
		SELECT [name] FROM sys.databases WHERE UPPER(state_desc) <> N'ONLINE';  -- mirrored dbs that have failed over and are now 'restoring'... 

		-- account for SQL Server 2008/2008 R2 (i.e., pre-HADR):
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @synchronized ([database_name])
			EXEC sp_executesql N'SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc != ''PRIMARY'';'	
		END

		IF @currentDatabase IN (SELECT [database_name] FROM @synchronized) BEGIN
			PRINT 'Skipping database: ' + @currentDatabase + ' because it is no longer available, online, or accessible.';
			GOTO NextDatabase;  -- just 'continue' - i.e., short-circuit processing of this 'loop'... 
		END; 

		-- specify and verify path info:
		IF ((SELECT dbo.[is_system_database](@currentDatabase)) = 1) AND @AddServerNameToSystemBackupPath = 1
			SET @serverName = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 
		ELSE 
			SET @serverName = N'';

		SET @backupPath = @BackupDirectory + N'\' + @currentDatabase + @serverName;
		SET @copyToBackupPath = REPLACE(@backupPath, @BackupDirectory, @CopyToBackupDirectory); 

		SET @operationStart = GETDATE();
		IF (@LogSuccessfulOutcomes = 1) AND (@PrintOnly = 0)  BEGIN
			INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start)
			VALUES(@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart);
			
			SELECT @currentOperationID = SCOPE_IDENTITY();
		END;

		IF @RemoveFilesBeforeBackup = 1 BEGIN
			GOTO RemoveOlderFiles;  -- zip down into the logic for removing files, then... once that's done... we'll get sent back up here (to DoneRemovingFilesBeforeBackup) to execute the backup... 

DoneRemovingFilesBeforeBackup:
		END

        SET @outcome = NULL;
		BEGIN TRY
            EXEC dbo.establish_directory
                @TargetDirectory = @backupPath, 
                @PrintOnly = @PrintOnly,
                @Error = @outcome OUTPUT;

			IF @outcome IS NOT NULL
				SET @errorMessage = ISNULL(@errorMessage, '') + N' Error verifying directory: [' + @backupPath + N']: ' + @outcome;

		END TRY
		BEGIN CATCH 
			SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception attempting to validate file path for backup: [' + @backupPath + N']. Error: [' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N']. Backup Filepath non-valid. Cannot continue with backup.';
		END CATCH;

		-- Normally, it wouldn't make sense to 'bail' on backups simply because we couldn't remove an older file. But, when the directive is to RemoveFilesBEFORE backups, we have to 'bail' to avoid running out of disk space when we can't delete files BEFORE backups. 
		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		-- Create a Backup Name: 
		SET @extension = N'.bak';
		IF @BackupType = N'LOG'
			SET @extension = N'.trn';

		SET @now = GETDATE();
		SET @timestamp = REPLACE(REPLACE(REPLACE(CONVERT(sysname, @now, 120), '-','_'), ':',''), ' ', '_');
		SET @offset = RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),7);

		SET @backupName = @BackupType + N'_' + @currentDatabase + (CASE WHEN @fileOrFileGroupDirective = '' THEN N'' ELSE N'_PARTIAL' END) + '_backup_' + @timestamp + '_' + @offset + @extension;

		SET @command = N'BACKUP {type} ' + QUOTENAME(@currentDatabase) + N'{FILE|FILEGROUP} TO DISK = N''' + @backupPath + N'\' + @backupName + ''' 
	WITH 
		{COPY_ONLY}{COMPRESSION}{DIFFERENTIAL}{MAXTRANSFER}{ENCRYPTION}NAME = N''' + @backupName + ''', SKIP, REWIND, NOUNLOAD, CHECKSUM;
	
	';

		IF @BackupType IN (N'FULL', N'DIFF')
			SET @command = REPLACE(@command, N'{type}', N'DATABASE');
		ELSE 
			SET @command = REPLACE(@command, N'{type}', N'LOG');

		IF @Edition IN (N'EXPRESS',N'WEB',N'WORKGROUP') OR ((SELECT dbo.[get_engine_version]()) < 10.5 AND @Edition NOT IN ('ENTERPRISE'))
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'');
		ELSE 
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'COMPRESSION, ');

		IF @BackupType = N'DIFF'
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'DIFFERENTIAL, ');
		ELSE 
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'');

		IF @isCopyOnlyBackup = 1 
			SET @command = REPLACE(@command, N'{COPY_ONLY}', N'COPY_ONLY, ');
		ELSE 
			SET @command = REPLACE(@command, N'{COPY_ONLY}', N'');

		IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
			SET @encryptionClause = ' ENCRYPTION (ALGORITHM = ' + ISNULL(@EncryptionAlgorithm, N'AES_256') + N', SERVER CERTIFICATE = ' + ISNULL(@EncryptionCertName, '') + N'), ';
			SET @command = REPLACE(@command, N'{ENCRYPTION}', @encryptionClause);
		  END;
		ELSE 
			SET @command = REPLACE(@command, N'{ENCRYPTION}','');

		-- Account for TDE and 2016+ Compression: 
		IF EXISTS (SELECT NULL FROM sys.[dm_database_encryption_keys] WHERE [database_id] = DB_ID(@currentDatabase) AND [encryption_state] <> 0) BEGIN 

			IF (SELECT dbo.[get_engine_version]()) > 13.0
				SET @command = REPLACE(@command, N'{MAXTRANSFER}', N'MAXTRANSFERSIZE = 2097152, ');
			ELSE BEGIN 
				-- vNEXT / when adding processing-bus implementation and 'warnings' channel... output the following into WARNINGS: 
				PRINT 'Disabling Database Compression for database [' + @currentDatabase + N'] because TDE is enabled on pre-2016 SQL Server instance.';
				SET @command = REPLACE(@command, N'COMPRESSION, ', N'');
				SET @command = REPLACE(@command, N'{MAXTRANSFER}', N'');
			END;
		  END;
		ELSE BEGIN 
			SET @command = REPLACE(@command, N'{MAXTRANSFER}', N'');
		END;

		-- account for 'partial' backups: 
		SET @command = REPLACE(@command, N'{FILE|FILEGROUP}', @fileOrFileGroupDirective);

		IF @PrintOnly = 1
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				SET @outcome = NULL;
				EXEC dbo.execute_uncatchable_command @command, 'BACKUP', @Result = @outcome OUTPUT;

				IF @outcome IS NOT NULL
					SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception executing backup with the following command: [' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH;
		END;

		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		IF @LogSuccessfulOutcomes = 1 BEGIN
			UPDATE dbo.backup_log 
			SET 
				backup_end = GETDATE(),
				backup_succeeded = 1, 
				verification_start = GETDATE()
			WHERE 
				backup_id = @currentOperationID;
		END;

		-----------------------------------------------------------------------------
		-- Kick off the verification:
		SET @command = N'RESTORE VERIFYONLY FROM DISK = N''' + @backupPath + N'\' + @backupName + N''' WITH NOUNLOAD, NOREWIND;';

		IF @PrintOnly = 1 
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				EXEC sys.sp_executesql @command;

				IF @LogSuccessfulOutcomes = 1 BEGIN
					UPDATE dbo.backup_log
					SET 
						verification_end = GETDATE(),
						verification_succeeded = 1
					WHERE
						backup_id = @currentOperationID;
				END;
			END TRY
			BEGIN CATCH
				SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected exception during backup verification for backup of database: ' + @currentDatabase + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';

					UPDATE dbo.backup_log
					SET 
						verification_end = GETDATE(),
						verification_succeeded = 0,
						error_details = @errorMessage
					WHERE
						backup_id = @currentOperationID;

				GOTO NextDatabase;
			END CATCH;
		END;

		-----------------------------------------------------------------------------
		-- Now that the backup (and, optionally/ideally) verification are done, copy the file to a secondary location if specified:
		IF NULLIF(@CopyToBackupDirectory, N'') IS NOT NULL BEGIN
			
			SET @copyStart = GETDATE();
            SET @copyMessage = NULL;

            BEGIN TRY 
                EXEC dbo.establish_directory
                    @TargetDirectory = @copyToBackupPath, 
                    @PrintOnly = @PrintOnly,
                    @Error = @outcome OUTPUT;                

                IF @outcome IS NOT NULL
				    SET @errorMessage = ISNULL(@errorMessage, '') + N' Error verifying COPY_TO directory: ' + @copyToBackupPath + N': ' + @copyMessage;   

            END TRY
            BEGIN CATCH 
                SET @copyMessage = N'Unexpected exception attempting to validate COPY_TO file path for backup: [' + @copyToBackupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N'. Detail: [' + ISNULL(@copyMessage, '') + N']';
            END CATCH

			-- if we didn't run into validation errors, we can go ahead and try the copyTo process: 
			IF @copyMessage IS NULL BEGIN

				DECLARE @copyOutput table ([output] nvarchar(2000));
				DELETE FROM @copyOutput;

				-- XCOPY supported on Windows 2003+; robocopy is supported on Windows 2008+
				SET @command = 'EXEC xp_cmdshell ''XCOPY "' + @backupPath + N'\' + @backupName + '" "' + @copyToBackupPath + '\"''';

				IF @PrintOnly = 1
					PRINT @command;
				ELSE BEGIN
					BEGIN TRY

						INSERT INTO @copyOutput ([output])
						EXEC sys.sp_executesql @command;

						IF NOT EXISTS(SELECT NULL FROM @copyOutput WHERE [output] LIKE '%1 file(s) copied%') BEGIN; -- there was an error, and we didn't copy the file.
							SET @copyMessage = ISNULL(@copyMessage, '') + (SELECT TOP 1 [output] FROM @copyOutput WHERE [output] IS NOT NULL AND [output] NOT LIKE '%0 file(s) copied%') + N' ';
						END;

						IF @LogSuccessfulOutcomes = 1 BEGIN 
							UPDATE dbo.backup_log
							SET 
								copy_succeeded = 1,
								copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
								failed_copy_attempts = 0
							WHERE
								backup_id = @currentOperationID;
						END;
					END TRY
					BEGIN CATCH

						SET @copyMessage = ISNULL(@copyMessage, '') + N'Unexpected error copying backup to [' + @copyToBackupPath + @serverName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
					END CATCH;
				END;
		    END;

			IF @copyMessage IS NOT NULL BEGIN

				IF @currentOperationID IS NULL BEGIN
					-- if we weren't logging successful operations, this operation isn't now a 100% failure, but there are problems, so we need to create a row for reporting/tracking purposes:
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(),0);

					SELECT @currentOperationID = SCOPE_IDENTITY();
				END

				UPDATE dbo.backup_log
				SET 
					copy_succeeded = 0, 
					copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
					failed_copy_attempts = 1, 
					copy_details = @copyMessage, 
					[error_details] = CASE WHEN [error_details] IS NULL THEN N'File Copy Failure.' ELSE 'File Copy Failure. ' + [error_details] END
				WHERE 
					backup_id = @currentOperationID;
			END;
		END;

		-----------------------------------------------------------------------------
		-- Process @OffSite backups as necessary: 
		IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
			
			SET @offSiteCopyStart = GETDATE();
			SET @offSiteCopyMessage = NULL; 

			DECLARE @offsiteCopy table ([row_id] int IDENTITY(1, 1) NOT NULL, [output] nvarchar(2000));
			DELETE FROM @offsiteCopy;

			SET @s3FullFileKey = @s3KeyPath + '\' + @currentDatabase + N'\' + @backupName;
			SET @s3fullOffSitePath = N'S3::' + @s3BucketName + N':' + @s3FullFileKey;

			SET @command = 'EXEC xp_cmdshell ''PowerShell.exe -Command "Write-S3Object -BucketName ''''' + @s3BucketName + ''''' -Key ''''' + @s3FullFileKey + ''''' -File ''''' + @backupPath + '\' + @backupName + ''''' " ''; ';

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN 
				BEGIN TRY
					INSERT INTO @offsiteCopy ([output])
					EXEC sys.sp_executesql @command;

					DELETE FROM @offsiteCopy WHERE [output] IS NULL;

					IF EXISTS (SELECT NULL FROM @offsiteCopy) BEGIN -- error, which we need to capture/document:
						SET @offSiteCopyMessage = N'ERROR: ';
						SELECT 
							@offSiteCopyMessage = @offSiteCopyMessage + [output] + @crlf
						FROM 
							@offsiteCopy 
						ORDER BY 
							[row_id];
					END;

					IF @LogSuccessfulOutcomes = 1 BEGIN 
						UPDATE dbo.backup_log
						SET 
							offsite_path = @s3fullOffSitePath,
							offsite_succeeded = 1,
							offsite_seconds = DATEDIFF(SECOND, @offSiteCopyStart, GETDATE()), 
							failed_offsite_attempts = 0
						WHERE
							backup_id = @currentOperationID;
					END;

				END TRY
				BEGIN CATCH

					SET @offSiteCopyMessage = ISNULL(@offSiteCopyMessage, N'') + N'Unexpected error copying backup to OffSite Location [' + @s3fullOffSitePath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
				END CATCH;
			END;
			
			IF @offSiteCopyMessage IS NOT NULL BEGIN
				IF @currentOperationID IS NULL BEGIN
					-- if we weren't already logging successful outcomes, need to create a new entry for this failure/problem:
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, offsite_path, backup_start, backup_end, backup_succeeded)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @s3fullOffSitePath, @operationStart, GETDATE(),0);
					
					SELECT @currentOperationID = SCOPE_IDENTITY();
				END

				UPDATE dbo.backup_log
				SET 
					offsite_succeeded = 0, 
					offsite_seconds = DATEDIFF(SECOND, @offSiteCopyStart, GETDATE()), 
					failed_offsite_attempts = 1, 
					offsite_details = @offSiteCopyMessage, 
					[error_details] = CASE WHEN [error_details] IS NULL THEN N'OffSite File Copy Failure.' ELSE 'OffSite File Copy Failure. ' + [error_details] END
				WHERE 
					backup_id = @currentOperationID;				
			END;
		END;

		-----------------------------------------------------------------------------
		-- Remove backups:
		-- Branch into this logic either by means of a GOTO (called from above) or by means of evaluating @RemoveFilesBeforeBackup.... 
		IF @RemoveFilesBeforeBackup = 0 BEGIN;
			
RemoveOlderFiles:
			BEGIN TRY

				IF @PrintOnly = 1 BEGIN;
					PRINT '-- EXEC dbo.remove_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @BackupDirectory + ''', @Retention = ''' + @BackupRetention + ''', @ServerNameInSystemBackupPath = ' + CAST(@AddServerNameToSystemBackupPath AS sysname) + N',  @PrintOnly = 1;';
					
                    EXEC dbo.remove_backup_files
                        @BackupType= @BackupType,
                        @DatabasesToProcess = @currentDatabase,
                        @TargetDirectory = @BackupDirectory,
                        @Retention = @BackupRetention, 
						@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile,

						-- note:
                        @PrintOnly = 1;

				  END;
				ELSE BEGIN;
					SET @outcome = NULL;
					DECLARE @Output nvarchar(MAX);
					EXEC dbo.remove_backup_files
						@BackupType= @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@TargetDirectory = @BackupDirectory,
						@Retention = @BackupRetention,
						@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile, 
						@Output = @outcome OUTPUT;

					IF @outcome IS NOT NULL 
						SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + ' ';

				END

				IF NULLIF(@CopyToBackupDirectory,'') IS NOT NULL BEGIN;
				
					IF @PrintOnly = 1 BEGIN;
						PRINT '-- EXEC dbo.remove_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @TargetDirectory = ''' + @CopyToBackupDirectory + ''', @Retention = ''' + @CopyToRetention + ''', @ServerNameInSystemBackupPath = ' + CAST(@AddServerNameToSystemBackupPath AS sysname) + N',  @PrintOnly = 1;';
						
						EXEC dbo.remove_backup_files
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@Retention = @CopyToRetention, 
							@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
							@OperatorName = @OperatorName,
							@MailProfileName  = @DatabaseMailProfile,

							--note:
							@PrintOnly = 1;

					  END;
					ELSE BEGIN;
						SET @outcome = NULL;
					
						EXEC dbo.remove_backup_files
							@BackupType= @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@TargetDirectory = @CopyToBackupDirectory,
							@Retention = @CopyToRetention, 
							@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
							@OperatorName = @OperatorName,
							@MailProfileName  = @DatabaseMailProfile,
							@Output = @outcome OUTPUT;					
					
						IF @outcome IS NOT NULL
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
					END
				END

				IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 

					IF @PrintOnly = 1 BEGIN 
						PRINT '-- EXEC dbo.remove_offsite_backup_files @BackupType = ''' + @BackupType + ''', @DatabasesToProcess = ''' + @currentDatabase + ''', @OffSiteBackupPath = ''' + @OffSiteBackupPath + ''', @OffSiteRetention = ''' + @OffSiteRetention + ''', @ServerNameInSystemBackupPath = ' + CAST(@AddServerNameToSystemBackupPath AS sysname) + N',  @PrintOnly = 1;';
					  END; 
					ELSE BEGIN 
						SET @outcome = NULL;

						EXEC dbo.[remove_offsite_backup_files]
							@BackupType = @BackupType,
							@DatabasesToProcess = @currentDatabase,
							@OffSiteBackupPath = @OffSiteBackupPath,
							@OffSiteRetention = @OffSiteRetention,
							@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
							@OperatorName = @OperatorName,
							@MailProfileName = @DatabaseMailProfile,
							@Output = @outcome OUTPUT;
						
						IF @outcome IS NOT NULL
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';
					END;
				END;

			END TRY 
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + 'Unexpected Error removing backups. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
			END CATCH

			IF @RemoveFilesBeforeBackup = 1 BEGIN;
				IF @errorMessage IS NULL -- there weren't any problems/issues - so keep processing.
					GOTO DoneRemovingFilesBeforeBackup;

				-- otherwise, the remove operations failed, they were set to run FIRST, which means we now might not have enough disk - so we need to 'fail' this operation and move on to the next db... 
				GOTO NextDatabase;
			END
		END

NextDatabase:
		IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
			CLOSE nuker;
			DEALLOCATE nuker;
		END;

		IF NULLIF(@errorMessage,'') IS NOT NULL BEGIN;
			IF @PrintOnly = 1 
				PRINT @errorMessage;
			ELSE BEGIN;
				IF @currentOperationID IS NULL BEGIN;
					INSERT INTO dbo.backup_log (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, backup_end, backup_succeeded, error_details)
					VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, GETDATE(), 0, @errorMessage);
				  END;
				ELSE BEGIN;
					UPDATE dbo.backup_log
					SET 
						error_details = @errorMessage
					WHERE 
						backup_id = @currentOperationID;
				END;
			END;
		END; 

		PRINT '
';

		FETCH NEXT FROM backups INTO @currentDatabase;
	END;

	CLOSE backups;
	DEALLOCATE backups;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- Cleanup:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','backups')) > -1 BEGIN;
		CLOSE backups;
		DEALLOCATE backups;
	END;

	-- MKC:
--			need to add some additional logic/processing here. 
--			a) look for failed copy operations up to X hours ago? 
--		    b) try to re-run them - via dba_sync... or ... via 'raw' roboopy? hmmm. 
--			c) mark any that succeed as done... success. 
--			d) up-tick any that still failed. 
--			e) for any that exceed @maxCopyToRetries - create an error and log it against all previous rows/databases that have failed? hmmm. Yeah... if we've been failing for, say, 45 minutes and sending 'warnings'... then we want to 
--				'call it' for all of the ones that have failed up to this point... and flag them as 'errored out' (might require a new column in the table). OR... maybe it works by me putting something like the following into error details
--				(for ALL rows that have failed up to this point - i.e., previous attempts + the current attempt/iteration):
--				"Attempts to copy backups from @sourcePath to @copyToPath consistently failed from @backupEndTime to @now (duration?) over @MaxSomethingAttempts. No longer attempting to synchronize files - meaning that backups are in jeopardy. Please
--					fix @CopyToPath and, when complete, run dba_syncDbs with such and such arguments? to ensure dbs copied on to secondary...."
--			   because, if that happens... then... the 'history' for backups will show errors (whereas they didn't show/report errors previously - so that covers 'history' - with a summary of when we 'called it'... 
--				and, this covers... the current rows as well. i.e., they'll have errors... which will then get picked up by the logic below. 
--			f) for any true 'errors', those get picked up below. 
--			g) for any non-errors - but failures to copy, there needs to be a 'warning' email sent - with a summary (list) of each db that hasn't copied - current number of attempts, how long it's been, etc. 

	DECLARE @emailErrorMessage nvarchar(MAX);

	IF EXISTS (SELECT NULL FROM dbo.backup_log WHERE execution_id = @executionID AND error_details IS NOT NULL) BEGIN;
		SET @emailErrorMessage = N'BACKUP TYPE: ' + @BackupType + @crlf
			+ N'TARGETS: ' + @DatabasesToBackup + @crlf
			+ @crlf 
			+ N'The following errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Target Database: [' + [database] + N']. Error: ' + error_details + @crlf + @crlf
		FROM 
			dbo.backup_log
		WHERE 
			execution_id = @executionID
			AND error_details IS NOT NULL 
		ORDER BY 
			backup_id;

	END;

	DECLARE @emailSubject nvarchar(2000);
	IF @emailErrorMessage IS NOT NULL BEGIN;
		
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
		SET @emailErrorMessage = @emailErrorMessage + @crlf + @crlf + N'Execute [ SELECT * FROM [admindb].dbo.backup_log WHERE execution_id = ''' + CAST(@executionID AS nvarchar(36)) + N'''; ] for details.';

		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
			PRINT @emailErrorMessage;
		  END;
		ELSE BEGIN 

			IF @Edition <> 'EXPRESS' BEGIN;
				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @emailErrorMessage;
			END;

		END;
	END;

	RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Configuration:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.update_server_name','P') IS NOT NULL
	DROP PROC dbo.[update_server_name];
GO

CREATE PROC dbo.[update_server_name]
	@PrintOnly			bit				= 1
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @currentHostNameInWindows sysname;
	DECLARE @serverNameFromSysServers sysname; 

	SELECT
		@currentHostNameInWindows = CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS sysname),
		@serverNameFromSysServers = @@SERVERNAME;

	IF UPPER(@currentHostNameInWindows) <> UPPER(@serverNameFromSysServers) BEGIN
		DECLARE @oldServerName sysname = @serverNameFromSysServers;
		DECLARE @newServerName sysname = @currentHostNameInWindows;

		PRINT N'BIOS/Windows HostName: ' + @newServerName + N' does not match name defined within SQL Server: ' + @oldServerName + N'.';
		

		IF @PrintOnly = 0 BEGIN 

			PRINT N'Initiating update to SQL Server definitions.';
			
			EXEC sp_dropserver @oldServerName;
			EXEC sp_addserver @newServerName, local;

			PRINT N'SQL Server Server-Name set to ' + @newServerName + N'.';

			PRINT 'Please RESTART SQL Server to ensure that this change has FULLY taken effect.';

		END;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.script_login','P') IS NOT NULL
	DROP PROC dbo.[script_login];
GO

CREATE PROC dbo.[script_login]
    @LoginName                              sysname,       
    @BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
	@DisableExpiryChecks					bit						= 0, 
    @DisablePolicyChecks					bit						= 0,
	@ForceMasterAsDefaultDB					bit						= 0, 
	@IncludeDefaultLanguage					bit						= 0,
    @Output                                 nvarchar(MAX)           = ''        OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	DECLARE @name sysname, @loginType nvarchar(60);

	SELECT 
		@name = [name],
		@loginType = [type_desc]
	FROM 
		sys.[server_principals]
	WHERE
		[name] = @LoginName;

    IF @name IS NULL BEGIN 
        IF @Output IS NULL 
            SET @Output = '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';
        ELSE 
            PRINT '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';

        RETURN -2;
    END;

	DECLARE @result int;
	DECLARE @formatted nvarchar(MAX);

	IF @loginType = N'WINDOWS_LOGIN' BEGIN

		EXEC @result = dbo.[script_windows_login]
			@LoginName = @name,
			@BehaviorIfLoginExists = @BehaviorIfLoginExists,
			@ForceMasterAsDefaultDB = @ForceMasterAsDefaultDB,
			@IncludeDefaultLanguage = @IncludeDefaultLanguage,
			@Output = @formatted OUTPUT;
		
		IF @result <> 0 
			RETURN @result;

		GOTO ScriptCreated;
	END; 

	IF @loginType = N'SQL_LOGIN' BEGIN

		EXEC @result = dbo.[script_sql_login]
			@LoginName = @name,
			@BehaviorIfLoginExists = @BehaviorIfLoginExists,
			@DisableExpiryChecks = @DisableExpiryChecks,
			@DisablePolicyChecks = @DisablePolicyChecks,
			@ForceMasterAsDefaultDB = @ForceMasterAsDefaultDB,
			@IncludeDefaultLanguage = @IncludeDefaultLanguage,
			@Output = @formatted OUTPUT

		IF @result <> 0 
			RETURN @result;

		GOTO ScriptCreated;
	END; 

	-- If we're still here, we tried to script/print a login type that's not yet supported. 
	RAISERROR('Sorry, S4 does not yet support scripting ''%s'' logins.', 16, 1);
	RETURN -20;

ScriptCreated: 

    IF @Output IS NULL BEGIN 
        SET @Output = @formatted;
        RETURN 0;
    END;

    PRINT @formatted;
    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.script_logins','P') IS NOT NULL
	DROP PROC dbo.script_logins;
GO

CREATE PROC dbo.script_logins 
	@TargetDatabases						nvarchar(MAX)			= N'{ALL}',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@DatabasePriorities						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL,
	@ExcludeMSAndServiceLogins				bit						= 1,
	@BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
    @DisablePolicyChecks					bit						= 0,
	@DisableExpiryChecks					bit						= 0, 
	@ForceMasterAsDefaultDB					bit						= 0,
-- TODO: remove this functionality - and... instead, have a sproc that lists logins that have access to MULTIPLE databases... 
	@WarnOnLoginsHomedToOtherDatabases		bit						= 0				-- warns when a) set to 1, and b) default_db is NOT master NOR the current DB where the user is defined... (for a corresponding login).
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF NULLIF(@TargetDatabases,'') IS NULL 
        SET @TargetDatabases = N'{ALL}';

	DECLARE @ignoredDatabases table (
		[database_name] sysname NOT NULL
	);

	DECLARE @ingnoredLogins table (
		[login_name] sysname NOT NULL 
	);

	DECLARE @ingoredUsers table (
		[user_name] sysname NOT NULL
	);

	CREATE TABLE #Users (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[type] char(1) NOT NULL
	);

	CREATE TABLE #Orphans (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL
	);

	CREATE TABLE #Vagrants ( 
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[default_database] sysname NOT NULL
	);

	SELECT 
        CASE WHEN sp.[is_disabled] = 1 THEN 0 ELSE 1 END [enabled],
		sp.[name], 
		sp.[sid],
		sp.[type], 
		sp.[is_disabled], 
		sp.[default_database_name],
		sl.[password_hash], 
		sl.[is_expiration_checked], 
		sl.[is_policy_checked], 
		sp.[default_language_name]
	INTO 
		#Logins
	FROM 
		sys.[server_principals] sp
		LEFT OUTER JOIN sys.[sql_logins] sl ON sp.[sid] = sl.[sid]
	WHERE 
		sp.[type] NOT IN ('R');

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @output nvarchar(MAX);

	INSERT INTO @ignoredDatabases ([database_name])
	SELECT [result] [database_name] FROM dbo.[split_string](@ExcludedDatabases, N',', 1) ORDER BY row_id;

	INSERT INTO @ingnoredLogins ([login_name])
	SELECT [result] [login_name] FROM dbo.[split_string](@ExcludedLogins, N',', 1) ORDER BY row_id;

	IF @ExcludeMSAndServiceLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',', 1) ORDER BY row_id;		
	END;

	INSERT INTO @ingoredUsers ([user_name])
	SELECT [result] [user_name] FROM dbo.[split_string](@ExcludedUsers, N',', 1) ORDER BY row_id;

	-- remove ignored logins:
	DELETE l 
	FROM [#Logins] l
	INNER JOIN @ingnoredLogins i ON l.[name] LIKE i.[login_name];	
			
	DECLARE @currentDatabase sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @principalsTemplate nvarchar(MAX) = N'SELECT [name], [sid], [type] FROM [{0}].sys.database_principals WHERE type IN (''S'', ''U'') AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'')';

	DECLARE @dbsToWalk table ( 
		row_id int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL
	); 

	INSERT INTO @dbsToWalk ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@ExcludeSecondaries = 1,
		@ExcludeOffline = 1,
		@Priorities = @DatabasePriorities;

	DECLARE db_walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [database_name] FROM @dbsToWalk ORDER BY [row_id]; 

	OPEN [db_walker];
	FETCH NEXT FROM [db_walker] INTO @currentDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN

		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
		PRINT '-- DATABASE: ' + @currentDatabase 
		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'

		DELETE FROM [#Users];
		DELETE FROM [#Orphans];

		SET @command = REPLACE(@principalsTemplate, N'{0}', @currentDatabase); 
		INSERT INTO #Users ([name], [sid], [type])
		EXEC master.sys.sp_executesql @command;

		-- remove any ignored users: 
		DELETE u 
		FROM [#Users] u 
		INNER JOIN 
			@ingoredUsers i ON i.[user_name] LIKE u.[name];

		INSERT INTO #Orphans ([name], [sid])
		SELECT 
			u.[name], 
			u.[sid]
		FROM 
			#Users u 
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		WHERE
			l.[name] IS NULL OR l.[sid] IS NULL;

		SET @output = N'';

		-- Report on Orphans:
		SELECT @output = @output + 
			N'-- ORPHAN DETECTED: ' + [name] + N' (SID: ' + CONVERT(nvarchar(MAX), [sid], 2) + N')' + @crlf
		FROM 
			[#Orphans]
		ORDER BY 
			[name]; 

		IF NULLIF(@output, '') IS NOT NULL
			PRINT @output; 

		-- Report on differently-homed logins if/as directed:
		IF @WarnOnLoginsHomedToOtherDatabases = 1 BEGIN
			SET @output = N'';

			SELECT @output = @output +
				N'-- NOTE: Login ' + u.[name] + N' is set to use [' + l.[default_database_name] + N'] as its default database instead of [' + @currentDatabase + N'].'
			FROM 
				[#Users] u
				LEFT OUTER JOIN [#Logins] l ON u.[sid] = l.[sid]
			WHERE 
				u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
				AND u.[name] NOT IN (SELECT [name] FROM #Orphans)
				AND l.default_database_name <> 'master'  -- master is fine... 
				AND l.default_database_name <> @currentDatabase; 				
				
			IF NULLIF(@output, N'') IS NOT NULL 
				PRINT @output;
		END;

		-- Process 'logins only' logins (i.e., not mapped to any databases as users): 
		IF LOWER(@currentDatabase) = N'master' BEGIN

			CREATE TABLE #SIDs (
				[sid] varbinary(85) NOT NULL, 
				[database] sysname NOT NULL
				PRIMARY KEY CLUSTERED ([sid], [database]) -- WITH (IGNORE_DUP_KEY = ON) -- looks like an EXCEPT might be faster: https://dba.stackexchange.com/a/90003/6100
			);

			DECLARE @allDbsToWalk table ( 
				row_id int IDENTITY(1,1) NOT NULL, 
				[database_name] sysname NOT NULL
			);

			INSERT INTO @allDbsToWalk ([database_name])
			EXEC dbo.[list_databases]
				@Targets = N'{ALL}',  -- has to be all when looking for login-only logins
				@ExcludeSecondaries = 1,
				@ExcludeOffline = 1;

			DECLARE @sidTemplate nvarchar(MAX) = N'SELECT [sid], N''{0}'' [database] FROM [{0}].sys.database_principals WHERE [sid] IS NOT NULL;';
			DECLARE @sql nvarchar(MAX);

			DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
			SELECT [database_name] FROM @allDbsToWalk ORDER BY [row_id];

			DECLARE @dbName sysname; 

			OPEN [looper]; 
			FETCH NEXT FROM [looper] INTO @dbName;

			WHILE @@FETCH_STATUS = 0 BEGIN
		
				SET @sql = REPLACE(@sidTemplate, N'{0}', @dbName);

				INSERT INTO [#SIDs] ([sid], [database])
				EXEC sys.[sp_executesql] @sql;

				FETCH NEXT FROM [looper] INTO @dbName;
			END; 

			CLOSE [looper];
			DEALLOCATE [looper];

			SET @output = N'';
			
            SELECT 
                @output = @output + 
                CASE 
                    WHEN [l].[type] = N'S' THEN 
                        dbo.[format_sql_login] (
                            l.[enabled], 
                            @BehaviorIfLoginExists, 
                            l.[name], 
                            N'0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' ', 
                            N'0x' + CONVERT(nvarchar(MAX), l.[sid], 2), 
                            l.[default_database_name], 
                            l.[default_language_name], 
                            CASE WHEN @DisableExpiryChecks = 1 THEN 1 ELSE l.[is_expiration_checked] END,
                            CASE WHEN @DisablePolicyChecks = 1 THEN 1 ELSE l.[is_policy_checked] END
                         )
                    WHEN l.[type] IN (N'U', N'G') THEN 
                        dbo.[format_windows_login] (
                            l.[enabled], 
                            @BehaviorIfLoginExists, 
                            l.[name], 
                            l.[default_database_name], 
                            l.[default_language_name]
                        )
                    ELSE 
                        '-- CERTIFICATE and SYMMETRIC KEY login types are NOT currently supported. (Nor are Roles)'  -- i..e, C (cert), K (symmetric key) or R (role)
                END
                 + @crlf + N'GO' + @crlf
            FROM 
				[#Logins] l
			WHERE 
				l.[sid] NOT IN (SELECT [sid] FROM [#SIDs]);                

			IF NULLIF(@output, '') IS NOT NULL BEGIN 
				PRINT @output + @crlf;
			END 
		END; 

		-- Output LOGINS:
		SET @output = N'';

		SELECT 
            @output = @output + 
            CASE 
                WHEN [l].[type] = N'S' THEN 
                    dbo.[format_sql_login] (
                        l.[enabled], 
                        @BehaviorIfLoginExists, 
                        l.[name], 
                        N'0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' ', 
                        N'0x' + CONVERT(nvarchar(MAX), l.[sid], 2), 
                        l.[default_database_name], 
                        l.[default_language_name], 
                        CASE WHEN @DisableExpiryChecks = 1 THEN 1 ELSE l.[is_expiration_checked] END,
                        CASE WHEN @DisablePolicyChecks = 1 THEN 1 ELSE l.[is_policy_checked] END
                        )
                WHEN l.[type] IN (N'U', N'G') THEN 
                    dbo.[format_windows_login] (
                        l.[enabled], 
                        @BehaviorIfLoginExists, 
                        l.[name], 
                        l.[default_database_name], 
                        l.[default_language_name]
                    )
                ELSE 
                    '-- CERTIFICATE and SYMMETRIC KEY login types are NOT currently supported. (Nor are Roles)'  -- i..e, C (cert), K (symmetric key) or R (role)
            END
                + @crlf + N'GO' + @crlf
		FROM 
			#Users u
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		WHERE 
			u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
			AND u.[name] NOT IN (SELECT name FROM #Orphans);
			
		IF NULLIF(@output, N'') IS NOT NULL
			PRINT @output;

		PRINT @crlf;

		FETCH NEXT FROM [db_walker] INTO @currentDatabase;
	END; 

	CLOSE [db_walker];
	DEALLOCATE [db_walker];

	RETURN 0;
GO


-----------------------------------
USE [admindb];

IF OBJECT_ID('dbo.export_server_logins','P') IS NOT NULL
	DROP PROC dbo.export_server_logins;
GO

CREATE PROC dbo.export_server_logins
	@TargetDatabases						nvarchar(MAX)			= N'{ALL}',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@DatabasePriorities						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL,
	@OutputPath								nvarchar(2000)			= N'{DEFAULT}',
	@CopyToPath								nvarchar(2000)			= NULL, 	
	@ExcludeMSAndServiceLogins				bit						= 1,
	@DisablePolicyChecks					bit						= 0,
	@DisableExpiryChecks					bit						= 0, 
	@ForceMasterAsDefaultDB					bit						= 0,
	@WarnOnLoginsHomedToOtherDatabases		bit						= 0,
	@AddServerNameToFileName				bit						= 1,
	@OperatorName							sysname					= N'Alerts',
	@MailProfileName						sysname					= N'General',
	@EmailSubjectPrefix						nvarchar(50)			= N'[Login Exports] ',	 
	@PrintOnly								bit						= 0	
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;

	-----------------------------------------------------------------------------
	-- Input Validation:

	DECLARE @edition sysname;
	SELECT @edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @edition = N'STANDARD' OR @edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @edition = 'WEB';
	END;
	
	IF @edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF (@PrintOnly = 0) AND (@edition <> 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @databaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @databaseMailProfile OUT, @no_output = N'no_output';
 
		IF @databaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@OutputPath) = N'{DEFAULT}' BEGIN
		SELECT @OutputPath = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@OutputPath, N'') IS NULL BEGIN
		RAISERROR('@OutputPath cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF @PrintOnly = 1 BEGIN
		 
		EXEC dbo.[script_logins]  
		    @TargetDatabases = @TargetDatabases, 
		    @ExcludedDatabases = @ExcludedDatabases, 
		    @DatabasePriorities = @DatabasePriorities, 
		    @ExcludedLogins = @ExcludedLogins, 
		    @ExcludedUsers = @ExcludedUsers, 
		    @ExcludeMSAndServiceLogins = @ExcludeMSAndServiceLogins, 
		    @DisablePolicyChecks = @DisablePolicyChecks, 
		    @DisableExpiryChecks = @DisableExpiryChecks, 
		    @ForceMasterAsDefaultDB = @ForceMasterAsDefaultDB, 
		    @WarnOnLoginsHomedToOtherDatabases = @WarnOnLoginsHomedToOtherDatabases; 

		RETURN 0; 
	END; 

	-- if we're still here, we need to dynamically output/execute dbo.script_logins so that output is directed to a file (and copied if needed)
	--		while catching and alerting on any errors or problems. 

	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	-- normalize paths: 
	IF(RIGHT(@OutputPath, 1) = '\')
		SET @OutputPath = LEFT(@OutputPath, LEN(@OutputPath) - 1);

	IF(RIGHT(ISNULL(@CopyToPath, N''), 1) = '\')
		SET @CopyToPath = LEFT(@CopyToPath, LEN(@CopyToPath) - 1);

	DECLARE @outputFileName varchar(2000);
	SET @outputFileName = @OutputPath + '\' + CASE WHEN @AddServerNameToFileName = 1 THEN @@SERVERNAME + '_' ELSE '' END + N'Logins.sql';

	DECLARE @errors table ( 
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) 
	);

	DECLARE @xpCmdShellOutput table (
		result_id int IDENTITY(1,1) NOT NULL, 
		result nvarchar(MAX) NULL
	);

	-- Set up a 'translation' of the sproc call (for execution via xp_cmdshell): 
	DECLARE @sqlCommand varchar(MAX); 
	SET @sqlCommand = N'EXEC admindb.dbo.script_logins @TargetDatabases = N''{0}'', @ExcludedDatabases = N''{1}'', @DatabasePriorities = N''{2}'', @ExcludedLogins = N''{3}'', @ExcludedUsers = N''{4}'', '
		+ '@ExcludeMSAndServiceLogins = {5}, @DisablePolicyChecks = {6}, @DisableExpiryChecks = {7}, @ForceMasterAsDefaultDB = {8}, @WarnOnLoginsHomedToOtherDatabases = {9};';

	SET @sqlCommand = REPLACE(@sqlCommand, N'{0}', CAST(@TargetDatabases AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{1}', CAST(ISNULL(@ExcludedDatabases, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{2}', CAST(ISNULL(@DatabasePriorities, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{3}', CAST(ISNULL(@ExcludedLogins, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{4}', CAST(ISNULL(@ExcludedUsers, N'NULL') AS varchar(MAX)));
	SET @sqlCommand = REPLACE(@sqlCommand, N'{5}', CASE WHEN @ExcludeMSAndServiceLogins = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{6}', CASE WHEN @DisablePolicyChecks = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{7}', CASE WHEN @DisableExpiryChecks = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{8}', CASE WHEN @ForceMasterAsDefaultDB = 1 THEN '1' ELSE '0' END);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{9}', CASE WHEN @WarnOnLoginsHomedToOtherDatabases = 1 THEN '1' ELSE '0' END);

	IF LEN(@sqlCommand) > 8000 BEGIN 
		INSERT INTO @errors (error) VALUES ('Combined length of all input parameters to dbo.script_logins exceeds 8000 characters and can NOT be executed dynamically. Export of logins can not and did NOT proceed as expected.')
		GOTO REPORTING;
	END; 

	DECLARE @command varchar(8000) = 'sqlcmd {0} -q "{1}" -o "{2}"';

	-- replace parameters: 
	SET @command = REPLACE(@command, '{0}', CASE WHEN UPPER(@@SERVICENAME) = 'MSSQLSERVER' THEN '' ELSE ' -S .\' + UPPER(@@SERVICENAME) END);
	SET @command = REPLACE(@command, '{1}', @sqlCommand);
	SET @command = REPLACE(@command, '{2}', @outputFileName);

	BEGIN TRY

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL; 

		IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 
			SET @errorDetails = N'';
			SELECT 
				@errorDetails = @errorDetails + [result] + @crlf + @tab
			FROM 
				@xpCmdShellOutput 
			ORDER BY 
				[result_id];

			SET @errorDetails = N'Unexpected problem while attempting to write logins to disk: ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

			INSERT INTO @errors (error) VALUES (@errorDetails);
		END


		-- Verify that the file was written as expected: 
		SET @command = 'for %a in ("' + @outputFileName + '") do @echo %~ta';
		DELETE FROM @xpCmdShellOutput; 

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DECLARE @timeStamp datetime; 
		SELECT @timeStamp = MAX(CAST([result] AS datetime)) FROM @xpCmdShellOutput WHERE [result] IS NOT NULL;

		IF DATEDIFF(MINUTE, @timeStamp, GETDATE()) > 2 BEGIN 
			SET @errorDetails = N'TimeStamp for [' + @outputFileName + N'] reads ' + CONVERT(nvarchar(30), @timeStamp, 120) + N'. Current Execution Time is: ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'. File writing operations did NOT throw an error, but time-stamp difference shows ' + @outputFileName + N' file was NOT written as expected.' ;
			
			INSERT INTO @errors (error) VALUES (@errorDetails);
		END;

		-- copy the file if/as needed:
		IF @CopyToPath IS NOT NULL BEGIN

			DELETE FROM @xpCmdShellOutput;
			SET @command = 'COPY "{0}" "{1}\"';

			SET @command = REPLACE(@command, '{0}', @outputFileName);
			SET @command = REPLACE(@command, '{1}', @CopyToPath);

			INSERT INTO @xpCmdShellOutput ([result])
			EXEC master.sys.[xp_cmdshell] @command;

			DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL OR [result] LIKE '%1 file(s) copied.%'; 

			IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 

				SET @errorDetails = N'';
				SELECT 
					@errorDetails = @errorDetails + [result] + @crlf + @tab
				FROM 
					@xpCmdShellOutput 
				ORDER BY 
					[result_id];

				SET @errorDetails = N'Unexpected problem while copying file from @OutputPath to @CopyFilePath : ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

				INSERT INTO @errors (error) VALUES (@errorDetails);
			END 
		END;

	END TRY 
	BEGIN CATCH
		SET @errorDetails = N'Unexpected Exception while executing command: [' + ISNULL(@command, N'#ERROR#') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

		INSERT INTO @errors (error) VALUES (@errorDetails);
	END CATCH
	

REPORTING: 
	IF EXISTS (SELECT NULL FROM @errors) BEGIN
		DECLARE @emailErrorMessage nvarchar(MAX) = N'The following errors were encountered: ' + @crlf + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + N'- ' + [error] + @crlf
		FROM 
			@errors
		ORDER BY 
			error_id;

		DECLARE @emailSubject nvarchar(2000);
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
	
		IF @edition <> 'EXPRESS' BEGIN;
			EXEC msdb.dbo.sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;		

	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.script_configuration','P') IS NOT NULL
	DROP PROC dbo.script_configuration;
GO

CREATE PROC dbo.script_configuration 

AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- meta / formatting: 
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);

	DECLARE @sectionMarker nvarchar(2000) = N'--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
	
	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Hardware: 
	PRINT @sectionMarker;
	PRINT N'-- Hardware'
	PRINT @sectionMarker;	

	DECLARE @output nvarchar(MAX) = @crlf + @tab;
	SET @output = @output + N'-- Processors' + @crlf; 

	SELECT @output = @output
		+ @tab + @tab + N'PhysicalCpuCount: ' + CAST(cpu_count/hyperthread_ratio AS sysname) + @crlf
		+ @tab + @tab + N'HyperthreadRatio: ' + CAST([hyperthread_ratio] AS sysname) + @crlf
		+ @tab + @tab + N'LogicalCpuCount: ' + CAST(cpu_count AS sysname) + @crlf
	FROM 
		sys.dm_os_sys_info;

	DECLARE @cpuFamily sysname; 
	EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', N'ProcessorNameString', @cpuFamily OUT;

	SET @output = @output + @tab + @tab + N'ProcessorFamily: ' + @cpuFamily + @crlf;
	PRINT @output;

	DECLARE @physicalMemorySize bigint;
	DECLARE @memoryLookupCommand nvarchar(2000) = N'SELECT @physicalMemorySize = physical_memory_kb/1024 FROM sys.[dm_os_sys_info];';
	IF (SELECT dbo.[get_engine_version]()) < 11  -- account for change to sys.dm_os_sys_info between SQL Server 2008R2 and 2012 ... 
		SET @memoryLookupCommand = N'SELECT @physicalMemorySize = physical_memory_in_bytes/1024/1024 FROM sys.[dm_os_sys_info];';

	EXEC sys.[sp_executesql]
		@memoryLookupCommand, 
		N'@physicalMemorySize bigint OUTPUT', 
		@physicalMemorySize = @physicalMemorySize OUTPUT;

	SET @output = @crlf + @tab + N'-- Memory' + @crlf;
	SELECT @output = @output + @tab + @tab + N'PhysicalMemoryOnServer: ' + CAST(@physicalMemorySize AS sysname) + N'MB ' + @crlf FROM sys.[dm_os_sys_info];
	SET @output = @output + @tab + @tab + N'MemoryNodes: ' + @crlf;

	SELECT @output = @output 
		+ @tab + @tab + @tab + N'NODE_ID: ' + CAST(node_id AS sysname) + N' - ' + node_state_desc + N' (OnlineSchedulerCount: ' + CAST(online_scheduler_count AS sysname) + N', CpuAffinity: ' + CAST(cpu_affinity_mask AS sysname) + N')' + @crlf
	FROM sys.dm_os_nodes;
	
	PRINT @output;

	SET @output = @crlf + @crlf + @tab + N'-- Disks' + @crlf;

	DECLARE @disks table (
		[volume_mount_point] nvarchar(256) NULL,
		[file_system_type] nvarchar(256) NULL,
		[logical_volume_name] nvarchar(256) NULL,
		[total_gb] decimal(18,2) NULL,
		[available_gb] decimal(18,2) NULL
	);

	INSERT INTO @disks ([volume_mount_point], [file_system_type], [logical_volume_name], [total_gb], [available_gb])
	SELECT DISTINCT 
		vs.volume_mount_point, 
		vs.file_system_type, 
		vs.logical_volume_name, 
		CONVERT(DECIMAL(18,2),vs.total_bytes/1073741824.0) AS [total_gb],
		CONVERT(DECIMAL(18,2), vs.available_bytes/1073741824.0) AS [available_gb]  
	FROM 
		sys.master_files AS f
		CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs; 

	SELECT @output = @output
		+ @tab + @tab + volume_mount_point + @crlf + @tab + @tab + @tab + N'Label: ' + logical_volume_name + N', FileSystem: ' + file_system_type + N', TotalGB: ' + CAST([total_gb] AS sysname)  + N', AvailableGB: ' + CAST([available_gb] AS sysname) + @crlf
	FROM 
		@disks 
	ORDER BY 
		[volume_mount_point];	

	PRINT @output + @crlf;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process Installation Details:
	PRINT @sectionMarker;
	PRINT N'-- Installation Details'
	PRINT @sectionMarker;

	DECLARE @properties table (
		row_id int IDENTITY(1,1) NOT NULL, 
		segment_name sysname, 
		property_name sysname
	);

	INSERT INTO @properties (segment_name, property_name)
	VALUES 
	(N'ProductDetails', 'Edition'), 
	(N'ProductDetails', 'ProductLevel'), 
	(N'ProductDetails', 'ProductUpdateLevel'),
	(N'ProductDetails', 'ProductVersion'),
	(N'ProductDetails', 'ProductMajorVersion'),
	(N'ProductDetails', 'ProductMinorVersion'),

	(N'InstanceDetails', 'ServerName'),
	(N'InstanceDetails', 'InstanceName'),
	(N'InstanceDetails', 'IsClustered'),
	(N'InstanceDetails', 'Collation'),

	(N'InstanceFeatures', 'FullTextInstalled'),
	(N'InstanceFeatures', 'IntegratedSecurityOnly'),
	(N'InstanceFeatures', 'FilestreamConfiguredLevel'),
	(N'InstanceFeatures', 'HadrEnabled'),
	(N'InstanceFeatures', 'InstanceDefaultDataPath'),
	(N'InstanceFeatures', 'InstanceDefaultLogPath'),
	(N'InstanceFeatures', 'ErrorLogFileName'),
	(N'InstanceFeatures', 'BuildClrVersion');

	DECLARE propertyizer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		segment_name,
		property_name 
	FROM 
		@properties
	ORDER BY 
		row_id;

	DECLARE @segment sysname; 
	DECLARE @propertyName sysname;
	DECLARE @propertyValue sysname;
	DECLARE @segmentFamily sysname = N'';

	DECLARE @sql nvarchar(MAX);

	OPEN propertyizer; 

	FETCH NEXT FROM propertyizer INTO @segment, @propertyName;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @sql = N'SELECT @output = CAST(SERVERPROPERTY(''' + @propertyName + N''') as sysname);';

		EXEC sys.sp_executesql 
			@stmt = @sql, 
			@params = N'@output sysname OUTPUT', 
			@output = @propertyValue OUTPUT;

		IF @segment <> @segmentFamily BEGIN 
			SET @segmentFamily = @segment;

			PRINT @crlf + @tab + N'-- ' + @segmentFamily;
		END 
		
		PRINT @tab + @tab + @propertyName + ': ' + ISNULL(@propertyValue, N'NULL');

		FETCH NEXT FROM propertyizer INTO @segment, @propertyName;
	END;

	CLOSE propertyizer; 
	DEALLOCATE propertyizer;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Output Service Details:
	PRINT @crlf + @crlf;
	PRINT @sectionMarker;
	PRINT N'-- Service Details'
	PRINT @sectionMarker;	

	DECLARE @memoryType sysname = N'CONVENTIONAL';
	IF EXISTS (SELECT NULL FROM sys.dm_os_memory_nodes WHERE [memory_node_id] <> 64 AND [locked_page_allocations_kb] <> 0) 
		SET @memoryType = N'LOCKED';


	PRINT @crlf + @tab + N'-- LPIM CONFIG: ' +  @crlf + @tab + @tab + @memoryType;

	DECLARE @command nvarchar(MAX);
	SET @command = N'SELECT 
	servicename, 
	startup_type_desc, 
	service_account, 
	is_clustered, 
	cluster_nodename, 
	[filename] [path], 
	{0} ifi_enabled 
FROM 
	sys.dm_server_services;';	

	IF ((SELECT dbo.get_engine_version()) >= 13.00) -- ifi added to 2016+
		SET @command = REPLACE(@command, N'{0}', 'instant_file_initialization_enabled');
	ELSE 
		SET @command = REPLACE(@command, N'{0}', '''?''');


	DECLARE @serviceDetails table (
		[servicename] nvarchar(256) NOT NULL,
		[startup_type_desc] nvarchar(256) NOT NULL,
		[service_account] nvarchar(256) NOT NULL,
		[is_clustered] nvarchar(1) NOT NULL,
		[cluster_nodename] nvarchar(256) NULL,
		[path] nvarchar(256) NOT NULL,
		[ifi_enabled] nvarchar(1) NOT NULL
	);
	
	INSERT INTO @serviceDetails ([servicename],  [startup_type_desc], [service_account], [is_clustered], [cluster_nodename], [path], [ifi_enabled])
	EXEC master.sys.[sp_executesql] @command;

	SET @output = @crlf + @tab;

	SELECT 
		@output = @output 
		+ N'-- ' + [servicename] + @crlf 
		+ @tab + @tab + N'StartupType: ' + [startup_type_desc] + @crlf 
		+ @tab + @tab + N'ServiceAccount: ' + service_account + @crlf 
		+ @tab + @tab + N'IsClustered: ' + [is_clustered] + CASE WHEN [cluster_nodename] IS NOT NULL THEN + N' (' + cluster_nodename + N')' ELSE N'' END + @crlf  
		+ @tab + @tab + N'FilePath: ' + [path] + @crlf
		+ @tab + @tab + N'IFI Enabled: ' + [ifi_enabled] + @crlf + @crlf + @tab

	FROM 
		@serviceDetails;


	PRINT @output;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- TODO: Cluster Details (if/as needed). 


	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Global Trace Flags
	DECLARE @traceFlags table (
		[trace_flag] [int] NOT NULL,
		[status] [bit] NOT NULL,
		[global] [bit] NOT NULL,
		[session] [bit] NOT NULL
	)

	INSERT INTO @traceFlags (trace_flag, [status], [global], [session])
	EXECUTE ('DBCC TRACESTATUS() WITH NO_INFOMSGS');

	PRINT @sectionMarker;
	PRINT N'-- Trace Flags'
	PRINT @sectionMarker;

	SET @output = N'' + @crlf;

	SELECT @output = @output 
		+ @tab + N'-- ' + CAST([trace_flag] AS sysname) + N': ' + CASE WHEN [status] = 1 THEN 'ENABLED' ELSE 'DISABLED' END + @crlf
	FROM 
		@traceFlags 
	WHERE 
		[global] = 1;

	PRINT @output + @crlf;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Configuration Settings (outside of norms): 

	DECLARE @config_defaults TABLE (
		[name] nvarchar(35) NOT NULL,
		default_value sql_variant NOT NULL
	);

	INSERT INTO @config_defaults (name, default_value) VALUES 
	('access check cache bucket count',0),
	('access check cache quota',0),
	('Ad Hoc Distributed Queries',0),
	('affinity I/O mask',0),
	('affinity mask',0),
	('affinity64 I/O mask',0),
	('affinity64 mask',0),
	('Agent XPs',1),
	('allow polybase export', 0),
	('allow updates',0),
	('automatic soft-NUMA disabled', 0), -- default is good in best in most cases
	('awe enabled',0),
	('backup checksum default', 0), -- this should really be 1
	('backup compression default',0),
	('blocked process threshold (s)',0),
	('c2 audit mode',0),
	('clr enabled',0),
	('clr strict', 1), -- 2017+ (enabled by default)
	('common criteria compliance enabled',0),
	('contained database authentication', 0),
	('cost threshold for parallelism',5),
	('cross db ownership chaining',0),
	('cursor threshold',-1),
	('Database Mail XPs',0),
	('default full-text language',1033),
	('default language',0),
	('default trace enabled',1),
	('disallow results from triggers',0),
	('EKM provider enabled',0),
	('external scripts enabled',0),  -- 2016+
	('filestream access level',0),
	('fill factor (%)',0),
	('ft crawl bandwidth (max)',100),
	('ft crawl bandwidth (min)',0),
	('ft notify bandwidth (max)',100),
	('ft notify bandwidth (min)',0),
	('index create memory (KB)',0),
	('in-doubt xact resolution',0),
	('hadoop connectivity', 0),  -- 2016+
	('lightweight pooling',0),
	('locks',0),
	('max degree of parallelism',0),
	('max full-text crawl range',4),
	('max server memory (MB)',2147483647),
	('max text repl size (B)',65536),
	('max worker threads',0),
	('media retention',0),
	('min memory per query (KB)',1024),
	('min server memory (MB)',0), -- NOTE: SQL Server apparently changes this one 'in-flight' on a regular basis
	('nested triggers',1),
	('network packet size (B)',4096),
	('Ole Automation Procedures',0),
	('open objects',0),
	('optimize for ad hoc workloads',0),
	('PH timeout (s)',60),
	('polybase network encryption',1),
	('precompute rank',0),
	('priority boost',0),
	('query governor cost limit',0),
	('query wait (s)',-1),
	('recovery interval (min)',0),
	('remote access',1),
	('remote admin connections',0),
	('remote data archive',0),
	('remote login timeout (s)',10),
	('remote proc trans',0),
	('remote query timeout (s)',600),
	('Replication XPs',0),
	('scan for startup procs',0),
	('server trigger recursion',1),
	('set working set size',0),
	('show advanced options',0),
	('SMO and DMO XPs',1),
	('SQL Mail XPs',0),
	('transform noise words',0),
	('two digit year cutoff',2049),
	('user connections',0),
	('user options',0),
	('xp_cmdshell',0);

	PRINT @sectionMarker;
	PRINT N'-- Modified Configuration Options'
	PRINT @sectionMarker;	

	SET @output = N'';

	SELECT @output = @output +
		+ @tab + N'-- ' + c.[name] + @crlf
		+ @tab + @tab + N'DEFAULT: ' + CAST([d].[default_value] AS sysname) + @crlf
		+ @tab + @tab + N'VALUE_IN_USE: ' +  CAST(c.[value_in_use] AS sysname) + @crlf
		+ @tab + @tab + N'VALUE: ' + CAST(c.[value] AS sysname) + @crlf + @crlf
	FROM sys.configurations c 
	INNER JOIN @config_defaults d ON c.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = d.[name]
	WHERE
		c.value <> c.value_in_use
		OR c.value_in_use <> d.default_value;
	

	PRINT @output;


		-- Server Log - config setttings (path and # to keep/etc.)

		-- base paths - backups, data, log... 

		-- count of all logins... 
		-- list of all logins with SysAdmin membership.

		-- list of all dbs, files/file-paths... and rough sizes/details. 

		-- DDL triggers. 

		-- endpoints. 

		-- linked servers. 

		-- credentials (list and detail - sans passwords/sensitive info). 

		-- Resource Governor Pools/settings/etc. 

		-- Audit Specs? (yes - though... guessing they're hard-ish to script?)  -- and these are things i can add-in later - i.e., 30 - 60 minutes here/there to add in audits, XEs, and the likes... 

		-- XEs ? (yeah... why not). 

		-- Mirrored DB configs. (partners, listeners, certs, etc.)

		-- AG configs + listeners and such. 

		-- replication pubs and subs

		-- Mail Settings. Everything. 
			-- profiles and which one is the default. 
			--		list of accounts per profile (in ranked order)
			-- accounts and all details. 


		-- SQL Server Agent - 
			-- config settings. 
			-- operators
			-- alerts
			-- operators
			-- JOBS... all of 'em.  (guessing I can FIND a script that'll do this for me - i.e., someone else has likely written it).


	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.export_server_configuration','P') IS NOT NULL
	DROP PROC dbo.export_server_configuration;
GO

CREATE PROC dbo.export_server_configuration 
	@OutputPath								nvarchar(2000)			= N'{DEFAULT}',
	@CopyToPath								nvarchar(2000)			= NULL, 
	@AddServerNameToFileName				bit						= 1, 
	@OperatorName							sysname					= N'Alerts',
	@MailProfileName						sysname					= N'General',
	@EmailSubjectPrefix						nvarchar(50)			= N'[Server Configuration Export] ',	 
	@PrintOnly								bit						= 0	

AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
    EXEC dbo.verify_advanced_capabilities;

	-----------------------------------------------------------------------------
	-- Input Validation:

	DECLARE @edition sysname;
	SELECT @edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @edition = N'STANDARD' OR @edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @edition = 'WEB';
	END;
	
	IF @edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF (@PrintOnly = 0) AND (@edition <> 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @databaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @databaseMailProfile OUT, @no_output = N'no_output';
 
		IF @databaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@OutputPath) = N'{DEFAULT}' BEGIN
		SELECT @OutputPath = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@OutputPath, N'') IS NULL BEGIN
		RAISERROR('@OutputPath cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF @PrintOnly = 1 BEGIN 
		
		-- just execute the sproc that prints info to the screen: 
		EXEC dbo.script_configuration;

		RETURN 0;
	END; 


	-- if we're still here, we need to dynamically output/execute dbo.script_configuration so that output is directed to a file (and copied if needed)
	--		while catching and alerting on any errors or problems. 
	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	-- normalize paths: 
	IF(RIGHT(@OutputPath, 1) = '\')
		SET @OutputPath = LEFT(@OutputPath, LEN(@OutputPath) - 1);

	IF(RIGHT(ISNULL(@CopyToPath, N''), 1) = '\')
		SET @CopyToPath = LEFT(@CopyToPath, LEN(@CopyToPath) - 1);

	DECLARE @outputFileName varchar(2000);
	SET @outputFileName = @OutputPath + '\' + CASE WHEN @AddServerNameToFileName = 1 THEN @@SERVERNAME + '_' ELSE '' END + N'Server_Configuration.txt';

	DECLARE @errors table ( 
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) 
	);

	DECLARE @xpCmdShellOutput table (
		result_id int IDENTITY(1,1) NOT NULL, 
		result nvarchar(MAX) NULL
	);

	-- Set up a 'translation' of the sproc call (for execution via xp_cmdshell): 
	DECLARE @sqlCommand varchar(MAX); 
	SET @sqlCommand = N'EXEC admindb.dbo.script_configuration;';

	DECLARE @command varchar(8000) = 'sqlcmd {0} -q "{1}" -o "{2}"';

	-- replace parameters: 
	SET @command = REPLACE(@command, '{0}', CASE WHEN UPPER(@@SERVICENAME) = 'MSSQLSERVER' THEN '' ELSE ' -S .\' + UPPER(@@SERVICENAME) END);
	SET @command = REPLACE(@command, '{1}', @sqlCommand);
	SET @command = REPLACE(@command, '{2}', @outputFileName);

	BEGIN TRY

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL; 

		IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 
			SET @errorDetails = N'';
			SELECT 
				@errorDetails = @errorDetails + [result] + @crlf + @tab
			FROM 
				@xpCmdShellOutput 
			ORDER BY 
				[result_id];

			SET @errorDetails = N'Unexpected problem while attempting to write configuration details to disk: ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

			INSERT INTO @errors (error) VALUES (@errorDetails);
		END
		
		-- Verify that the file was written as expected: 
		SET @command = 'for %a in ("' + @outputFileName + '") do @echo %~ta';
		DELETE FROM @xpCmdShellOutput; 

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DECLARE @timeStamp datetime; 
		SELECT @timeStamp = MAX(CAST([result] AS datetime)) FROM @xpCmdShellOutput WHERE [result] IS NOT NULL;

		IF DATEDIFF(MINUTE, @timeStamp, GETDATE()) > 2 BEGIN 
			SET @errorDetails = N'TimeStamp for [' + @outputFileName + N'] reads ' + CONVERT(nvarchar(30), @timeStamp, 120) + N'. Current Execution Time is: ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'. File writing operations did NOT throw an error, but time-stamp difference shows ' + @outputFileName + N' file was NOT written as expected.' ;
			
			INSERT INTO @errors (error) VALUES (@errorDetails);
		END;

		-- copy the file if/as needed:
		IF @CopyToPath IS NOT NULL BEGIN

			DELETE FROM @xpCmdShellOutput;
			SET @command = 'COPY "{0}" "{1}\"';

			SET @command = REPLACE(@command, '{0}', @outputFileName);
			SET @command = REPLACE(@command, '{1}', @CopyToPath);

			INSERT INTO @xpCmdShellOutput ([result])
			EXEC master.sys.[xp_cmdshell] @command;

			DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL OR [result] LIKE '%1 file(s) copied.%'; 

			IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 

				SET @errorDetails = N'';
				SELECT 
					@errorDetails = @errorDetails + [result] + @crlf + @tab
				FROM 
					@xpCmdShellOutput 
				ORDER BY 
					[result_id];

				SET @errorDetails = N'Unexpected problem while copying file from @OutputPath to @CopyFilePath : ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

				INSERT INTO @errors (error) VALUES (@errorDetails);
			END 
		END;

	END TRY 
	BEGIN CATCH
		SET @errorDetails = N'Unexpected Exception while executing command: [' + ISNULL(@command, N'#ERROR#') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

		INSERT INTO @errors (error) VALUES (@errorDetails);
	END CATCH

REPORTING: 
	IF EXISTS (SELECT NULL FROM @errors) BEGIN
		DECLARE @emailErrorMessage nvarchar(MAX) = N'The following errors were encountered: ' + @crlf + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + N'- ' + [error] + @crlf
		FROM 
			@errors
		ORDER BY 
			error_id;

		DECLARE @emailSubject nvarchar(2000);
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
	
		IF @edition <> 'EXPRESS' BEGIN;
			EXEC msdb.dbo.sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;		

	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.configure_instance','P') IS NOT NULL
	DROP PROC dbo.[configure_instance];
GO

CREATE PROC dbo.[configure_instance]
	@MaxDOP									int, 
	@CostThresholdForParallelism			int, 
	@MaxServerMemoryGBs						decimal(8,1)
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	DECLARE @changesMade bit = 0;
	
	-- Enable the Dedicated Admin Connection: 
	IF NOT EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'remote admin connections' AND [value_in_use] = 1) BEGIN
		EXEC sp_configure 'remote admin connections', 1;
		SET @changesMade = 1;
	END;
	
	IF @MaxDOP IS NOT NULL BEGIN
		DECLARE @currentMaxDop int;
		
		SELECT @currentMaxDop = CAST([value_in_use] AS int) FROM sys.[configurations] WHERE [name] = N'max degree of parallelism';

		IF @currentMaxDop <> @MaxDOP BEGIN
			-- vNEXT verify that the value is legit (i.e., > -1 (0 IS valid) and < total core count/etc.)... 
			EXEC sp_configure 'max degree of parallelism', @MaxDOP;

			SET @changesMade = 1;
		END;
	END;

	IF @CostThresholdForParallelism IS NOT NULL BEGIN 
		DECLARE @currentThreshold int; 

		SELECT @currentThreshold = CAST([value_in_use] AS int) FROM sys.[configurations] WHERE [name] = N'cost threshold for parallelism';

		IF @currentThreshold <> @CostThresholdForParallelism BEGIN
			EXEC sp_configure 'cost threshold for parallelism', @CostThresholdForParallelism;

			SET @changesMade = 1;
		END;
	END;

	IF @MaxServerMemoryGBs IS NOT NULL BEGIN 
		DECLARE @maxServerMemAsInt int; 
		DECLARE @currentMaxServerMem int;

		SET @maxServerMemAsInt = @MaxServerMemoryGBs * 1024;
		SELECT @currentMaxServerMem = CAST([value_in_use] AS int) FROM sys.[configurations] WHERE [name] LIKE N'max server memory%';

		-- pad by 30MB ... i.e., 'close enough':
		IF ABS((@currentMaxServerMem - @maxServerMemAsInt)) > 30 BEGIN
			EXEC sp_configure 'max server memory', @maxServerMemAsInt;

			SET @changesMade = 1;
		END;
	END;

	IF @changesMade = 1 BEGIN
		RECONFIGURE;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.configure_database_mail','P') IS NOT NULL
	DROP PROC dbo.configure_database_mail;
GO

CREATE PROC dbo.configure_database_mail
    @ProfileName                    sysname             = N'General', 
    @OperatorName                   sysname             = N'Alerts', 
    @OperatorEmail                  sysname, 
    @SmtpAccountName                sysname             = N'Default SMTP Account', 
    @SmtpAccountDescription         sysname             = N'Defined/Created by S4',
    @SmtpOutgoingEmailAddress       sysname,
    @SmtpOutgoingDisplayName        sysname             = NULL,            -- e.g., SQL1 or POD2-SQLA, etc.  Will be set to @@SERVERNAME if NULL 
    @SmtpServerName                 sysname, 
    @SmtpPortNumber                 int                 = 587, 
    @SmtpRequiresSSL                bit                 = 1, 
    @SmtpAuthType                   sysname             = N'BASIC',         -- WINDOWS | BASIC | ANONYMOUS
    @SmptUserName                   sysname				= N'',
    @SmtpPassword                   sysname				= N'', 
	@SendTestEmailUponCompletion	bit					= 1
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	-----------------------------------------------------------------------------
	-- Verify that the SQL Server Agent is running
	IF NOT EXISTS (SELECT NULL FROM sys.[dm_server_services] WHERE [servicename] LIKE '%Agent%' AND [status_desc] = N'Running') BEGIN
		RAISERROR('SQL Server Agent Service is NOT running. Please ensure that it is running (and/or that this is not an Express Edition of SQL Server) before continuing.', 16, 1);
		RETURN -100;
	END;

	-----------------------------------------------------------------------------
    -- TODO: validate all inputs.. 
    IF NULLIF(@ProfileName, N'') IS NULL OR NULLIF(@OperatorName, N'') IS NULL OR NULLIF(@OperatorEmail, N'') IS NULL BEGIN 
        RAISERROR(N'@ProfileName, @OperatorName, and @OperatorEmail are all REQUIRED parameters.', 16, 1);
        RETURN -1;
    END;

    IF NULLIF(@SmtpOutgoingEmailAddress, N'') IS NULL OR NULLIF(@SmtpServerName, N'') IS NULL OR NULLIF(@SmtpAuthType, N'') IS NULL BEGIN 
        RAISERROR(N'@SmtpOutgoingEmailAddress, @SmtpServerName, and @SmtpAuthType are all REQUIRED parameters.', 16, 1);
        RETURN -2;
    END;

    IF UPPER(@SmtpAuthType) NOT IN (N'WINDOWS', N'BASIC', N'ANONYMOUS') BEGIN 
        RAISERROR(N'Valid options for @SmtpAuthType are { WINDOWS | BASIC | ANONYMOUS }.', 16, 1);
        RETURN -3;
    END;

    IF @SmtpPortNumber IS NULL OR @SmtpRequiresSSL IS NULL OR @SmtpRequiresSSL NOT IN (0, 1) BEGIN 
        RAISERROR(N'@SmtpPortNumber and @SmtpRequiresSSL are both REQUIRED Parameters. @SmtpRequiresSSL must also have a value of 0 or 1.', 16, 1);
        RETURN -4;
    END;

    IF NULLIF(@SmtpOutgoingDisplayName, N'') IS NULL 
        SELECT @SmtpOutgoingDisplayName = @@SERVERNAME;

    --------------------------------------------------------------
    -- Enable Mail XPs: 
	DECLARE @reconfigure bit = 0;
    IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'show advanced options' AND [value_in_use] = 0) BEGIN
        EXEC sp_configure 'show advanced options', 1; 
        
		SET @reconfigure = 1;
    END;

    IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'Database Mail XPs' AND [value_in_use] = 0) BEGIN
        EXEC sp_configure 'Database Mail XPs', 1; 
	    
		SET @reconfigure = 1;
    END;

	IF @reconfigure = 1 BEGIN
		RECONFIGURE;
	END;

    --------------------------------------------------------------
    -- Create Profile: 
    DECLARE @profileID int; 
	  
	-- TODO: attempt to load @profileID from queries to see if it @exists (so to speak). If it does, move on. If not, create the profile and 'load' @profileID in the process.
    EXEC msdb.dbo.[sysmail_add_profile_sp] 
        @profile_name = @ProfileName, 
        @description = N'S4-Created Profile... ', 
        @profile_id = @profileID OUTPUT;

    --------------------------------------------------------------
    -- Create an Account: 
    DECLARE @AccountID int; 
    DECLARE @useDefaultCredentials bit = 0;  -- username/password. 
    IF UPPER(@SmtpAuthType) = N'WINDOWS' SET @useDefaultCredentials = 1;  -- use windows. 
    IF UPPER(@SmtpAuthType) = N'ANONYMOUS' SET @useDefaultCredentials = 0;  

    EXEC msdb.dbo.[sysmail_add_account_sp]
        @account_name = @SmtpAccountName,
        @email_address = @SmtpOutgoingEmailAddress,
        @display_name = @SmtpOutgoingDisplayName,
        --@replyto_address = N'',
        @description = @SmtpAccountDescription,
        @mailserver_name = @SmtpServerName,
        @mailserver_type = N'SMTP',
        @port = @SmtpPortNumber,
        @username = @SmptUserName,
        @password = @SmtpPassword,
        @use_default_credentials = @useDefaultCredentials,
        @enable_ssl = @SmtpRequiresSSL,
        @account_id = @AccountID OUTPUT;

    --------------------------------------------------------------
    -- Bind Account to Profile: 
    EXEC msdb.dbo.sysmail_add_profileaccount_sp 
	    @profile_id = @profileID,
        @account_id = @AccountID, 
        @sequence_number = 1;  -- primary/initial... 


    --------------------------------------------------------------
    -- set as default: 
    EXEC msdb.dbo.sp_set_sqlagent_properties 
	    @databasemail_profile = @ProfileName,
        @use_databasemail = 1;

    --------------------------------------------------------------
    -- Create Operator: 
    EXEC msdb.dbo.[sp_add_operator]
        @name = @OperatorName,
        @enabled = 1,
        @email_address = @OperatorEmail;

    --------------------------------------------------------------
    -- Enable SQL Server Agent to use Database Mail and enable tokenization:
    EXEC msdb.dbo.[sp_set_sqlagent_properties]  -- NON-DOCUMENTED SPROC: 
        @alert_replace_runtime_tokens = 1,
        @use_databasemail = 1,
        @databasemail_profile = @ProfileName;

    -- define a default operator:
    EXEC master.dbo.sp_MSsetalertinfo 
        @failsafeoperator = @OperatorName, 
		@notificationmethod = 1;

    --------------------------------------------------------------
    -- vNext: bind operator and profile to dbo.settings as 'default' operator/profile details. 

	/*
	
		UPSERT... 
			dbo.settings: 
				setting_type	= SINGLETON
				setting_key		= s4_default_profile
				setting_value	= @ProfileName


		UPSERT 
			dbo.settings: 
				setting_type	= SINGLETON
				setting_key		= s4_default_operator
				setting_value	= @OperatorName				
	
		THEN... 
			need some sort of check/validation/CYA at the start of this processs
				that avoids configuring mail IF the values above are already set? 
					or something along those lines... 


			because... this process isn't super idempotent (or is it?)

	*/

	--------------------------------------------------------------
	-- Send a test email - to verify that the SQL Server Agent can correctly send email... 

	DECLARE @version sysname = (SELECT [version_number] FROM dbo.version_history WHERE [version_id] = (SELECT MAX([version_id]) FROM dbo.[version_history]));
	DECLARE @body nvarchar(MAX) = N'Test Email - Configuration Validation.

If you''re seeing this, the SQL Server Agent on ' + @SmtpOutgoingDisplayName + N' has been correctly configured to 
allow alerts via the SQL Server Agent.

Triggered by dbo.configure_database_mail. S4 version ' + @version + N'.

';
	EXEC msdb.dbo.[sp_notify_operator] 
		@profile_name = @ProfileName, 
		@name = @OperatorName, 
		@subject = N'', 
		@body = @body;
    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.enable_alerts','P') IS NOT NULL
	DROP PROC dbo.[enable_alerts];
GO

CREATE PROC dbo.[enable_alerts]
    @OperatorName                   sysname             = N'Alerts',
    @AlertTypes                     sysname             = N'SEVERITY_AND_IO',       -- SEVERITY | IO | SEVERITY_AND_IO
    @PrintOnly                      bit                 = 0
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -- TODO: verify that @OperatorName is a valid operator.

    IF UPPER(@AlertTypes) NOT IN (N'SEVERITY', N'IO', N'SEVERITY_AND_IO') BEGIN 
        RAISERROR('Valid @AlertTypes are { SEVERITY | IO | SEVERITY_AND_IO }.', 16, 1);
        RETURN -5;
    END;

    DECLARE @ioAlerts table (
        message_id int NOT NULL, 
        [name] sysname NOT NULL
    );

    DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

    DECLARE @alertTemplate nvarchar(MAX) = N'------- {name}
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE severity = {severity} AND [name] = N''{name}'') BEGIN
    EXEC msdb.dbo.sp_add_alert 
	    @name = N''{name}'', 
        @message_id = {id},
        @severity = {severity},
        @enabled = 1,
        @delay_between_responses = 0,
        @include_event_description_in = 1; 
    EXEC msdb.dbo.sp_add_notification 
	    @alert_name = N''{name}'', 
	    @operator_name = N''{operator}'', 
	    @notification_method = 1; 
END;' ;

    SET @alertTemplate = REPLACE(@alertTemplate, N'{operator}', @OperatorName);

    DECLARE @command nvarchar(MAX) = N'';

    IF UPPER(@AlertTypes) IN (N'SEVERITY', N'SEVERITY_AND_IO') BEGIN
            
        DECLARE @severityTemplate nvarchar(MAX) = REPLACE(@alertTemplate, N'{id}', N'0');
        SET @severityTemplate = REPLACE(@severityTemplate, N'{name}', N'Severity 0{severity}');

        WITH numbers AS ( 
            SELECT 
                ROW_NUMBER() OVER (ORDER BY [object_id]) [severity]
            FROM 
                sys.[objects] 
            WHERE 
                [object_id] < 50
        )

        SELECT
            @command = @command + @crlf + @crlf + REPLACE(@severityTemplate, N'{severity}', severity)
        FROM 
            numbers
        WHERE 
            [severity] >= 17 AND [severity] <= 25
        ORDER BY 
            [severity];
    END;

    IF UPPER(@AlertTypes) IN ( N'IO', N'SEVERITY_AND_IO') BEGIN 

        IF DATALENGTH(@command) > 2 SET @command = @command + @crlf + @crlf;

        INSERT INTO @ioAlerts (
            [message_id],
            [name]
        )
        VALUES       
            (605, N'605 - Page Allocation Unit Error'),
            (823, N'823 - Read/Write Failure'),
            (824, N'824 - Page Error'),
            (825, N'825 - Read-Retry Required');

        DECLARE @ioTemplate nvarchar(MAX) = REPLACE(@alertTemplate, N'{severity}', N'0');

        SELECT
            @command = @command + @crlf + @crlf + REPLACE(REPLACE(@ioTemplate, N'{id}', message_id), N'{name}', [name])
        FROM 
            @ioAlerts;

    END;

    IF @PrintOnly = 1 
        EXEC dbo.[print_long_string] @command;
    ELSE 
        EXEC sp_executesql @command;

    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.enable_alert_filtering','P') IS NOT NULL
	DROP PROC dbo.[enable_alert_filtering];
GO

CREATE PROC dbo.[enable_alert_filtering]
    @TargetAlerts                   nvarchar(MAX)           = N'{ALL}', 
    @ExcludedAlerts                 nvarchar(MAX)           = NULL,                        -- N'%18, %4605%, Severity%, etc..'. NOTE: 1480, if present, is filtered automatically.. 
    @AlertsProcessingJobName        sysname                 = N'Filter Alerts', 
    @AlertsProcessingJobCategory    sysname                 = N'Alerting',
	@OperatorName				    sysname					= N'Alerts',
	@MailProfileName			    sysname					= N'General'
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    ------------------------------------
    -- create a 'response' job: 
    DECLARE @errorMessage nvarchar(MAX);

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.syscategories WHERE [name] = @AlertsProcessingJobCategory AND category_class = 1) BEGIN
        
        BEGIN TRY
            EXEC msdb.dbo.sp_add_category 
                @class = N'JOB', 
                @type = N'LOCAL', 
                @name = @AlertsProcessingJobCategory;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected problem creating job category [' + @AlertsProcessingJobCategory + N'] on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -20;
        END CATCH;
    END;

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobs WHERE [name] = @AlertsProcessingJobName) BEGIN 
    
        -- vNEXT: check to see if there isn't already a job 'out there' that's doing these exact same things - i.e., where the @command is pretty close to the same stuff 
        --          being done below. And, if it is, raise a WARNING... but don't raise an error OR kill execution... 
        DECLARE @command nvarchar(MAX) = N'
        DECLARE @ErrorNumber int, @Severity int;
        SET @ErrorNumber = CONVERT(int, N''$(ESCAPE_SQUOTE(A-ERR))'');
        SET @Severity = CONVERT(int, N''$(ESCAPE_NONE(A-SEV))'');

        EXEC admindb.dbo.process_alerts 
	        @ErrorNumber = @ErrorNumber, 
	        @Severity = @Severity,
	        @Message = N''$(ESCAPE_SQUOTE(A-MSG))'', 
            @OperatorName = N''{operator}'', 
            @MailProfileName = N''{profile}''; ';

        SET @command = REPLACE(@command, N'{operator}', @OperatorName);
        SET @command = REPLACE(@command, N'{profile}', @MailProfileName);
        
        BEGIN TRANSACTION; 

        BEGIN TRY 
            EXEC msdb.dbo.[sp_add_job]
                @job_name = @AlertsProcessingJobName,
                @enabled = 1,
                @description = N'Executed by SQL Server Agent Alerts - to enable logic/processing for filtering of ''noise'' alerts.',
                @start_step_id = 1,
                @category_name = @AlertsProcessingJobCategory,
                @owner_login_name = N'sa',
                @notify_level_email = 2,
                @notify_email_operator_name = @OperatorName,
                @delete_level = 0;

            -- TODO: might need a version check here... i.e., this behavior is new to ... 2017? (possibly 2016?) (or I'm on drugs) (eithe way, NOT clearly documented as of 2019-07-29)
            EXEC msdb.dbo.[sp_add_jobserver] 
                @job_name = @AlertsProcessingJobName, 
                @server_name = N'(LOCAL)';

            EXEC msdb.dbo.[sp_add_jobstep]
                @job_name = @AlertsProcessingJobName,
                @step_id = 1,
                @step_name = N'Process Alert Filtering',
                @subsystem = N'TSQL',
                @command = @command,
                @cmdexec_success_code = 0,
                @on_success_action = 1,
                @on_success_step_id = 0,
                @on_fail_action = 2,
                @on_fail_step_id = 0,
                @database_name = N'admindb',
                @flags = 0;

            COMMIT TRANSACTION;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected error creating alert-processing/filtering job on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            ROLLBACK TRANSACTION;
            RETURN -25;
        END CATCH;

      END;
    ELSE BEGIN 
        -- vNEXT: verify that the @OperatorName and @MailProfileName in job-step 1 are the same as @inputs... 
        PRINT 'TODO/vNEXT. [1]';
    END;

    ------------------------------------
    -- process targets/exclusions:
    DECLARE @inclusions table (
        [name] sysname NOT NULL 
    );

    DECLARE @targets table (
        [name] sysname NOT NULL 
    );

    IF UPPER(@TargetAlerts) = N'{ALL}' BEGIN 
        INSERT INTO @targets (
            [name] 
        )
        SELECT 
            s.[name] 
        FROM 
            msdb.dbo.[sysalerts] s
      END;
    ELSE BEGIN 
        INSERT INTO @inclusions (
            [name]
        )
        SELECT [result] FROM [dbo].[split_string](@TargetAlerts, N',', 1);

        INSERT INTO @targets (
            [name]
        )
        SELECT 
            a.[name]
        FROM 
            msdb.dbo.[sysalerts] a
            INNER JOIN @inclusions i ON a.[name] LIKE i.[name];
    END;

    DECLARE @exclusions table ( 
        [name] sysname NOT NULL
    );

    INSERT INTO @exclusions (
        [name]
    )
    VALUES (
        N'1480%'
    );

    IF NULLIF(@ExcludedAlerts, N'') IS NOT NULL BEGIN
        INSERT INTO @exclusions (
            [name]
        )
        SELECT [result] FROM dbo.[split_string](@ExcludedAlerts, N',', 1);
    END;


    DECLARE walker CURSOR LOCAL FAST_FORWARD FOR
    SELECT 
        [t].[name] 
    FROM 
        @targets [t]
        LEFT OUTER JOIN @exclusions x ON [t].[name] LIKE [x].[name]
    WHERE 
        x.[name] IS NULL;

    DECLARE @currentAlert sysname; 

    OPEN [walker]; 

    FETCH NEXT FROM [walker] INTO @currentAlert;

    WHILE @@FETCH_STATUS = 0 BEGIN
        
        IF EXISTS (SELECT NULL FROM msdb.dbo.[sysalerts] WHERE [name] = @currentAlert AND [has_notification] = 1) BEGIN
            EXEC msdb.dbo.[sp_delete_notification] 
                @alert_name = @currentAlert, 
                @operator_name = @OperatorName;
        END;
        
        IF NOT EXISTS (SELECT NULL FROM [msdb].dbo.[sysalerts] WHERE [name] = @currentAlert AND NULLIF([job_id], N'00000000-0000-0000-0000-000000000000') IS NOT NULL) BEGIN
            EXEC msdb.dbo.[sp_update_alert]
                @name = @currentAlert,
                @job_name = @AlertsProcessingJobName;
        END;
        
        FETCH NEXT FROM [walker] INTO @currentAlert;
    END;

    CLOSE [walker];
    DEALLOCATE [walker];

    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.manage_server_history','P') IS NOT NULL
	DROP PROC dbo.[manage_server_history];
GO

CREATE PROC dbo.[manage_server_history]
	@HistoryCleanupJobName				sysname			= N'Regular History Cleanup', 
	@JobCategoryName					sysname			= N'Server Maintenance', 
	@JobOperatorToAlertOnErrors			sysname			= N'Alerts',
	@NumberOfServerLogsToKeep			int				= 24, 
	@StartDayOfWeekForCleanupJob		sysname			= N'Sunday',
	@StartTimeForCleanupJob				time			= N'09:45',				-- AM/24-hour time (i.e. defaults to morning)
	@TimeZoneForUtcOffset				sysname			= NULL,					-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@AgentJobHistoryRetention			sysname			= N'4 weeks', 
	@BackupHistoryRetention				sysname			= N'4 weeks', 
	@EmailHistoryRetention				sysname			= N'', 
	@CycleFTCrawlLogsInDatabases		nvarchar(MAX)	= NULL,
	@CleanupS4History					sysname			= N'', 
	@OverWriteExistingJob				bit				= 0						-- Exactly as it sounds. Used for cases where we want to force an exiting job into a 'new' shap.e... 
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	-- TODO: validate inputs... 

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		DECLARE @utc datetime = GETUTCDATE();
		DECLARE @atTimeZone datetime = @utc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneForUtcOffset;

		SET @StartTimeForCleanupJob = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @StartTimeForCleanupJob);
	END;

	DECLARE @outcome int;
	DECLARE @error nvarchar(MAX);

	-- Set the Error Log Retention value: 
	EXEC xp_instance_regwrite 
		N'HKEY_LOCAL_MACHINE', 
		N'Software\Microsoft\MSSQLServer\MSSQLServer', 
		N'NumErrorLogs', 
		REG_DWORD, 
		@NumberOfServerLogsToKeep;

	-- Toggle Agent History Retention (i.e., get rid of 'silly' 1000/100 limits: 
	EXEC [msdb].[dbo].[sp_set_sqlagent_properties]			-- undocumented, but... pretty 'solid'/obvious: EXEC msdb.dbo.sp_helptext 'sp_set_sqlagent_properties';
		@jobhistory_max_rows = -1, 
		@jobhistory_max_rows_per_job = -1;

	DECLARE @historyDaysBack int; 
	EXEC @outcome = dbo.[translate_vector]
		@Vector = @AgentJobHistoryRetention,
		@ValidationParameterName = N'@AgentJobHistoryRetention',
		@ProhibitedIntervals = 'MILLISECOND, SECOND, MINUTE, HOUR',
		@TranslationDatePart = 'DAY',
		@Output = @historyDaysBack OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN
		RAISERROR(@error, 16, 1);
		RETURN - 20;
	END;

	DECLARE @backupDaysBack int;
	EXEC @outcome = dbo.[translate_vector]
		@Vector = @BackupHistoryRetention, 
		@ValidationParameterName = N'@BackupHistoryRetention', 
		@ProhibitedIntervals = 'MILLISECOND, SECOND, MINUTE, HOUR',
		@TranslationDatePart = 'DAY',
		@Output = @backupDaysBack OUTPUT, 
		@error = @error OUTPUT;

	IF @outcome <> 0 BEGIN
		RAISERROR(@error, 16, 1);
		RETURN - 21;
	END;

	DECLARE @emailDaysBack int; 
	IF NULLIF(@EmailHistoryRetention, N'') IS NOT NULL BEGIN
		EXEC @outcome = dbo.[translate_vector]
			@Vector = @EmailHistoryRetention, 
			@ValidationParameterName = N'@EmailHistoryRetention', 
			@ProhibitedIntervals = 'MILLISECOND, SECOND, MINUTE, HOUR',
			@TranslationDatePart = 'DAY',
			@Output = @emailDaysBack OUTPUT, 
			@error = @error OUTPUT;

		IF @outcome <> 0 BEGIN
			RAISERROR(@error, 16, 1);
			RETURN - 22;
		END;
	END;

	DECLARE @dayNames TABLE (
		day_map int NOT NULL, 
		day_name sysname NOT NULL
	);
	INSERT INTO @dayNames
	(
		day_map,
		day_name
	)
	SELECT id, val FROM (VALUES (1, N'Sunday'), (2, N'Monday'), (4, N'Tuesday'), (8, N'Wednesday'), (16, N'Thursday'), (32, N'Friday'), (64, N'Saturday')) d(id, val);

	IF NOT EXISTS(SELECT NULL FROM @dayNames WHERE UPPER([day_name]) = UPPER(@StartDayOfWeekForCleanupJob)) BEGIN
		RAISERROR(N'Specified value of ''%s'' for @StartDayOfWeekForCleanupJob is invalid.', 16, 1);
		RETURN -2;
	END;
	   	 
	DECLARE @jobId uniqueidentifier;
	EXEC [dbo].[create_agent_job]
		@TargetJobName = @HistoryCleanupJobName,
		@JobCategoryName = @JobCategoryName,
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJob,
		@JobID = @jobId OUTPUT;

	-- create a schedule:
	DECLARE @dayMap int;
	SELECT @dayMap = [day_map] FROM @dayNames WHERE UPPER([day_name]) = UPPER(@StartDayOfWeekForCleanupJob);

	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @StartTimeForCleanupJob, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = N'Schedule: ' + @HistoryCleanupJobName;

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_name = @HistoryCleanupJobName,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 8,	
		@freq_interval = @dayMap,
		@freq_subday_type = 1,
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 1, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- Start adding job-steps:
	DECLARE @currentStepName sysname;
	DECLARE @currentCommand nvarchar(MAX);
	DECLARE @currentStepId int = 2;		-- job step ID 1 is the placeholder... 

	-- Remove Job History
	SET @currentStepName = N'Truncate Job History';
	SET @currentCommand = N'DECLARE @cutoff datetime; 
SET @cutoff = DATEADD(DAY, 0 - {daysBack}, GETDATE());

EXEC msdb.dbo.sp_purge_jobhistory  
	@oldest_date = @cutoff; ';

	SET @currentCommand = REPLACE(@currentCommand, N'{daysBack}', @historyDaysBack);

	EXEC msdb..sp_add_jobstep 
		@job_id = @jobId,               
	    @step_id = @currentStepId,		
	    @step_name = @currentStepName,	
	    @subsystem = N'TSQL',			
	    @command = @currentCommand,		
	    @on_success_action = 3,			
	    @on_fail_action = 3, 
	    @database_name = N'msdb',
	    @retry_attempts = 2,
	    @retry_interval = 1;			
	
	SET @currentStepId += 1;

	-- Remove Backup History:
	SET @currentStepName = N'Truncate Backup History';
	SET @currentCommand = N'DECLARE @cutoff datetime; 
SET @cutoff = DATEADD(DAY, 0 - {daysBack}, GETDATE());

EXEC msdb.dbo.sp_delete_backuphistory  
	@oldest_date = @cutoff; ';

	SET @currentCommand = REPLACE(@currentCommand, N'{daysBack}', @backupDaysBack);

	EXEC msdb..sp_add_jobstep 
		@job_id = @jobId,               
	    @step_id = @currentStepId,		
	    @step_name = @currentStepName,	
	    @subsystem = N'TSQL',			
	    @command = @currentCommand,		
	    @on_success_action = 3,			
	    @on_fail_action = 3, 
	    @database_name = N'msdb',
	    @retry_attempts = 2,
	    @retry_interval = 1;			
	
	SET @currentStepId += 1;
	
	-- Remove Email History:
	IF NULLIF(@EmailHistoryRetention, N'') IS NOT NULL BEGIN 

		SET @currentStepName = N'Truncate Email History';
		SET @currentCommand = N'DECLARE @cutoff datetime; 
SET @cutoff = DATEADD(DAY, 0 - {daysBack}, GETDATE());

EXEC msdb.dbo.sysmail_delete_mailitems_sp  
	@sent_before = @cutoff, 
	@sent_status = ''sent''; ';

		SET @currentCommand = REPLACE(@currentCommand, N'{daysBack}', @emailDaysBack);

		EXEC msdb..sp_add_jobstep 
			@job_id = @jobId,               
			@step_id = @currentStepId,		
			@step_name = @currentStepName,	
			@subsystem = N'TSQL',			
			@command = @currentCommand,		
			@on_success_action = 3,			
			@on_fail_action = 3, 
			@database_name = N'msdb',
			@retry_attempts = 2,
			@retry_interval = 1;			
	
		SET @currentStepId += 1;

	END;

	-- Remove FTCrawlHistory:
--	IF @CycleFTCrawlLogsInDatabases IS NOT NULL BEGIN

--		DECLARE @ftStepNameTemplate sysname = N'{dbName} - Truncate FT Crawl History';
--		SET @currentCommand = N'SET NOCOUNT ON;

--DECLARE @catalog sysname; 
--DECLARE @command nvarchar(300); 
--DECLARE @template nvarchar(200) = N''EXEC sp_fulltext_recycle_crawl_log ''''{0}''''; '';

--DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
--SELECT 
--	[name]
--FROM 
--	sys.[fulltext_catalogs]
--ORDER BY 
--	[name];

--OPEN walker; 
--FETCH NEXT FROM walker INTO @catalog;

--WHILE @@FETCH_STATUS = 0 BEGIN

--	SET @command = REPLACE(@template, N''{0}'', @catalog);

--	--PRINT @command;
--	EXEC sys.[sp_executesql] @command;

--	FETCH NEXT FROM walker INTO @catalog;
--END;

--CLOSE walker;
--DEALLOCATE walker; ';

--		DECLARE @currentDBName sysname;
--		DECLARE @targets table (
--			row_id int IDENTITY(1, 1) NOT NULL,
--			[db_name] sysname NOT NULL
--		);

--		INSERT INTO @targets 
--		EXEC dbo.list_databases 
--			@Targets = @CycleFTCrawlLogsInDatabases, 
--			@ExcludeClones = 1, 
--			@ExcludeSecondaries = 1, 
--			@ExcludeSimpleRecovery = 0, 
--			@ExcludeReadOnly = 1, 
--			@ExcludeRestoring = 1, 
--			@ExcludeRecovering = 1, 
--			@ExcludeOffline = 1;

--		DECLARE [cycler] CURSOR LOCAL FAST_FORWARD FOR 
--		SELECT
--			[db_name]
--		FROM 
--			@targets 
--		ORDER BY 
--			[row_id];

--		OPEN [cycler];
--		FETCH NEXT FROM [cycler] INTO @currentDBName;
		
--		WHILE @@FETCH_STATUS = 0 BEGIN
		
--			SET @currentStepName = REPLACE(@ftStepNameTemplate, N'{dbName}', @currentDBName);

--			EXEC msdb..sp_add_jobstep 
--				@job_id = @jobId,               
--				@step_id = @currentStepId,		
--				@step_name = @currentStepName,	
--				@subsystem = N'TSQL',			
--				@command = @currentCommand,		
--				@on_success_action = 3,			
--				@on_fail_action = 3, 
--				@database_name = @currentDBName,
--				@retry_attempts = 2,
--				@retry_interval = 1;			
	
--			SET @currentStepId += 1;
		
--			FETCH NEXT FROM [cycler] INTO @currentDBName;
--		END;
		
--		CLOSE [cycler];
--		DEALLOCATE [cycler];

--	END;

	-- Cycle Error Logs: 
	SET @currentStepName = N'Cycle Logs';
	SET @currentCommand = N'-- Error Log:
USE master;
GO
EXEC master.sys.sp_cycle_errorlog;
GO

-- SQL Server Agent Error Log:
USE msdb;
GO
EXEC dbo.sp_cycle_agent_errorlog;
GO ';	

	EXEC msdb..sp_add_jobstep 
			@job_id = @jobId,               
			@step_id = @currentStepId,		
			@step_name = @currentStepName,	
			@subsystem = N'TSQL',			
			@command = @currentCommand,		
			@on_success_action = 1,	-- quit reporting success	
			@on_fail_action = 2,	-- quit reporting failure 
			@database_name = N'msdb',
			@retry_attempts = 2,
			@retry_interval = 1;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.enable_disk_monitoring','P') IS NOT NULL
	DROP PROC dbo.[enable_disk_monitoring];
GO

CREATE PROC dbo.[enable_disk_monitoring]
	@WarnWhenFreeGBsGoBelow				decimal(12,1)		= 22.0,				
	@HalveThresholdAgainstCDrive		bit					= 0,	
	@DriveCheckJobName					sysname				= N'Regular Drive Space Checks',
	@JobCategoryName					sysname				= N'Monitoring',
	@JobOperatorToAlertOnErrors			sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[DriveSpace Checks] ',
	@CheckFrequencyInterval				sysname				= N'20 minutes', 
	@DailyStartTime						time				= '00:03', 
	@TimeZoneForUtcOffset				sysname				= NULL,				-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@OverWriteExistingJob				bit					= 0
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-- TODO: validate inputs... 

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		DECLARE @utc datetime = GETUTCDATE();
		DECLARE @atTimeZone datetime = @utc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneForUtcOffset;

		SET @DailyStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @DailyStartTime);
	END;

	-- translate/validate job start/frequency:
	DECLARE @frequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @CheckFrequencyInterval,
		@ValidationParameterName = N'@CheckFrequency',
		@ProhibitedIntervals = N'MILLISECOND,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	DECLARE @scheduleFrequencyType int = 4;  -- daily (in all scenarios below)
	DECLARE @schedFrequencyInterval int;   
	DECLARE @schedSubdayType int; 
	DECLARE @schedSubdayInteval int; 
	DECLARE @translationSet bit = 0;  -- bit of a hack at this point... 

	IF @frequencyMinutes <= 0 BEGIN
		RAISERROR('Invalid value for @CheckFrequencyInterval. Intervals must be > 1 minute and <= 24 hours.', 16, 1);
		RETURN -5;
	END;

	IF @CheckFrequencyInterval LIKE '%day%' BEGIN 
		IF @frequencyMinutes > (60 * 24 * 7) BEGIN 
			RAISERROR('@CheckFrequencyInterval may not be set for > 7 days. Hours/Minutes and < 7 days are allowable options.', 16, 1);
			RETURN -20;
		END;

		SET @schedFrequencyInterval = @frequencyMinutes / (60 * 24);
		SET @schedSubdayType = 1; -- at the time specified... 
		SET @schedSubdayInteval = 0;   -- ignored... 

		SET @translationSet = 1;
	END;

	IF @CheckFrequencyInterval LIKE '%hour%' BEGIN
		IF @frequencyMinutes > (60 * 24) BEGIN 
			RAISERROR('Please specify ''day[s]'' for @CheckFrequencyInterval when setting values for > 1 day.', 16, 1);
			RETURN -21;
		END;

		SET @schedFrequencyInterval = 1;
		SET @schedSubdayType = 8;  -- hours
		SET @schedSubdayInteval = @frequencyMinutes / 60;
		SET @translationSet = 1; 
	END;
	
	IF @CheckFrequencyInterval LIKE '%minute%' BEGIN
		IF @frequencyMinutes > (60 * 24) BEGIN 
			RAISERROR('Please specify ''day[s]'' for @CheckFrequencyInterval when setting values for > 1 day.', 16, 1);
			RETURN -21;
		END;		

		SET @schedFrequencyInterval = 1;
		SET @schedSubdayType = 4;  -- minutes
		SET @schedSubdayInteval = @frequencyMinutes;
		SET @translationSet = 1;
	END;

--SELECT @scheduleFrequencyType [FreqType], @schedFrequencyInterval [FrequencyInterval], @schedSubdayType [subdayType], @schedSubdayInteval [subDayInterval];
--RETURN 0;

	IF @translationSet = 0 BEGIN
		RAISERROR('Invalid timespan value specified for @CheckFrequencyInterval. Allowable values are Minutes, Hours, and (less than) 7 days.', 16, 1);
		RETURN -30;
	END;

	DECLARE @jobId uniqueidentifier;
	EXEC dbo.[create_agent_job]
		@TargetJobName = @DriveCheckJobName,
		@JobCategoryName = @JobCategoryName,
		@AddBlankInitialJobStep = 0,	-- this isn't usually a long-running job - so it doesn't need this... 
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJob,
		@JobID = @jobId OUTPUT;
	
	-- create a schedule:
	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @DailyStartTime, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = N'Schedule: ' + @DriveCheckJobName;

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = @scheduleFrequencyType,										
		@freq_interval = @schedFrequencyInterval,								
		@freq_subday_type = @schedSubdayType,							
		@freq_subday_interval = @schedSubdayInteval, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- Define Job Step for execution of checkup logic: 
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @stepBody nvarchar(MAX) = N'EXEC admindb.dbo.verify_drivespace 
	@WarnWhenFreeGBsGoBelow = {freeGBs}{halveForC}{Operator}{Profile}{Prefix};';
	
	SET @stepBody = REPLACE(@stepBody, N'{freeGBs}', CAST(@WarnWhenFreeGBsGoBelow AS sysname));

	--TODO: need a better way of handling/processing addition of non-defaults... 
	IF @HalveThresholdAgainstCDrive = 1
		SET @stepBody = REPLACE(@stepBody, N'{halveForC}', @crlfTab + N',@HalveThresholdAgainstCDrive = 1')
	ELSE 
		SET @stepBody = REPLACE(@stepBody, N'{halveForC}', N'');

	IF UPPER(@JobOperatorToAlertOnErrors) <> N'ALERTS' 
		SET @stepBody = REPLACE(@stepBody, N'{Operator}', @crlfTab + N',@OperatorName = ''' + @JobOperatorToAlertOnErrors + N'''');
	ELSE 
		SET @stepBody = REPLACE(@stepBody, N'{Operator}', N'');

	IF UPPER(@MailProfileName) <> N'GENERAL'
		SET @stepBody = REPLACE(@stepBody, N'{Profile}', @crlfTab + N',@MailProfileName = ''' + @MailProfileName + N'''');
	ELSE 
		SET @stepBody = REPLACE(@stepBody, N'{Profile}', N'');

	IF UPPER(@EmailSubjectPrefix) <> N'[DRIVESPACE CHECKS] '
		SET @stepBody = REPLACE(@stepBody, N'{Prefix}', @crlfTab + N',@EmailSubjectPrefix = ''' + @EmailSubjectPrefix + N'''');
	ELSE
		SET @stepBody = REPLACE(@stepBody, N'{Prefix}', N'');

	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 1,
		@step_name = N'Check on Disk Space and Send Alerts',
		@subsystem = N'TSQL',
		@command = @stepBody,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 1,
		@retry_interval = 1;
	
	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.create_backup_jobs','P') IS NOT NULL
	DROP PROC dbo.[create_backup_jobs];
GO

CREATE PROC dbo.[create_backup_jobs]
	@FullAndLogUserDBTargets					sysname					= N'{USER}',
	@FullAndLogUserDBExclusions					sysname					= N'',
	@EncryptionCertName							sysname					= NULL,
	@BackupsDirectory							sysname					= N'{DEFAULT}', 
	@CopyToBackupDirectory						sysname					= N'',
	--@OffSiteBackupPath						sysname					= NULL, 
	@SystemBackupRetention						sysname					= N'4 days', 
	@CopyToSystemBackupRetention				sysname					= N'4 days', 
	@UserFullBackupRetention					sysname					= N'3 days', 
	@CopyToUserFullBackupRetention				sysname					= N'3 days',
	@LogBackupRetention							sysname					= N'73 hours', 
	@CopyToLogBackupRetention					sysname					= N'73 hours',
	@AllowForSecondaryServers					bit						= 0,				-- Set to 1 for Mirrored/AG'd databases. 
	@FullSystemBackupsStartTime					sysname					= N'18:50:00',		-- if '', then system backups won't be created... 
	@FullUserBackupsStartTime					sysname					= N'02:00:00',		
	--@DiffBackupsStartTime						sysname					= NULL, 
	--@DiffBackupsRunEvery						sysname					= NULL,				-- minutes or hours ... e.g., N'4 hours' or '180 minutes', etc. 
	@LogBackupsStartTime						sysname					= N'00:02:00',		-- ditto ish
	@LogBackupsRunEvery							sysname					= N'10 minutes',	-- vector, but only allows minutes (i think).
	@TimeZoneForUtcOffset						sysname					= NULL,				-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@JobsNamePrefix								sysname					= N'Database Backups - ',		-- e.g., "Database Backups - USER - FULL" or "Database Backups - USER - LOG" or "Database Backups - SYSTEM - FULL"
	@JobsCategoryName							sysname					= N'Backups',							
	@JobOperatorToAlertOnErrors					sysname					= N'Alerts',	
	@ProfileToUseForAlerts						sysname					= N'General',
	@OverWriteExistingJobs						bit						= 0
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-- TODO: validate inputs... 

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		DECLARE @utc datetime = GETUTCDATE();
		DECLARE @atTimeZone datetime = @utc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneForUtcOffset;

		SET @FullSystemBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @FullSystemBackupsStartTime);
		SET @FullUserBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @FullUserBackupsStartTime);
		SET @LogBackupsStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @LogBackupsStartTime);
	END;

	DECLARE @systemStart time, @userStart time, @logStart time;
	SELECT 
		@systemStart	= CAST(@FullSystemBackupsStartTime AS time), 
		@userStart		= CAST(@FullUserBackupsStartTime AS time), 
		@logStart		= CAST(@LogBackupsStartTime AS time);

	-- Verify minutes-only for T-Log Backups: 
	IF @logStart IS NOT NULL AND @LogBackupsRunEvery IS NOT NULL BEGIN 
		IF @LogBackupsRunEvery NOT LIKE '%minute%' BEGIN 
			RAISERROR('@LogBackupsRunEvery can only specify values defined in minutes - e.g., N''5 minutes'', or N''10 minutes'', etc.', 16, 1);
			RETURN -2;
		END;
	END;

	DECLARE @frequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @LogBackupsRunEvery,
		@ValidationParameterName = N'@LogBackupsRunEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	DECLARE @backupsTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[backup_databases]
	@BackupType = N''{backupType}'',
	@DatabasesToBackup = N''{targets}'',
	@DatabasesToExclude = N''{exclusions}'',
	@BackupDirectory = N''{backupsDirectory}'',{copyToDirectory}
	@BackupRetention = N''{retention}'',{copyToRetention}{encryption}{secondaries}{operator}{profile}
	@PrintOnly = 0;';

	DECLARE @sysBackups nvarchar(MAX), @userBackups nvarchar(MAX), @logBackups nvarchar(MAX);
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

	-- 'global' template config settings/options: 
	SET @backupsTemplate = REPLACE(@backupsTemplate, N'{backupsDirectory}', @BackupsDirectory);
	
	IF NULLIF(@EncryptionCertName, N'') IS NULL 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{encryption}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{encryption}', @crlfTab + N'@EncryptionCertName = N''' + @EncryptionCertName + N''',' + @crlfTab + N'@EncryptionAlgorithm = N''AES_256'',');

	IF NULLIF(@CopyToBackupDirectory, N'') IS NULL BEGIN
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToDirectory}', N'');
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToRetention}', N'');
	  END;
	ELSE BEGIN
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToDirectory}', @crlfTab + N'@CopyToBackupDirectory = N''' + @CopyToBackupDirectory + N''', ');
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{copyToRetention}', @crlfTab + N'@CopyToRetention = N''{copyRetention}'', ');
	END;

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{operator}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{profile}', N'');
	ELSE 
		SET @backupsTemplate = REPLACE(@backupsTemplate, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-- system backups: 
	SET @sysBackups = REPLACE(@backupsTemplate, N'{exclusions}', N'');

	IF @AllowForSecondaryServers = 0 
		SET @sysBackups = REPLACE(@sysBackups, N'{secondaries}', N'');
	ELSE 
		SET @sysBackups = REPLACE(@sysBackups, N'{secondaries}', @crlfTab + N'@AddServerNameToSystemBackupPath = 1, ');

	SET @sysBackups = REPLACE(@sysBackups, N'{backupType}', N'FULL');
	SET @sysBackups = REPLACE(@sysBackups, N'{targets}', N'{SYSTEM}');
	SET @sysBackups = REPLACE(@sysBackups, N'{retention}', @SystemBackupRetention);
	SET @sysBackups = REPLACE(@sysBackups, N'{copyRetention}', ISNULL(@CopyToSystemBackupRetention, N''));

	-- Make sure to exclude _s4test dbs from USER backups: 
	IF NULLIF(@FullAndLogUserDBExclusions, N'') IS NULL 
		SET @FullAndLogUserDBExclusions = N'%s4test';
	ELSE BEGIN 
		IF @FullAndLogUserDBExclusions NOT LIKE N'%s4test%'
			SET @FullAndLogUserDBExclusions = @FullAndLogUserDBExclusions + N', %s4test';
	END;

	SET @backupsTemplate = REPLACE(@backupsTemplate, N'{exclusions}', @FullAndLogUserDBExclusions);

	-- full user backups: 
	SET @userBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @userBackups = REPLACE(@userBackups, N'{secondaries}', N'');
	ELSE 
		SET @userBackups = REPLACE(@userBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @userBackups = REPLACE(@userBackups, N'{backupType}', N'FULL');
	SET @userBackups = REPLACE(@userBackups, N'{targets}', N'{USER}');
	SET @userBackups = REPLACE(@userBackups, N'{retention}', @UserFullBackupRetention);
	SET @userBackups = REPLACE(@userBackups, N'{copyRetention}', ISNULL(@CopyToUserFullBackupRetention, N''));
	SET @userBackups = REPLACE(@userBackups, N'{exclusions}', @FullAndLogUserDBExclusions);

	-- log backups: 
	SET @logBackups = @backupsTemplate;

	IF @AllowForSecondaryServers = 0 
		SET @logBackups = REPLACE(@logBackups, N'{secondaries}', N'');
	ELSE 
		SET @logBackups = REPLACE(@logBackups, N'{secondaries}', @crlfTab + N'@AllowNonAccessibleSecondaries = 1, ');

	SET @logBackups = REPLACE(@logBackups, N'{backupType}', N'LOG');
	SET @logBackups = REPLACE(@logBackups, N'{targets}', N'{USER}');
	SET @logBackups = REPLACE(@logBackups, N'{retention}', @LogBackupRetention);
	SET @logBackups = REPLACE(@logBackups, N'{copyRetention}', ISNULL(@CopyToLogBackupRetention, N''));
	SET @logBackups = REPLACE(@logBackups, N'{exclusions}', @FullAndLogUserDBExclusions);

	DECLARE @jobs table (
		job_id int IDENTITY(1,1) NOT NULL, 
		job_name sysname NOT NULL, 
		job_step_name sysname NOT NULL, 
		job_body nvarchar(MAX) NOT NULL,
		job_start_time time NULL
	);

	INSERT INTO @jobs (
		[job_name],
		[job_step_name],
		[job_body],
		[job_start_time]
	)
	VALUES	
	(
		N'SYSTEM - Full', 
		N'FULL Backup of SYSTEM Databases', 
		@sysBackups, 
		@systemStart
	), 
	(
		N'USER - Full', 
		N'FULL Backup of USER Databases', 
		@userBackups, 
		@userStart
	), 
	(
		N'USER - Log', 
		N'TLOG Backup of USER Databases', 
		@LogBackups, 
		@logStart
	);
	
	DECLARE @currentJobSuffix sysname, @currentJobStep sysname, @currentJobStepBody nvarchar(MAX), @currentJobStart time;

	DECLARE @currentJobName sysname;
	DECLARE @existingJob sysname; 
	DECLARE @jobID uniqueidentifier;

	DECLARE @dateAsInt int;
	DECLARE @startTimeAsInt int; 
	DECLARE @scheduleName sysname;

	DECLARE @schedSubdayType int; 
	DECLARE @schedSubdayInteval int; 
	
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[job_name],
		[job_step_name],
		[job_body],
		[job_start_time]
	FROM 
		@jobs
	WHERE 
		[job_start_time] IS NOT NULL -- don't create jobs for 'tasks' without start times.
	ORDER BY 
		[job_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentJobSuffix, @currentJobStep, @currentJobStepBody, @currentJobStart;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @currentJobName =  @JobsNamePrefix + @currentJobSuffix;

		SET @jobID = NULL;
		EXEC [admindb].[dbo].[create_agent_job]
			@TargetJobName = @currentJobName,
			@JobCategoryName = @JobsCategoryName,
			@AddBlankInitialJobStep = 1,
			@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
			@OverWriteExistingJobDetails = @OverWriteExistingJobs,
			@JobID = @jobID OUTPUT;
		
		-- create a schedule:
		SET @dateAsInt = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
		SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, @currentJobStart, 108), N':', N''), 6)) AS int);
		SET @scheduleName = @currentJobName + N' Schedule';

		IF @currentJobName LIKE '%log%' BEGIN 
			SET @schedSubdayType = 4; -- every N minutes
			SET @schedSubdayInteval = @frequencyMinutes;	 -- N... 
		  END; 
		ELSE BEGIN 
			SET @schedSubdayType = 1; -- at the specified (start) time. 
			SET @schedSubdayInteval = 0
		END;

		EXEC msdb.dbo.sp_add_jobschedule 
			@job_id = @jobId,
			@name = @scheduleName,
			@enabled = 1, 
			@freq_type = 4,  -- daily										
			@freq_interval = 1,  -- every 1 days... 								
			@freq_subday_type = @schedSubdayType,							
			@freq_subday_interval = @schedSubdayInteval, 
			@freq_relative_interval = 0, 
			@freq_recurrence_factor = 0, 
			@active_start_date = @dateAsInt, 
			@active_start_time = @startTimeAsInt;

		-- now add the job step:
		EXEC msdb..sp_add_jobstep
			@job_id = @jobId,
			@step_id = 2,		-- place-holder already defined for step 1
			@step_name = @currentJobStep,
			@subsystem = N'TSQL',
			@command = @currentJobStepBody,
			@on_success_action = 1,		-- quit reporting success
			@on_fail_action = 2,		-- quit reporting failure 
			@database_name = N'admindb',
			@retry_attempts = 0,
			@retry_interval = 0;
	
	FETCH NEXT FROM [walker] INTO @currentJobSuffix, @currentJobStep, @currentJobStepBody, @currentJobStart;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];
	
	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.create_restore_test_job','P') IS NOT NULL
	DROP PROC dbo.[create_restore_test_job];
GO

CREATE PROC dbo.[create_restore_test_job]
    @JobName						sysname				= N'Database Backups - Regular Restore Tests',
	@RestoreTestStartTime			time				= N'22:05:00',
	@TimeZoneForUtcOffset			sysname				= NULL,				-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@JobCategoryName				sysname				= N'Backups',
	@AllowForSecondaries			bit					= 0,									-- IF AG/Mirrored environment (secondaries), then wrap restore-test in IF is_primary_server check... 
    @DatabasesToRestore				nvarchar(MAX)		= N'{READ_FROM_FILESYSTEM}', 
    @DatabasesToExclude				nvarchar(MAX)		= N'',									-- TODO: document specialized logic here... 
    @Priorities						nvarchar(MAX)		= NULL,
    @BackupsRootPath				nvarchar(MAX)		= N'{DEFAULT}',
    @RestoredRootDataPath			nvarchar(MAX)		= N'{DEFAULT}',
    @RestoredRootLogPath			nvarchar(MAX)		= N'{DEFAULT}',
    @RestoredDbNamePattern			nvarchar(40)		= N'{0}_s4test',
    @AllowReplace					nchar(7)			= NULL,									-- NULL or the exact term: N'REPLACE'...
	@RpoWarningThreshold			nvarchar(10)		= N'24 hours',							-- Only evaluated if non-NULL. 
    @DropDatabasesAfterRestore		bit					= 1,									-- Only works if set to 1, and if we've RESTORED the db in question. 
    @MaxNumberOfFailedDrops			int					= 1,									-- number of failed DROP operations we'll tolerate before early termination.
	@OperatorName					sysname				= N'Alerts',
    @MailProfileName				sysname				= N'General',
    @EmailSubjectPrefix				nvarchar(50)		= N'[RESTORE TEST] ',
	@OverWriteExistingJob			bit					= 0
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-- TODO: validate inputs... 

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		DECLARE @utc datetime = GETUTCDATE();
		DECLARE @atTimeZone datetime = @utc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneForUtcOffset;

		SET @RestoreTestStartTime = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @RestoreTestStartTime);
	END;

	DECLARE @restoreStart time;
	SELECT 
		@restoreStart	= CAST(@RestoreTestStartTime AS time);

	-- Typical Use-Case/Pattern: 
	IF UPPER(@AllowReplace) <> N'REPLACE' AND @DropDatabasesAfterRestore IS NULL 
		SET @DropDatabasesAfterRestore = 1;

	-- Define the Job Step: 
	DECLARE @restoreTemplate nvarchar(MAX) = N'EXEC admindb.dbo.restore_databases  
	@DatabasesToRestore = N''{targets}'',{exclusions}{priorities}
	@BackupsRootPath = N''{backupsPath}'',
	@RestoredRootDataPath = N''{dataPath}'',
	@RestoredRootLogPath = N''{logPath}'',
	@RestoredDbNamePattern = N''{restorePattern}'',{replace}{rpo}{operator}{profile}
	@DropDatabasesAfterRestore = {drop},
	@PrintOnly = 0; ';

	IF @AllowForSecondaries = 1 BEGIN 
		SET @restoreTemplate = N'IF (SELECT admindb.dbo.is_primary_server()) = 1 BEGIN
	EXEC admindb.dbo.restore_databases  
		@DatabasesToRestore = N''{targets}'',{exclusions}{priorities}
		@BackupsRootPath = N''{backupsPath}'',
		@RestoredRootDataPath = N''{dataPath}'',
		@RestoredRootLogPath = N''{logPath}'',
		@RestoredDbNamePattern = N''{restorePattern}'',{replace}{rpo}{operator}{profile}
		@DropDatabasesAfterRestore = {drop},
		@PrintOnly = 0; 
END;'

	END;

	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @jobStepBody nvarchar(MAX) = @restoreTemplate;

	-- TODO: document the 'special case' of SYSTEM as exclusions... 
	IF @DatabasesToRestore IN (N'{READ_FROM_FILESYSTEM}', N'{ALL}') BEGIN 
		IF NULLIF(@DatabasesToExclude, N'') IS NULL 
			SET @DatabasesToExclude = N'{SYSTEM}'
		ELSE BEGIN
			IF @DatabasesToExclude NOT LIKE N'%{SYSTEM}%' BEGIN
				SET @DatabasesToExclude = N'{SYSTEM},' + @DatabasesToExclude;
			END;
		END;
	END;

	IF NULLIF(@DatabasesToExclude, N'') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{exclusions}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{exclusions}', @crlfTab + N'@DatabasesToExclude = ''' + @DatabasesToExclude + N''', ');

	IF NULLIF(@OperatorName, N'Alerts') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{operator}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{operator}', @crlfTab + N'@OperatorName = ''' + @OperatorName + N''', ');

	IF NULLIF(@MailProfileName, N'General') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{profile}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{profile}', @crlfTab + N'@MailProfileName = ''' + @MailProfileName + N''', ');

	IF NULLIF(@Priorities, N'') IS NULL 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{priorities}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{priorities}', @crlfTab + N'@Priorities = N''' + @Priorities + N''', ');

	IF NULLIF(@AllowReplace, N'') IS NULL
		SET @jobStepBody = REPLACE(@jobStepBody, N'{replace}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{replace}', @crlfTab + N'@AllowReplace = N''' + @AllowReplace + N''', ');

	IF NULLIF(@RpoWarningThreshold, N'') IS NULL
		SET @jobStepBody = REPLACE(@jobStepBody, N'{rpo}', N'');
	ELSE 
		SET @jobStepBody = REPLACE(@jobStepBody, N'{rpo}', @crlfTab + N'@RpoWarningThreshold = N''' + @RpoWarningThreshold + N''', ');

	SET @jobStepBody = REPLACE(@jobStepBody, N'{targets}', @DatabasesToRestore);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{backupsPath}', @BackupsRootPath);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{dataPath}', @RestoredRootDataPath);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{logPath}', @RestoredRootLogPath);
	SET @jobStepBody = REPLACE(@jobStepBody, N'{restorePattern}', @RestoredDbNamePattern);

	SET @jobStepBody = REPLACE(@jobStepBody, N'{drop}', CAST(@DropDatabasesAfterRestore AS sysname));

	DECLARE @jobId uniqueidentifier = NULL;
	EXEC [dbo].[create_agent_job]
		@TargetJobName = @JobName,
		@JobCategoryName = @JobCategoryName,
		@AddBlankInitialJobStep = 1,
		@OperatorToAlertOnErrorss = @OperatorName,
		@OverWriteExistingJobDetails = @OverWriteExistingJob,
		@JobID = @jobId OUTPUT;
	
	-- create a schedule:
	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @restoreStart, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = @JobName + ' Schedule';

	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobId,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 4,		-- daily								
		@freq_interval = 1, -- every 1 days							
		@freq_subday_type = 1,	-- at the scheduled time... 					
		@freq_subday_interval = 0, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- and add the job step: 
	EXEC msdb..sp_add_jobstep
		@job_id = @jobId,
		@step_id = 2,		-- place-holder defined as job-step 1.
		@step_name = N'Restore Tests',
		@subsystem = N'TSQL',
		@command = @jobStepBody,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 0,
		@retry_interval = 0;
	
	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.define_masterkey_encryption','P') IS NOT NULL
	DROP PROC dbo.[define_masterkey_encryption];
GO

CREATE PROC dbo.[define_masterkey_encryption]
	@MasterEncryptionKeyPassword		sysname		= NULL, 
	@BackupPath							sysname		= NULL, 
	@BackupEncryptionPassword			sysname		= NULL
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF NULLIF(@BackupPath, N'') IS NOT NULL BEGIN 
		IF NULLIF(@BackupEncryptionPassword, N'') IS NULL BEGIN 
			RAISERROR('Backup of Master Encryption Key can NOT be done without specifying a password (you''ll need this to recover the key IF necessary).', 16, 1);
			RETURN -2;
		END;

		DECLARE @error nvarchar(MAX);
		EXEC dbo.[establish_directory] 
			@TargetDirectory = @BackupPath, 
			@Error = @error OUTPUT;
		
		IF @error IS NOT NULL BEGIN
			RAISERROR(@error, 16, 1);
			RETURN - 5;
		END;
	END;

	IF NULLIF(@MasterEncryptionKeyPassword, N'') IS NULL 
		SET @MasterEncryptionKeyPassword = CAST(NEWID() AS sysname);
	
	DECLARE @command nvarchar(MAX);
	IF NOT EXISTS (SELECT NULL FROM master.sys.[symmetric_keys] WHERE [symmetric_key_id] = 101) BEGIN 
		SET @command = N'USE [master]; CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + @MasterEncryptionKeyPassword + N'''; ';

		EXEC sp_executesql @command;

		PRINT 'MASTER KEY defined with password of: ' + @MasterEncryptionKeyPassword
	  
		IF NULLIF(@BackupPath, N'') IS NOT NULL BEGIN 
			-- TODO: verify backup location. 
		
			DECLARE @hostName sysname; 
			SELECT @hostName = @@SERVERNAME;

			SET @command = N'USE [master]; BACKUP MASTER KEY TO FILE = N''' + @BackupPath + N'\' + @hostName + N'_Master_Encryption_Key.key''
				ENCRYPTION BY PASSWORD = ''' + @BackupEncryptionPassword + N'''; '; 

			EXEC sp_executesql @command;

			PRINT 'Master Key Backed up to ' + @BackupPath + N' with Password of: ' + @BackupEncryptionPassword;
		END;	  
	  
	  RETURN 0;

	END; 

	-- otherwise, if we're still here... 
	PRINT 'Master Key Already Exists';	

	RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Restores:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_files','P') IS NOT NULL
	DROP PROC dbo.load_backup_files;
GO

CREATE PROC dbo.load_backup_files 
	@DatabaseToRestore			sysname,
	@SourcePath					nvarchar(400), 
	@Mode						sysname,				-- FULL | DIFF | LOG 
	@LastAppliedFile			nvarchar(400)			= NULL,	
	@Output						nvarchar(MAX)			= N'default'  OUTPUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;

	IF @Mode NOT IN (N'FULL',N'DIFF',N'LOG') BEGIN;
		RAISERROR('Configuration Error: Invalid @Mode specified.', 16, 1);
		SET @Output = NULL;
		RETURN -1;
	END 

	DECLARE @results table ([id] int IDENTITY(1,1) NOT NULL, [output] varchar(500));

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	--PRINT @command
	INSERT INTO @results ([output])
	EXEC xp_cmdshell 
		@stmt = @command;

	-- High-level Cleanup: 
	DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';

	-- if this is a SYSTEM database and we didn't get any results, test for @AppendServerNameToSystemDbs 
	IF ((SELECT dbo.[is_system_database](@DatabaseToRestore)) = 1) AND NOT EXISTS (SELECT NULL FROM @results) BEGIN

		SET @SourcePath = @SourcePath + N'\' + REPLACE(@@SERVERNAME, N'\', N'_');

		SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';
		INSERT INTO @results ([output])
		EXEC xp_cmdshell 
			@stmt = @command;

		DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';
	END;

	-- Mode Processing: 
	IF UPPER(@Mode) = N'FULL' BEGIN
		-- most recent full only: 
		DELETE FROM @results WHERE id <> ISNULL((SELECT MAX(id) FROM @results WHERE [output] LIKE 'FULL%'), -1);
	END;

	IF UPPER(@Mode) = N'DIFF' BEGIN 
		-- start by deleting since the most recent file processed: 
		DELETE FROM @results WHERE id <= (SELECT id FROM @results WHERE [output] = @LastAppliedFile);

		-- now dump everything but the most recent DIFF - if there is one: 
		IF EXISTS(SELECT NULL FROM @results WHERE [output] LIKE 'DIFF%')
			DELETE FROM @results WHERE id <> (SELECT MAX(id) FROM @results WHERE [output] LIKE 'DIFF%'); 
		ELSE
			DELETE FROM @results;
	END;

	IF UPPER(@Mode) = N'LOG' BEGIN
		
		DELETE FROM @results WHERE id <= (SELECT MIN(id) FROM @results WHERE [output] = @LastAppliedFile);
		DELETE FROM @results WHERE [output] NOT LIKE 'LOG%';
	END;

    IF NULLIF(@Output, N'') IS NULL BEGIN -- if @Output has been EXPLICITLY initialized as NULL/empty... then REPLY... 
        
	    SET @Output = N'';
	    SELECT @Output = @Output + [output] + N',' FROM @results ORDER BY [id];

	    IF ISNULL(@Output,'') <> ''
		    SET @Output = LEFT(@Output, LEN(@Output) - 1);

        RETURN 0;
    END;

    -- otherwise, project:
    SELECT 
        [output]
    FROM 
        @results
    ORDER BY 
        [id];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.load_header_details','P') IS NOT NULL
	DROP PROC dbo.load_header_details;
GO

CREATE PROC dbo.load_header_details 
	@BackupPath					nvarchar(800), 
	@SourceVersion				decimal(4,2)	            = NULL,
	@BackupDate					datetime		            OUTPUT, 
	@BackupSize					bigint			            OUTPUT, 
	@Compressed					bit				            OUTPUT, 
	@Encrypted					bit				            OUTPUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-- TODO: 
	--		make sure file/path exists... 

	DECLARE @executingServerVersion decimal(4,2);
	SELECT @executingServerVersion = (SELECT dbo.get_engine_version());

	IF NULLIF(@SourceVersion, 0) IS NULL SET @SourceVersion = @executingServerVersion;

	CREATE TABLE #header (
		BackupName nvarchar(128) NULL, -- backups generated by S4 ALWAYS have this value populated - but it's NOT required by SQL Server (obviously).
		BackupDescription nvarchar(255) NULL, 
		BackupType smallint NOT NULL, 
		ExpirationDate datetime NULL, 
		Compressed bit NOT NULL, 
		Position smallint NOT NULL, 
		DeviceType tinyint NOT NULL, --
		Username nvarchar(128) NOT NULL, 
		ServerName nvarchar(128) NOT NULL, 
		DatabaseName nvarchar(128) NOT NULL,
		DatabaseVersion int NOT NULL, 
		DatabaseCreationDate datetime NOT NULL, 
		BackupSize numeric(20,0) NOT NULL, 
		FirstLSN numeric(25,0) NOT NULL, 
		LastLSN numeric(25,0) NOT NULL, 
		CheckpointLSN numeric(25,0) NOT NULL, 
		DatabaseBackupLSN numeric(25,0) NOT NULL, 
		BackupStartDate datetime NOT NULL, 
		BackupFinishDate datetime NOT NULL, 
		SortOrder smallint NULL, 
		[CodePage] smallint NOT NULL, 
		UnicodeLocaleID int NOT NULL, 
		UnicodeComparisonStyle int NOT NULL,
		CompatibilityLevel tinyint NOT NULL, 
		SoftwareVendorID int NOT NULL, 
		SoftwareVersionMajor int NOT NULL, 
		SoftwareVersionMinor int NOT NULL, 
		SoftwareVersionBuild int NOT NULL, 
		MachineName nvarchar(128) NOT NULL, 
		Flags int NOT NULL, 
		BindingID uniqueidentifier NOT NULL, 
		RecoveryForkID uniqueidentifier NULL, 
		Collation nvarchar(128) NOT NULL, 
		FamilyGUID uniqueidentifier NOT NULL, 
		HasBulkLoggedData bit NOT NULL, 
		IsSnapshot bit NOT NULL, 
		IsReadOnly bit NOT NULL, 
		IsSingleUser bit NOT NULL, 
		HasBackupChecksums bit NOT NULL, 
		IsDamaged bit NOT NULL, 
		BeginsLogChain bit NOT NULL, 
		HasIncompleteMetaData bit NOT NULL, 
		IsForceOffline bit NOT NULL, 
		IsCopyOnly bit NOT NULL, 
		FirstRecoveryForkID uniqueidentifier NOT NULL, 
		ForkPointLSN numeric(25,0) NULL, 
		RecoveryModel nvarchar(60) NOT NULL, 
		DifferntialBaseLSN numeric(25,0) NULL, 
		DifferentialBaseGUID uniqueidentifier NULL, 
		BackupTypeDescription nvarchar(60) NOT NULL, 
		BackupSetGUID uniqueidentifier NULL, 
		CompressedBackupSize bigint NOT NULL  -- 2008 / 2008 R2  (10.0  / 10.5)
	);

	IF @SourceVersion >= 11.0 BEGIN -- columns added to 2012 and above:
		ALTER TABLE [#header]
			ADD Containment tinyint NOT NULL; -- 2012 (11.0)
	END; 

	IF @SourceVersion >= 13.0 BEGIN  -- columns added to 2016 and above:
		ALTER TABLE [#header]
			ADD 
				KeyAlgorithm nvarchar(32) NULL, 
				EncryptorThumbprint varbinary(20) NULL, 
				EncryptorType nvarchar(32) NULL
	END;

	DECLARE @command nvarchar(MAX); 

	SET @command = N'RESTORE HEADERONLY FROM DISK = N''{0}'';';
	SET @command = REPLACE(@command, N'{0}', @BackupPath);
	
	INSERT INTO [#header] 
	EXEC sp_executesql @command;

	DECLARE @encryptionValue bit = 0;
	IF @SourceVersion >= 13.0 BEGIN

		EXEC sys.[sp_executesql]
			@stmt = N'SELECT @encryptionValue = CASE WHEN EncryptorThumbprint IS NOT NULL THEN 1 ELSE 0 END FROM [#header];', 
			@params = N'@encryptionValue bit OUTPUT',
			@encryptionValue = @encryptionValue OUTPUT; 
	END;

	-- Return Output Details: 
	SELECT 
		@BackupDate = [BackupFinishDate], 
		@BackupSize = CAST((ISNULL([CompressedBackupSize], [BackupSize])) AS bigint), 
		@Compressed = [Compressed], 
		@Encrypted =ISNULL(@encryptionValue, 0)
	FROM 
		[#header];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.restore_databases','P') IS NOT NULL
    DROP PROC dbo.restore_databases;
GO

CREATE PROC dbo.restore_databases 
    @DatabasesToRestore				nvarchar(MAX),
    @DatabasesToExclude				nvarchar(MAX)	= NULL,
    @Priorities						nvarchar(MAX)	= NULL,
    @BackupsRootPath				nvarchar(MAX)	= N'{DEFAULT}',
    @RestoredRootDataPath			nvarchar(MAX)	= N'{DEFAULT}',
    @RestoredRootLogPath			nvarchar(MAX)	= N'{DEFAULT}',
    @RestoredDbNamePattern			nvarchar(40)	= N'{0}_s4test',
    @AllowReplace					nchar(7)		= NULL,				-- NULL or the exact term: N'REPLACE'...
    @SkipLogBackups					bit				= 0,
	@ExecuteRecovery				bit				= 1,
    @CheckConsistency				bit				= 1,
	@RpoWarningThreshold			nvarchar(10)	= N'24 hours',		-- Only evaluated if non-NULL. 
    @DropDatabasesAfterRestore		bit				= 0,				-- Only works if set to 1, and if we've RESTORED the db in question. 
    @MaxNumberOfFailedDrops			int				= 1,				-- number of failed DROP operations we'll tolerate before early termination.
    @Directives						nvarchar(400)	= NULL,				-- { RESTRICTED_USER | KEEP_REPLICATION | KEEP_CDC | [ ENABLE_BROKER | ERROR_BROKER_CONVERSATIONS | NEW_BROKER ] }
	@OperatorName					sysname			= N'Alerts',
    @MailProfileName				sysname			= N'General',
    @EmailSubjectPrefix				nvarchar(50)	= N'[RESTORE TEST] ',
    @PrintOnly						bit				= 0
AS
    SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	-----------------------------------------------------------------------------
    -- Set Defaults:
    IF UPPER(@BackupsRootPath) = N'{DEFAULT}' BEGIN
        SELECT @BackupsRootPath = dbo.load_default_path('BACKUP');
    END;

    IF UPPER(@RestoredRootDataPath) = N'{DEFAULT}' BEGIN
        SELECT @RestoredRootDataPath = dbo.load_default_path('DATA');
    END;

    IF UPPER(@RestoredRootLogPath) = N'{DEFAULT}' BEGIN
        SELECT @RestoredRootLogPath = dbo.load_default_path('LOG');
    END;

    -----------------------------------------------------------------------------
    -- Validate Inputs: 
    IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
        
        -- Operator Checks:
        IF ISNULL(@OperatorName, '') IS NULL BEGIN
            RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
            RETURN -2;
         END;
        ELSE BEGIN 
            IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
                RAISERROR('Invalild Operator Name Specified.', 16, 1);
                RETURN -2;
            END;
        END;

        -- Profile Checks:
        DECLARE @DatabaseMailProfile nvarchar(255)
        EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
        IF @DatabaseMailProfile <> @MailProfileName BEGIN
            RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
            RETURN -2;
        END; 
    END;

	IF @ExecuteRecovery = 0 AND @DropDatabasesAfterRestore = 1 BEGIN
		RAISERROR(N'@ExecuteRecovery cannot be set to false (0) when @DropDatabasesAfterRestore is set to true (1).', 16, 1);
		RETURN -5;
	END;

    IF @MaxNumberOfFailedDrops <= 0 BEGIN
        RAISERROR('@MaxNumberOfFailedDrops must be set to a value of 1 or higher.', 16, 1);
        RETURN -6;
    END;

    IF NULLIF(@AllowReplace, N'') IS NOT NULL AND UPPER(@AllowReplace) <> N'REPLACE' BEGIN
        RAISERROR('The @AllowReplace switch must be set to NULL or the exact term N''REPLACE''.', 16, 1);
        RETURN -4;
    END;

    IF NULLIF(@AllowReplace, N'') IS NOT NULL AND @DropDatabasesAfterRestore = 1 BEGIN
        RAISERROR('Databases cannot be explicitly REPLACED and DROPPED after being replaced. If you wish DBs to be restored (on a different server for testing) with SAME names as PROD, simply leave suffix empty (but not NULL) and leave @AllowReplace NULL.', 16, 1);
        RETURN -6;
    END;

    IF UPPER(@DatabasesToRestore) IN (N'{SYSTEM}', N'{USER}') BEGIN
        RAISERROR('The tokens {SYSTEM} and {USER} cannot be used to specify which databases to restore via dbo.restore_databases. Use either {READ_FROM_FILESYSTEM} (plus any exclusions via @DatabasesToExclude), or specify a comma-delimited list of databases to restore.', 16, 1);
        RETURN -10;
    END;

    IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
        SET @DatabasesToExclude = NULL;

    IF (@DatabasesToExclude IS NOT NULL) AND (UPPER(@DatabasesToRestore) <> N'{READ_FROM_FILESYSTEM}') BEGIN
        RAISERROR('@DatabasesToExclude can ONLY be specified when @DatabasesToRestore is defined as the {READ_FROM_FILESYSTEM} token. Otherwise, if you don''t want a database restored, don''t specify it in the @DatabasesToRestore ''list''.', 16, 1);
        RETURN -20;
    END;

    IF (NULLIF(@RestoredDbNamePattern,'')) IS NULL BEGIN
        RAISERROR('@RestoredDbNamePattern can NOT be NULL or empty. Use the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname - whereas ''{0}'' would simply be restored as the name of the db to restore per database).', 16, 1);
        RETURN -22;
    END;

	DECLARE @vector bigint;  -- 'global'
	DECLARE @vectorError nvarchar(MAX);
	
	IF NULLIF(@RpoWarningThreshold, N'') IS NOT NULL BEGIN 
		EXEC [dbo].[translate_vector]
		    @Vector = @RpoWarningThreshold, 
		    @ValidationParameterName = N'@RpoWarningThreshold', 
		    @TranslationDatePart = N'SECOND', 
		    @Output = @vector OUTPUT, 
		    @Error = @vectorError OUTPUT;

		IF @vectorError IS NOT NULL BEGIN 
			RAISERROR(@vectorError, 16, 1);
			RETURN -20;
		END;
	END;

	DECLARE @directivesText nvarchar(200) = N'';
	IF NULLIF(@Directives, N'') IS NOT NULL BEGIN
		SET @Directives = LTRIM(RTRIM(@Directives));
		
		DECLARE @allDirectives table ( 
			row_id int NOT NULL, 
			directive sysname NOT NULL
		);

		INSERT INTO @allDirectives ([row_id], [directive])
		SELECT * FROM dbo.[split_string](@Directives, N',', 1);

		-- verify that only supported directives are defined: 
		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] NOT IN (N'RESTRICTED_USER', N'KEEP_REPLICATION', N'KEEP_CDC', N'ENABLE_BROKER', N'ERROR_BROKER_CONVERSATIONS' , N'NEW_BROKER')) BEGIN
			RAISERROR(N'Invalid @Directives value specified. Permitted values are { RESTRICTED_USER | KEEP_REPLICATION | KEEP_CDC | [ ENABLE_BROKER | ERROR_BROKER_CONVERSATIONS | NEW_BROKER ] }.', 16, 1);
			RETURN -20;
		END;

		-- make sure we're ONLY specifying a single BROKER directive (i.e., all three options are supported, but they're (obviously) mutually exclusive).
		IF (SELECT COUNT(*) FROM @allDirectives WHERE [directive] LIKE '%BROKER%') > 1 BEGIN 
			RAISERROR(N'Invalid @Directives values specified. ENABLE_BROKER, ERROR_BROKER_CONVERSATIONS, and NEW_BROKER directives are ALLOWED - but only one can be specified as part of a restore operation. Consult Books Online for more info.', 16, 1);
			RETURN -21;
		END;

		SELECT @directivesText = @directivesText + [directive] + N', ' FROM @allDirectives ORDER BY [row_id];
	END;

	-----------------------------------------------------------------------------
    -- 'Global' Variables:
    DECLARE @isValid bit;
    DECLARE @earlyTermination nvarchar(MAX) = N'';
    DECLARE @emailErrorMessage nvarchar(MAX);
    DECLARE @emailSubject nvarchar(300);
    DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
    DECLARE @tab char(1) = CHAR(9);
    DECLARE @executionID uniqueidentifier = NEWID();
    DECLARE @executeDropAllowed bit;
    DECLARE @failedDropCount int = 0;
	DECLARE @isPartialRestore bit = 0;

	-- normalize paths: 
	IF(RIGHT(@BackupsRootPath, 1) = '\')
		SET @BackupsRootPath = LEFT(@BackupsRootPath, LEN(@BackupsRootPath) - 1);

    -- Verify Paths: 
    EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;
    
    EXEC dbo.check_paths @RestoredRootDataPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@RestoredRootDataPath (' + @RestoredRootDataPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    EXEC dbo.check_paths @RestoredRootLogPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@RestoredRootLogPath (' + @RestoredRootLogPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    -----------------------------------------------------------------------------
    -- Construct list of databases to restore:
    DECLARE @dbsToRestore table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	-- If the {READ_FROM_FILESYSTEM} token is specified, replace {READ_FROM_FILESYSTEM} in @DatabasesToRestore with a serialized list of db-names pulled from @BackupRootPath:
	IF ((SELECT dbo.[count_matches](@DatabasesToRestore, N'{READ_FROM_FILESYSTEM}')) > 0) BEGIN
		DECLARE @databases xml = NULL;
		DECLARE @serialized nvarchar(MAX) = '';

		EXEC dbo.[load_backup_database_names]
		    @TargetDirectory = @BackupsRootPath,
		    @SerializedOutput = @databases OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@databases.nodes('//database') [data]([row])
		) 

		SELECT 
			@serialized = @serialized + [database_name] + N','
		FROM 
			shredded 
		ORDER BY 
			row_id;

		IF @serialized = N'' BEGIN
			RAISERROR(N'No sub-folders (potential database backups) found at path specified by @BackupsRootPath. Please double-check your input.', 16, 1);
			RETURN -30;
		  END;
		ELSE
			SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);

		SET @DatabasesToRestore = REPLACE(@DatabasesToRestore, N'{READ_FROM_FILESYSTEM}', @serialized); 
	END;
    
    INSERT INTO @dbsToRestore ([database_name])
    EXEC dbo.list_databases
        @Targets = @DatabasesToRestore,         
        @Exclusions = @DatabasesToExclude,		-- only works if {READ_FROM_FILESYSTEM} is specified for @Input... 
        @Priorities = @Priorities,

		-- ALLOW these to be included ... they'll throw exceptions if REPLACE isn't specified. But if it is SPECIFIED, then someone is trying to EXPLICTLY overwrite 'bunk' databases with a restore... 
		@ExcludeSecondaries = 0,
		@ExcludeRestoring = 0,
		@ExcludeRecovering = 0,	
		@ExcludeOffline = 0;

    IF NOT EXISTS (SELECT NULL FROM @dbsToRestore) BEGIN
        RAISERROR('No Databases Specified to Restore. Please Check inputs for @DatabasesToRestore + @DatabasesToExclude and retry.', 16, 1);
        RETURN -20;
    END;

    -- TODO: @serialized no longer contains a legit list of targets... (@dbsToRestore does).
    --IF @PrintOnly = 1 BEGIN;
    --    PRINT '-- Databases To Attempt Restore Against: ' + @serialized;
    --END;

    DECLARE @databaseToRestore sysname;
    DECLARE @restoredName sysname;

    DECLARE @fullRestoreTemplate nvarchar(MAX) = N'RESTORE DATABASE [{0}] FROM DISK = N''{1}''' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'WITH {partial}' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + '{move}, ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'NORECOVERY;'; 
    DECLARE @move nvarchar(MAX);
    DECLARE @restoreLogId int;
    DECLARE @sourcePath nvarchar(500);
    DECLARE @statusDetail nvarchar(MAX);
    DECLARE @pathToDatabaseBackup nvarchar(600);
    DECLARE @outcome varchar(4000);
	DECLARE @fileList nvarchar(MAX) = NULL; 
	DECLARE @backupName sysname;
	DECLARE @fileListXml nvarchar(MAX);

	-- dbo.execute_command variables: 
	DECLARE @execOutcome bit;
	DECLARE @execResults xml;

	DECLARE @ignoredLogFiles int = 0;

	DECLARE @logFilesToRestore table ( 
		id int IDENTITY(1,1) NOT NULL, 
		log_file sysname NOT NULL
	);
	DECLARE @currentLogFileID int = 0;

	DECLARE @restoredFiles table (
		ID int IDENTITY(1,1) NOT NULL, 
		[FileName] nvarchar(400) NOT NULL, 
		Detected datetime NOT NULL, 
		BackupCreated datetime NULL, 
		Applied datetime NULL, 
		BackupSize bigint NULL, 
		Compressed bit NULL, 
		[Encrypted] bit NULL, 
		[Comment] nvarchar(MAX) NULL
	); 

	DECLARE @backupDate datetime, @backupSize bigint, @compressed bit, @encrypted bit;

    -- Assemble a list of dbs (if any) that were NOT dropped during the last execution (only) - so that we can drop them before proceeding. 
    DECLARE @NonDroppedFromPreviousExecution table( 
        [Database] sysname NOT NULL, 
        RestoredAs sysname NOT NULL
    );

    DECLARE @LatestBatch uniqueidentifier;
    SELECT @LatestBatch = (SELECT TOP(1) execution_id FROM dbo.restore_log ORDER BY restore_id DESC);

    INSERT INTO @NonDroppedFromPreviousExecution ([Database], RestoredAs)
    SELECT [database], [restored_as]
    FROM dbo.restore_log 
    WHERE execution_id = @LatestBatch
        AND [dropped] = 'NOT-DROPPED'
        AND [restored_as] IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM sys.databases WHERE UPPER(state_desc) = 'RESTORING');  -- make sure we're only targeting DBs in the 'restoring' state too. 

    IF @CheckConsistency = 1 BEGIN
        IF OBJECT_ID('tempdb..#DBCC_OUTPUT') IS NOT NULL 
            DROP TABLE #DBCC_OUTPUT;

        CREATE TABLE #DBCC_OUTPUT(
                RowID int IDENTITY(1,1) NOT NULL, 
                Error int NULL,
                [Level] int NULL,
                [State] int NULL,
                MessageText nvarchar(2048) NULL,
                RepairLevel nvarchar(22) NULL,
                [Status] int NULL,
                [DbId] int NULL, -- was smallint in SQL2005
                DbFragId int NULL,      -- new in SQL2012
                ObjectId int NULL,
                IndexId int NULL,
                PartitionId bigint NULL,
                AllocUnitId bigint NULL,
                RidDbId smallint NULL,  -- new in SQL2012
                RidPruId smallint NULL, -- new in SQL2012
                [File] smallint NULL,
                [Page] int NULL,
                Slot int NULL,
                RefDbId smallint NULL,  -- new in SQL2012
                RefPruId smallint NULL, -- new in SQL2012
                RefFile smallint NULL,
                RefPage int NULL,
                RefSlot int NULL,
                Allocation smallint NULL
        );
    END;

    CREATE TABLE #FileList (
        LogicalName nvarchar(128) NOT NULL, 
        PhysicalName nvarchar(260) NOT NULL,
        [Type] CHAR(1) NOT NULL, 
        FileGroupName nvarchar(128) NULL, 
        Size numeric(20,0) NOT NULL, 
        MaxSize numeric(20,0) NOT NULL, 
        FileID bigint NOT NULL, 
        CreateLSN numeric(25,0) NOT NULL, 
        DropLSN numeric(25,0) NULL, 
        UniqueId uniqueidentifier NOT NULL, 
        ReadOnlyLSN numeric(25,0) NULL, 
        ReadWriteLSN numeric(25,0) NULL, 
        BackupSizeInBytes bigint NOT NULL, 
        SourceBlockSize int NOT NULL, 
        FileGroupId int NOT NULL, 
        LogGroupGUID uniqueidentifier NULL, 
        DifferentialBaseLSN numeric(25,0) NULL, 
        DifferentialBaseGUID uniqueidentifier NOT NULL, 
        IsReadOnly bit NOT NULL, 
        IsPresent bit NOT NULL, 
        TDEThumbprint varbinary(32) NULL
    );

    -- SQL Server 2016 adds SnapshotURL of nvarchar(360) for azure stuff:
	IF (SELECT dbo.get_engine_version()) >= 13.0 BEGIN
        ALTER TABLE #FileList ADD SnapshotURL nvarchar(360) NULL;
    END;

    DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
    SELECT 
        [database_name]
    FROM 
        @dbsToRestore
    WHERE
        LEN([database_name]) > 0
    ORDER BY 
        entry_id;

    DECLARE @command nvarchar(2000);

    OPEN restorer;

    FETCH NEXT FROM restorer INTO @databaseToRestore;
    WHILE @@FETCH_STATUS = 0 BEGIN
        
		-- reset every 'loop' through... 
		SET @ignoredLogFiles = 0;
        SET @statusDetail = NULL; 
		SET @isPartialRestore = 0;
        DELETE FROM @restoredFiles;
		
		SET @restoredName = REPLACE(@RestoredDbNamePattern, N'{0}', @databaseToRestore);
        IF (@restoredName = @databaseToRestore) AND (@RestoredDbNamePattern <> '{0}') -- then there wasn't a {0} token - so set @restoredName to @RestoredDbNamePattern
            SET @restoredName = @RestoredDbNamePattern;  -- which seems odd, but if they specified @RestoredDbNamePattern = 'Production2', then that's THE name they want...

        IF @PrintOnly = 0 BEGIN
            INSERT INTO dbo.restore_log (execution_id, [database], restored_as, restore_start, error_details)
            VALUES (@executionID, @databaseToRestore, @restoredName, GETDATE(), '#UNKNOWN ERROR#');

            SELECT @restoreLogId = SCOPE_IDENTITY();
        END;

        -- Verify Path to Source db's backups:
        SET @sourcePath = @BackupsRootPath + N'\' + @databaseToRestore;
        EXEC dbo.check_paths @sourcePath, @isValid OUTPUT;
        IF @isValid = 0 BEGIN 
			SET @statusDetail = N'The backup path: ' + @sourcePath + ' is invalid.';
			GOTO NextDatabase;
        END;
        
		-- Process attempt to overwrite an existing database: 
		IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN

			-- IF we're going to allow an explicit REPLACE, start by putting the target DB into SINGLE_USER mode: 
			IF @AllowReplace = N'REPLACE' BEGIN
				

				BEGIN TRY 

					IF EXISTS(SELECT NULL FROM sys.databases WHERE [name] = @restoredName AND state_desc = 'ONLINE') BEGIN

						SET @command = N'ALTER DATABASE ' + QUOTENAME(@restoredName) + ' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + @crlf
							+ N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';' + @crlf + @crlf;
							
						IF @PrintOnly = 1 BEGIN
							PRINT @command;
							END;
						ELSE BEGIN
							
							EXEC @execOutcome = dbo.[execute_command]
								@Command = @command, 
								@DelayBetweenAttempts = N'8 seconds',
								@IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS],[SINGLE_USER]', 
								@Results = @execResults OUTPUT;

							IF @execOutcome <> 0 
								SET @statusDetail = N'Error with SINGLE_USER > DROP operations: ' + CAST(@execResults AS nvarchar(MAX));
						END;

					  END;
					ELSE BEGIN -- at this point, the targetDB exists ... and it's NOT 'ONLINE' so... it's restoring, suspect, whatever, and we've been given explicit instructions to replace it:
						
						SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';' + @crlf + @crlf;

						IF @PrintOnly = 1 BEGIN 
							PRINT @command;
						  END;
						ELSE BEGIN 
							
							EXEC @execOutcome = dbo.[execute_command]
								@Command = @command, 
								@DelayBetweenAttempts = N'8 seconds',
								@IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS],[SINGLE_USER]', 
								@Results = @execResults OUTPUT;
							
							IF @execOutcome <> 0 
								SET @statusDetail = N'Error with DROP DATABASE: ' + CAST(@execResults AS nvarchar(MAX));

						END;

					END;

				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while setting target database: [' + @restoredName + N'] into SINGLE_USER mode and/or attempting to DROP target database for explicit REPLACE operation. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH

				IF @statusDetail IS NOT NULL
					GOTO NextDatabase;

			  END;
			ELSE BEGIN
				SET @statusDetail = N'Cannot restore database [' + @databaseToRestore + N'] as [' + @restoredName + N'] - because target database already exists. Consult documentation for WARNINGS and options for using @AllowReplace parameter.';
				GOTO NextDatabase;
			END;
        END;

		-- Check for a FULL backup: 
		--			NOTE: If dbo.load_backup_files does NOT return any results and if @databaseToRestore is a {SYSTEM} database, then dbo.load_backup_files will check @SourcePath + @ServerName as well - i.e., it accounts for @AppendServerNameToSystemDbs 
		EXEC dbo.load_backup_files 
            @DatabaseToRestore = @databaseToRestore, 
            @SourcePath = @sourcePath, 
            @Mode = N'FULL', 
            @Output = @fileList OUTPUT;
		
		IF(NULLIF(@fileList,N'') IS NULL) BEGIN
			SET @statusDetail = N'No FULL backups found for database [' + @databaseToRestore + N'] in "' + @sourcePath + N'".';
			GOTO NextDatabase;	
		END;

        -- Load Backup details/etc. 
		SELECT @backupName = @fileList;
		SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName;

		-- define the list of files to be processed:
		INSERT INTO @restoredFiles ([FileName], [Detected])
		SELECT 
			@backupName, 
			GETDATE(); -- detected (i.e., when this file was 'found' and 'added' for processing).  

        -- Query file destinations:
        SET @move = N'';
        SET @command = N'RESTORE FILELISTONLY FROM DISK = N''' + @pathToDatabaseBackup + ''';';

        IF @PrintOnly = 1 BEGIN
            PRINT N'-- ' + @command;
        END;

        BEGIN TRY 
            DELETE FROM #FileList;
            INSERT INTO #FileList -- shorthand syntax is usually bad, but... whatever. 
            EXEC sys.sp_executesql @command;
        END TRY
        BEGIN CATCH
            SELECT @statusDetail = N'Unexpected Error Restoring FileList: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            
            GOTO NextDatabase;
        END CATCH;
    
        -- Make sure we got some files (i.e. RESTORE FILELIST doesn't always throw exceptions if the path you send it sucks):
        IF ((SELECT COUNT(*) FROM #FileList) < 2) BEGIN
            SET @statusDetail = N'The backup located at [' + @pathToDatabaseBackup + N'] is invalid, corrupt, or does not contain a viable FULL backup.';
            GOTO NextDatabase;
        END;

		IF EXISTS (SELECT NULL FROM [#FileList] WHERE [IsPresent] = 0) BEGIN
			SET @isPartialRestore = 1;
		END;
        
        -- Map File Destinations:
        DECLARE @LogicalFileName sysname, @FileId bigint, @Type char(1);
        DECLARE mover CURSOR LOCAL FAST_FORWARD FOR 
        SELECT 
            LogicalName, FileID, [Type]
        FROM 
            #FileList
		WHERE 
			[IsPresent] = 1 -- allow for partial restores
        ORDER BY 
            FileID;

        OPEN mover; 
        FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;

        WHILE @@FETCH_STATUS = 0 BEGIN 

            SET @move = @move + N'MOVE ''' + @LogicalFileName + N''' TO ''' + CASE WHEN @FileId = 2 THEN @RestoredRootLogPath ELSE @RestoredRootDataPath END + N'\' + @restoredName + '.';
            IF @FileId = 1
                SET @move = @move + N'mdf';
            IF @FileId = 2
                SET @move = @move + N'ldf';
            IF @FileId NOT IN (1, 2)
                SET @move = @move + N'ndf';

            SET @move = @move + N''', '

            FETCH NEXT FROM mover INTO @LogicalFileName, @FileId, @Type;
        END;

        CLOSE mover;
        DEALLOCATE mover;

        SET @move = LEFT(@move, LEN(@move) - 1); -- remove the trailing ", "... 

        -- Set up the Restore Command and Execute:
        SET @command = REPLACE(@fullRestoreTemplate, N'{0}', @restoredName);
        SET @command = REPLACE(@command, N'{1}', @pathToDatabaseBackup);
        SET @command = REPLACE(@command, N'{move}', @move);
		SET @command = REPLACE(@command, N'{partial}', (CASE WHEN @isPartialRestore = 1 THEN N'PARTIAL, ' ELSE N'' END));
		
        BEGIN TRY 
            IF @PrintOnly = 1 BEGIN
                PRINT @command;
              END;
            ELSE BEGIN
                SET @outcome = NULL;
                EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

                SET @statusDetail = @outcome;
            END;
        END TRY 
        BEGIN CATCH
            SELECT @statusDetail = N'Unexpected Exception while executing FULL Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();			
        END CATCH

        IF @statusDetail IS NOT NULL BEGIN
            GOTO NextDatabase;
        END;

		-- Update MetaData: 
		EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

		UPDATE @restoredFiles 
		SET 
			[Applied] = GETDATE(), 
			[BackupCreated] = @backupDate, 
			[BackupSize] = @backupSize, 
			[Compressed] = @compressed, 
			[Encrypted] = @encrypted
		WHERE 
			[FileName] = @backupName;
        
		-- Restore any DIFF backups if present:
        SET @fileList = NULL;
		EXEC dbo.load_backup_files 
            @DatabaseToRestore = @databaseToRestore, 
            @SourcePath = @sourcePath, 
            @Mode = N'DIFF', 
            @LastAppliedFile = @backupName, 
            @Output = @fileList OUTPUT;
		
		IF NULLIF(@fileList, N'') IS NOT NULL BEGIN
			SET @backupName = @fileList;
			SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName

            SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName) + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';

			INSERT INTO @restoredFiles ([FileName], [Detected])
			SELECT @backupName, GETDATE();

            BEGIN TRY
                IF @PrintOnly = 1 BEGIN
                    PRINT @command;
                  END;
                ELSE BEGIN
                    SET @outcome = NULL;
                    EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

                    SET @statusDetail = @outcome;
                END;
            END TRY
            BEGIN CATCH
                SELECT @statusDetail = N'Unexpected Exception while executing DIFF Restore from File: "' + @pathToDatabaseBackup + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            END CATCH

            IF @statusDetail IS NOT NULL BEGIN
                GOTO NextDatabase;
            END;

			-- Update MetaData: 
			EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

			UPDATE @restoredFiles 
			SET 
				[Applied] = GETDATE(), 
				[BackupCreated] = @backupDate, 
				[BackupSize] = @backupSize, 
				[Compressed] = @compressed, 
				[Encrypted] = @encrypted
			WHERE 
				[FileName] = @backupName;
		END;

        -- Restore any LOG backups if specified and if present:
        IF @SkipLogBackups = 0 BEGIN
			
			-- reset values per every 'loop' of main processing body:
			DELETE FROM @logFilesToRestore;

            SET @fileList = NULL;
			EXEC dbo.load_backup_files 
                @DatabaseToRestore = @databaseToRestore, 
                @SourcePath = @sourcePath, 
                @Mode = N'LOG', 
                @LastAppliedFile = @backupName,
                @Output = @fileList OUTPUT;

			INSERT INTO @logFilesToRestore ([log_file])
			SELECT result FROM dbo.[split_string](@fileList, N',', 1) ORDER BY row_id;
			
			-- re-update the counter: 
			SET @currentLogFileID = ISNULL((SELECT MIN(id) FROM @logFilesToRestore), @currentLogFileID + 1);

			-- start a loop to process files while they're still available: 
			WHILE EXISTS (SELECT NULL FROM @logFilesToRestore WHERE [id] = @currentLogFileID) BEGIN

				SELECT @backupName = log_file FROM @logFilesToRestore WHERE id = @currentLogFileID;
				SET @pathToDatabaseBackup = @sourcePath + N'\' + @backupName;

				INSERT INTO @restoredFiles ([FileName], [Detected])
				SELECT @backupName, GETDATE();

                SET @command = N'RESTORE LOG ' + QUOTENAME(@restoredName) + N' FROM DISK = N''' + @pathToDatabaseBackup + N''' WITH NORECOVERY;';
                
                BEGIN TRY 
                    IF @PrintOnly = 1 BEGIN
                        PRINT @command;
                      END;
                    ELSE BEGIN
                        SET @outcome = NULL;
                        EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

                        SET @statusDetail = @outcome;
                    END;
                END TRY
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @backupName + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

                END CATCH

				-- Update MetaData: 
				EXEC dbo.load_header_details @BackupPath = @pathToDatabaseBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

				UPDATE @restoredFiles 
				SET 
					[Applied] = GETDATE(), 
					[BackupCreated] = @backupDate, 
					[BackupSize] = @backupSize, 
					[Compressed] = @compressed, 
					[Encrypted] = @encrypted, 
					[Comment] = @statusDetail
				WHERE 
					[FileName] = @backupName;

				-- S4-86: Account for scenarios where we're told that the T-LOG is too 'early' (i.e., old): 
				IF @statusDetail LIKE '%terminates%which is too early%a more recent log backup%can be restored%' BEGIN
					SET @ignoredLogFiles += 1;  

					IF @ignoredLogFiles < 3					
						SET @statusDetail = NULL; 	
				END;

                IF @statusDetail IS NOT NULL BEGIN
                    GOTO NextDatabase;
                END;

				-- Check for any new files if we're now 'out' of files to process: 
				IF @currentLogFileID = (SELECT MAX(id) FROM @logFilesToRestore) BEGIN

					-- if there are any new log files, we'll get those... and they'll be added to the list of files to process (along with newer (higher) ids)... 
                    SET @fileList = NULL;
					EXEC dbo.load_backup_files 
                        @DatabaseToRestore = @databaseToRestore, 
                        @SourcePath = @sourcePath, 
                        @Mode = N'LOG', 
                        @LastAppliedFile = @backupName,
                        @Output = @fileList OUTPUT;

					INSERT INTO @logFilesToRestore ([log_file])
					SELECT result FROM dbo.[split_string](@fileList, N',', 1) WHERE [result] NOT IN (SELECT [log_file] FROM @logFilesToRestore)
					ORDER BY row_id;
				END;

				-- increment: 
				SET @currentLogFileID = @currentLogFileID + 1;
			END;
        END;

        -- Recover the database if instructed: 
		IF @ExecuteRecovery = 1 BEGIN
			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@restoredName) + N' WITH {directives}RECOVERY;';
			SET @command = REPLACE(@command, N'{directives}', @directivesText);

			BEGIN TRY
				IF @PrintOnly = 1 BEGIN
					PRINT @command;
				  END;
				ELSE BEGIN
					SET @outcome = NULL;

                    -- TODO: do I want to specify a DIFFERENT (subset/set) of 'filters' for RESTORE and RECOVERY? (don't really think so, unless there are ever problems with 'overlap' and/or confusion.
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @Result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END;
			END TRY	
			BEGIN CATCH
				SELECT @statusDetail = N'Unexpected Exception while attempting to RECOVER database [' + @restoredName + N'. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				
				UPDATE dbo.[restore_log]
				SET 
					[recovery] = 'FAILED'
				WHERE 
					restore_id = @restoreLogId;

			END CATCH

			IF @statusDetail IS NOT NULL BEGIN
				GOTO NextDatabase;
			END;
		END;

        -- If we've made it here, then we need to update logging/meta-data:
        IF @PrintOnly = 0 BEGIN
            UPDATE dbo.restore_log 
            SET 
                restore_succeeded = 1,
				[recovery] = CASE WHEN @ExecuteRecovery = 0 THEN 'NORECOVERY' ELSE 'RECOVERED' END, 
                restore_end = GETDATE(), 
                error_details = NULL
            WHERE 
                restore_id = @restoreLogId;
        END;

        -- Run consistency checks if specified:
        IF @CheckConsistency = 1 BEGIN

            SET @command = N'DBCC CHECKDB([' + @restoredName + N']) WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS;'; -- outputting data for review/analysis. 

            IF @PrintOnly = 0 BEGIN 
                UPDATE dbo.restore_log
                SET 
                    consistency_start = GETDATE(),
                    consistency_succeeded = 0, 
                    error_details = '#UNKNOWN ERROR CHECKING CONSISTENCY#'
                WHERE
                    restore_id = @restoreLogId;
            END;

            BEGIN TRY 
                IF @PrintOnly = 1 
                    PRINT @command;
                ELSE BEGIN 
                    DELETE FROM #DBCC_OUTPUT;
                    INSERT INTO #DBCC_OUTPUT (Error, [Level], [State], MessageText, RepairLevel, [Status], [DbId], DbFragId, ObjectId, IndexId, PartitionId, AllocUnitId, RidDbId, RidPruId, [File], [Page], Slot, RefDbId, RefPruId, RefFile, RefPage, RefSlot, Allocation)
                    EXEC sp_executesql @command; 

                    IF EXISTS (SELECT NULL FROM #DBCC_OUTPUT) BEGIN -- consistency errors: 
                        SET @statusDetail = N'CONSISTENCY ERRORS DETECTED against database ' + QUOTENAME(@restoredName) + N'. Details: ' + @crlf;
                        SELECT @statusDetail = @statusDetail + MessageText + @crlf FROM #DBCC_OUTPUT ORDER BY RowID;

                        UPDATE dbo.restore_log
                        SET 
                            consistency_end = GETDATE(),
                            consistency_succeeded = 0,
                            error_details = @statusDetail
                        WHERE 
                            restore_id = @restoreLogId;

                      END;
                    ELSE BEGIN -- there were NO errors:
                        UPDATE dbo.restore_log
                        SET
                            consistency_end = GETDATE(),
                            consistency_succeeded = 1, 
                            error_details = NULL
                        WHERE 
                            restore_id = @restoreLogId;

                    END;
                END;

            END TRY	
            BEGIN CATCH
                SELECT @statusDetail = N'Unexpected Exception while running consistency checks. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
                GOTO NextDatabase;
            END CATCH

        END;

-- Primary Restore/Restore-Testing complete - log file lists, and cleanup/prep for next db to process... 
NextDatabase:

        -- Record any error details as needed:
        IF @statusDetail IS NOT NULL BEGIN

            IF @PrintOnly = 1 BEGIN
                PRINT N'ERROR: ' + @statusDetail;
              END;
            ELSE BEGIN
                UPDATE dbo.restore_log
                SET 
                    error_details = @statusDetail
                WHERE 
                    restore_id = @restoreLogId;
            END;

          END;
		ELSE BEGIN 
			PRINT N'-- Operations for database [' + @restoredName + N'] completed successfully.' + @crlf + @crlf;
		END; 

		-- serialize restored file details and push into dbo.restore_log
		SELECT @fileListXml = (
			SELECT 
				ROW_NUMBER() OVER (ORDER BY ID) [@id],
				[FileName] [name], 
				BackupCreated [created],
				Detected [detected], 
				Applied [applied], 
				BackupSize [size], 
				Compressed [compressed], 
				[Encrypted] [encrypted], 
				[Comment] [comments]
			FROM 
				@restoredFiles 
			ORDER BY 
				ID
			FOR XML PATH('file'), ROOT('files')
		);

		IF @PrintOnly = 1
			PRINT N'-- ' + @fileListXml; 
		ELSE BEGIN
			UPDATE dbo.[restore_log] 
			SET 
				restored_files = @fileListXml  -- may be null in some cases (i.e., no FULL backup found or db backups not found/etc.) but... meh. 
			WHERE 
				[restore_id] = @restoreLogId;
		END;

        -- Drop the database if specified and if all SAFE drop precautions apply:
        IF @DropDatabasesAfterRestore = 1 BEGIN
            
            -- Make sure we can/will ONLY restore databases that we've restored in this session. 
            SELECT @executeDropAllowed = restore_succeeded FROM dbo.restore_log WHERE restored_as = @restoredName AND execution_id = @executionID;

            IF @PrintOnly = 1 AND @DropDatabasesAfterRestore = 1
                SET @executeDropAllowed = 1; 
            
            IF ISNULL(@executeDropAllowed, 0) = 0 BEGIN 

				--MKC: BUG S4-11 - see the alternate 'option' for processing this below. But, given the potential for RISK (i.e., to dropping a real db), 'erroring out' here seems like the best and safest solution.
                UPDATE dbo.restore_log
                SET 
                    [dropped] = 'ERROR', 
                    error_details = ISNULL(error_details, N'') + @crlf + N'Database was NOT successfully restored - but WAS slated to be DROPPED as part of processing.'
                WHERE 
                    restore_id = @restoreLogId;

				--MKC: Bug S4-11 - the flow below MIGHT work... but I don't BELIEVE that the logic for SET @executeDropAllowed = 1 is fully thought out... so, until I assess that further, this whole block of code will be ignored. 
				--IF @restoredName <> @databaseToRestore BEGIN
				--	SET @executeDropAllowed = 1;  -- @AllowReplace and @DropDatabasesAfterRestore can NOT both be set to true. So, if the restoredDB.name <> backupSourceDB.name then... we can drop this database
				--  END;
				--ELSE BEGIN 
				--	-- otherwise, we can't... this could be a legit/production db so we can't drop it. So flag it as a problem: 
				--	UPDATE dbo.restore_log
				--	SET 
				--		[dropped] = 'ERROR', 
				--		error_details = ISNULL(error_details, N'') + @crlf + N'Database was NOT successfully restored - but WAS slated to be DROPPED as part of processing.'
				--	WHERE 
				--		restore_id = @restoreLogId;
				--END;

            END;

            IF (@executeDropAllowed = 1) AND EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @restoredName) BEGIN -- this is a db we restored (or tried to restore) in this 'session' - so we can drop it:
                SET @command = N'DROP DATABASE ' + QUOTENAME(@restoredName) + N';';

                BEGIN TRY 
                    IF @PrintOnly = 1 
                        PRINT @command;
                    ELSE BEGIN
                        UPDATE dbo.restore_log 
                        SET 
                            [dropped] = N'ATTEMPTED'
                        WHERE 
                            restore_id = @restoreLogId;

                        EXEC sys.sp_executesql @command;

                        IF EXISTS (SELECT NULL FROM master.sys.databases WHERE [name] = @restoredName) BEGIN
                            SET @statusDetail = N'Executed command to DROP database [' + @restoredName + N']. No exceptions encountered, but database still in place POST-DROP.';

                            SET @failedDropCount = @failedDropCount +1;
                          END;
                        ELSE -- happy / expected outcome:
                            UPDATE dbo.restore_log
                            SET 
                                dropped = 'DROPPED'
                            WHERE 
                                restore_id = @restoreLogId;
                    END;

                END TRY 
                BEGIN CATCH
                    SELECT @statusDetail = N'Unexpected Exception while attempting to DROP database [' + @restoredName + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

                    UPDATE dbo.restore_log
                    SET 
                        dropped = 'ERROR', 
						[error_details] = ISNULL(error_details, N'') + @statusDetail
                    WHERE 
                        restore_id = @restoreLogId;

                    SET @failedDropCount = @failedDropCount +1;
                END CATCH
            END;

          END;
        ELSE BEGIN
            UPDATE dbo.restore_log 
            SET 
                dropped = 'LEFT ONLINE' -- same as 'NOT DROPPED' but shows explicit intention.
            WHERE
                restore_id = @restoreLogId;
        END;

        -- Check-up on total number of 'failed drops':
		IF @DropDatabasesAfterRestore = 1 BEGIN 
			SELECT @failedDropCount = COUNT(*) FROM dbo.[restore_log] WHERE [execution_id] = @executionID AND [dropped] IN ('ATTEMPTED', 'ERROR');

			IF @failedDropCount >= @MaxNumberOfFailedDrops BEGIN 
				-- we're done - no more processing (don't want to risk running out of space with too many restore operations.
				SET @earlyTermination = N'Max number of databases that could NOT be dropped after restore/testing was reached. Early terminatation forced to reduce risk of causing storage problems.';
				GOTO FINALIZE;
			END;
		END;

        FETCH NEXT FROM restorer INTO @databaseToRestore;
    END

    -----------------------------------------------------------------------------
FINALIZE:

    -- close/deallocate any cursors left open:
    IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN
        CLOSE restorer;
        DEALLOCATE restorer;
    END;

    IF (SELECT CURSOR_STATUS('local','mover')) > -1 BEGIN
        CLOSE mover;
        DEALLOCATE mover;
    END;

    IF (SELECT CURSOR_STATUS('local','logger')) > -1 BEGIN
        CLOSE logger;
        DEALLOCATE logger;
    END;

	-- Process RPO Warnings: 
	DECLARE @rpoWarnings nvarchar(MAX) = NULL;
	IF NULLIF(@RpoWarningThreshold, N'') IS NOT NULL BEGIN 
		
		DECLARE @rpo sysname = (SELECT dbo.[format_timespan](@vector * 1000));
		DECLARE @rpoMessage nvarchar(MAX) = N'';

		SELECT 
			[database], 
			[restored_files],
			[restore_end]
		INTO #subset
		FROM 
			dbo.[restore_log] 
		WHERE 
			[execution_id] = @executionID
		ORDER BY
			[restore_id];

		WITH core AS ( 
			SELECT 
				s.[database], 
				s.restored_files.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime') [most_recent_backup],
				s.[restore_end]
			FROM 
				#subset s
		)

		SELECT 
			IDENTITY(int, 1, 1) [id],
			c.[database], 
			c.[most_recent_backup], 
			c.[restore_end], 
			CASE WHEN ((DATEDIFF(DAY, [c].[most_recent_backup], [c].[restore_end])) < 20) THEN -1 ELSE (DATEDIFF(DAY, [c].[most_recent_backup], [c].[restore_end])) END [days_old], 
			CASE WHEN ((DATEDIFF(DAY, [c].[most_recent_backup], [c].[restore_end])) > 20) THEN -1 ELSE (DATEDIFF(SECOND, [c].[most_recent_backup], [c].[restore_end])) END [vector]
		INTO 
			#stale 
		FROM 
			[core] c;

		SELECT 
			@rpoMessage = @rpoMessage 
			+ @crlf + N'  WARNING: database ' + QUOTENAME([x].[database]) + N' exceeded recovery point objectives: '
			+ @crlf + @tab + N'- recovery_point_objective  : ' + @RpoWarningThreshold --  @rpo
			+ @crlf + @tab + @tab + N'- most_recent_backup: ' + CONVERT(sysname, [x].[most_recent_backup], 120) 
			+ @crlf + @tab + @tab + N'- restore_completion: ' + CONVERT(sysname, [x].[restore_end], 120)
			+  CASE WHEN [x].[vector] = -1 THEN 
					+ @crlf + @tab + @tab + @tab + N'- recovery point exceeded by: ' + CAST([x].[days_old] AS sysname) + N' days'
				ELSE 
					+ @crlf + @tab + @tab + @tab + N'- actual recovery point     : ' + dbo.[format_timespan]([x].vector)
					+ @crlf + @tab + @tab + @tab + N'- recovery point exceeded by: ' + dbo.[format_timespan]([x].vector - @vector)
				END + @crlf
		FROM 
			[#stale] x
		WHERE  
			(x.[vector] > @vector) OR [x].[days_old] > 20 
		ORDER BY 
			CASE WHEN [x].[days_old] > 20 THEN [x].[days_old] ELSE 0 END DESC, 
			[x].[vector];

		IF LEN(@rpoMessage) > 2
			SET @rpoWarnings = N'WARNINGS: ' 
				+ @crlf + @rpoMessage + @crlf + @crlf;

	END;

    -- Assemble details on errors - if there were any (i.e., logged errors OR any reason for early termination... 
    IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN

        SET @emailErrorMessage = N'ERRORS: ' + @crlf;

        SELECT 
			@emailErrorMessage = @emailErrorMessage 
			+ @crlf + N'   ERROR: problem with database ' + QUOTENAME([database]) + N'.' 
			+ @crlf + @tab + N'- source_database:' + QUOTENAME([database])
			+ @crlf + @tab + N'- restored_as: ' + QUOTENAME([restored_as]) + CASE WHEN [restore_succeeded] = 1 THEN N'' ELSE ' (attempted - but failed) ' END 
			+ @crlf
			+ @crlf + @tab + N'   - error_detail: ' + [error_details] 
			+ @crlf + @crlf
        FROM 
            dbo.restore_log
        WHERE 
            execution_id = @executionID
            AND error_details IS NOT NULL
        ORDER BY 
            restore_id;

        -- notify too that we stopped execution due to early termination:
        IF NULLIF(@earlyTermination, '') IS NOT NULL BEGIN
            SET @emailErrorMessage = @emailErrorMessage + @tab + N'- ' + @earlyTermination;
        END;
    END;
    
    IF @emailErrorMessage IS NOT NULL OR @rpoWarnings IS NOT NULL BEGIN

		SET @emailErrorMessage = ISNULL(@rpoWarnings, '') + ISNULL(@emailErrorMessage, '');

        IF @PrintOnly = 1
            PRINT N'ERROR: ' + @emailErrorMessage;
        ELSE BEGIN
            SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

            EXEC msdb..sp_notify_operator
                @profile_name = @MailProfileName,
                @name = @OperatorName,
                @subject = @emailSubject, 
                @body = @emailErrorMessage;
        END;
    END;

    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.copy_database','P') IS NOT NULL
	DROP PROC dbo.copy_database;
GO

CREATE PROC dbo.copy_database 
	@SourceDatabaseName					sysname, 
	@TargetDatabaseName					sysname, 
	@BackupsRootDirectory				nvarchar(2000)	= N'{DEFAULT}', 
	@CopyToBackupDirectory					nvarchar(2000)	= NULL,
	@DataPath							sysname			= N'{DEFAULT}', 
	@LogPath							sysname			= N'{DEFAULT}',
	@RenameLogicalFileNames				bit				= 1, 
	@OperatorName						sysname			= N'Alerts',
	@MailProfileName					sysname			= N'General', 
	@PrintOnly							bit				= 0
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF NULLIF(@SourceDatabaseName,'') IS NULL BEGIN
		RAISERROR('@SourceDatabaseName cannot be Empty/NULL. Please specify the name of the database you wish to copy (from).', 16, 1);
		RETURN -1;
	END;

	IF NULLIF(@TargetDatabaseName, '') IS NULL BEGIN
		RAISERROR('@TargetDatabaseName cannot be Empty/NULL. Please specify the name of new database that you want to create (as a copy).', 16, 1);
		RETURN -1;
	END;

	-- Make sure the target database doesn't already exist: 
	IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabaseName) BEGIN
		RAISERROR('@TargetDatabaseName already exists as a database. Either pick another target database name - or drop existing target before retrying.', 16, 1);
		RETURN -5;
	END;

	-- Allow for default paths:
	IF UPPER(@BackupsRootDirectory) = N'{DEFAULT}' BEGIN
		SELECT @BackupsRootDirectory = dbo.load_default_path('BACKUP');
	END;

	IF UPPER(@DataPath) = N'{DEFAULT}' BEGIN
		SELECT @DataPath = dbo.load_default_path('DATA');
	END;

	IF UPPER(@LogPath) = N'{DEFAULT}' BEGIN
		SELECT @LogPath = dbo.load_default_path('LOG');
	END;

	DECLARE @retention nvarchar(10) = N'110w'; -- if we're creating/copying a new db, there shouldn't be ANY backups. Just in case, give it a very wide berth... 
	DECLARE @copyToRetention nvarchar(10) = NULL;
	IF @CopyToBackupDirectory IS NOT NULL 
		SET @copyToRetention = @retention;

	PRINT N'-- Attempting to Restore a backup of [' + @SourceDatabaseName + N'] as [' + @TargetDatabaseName + N']';
	
	DECLARE @restored bit = 0;
	DECLARE @errorMessage nvarchar(MAX); 

	BEGIN TRY 
		EXEC dbo.restore_databases
			@DatabasesToRestore = @SourceDatabaseName,
			@BackupsRootPath = @BackupsRootDirectory,
			@RestoredRootDataPath = @DataPath,
			@RestoredRootLogPath = @LogPath,
			@RestoredDbNamePattern = @TargetDatabaseName,
			@SkipLogBackups = 0,
			@CheckConsistency = 0, 
			@DropDatabasesAfterRestore = 0,
			@OperatorName = @OperatorName, 
			@MailProfileName = @MailProfileName, 
			@EmailSubjectPrefix = N'[COPY DATABASE OPERATION] : ', 
			@PrintOnly = @PrintOnly;

	END TRY
	BEGIN CATCH
		SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception while restoring copy of database. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
	END CATCH

	-- 'sadly', restore_databases does a great job of handling most exceptions during execution - meaning that if we didn't get errors, that doesn't mean there weren't problems. So, let's check up: 
	IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabaseName AND state_desc = N'ONLINE') OR (@PrintOnly = 1)
		SET @restored = 1; -- success (the db wasn't there at the start of this sproc, and now it is (and it's online). 
	ELSE BEGIN 
		-- then we need to grab the latest error: 
		SELECT @errorMessage = error_details FROM dbo.restore_log WHERE restore_id = (
			SELECT MAX(restore_id) FROM dbo.restore_log WHERE operation_date = GETDATE() AND [database] = @SourceDatabaseName AND restored_as = @TargetDatabaseName);

		IF @errorMessage IS NULL BEGIN -- hmmm weird:
			SET @errorMessage = N'Unknown error with restore operation - execution did NOT complete as expected. Please Check Email for additional details/insights.';
			RETURN -20;
		END;

	END

	IF @errorMessage IS NULL
		PRINT N'-- Restore Complete. Kicking off backup [' + @TargetDatabaseName + N'].';
	ELSE BEGIN
		PRINT @errorMessage;
		RETURN -10;
	END;
	
	-- Make sure the DB owner is set correctly: 
	DECLARE @sql nvarchar(MAX) = N'ALTER AUTHORIZATION ON DATABASE::[' + @TargetDatabaseName + N'] TO sa;';
	
	IF @PrintOnly = 1 
		PRINT @sql
	ELSE 
		EXEC sp_executesql @sql;

	IF @RenameLogicalFileNames = 1 BEGIN

		DECLARE @renameTemplate nvarchar(200) = N'ALTER DATABASE ' + QUOTENAME(@TargetDatabaseName) + N' MODIFY FILE (NAME = {0}, NEWNAME = {1});' + NCHAR(13) + NCHAR(10); 
		SET @sql = N'';
		
		WITH renamed AS ( 

			SELECT 
				[name] [old_file_name], 
				REPLACE([name], @SourceDatabaseName, @TargetDatabaseName) [new_file_name], 
				[file_id]
			FROM 
				sys.[master_files] 
			WHERE 
				([database_id] = DB_ID(@TargetDatabaseName)) OR 
				(@PrintOnly = 1 AND [database_id] = DB_ID(@SourceDatabaseName))

		) 

		SELECT 
			@sql = @sql + REPLACE(REPLACE(@renameTemplate, N'{0}', [old_file_name]), N'{1}', [new_file_name])
		FROM 
			renamed
		ORDER BY 
			[file_id];

		IF @PrintOnly = 1 
			PRINT @sql; 
		ELSE 
			EXEC sys.sp_executesql @sql;

	END;


	DECLARE @backedUp bit = 0;
	IF @restored = 1 BEGIN
		
		BEGIN TRY
			EXEC dbo.backup_databases
				@BackupType = N'FULL',
				@DatabasesToBackup = @TargetDatabaseName,
				@BackupDirectory = @BackupsRootDirectory,
				@BackupRetention = @retention,
				@CopyToBackupDirectory = @CopyToBackupDirectory, 
				@CopyToRetention = @copyToRetention,
				@OperatorName = @OperatorName, 
				@MailProfileName = @MailProfileName, 
				@EmailSubjectPrefix = N'[COPY DATABASE OPERATION] : ', 
				@PrintOnly = @PrintOnly;

			SET @backedUp = 1;
		END TRY
		BEGIN CATCH
			SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception while executing backup of new/copied database. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
		END CATCH

	END;

	IF @restored = 1 AND @backedUp = 1 
		PRINT N'Operation Complete.';
	ELSE BEGIN
		PRINT N'Errors occurred during execution:';
		PRINT @errorMessage;
	END;

	RETURN 0;
GO
	


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.apply_logs','P') IS NOT NULL
	DROP PROC dbo.apply_logs;
GO

CREATE PROC dbo.apply_logs 
	@SourceDatabases					nvarchar(MAX)		= NULL,						-- explicitly named dbs - e.g., N'db1, db7, db28' ... and, only works, obviously, if dbs specified are in non-recovered mode (or standby).
	@Exclusions							nvarchar(MAX)		= NULL,
	@Priorities							nvarchar(MAX)		= NULL, 
	@BackupsRootPath					nvarchar(MAX)		= N'{DEFAULT}',
	@TargetDbMappingPattern				sysname				= N'{0}',					-- MAY not use/allow... 
	@RecoveryType						sysname				= N'NORECOVERY',			-- options are: NORECOVERY | STANDBY | RECOVERY
	@StaleAlertThreshold				nvarchar(10)		= NULL,						-- NULL means... don't bother... otherwise, if the restoring_db is > @threshold... raise an alert... 
	@AlertOnStaleOnly					bit					= 0,						-- when true, then failures won't trigger alerts - only if/when stale-threshold is exceeded is an alert sent.
	@OperatorName						sysname				= N'Alerts', 
    @MailProfileName					sysname				= N'General', 
    @EmailSubjectPrefix					sysname				= N'[APPLY LOGS] - ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
    EXEC dbo.verify_advanced_capabilities;;

    -----------------------------------------------------------------------------
    -- Validate Inputs: 
    IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
        
        -- Operator Checks:
        IF ISNULL(@OperatorName, '') IS NULL BEGIN
            RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
            RETURN -2;
         END;
        ELSE BEGIN 
            IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
                RAISERROR('Invalild Operator Name Specified.', 16, 1);
                RETURN -2;
            END;
        END;

        -- Profile Checks:
        DECLARE @DatabaseMailProfile nvarchar(255)
        EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
        IF @DatabaseMailProfile <> @MailProfileName BEGIN
            RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
            RETURN -2;
        END; 
    END;

    IF UPPER(@SourceDatabases) IN (N'{SYSTEM}', N'{USER}') BEGIN
        RAISERROR('The tokens {SYSTEM} and {USER} cannot be used to specify which databases to restore via dbo.apply_logs. Only explicitly defined/named databases can be targetted - e.g., N''myDB, anotherDB, andYetAnotherDbName''.', 16, 1);
        RETURN -10;
    END;

    IF (NULLIF(@TargetDbMappingPattern,'')) IS NULL BEGIN
        RAISERROR('@TargetDbMappingPattern can NOT be NULL or empty. Use the place-holder token ''{0}'' to represent the name of the original database (e.g., ''{0}_test'' would become ''dbname_test'' when restoring a database named ''dbname'').', 16, 1);
        RETURN -22;
    END;

	DECLARE @vectorError nvarchar(MAX);
	DECLARE @vector bigint;  -- represents # of MILLISECONDS that a 'restore' operation is allowed to be stale

	IF NULLIF(@StaleAlertThreshold, N'') IS NOT NULL BEGIN

		EXEC [dbo].[translate_vector]
			@Vector = @StaleAlertThreshold, 
			@ValidationParameterName = N'@StaleAlertThreshold', 
			@ProhibitedIntervals = NULL, 
			@TranslationDatePart = N'SECOND', 
			@Output = @vector OUTPUT, 
			@Error = @vectorError OUTPUT;

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1); 
			RETURN -30;
		END;
	END;

	-----------------------------------------------------------------------------
    -- Allow for default paths:
    IF UPPER(@BackupsRootPath) = N'{DEFAULT}' BEGIN
        SELECT @BackupsRootPath = dbo.load_default_path('BACKUP');
    END;

    -- 'Global' Variables:
    DECLARE @isValid bit;
	DECLARE @earlyTermination nvarchar(MAX) = N'';

	-- normalize paths: 
	IF(RIGHT(@BackupsRootPath, 1) = '\')
		SET @BackupsRootPath = LEFT(@BackupsRootPath, LEN(@BackupsRootPath) - 1);
    
	-- Verify Paths: 
    EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
    IF @isValid = 0 BEGIN
        SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
        GOTO FINALIZE;
    END;

    -----------------------------------------------------------------------------
    -- Construct list of databases to process:
	DECLARE @applicableDatabases table (
		entry_id int IDENTITY(1,1) NOT NULL, 
		source_database_name sysname NOT NULL,
		target_database_name sysname NOT NULL
	);

	-- If the {READ_FROM_FILESYSTEM} token is specified, replace {READ_FROM_FILESYSTEM} in @DatabasesToRestore with a serialized list of db-names pulled from @BackupRootPath:
	IF ((SELECT dbo.[count_matches](@SourceDatabases, N'{READ_FROM_FILESYSTEM}')) > 0) BEGIN
		DECLARE @databases xml = NULL;
		DECLARE @serialized nvarchar(MAX) = '';

		EXEC dbo.[load_backup_database_names]
		    @TargetDirectory = @BackupsRootPath,
		    @SerializedOutput = @databases OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@databases.nodes('//database') [data]([row])
		) 

		SELECT 
			@serialized = @serialized + [database_name] + N','
		FROM 
			shredded 
		ORDER BY 
			row_id;

		SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);

        SET @databases = NULL;
		EXEC dbo.load_backup_database_names
			@TargetDirectory = @BackupsRootPath, 
			@SerializedOutput = @databases OUTPUT;

		SET @SourceDatabases = REPLACE(@SourceDatabases, N'{READ_FROM_FILESYSTEM}', @serialized); 
	END;

	DECLARE @possibleDatabases table ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 

	INSERT INTO @possibleDatabases ([database_name])
	EXEC dbo.list_databases 
        @Targets = @SourceDatabases,         
        @Exclusions = @Exclusions,		
        @Priorities = @Priorities,

		@ExcludeSimpleRecovery = 1, 
		@ExcludeRestoring = 0, -- we're explicitly targetting just these in fact... 
		@ExcludeRecovering = 1; -- we don't want these... (they're 'too far gone')

	INSERT INTO @applicableDatabases ([source_database_name], [target_database_name])
	SELECT [database_name] [source_database_name], REPLACE(@TargetDbMappingPattern, N'{0}', [database_name]) [target_database_name] FROM @possibleDatabases ORDER BY [row_id];

    IF NOT EXISTS (SELECT NULL FROM @applicableDatabases) BEGIN
        SET @earlyTermination = N'Databases specified for apply_logs operation: [' + @SourceDatabases + ']. However, none of the databases specified can have T-LOGs applied - as there are no databases in STANDBY or NORECOVERY mode.';
        GOTO FINALIZE;
    END;

    PRINT '-- Databases To Attempt Log Application Against: ' + @serialized;

    -----------------------------------------------------------------------------
	-- start processing:
	DECLARE @executionID uniqueidentifier = NEWID();
	DECLARE @sourceDbName sysname;
	DECLARE @targetDbName sysname;
	DECLARE @fileList xml;
	DECLARE @latestPreviousFileRestored sysname;
	DECLARE @sourcePath sysname; 
	DECLARE @backupFilesList nvarchar(MAX) = NULL;
	DECLARE @currentLogFileID int;
	DECLARE @backupName sysname;
	DECLARE @pathToTLogBackup sysname;
	DECLARE @command nvarchar(2000);
	DECLARE @outcome varchar(4000);
	DECLARE @statusDetail nvarchar(500);
	DECLARE @appliedFileList nvarchar(MAX);
	DECLARE @restoreStart datetime;
	DECLARE @logsWereApplied bit = 0;
	DECLARE @operationSuccess bit;
	DECLARE @noFilesApplied bit = 0;

	DECLARE @outputSummary nvarchar(MAX);
    DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
    DECLARE @tab char(1) = CHAR(9);

	DECLARE @offset sysname;
	DECLARE @tufPath sysname;
	DECLARE @restoredFiles xml;

	-- meta-data variables:
	DECLARE @backupDate datetime, @backupSize bigint, @compressed bit, @encrypted bit;

	DECLARE @logFilesToRestore table ( 
		id int IDENTITY(1,1) NOT NULL, 
		log_file sysname NOT NULL
	);

	DECLARE @appliedFiles table (
		ID int IDENTITY(1,1) NOT NULL, 
		[FileName] nvarchar(400) NOT NULL, 
		Detected datetime NOT NULL, 
		BackupCreated datetime NULL, 
		Applied datetime NULL, 
		BackupSize bigint NULL, 
		Compressed bit NULL, 
		[Encrypted] bit NULL
	); 

	DECLARE @warnings table (
		warning_id int IDENTITY(1,1) NOT NULL, 
		warning nvarchar(MAX) NOT NULL 
	);

    DECLARE restorer CURSOR LOCAL FAST_FORWARD FOR 
    SELECT 
        [source_database_name],
		[target_database_name]
    FROM 
        @applicableDatabases
    ORDER BY 
        entry_id;

	OPEN [restorer]; 

	FETCH NEXT FROM [restorer] INTO @sourceDbName, @targetDbName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		SET @restoreStart = GETDATE();
		SET @noFilesApplied = 0;  

		-- determine last successfully applied t-log:
		SELECT @fileList = [restored_files] FROM dbo.[restore_log] WHERE [restore_id] = (SELECT MAX(restore_id) FROM [dbo].[restore_log] WHERE [database] = @sourceDbName AND [restored_as] = @targetDbName AND [restore_succeeded] = 1);

		IF @fileList IS NULL BEGIN 
			SET @statusDetail = N'Attempt to apply logs from ' + QUOTENAME(@sourceDbName) + N' to ' + QUOTENAME(@targetDbName) + N' could not be completed. No details in dbo.restore_log for last backup-file used during restore/application process. Please use dbo.restore_databases to ''seed'' databases.';
			GOTO NextDatabase;
		END; 

		SELECT @latestPreviousFileRestored = @fileList.value('(/files/file[@id = max(/files/file/@id)]/name)[1]', 'sysname');

		IF @latestPreviousFileRestored IS NULL BEGIN 
			SET @statusDetail = N'Attempt to apply logs from ' + QUOTENAME(@sourceDbName) + N' to ' + QUOTENAME(@targetDbName) + N' could not be completed. The column: restored_files in dbo.restore_log is missing data on the last file applied to ' + QUOTENAME(@targetDbName) + N'. Please use dbo.restore_databases to ''seed'' databases.';
			GOTO NextDatabase;
		END; 

		SET @sourcePath = @BackupsRootPath + N'\' + @sourceDbName;
		EXEC dbo.load_backup_files 
			@DatabaseToRestore = @sourceDbName, 
			@SourcePath = @sourcePath, 
			@Mode = N'LOG', 
			@LastAppliedFile = @latestPreviousFileRestored, 
			@Output = @backupFilesList OUTPUT;

		-- reset values per every 'loop' of main processing body:
		DELETE FROM @logFilesToRestore;

		INSERT INTO @logFilesToRestore ([log_file])
		SELECT [result] FROM dbo.[split_string](@backupFilesList, N',', 1) ORDER BY row_id;

		SET @logsWereApplied = 0;

		IF EXISTS(SELECT NULL FROM @logFilesToRestore) BEGIN

			-- switch any dbs in STANDBY back to NORECOVERY.
			IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @targetDbName AND [is_in_standby] = 1) BEGIN

				SET @command = N'ALTER DATABASE ' + QUOTENAME(@targetDbName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; 
GO
RESTORE DATABASE ' + QUOTENAME(@targetDbName) + N' WITH NORECOVERY;';

				IF @PrintOnly = 1 BEGIN 
					PRINT @command;
				  END; 
				ELSE BEGIN 

					BEGIN TRY 
						SET @outcome = NULL; 
						DECLARE @result varchar(4000);
						EXEC dbo.[execute_uncatchable_command] @command, N'UN-STANDBY', @Result = @outcome OUTPUT;

						SET @statusDetail = @outcome;

					END TRY	
					BEGIN CATCH
						SELECT @statusDetail = N'Unexpected Exception while attempting to remove database ' + QUOTENAME(@targetDbName) + N' from STANDBY mode. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
						GOTO NextDatabase;
					END CATCH

					-- give it a second, and verify the state: 
					WAITFOR DELAY '00:00:05';

					IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @targetDbName AND [is_in_standby] = 1) BEGIN
						SET @statusDetail = N'Database ' + QUOTENAME(@targetDbName) + N' was set to RESTORING but, 05 seconds later, is still in STANDBY mode.';
					END;
				END;

				-- if there were ANY problems with the operations above, we can't apply logs: 
				IF @statusDetail IS NOT NULL 
					GOTO NextDatabase;
			END;

			-- re-update the counter: 
			SET @currentLogFileID = ISNULL((SELECT MIN(id) FROM @logFilesToRestore), @currentLogFileID + 1);

			WHILE EXISTS (SELECT NULL FROM @logFilesToRestore WHERE [id] = @currentLogFileID) BEGIN

				SELECT @backupName = log_file FROM @logFilesToRestore WHERE id = @currentLogFileID;
				SET @pathToTLogBackup = @sourcePath + N'\' + @backupName;

				INSERT INTO @appliedFiles ([FileName], [Detected])
				SELECT @backupName, GETDATE();

				SET @command = N'RESTORE LOG ' + QUOTENAME(@targetDbName) + N' FROM DISK = N''' + @pathToTLogBackup + N''' WITH NORECOVERY;';
                
				BEGIN TRY 
					IF @PrintOnly = 1 BEGIN
						PRINT @command;
					  END;
					ELSE BEGIN
						SET @outcome = NULL;
						EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;
						SET @statusDetail = @outcome;
					END;
				END TRY
				BEGIN CATCH
					SELECT @statusDetail = N'Unexpected Exception while executing LOG Restore from File: "' + @backupName + N'". Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					-- don't go to NextDatabase - we need to record meta data FIRST... 
				END CATCH

				-- Update MetaData: 
				EXEC dbo.load_header_details @BackupPath = @pathToTLogBackup, @BackupDate = @backupDate OUTPUT, @BackupSize = @backupSize OUTPUT, @Compressed = @compressed OUTPUT, @Encrypted = @encrypted OUTPUT;

				UPDATE @appliedFiles 
				SET 
					[Applied] = GETDATE(), 
					[BackupCreated] = @backupDate, 
					[BackupSize] = @backupSize, 
					[Compressed] = @compressed, 
					[Encrypted] = @encrypted
				WHERE 
					[FileName] = @backupName;

				IF @statusDetail IS NOT NULL BEGIN
					GOTO NextDatabase;
				END;

				-- Check for any new files if we're now 'out' of files to process: 
				IF @currentLogFileID = (SELECT MAX(id) FROM @logFilesToRestore) BEGIN

                    SET @backupFilesList = NULL;
					-- if there are any new log files, we'll get those... and they'll be added to the list of files to process (along with newer (higher) ids)... 
					EXEC dbo.load_backup_files 
                        @DatabaseToRestore = @sourceDbName, 
                        @SourcePath = @sourcePath, 
                        @Mode = N'LOG', 
                        @LastAppliedFile = @backupName,
                        @Output = @backupFilesList OUTPUT;

					INSERT INTO @logFilesToRestore ([log_file])
					SELECT [result] FROM dbo.[split_string](@backupFilesList, N',', 1) WHERE [result] NOT IN (SELECT [log_file] FROM @logFilesToRestore)
					ORDER BY row_id;
				END;

				-- signify files applied: 
				SET @logsWereApplied = 1;

				-- increment: 
				SET @currentLogFileID = @currentLogFileID + 1;
			END;
		  END;
		ELSE BEGIN 
			-- No Log Files found/available for application (either it's too early or something ugly has happened and backups aren't pushing files). 
			SET @noFilesApplied = 1; -- which will SKIP inserting a row for this db/operation BUT @StaleAlertThreshold will still get checked (to alert if something ugly is going on.

		END;

		IF UPPER(@RecoveryType) = N'STANDBY' AND @logsWereApplied = 1 BEGIN 
						
			SET @offset = RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),7);
			SELECT @tufPath = [physical_name] FROM sys.[master_files]  WHERE database_id = DB_ID(@targetDbName) AND [file_id] = 1;

			SET @tufPath = LEFT(@tufPath, LEN(@tufPath) - (CHARINDEX(N'\', REVERSE(@tufPath)) - 1)); -- strip the filename... 

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@targetDbName) + N' WITH STANDBY = N''' + @tufPath + @targetDbName + N'_' + @offset + N'.tuf'';
ALTER DATABASE ' + QUOTENAME(@targetDbName) + N' SET MULTI_USER;';

			IF @PrintOnly = 1 BEGIN 
				PRINT @command;
			  END;
			ELSE BEGIN
				BEGIN TRY
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END TRY
				BEGIN CATCH
					SET @statusDetail = N'Exception when attempting to put database ' + QUOTENAME(@targetDbName) + N' into STANDBY mode. [Command: ' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH
			END;
		END; 

		IF UPPER(@RecoveryType) = N'RECOVERY' AND @logsWereApplied = 1 BEGIN

			SET @command = N'RESTORE DATABASE ' + QUOTENAME(@targetDbName) + N' WITH RECCOVERY;';

			IF @PrintOnly = 1 BEGIN 
				PRINT @command;
			  END;
			ELSE BEGIN
				BEGIN TRY
					SET @outcome = NULL;
					EXEC dbo.execute_uncatchable_command @command, 'RESTORE', @result = @outcome OUTPUT;

					SET @statusDetail = @outcome;
				END TRY
				BEGIN CATCH
					SET @statusDetail = N'Exception when attempting to RECOVER database ' + QUOTENAME(@targetDbName) + N'. [Command: ' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH
			END;
		END;

NextDatabase:

		-- Execute Stale Checks if configured/defined: 
		DECLARE @latestApplied datetime;
		IF NULLIF(@StaleAlertThreshold, N'') IS NOT NULL BEGIN

			IF @logsWereApplied = 1 BEGIN 
				SELECT @latestApplied = MAX([BackupCreated]) FROM @appliedFiles;  -- REFACTOR: call this variable @mostRecentBackup instead of @latestApplied... 
			  END;
			ELSE BEGIN -- grab it from the LAST successful operation 

				SELECT @restoredFiles = [restored_files] FROM dbo.[restore_log] WHERE [restore_id] = (SELECT MAX(restore_id) FROM [dbo].[restore_log] WHERE [database] = @sourceDbName AND [restored_as] = @targetDbName AND [restore_succeeded] = 1);

				IF @restoredFiles IS NULL BEGIN 
					
					PRINT 'warning ... could not get previous file details for stale check....';
				END; 

				SELECT @latestApplied = @restoredFiles.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime')
			END;

			IF DATEDIFF(SECOND, @latestApplied, GETDATE()) > @vector BEGIN 
				INSERT INTO @warnings ([warning])
				VALUES ('Database ' + QUOTENAME(@targetDbName) + N' has exceeded the amount of time allowed since successfully restoring live data to the applied/target database. Specified threshold: ' + @StaleAlertThreshold + N', CreationTime of Last live backup: ' + CONVERT(sysname, @latestApplied, 121) + N'.');
			END;

		END;

		-- serialize restored file details and push into dbo.restore_log
		SELECT @appliedFileList = (
			SELECT 
				ROW_NUMBER() OVER (ORDER BY ID) [@id],
				[FileName] [name], 
				BackupCreated [created],
				Detected [detected], 
				Applied [applied], 
				BackupSize [size], 
				Compressed [compressed], 
				[Encrypted] [encrypted]
			FROM 
				@appliedFiles 
			ORDER BY 
				ID
			FOR XML PATH('file'), ROOT('files')
		);

		IF @PrintOnly = 1
			PRINT @appliedFileList; 
		ELSE BEGIN
			
			IF @logsWereApplied = 0
				SET @operationSuccess = 0 
			ELSE 
				SET @operationSuccess =  CASE WHEN NULLIF(@statusDetail,'') IS NULL THEN 1 ELSE 0 END;

			IF @noFilesApplied = 0 BEGIN
				INSERT INTO dbo.[restore_log] ([execution_id], [operation_date], [operation_type], [database], [restored_as], [restore_start], [restore_end], [restore_succeeded], [restored_files], [recovery], [dropped], [error_details])
				VALUES (@executionID, GETDATE(), 'APPLY-LOGS', @sourceDbName, @targetDbName, @restoreStart, GETDATE(), @operationSuccess, @appliedFileList, @RecoveryType, 'LEFT-ONLINE', NULLIF(@statusDetail, ''));
			END;
		END;

		SET @outputSummary = N'Applied the following Logs: ' + @crlf;

		SELECT 
			@outputSummary = @outputSummary + @tab + [FileName] + @crlf
		FROM 
			@appliedFiles 
		ORDER BY 
			ID;

		EXEC [dbo].[print_long_string] @outputSummary;

		FETCH NEXT FROM [restorer] INTO @sourceDbName, @targetDbName;
	END; 

	CLOSE [restorer];
	DEALLOCATE [restorer];

FINALIZE:

	-- check for and close cursor (if open/etc.)
	IF (SELECT CURSOR_STATUS('local','restorer')) > -1 BEGIN;
		CLOSE [restorer];
		DEALLOCATE [restorer];
	END;

	DECLARE @messageSeverity sysname = N'';
	DECLARE @message nvarchar(MAX); 

	IF EXISTS (SELECT NULL FROM @warnings) BEGIN 
		SET @messageSeverity = N'WARNING';

		SET @message = N'The following WARNINGS were raised: ' + @crlf;

		SELECT 
			@message = @message + @crlf
			+ @tab + N'- ' + [warning]
		FROM 
			@warnings 
		ORDER BY [warning_id];

		SET @message = @message + @crlf + @crlf;
	END;

	IF (NULLIF(@earlyTermination,'') IS NOT NULL) OR (EXISTS (SELECT NULL FROM dbo.restore_log WHERE execution_id = @executionID AND error_details IS NOT NULL)) BEGIN

		IF @messageSeverity <> '' 
			SET @messageSeverity = N'ERROR & WARNING';
		ELSE 
			SET @messageSeverity = N'ERRROR';

		SET @message = @message + N'The following ERRORs were encountered: ' + @crlf 

		SELECT 
			@message  = @message + @crlf
			+ @tab + N'- Database: ' + QUOTENAME([database]) + CASE WHEN [restored_as] <> [database] THEN N' (being restored as ' + QUOTENAME([restored_as]) + N') ' ELSE N' ' END + ': ' + [error_details]
		FROM 
			dbo.restore_log 
		WHERE 
			[execution_id] = @executionID AND error_details IS NOT NULL
		ORDER BY 
			[restore_id];
	END; 

	IF @message IS NOT NULL BEGIN 

		IF @AlertOnStaleOnly = 1 BEGIN
			IF @messageSeverity NOT LIKE '%WARNING%' BEGIN
				PRINT 'Apply Errors Detected - but not raised because @AlertOnStaleOnly is set to true.';
				RETURN 0; -- early termination... 
			END;
		END;

		DECLARE @subject nvarchar(2000) = ISNULL(@EmailSubjectPrefix, N'') + @messageSeverity;

		IF @PrintOnly = 1 BEGIN 
			PRINT @subject;
			PRINT @message;
		  END;
		ELSE BEGIN 
            EXEC msdb..sp_notify_operator
                @profile_name = @MailProfileName,
                @name = @OperatorName,
                @subject = @subject, 
                @body = @message;
		END;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_recovery_metrics','P') IS NOT NULL
	DROP PROC dbo.list_recovery_metrics;
GO

CREATE PROC dbo.list_recovery_metrics 
	@TargetDatabases				nvarchar(MAX)		= N'{ALL}', 
	@ExcludedDatabases				nvarchar(MAX)		= NULL,				-- e.g., 'demo, test, %_fake, etc.'
	@Priorities						nvarchar(MAX)		= NULL,
	@Mode							sysname				= N'SUMMARY',		-- SUMMARY | SLA | RPO | RTO | ERROR | DEVIATION
	@Scope							sysname				= N'WEEK'			-- LATEST | DAY | WEEK | MONTH | QUARTER
AS 
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -----------------------------------------------------------------------------
    -- Validate Inputs: 
	-- TODO: validate inputs.... 

	-----------------------------------------------------------------------------
	-- Establish target databases and execution instances:
	CREATE TABLE #targetDatabases (
		[database_name] sysname NOT NULL
	);

	CREATE TABLE #executionIDs (
		execution_id uniqueidentifier NOT NULL
	);

	INSERT INTO [#targetDatabases] ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@Priorities = @Priorities;

	IF UPPER(@Scope) = N'LATEST'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT TOP(1) [execution_id] FROM dbo.[restore_log] ORDER BY [restore_id] DESC;

	IF UPPER(@Scope) = N'DAY'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(GETDATE() AS [date]) GROUP BY [execution_id];
	
	IF UPPER(@Scope) = N'WEEK'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(WEEK, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	

	IF UPPER(@Scope) = N'MONTH'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(MONTH, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	

	IF UPPER(@Scope) = N'QUARTER'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(QUARTER, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	
	

	-----------------------------------------------------------------------------
	-- Extract core/key details into a temp table (to prevent excessive CPU iteration later on via sub-queries/operations/presentation-types). 
	SELECT 
		l.[restore_id], 
		l.[execution_id], 
		ROW_NUMBER() OVER (ORDER BY l.[restore_id]) [row_number],
		l.[operation_date],
		l.[database], 
		l.[restored_as], 
		l.[restore_succeeded], 
		l.[restore_start], 
		l.[restore_end],
		CASE 
			WHEN l.[restore_succeeded] = 1 THEN DATEDIFF(MILLISECOND, l.[restore_start], l.[restore_end])
			ELSE 0
		END [restore_duration], 
		l.[consistency_succeeded], 
		CASE
			WHEN ISNULL(l.[consistency_succeeded], 0) = 1 THEN DATEDIFF(MILLISECOND, l.[consistency_start], l.[consistency_end])
			ELSE 0
		END [consistency_check_duration], 				
		l.[restored_files], 
		ISNULL(restored_files.value('count(/files/file)', 'int'), 0) [restored_file_count],
		ISNULL(restored_files.exist('/files/file/name[contains(., "DIFF_")]'), 0) [diff_restored],
		restored_files.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime') [latest_backup],
		l.[error_details]
	INTO 
		#facts 
	FROM 
		dbo.[restore_log] l 
		INNER JOIN [#targetDatabases] d ON l.[database] = d.[database_name]
		INNER JOIN [#executionIDs] e ON l.[execution_id] = e.[execution_id];

				-- vNEXT: 
				--		so. if there's just one db being restored per 'test' (i.e., execution) then ... only show that db's name... 
				--			but, if there are > 1 ... show all dbs in an 'xml list'... 
				--			likewise, if there's just a single db... report on rpo... total. 
				--			but, if there are > 1 dbs... show rpo_total, rpo_min, rpo_max, rpo_avg... AND... then ... repos by db.... i.e., 4 columns for total, min, max, avg and then a 5th/additional column for rpos by db as xml... 
				--			to pull this off... just need a dynamic query/projection that has {db_list} and {rpo} tokens for columns... that then get replaced as needed. 
				--				though, the trick, of course, will be to tie into the #tempTables and so on... 

	-- generate aggregate details as well: 
	SELECT 
		x.execution_id, 
		CAST((SELECT  
		CASE 
			-- note: using slightly diff xpath directives in each of these cases/options:
			WHEN [x].[database] = x.[restored_as] THEN CAST((SELECT f2.[restored_as] [restored_db] FROM [#facts] f2 WHERE x.execution_id = f2.[execution_id] ORDER BY f2.[database] FOR XML PATH(''), ROOT('dbs')) AS XML)
			ELSE CAST((SELECT f2.[database] [@source_db], f2.[restored_as] [*] FROM [#facts] f2 WHERE x.execution_id = f2.[execution_id] ORDER BY f2.[database] FOR XML PATH('restored_db'), ROOT('dbs')) AS XML)
		END [databases]
		) AS xml) [databases],
-- TODO: when I query/project this info (down below in various modes) use xpath or even a NASTY REPLACE( where I look for '<error source="[$db_name]" />') ... to remove 'empty' nodes (databases) and, ideally, just have <errors/> if/when there were NO errors.
		CAST((SELECT [database] [@source], error_details [*] FROM [#facts] f3 WHERE x.execution_id = f3.[execution_id] AND f3.[error_details] IS NOT NULL ORDER BY f3.[database] FOR XML PATH('error'), ROOT('errors')) AS xml) [errors]

-- TODO: need a 'details' column somewhat like: 
		--	<detail database="restored_db_name_here" restored_file_count="N" rpo_milliseconds="nnnn" /> ... or something similar... 
	INTO 
		#aggregates
	FROM 
		#facts x;


	IF UPPER(@Mode) IN (N'SLA', N'RPO', N'RTO') BEGIN 

		SELECT 
			[restore_id], 
			[execution_id],
			COUNT(restore_id) OVER (PARTITION BY [execution_id]) [tested_count],
			[database], 
			[restored_as],
			--DATEDIFF(DAY, [latest_backup], [restore_end]) [rpo_gap_days], 
			--DATEDIFF(DAY, [restore_start], [restore_end]) [rto_gap_days],
			DATEDIFF(MILLISECOND, [latest_backup], [restore_end]) [rpo_gap], 
			DATEDIFF(MILLISECOND, [restore_start], [restore_end]) [rto_gap]
		INTO 
			#metrics
		FROM 
			#facts;
	END; 

	-----------------------------------------------------------------------------
	-- SUMMARY: 
	IF UPPER(@Mode) = N'SUMMARY' BEGIN
	
		DECLARE @compatibilityCommand nvarchar(MAX) = N'
		SELECT 
			f.[operation_date], 
			f.[database] + N'' -> '' + f.[restored_as] [operation],
			f.[restore_succeeded], 
			f.[consistency_succeeded] [check_succeeded],
			f.[restored_file_count],
			f.[diff_restored], 
			dbo.format_timespan(f.[restore_duration]) [restore_duration],
			dbo.format_timespan(SUM(f.[restore_duration]) OVER (PARTITION BY f.[execution_id] ORDER BY f.[restore_id])) [cummulative_restore],
			dbo.format_timespan(f.[consistency_check_duration]) [check_duration], 
			dbo.format_timespan(SUM(f.[consistency_check_duration]) OVER (PARTITION BY f.[execution_id] ORDER BY f.[restore_id])) [cummulative_check], 
			CASE 
				WHEN DATEDIFF(DAY, f.[latest_backup], f.[restore_end]) > 20 THEN CAST(DATEDIFF(DAY, f.[latest_backup], f.[restore_end]) AS nvarchar(20)) + N'' days'' 
				ELSE dbo.format_timespan(DATEDIFF(MILLISECOND, f.[latest_backup], f.[restore_end])) 
			END [rpo_gap], 
			ISNULL(f.[error_details], N'''') [error_details]
		FROM 
			#facts f
		ORDER BY 
			f.[row_number]; ';

		IF (SELECT dbo.[get_engine_version]()) <= 10.5 BEGIN 
			-- TODO: the fix here won't be too hard. i.e., I just need to do the following: 
			--		a) figure out how to 'order' the rows in #facts as needed... i.e., either by a ROW_NUMBER() ... windowing function (assuming that's supported) or by means of some other option... 
			--		b) instead of using SUM() OVER ()... 
			--				just 1) create an INNER JOIN against #facts f2 ON f1.previousRowIDs <= f2.currentRowID - as per this approach: https://stackoverflow.com/a/2120639/11191
			--				then 2) just SUM against f2 instead... and that should work just fine. 
			
			-- as in... i'd create/define a DIFFERENT @compatibilityCommand 'body'... then let that be RUN below via sp_executesql... 


			RAISERROR('The SUMMARY mode is currently NOT supported in SQL Server 2008 and 2008R2.', 16, 1); 
			RETURN -100;
		END; 

		EXEC sys.[sp_executesql] @compatibilityCommand;
	END; 

	-----------------------------------------------------------------------------
	-- SLA: 
	IF UPPER(@Mode) = N'SLA' BEGIN
		DECLARE @dbTestCount int; 
		SELECT @dbTestCount = MAX([tested_count]) FROM [#metrics];

		IF @dbTestCount < 2 BEGIN
			WITH core AS ( 
				SELECT 
					f.execution_id, 
					MAX(f.[row_number]) [rank_id],
					MIN(f.[operation_date]) [test_date],
					COUNT(f.[database]) [tested_db_count],
					SUM(CAST(f.[restore_succeeded] AS int)) [restore_succeeded_count],
					SUM(CAST(f.[consistency_succeeded] AS int)) [check_succeeded_count], 
					SUM(CASE WHEN NULLIF(f.[error_details], N'') IS NULL THEN 0 ELSE 1 END) [error_count], 
					SUM(f.[restore_duration]) restore_duration, 
					SUM(f.[consistency_check_duration]) [consistency_duration], 

					-- NOTE: these really only work when there's a single db per execution_id being processed... 
					MAX(f.[restore_end]) [most_recent_restore],
					MAX(f.[latest_backup]) [most_recent_backup]
				FROM 
					#facts f
				GROUP BY 
					f.[execution_id]
			) 

			SELECT 
				x.[test_date],
				a.[databases],
				x.[tested_db_count],
				x.[restore_succeeded_count],
				x.[check_succeeded_count],
				x.[error_count],
				CASE 
					WHEN x.[error_count] = 0 THEN CAST('<errors />' AS xml)
					ELSE a.[errors]   -- TODO: strip blanks and such...   i.e., if there are 50 dbs tested, and 2x had errors, don't want to show 48x <error /> and 2x <error>blakkljdfljjlfsdfj</error>. Instead, just want to show... the 2x <error> blalsdfjldflk</errro> rows... (inside of an <errors> node... 
				END [errors],
				dbo.format_timespan(x.[restore_duration]) [recovery_time_gap],
				dbo.format_timespan(DATEDIFF(MILLISECOND, x.[most_recent_backup], x.[most_recent_restore])) [recovery_point_gap]
			FROM 
				core x
				INNER JOIN [#aggregates] a ON x.[execution_id] = a.[execution_id]
			ORDER BY 
				x.[test_date], x.[rank_id];
		  END;
		ELSE BEGIN 

			WITH core AS ( 
				SELECT 
					f.execution_id, 
					MAX(f.[row_number]) [rank_id],
					MIN(f.[operation_date]) [test_date],
					COUNT(f.[database]) [tested_db_count],
					SUM(CAST(f.[restore_succeeded] AS int)) [restore_succeeded_count],
					SUM(CAST(f.[consistency_succeeded] AS int)) [check_succeeded_count], 
					SUM(CASE WHEN NULLIF(f.[error_details], N'') IS NULL THEN 0 ELSE 1 END) [error_count], 
					SUM(f.[restore_duration]) restore_duration, 
					SUM(f.[consistency_check_duration]) [consistency_duration]
				FROM 
					#facts f
				GROUP BY 
					f.[execution_id]
			), 
			metrics AS ( 
				SELECT 
					[execution_id],
					MAX([rpo_gap]) [max_rpo_gap], 
					AVG([rpo_gap]) [avg_rpo_gap],
					MIN([rpo_gap]) [min_rpo_gap], 
					MAX([rto_gap]) [max_rto_gap], 
					AVG([rto_gap]) [avg_rto_gap],
					MIN([rto_gap]) [min_rto_gap]
				FROM
					#metrics  
				GROUP BY 
					[execution_id]
			) 

			SELECT 
				x.[test_date],
				x.[execution_id],

-- TODO: this top(1) is a hack. Need to figure out a cleaner way to run AGGREGATES in #aggregates when > 1 db is being restored ... 
				(SELECT TOP (1) a.[databases] FROM #aggregates a WHERE a.[execution_id] = x.[execution_id]) [databases],
				x.[tested_db_count],
				x.[restore_succeeded_count],
				x.[check_succeeded_count],
				x.[error_count],
				CASE 
					WHEN x.[error_count] = 0 THEN CAST('<errors />' AS xml)
-- TODO: also a hack... 
					ELSE (SELECT TOP(1) a.[errors] FROM [#aggregates] a WHERE a.[execution_id] = x.execution_id)   
					--ELSE (SELECT y.value('(/errors/error/@source_db)[1]','sysname') [@source_db], y.value('.', 'nvarchar(max)') [*] FROM ((SELECT TOP(1) a.[errors] FROM [#aggregates] a WHERE a.[execution_id] = x.[execution_id])).nodes() AS x(y) WHERE y.value('.','nvarchar(max)') <> N'' FOR XML PATH('error'), ROOT('errors'))
				END [errors],
				
				dbo.format_timespan(m.[max_rto_gap]) [max_rto_gap],
				dbo.format_timespan(m.[avg_rto_gap]) [avg_rto_gap],
				dbo.format_timespan(m.[min_rto_gap]) [min_rto_gap],
				'blah as xml' recovery_time_details,  --'xclklsdlfs' [---rpo_metrics--]  -- i need... avg rpo, min_rpo, max_rpo... IF there's > 1 db being restored... otherwise, just the rpo, etc. 

				dbo.format_timespan(m.[max_rpo_gap]) [max_rpo_gap],
				dbo.format_timespan(m.[avg_rpo_gap]) [avg_rpo_gap],
				dbo.format_timespan(m.[min_rpo_gap]) [min_rpo_gap],
				'blah as xml' recovery_point_details  -- <detail database="restored_db_name_here" restored_file_count="N" rpo_milliseconds="nnnn" /> ... or something similar... 
			FROM 
				core x
				INNER JOIN metrics m ON x.[execution_id] = m.[execution_id]
			ORDER BY 
				x.[test_date], x.[rank_id];

		END;
		

	END; 

	-----------------------------------------------------------------------------
	-- RPO: 
	IF UPPER(@Mode) = N'RPO' BEGIN

		PRINT 'RPO';

	END; 

	-----------------------------------------------------------------------------
	-- RTO: 
	IF UPPER(@Mode) = N'RTO' BEGIN

		PRINT 'RTO';
		
	END; 

	-----------------------------------------------------------------------------
	-- ERROR: 
	IF UPPER(@Mode) = N'ERROR' BEGIN

		PRINT 'ERROR';

	END; 

	-----------------------------------------------------------------------------
	-- DEVIATION: 
	IF UPPER(@Mode) = N'DEVIATION' BEGIN

		PRINT 'DEVIATION';

	END; 

	RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
--- Performance
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_processes','P') IS NOT NULL
	DROP PROC dbo.list_processes;
GO

CREATE PROC dbo.list_processes 
	@TopNRows								int			= -1,		-- TOP is only used if @TopNRows > 0. 
	@OrderBy								sysname		= N'CPU',	-- CPU | DURATION | READS | WRITES | MEMORY
	@ExcludeMirroringProcesses				bit			= 1,		-- optional 'ignore' wait types/families.
	@ExcludeNegativeDurations				bit			= 1,		-- exclude service broker and some other system-level operations/etc. 
	@ExcludeBrokerProcesses					bit			= 1,		-- need to document that it does NOT block ALL broker waits (and, that it ONLY blocks broker WAITs - i.e., that's currently the ONLY way it excludes broker processes - by waits).
	@ExcludeFTSDaemonProcesses				bit			= 1,
    --@ExcludeCDCProcesses                    bit         = 1,      -- vNEXT: looks like, sadly, either have to watch for any/some/all? of the following: program_name = SQLAgent Job ID that ... is a CDC task (sigh)... statement_text = 'waitfor delay @waittime' (see this all the time), and/or NAME of the object_id/sproc being executed is ... sys.sp_cdc_scan...  and that's JUST to ignore the LOG READER when it's idle... might have to look at other waits when active/etc. 
	@ExcludeSystemProcesses					bit			= 1,			-- spids < 50... 
	@ExcludeSelf							bit			= 1,	
	@IncludePlanHandle						bit			= 0,	
	@IncludeIsolationLevel					bit			= 0,
	@IncludeBlockingSessions				bit			= 1,		-- 'forces' inclusion of spids CAUSING blocking even if they would not 'naturally' be pulled back by TOP N, etc. 
	@IncudeDetailedMemoryStats				bit			= 0,		-- show grant info... 
	@IncludeExtendedDetails					bit			= 1,
    @IncludeTempdbUsageDetails              bit         = 1,
	@ExtractCost							bit			= 1	
AS 
	SET NOCOUNT ON; 

	IF UPPER(@OrderBy) NOT IN (N'CPU', N'DURATION', N'READS', N'WRITES', 'MEMORY') BEGIN 
		RAISERROR('@OrderBy may only be set to the following values { CPU | DURATION | READS | WRITES | MEMORY } (and is implied as being in DESC order.', 16, 1);
		RETURN -1;
	END;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	CREATE TABLE #core (
		[row_source] sysname NOT NULL,
		[session_id] smallint NOT NULL,
		[blocked_by] smallint NULL,
		[isolation_level] smallint NULL,
		[status] nvarchar(30) NOT NULL,
		[wait_type] nvarchar(60) NULL,
        [wait_resource] nvarchar(256) NOT NULL,
		[command] nvarchar(32) NULL,
		[granted_memory] bigint NULL,
		[requested_memory] bigint NULL,
        [query_cost] float NULL,
		[ideal_memory] bigint NULL,
		[cpu] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[duration] int NOT NULL,
		[wait_time] int NULL,
		[database_id] smallint NULL,
		[login_name] sysname NULL,
		[program_name] sysname NULL,
		[host_name] sysname NULL,
		[percent_complete] real NULL,
		[open_tran] int NULL,
        [tempdb_details] nvarchar(MAX) NULL,
		[sql_handle] varbinary(64) NULL,
		[plan_handle] varbinary(64) NULL, 
		[statement_start_offset] int NULL, 
		[statement_end_offset] int NULL,
		[statement_source] sysname NOT NULL DEFAULT N'REQUEST', 
		[row_number] int IDENTITY(1,1) NOT NULL,
		[text] nvarchar(max) NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	WITH [core] AS (
		SELECT {TOP}
			N''ACTIVE_PROCESS'' [row_source],
			r.[session_id], 
			r.[blocking_session_id] [blocked_by],
			s.[transaction_isolation_level] [isolation_level],
			r.[status],
			r.[wait_type],
            r.[wait_resource],
			r.[command],
			g.[granted_memory_kb],
			g.[requested_memory_kb],
			g.[ideal_memory_kb],
            g.[query_cost],
			r.[cpu_time] [cpu], 
			r.[reads], 
			r.[writes], 
			r.[total_elapsed_time] [duration],
			r.[wait_time],
			r.[database_id],
			s.[login_name],
			s.[program_name],
			s.[host_name],
			r.[percent_complete],
			r.[open_transaction_count] [open_tran],
            {TempDBDetails},
			r.[sql_handle],
			r.[plan_handle],
			r.[statement_start_offset], 
			r.[statement_end_offset]
		FROM 
			sys.dm_exec_requests r
			INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
			LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id AND r.[plan_handle] = g.[plan_handle]
		WHERE
			-- TODO: if wait_types to exclude gets ''stupid large'', then instead of using an IN()... go ahead and create a CTE/derived-table/whatever and do a JOIN instead... 
			ISNULL(r.wait_type, '''') NOT IN(''BROKER_TO_FLUSH'',''HADR_FILESTREAM_IOMGR_IOCOMPLETION'', ''BROKER_EVENTHANDLER'', ''BROKER_TRANSMITTER'',''BROKER_TASK_STOP'', ''MISCELLANEOUS'' {ExcludeMirroringWaits} {ExcludeFTSWaits} {ExcludeBrokerWaits})
			{ExcludeSystemProcesses}
			{ExcludeSelf}
			{ExcludeNegative}
			{ExcludeFTS}
		{TopOrderBy}
	){blockersCTE} 
	
	SELECT 
		[row_source],
		[session_id],
		[blocked_by],
		[isolation_level],
		[status],
		[wait_type],
        [wait_resource],
		[command],
		[granted_memory_kb],
		[requested_memory_kb],
		[ideal_memory_kb],
        [query_cost],
		[cpu],
		[reads],
		[writes],
		[duration],
		[wait_time],
		[database_id],
		[login_name],
		[program_name],
		[host_name],
		[percent_complete],
		[open_tran],
        [tempdb_details],
		[sql_handle],
		[plan_handle],
		[statement_start_offset],
		[statement_end_offset]
	FROM 
		[core] 

	{blockersUNION} 

	{OrderBy};';

	DECLARE @blockersCTE nvarchar(MAX) = N', 
	[blockers] AS ( 
		SELECT 
			N''BLOCKING_SPID'' [row_source],
			[s].[session_id],
			ISNULL([r].[blocking_session_id], x.[blocked]) [blocked_by],
			[s].[transaction_isolation_level] [isolation_level],
			[s].[status],
			ISNULL([r].[wait_type], x.[lastwaittype]) [wait_type],
            ISNULL([r].[wait_resource], N'''') [wait_resource],
			ISNULL([r].[command], x.[cmd]) [command],
			ISNULL([g].[granted_memory_kb],	(x.[memusage] * 8096)) [granted_memory_kb],
			ISNULL([g].[requested_memory_kb], -1) [requested_memory_kb],
			ISNULL([g].[ideal_memory_kb], -1) [ideal_memory_kb],
            ISNULL([g].[query_cost], -1) [query_cost],
			ISNULL([r].[cpu_time], 0 - [s].[cpu_time]) [cpu],
			ISNULL([r].[reads], 0 - [s].[reads]) [reads],
			ISNULL([r].[writes], 0 - [s].[writes]) [writes],
			ISNULL([r].[total_elapsed_time], 0 - [s].[total_elapsed_time]) [duration],
			ISNULL([r].[wait_time],	x.[waittime]) [wait_time],
			[x].[dbid] [database_id],					-- sys.dm_exec_sessions has this - from 2012+ 
			[s].[login_name],
			[s].[program_name],
			[s].[host_name],
			0 [percent_complete],
			x.[open_tran] [open_tran],	  -- sys.dm_exec_sessions has this - from 2012+
            {TempDBDetails},
			ISNULL([r].[sql_handle], (SELECT c.most_recent_sql_handle FROM sys.[dm_exec_connections] c WHERE c.[most_recent_session_id] = s.[session_id])) [sql_handle],
			[r].[plan_handle],
			ISNULL([r].[statement_start_offset], x.[stmt_start]) [statement_start_offset],
			ISNULL([r].[statement_end_offset], x.[stmt_end]) [statement_end_offset]

		FROM 
			sys.dm_exec_sessions s 
			INNER JOIN sys.[sysprocesses] x ON s.[session_id] = x.[spid] -- ugh... i hate using this BUT there are details here that are just NOT anywhere else... 
			LEFT OUTER JOIN sys.dm_exec_requests r ON s.session_id = r.[session_id] 
			LEFT OUTER JOIN sys.[dm_exec_query_memory_grants] g ON s.[session_id] = g.[session_id] AND r.[plan_handle] = g.[plan_handle] 
		WHERE 
			s.[session_id] NOT IN (SELECT session_id FROM [core])
			AND s.[session_id] IN (SELECT blocked_by FROM [core])
	) ';

	DECLARE @blockersUNION nvarchar(MAX) = N'
	UNION 

	SELECT 
		[row_source],
		[session_id],
		[blocked_by],
		[isolation_level],
		[status],
		[wait_type],
        [wait_resource],
		[command],
		[granted_memory_kb],
		[requested_memory_kb],
		[ideal_memory_kb],
        [query_cost],
		[cpu],
		[reads],
		[writes],
		[duration],
		[wait_time],
		[database_id],
		[login_name],
		[program_name],
		[host_name],
		[percent_complete],
		[open_tran],
        [tempdb_details],
		[sql_handle],
		[plan_handle],
		[statement_start_offset],
		[statement_end_offset] 
	FROM 
		[blockers]	
	';

    DECLARE @mergedTempdbMetricsAsACorrelatedSubQuery nvarchar(MAX) = N'
	        N''<tempdb_usage>'' + 
		        ISNULL((
			            (SELECT 
				            COUNT(*) [@allocation_count],
				            CAST(ISNULL((SUM(u.user_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@tempdb_mb], 
				            CAST(ISNULL((SUM(u.internal_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@spill_mb]
			            FROM 
				            sys.dm_db_task_space_usage u 
			            WHERE 
				            u.session_id = s.session_id AND (u.user_objects_alloc_page_count > 0 OR u.internal_objects_alloc_page_count > 0)
			            GROUP BY 
				            u.session_id
			            FOR 
				            XML PATH(''request'')))
		            , N''<request />'')
		        + 
		        ISNULL((
		            (SELECT 
			            COUNT(*) [@allocation_count],
			            CAST(ISNULL((SUM(u.user_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@tempdb_mb], 
			            CAST(ISNULL((SUM(u.internal_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@spill_mb]
		            FROM 
			            sys.dm_db_session_space_usage u 
		            WHERE 
			            u.session_id = s.session_id AND (u.user_objects_alloc_page_count > 0 OR u.internal_objects_alloc_page_count > 0)
		            GROUP BY 
			            u.session_id
		            FOR 
			            XML PATH(''session'')))
		            , N''<session />'') + N''</tempdb_usage>'' [tempdb_details]';

	SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY [row_source], ' + QUOTENAME(LOWER(@OrderBy)) + N' DESC');

    -- must be processed before @IncludeBlockingSessions:
    IF @IncludeTempdbUsageDetails = 1 BEGIN 
        SET @topSQL = REPLACE(@topSQL, N'{TempDBDetails}', @mergedTempdbMetricsAsACorrelatedSubQuery);
        SET @blockersCTE = REPLACE(@blockersCTE, N'{TempDBDetails}', @mergedTempdbMetricsAsACorrelatedSubQuery);
      END; 
    ELSE BEGIN 
        SET @topSQL = REPLACE(@topSQL, N'{TempDBDetails}', N'NULL [tempdb_details]');
        SET @blockersCTE = REPLACE(@blockersCTE, N'{TempDBDetails}', N'NULL [tempdb_details]');
    END;

	IF @IncludeBlockingSessions = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{blockersCTE} ', @blockersCTE);
		SET @topSQL = REPLACE(@topSQL, N'{blockersUNION} ', @blockersUNION);
	  END;
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{blockersCTE} ', N'');
		SET @topSQL = REPLACE(@topSQL, N'{blockersUNION} ', N'');
	END;

	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{TopOrderBy}', N'ORDER BY ' + CASE LOWER(@OrderBy) WHEN 'cpu' THEN 'r.[cpu_time]' WHEN 'duration' THEN 'r.[total_elapsed_time]' WHEN 'memory' THEN 'g.[granted_memory_kb]' ELSE LOWER(@OrderBy) END + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{TopOrderBy}', N'');
	END; 

	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND (r.[session_id] > 50) AND (r.[database_id] <> 0) AND (r.[session_id] NOT IN (SELECT [session_id] FROM sys.[dm_exec_sessions] WHERE [is_user_process] = 0)) ');
	  END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'');
	END;

	IF @ExcludeMirroringProcesses = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N',''DBMIRRORING_CMD'',''DBMIRROR_EVENTS_QUEUE'', ''DBMIRROR_WORKER_QUEUE''');
	  END;
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND r.[session_id] <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

	IF @ExcludeNegativeDurations = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'AND r.[total_elapsed_time] > 0 ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'');
	END; 

	IF @ExcludeFTSDaemonProcesses = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWaits}', N', ''FT_COMPROWSET_RWLOCK'', ''FT_IFTS_RWLOCK'', ''FT_IFTS_SCHEDULER_IDLE_WAIT'', ''FT_IFTSHC_MUTEX'', ''FT_IFTSISM_MUTEX'', ''FT_MASTER_MERGE'', ''FULLTEXT GATHERER'' ');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'AND r.[command] NOT LIKE ''FT%'' ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWaits}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'');
	END; 

	IF @ExcludeBrokerProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeBrokerWaits}', N', ''BROKER_RECEIVE_WAITFOR'', ''BROKER_TASK_STOP'', ''BROKER_TO_FLUSH'', ''BROKER_TRANSMITTER'' ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeBrokerWaits}', N'');
	END;

--EXEC dbo.[print_long_string] @Input = @topSQL;
--RETURN 0;

	INSERT INTO [#core] (
		[row_source],
		[session_id],
		[blocked_by],
		[isolation_level],
		[status],
		[wait_type],
        [wait_resource],
		[command],
		[granted_memory],
		[requested_memory],
		[ideal_memory],
        [query_cost],
		[cpu],
		[reads],
		[writes],
		[duration],
		[wait_time],
		[database_id],
		[login_name],
		[program_name],
		[host_name],
		[percent_complete],
		[open_tran],
        [tempdb_details],
		[sql_handle],
		[plan_handle],
		[statement_start_offset],
		[statement_end_offset]
	)
	EXEC sys.[sp_executesql] @topSQL; 

	IF NOT EXISTS (SELECT NULL FROM [#core]) BEGIN 
		RETURN 0; -- short-circuit - there's nothing to see here... 
	END;

	-- populate sql_handles for sessions without current requests: 
	UPDATE x 
	SET 
		x.[sql_handle] = c.[most_recent_sql_handle],
		x.[statement_source] = N'CONNECTION'
	FROM 
		[#core] x 
		INNER JOIN sys.[dm_exec_connections] c ON x.[session_id] = c.[most_recent_session_id]
	WHERE 
		x.[sql_handle] IS NULL;

	-- load statements: 
	SELECT 
		x.[session_id], 
		t.[text] [batch_text], 
		SUBSTRING(t.[text], (x.[statement_start_offset]/2) + 1, ((CASE WHEN x.[statement_end_offset] = -1 THEN DATALENGTH(t.[text]) ELSE x.[statement_end_offset] END - x.[statement_start_offset])/2) + 1) [statement_text]
	INTO 
		#statements 
	FROM 
		[#core] x 
		OUTER APPLY sys.[dm_exec_sql_text](x.[sql_handle]) t;

	-- load plans: 
	SELECT 
		x.[session_id], 
		p.query_plan [batch_plan]
	INTO 
		#plans 
	FROM 
		[#core] x 
		OUTER APPLY sys.dm_exec_query_plan(x.plan_handle) p

    CREATE TABLE #statementPlans (
        session_id int NOT NULL, 
        [statement_plan] xml 
    );

	DECLARE @loadPlans nvarchar(MAX) = N'
	SELECT 
		x.session_id, 
		' + CASE WHEN (SELECT dbo.[get_engine_version]()) > 10.5 THEN N'TRY_CAST' ELSE N'CAST' END + N'(q.[query_plan] AS xml) [statement_plan]
	FROM 
		[#core] x 
		OUTER APPLY sys.dm_exec_text_query_plan(x.[plan_handle], x.statement_start_offset, x.statement_end_offset) q ';

    INSERT INTO [#statementPlans] (
        [session_id],
        [statement_plan]
    )
	EXEC [sys].[sp_executesql] @loadPlans;

	IF @ExtractCost = 1 BEGIN
        
        WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT
            p.[session_id],
--TODO: look at whether or not a more explicit path with provide any perf benefits (less tempdb usage, less CPU/less time, etc.)
            p.batch_plan.value('(/ShowPlanXML/BatchSequence/Batch/Statements/StmtSimple/@StatementSubTreeCost)[1]', 'float') [plan_cost]
		INTO 
			#costs
        FROM
            [#plans] p;
    END;

    DECLARE @tempdbExtractionCTE nvarchar(MAX) = N'
    WITH extracted AS (
        SELECT 
            session_id,
            details.value(''(tempdb_usage[1]/request[1]/@tempdb_mb)'', N''decimal(22,1)'') [request_tempdb_mb],
            details.value(''(tempdb_usage[1]/request[1]/@spill_mb)'', N''decimal(22,1)'') [request_spills_mb],
            details.value(''(tempdb_usage[1]/session[1]/@tempdb_mb)'', N''decimal(22,1)'') [session_tempdb_mb],
            details.value(''(tempdb_usage[1]/session[1]/@spill_mb)'', N''decimal(22,1)'') [session_spills_mb]
        FROM 
            (SELECT 
                [session_id],
                CAST([tempdb_details] AS xml) [details]
            FROM 
                [#core]) x
    )
    ' ;

    DECLARE @tempdbDetailsSummary nvarchar(MAX) = N'
        CAST(ISNULL(x.[session_spills_mb], 0.0) AS sysname) + N'' '' + CASE WHEN NULLIF(x.[request_spills_mb], 0.0) IS NULL THEN N'''' ELSE N'' ('' + CAST(x.[request_spills_mb] AS sysname) + N'')'' END[spills_mb - s (r)],
        CAST(ISNULL(x.[session_tempdb_mb], 0.0) AS sysname) + N'' '' + CASE WHEN NULLIF(x.[request_tempdb_mb], 0.0) IS NULL THEN N'''' ELSE N'' ('' + CAST(x.[request_tempdb_mb] AS sysname) + N'')'' END[tempdb_mb - s (r)],
    ';

	DECLARE @projectionSQL nvarchar(MAX) = N'{tempdbExtractionCTE}
    SELECT 
		c.[session_id],
		c.[blocked_by],  
		CASE WHEN c.[database_id] = 0 THEN ''resourcedb'' ELSE DB_NAME(c.database_id) END [db_name],
		{isolation_level}
		c.[command], 
        c.[status], 
		c.[wait_type],
        c.[wait_resource],
		t.[batch_text],  
		--t.[statement_text],
		{extractCost}        
		c.[cpu],
		c.[reads],
		c.[writes],
		{memory}
		dbo.format_timespan(c.[duration]) [elapsed_time], 
		dbo.format_timespan(c.[wait_time]) [wait_time],
        {tempdbDetails}
		ISNULL(c.[program_name], '''') [program_name],
		c.[login_name],
		c.[host_name],
		{plan_handle}
		{extended_details}
		sp.[statement_plan],
        p.[batch_plan]
	FROM 
		[#core] c
		INNER JOIN #statements t ON c.session_id = t.session_id
		INNER JOIN #plans p ON c.session_id = p.session_id
		INNER JOIN #statementPlans sp ON c.session_id = sp.session_id
		{extractJoin}
        {tempdbUsageJoin}
	ORDER BY
		[row_number];'

	IF @IncludeIsolationLevel = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'CASE c.isolation_level WHEN 0 THEN ''Unspecified'' WHEN 1 THEN ''ReadUncomitted'' WHEN 2 THEN ''Readcomitted'' WHEN 3 THEN ''Repeatable'' WHEN 4 THEN ''Serializable'' WHEN 5 THEN ''Snapshot'' END [isolation_level],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'');
	END;

	IF @IncudeDetailedMemoryStats = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'ISNULL(CAST((c.granted_memory / 1024.0) as decimal(20,2)),0) [granted_mb], ISNULL(CAST((c.requested_memory / 1024.0) as decimal(20,2)),0) [requested_mb], ISNULL(CAST((c.ideal_memory  / 1024.0) as decimal(20,2)),0) [ideal_mb],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'ISNULL(CAST((c.granted_memory / 1024.0) as decimal(20,2)),0) [granted_mb],');
	END; 

	IF @IncludePlanHandle = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'c.[statement_source], c.[plan_handle], ');
	  END; 
	ELSE BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'');
	END; 

	IF @IncludeExtendedDetails = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extended_details}', N'c.[percent_complete], c.[open_tran], (SELECT COUNT(x.session_id) FROM sys.dm_os_waiting_tasks x WHERE x.session_id = c.session_id) [thread_count], ')
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extended_details}', N'');
	END; 

	IF @ExtractCost = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractCost}', N'CASE WHEN [pc].[plan_cost] IS NULL AND [c].[query_cost] IS NOT NULL THEN CAST(CAST([c].[query_cost] AS decimal(20,2)) AS sysname) + N''g'' ELSE CAST(CAST([pc].[plan_cost] AS decimal(20,2)) AS sysname) END [cost], ');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractJoin}', N'LEFT OUTER JOIN #costs pc ON c.[session_id] = pc.[session_id]');
	  END
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractCost}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractJoin}', N'');
	END;

    IF @IncludeTempdbUsageDetails = 1 BEGIN 
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbDetails}', @tempdbDetailsSummary);
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbExtractionCTE}', @tempdbExtractionCTE);
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbUsageJoin}', N'LEFT OUTER JOIN extracted x ON c.[session_id] = x.[session_id] ');
      END;
    ELSE BEGIN 
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbDetails}', N'');
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbExtractionCTE}', N'');
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbUsageJoin}', N'');
    END;

--EXEC dbo.print_long_string @projectionSQL;
--RETURN 0;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_parallel_processes','P') IS NOT NULL
	DROP PROC dbo.[list_parallel_processes];
GO

CREATE PROC dbo.[list_parallel_processes]

AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	SELECT 
		[spid] [session_id],
		[ecid] [execution_id],
		[blocked],
		[dbid] [database_id],
		[cmd] [command],
		[lastwaittype] [wait_type],
		[waitresource] [wait_resource],
		[waittime] [wait_time],
		[status],
		[open_tran],
		[cpu],
		[physical_io],
		[memusage],
		[login_time],
		[last_batch],
		
		[hostname],
		[program_name],
		[loginame],
		[sql_handle],
		[stmt_start],
		[stmt_end]
	INTO
		#ecids
	FROM 
		sys.[sysprocesses] 
	WHERE 
		spid IN (SELECT session_id FROM sys.[dm_os_waiting_tasks] WHERE [session_id] IS NOT NULL GROUP BY [session_id] HAVING COUNT(*) > 1);

	IF NOT EXISTS(SELECT NULL FROM [#ecids]) BEGIN 
		-- short circuit.
		RETURN 0;
	END;


	--TODO: if 2016+ get dop from sys.dm_exec_requests... (or is waiting_tasks?)
	--TODO: execute a cleanup/sanitization of this info + extract code and so on... 
	SELECT 
		[session_id],
		[execution_id],
		[blocked],
		DB_NAME([database_id]) [database_name],
		[command],
		[wait_type],
		[wait_resource],
		[wait_time],
		[status],
		[open_tran],
		[cpu],
		[physical_io],
		[memusage],
		[login_time],
		[last_batch],
		[hostname],
		[program_name],
		[loginame]--,
		--[sql_handle],
		--[stmt_start],
		--[stmt_end]
	FROM 
		[#ecids] 
	ORDER BY 
		-- TODO: whoever is using the most CPU (by session_id) then by ecid... 
		[session_id], 
		[execution_id];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_transactions','P') IS NOT NULL
	DROP PROC dbo.list_transactions;
GO

CREATE PROC dbo.list_transactions 
	@TopNRows						int			= -1, 
	@OrderBy						sysname		= N'DURATION',  -- DURATION | LOG_COUNT | LOG_SIZE   
	@ExcludeSystemProcesses			bit			= 0,            -- USUALLY, if we're looking at Transactions, we want to see EVERYTHING that's holding a resource - system or otherwise. 
    @ExcludeSchemaLocksOnly         bit         = 1,            -- in the vast majority of cases... don't want to see who has a connection into the db (ONLY)... sp_who/sp_who2 would do a fine job of that... 
	@ExcludeSelf					bit			= 1, 
	@IncludeContext					bit			= 1,	
	@IncludeStatements				bit			= 1, 
	@IncludePlans					bit			= 0, 
	@IncludeBoundSessions			bit			= 0, -- seriously, i bet .00x% of transactions would ever even use this - IF that ... 
	@IncludeDTCDetails				bit			= 0, 
	@IncludeLockedResources			bit			= 1, 
	@IncludeVersionStoreDetails		bit			= 0
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	CREATE TABLE #core (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[session_id] int NOT NULL,
		[transaction_id] bigint NULL,
		[database_id] int NULL,
		[duration] int NULL,
		[enlisted_db_count] int NULL, 
		[tempdb_enlisted] bit NULL,
		[transaction_type] sysname NULL,
		[transaction_state] sysname NULL,
		[enlist_count] int NOT NULL,
		[is_user_transaction] bit NOT NULL,
		[is_local] bit NOT NULL,
		[is_enlisted] bit NOT NULL,
		[is_bound] bit NOT NULL,
		[open_transaction_count] int NOT NULL,
		[log_record_count] bigint NULL,
		[log_bytes_used] bigint NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	SELECT {TOP}
		[dtst].[session_id],
		[dtat].[transaction_id],
		[dtdt].[database_id],
		DATEDIFF(MILLISECOND, [dtdt].[begin_time], GETDATE()) [duration],
		[dtdt].[enlisted_db_count], 
		[dtdt].[tempdb_enlisted],
		CASE [dtat].[transaction_type]
			WHEN 1 THEN ''Read/Write''
			WHEN 2 THEN ''Read-Only''
			WHEN 3 THEN ''System''
			WHEN 4 THEN ''Distributed''
			ELSE ''#Unknown#''
		END [transaction_type],
		CASE [dtat].[transaction_state]
			WHEN 0 THEN ''Initializing''
			WHEN 1 THEN ''Initialized''
			WHEN 2 THEN ''Active''
			WHEN 3 THEN ''Ended (read-only)''
			WHEN 4 THEN ''DTC commit started''
			WHEN 5 THEN ''Awaiting resolution''
			WHEN 6 THEN ''Committed''
			WHEN 7 THEN ''Rolling back...''
			WHEN 8 THEN ''Rolled back''
		END [transaction_state],
		[dtst].[enlist_count], -- # of active requests enlisted... 
		[dtst].[is_user_transaction],
		[dtst].[is_local],
		[dtst].[is_enlisted],
		[dtst].[is_bound],		-- active or not... 
		[dtst].[open_transaction_count], 
		[dtdt].[log_record_count],
		[dtdt].[log_bytes_used]
	FROM 
		sys.[dm_tran_active_transactions] dtat WITH(NOLOCK)
		INNER JOIN sys.[dm_tran_session_transactions] dtst WITH(NOLOCK) ON [dtat].[transaction_id] = [dtst].[transaction_id]
		LEFT OUTER JOIN ( 
			SELECT 
				x.transaction_id,
				MAX(x.database_id) [database_id], -- max isn''t always logical/best. But with tempdb_enlisted + enlisted_db_count... it''s as good as it gets... 
				MIN(x.[database_transaction_begin_time]) [begin_time],
				SUM(CASE WHEN x.database_id = 2 THEN 1 ELSE 0 END) [tempdb_enlisted],
				COUNT(x.database_id) [enlisted_db_count],
				MAX(x.[database_transaction_log_record_count]) [log_record_count],
				MAX(x.[database_transaction_log_bytes_used]) [log_bytes_used]
			FROM 
				sys.[dm_tran_database_transactions] x WITH(NOLOCK)
			GROUP BY 
				x.transaction_id
		) dtdt ON [dtat].[transaction_id] = [dtdt].[transaction_id]
        {ExcludeSchemaLocksOnly}
	WHERE 
		1 = 1 
		{ExcludeSystemProcesses}
		{ExcludeSelf}
	{OrderBy};';

	-- This is a bit ugly... but works... 
	DECLARE @orderByOrdinal nchar(2) = N'3'; -- duration. 
	IF UPPER(@OrderBy) = N'LOG_COUNT' SET @orderByOrdinal = N'12'; 
	IF UPPER(@OrderBy) = N'LOG_SIZE' SET @orderByOrdinal = N'13';

	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + @orderByOrdinal + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + @orderByOrdinal + N' DESC');
	END; 

	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND dtst.[session_id] > 50 AND [dtst].[is_user_transaction] = 1 AND (dtst.[session_id] NOT IN (SELECT session_id FROM sys.[dm_exec_sessions] WHERE [is_user_process] = 0))  ');
		END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND dtst.[session_id] <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

    IF @ExcludeSchemaLocksOnly = 1 BEGIN 
        SET @topSQL = REPLACE(@topSQL, N'{ExcludeSchemaLocksOnly}', N'INNER JOIN (SELECT request_session_id [session_id] FROM sys.dm_tran_locks GROUP BY request_session_id HAVING COUNT(*) > 1) [schema_only] ON [dtst].session_id = [schema_only].[session_id]');
      END;
    ELSE BEGIN
        SET @topSQL = REPLACE(@topSQL, N'{ExcludeSchemaLocksOnly}', N'');
    END;


	INSERT INTO [#core] ([session_id], [transaction_id], [database_id], [duration], [enlisted_db_count], [tempdb_enlisted], [transaction_type], [transaction_state], [enlist_count], 
		[is_user_transaction], [is_local], [is_enlisted], [is_bound], [open_transaction_count], [log_record_count], [log_bytes_used])
	EXEC sys.[sp_executesql] @topSQL;

	CREATE TABLE #handles (
		session_id int NOT NULL, 
		statement_source sysname NOT NULL DEFAULT N'REQUEST',
		statement_handle varbinary(64) NULL, 
		plan_handle varbinary(64) NULL, 
		[status] nvarchar(30) NULL, 
		isolation_level varchar(14) NULL, 
		blocking_session_id int NULL, 
		wait_time int NULL, 
		wait_resource nvarchar(256) NULL, 
		[wait_type] nvarchar(60) NULL,
		last_wait_type nvarchar(60) NULL, 
		cpu_time int NULL, 
		[statement_start_offset] int NULL, 
		[statement_end_offset] int NULL
	);

	CREATE TABLE #statements (
		session_id int NOT NULL,
		statement_source sysname NOT NULL DEFAULT N'REQUEST',
		[statement] nvarchar(MAX) NULL
	);

	CREATE TABLE #plans (
		session_id int NOT NULL,
		query_plan xml NULL
	);

	INSERT INTO [#handles] ([session_id], [statement_handle], [plan_handle], [status], [isolation_level], [blocking_session_id], [wait_time], [wait_resource], [wait_type], [last_wait_type], [cpu_time], [statement_start_offset], [statement_end_offset])
	SELECT 
		c.[session_id], 
		r.[sql_handle] [statement_handle], 
		r.[plan_handle], 
		ISNULL(r.[status], N'sleeping'), 
		CASE r.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
			ELSE NULL
		END isolation_level,
		r.[blocking_session_id], 
		r.[wait_time], 
		r.[wait_resource], 
		r.[wait_type],
		r.[last_wait_type], 
		r.[cpu_time], 
		r.[statement_start_offset], 
		r.[statement_end_offset]
	FROM 
		[#core] c 
		LEFT OUTER JOIN sys.[dm_exec_requests] r WITH(NOLOCK) ON c.[session_id] = r.[session_id];

	UPDATE h
	SET 
		h.[statement_handle] = CAST(p.[sql_handle] AS varbinary(64)), 
		h.[statement_source] = N'SESSION'
	FROM 
		[#handles] h
		LEFT OUTER JOIN sys.[sysprocesses] p ON h.[session_id] = p.[spid] -- AND h.[request_handle] IS NULL don't really think i need this pushed-down predicate... but might be worth a stab... 
	WHERE 
		h.[statement_handle] IS NULL;

	IF @IncludeStatements = 1 OR @IncludeContext = 1 BEGIN
		
		INSERT INTO [#statements] ([session_id], [statement_source], [statement])
		SELECT 
			h.[session_id], 
			h.[statement_source], 
			t.[text] [statement]
		FROM 
			[#handles] h
			OUTER APPLY sys.[dm_exec_sql_text](h.[statement_handle]) t;
	END; 

	IF @IncludePlans = 1 BEGIN

		INSERT INTO [#plans] ([session_id], [query_plan])
		SELECT 
			h.session_id, 
			p.[query_plan]
		FROM 
			[#handles] h 
			OUTER APPLY sys.[dm_exec_query_plan](h.[plan_handle]) p
	END

    IF @IncludeLockedResources = 1 BEGIN 
        SELECT 
            dtl.[request_session_id] [session_id], 
            dtl.[resource_type],
            dtl.[resource_subtype], 
            dtl.[request_mode], 
            dtl.[request_status], 
            dtl.[request_reference_count], 
            dtl.[request_owner_type], 
            dtl.[request_owner_id], 
            dtl.[resource_associated_entity_id],
            dtl.[resource_database_id], 
            dtl.[resource_lock_partition],
            x.[waiting_task_address], 
            x.[wait_duration_ms], 
            x.[wait_type], 
            x.[blocking_session_id], 
            x.[blocking_task_address], 
            x.[resource_description]
        INTO 
            #lockedResources
        FROM 
            [#core] c
            INNER JOIN sys.[dm_tran_locks] dtl ON c.[session_id] = dtl.[request_session_id]
            LEFT OUTER JOIN sys.[dm_os_waiting_tasks] x WITH(NOLOCK) ON x.[session_id] = c.[session_id]
    END;

	-- correlated sub-query:
	DECLARE @lockedResourcesSQL nvarchar(MAX) = N'
		CAST((SELECT 
			--x.[resource_type] [@resource_type],
			--x.[request_session_id] [@owning_session_id],
			--DB_NAME(x.[resource_database_id]) [@database],
			CASE WHEN x.[resource_subtype] IS NOT NULL THEN x.[resource_subtype] ELSE NULL END [@resource_subtype],
            
            CASE WHEN x.resource_type = N''PAGE'' THEN x.[resource_associated_entity_id] ELSE NULL END [identifier/@associated_hobt_id],
            RTRIM(x.[resource_type] + N'': '' + CAST(x.[resource_database_id] AS sysname) + N'':'' + CASE WHEN x.[resource_type] = N''PAGE'' THEN CAST(x.[resource_description] AS sysname) ELSE CAST(x.[resource_associated_entity_id] AS sysname) END
				+ CASE WHEN x.[resource_type] = N''KEY'' THEN N'' '' + CAST(x.[resource_description] AS sysname) ELSE '''' END
				+ CASE WHEN x.[resource_type] = N''OBJECT'' AND x.[resource_lock_partition] <> 0 THEN N'':'' + CAST(x.[resource_lock_partition] AS sysname) ELSE '''' 
				END) [identifier], 
			
			--x.[request_type] [transaction/@request_type],	-- will ALWAYS be ''LOCK''... 
			x.[request_mode] [transaction/@request_mode], 
			x.[request_status] [transaction/@request_status],
			x.[request_reference_count] [transaction/@reference_count],  -- APPROXIMATE (ont definitive).
			x.[request_owner_type] [transaction/@owner_type],
			x.[request_owner_id] [transaction/@transaction_id],		-- transactionID of the owner... can be ''overloaded'' with negative values (-4 = filetable has a db lock, -3 = filetable has a table lock, other options outlined in BOL).
			x.[waiting_task_address] [waits/waiting_task_address],
			x.[wait_duration_ms] [waits/wait_duration_ms], 
			x.[wait_type] [waits/wait_type],
			x.[blocking_session_id] [waits/blocking/blocking_session_id], 
			x.[blocking_task_address] [waits/blocking/blocking_task_address], 
			x.[resource_description] [waits/blocking/resource_description]
		FROM 
            #lockedResources x
		WHERE 
			x.[session_id] = c.session_id
		FOR XML PATH (''resource''), ROOT(''locked_resources'')) AS xml) [locked_resources],	';
	
	DECLARE @contextSQL nvarchar(MAX) = N'
CAST((
	SELECT 
		-- transaction
			c2.transaction_id [transaction/@transaction_id], 
			c2.transaction_state [transaction/current_state],
			c2.transaction_type [transaction/transaction_type], 
			h2.isolation_level [transaction/isolation_level], 
			c2.enlist_count [transaction/active_request_count], 
			c2.open_transaction_count [transaction/open_transaction_count], 
		
			-- statement
				h2.statement_source [transaction/statement/statement_source], 
				ISNULL(h2.[statement_start_offset], 0) [transaction/statement/sql_handle/@offset_start], 
				ISNULL(h2.[statement_end_offset], 0) [transaction/statement/sql_handle/@offset_end],
				ISNULL(CONVERT(nvarchar(128), h2.[statement_handle], 1), '''') [transaction/statement/sql_handle], 
				h2.plan_handle [transaction/statement/plan_handle],
				ISNULL(s2.statement, N'''') [transaction/statement/sql_text],
			--/statement

			-- waits
				dbo.format_timespan(h2.wait_time) [transaction/waits/@wait_time], 
				h2.wait_resource [transaction/waits/wait_resource], 
				h2.wait_type [transaction/waits/wait_type], 
				h2.last_wait_type [transaction/waits/last_wait_type],
			--/waits

			-- databases 
				c2.enlisted_db_count [transaction/databases/enlisted_db_count], 
				c2.tempdb_enlisted [transaction/databases/is_tempdb_enlisted], 
				DB_NAME(c2.database_id) [transaction/databases/primary_db], 
			--/databases
		--/transaction 

		-- time 
			dbo.format_timespan(h2.cpu_time) [time/cpu_time], 
			dbo.format_timespan(h2.wait_time) [time/wait_time], 
			dbo.format_timespan(c2.duration) [time/duration], 
			dbo.format_timespan(DATEDIFF(MILLISECOND, des2.last_request_start_time, GETDATE())) [time/time_since_last_request_start], 
			ISNULL(CONVERT(sysname, des2.[last_request_start_time], 121), '''') [time/last_request_start]
		--/time
	FROM 
		[#core] c2 
		LEFT OUTER JOIN #handles h2 ON c2.session_id = h2.session_id
		LEFT OUTER JOIN sys.dm_exec_sessions des2 ON c2.session_id = des.session_id
		LEFT OUTER JOIN #statements s2 ON c2.session_id = s2.session_id
	WHERE 
		c2.session_id = c.session_id
		AND h2.session_id = c.session_id 
		AND des2.session_id = c.session_id
		AND s2.session_id = c.session_id
	FOR XML PATH(''''), ROOT(''context'')
	) as xml) [context],	';

	DECLARE @versionStoreSQL nvarchar(MAX) = N'
CAST((
	SELECT 
		[dtvs].[version_sequence_num] [@version_id],
		[dtst].[session_id] [@owner_session_id], 
		[dtvs].[database_id] [versioned_rowset/@database_id],
		[dtvs].[rowset_id] [versioned_rowset/@hobt_id],
		SUM([dtvs].[record_length_first_part_in_bytes]) + SUM([dtvs].[record_length_second_part_in_bytes]) [versioned_rowset/@total_bytes], 
		MAX([dtasdt].[elapsed_time_seconds]) [version_details/@total_seconds_old],
		CASE WHEN MAX(ISNULL([dtasdt].[commit_sequence_num],0)) = 0 THEN 1 ELSE 0 END [version_details/@is_active_transaction],
		MAX(CAST([dtasdt].[is_snapshot] AS tinyint)) [version_details/@is_snapshot],
		MAX([dtasdt].[max_version_chain_traversed]) [version_details/@max_chain_traversed], 
		MAX([dtvs].[status]) [version_details/@using_multipage_storage]
	FROM 
		sys.[dm_tran_session_transactions] dtst
		LEFT OUTER JOIN sys.[dm_tran_locks] dtl ON [dtst].[transaction_id] = dtl.[request_owner_id]
		LEFT OUTER JOIN sys.[dm_tran_version_store] dtvs ON dtl.[resource_database_id] = dtvs.[database_id] AND dtl.[resource_associated_entity_id] = [dtvs].[rowset_id]
		LEFT OUTER JOIN sys.[dm_tran_active_snapshot_database_transactions] dtasdt ON dtst.[session_id] = c.[session_id]
	WHERE 
		dtst.[session_id] = c.[session_id]
		AND [dtvs].[rowset_id] IS NOT NULL
	GROUP BY 
		[dtst].[session_id], [dtvs].[database_id], [dtvs].[rowset_id], [dtvs].[version_sequence_num]
	ORDER BY 
		[dtvs].[version_sequence_num]
	FOR XML PATH(''version''), ROOT(''versions'')
	) as xml) [version_store_data], '

	DECLARE @projectionSQL nvarchar(MAX) = N'
	SELECT 
        [c].[session_id],
		ISNULL([h].blocking_session_id, 0) [blocked_by],
        {lockedResourceCount}
        DB_NAME([c].[database_id]) [database],
        dbo.format_timespan([c].[duration]) [duration],
		h.[status],
		{statement}
		des.[login_name],
		des.[program_name], 
		des.[host_name],
		ISNULL(c.log_record_count, 0) [log_record_count], 
		ISNULL(c.log_bytes_used, 0) [log_bytes_used],
		--N'''' + ISNULL(CAST(c.log_record_count as sysname), ''0'') + N'' - '' + ISNULL(CAST(c.log_bytes_used as sysname),''0'') + N''''		[log_used (count - bytes)],
		{context}
		{locked_resources}
		{version_store}
		{plan}
		{bound}
		CASE WHEN [c].[is_user_transaction] = 1 THEN ''EXPLICIT'' ELSE ''IMPLICIT'' END [transaction_type]
	FROM 
		[#core] c 
		LEFT OUTER JOIN #handles h ON c.session_id = h.session_id
		LEFT OUTER JOIN sys.dm_exec_sessions des ON c.session_id = des.session_id
		{statementJOIN}
		{planJOIN}
	ORDER BY 
		[c].[row_number];';

	IF @IncludeContext = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{context}', @contextSQL);
	  END; 
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{context}', N'');
	END;

	IF @IncludeStatements = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'[s].[statement],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'LEFT OUTER JOIN #statements s ON c.session_id = s.session_id');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'');
	END; 

	IF @IncludePlans = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan}', N'[p].[query_plan],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{planJOIN}', N'LEFT OUTER JOIN #plans p ON c.session_id = p.session_id');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{planJOIN}', N'');
	END;

	IF @IncludeLockedResources = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{locked_resources}', @lockedResourcesSQL);
        SET @projectionSQL = REPLACE(@projectionSQL, N'{lockedResourceCount}', N'ISNULL((SELECT COUNT(*) FROM #lockedResources x WHERE x.session_id = c.session_id), 0) [lock_count], ');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{locked_resources}', N'');
        SET @projectionSQL = REPLACE(@projectionSQL, N'{lockedResourceCount}', N'');
	END;

	IF @IncludeVersionStoreDetails = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{version_store}', @versionStoreSQL);
	  END; 
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{version_store}', N'');
	END;

	IF @IncludeBoundSessions = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{bound}', N', [c].[is_bound]');
	  END; 
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{bound}', N'');
	END;

	IF @IncludeDTCDetails = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{dtc}', N'<dtc_detail is_local="'' + ISNULL(CAST(c.is_local as char(1)), ''0'') + N''" is_enlisted="'' + ISNULL(CAST(c.is_enlisted as char(1)), ''0'') + N''" />');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{dtc}', N'');
	END;

--EXEC dbo.[print_string] @Input = @projectionSQL;
--RETURN;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_collisions', 'P') IS NOT NULL
	DROP PROC dbo.list_collisions;
GO

CREATE PROC dbo.list_collisions 
	@TargetDatabases								nvarchar(max)	= N'{ALL}',  -- allowed values: {ALL} | {SYSTEM} | {USER} | 'name, other name, etc'; -- this is an EXCLUSIVE list... as in, anything not explicitly mentioned is REMOVED. 
	@IncludePlans									bit				= 1, 
	@IncludeContext									bit				= 1,
	@UseInputBuffer									bit				= 0,     -- for any statements (query_handles) that couldn't be pulled from sys.dm_exec_requests and then (as a fallback) from sys.sysprocesses, this specifies if we should use DBCC INPUTBUFFER(spid) or not... 
	@ExcludeFullTextCollisions						bit				= 1   
	--@MinimumWaitThresholdInMilliseconds				int			= 200	
	--@ExcludeSystemProcesses							bit			= 1		-- TODO: this needs to be restricted to ... blocked only? or... how's that work... (what if i don't care that a system process is blocked... but that system process is blocking a user process? then what?
AS 
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF NULLIF(@TargetDatabases, N'') IS NULL
		SET @TargetDatabases = N'{ALL}';

	WITH blocked AS (
		SELECT 
			session_id, 
			blocking_session_id
		FROM 
			sys.[dm_os_waiting_tasks]
		WHERE 
			session_id <> blocking_session_id
			AND blocking_session_id IS NOT NULL
	), 
	collisions AS ( 
		SELECT 
			session_id 
		FROM 
			blocked 
		UNION 
		SELECT 
			blocking_session_id
		FROM 
			blocked
		WHERE 
			blocked.blocking_session_id NOT IN (SELECT session_id FROM blocked)  
	)

	SELECT 
		s.session_id, 
		ISNULL(r.database_id, (SELECT TOP (1) [dbid] FROM sys.sysprocesses WHERE spid = s.[session_id])) [database_id],	
		r.wait_time, 
		s.session_id [blocked_session_id],
		r.blocking_session_id,
		r.command,
		ISNULL(r.[status], 'connected') [status],
		ISNULL(CAST(r.[total_elapsed_time] AS bigint), CASE WHEN NULLIF(s.last_request_start_time, '1900-01-01 00:00:00.000') IS NULL THEN NULL ELSE DATEDIFF_BIG(MILLISECOND, s.last_request_start_time, GETDATE()) END) [duration],
		ISNULL(r.wait_resource, '') wait_resource,
		r.[last_wait_type] [wait_type],
		CASE [dtat].[transaction_type]
			WHEN 1 THEN 'Read/Write'
			WHEN 2 THEN 'Read-Only'
			WHEN 3 THEN 'System'
			WHEN 4 THEN 'Distributed'
			ELSE '#Unknown#'
		END [transaction_scope],		
		CASE [dtat].[transaction_state]
			WHEN 0 THEN 'Initializing'
			WHEN 1 THEN 'Initialized'
			WHEN 2 THEN 'Active'
			WHEN 3 THEN 'Ended (read-only)'
			WHEN 4 THEN 'DTC commit started'
			WHEN 5 THEN 'Awaiting resolution'
			WHEN 6 THEN 'Committed'
			WHEN 7 THEN 'Rolling back...'
			WHEN 8 THEN 'Rolled back'
			ELSE NULL
		END [transaction_state],
		CASE r.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
			ELSE NULL
		END [isolation_level],
		CASE WHEN dtst.is_user_transaction = 1 THEN 'EXPLICIT' ELSE 'IMPLICIT' END [transaction_type], 
--MKC: This needs a bit more work... 
		--(SELECT MAX(open_tran) FROM sys.sysprocesses p WHERE s.session_id = p.spid) [open_transaction_count], 
		CAST(N'REQUEST' AS sysname) [statement_source],
		r.[sql_handle] [statement_handle], 
		r.plan_handle, 
		r.statement_start_offset, 
		r.statement_end_offset
	INTO 
		#core
	FROM 
		sys.[dm_exec_sessions] s 
		INNER JOIN [collisions] c ON s.[session_id] = c.[session_id]
		LEFT OUTER JOIN sys.[dm_exec_requests] r ON s.[session_id] = r.[session_id]
		LEFT OUTER JOIN sys.dm_tran_session_transactions dtst ON r.session_id = dtst.session_id
		LEFT OUTER JOIN sys.dm_tran_active_transactions dtat ON dtst.transaction_id = dtat.transaction_id;

	IF @ExcludeFullTextCollisions = 1 BEGIN 
		DELETE FROM [#core]
		WHERE [command] LIKE 'FT%';
	END;

	IF @TargetDatabases <> N'{ALL}' BEGIN
		
		DECLARE @dbNames table ( 
			[database_name] sysname NOT NULL 
		); 
		
		INSERT INTO @dbNames ([database_name])
		EXEC dbo.list_databases 
			@Targets = @TargetDatabases, 
			@ExcludeSecondaries = 1, 
			@ExcludeReadOnly = 1;

		DELETE FROM #core 
		WHERE 
			database_id NOT IN (SELECT database_id FROM sys.databases WHERE [name] IN (SELECT [database_name] FROM @dbNames));
	END; 

	-- HACK: roll this logic up into the parent query (if the perf is better) ... sometime when it's not 2AM and I'm not working in a hotel...	
	DELETE FROM #core 
	WHERE 
		session_id IS NULL
		OR (blocking_session_id IS NULL AND session_id NOT IN (
			SELECT blocking_session_id FROM #core WHERE blocking_session_id IS NOT NULL AND blocking_session_id <> 0
			)
		);

	--NOTE: this is part of both the PROBLEM... and the hack above:
	UPDATE #core SET blocking_session_id = 0 WHERE blocking_session_id IS NULL;	

	--NOTE: this is no longer a hack, there's just something stupid going on with my core/main CTEs and 'collisions' detection logic... it's returning 'false' positives
	--			likely due to the fact that I'm being a moron with regards to NULLs and ISNULL(x, 0) and so on... 
	--		at any rate the hack continues: 
	--			(or, in other words, pretend this is TDD.. the code in this sproc is red/green .. done but needs a MAJOR refactor (to make it less ugly/tedious/perf-heavy).
	DELETE FROM #core WHERE blocking_session_id = 0 AND blocked_session_id NOT IN (SELECT blocking_session_id FROM #core);

	IF NOT EXISTS(SELECT NULL FROM [#core]) BEGIN
		RETURN 0; -- short-circuit.
	END;

	-- populate sql_handles for sessions without current requests: 
	UPDATE c 
	SET 
		c.statement_handle = x.[most_recent_sql_handle],
		c.statement_source = N'CONNECTION'
	FROM 
		#core c 
		LEFT OUTER JOIN sys.[dm_exec_connections] x ON c.session_id = x.[most_recent_session_id]
	WHERE 
		c.statement_handle IS NULL;

	--------------------------------------------------------
	-- Extract Statements: 
	SELECT 
		c.[session_id], 
		c.[statement_source], 
		t.[text] [statement]
	INTO 
		#statements 
	FROM 
		#core c 
		OUTER APPLY sys.[dm_exec_sql_text](c.[statement_handle]) t;
	
	IF @UseInputBuffer = 1 BEGIN
		
		DECLARE @sql nvarchar(MAX); 

		DECLARE filler CURSOR LOCAL FAST_FORWARD READ_ONLY FOR 
		SELECT 
			session_id 
		FROM 
			[#statements] 
		WHERE 
			[statement] IS NULL; 

		DECLARE @spid int; 
		DECLARE @bufferStatement nvarchar(MAX);

		CREATE TABLE #inputbuffer (EventType nvarchar(30), Params smallint, EventInfo nvarchar(4000))

		OPEN filler; 
		FETCH NEXT FROM filler INTO @spid;

		WHILE @@FETCH_STATUS = 0 BEGIN 
			TRUNCATE TABLE [#inputbuffer];

			SET @sql = N'EXEC DBCC INPUTBUFFER(' + STR(@spid) + N');';
			
			BEGIN TRY 
				INSERT INTO [#inputbuffer]
				EXEC @sql;

				SET @bufferStatement = (SELECT TOP (1) EventInfo FROM [#inputbuffer]);
			END TRY 
			BEGIN CATCH 
				SET @bufferStatement = N'#Error Extracting Statement from DBCC INPUTBUFFER();';
			END CATCH

			UPDATE [#statements] 
			SET 
				[statement_source] = N'BUFFER', 
				[statement] = @bufferStatement 
			WHERE 
				[session_id] = @spid;

			FETCH NEXT FROM filler INTO @spid;
		END;
		
		CLOSE filler; 
		DEALLOCATE filler;

	END;

	IF @IncludePlans = 1 BEGIN 
		
		SELECT 
			c.[session_id], 
			p.[query_plan]
		INTO 
			#plans
		FROM 
			[#core] c 
			OUTER APPLY sys.[dm_exec_query_plan](c.[plan_handle]) p;
	END; 

	IF @IncludeContext = 1 BEGIN; 
		
		SELECT 
			c.[session_id], 
			(
				SELECT 
					[c].[statement_source],
					[c].[statement_handle],
					[c].[plan_handle],
					[c].[statement_start_offset],
					[c].[statement_end_offset],
					[c].[statement_source],	
					[s].[login_name], 
					[s].[host_name], 
					[s].[program_name]			
				FROM 
					#core c2 
					LEFT OUTER JOIN sys.[dm_exec_sessions] s ON c2.[session_id] = [s].[session_id]
				WHERE 
					c2.[session_id] = c.[session_id]
				FOR 
					XML PATH('context')
			) [context]
		INTO 
			#context
		FROM 
			#core  c;
	END;
	
	-------------------------------------------
	-- Generate Blocking Chains: 
	WITH chainedSessions AS ( 
		
		SELECT 
			0 [level], 
			session_id, 
			blocking_session_id, 
			blocked_session_id,
			CAST((N' ' + CHAR(187) + N' ' + CAST([blocked_session_id] AS sysname)) AS nvarchar(400)) [blocking_chain]
		FROM 
			#core 
		WHERE 
			[blocking_session_id] = 0 -- anchor to root... 

		UNION ALL 

		SELECT 
			([x].[level] + 1) [level], 
			c.session_id, 
			c.[blocking_session_id], 
			c.[blocked_session_id],
			CAST((x.[blocking_chain] + N' > ' + CAST(c.[blocked_session_id] AS sysname)) AS nvarchar(400)) [blocking_chain]
		FROM 
			[#core] c
			INNER JOIN [chainedSessions] x ON [c].[blocking_session_id] = x.blocked_session_id
	)

	SELECT 
		[session_id], 
		[level],
		[blocking_chain]
	INTO 
		#chain 
	FROM 
		[chainedSessions]
	ORDER BY 
		[level], [session_id];

	DECLARE @finalProjection nvarchar(MAX);

	SET @finalProjection = N'
	SELECT 
		CASE WHEN ISNULL(c.[database_id], 0) = 0 THEN ''resourcedb'' ELSE DB_NAME(c.[database_id]) END [database],
		[x].[blocking_chain],
        CASE WHEN c.[blocking_session_id] = 0 THEN N'' - '' ELSE REPLICATE(''   '', x.[level]) + CAST([c].[blocking_session_id] AS sysname) END [blocking_session_id],
        REPLICATE(''   '', x.[level]) + CAST(([c].[blocked_session_id]) AS sysname) [session_id],
        [c].[command],
        [c].[status],
        RTRIM(LTRIM([s].[statement])) [statement],
		[c].[wait_time],
		[c].[wait_type],
		[c].[wait_resource],
		dbo.format_timespan([c].[duration]) [duration],		
        
        ISNULL([c].[transaction_scope], '') [transaction_scope],
        ISNULL([c].[transaction_state], N'') [transaction_state],
        [c].[isolation_level],
        [c].[transaction_type]--,
--        [c].[open_transaction_count]
		{context}
		{query_plan}
	FROM 
		[#core] c 
		LEFT OUTER JOIN #chain x ON [c].[session_id] = [x].[session_id]
		LEFT OUTER JOIN [#context] cx ON [c].[session_id] = [cx].[session_id]
		LEFT OUTER JOIN [#statements] s ON c.[session_id] = s.[session_id] 
		LEFT OUTER JOIN [#plans] p ON [c].[session_id] = [p].[session_id]
	ORDER BY 
		x.level, c.duration DESC;
	';

	IF @IncludeContext = 1
		SET @finalProjection = REPLACE(@finalProjection, N'{context}', N' ,CAST(cx.[context] AS xml) [context] ');
	ELSE 
		SET @finalProjection = REPLACE(@finalProjection, N'{context}', N'');

	IF @IncludePlans = 1 
		SET @finalProjection = REPLACE(@finalProjection, N'{query_plan}', N' ,[p].[query_plan] ');
	ELSE 
		SET @finalProjection = REPLACE(@finalProjection, N'{query_plan}', N'');

	-- final projection:
	EXEC sp_executesql @finalProjection;

	RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
--- Monitoring
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_backup_execution','P') IS NOT NULL
	DROP PROC dbo.verify_backup_execution;
GO

CREATE PROC dbo.verify_backup_execution 
	@DatabasesToCheck					nvarchar(MAX),
	@DatabasesToExclude					nvarchar(MAX)		= NULL,
	@FullBackupAlertThresholdHours		int, 
	@LogBackupAlertThresholdMinutes		int,
	@MonitoredJobs						nvarchar(MAX)		= NULL, 
	@AllowNonAccessibleSecondaries		bit					= 0,
	@MinimumElapsedSecondsToConsider	int					= 60,   -- if a specified backup job has been running < @MinimumElapsedSecondsToConsider, then there's NO reason to raise an alert. 
	@MaximumElapsedSecondsToIgnore		int					= 300,			-- if a backup job IS running longer than normal, but is STILL under @MaximumElapsedSecondsToIgnore, then there's no reason to raise an alert. 
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[Database Backups - Failed Checkups] ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 

	-- Operator Checks:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalild Operator Name Specified.', 16, 1);
			RETURN -4;
		END;
	END;

	-- Profile Checks:
	DECLARE @DatabaseMailProfile nvarchar(255);
	EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
	IF @DatabaseMailProfile != @MailProfileName BEGIN
		RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
		RETURN -5;
	END;

	-----------------------------------------------------------------------------

	DECLARE @outputs table (
		output_id int IDENTITY(1,1) NOT NULL, 
		[type] sysname NOT NULL, -- warning or error 
		[message] nvarchar(MAX)
	);

	DECLARE @errorMessage nvarchar(MAX) = '';

	-----------------------------------------------------------------------------
	-- Determine which databases to check:
	DECLARE @databaseToCheckForFullBackups table (
		[name] sysname NOT NULL
	);

	DECLARE @databaseToCheckForLogBackups table (
		[name] sysname NOT NULL
	);

	INSERT INTO @databaseToCheckForFullBackups ([name])
	EXEC dbo.list_databases 
		@Targets = @DatabasesToCheck,
		@Exclusions = @DatabasesToExclude; 

	INSERT INTO @databaseToCheckForLogBackups ([name])
	EXEC dbo.list_databases 
		@Targets = @DatabasesToCheck,
		@Exclusions = @DatabasesToExclude, 
		@ExcludeSimpleRecovery = 1;

	-----------------------------------------------------------------------------
	-- Determine which jobs to check:
	DECLARE @specifiedJobs table ( 
		jobname sysname NOT NULL
	);

	DECLARE @jobsToCheck table ( 
		jobname sysname NOT NULL, 
		jobid uniqueidentifier NULL
	);

	INSERT INTO @specifiedJobs (jobname)
	SELECT [result] FROM dbo.split_string(@MonitoredJobs, N',', 1) ORDER BY row_id;

	INSERT INTO @jobsToCheck (jobname, jobid)
	SELECT 
		s.jobname, 
		j.job_id [jobid]
	FROM 
		@specifiedJobs s
		LEFT OUTER JOIN msdb..sysjobs j ON s.jobname COLLATE SQL_Latin1_General_CP1_CI_AS = j.[name];

	-----------------------------------------------------------------------------
	-- backup checks:

	BEGIN TRY

		-- FULL Backup Checks: 
		DECLARE @backupStatuses table (
			backup_id int IDENTITY(1,1) NOT NULL,
			[database_name] sysname NOT NULL, 
			[backup_type] sysname NOT NULL, 
			[minutes_since_last_backup] int
		);

		WITH core AS (
			SELECT 
				b.[database_name] COLLATE SQL_Latin1_General_CP1_CI_AS [database_name],
				CASE b.[type] COLLATE SQL_Latin1_General_CP1_CI_AS	
					WHEN 'D' THEN 'FULL'
					WHEN 'I' THEN 'DIFF'
					WHEN 'L' THEN 'LOG'
					ELSE 'OTHER'  -- options include, F, G, P, Q, [NULL] 
				END [backup_type],
				MAX(b.backup_finish_date) [last_completion]
			FROM 
				@databaseToCheckForFullBackups x
				INNER JOIN msdb.dbo.backupset b ON x.[name] = b.[database_name] COLLATE SQL_Latin1_General_CP1_CI_AS
			WHERE
				b.is_damaged = 0
				AND b.has_incomplete_metadata = 0
				AND b.is_copy_only = 0
			GROUP BY 
				b.[database_name]  COLLATE SQL_Latin1_General_CP1_CI_AS, 
				b.[type]  COLLATE SQL_Latin1_General_CP1_CI_AS
		) 
	
		INSERT INTO @backupStatuses ([database_name], backup_type, minutes_since_last_backup)
		SELECT 
			[database_name],
			[backup_type],
			DATEDIFF(MINUTE, last_completion, GETDATE()) [minutes_since_last_backup]
		FROM 
			core
		ORDER BY 
			[core].[database_name];

		-- Grab a list of any dbs that were specified for checkups, but which aren't on the server - then report on those, and use the temp-table for exclusions from subsequent checks:
		DECLARE @phantoms table (
			[name] sysname NOT NULL
		);

		INSERT INTO @phantoms ([name])
		SELECT [name] FROM @databaseToCheckForFullBackups WHERE [name] NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM master.sys.databases WHERE state_desc = 'ONLINE');

		-- Remove non-accessible secondaries (Mirrored or AG'd) as needed/specified:
		IF @AllowNonAccessibleSecondaries = 1 BEGIN

			DECLARE @activeSecondaries table ( 
				[name] sysname NOT NULL
			);

			INSERT INTO @activeSecondaries ([name])
			SELECT [name] FROM master.sys.databases 
			WHERE [name] IN (SELECT d.[name] FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL AND m.mirroring_role_desc != 'PRINCIPAL' )
			OR [name] IN (
				SELECT d.name 
				FROM master.sys.databases d 
				INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
				WHERE hars.role_desc != 'PRIMARY'
			); -- grab any dbs that are in an AG where the current role != PRIMARY. 


			-- remove secondaries from any list of CHECKS and from the list of statuses we've pulled back (because evaluation is a comparison of BOTH sides of the union/join of these sets).
			DELETE FROM @backupStatuses WHERE [database_name] IN (SELECT [name] FROM @activeSecondaries);

			DELETE FROM @phantoms WHERE [name] IN (SELECT [name] FROM @activeSecondaries);
			DELETE FROM @databaseToCheckForFullBackups WHERE [name] IN (SELECT [name] FROM @activeSecondaries);
			DELETE FROM @databaseToCheckForLogBackups WHERE [name] IN (SELECT [name] FROM @activeSecondaries);

		END;

		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING',
			N'Database [' + [name] + N'] was configured for backup checks/verifications - but is NOT currently listed as an ONLINE database on the server.'
		FROM 
			@phantoms
		ORDER BY 
			[name];

		-- Report on databases that were specified for checks, but which have NEVER been backed-up:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING', 
			N'Database [' + [name] + '] has been configured for regular FULL backup checks/verifications - but has NEVER been backed up.'
		FROM 
			@databaseToCheckForFullBackups
		WHERE 
			[name] NOT IN (SELECT [database_name] FROM @backupStatuses WHERE backup_type = 'FULL')
			AND [name] NOT IN (SELECT [name] FROM @phantoms);
		
		-- Report on databases that were specified for checks, but which haven't had FULL backups in > @FullBackupAlertThresholdHours:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING' [type], 
			N'The last successful FULL backup for database [' + [database_name] + N'] was ' + CAST((minutes_since_last_backup / 60) AS sysname) + N' hours (and ' + CAST((minutes_since_last_backup % 60) AS sysname) + N' minutes) ago - which exceeds the currently specified value of ' + CAST(@FullBackupAlertThresholdHours AS sysname) + N' hours for @FullBackupAlertThresholdHours.'
		FROM 
			@backupStatuses
		WHERE 
			backup_type = 'FULL'
			AND minutes_since_last_backup > 60 * @FullBackupAlertThresholdHours
		ORDER BY 
			minutes_since_last_backup DESC;

		-- Report on User DBs specified for checkups that are set to NON-SIMPLE recovery, and which haven't had their T-Logs backed up:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING',
			N'Database [' + [name] + N'] has been configured for regular LOG backup checks/verifiation - but has NEVER had its Transaction Log backed up.'
		FROM 
			@databaseToCheckForLogBackups
		WHERE 
			[name] NOT IN (SELECT [database_name] FROM @backupStatuses WHERE backup_type = 'LOG')
			AND [name] NOT IN (SELECT [name] FROM @phantoms);

		-- Report on databases in NON-SIMPLE recovery mode that haven't had their T-Logs backed up in > @LogBackupAlertThresholdMinutes:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING', 
			N'The last successful Transaction Log backup for database [' + [database_name] + N'] was ' + CAST((minutes_since_last_backup / 60) AS sysname) + N' hours (and ' + CAST((minutes_since_last_backup % 60) AS sysname) + N' minutes) ago - which exceeds the currently specified value of ' + CAST(@LogBackupAlertThresholdMinutes AS sysname) + N' minutes for @LogBackupAlertThresholdMinutes.'
		FROM 
			@backupStatuses
		WHERE 
			backup_type = 'LOG'
			AND minutes_since_last_backup > @LogBackupAlertThresholdMinutes
		ORDER BY 
			minutes_since_last_backup DESC;
	
	END TRY
	BEGIN CATCH
		SELECT @errorMessage = N'Exception during Backup Checks: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']'; 

		INSERT INTO @outputs ([type], [message])
		VALUES ('EXCEPTION', @errorMessage);

		SET @errorMessage = '';
	END CATCH

	-----------------------------------------------------------------------------
	-- job checks:


	IF (SELECT COUNT(*) FROM @jobsToCheck) > 0 BEGIN

		BEGIN TRY
			-- Warn about any jobs specified for checks that aren't actual jobs (i.e., where the names couldn't match a SQL Agent job).
			INSERT INTO @outputs ([type], [message])
			SELECT 
				N'WARNING', 
				N'Job [' + jobname + '] was configured for a regular checkup - but is NOT a VALID SQL Server Agent Job Name.'
			FROM 
				@jobsToCheck 
			WHERE 
				jobid IS NULL
			ORDER BY 
				jobname;

			-- otherwise, make sure that if the job is currently running, it hasn't exceeded 130% of the time it normally takes to run. 
			DECLARE @currentJobName sysname, @currentJobID uniqueidentifier;
			DECLARE @instanceCounts int, @avgRunDuration int;

			DECLARE @isExecuting bit, @elapsed int;
		
			DECLARE checker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT jobname, jobid FROM @jobsToCheck WHERE jobid IS NOT NULL; 

			OPEN checker;
			FETCH NEXT FROM checker INTO @currentJobName, @currentJobID;

			WHILE @@FETCH_STATUS = 0 BEGIN
				SET @isExecuting = 0;
				SET @elapsed = 0;

				WITH core AS ( 
					SELECT job_id, 
						DATEDIFF(SECOND, run_requested_date, GETDATE()) [elapsed] 
					FROM msdb.dbo.sysjobactivity 
					WHERE run_requested_date IS NOT NULL AND stop_execution_date IS NULL
				)

				SELECT 
					@isExecuting = CASE when job_id IS NULL THEN 0 ELSE 1 END, 
					@elapsed = elapsed 
				FROM 
					core
				WHERE 
					job_id = @currentJobID;

				-- 4.2.3.16822 Only check for 'long-running' jobs if a) duration is > @MinimumElapsedSecondsToConsider (i.e., don't alert for a job running 220% over normal IF 220% over normal is, say, 10 seconds TOTAL)
				--		 _AND_ b) if @elapsed is >  @MaximumElapsedSecondsToIgnore - i.e., don't alert if 'total elapsed' time is, say, 3 minutes - who cares...  (in 15 minutes when we run again, IF this job is still running (and that's a problem), THEN we'll get an alert). 
				IF (@isExecuting = 1) AND (@elapsed > @MinimumElapsedSecondsToConsider) AND (@elapsed > @MaximumElapsedSecondsToIgnore) BEGIN	

					-- check on execution durations:
					SELECT 
						@instanceCounts = COUNT(*), 
						@avgRunDuration = AVG(run_duration) 
					FROM (
						SELECT TOP(20)
							run_duration 
						FROM 
							msdb.dbo.sysjobhistory 
						WHERE 
							job_id = @currentJobID
							AND step_id = 0 AND run_status = 1 -- only grab metrics/durations for the ENTIRE duration of (successful only) executions.
						ORDER BY 
							run_date DESC, 
							run_time DESC
						) latest;
				

					IF @instanceCounts < 6 BEGIN 
						-- Arguably, we could send a 'warning' here ... but that's lame. At present, there is NOT a problem - because we don't have enough history to determine if this execution is 'out of scope' or not. 
						--		so, rather than causing false-alarms/red-herrings, just spit out a bit of info into the job history instead.
						PRINT 'History for job [' + @currentJobName + '] only contains information on the last ' + CAST(@instanceCounts AS sysname) + N' executions of the job. Meaning there is not enough history to determine abnormalities.'

				       END;
					ELSE BEGIN

						-- otherwise, if the current execution duration is > 220% of normal execution - raise an alert... 
						IF @elapsed > @avgRunDuration * 2.2 BEGIN
							INSERT INTO @outputs ([type], [message])
							SELECT 
								N'WARNING',
								N'Job [' + @currentJobName + N'] is currently running, and has been running for ' + CAST(@elapsed AS sysname) + N' seconds - which is greater than 220% of the average time it has taken to execute over the last ' + CAST(@instanceCounts AS sysname) + N' executions.'
						END;
					END;
				
				END;

				FETCH NEXT FROM checker INTO @currentJobName, @currentJobID;
			END;


		END TRY
		BEGIN CATCH
			SELECT @errorMessage = N'Exception during Job Checks: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']'; 

			INSERT INTO @outputs ([type], [message])
			VALUES ('EXCEPTION', @errorMessage);			
		END CATCH

		CLOSE checker;
		DEALLOCATE checker;

	END;  -- /IF JobChecks


	IF EXISTS (SELECT NULL FROM @outputs) BEGIN

		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9); 

		DECLARE @message nvarchar(MAX); 
		DECLARE @subject nvarchar(2000);

		IF EXISTS (SELECT NULL FROM @outputs WHERE [type] = 'EXCEPTION') 
			SET @subject = @EmailSubjectPrefix + N' Exceptions Detected';
		ELSE  
			SET @subject = @EmailSubjectPrefix + N' Warnings Detected';

		SET @message = N'The following problems were encountered during execution:' + @crlf + @crlf;

		--MKC: Insane. The following does NOT work. It returns only the LAST row from a multi-row 'set'. (remove the order-by, and ALL results return. Crazy.)
			--SELECT 
			--	@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
			--FROM 
			--	@outputs
			--ORDER BY 
			--	CASE WHEN [type] = 'EXCEPTION' THEN 0 ELSE 1 END ASC, output_id ASC;

		-- So, instead of combining 'types' of outputs, i'm just hacking this to concatenate 2x different result 'sets' or types of results. (I could try a CTE + Windowing Function... or .. something else, but this is easiest for now). 
		SELECT 
			@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
		FROM 
			@outputs
		WHERE 
			[type] = 'EXCEPTION'
		ORDER BY 
			output_id ASC;

		-- + this:
		SELECT 
			@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
		FROM 
			@outputs
		WHERE 
			[type] = 'WARNING'
		ORDER BY 
			output_id ASC;

		IF @PrintOnly = 1 BEGIN
			
			PRINT @subject;
			PRINT @message;

		  END
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @subject, 
				@body = @message;
		END;

	END;

	RETURN 0;
GO


-----------------------------------
USE admindb;
GO

IF OBJECT_ID('dbo.verify_database_configurations','P') IS NOT NULL
	DROP PROC dbo.verify_database_configurations;
GO

CREATE PROC dbo.verify_database_configurations 
	@DatabasesToExclude				nvarchar(MAX) = NULL,
	@CompatabilityExclusions		nvarchar(MAX) = NULL,
	@ReportDatabasesNotOwnedBySA	bit	= 0,
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[Database Configuration Alert] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -2;
		 END;
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -2;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -2;
		END; 
	END;

	-----------------------------------------------------------------------------
	-- Set up / initialization:

	-- start by (messily) grabbing the current version on the server:
	DECLARE @serverVersion int;
	SET @serverVersion = (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) * 10;

	DECLARE @databasesToCheck table (
		[name] sysname
	);
	
	INSERT INTO @databasesToCheck ([name])
	EXEC dbo.list_databases 
		@Targets = N'{USER}',
		@Exclusions = @DatabasesToExclude;

	DECLARE @excludedComptabilityDatabases table ( 
		[name] sysname NOT NULL
	); 

	IF @CompatabilityExclusions IS NOT NULL BEGIN 
		INSERT INTO @excludedComptabilityDatabases ([name])
		SELECT [result] FROM dbo.split_string(@CompatabilityExclusions, N',', 1) ORDER BY row_id;
	END; 

	DECLARE @issues table ( 
		issue_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		issue varchar(2000) NOT NULL, 
		command nvarchar(2000) NOT NULL, 
		success_message varchar(2000) NOT NULL,
		succeeded bit NOT NULL DEFAULT (0),
		[error_message] nvarchar(MAX) NULL 
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);

	-----------------------------------------------------------------------------
	-- Checks: 
	
	-- Compatablity Checks: 
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database],
		N'Compatibility should be ' + CAST(@serverVersion AS sysname) + N'. Currently set to ' + CAST(d.[compatibility_level] AS sysname) + N'.' [issue], 
		N'ALTER DATABASE' + QUOTENAME(d.[name]) + N' SET COMPATIBILITY_LEVEL = ' + CAST(@serverVersion AS sysname) + N';' [command], 
		N'Database Compatibility successfully set to ' + CAST(@serverVersion AS sysname) + N'.'  [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
		LEFT OUTER JOIN @excludedComptabilityDatabases e ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE e.[name] -- allow LIKE %wildcard% exclusions
	WHERE 
		d.[compatibility_level] <> CAST(@serverVersion AS tinyint)
		AND e.[name] IS  NULL -- only include non-exclusions
	ORDER BY 
		d.[name] ;
		
	-- Page Verify: 
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'Page Verify should be set to CHECKSUM. Currently set to ' + ISNULL(page_verify_option_desc, 'NOTHING') + N'.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET PAGE_VERIFY CHECKSUM; ' [command], 
		N'Page Verify successfully set to CHECKSUM.' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		page_verify_option_desc <> N'CHECKSUM'
	ORDER BY 
		d.[name];

	-- OwnerChecks:
	IF @ReportDatabasesNotOwnedBySA = 1 BEGIN
		INSERT INTO @issues ([database], [issue], [command], [success_message])
		SELECT 
			d.[name] [database], 
			N'Should be owned by 0x01 (SysAdmin). Currently owned by 0x' + CONVERT(nvarchar(MAX), owner_sid, 2) + N'.' [issue], 
			N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(d.[name]) + N' TO sa;' [command], 
			N'Database owndership successfully transferred to 0x01 (SysAdmin).' [success_message]
		FROM 
			sys.databases d
			INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
		WHERE 
			owner_sid <> 0x01;
	END;

	-- AUTO_CLOSE:
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'AUTO_CLOSE should be DISABLED. Currently ENABLED.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET AUTO_CLOSE OFF; ' [command], 
		N'AUTO_CLOSE successfully set to DISABLED.' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		[is_auto_close_on] = 1
	ORDER BY 
		d.[name];

	-- AUTO_SHRINK:
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'AUTO_SHRINK should be DISABLED. Currently ENABLED.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET AUTO_SHRINK OFF; ' [command], 
		N'AUTO_SHRINK successfully set to DISABLED.' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		[is_auto_shrink_on] = 1
	ORDER BY 
		d.[name];
		
	-----------------------------------------------------------------------------
	-- add other checks as needed/required per environment:

    -- vNEXT: figure out how to drop these details into a table and/or something that won't 'change' per environment. 
    --          i.e., say that in environment X we NEED to check for ABC... great. we hard code in here for that. 
    --              then S4 vNext comes out, ALTERS this (assuming there were changes) and the logic for ABC checks is overwritten... 



	-----------------------------------------------------------------------------
	-- (attempted) fixes: 
	IF EXISTS (SELECT NULL FROM @issues) BEGIN 

		DECLARE fixer CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[issue_id], 
			[command] 
		FROM 
			@issues 
		ORDER BY [issue_id];

		DECLARE @currentID int;
		DECLARE @currentCommand nvarchar(2000); 
		DECLARE @errorMessage nvarchar(MAX);

		OPEN [fixer];
		FETCH NEXT FROM [fixer] INTO @currentID, @currentCommand;

		WHILE @@FETCH_STATUS = 0 BEGIN 
			
			SET @errorMessage = NULL;

			BEGIN TRY 
                IF @PrintOnly = 0 BEGIN 
				    EXEC sp_executesql @currentCommand;
                END;

                UPDATE @issues SET [succeeded] = 1 WHERE [issue_id] = @currentID;

			END TRY 
			BEGIN CATCH
				SET @errorMessage = CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
				UPDATE @issues SET [error_message] = @errorMessage WHERE [issue_id] = @currentID;
			END CATCH

			FETCH NEXT FROM [fixer] INTO @currentID, @currentCommand;
		END;

		CLOSE [fixer]; 
		DEALLOCATE fixer;

	END;

	-----------------------------------------------------------------------------
	-- reporting: 
	DECLARE @emailBody nvarchar(MAX) = NULL;
	DECLARE @emailSubject nvarchar(300);
	IF EXISTS (SELECT NULL FROM @issues) BEGIN 
		SET @emailBody = N'';
		
		DECLARE @correctionErrorsOccurred bit = 0;
		DECLARE @correctionsCompletedSuccessfully bit = 0; 

		IF EXISTS (SELECT NULL FROM @issues WHERE [succeeded] = 0) BEGIN -- process ERRORS first. 
			SET @correctionErrorsOccurred = 1;
		END; 

		IF EXISTS (SELECT NULL FROM @issues WHERE [succeeded] = 1) BEGIN -- report on successful changes: 
			SET @correctionsCompletedSuccessfully = 1;
		END;

		IF @correctionErrorsOccurred = 1 BEGIN
			SET @emailSubject = @EmailSubjectPrefix + N' - Errors Addressing Database Settings';
			
			IF @correctionsCompletedSuccessfully = 1 
				SET @emailBody = N'Configuration Problems Detected. Some were automatically corrected; Others encountered errors during attempt to correct:' + @crlf + @crlf;
			ELSE 
				SET @emailBody = N'Configuration Problems Detected.' + @crlf + @crlf + UPPER(' Errors encountred while attempting to correct:') + @crlf + @crlf;

			SELECT 
				@emailBody = @emailBody + @tab + QUOTENAME([database]) + N' - ' + [issue] + @crlf
					+ @tab + @tab + N'ATTEMPTED CORRECTION: -> ' + [command] + @crlf
					+ @tab + @tab + @tab + N'ERROR: ' + ISNULL([error_message], N'##Unknown/Uncaptured##') + @crlf + @crlf
			FROM 
				@issues 
			WHERE 
				[succeeded] = 0 
			ORDER BY [issue_id];

		END;

		IF @correctionsCompletedSuccessfully = 1 BEGIN
			SET @emailSubject = @EmailSubjectPrefix + N' - Database Configuration Settings Successfully Updated';

			IF @correctionErrorsOccurred = 1
				SET @emailBody = @emailBody + @crlf + @crlf;

			SET @emailBody = @emailBody + N'The following database configuration changes were successfully applied:' + @crlf + @crlf;

			SELECT 
				@emailBody = @emailBody + @tab + QUOTENAME([database]) + @crlf
				+ @tab + @tab + N'OUTCOME: ' + [success_message] + @crlf + @crlf
				+ @tab + @tab + @tab + @tab + N'Detected Problem: ' + [issue] + @crlf
				+ @tab + @tab + @tab + @tab + N'Executed Correction: ' + [command] + @crlf + @crlf
			FROM 
				@issues 
			WHERE 
				[succeeded] = 1 
			ORDER BY [issue_id];
		END;

	END;

	-- send/display any problems:
	IF @emailBody IS NOT NULL BEGIN
		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
            PRINT N'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!';
            PRINT N'! NOTE: _NO CHANGES_ were made. The output below simply ''simulates'' what would have been done had @PrintOnly been set to 0:';
            PRINT N'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!';
			PRINT @emailBody;
		  END;
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailBody;
		END
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_drivespace','P') IS NOT NULL
	DROP PROC dbo.verify_drivespace;
GO

CREATE PROC dbo.verify_drivespace 
	@WarnWhenFreeGBsGoBelow				decimal(12,1)		= 22.0,				-- 
	@HalveThresholdAgainstCDrive		bit					= 0,				-- In RARE cases where some (piddly) dbs are on the C:\ drive, and there's not much space on the C:\ drive overall, it can make sense to treat the C:\ drive's available space as .5x what we'd see on a 'normal' drive.
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[DriveSpace Checks] ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs: 

	-- Operator Checks:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalild Operator Name Specified.', 16, 1);
			RETURN -4;
		END;
	END;

	-- Profile Checks:
	DECLARE @DatabaseMailProfile nvarchar(255);
	EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
	IF @DatabaseMailProfile != @MailProfileName BEGIN
		RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
		RETURN -5;
	END;

	DECLARE @core table (
		drive sysname NOT NULL, 
		available_gbs decimal(14,2) NOT NULL
	);

	INSERT INTO @core (drive, available_gbs)
	SELECT DISTINCT
		s.volume_mount_point [Drive],
		CAST(s.available_bytes / 1073741824 as decimal(12,2)) [AvailableMBs]
	FROM 
		sys.master_files f
		CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) s;

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);
	DECLARE @message nvarchar(MAX) = N'';

	-- Start with the C:\ drive if it's present (i.e., has dbs on it - which is a 'worst practice'):
	SELECT 
		@message = @message + @tab + drive + N' -> ' + CAST(available_gbs AS nvarchar(20)) +  N' GB free (vs. threshold of ' + CAST((CASE WHEN @HalveThresholdAgainstCDrive = 1 THEN @WarnWhenFreeGBsGoBelow / 2 ELSE @WarnWhenFreeGBsGoBelow END) AS nvarchar(20)) + N' GB) '  + @crlf
	FROM 
		@core
	WHERE 
		UPPER(drive) = N'C:\' AND 
		CASE 
			WHEN @HalveThresholdAgainstCDrive = 1 THEN @WarnWhenFreeGBsGoBelow / 2 
			ELSE @WarnWhenFreeGBsGoBelow
		END > available_gbs;

	-- Now process all other drives: 
	SELECT 
		@message = @message + @tab + drive + N' -> ' + CAST(available_gbs AS nvarchar(20)) +  N' GB free (vs. threshold of ' + CAST(@WarnWhenFreeGBsGoBelow AS nvarchar(20)) + N' GB) '  + @crlf
	FROM 
		@core
	WHERE 
		UPPER(drive) <> N'C:\'
		AND @WarnWhenFreeGBsGoBelow > available_gbs;

	IF LEN(@message) > 3 BEGIN 

		DECLARE @subject nvarchar(200) = ISNULL(@EmailSubjectPrefix, N'') + N'Low Disk Notification';

		SET @message = N'The following disks on ' + QUOTENAME(@@SERVERNAME) + ' have dropped below specified thresholds for Free Space (GBs) Specified: ' + @crlf + @crlf + @message;

		IF @PrintOnly = 1 BEGIN 
			PRINT @subject;
			PRINT @message;
		  END;
		ELSE BEGIN 

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName, -- operator name
				@subject = @subject, 
				@body = @message;			
		END; 
	END; 


	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.process_alerts','P') IS NOT NULL
	DROP PROC dbo.process_alerts;
GO

CREATE PROC dbo.process_alerts 
	@ErrorNumber				int, 
	@Severity					int, 
	@Message					nvarchar(2048),
	@OperatorName				sysname					= N'Alerts',
	@MailProfileName			sysname					= N'General', 
	@PrintOnly					bit						= 0
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @response nvarchar(2000); 
	SELECT @response = response FROM dbo.alert_responses 
	WHERE 
		message_id = @ErrorNumber
		AND is_enabled = 1;

	IF NULLIF(@response, N'') IS NOT NULL BEGIN 

		IF UPPER(@response) = N'[IGNORE]' BEGIN 

			-- this is an explicitly ignored alert. print the error details (which'll go into the SQL Server Agent Job log), then bail/return: 
			PRINT '[IGNORE] Error. Severity: ' + CAST(@Severity AS sysname) + N', ErrorNumber: ' + CAST(@ErrorNumber AS sysname) + N', Message: '  + @Message;
			RETURN 0;
		END;

		-- vNEXT:
			-- add additional processing options here. 
	END;

	------------------------------------
	-- If we're still here, then there were now 'special instructions' for this specific error/alert(so send an email with details): 

	DECLARE @body nvarchar(MAX) = N'DATE/TIME: {0}

DESCRIPTION: {1}

ERROR NUMBER: {2}' ;

	SET @body = REPLACE(@body, '{0}', CONVERT(nvarchar(20), GETDATE(), 100));
	SET @body = REPLACE(@body, '{1}', @Message);
	SET @body = REPLACE(@body, '{2}', @ErrorNumber);

	DECLARE @subject nvarchar(256) = N'SQL Server Alert System: ''Severity {0}'' occurred on {1}';

	SET @subject = REPLACE(@subject, '{0}', @Severity);
	SET @subject = REPLACE(@subject, '{1}', @@SERVERNAME); 
	
	IF @PrintOnly = 1 BEGIN 
			PRINT N'SUBJECT: ' + @subject; 
			PRINT N'BODY: ' + @body;
	  END;
	ELSE BEGIN
		EXEC msdb.dbo.sp_notify_operator
			@profile_name = @MailProfileName, 
			@name = @OperatorName,
			@subject = @subject, 
			@body = @body;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.monitor_transaction_durations','P') IS NOT NULL
	DROP PROC dbo.monitor_transaction_durations;
GO


CREATE PROC dbo.monitor_transaction_durations	
	@ExcludeSystemProcesses				bit					= 1,				
	@ExcludedDatabases					nvarchar(MAX)		= NULL,				-- N'master, msdb'  -- recommended that tempdb NOT be excluded... (long running txes in tempdb are typically going to be a perf issue - typically (but not always).
	@ExcludedLoginNames					nvarchar(MAX)		= NULL, 
	@ExcludedProgramNames				nvarchar(MAX)		= NULL,
	@ExcludedSQLAgentJobNames			nvarchar(MAX)		= NULL,
	@AlertOnlyWhenBlocking				bit					= 0,				-- if there's a long-running TX, but it's not blocking... and this is set to 1, then no alert is raised. 
	@AlertThreshold						sysname				= N'10m',			-- defines how long a transaction has to be running before it's 'raised' as a potential problem.
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[ALERT:] ', 
	@PrintOnly							bit					= 0
AS
	
	RAISERROR('Sorry. The S4 stored procedure dbo.monitor_transaction_durations is NOT supported on SQL Server 2008/2008R2 instances.', 16, 1);
	RETURN -100;
GO

DECLARE @monitor_transaction_durations nvarchar(MAX) = N'ALTER PROC dbo.monitor_transaction_durations	
	@ExcludeSystemProcesses				bit					= 1,				
	@ExcludedDatabases					nvarchar(MAX)		= NULL,				-- N''master, msdb''  -- recommended that tempdb NOT be excluded... (long running txes in tempdb are typically going to be a perf issue - typically (but not always).
	@ExcludedLoginNames					nvarchar(MAX)		= NULL, 
	@ExcludedProgramNames				nvarchar(MAX)		= NULL,
	@ExcludedSQLAgentJobNames			nvarchar(MAX)		= NULL,
	@AlertOnlyWhenBlocking				bit					= 0,				-- if there''s a long-running TX, but it''s not blocking... and this is set to 1, then no alert is raised. 
	@AlertThreshold						sysname				= N''10m'',			-- defines how long a transaction has to be running before it''s ''raised'' as a potential problem.
	@OperatorName						sysname				= N''Alerts'',
	@MailProfileName					sysname				= N''General'',
	@EmailSubjectPrefix					nvarchar(50)		= N''[ALERT:] '', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -----------------------------------------------------------------------------
    -- Validate Inputs: 
	SET @AlertThreshold = LTRIM(RTRIM(@AlertThreshold));
	DECLARE @transactionCutoffTime datetime; 

	DECLARE @vectorError nvarchar(MAX); 

	EXEC dbo.[translate_vector_datetime]
	    @Vector = @AlertThreshold,
	    @ValidationParameterName = N''@AlertThreshold'',
	    @ProhibitedIntervals = N''WEEK, MONTH, QUARTER, YEAR'',
	    @Output = @transactionCutoffTime OUTPUT,
	    @Error = @vectorError OUTPUT
	
	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1); 
		RETURN -10;
	END;

	SELECT 
		[dtat].[transaction_id],
        [dtat].[transaction_begin_time], 
		[dtst].[session_id],
        [dtst].[enlist_count] [active_requests],
        [dtst].[is_user_transaction],
        [dtst].[open_transaction_count]
	INTO 
		#LongRunningTransactions
	FROM 
		sys.[dm_tran_active_transactions] dtat
		LEFT OUTER JOIN sys.[dm_tran_session_transactions] dtst ON dtat.[transaction_id] = dtst.[transaction_id]
	WHERE 
		[dtst].[session_id] IS NOT NULL
		AND [dtat].[transaction_begin_time] < @transactionCutoffTime
	ORDER BY 
		[dtat].[transaction_begin_time];

	IF NOT EXISTS(SELECT NULL FROM [#LongRunningTransactions]) 
		RETURN 0;  -- nothing to report on... 
		
	IF @ExcludeSystemProcesses = 1 BEGIN 
		DELETE lrt 
		FROM 
			[#LongRunningTransactions] lrt
			LEFT OUTER JOIN sys.[dm_exec_sessions] des ON lrt.[session_id] = des.[session_id]
		WHERE 
			des.[is_user_process] = 0
			OR des.[session_id] < 50
			OR des.[database_id] IS NULL;  -- also, delete any operations where the db_id is NULL
	END;

	IF NULLIF(@ExcludedDatabases, N'''') IS NOT NULL BEGIN 
		DELETE lrt 
		FROM 
			[#LongRunningTransactions] lrt
			LEFT OUTER JOIN sys.[dm_exec_sessions] des ON lrt.[session_id] = des.[session_id]
		WHERE 
			des.[database_id] IN (SELECT d.database_id FROM sys.databases d LEFT OUTER JOIN dbo.[split_string](@ExcludedDatabases, N'','', 1) ss ON d.[name] = ss.[result] WHERE ss.[result] IS NOT NULL);
	END;

	IF NOT EXISTS(SELECT NULL FROM [#LongRunningTransactions]) 
		RETURN 0;  -- filters removed anything to report on. 

	-- Grab Statements
	WITH handles AS ( 
		SELECT 
			sp.spid [session_id], 
			sp.[sql_handle]
		FROM 
			sys.[sysprocesses] sp
			INNER JOIN [#LongRunningTransactions] lrt ON sp.[spid] = lrt.[session_id]
	)

	SELECT 
		[session_id],
		t.[text] [statement]
	INTO 
		#Statements
	FROM 
		handles h
		OUTER APPLY sys.[dm_exec_sql_text](h.[sql_handle]) t;

	CREATE TABLE #ExcludedSessions (
		session_id int NOT NULL
	);

	-- Process additional exclusions if present: 
	IF ISNULL(@ExcludedLoginNames, N'''') IS NOT NULL BEGIN 

		INSERT INTO [#ExcludedSessions] ([session_id])
		SELECT 
			s.[session_id]
		FROM 
			dbo.[split_string](@ExcludedLoginNames, N'','', 1) x 
			INNER JOIN sys.[dm_exec_sessions] s ON s.[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE x.[result];
	END;

	IF ISNULL(@ExcludedProgramNames, N'''') IS NOT NULL BEGIN 
		INSERT INTO [#ExcludedSessions] ([session_id])
		SELECT 
			s.[session_id]
		FROM 
			dbo.[split_string](@ExcludedProgramNames, N'','', 1) x 
			INNER JOIN sys.[dm_exec_sessions] s ON s.[program_name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE x.[result];
	END;

	IF ISNULL(@ExcludedSQLAgentJobNames, N'''') IS NOT NULL BEGIN 
		DECLARE @jobIds table ( 
			job_id nvarchar(200) 
		); 

		INSERT INTO @jobIds ([job_id])
		SELECT 
			N''%'' + CONVERT(nvarchar(200), (CONVERT(varbinary(200), j.job_id , 1)), 1) + N''%'' job_id
		FROM 
			msdb.dbo.sysjobs j
			INNER JOIN admindb.dbo.[split_string](@ExcludedSQLAgentJobNames, N'','', 1) x ON j.[name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE x.[result];

		INSERT INTO [#ExcludedSessions] ([session_id])
		SELECT 
			s.session_id 
		FROM 
			sys.[dm_exec_sessions] s 
			INNER JOIN @jobIds x ON s.[program_name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE x.[job_id];
	END; 

	DELETE lrt 
	FROM 
		[#LongRunningTransactions] lrt 
	INNER JOIN 
		[#ExcludedSessions] x ON lrt.[session_id] = x.[session_id];


	IF @AlertOnlyWhenBlocking = 1 BEGIN
		DECLARE @iteration int = 0;

		DECLARE @sessions_that_are_blocking table ( 
			session_id int NOT NULL 
		);

CheckForBlocking:
		
		-- NOTE: ARGUABLY, this should be using sys.dm_exec_requests... only, there''s a HUGE problem with that ''table'' - it only shows in-flight requests that are blocked... (so if something is blocked and NOT in a RUNNING state... it won''t show up). 

		SELECT 
			lrt.session_id 
		FROM 
			[#LongRunningTransactions] lrt 
			--INNER JOIN sys.[dm_exec_requests] r ON lrt.[session_id] = r.[blocking_session_id]
			INNER JOIN sys.[sysprocesses] p ON lrt.[session_id] = p.[blocked]
		WHERE 
			lrt.[session_id] NOT IN (SELECT session_id FROM @sessions_that_are_blocking);

		-- short-circuit if we''ve confirmed that ALL long-running-transactions are blocking:
		IF NOT EXISTS (SELECT NULL FROM [#LongRunningTransactions] t1 LEFT OUTER JOIN @sessions_that_are_blocking t2 ON t1.[session_id] = t2.[session_id] WHERE t2.[session_id] IS NULL) BEGIN 
			GOTO BlockingCheckComplete;
		END;

		WAITFOR DELAY ''00:00:02.000'';
	
		SET @iteration = @iteration + 1; 

		IF @iteration < 10
			GOTO CheckForBlocking;
		
BlockingCheckComplete:
		
		-- remove any long-running transactions that were NOT showing as blocking... 
		DELETE lrt
		FROM 
			[#LongRunningTransactions] lrt 
		WHERE [lrt].[session_id] NOT IN (SELECT [session_id] FROM @sessions_that_are_blocking);

	END;

	IF NOT EXISTS(SELECT NULL FROM [#LongRunningTransactions]) 
		RETURN 0;  -- nothing to report on... 

	-- Assemble output/report: 
	DECLARE @line nvarchar(200) = REPLICATE(N''-'', 200);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9); 
	DECLARE @messageBody nvarchar(MAX) = N'''';

	SELECT 
		@messageBody = @messageBody + @line + @crlf
		+ ''- session_id ['' + CAST(ISNULL(lrt.[session_id], -1) AS sysname) + N''] has been running in database '' +  QUOTENAME(COALESCE(DB_NAME([dtdt].[database_id]), DB_NAME(sx.[database_id]),''#NULL#'')) + N'' for a duration of: '' + dbo.[format_timespan](DATEDIFF(MILLISECOND, lrt.[transaction_begin_time], GETDATE())) + N''.'' + @crlf 
		+ @tab + N''METRICS: '' + @crlf
		+ @tab + @tab + N''[is_user_transaction: '' + CAST(ISNULL(lrt.[is_user_transaction], N''-1'') AS sysname) + N'']'' + @crlf 
		+ @tab + @tab + N''[open_transaction_count: ''+ CAST(ISNULL(lrt.[open_transaction_count], N''-1'') AS sysname) + N'']'' + @crlf
		+ @tab + @tab + N''[blocked_session_count: '' + CAST(ISNULL((SELECT COUNT(*) FROM sys.[sysprocesses] p WHERE lrt.session_id = p.blocked), 0) AS sysname) + N'']'' + @crlf  
		+ @tab + @tab + N''[active_requests: '' + CAST(ISNULL(lrt.[active_requests], N''-1'') AS sysname) + N'']'' + @crlf 
		+ @tab + @tab + N''[is_tempdb_enlisted: '' + CAST(ISNULL([dtdt].[tempdb_enlisted], N''-1'') AS sysname) + N'']'' + @crlf 
		+ @tab + @tab + N''[log_record (count|bytes): ('' + CAST(ISNULL([dtdt].[log_record_count], N''-1'') AS sysname) + N'') | ( '' + CAST(ISNULL([dtdt].[log_bytes_used], N''-1'') AS sysname) + N'') ]'' + @crlf
		+ @crlf
		+ @tab + N''CONTEXT: '' + @crlf
		+ @tab + @tab + N''[login_name]: '' + CAST(ISNULL(sx.[login_name], N''#NULL#'') AS sysname) + N'']'' + @crlf 
		+ @tab + @tab + N''[program_name]: '' + CAST(ISNULL(sx.[program_name], N''#NULL#'') AS sysname) + N'']'' + @crlf 
		+ @tab + @tab + N''[host_name]: '' + CAST(ISNULL(sx.[host_name], N''#NULL#'') AS sysname) + N'']'' + @crlf 
		+ @crlf
        + @tab + N''STATEMENT'' + @crlf + @crlf
		+ @tab + @tab + REPLACE(ISNULL(s.[statement], N''#EMPTY STATEMENT#''), @crlf, @crlf + @tab + @tab)
	FROM 
		[#LongRunningTransactions] lrt
		LEFT OUTER JOIN sys.[dm_exec_sessions] sx ON lrt.[session_id] = sx.[session_id]
		LEFT OUTER JOIN ( 
			SELECT 
				x.transaction_id,
				MAX(x.database_id) [database_id], -- max isn''''t always logical/best. But with tempdb_enlisted + enlisted_db_count... it''''s as good as it gets... 
				SUM(CASE WHEN x.database_id = 2 THEN 1 ELSE 0 END) [tempdb_enlisted],
				COUNT(x.database_id) [enlisted_db_count],
				MAX(x.[database_transaction_log_record_count]) [log_record_count],
				MAX(x.[database_transaction_log_bytes_used]) [log_bytes_used]
			FROM 
				sys.[dm_tran_database_transactions] x WITH(NOLOCK)
			GROUP BY 
				x.transaction_id
		) dtdt ON lrt.[transaction_id] = dtdt.[transaction_id]
		LEFT OUTER JOIN [#Statements] s ON lrt.[session_id] = s.[session_id]

	DECLARE @message nvarchar(MAX) = N''The following long-running transactions (and associated) details were found - which exceed the @AlertThreshold of [''  + @AlertThreshold + N''].'' + @crlf
		+ @tab + N''(Details about how to resolve/address potential problems follow AFTER identified long-running transactions.)'' + @crlf 
		+ ISNULL(@messageBody, N''#NULL in DETAILS#'')
		+ @crlf 
		+ @crlf 
		+ @line + @crlf
		+ @line + @crlf 
		+ @tab + N''To resolve:  '' + @crlf
		+ @tab + @tab + N''First, execute the following statement against '' + @@SERVERNAME + N'' to ensure that the long-running transaction is still causing problems: '' + @crlf
		+ @crlf
		+ @tab + @tab + @tab + @tab + N''EXEC admindb.dbo.list_transactions;'' + @crlf 
		+ @crlf 
		+ @tab + @tab + N''If the same session_id is still listed and causing problems, you can attempt to KILL the session in question by running '' + @crlf 
		+ @tab + @tab + @tab + N''KILL X - where X is the session_id you wish to terminate. (So, if session_id 234 is causing problems, you would execute KILL 234; )'' + @crlf 
		+ @tab + @tab + N''WARNING: KILLing an in-flight/long-running transaction is NOT an immediate operation. It typically takes around 75% - 150% of the time a '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''transaction has taken to ''''roll-forward'''' in order to ''''KILL'''' or ROLLBACK a long-running operation. '' + @crlf
		+ @tab + @tab + @tab + N''Example: suppose it takes 10 minutes for a long-running transaction (like a large UPDATE or DELETE operation) to complete and/or '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''GET stuck - or it has been running for ~10 minutes when you attempt to KILL it.'' + @crlf
		+ @tab + @tab + @tab + @tab + N''At this point (i.e., 10 minutes into an active transaction), you should ROUGHLY expect the rollback to take ''  + @crlf
		+ @tab + @tab + @tab + @tab + @tab + N'' anywhere from 7 - 15 minutes to execute.'' + @crlf
		+ @tab + @tab + @tab + @tab + N''NOTE: If a short/simple transaction (like running an UPDATE against a single row) executes and the gets ''''orphaned'''' (i.e., it '' + @crlf 
		+ @tab + @tab + @tab + @tab + @tab + N''somehow gets stuck and/or there was an EXPLICIT BEGIN TRAN and the operation is waiting on an explicit COMMIT), '' + @crlf
		+ @tab + @tab + @tab + @tab + @tab + N''then, in this case, the transactional ''''overhead'''' should have been minimal - meaning that a KILL operation should be very QUICK ''  + @crlf 
		+ @tab + @tab + @tab + @tab + @tab + @tab + N''and almost immediate - because you are only rolling-back a few milliseconds'''' or second''''s worth of transactional overhead.'' + @crlf 
		+ @crlf
		+ @tab + @tab + N''Once you KILL a session, the rollback proccess will begin (if there was a transaction in-flight). Keep checking admindb.dbo.list_transactions to see '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''IF the session in question is still running - and once it is DONE running blocked processes and other operations SHOULD start to work as normal again.'' + @crlf
		+ @tab + @tab + @tab + N''IF you would like to see ROLLBACK process you can run: KILL ### WITH STATUSONLY; and SQL Server will USUALLY (but not always) provide a relatively accurate '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''picture of how far along the rollback is. '' + @crlf 
		+ @crlf
		+ @tab + @tab + N''NOTE: If you are unable to determine the ''''root'''' blocker and/or are WILLING to effectively take the ENTIRE database ''''down'''' to fix problems with blocking/time-outs '' + @crlf 
		+ @tab + @tab + @tab + N''due to long-running transactions, you CAN kick the entire database in question into SINGLE_USER mode thereby forcing all '' + @crlf
		+ @tab + @tab + @tab + N''in-flight transactions to ROLLBACK - at the expense of (effectively) KILLing ALL connections into the database AND preventing new connections.'' + @crlf
		+ @tab + @tab + @tab + N''As you might suspect, this is effectively a ''''nuclear'''' option - and can/will result in across-the-board down-time against the database in question. '' + @crlf
		+ @tab + @tab + @tab + N''WARNING: Knocking a database into SINGLE_USER mode will NOT do ANYTHING to ''''speed up'''' or decrease ROLLBACK time for any transactions in flight. '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''In fact, because it KILLs ALL transactions in the target database, it can take LONGER in some cases to ''''go'''' SINGLE_USER mode '' + @crlf
		+ @tab + @tab + @tab + @tab + N''than finding/KILLing a root-blocker. Likewise, taking a database into SINGLE_USER mode is a semi-advanced operation and should NOT be done lightly.'' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + N''To force a database into SINGLE_USER mode (and kill all connections/transactions), run the following from within the master database: '' + @crlf
		+ @crlf 
		+ @tab + @tab + @tab + @tab + N''ALTER DATABSE [targetDBNameHere] SET SINGLE_USER WITH ROLLBACK AFTER 5 SECONDS;'' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + N''The command above will allow any/all connections and transactions currently active in the target database another 5 seconds to complete - while also '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''blocking any NEW connections into the database. After 5 seconds (and you can obvious set this value as you would like), all in-flight transactions '' + @crlf
		+ @tab + @tab + @tab + @tab + N''will be KILLed and start the ROLLBACK process - and any active connections in the database will also be KILLed and kicked-out of the database in question.'' + @crlf
		+ @tab + @tab + @tab + N''WARNING: Once a database has been put into SINGLE_USER mode it can ONLY be accessed by the session that switched the database into SINGLE_USER mode. As such, if '' + @crlf 
		+ @tab + @tab + @tab + @tab + N''you CLOSE your connection/session - ''''control'''' of the database ''''falls'''' to the next session that '' + @crlf
		+ @tab + @tab + @tab + @tab + N''accesses the database - and all OTHER connections are blocked - which means that IF you close your connection/session, you will have to ACTIVELY fight other '' + @crlf
		+ @tab + @tab + @tab + @tab + N''processes for connection into the database before you can set it to MULTI_USER again - and clear it for production use.'' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + N''Once a database has been put into SINGLE_USER mode (i.e., after the command has been executed and ALL in-flight transactions have been rolled-back and all '' + @crlf
		+ @tab + @tab + @tab + @tab + N''connections have been terminated and the state of the database switches to SINGLE_USER mode), any transactional locking and blocking in the target database'' + @crlf
		+ @tab + @tab + @tab + @tab + N''will be corrected. At which point you can then return the database to active service by switching it back to MULTI_USER mode by executing the following: '' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + @tab + @tab + N''ALTER DATABASE [targetDatabaseInSINGLE_USERMode] SET MULTI_USER;'' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + @tab + N''Note that the command above can ONLY be successfully executed by the session_id that currently ''''owns'''' the SINGLE_USER access into the database in question.'' + @crlf;

	IF @PrintOnly = 1 BEGIN 
		PRINT @message;
	  END;
	ELSE BEGIN 

		DECLARE @subject nvarchar(200); 
		DECLARE @txCount int; 
		SET @txCount = (SELECT COUNT(*) FROM [#LongRunningTransactions]); 

		SET @subject = @EmailSubjectPrefix + ''Long-Running Transaction Detected'';
		IF @txCount > 1 SET @subject = @EmailSubjectPrefix + CAST(@txCount AS sysname) + '' Long-Running Transactions Detected'';

		EXEC msdb..sp_notify_operator
			@profile_name = @MailProfileName,
			@name = @OperatorName,
			@subject = @subject, 
			@body = @message;
	END;

	RETURN 0;

 ';

IF (SELECT dbo.get_engine_version())> 10.5 
	EXEC sp_executesql @monitor_transaction_durations;

------------------------------------------------------------------------------------------------------------------------------------------------------
--- Diagnostics
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.help_index','P') IS NOT NULL
	DROP PROC dbo.[help_index];
GO

CREATE PROC dbo.[help_index]
	@Target					sysname				= NULL

AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @Target, 
		@ParameterNameForTarget = N'@Target', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 

	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetTable sysname;
	SELECT 
		@targetDatabase = PARSENAME(@normalizedName, 3),
		@targetSchema = PARSENAME(@normalizedName, 2), 
		@targetTable = PARSENAME(@normalizedName, 1);

	DECLARE @sql nvarchar(MAX);
	SET @sql = N'SELECT index_id, [name] FROM [' + @targetDatabase + N'].sys.[indexes] WHERE [object_id] = @targetObjectID; ';

	CREATE TABLE #sys_indexes (
		index_id int NOT NULL, 
		index_name sysname NOT NULL 
	);

	INSERT INTO [#sys_indexes] (
		[index_id],
		[index_name]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@targetObjectID int', 
		@targetObjectID = @targetObjectID;


	SET @sql = N'
	SELECT 
		ic.index_id, 
		c.[name] column_name, 
		ic.key_ordinal,
		ic.is_included_column, 
		ic.is_descending_key 
	FROM 
		[' + @targetDatabase + N'].sys.index_columns ic 
		INNER JOIN [' + @targetDatabase + N'].sys.columns c ON ic.[object_id] = c.[object_id] AND ic.column_id = c.column_id 
	WHERE 
		ic.[object_id] = @targetObjectID;
	';

	CREATE TABLE #index_columns (
		index_id int NOT NULL, 
		column_name sysname NOT NULL, 
		key_ordinal int NOT NULL,
		is_included_column bit NOT NULL, 
		is_descending_key bit NOT NULL
	);

	INSERT INTO [#index_columns] (
		[index_id],
		[column_name],
		[key_ordinal],
		[is_included_column],
		[is_descending_key]
	)
	EXEC [sys].[sp_executesql] 
		@sql, 
		N'@targetObjectID int', 
		@targetObjectID = @targetObjectID;

	--SELECT * FROM [#sys_indexes];

	--SELECT * FROM [#index_columns];

	CREATE TABLE #output (
		index_id int NOT NULL, 
		index_name sysname NOT NULL, 
		[definition] nvarchar(MAX) NOT NULL 
	);

	DECLARE @serialized nvarchar(MAX);
	DECLARE @currentIndexID int, @currentIndexName sysname;
	DECLARE [serializer] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		index_id, 
		index_name 
	FROM 
		[#sys_indexes] 
	ORDER BY 
		[index_id];
	
	OPEN [serializer];
	FETCH NEXT FROM [serializer] INTO @currentIndexID, @currentIndexName;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @serialized = N'';

		WITH core AS ( 
			SELECT 
				ic.column_name, 
				CASE 
					WHEN ic.is_included_column = 1 THEN 999 
					ELSE ic.key_ordinal 
				END [ordinal], 
				ic.is_descending_key
			FROM 
				[#sys_indexes] i
				INNER JOIN [#index_columns] ic ON i.[index_id] = ic.[index_id]
			WHERE 
				i.[index_id] = @currentIndexID
		) 	

		SELECT 
			@serialized = @serialized 
				+ CASE WHEN ordinal = 999 THEN N'[' ELSE N'' END 
				+ column_name 
				+ CASE WHEN is_descending_key = 1 THEN N' DESC' ELSE N'' END 
				+ CASE WHEN ordinal = 999 THEN N']' ELSE N'' END
				+ N','				   
		FROM 
			[core] 
		ORDER BY 
			[ordinal];

		SET @serialized = SUBSTRING(@serialized, 0, LEN(@serialized));

		INSERT INTO [#output] (
			[index_id],
			[index_name],
			[definition]
		)
		VALUES	(
			@currentIndexID, 
			@currentIndexName, 
			@serialized
		)

		FETCH NEXT FROM [serializer] INTO @currentIndexID, @currentIndexName;
	END;
	
	CLOSE [serializer];
	DEALLOCATE [serializer];

	-- Projection: 
	SELECT 
		[index_id],
		CASE WHEN [index_id] = 0 THEN N'-HEAP-' ELSE [index_name] END [index_name],
		CASE WHEN [index_id] = 0 THEN N'-HEAP-' ELSE [definition] END [definition]
	FROM 
		[#output]
	ORDER BY 
		[index_id];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_sysadmins_and_owners','P') IS NOT NULL
	DROP PROC dbo.[list_sysadmins_and_owners];
GO

CREATE PROC dbo.[list_sysadmins_and_owners]
	@ListType				sysname						= N'SYSADMINS_AND_OWNERS',			-- { SYSADMINS | OWNERS | SYSADMINS_AND_OWNERS }
	@TargetDatabases		nvarchar(MAX)				= N'{ALL}', 
	@Exclusions				nvarchar(MAX)				= NULL, 
	@Priorities				nvarchar(MAX)				= NULL
AS
    SET NOCOUNT ON; 

    -- {copyright}

	CREATE TABLE #principals (
		[row_id] int IDENTITY(1, 1),
		[scope] sysname NOT NULL,
		[database] sysname NOT NULL,
		[role] sysname NOT NULL,
		[login_or_user_name] sysname NOT NULL
	);

	IF UPPER(@ListType) LIKE '%SYSADMINS%' BEGIN

		INSERT INTO #principals (
			[scope],
			[database],
			[role],
			[login_or_user_name]
		)
		SELECT
			N'SERVER' [scope],
			N'' [database],
			[r].[name] [role],
			[sp].[name] [login_name]
		FROM
			[sys].[server_principals] [sp],
			[sys].[server_role_members] [rm],
			[sys].[server_principals] [r]
		WHERE
			[sp].[principal_id] = [rm].[member_principal_id] AND [r].[principal_id] = [rm].[role_principal_id] AND LOWER([r].[name]) IN (N'sysadmin', N'securityadmin')
		ORDER BY
			[r].[name],
			[sp].[name];

	END;

	IF UPPER(@ListType) LIKE '%OWNER%' BEGIN
		----------------------------------------------------------------------------------------------------------------------------------
		-- TODO: 
		--		this is a PURE ugly implementation at this point - it's using sp_msForEachDB... 
		--		instead, need to spin up a cursor for each db in @targets or whatever... 
		--		and grab non-dbo usrs per each db and spit them out as members of the db_owner role. 
		DECLARE @targetDBs table ( 
			row_id int IDENTITY(1,1) NOT NULL,
			[database_name] sysname NOT NULL
		);

		INSERT INTO @targetDBs (
			[database_name]
		)
		EXEC dbo.[list_databases]
			@Targets = @TargetDatabases,
			@Exclusions = @Exclusions,
			@Priorities = @Priorities,
			@ExcludeClones = 1,
			@ExcludeSecondaries = 1,
			@ExcludeSimpleRecovery = 0,
			@ExcludeReadOnly = 0,
			@ExcludeRestoring = 1,
			@ExcludeRecovering = 1,
			@ExcludeOffline = 1;
		
		DECLARE @databaseName sysname;
		DECLARE @template nvarchar(MAX) = N'
			INSERT INTO #principals ([scope], [database], [role], [login_or_user_name]) 
			SELECT ''DATABASE'' [scope], ''{dbname}'', ''db_owner'' [role], p.[name] [login_or_user_name]
			FROM 
				[{dbname}].sys.database_role_members m
				INNER JOIN [{dbname}].sys.database_principals r ON m.role_principal_id = r.principal_id
				INNER JOIN [{dbname}].sys.database_principals p ON m.member_principal_id = p.principal_id
			WHERE 
				r.[name] = ''db_owner''
				AND p.[name] <> ''dbo''; ';

		DECLARE @command nvarchar(MAX);
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[database_name]
		FROM 
			@targetDBs
		ORDER BY 
			[row_id];

		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @databaseName;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			SET @command = REPLACE(@template, N'{dbname}', @databaseName);

			EXEC sp_executesql @command;
		
			FETCH NEXT FROM [walker] INTO @databaseName;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

	END;

	SELECT
		*
	FROM
		#principals
	ORDER BY 
		row_id;

	RETURN 0;
GO





------------------------------------------------------------------------------------------------------------------------------------------------------
--- Maintenance
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.check_database_consistency','P') IS NOT NULL
	DROP PROC dbo.[check_database_consistency];
GO

CREATE PROC dbo.[check_database_consistency]
	@Targets								nvarchar(MAX)	                        = N'{ALL}',		-- {ALL} | {SYSTEM} | {USER} | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions								nvarchar(MAX)	                        = NULL,			-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities								nvarchar(MAX)	                        = NULL,			-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@IncludeExtendedLogicalChecks           bit                                     = 0,
    @OperatorName						    sysname									= N'Alerts',
	@MailProfileName					    sysname									= N'General',
	@EmailSubjectPrefix					    nvarchar(50)							= N'[Database Corruption Checks] ',	
    @PrintOnly                              bit                                     = 0
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
    IF @PrintOnly = 0 BEGIN 
        DECLARE @check int;

	    EXEC @check = dbo.verify_advanced_capabilities;
        IF @check <> 0
            RETURN @check;

        EXEC @check = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @check <> 0 
            RETURN @check;
    END;

    DECLARE @DatabasesToCheck table ( 
        row_id int IDENTITY(1,1) NOT NULL,
        [database_name] sysname NOT NULL
    ); 

    INSERT INTO @DatabasesToCheck (
        [database_name]
    )
    EXEC dbo.[list_databases]
        @Targets = @Targets,
        @Exclusions = @Exclusions,
        @Priorities = @Priorities,
        @ExcludeClones = 1,
        @ExcludeSecondaries = 1,
        @ExcludeSimpleRecovery = 0,
        @ExcludeReadOnly = 0,
        @ExcludeRestoring = 1,
        @ExcludeRecovering = 1,
        @ExcludeOffline = 1;
    
    DECLARE @errorMessage nvarchar(MAX); 
	DECLARE @errors table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[error_message] xml NOT NULL
	);
	
	DECLARE @currentDbName sysname; 
    DECLARE @sql nvarchar(MAX);
    DECLARE @template nvarchar(MAX) = N'DBCC CHECKDB([{DbName}]) WITH NO_INFOMSGS, ALL_ERRORMSGS{ExtendedChecks};';
	DECLARE @succeeded int;

    IF @IncludeExtendedLogicalChecks = 1 
        SET @template = REPLACE(@template, N'{ExtendedChecks}', N', EXTENDED_LOGICAL_CHECKS');
    ELSE 
        SET @template = REPLACE(@template, N'{ExtendedChecks}', N'');

    DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
    SELECT 
        [database_name]
    FROM 
        @DatabasesToCheck
    ORDER BY 
        [row_id];

    OPEN [walker]; 
    FETCH NEXT FROM [walker] INTO @currentDbName;

    WHILE @@FETCH_STATUS = 0 BEGIN 

		SET @sql = REPLACE(@template, N'{DbName}', @currentDbName);

		IF @PrintOnly = 1 
			PRINT @sql; 
		ELSE BEGIN 
			DECLARE @results xml;
			EXEC @succeeded = dbo.[execute_command]
			    @Command = @sql,
			    @ExecutionType = N'SQLCMD',
			    @ExecutionAttemptsCount = 1,
			    @DelayBetweenAttempts = NULL,
			    @IgnoredResults = N'[COMMAND_SUCCESS]',
			    @PrintOnly = 0,
			    @Results = @results OUTPUT;

			IF @succeeded <> 0 BEGIN 
				INSERT INTO @errors (
				    [database_name],
				    [error_message]
				)
				VALUES (
					@currentDbName, 
					@results
				);
			END;
		END;

        FETCH NEXT FROM [walker] INTO @currentDbName;    
    END;

    CLOSE [walker];
    DEALLOCATE [walker];

	DECLARE @emailBody nvarchar(MAX);
	DECLARE @emailSubject nvarchar(300);

	IF EXISTS (SELECT NULL FROM @errors) BEGIN 
		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9);


		SET @emailSubject = ISNULL(@EmailSubjectPrefix, N'') + ' DATABASE CONSISTENCY CHECK ERRORS';
		SET @emailBody = N'The following problems were encountered: ' + @crlf; 

		SELECT 
			@emailBody = @emailBody + UPPER([database_name]) + @crlf + @tab + CAST([error_message] AS nvarchar(MAX)) + @crlf + @crlf
		FROM 
			@errors 
		ORDER BY 
			[row_id];
	END;

	IF @emailBody IS NOT NULL BEGIN 

        EXEC msdb..sp_notify_operator
            @profile_name = @MailProfileName,
            @name = @OperatorName,
            @subject = @emailSubject, 
            @body = @emailBody;
	END; 
	
	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_logfile_sizes','P') IS NOT NULL
	DROP PROC dbo.list_logfile_sizes;
GO

CREATE PROC dbo.list_logfile_sizes
	@TargetDatabases					nvarchar(MAX),															-- { {ALL} | {SYSTEM} | {USER} | name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX)							= NULL,							-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX)							= NULL,
	--@IgnoreLogFilesWithGBsLessThan	decimal(12,1)							= 0.5,
	@ExcludeSimpleRecoveryDatabases		bit										= 1,
	@SerializedOutput					xml										= N'<default/>'			OUTPUT
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Inputs:




	-----------------------------------------------------------------------------
	
	CREATE TABLE #targetDatabases ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[vlf_count] int NULL, 
		[mimimum_allowable_log_size_gb] decimal(20,2) NULL
	);

	INSERT INTO [#targetDatabases] ([database_name])
	EXEC dbo.list_databases
		@Targets = @TargetDatabases, 
		@Exclusions = @DatabasesToExclude, 
		@Priorities = @Priorities, 
		@ExcludeSimpleRecovery = @ExcludeSimpleRecoveryDatabases;

	CREATE TABLE #logSizes (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[recovery_model] sysname NOT NULL,
		[database_size_gb] decimal(20,2) NOT NULL, 
		[log_size_gb] decimal(20,2) NOT NULL, 
		[log_percent_used] decimal(5,2) NOT NULL,
		[vlf_count] int NOT NULL,
		[log_as_percent_of_db_size] decimal(5,2) NULL, 
		[mimimum_allowable_log_size_gb] decimal(20,2) NOT NULL, 
	);

	IF NOT EXISTS (SELECT NULL FROM [#targetDatabases]) BEGIN 
		PRINT 'No databases matched @TargetDatbases (and @DatabasesToExclude) Inputs.'; 
		SELECT * FROM [#logSizes];
		RETURN 0; -- success (ish).
	END;

	DECLARE walker CURSOR LOCAL READ_ONLY FAST_FORWARD FOR 
	SELECT [database_name] FROM [#targetDatabases];

	DECLARE @currentDBName sysname; 
	DECLARE @vlfCount int; 
	DECLARE @startOffset bigint;
	DECLARE @fileSize bigint;
	DECLARE @MinAllowableSize decimal(20,2);

	DECLARE @template nvarchar(1000) = N'INSERT INTO #logInfo EXECUTE (''DBCC LOGINFO([{0}]) WITH NO_INFOMSGS''); ';
	DECLARE @command nvarchar(2000);

	CREATE TABLE #logInfo (
		RecoveryUnitId bigint,
		FileID bigint,
		FileSize bigint,
		StartOffset bigint,
		FSeqNo bigint,
		[Status] bigint,
		Parity bigint,
		CreateLSN varchar(50)
	);

	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDBName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		DELETE FROM [#logInfo];
		SET @command = REPLACE(@template, N'{0}', @currentDBName); 

		EXEC master.sys.[sp_executesql] @command;
		SELECT @vlfCount = COUNT(*) FROM [#logInfo];

		SELECT @startOffset = MAX(StartOffset) FROM #LogInfo WHERE [Status] = 2;
		SELECT @fileSize = FileSize FROM #LogInfo WHERE StartOffset = @startOffset;
		SET @MinAllowableSize = CAST(((@startOffset + @fileSize) / (1024.0 * 1024.0 * 1024.0)) AS decimal(20,2))

		UPDATE [#targetDatabases] 
		SET 
			[vlf_count] = @vlfCount, 
			[mimimum_allowable_log_size_gb] = @MinAllowableSize 
		WHERE 
			[database_name] = @currentDBName;

		FETCH NEXT FROM [walker] INTO @currentDBName;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	WITH core AS ( 
		SELECT
			x.[row_id],
			db.[name] [database_name], 
			db.recovery_model_desc [recovery_model],	
			CAST((CONVERT(decimal(20,2), sizes.size * 8.0 / (1024.0) / (1024.0))) AS decimal(20,2)) database_size_gb,
			CAST((logsize.log_size / (1024.0)) AS decimal(20,2)) [log_size_gb],
			CASE 
				WHEN logsize.log_size = 0 THEN 0.0
				WHEN logused.log_used = 0 THEN 0.0
				ELSE CAST(((logused.log_used / logsize.log_size) * 100.0) AS decimal(5,2))
			END log_percent_used, 
			x.[vlf_count], 
			x.[mimimum_allowable_log_size_gb]
		FROM 
			sys.databases db
			INNER JOIN #targetDatabases x ON db.[name] = x.database_name
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / (1024.0)) AS decimal(20,2)) [log_size] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Size %') logsize ON db.[name] = logsize.[db_name]
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / (1024.0)) AS decimal(20,2)) [log_used] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Used %') logused ON db.[name] = logused.[db_name]
			LEFT OUTER JOIN (
				SELECT	database_id, SUM(size) size, COUNT(database_id) [Files] FROM sys.master_files WHERE [type] = 0 GROUP BY database_id
			) sizes ON db.database_id = sizes.database_id		
	) 

	INSERT INTO [#logSizes] (
        [database_name], 
        [recovery_model], 
        [database_size_gb], 
        [log_size_gb], 
        [log_percent_used], 
        [vlf_count], 
        [log_as_percent_of_db_size], 
        [mimimum_allowable_log_size_gb]
    )
	SELECT 
        [database_name],
        [recovery_model],
        [database_size_gb],
        [log_size_gb],
        [log_percent_used], 
		[vlf_count],
		CAST(((([log_size_gb] / CASE WHEN [database_size_gb] = 0 THEN 0.01 ELSE [core].[database_size_gb] END) * 100.0)) AS decimal(20,2)) [log_as_percent_of_db_size],		-- goofy issue with divide by zero is reason for CASE... 
		[mimimum_allowable_log_size_gb]
	FROM 
		[core]
	ORDER BY 
		[row_id];

	-----------------------------------------------------------------------------
    -- Send output as XML if requested:
	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY...
		SELECT @SerializedOutput = (SELECT 
			[database_name],
			[recovery_model],
			[database_size_gb],
			[log_size_gb],
			[log_percent_used],
			[vlf_count],
			[log_as_percent_of_db_size], 
			[mimimum_allowable_log_size_gb]
		FROM 
			[#logSizes]
		ORDER BY 
			[row_id] 
		FOR XML PATH('database'), ROOT('databases'));

		RETURN 0;
	END; 

	-----------------------------------------------------------------------------
	-- otherwise, project:
	SELECT 
        [database_name],
        [recovery_model],
        [database_size_gb],
        [log_size_gb],
        [log_percent_used],
		[vlf_count],
        [log_as_percent_of_db_size], 
		[mimimum_allowable_log_size_gb]
	FROM 
		[#logSizes]
	ORDER BY 
		[row_id];


	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.shrink_logfiles','P') IS NOT NULL
	DROP PROC dbo.shrink_logfiles;
GO

CREATE PROC dbo.shrink_logfiles
	@TargetDatabases							nvarchar(MAX),																		-- { {ALL} | {SYSTEM} | {USER} | name1,name2,etc }
	@DatabasesToExclude							nvarchar(MAX)							= NULL,										-- { NULL | name1,name2 }  
	@Priorities									nvarchar(MAX)							= NULL,										
	@TargetLogPercentageSize					int										= 20,										-- can be > 100? i.e., 200? would be 200% - which ... i guess is legit, right? 
	@ExcludeSimpleRecoveryDatabases				bit										= 1,										
	@IgnoreLogFilesSmallerThanGBs				decimal(5,2)							= 0.25,										-- e.g., don't bother shrinking anything > 200MB in size... 								
	@LogFileSizingBufferInGBs					decimal(5,2)							= 0.25,										-- a) when targetting a log for DBCC SHRINKFILE() add this into the target and b) when checking on dbs POST shrink, if they're under target + this Buffer, they're FINE/done/shrunk/ignored.
	@MaxTimeToWaitForLogBackups					sysname									= N'20m',		
	@LogBackupCheckPollingInterval				sysname									= N'40s',									-- Interval that defines how long to wait between 'polling' attempts to look for new T-LOG backups... 
	@OperatorName								sysname									= N'Alerts',
	@MailProfileName							sysname									= N'General',
	@EmailSubjectPrefix							nvarchar(50)							= N'[Log Shrink Operations ] ',
	@PrintOnly									bit										= 0
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Validate Dependencies:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:

	DECLARE @maxSecondsToWaitForLogFileBackups int; 
	DECLARE @error nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	EXEC dbo.[translate_vector]
	    @Vector = @MaxTimeToWaitForLogBackups,
	    @ValidationParameterName = N'@MaxTimeToWaitForLogBackups',
		@ProhibitedIntervals = N'MILLISECOND, DAY, WEEK, MONTH, QUARTER, YEAR',
	    @TranslationDatePart = N'SECOND',
	    @Output = @maxSecondsToWaitForLogFileBackups OUTPUT,
	    @Error = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN -10;
	END; 

	DECLARE @waitDuration sysname;
	EXEC dbo.[translate_vector_delay]
	    @Vector = @LogBackupCheckPollingInterval,
	    @ParameterName = N'@LogBackupCheckPollingInterval',
	    @Output = @waitDuration OUTPUT,
	    @Error = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN -11;
	END; 

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @targetRatio decimal(6,2) = @TargetLogPercentageSize / 100.0;
	DECLARE @BufferMBs int = CAST((@LogFileSizingBufferInGBs * 1024.0) AS int);  

	-- get a list of dbs to target/review: 
	CREATE TABLE #logSizes (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[recovery_model] sysname NOT NULL,
		[database_size_gb] decimal(20,2) NOT NULL, 
		[log_size_gb] decimal(20,2) NOT NULL, 
		[log_percent_used] decimal(5,2) NOT NULL,
		[initial_min_allowed_gbs] decimal(20,2) NOT NULL, 
		[target_log_size] decimal(20,2) NOT NULL, 
		[operation] sysname NULL, 
		[last_log_backup] datetime NULL, 
		[processing_complete] bit NOT NULL DEFAULT (0)
	);

	CREATE TABLE #operations (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[timestamp] datetime NOT NULL DEFAULT(GETDATE()), 
		[operation] nvarchar(2000) NOT NULL, 
		[outcome] nvarchar(MAX) NOT NULL, 
	);

	DECLARE @SerializedOutput xml = NULL;
	EXEC dbo.[list_logfile_sizes]
	    @TargetDatabases = @TargetDatabases,
	    @DatabasesToExclude = @DatabasesToExclude,
	    @Priorities = @Priorities,
	    @ExcludeSimpleRecoveryDatabases = @ExcludeSimpleRecoveryDatabases,
	    @SerializedOutput = @SerializedOutput OUTPUT;
	
	WITH shredded AS ( 
		SELECT 
			[data].[row].value('database_name[1]', 'sysname') [database_name], 
			[data].[row].value('recovery_model[1]', 'sysname') recovery_model, 
			[data].[row].value('database_size_gb[1]', 'decimal(20,1)') database_size_gb, 
			[data].[row].value('log_size_gb[1]', 'decimal(20,1)') log_size_gb,
			[data].[row].value('log_percent_used[1]', 'decimal(5,2)') log_percent_used, 
			[data].[row].value('vlf_count[1]', 'int') vlf_count,
			[data].[row].value('log_as_percent_of_db_size[1]', 'decimal(5,2)') log_as_percent_of_db_size,
			[data].[row].value('mimimum_allowable_log_size_gb[1]', 'decimal(20,1)') [initial_min_allowed_gbs]
		FROM 
			@SerializedOutput.nodes('//database') [data]([row])
	), 
	targets AS ( 
		SELECT
			[database_name],
			CAST(([shredded].[database_size_gb] * @targetRatio) AS decimal(20,2)) [target_log_size] 
		FROM 
			[shredded]
	) 
	
	INSERT INTO [#logSizes] (
        [database_name], 
        [recovery_model], 
        [database_size_gb], 
        [log_size_gb], 
        [log_percent_used], 
        [initial_min_allowed_gbs], 
        [target_log_size]
    )
	SELECT 
		[s].[database_name],
        [s].[recovery_model],
        [s].[database_size_gb],
        [s].[log_size_gb],
        [s].[log_percent_used],
        [s].[initial_min_allowed_gbs] [starting_mimimum_allowable_log_size_gb], 
		CAST((CASE WHEN t.[target_log_size] < @IgnoreLogFilesSmallerThanGBs THEN @IgnoreLogFilesSmallerThanGBs ELSE t.[target_log_size] END) AS decimal(20,2)) [target_log_size]
	FROM 
		[shredded] s 
		INNER JOIN [targets] t ON [s].[database_name] = [t].[database_name];

	WITH operations AS ( 
		SELECT 
			[database_name], 
			CASE 
				WHEN [log_size_gb] <= [target_log_size] THEN 'NOTHING' -- N'N/A - Log file is already at target size or smaller. (Current Size: ' + CAST([log_size_gb] AS sysname) + N' GB - Target Size: ' + CAST([target_log_size] AS sysname) + N' GB)'
				ELSE CASE 
					WHEN [initial_min_allowed_gbs] <= ([target_log_size] + @LogFileSizingBufferInGBs) THEN 'SHRINK'
					ELSE N'CHECKPOINT + BACKUP + SHRINK'
				END
			END [operation]
		FROM 
			[#logSizes]
	) 

	UPDATE x 
	SET 
		x.[operation] = o.[operation]
	FROM 
		[#logSizes] x 
		INNER JOIN [operations] o ON [x].[database_name] = [o].[database_name];

	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE [operation] = N'NOTHING') BEGIN 
		INSERT INTO [#operations] ([database_name], [operation], [outcome])
		SELECT 
			[database_name],
			N'NOTHING. Log file is already at target size or smaller. (Current Size: ' + CAST([log_size_gb] AS sysname) + N' GB - Target Size: ' + CAST([target_log_size] AS sysname) + N' GB)' [operation],
			N'' [outcome]
		FROM 
			[#logSizes] 
		WHERE 
			[operation] = N'NOTHING'
		ORDER BY 
			[row_id];

		UPDATE [#logSizes] 
		SET 
			[processing_complete] = 1
		WHERE 
			[operation] = N'NOTHING';
	END;

	DECLARE @returnValue int;
	DECLARE @outcome nvarchar(MAX);
	DECLARE @currentDatabase sysname;
	DECLARE @targetSize int;
	DECLARE @command nvarchar(2000); 
	DECLARE @executionResults xml;

	DECLARE @checkpointComplete datetime; 
	DECLARE @waitStarted datetime;
	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE [operation] = N'CHECKPOINT + BACKUP + SHRINK') BEGIN 
		
		-- start by grabbing the latest backups: 
		UPDATE [ls]
		SET 
			ls.[last_log_backup] = x.[backup_finish_date]
		FROM 
			[#logSizes] ls
			INNER JOIN ( 
				SELECT
					[database_name],
					MAX([backup_finish_date]) [backup_finish_date]
				FROM 
					msdb.dbo.[backupset]
				WHERE 
					[type] = 'L'
				GROUP BY 
					[database_name]
			) x ON [ls].[database_name] = [x].[database_name]
		WHERE 
			ls.[processing_complete] = 0 AND ls.[operation] = N'CHECKPOINT + BACKUP + SHRINK';


		DECLARE @checkpointTemplate nvarchar(200) = N'USE [{0}]; ' + @crlf + N'CHECKPOINT; ' + @crlf + N'CHECKPOINT;' + @crlf + N'CHECKPOINT;';
		DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[database_name]
		FROM 
			[#logSizes] 
		WHERE 
			[processing_complete] = 0 AND [operation] = N'CHECKPOINT + BACKUP + SHRINK';

		OPEN walker; 
		FETCH NEXT FROM walker INTO @currentDatabase;

		WHILE @@FETCH_STATUS = 0 BEGIN

			SET @command = REPLACE(@checkpointTemplate, N'{0}', @currentDatabase);

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN 
			
				EXEC @returnValue = dbo.[execute_command]
					@Command = @command,
					@ExecutionType = N'SQLCMD',
					@ExecutionRetryCount = 1, 
					@DelayBetweenAttempts = N'5s',
					@Results = @executionResults OUTPUT 
			
				IF @returnValue = 0	BEGIN
					SET @outcome = N'SUCCESS';
				  END;
				ELSE BEGIN
					SET @outcome = N'ERROR: ' + CAST(@executionResults AS nvarchar(MAX));
				END;

				SET @checkpointComplete = GETDATE();

				INSERT INTO [#operations] ([database_name], [timestamp], [operation], [outcome])
				VALUES (@currentDatabase, @checkpointComplete, @command, @outcome);

				IF @returnValue <> 0 BEGIN
					-- we needed a checkpoint before we could go any further... it didn't work (somhow... not even sure that's a possibility)... so, we're 'done'. we need to terminate early.
					PRINT 'run an update where operation = checkpoint/backup/shrink and set those pigs to done with an ''early termination'' summary as the operation... we can keep trying other dbs... ';
				END;

			END;

			FETCH NEXT FROM walker INTO @currentDatabase;
		END;

		CLOSE walker;
		DEALLOCATE walker;


		SET @waitStarted = GETDATE();
WaitAndCheck:
		
		IF @PrintOnly = 1 BEGIN 
			SET @command = N'';
			SELECT @command = @command + [database_name] + N', ' FROM [#logSizes] WHERE [operation] = N'CHECKPOINT + BACKUP + SHRINK';
			
			PRINT N'-- NOTE: LogFileBackups of the following databases are required before processing can continue: '
			PRINT N'--		' + LEFT(@command, LEN(@command) - 1);

			GOTO ShrinkLogFile;
		END;

		WAITFOR DELAY @waitDuration;  -- Wait, then poll for new T-LOG backups:
-- TODO: arguably... i could keep track of the # of dbs we're waiting on ... and, each time we detect that a new DB has been T-log backed up... i could 'GOTO ShrinkDBs;' and then... if there are any dbs to process (at the end of that block of logic (i.e., @dbsWaitingOn > 0) then... GOTO WaitAndStuff;.. and, then, just tweak the way we do the final error/check - as in, if we've waited too long and stil have dbs to process, then.. we log the error message and 'goto' some other location (the end).
--			that way, say we've got t-logs cycling at roughly 2-3 minute intervals over the next N minutes... ... currently, if we're going to wait up to 20 minutes, we'll wait until ALL of them have been be backed up (or as many as we could get to before we timed out) and then PROCESS ALL of them. 
--				the logic above would, effectively, process each db _AS_ its t-log backup was completed... making it a bit more 'robust' and better ... 
		-- keep looping/waiting while a) we have time left, and b) there are dbs that have NOT been backed up.... 
		IF DATEDIFF(MINUTE, @waitStarted, GETDATE()) < @maxSecondsToWaitForLogFileBackups BEGIN 
			IF EXISTS (SELECT NULL FROM [#logSizes] ls 
				INNER JOIN (SELECT [database_name], MAX([backup_finish_date]) latest FROM msdb.dbo.[backupset] WHERE type = 'L' GROUP BY [database_name]) x ON ls.[database_name] = [x].[database_name] 
					WHERE ls.[last_log_backup] IS NOT NULL AND x.[latest] < @checkpointComplete
			) BEGIN
					GOTO WaitAndCheck;
			END;
		END;

		-- done waiting - either we've now got T-LOG backups for all DBs, or we hit our max wait time: 
		INSERT INTO [#operations] ([database_name], [operation], [outcome])
		SELECT 
			ls.[database_name], 
			N'TIMEOUT' [operation], 
			N'Max Wait Time of (N) reached - last t-log backup of x was found (vs t-log backup > checkpoint date that was needed. SHRINKFILE won''t work.. ' [outcome]
		FROM 
			[#logSizes] ls 
			INNER JOIN ( 
				SELECT
					[database_name],
					MAX([backup_finish_date]) [backup_finish_date]
				FROM 
					msdb.dbo.[backupset]
				WHERE 
					[type] = 'L'
				GROUP BY 
					[database_name]
			) x ON [ls].[database_name] = [x].[database_name] 
		WHERE 
			ls.[operation] = N'CHECKPOINT + BACKUP + SHRINK'
			AND x.[backup_finish_date] < @checkpointComplete;
		
	END;


ShrinkLogFile:
	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE ([operation] = N'SHRINK') OR ([operation] = N'CHECKPOINT + BACKUP + SHRINK')) BEGIN 
		
		DECLARE @minLogFileSize int = CAST((@IgnoreLogFilesSmallerThanGBs * 1024.0) as int);
		DECLARE shrinker CURSOR LOCAL READ_ONLY FAST_FORWARD FOR 
		SELECT [database_name], (CAST(([target_log_size] * 1024.0) AS int) - @BufferMBs) [target_log_size] FROM [#logSizes] WHERE [processing_complete] = 0 AND ([operation] = N'SHRINK') OR ([operation] = N'CHECKPOINT + BACKUP + SHRINK');

		OPEN [shrinker]; 
		FETCH NEXT FROM [shrinker] INTO @currentDatabase, @targetSize;

		WHILE @@FETCH_STATUS = 0 BEGIN

			BEGIN TRY 

				IF @targetSize < @minLogFileSize
					SET @targetSize = @minLogFileSize;

				SET @command = N'USE [{database}];' + @crlf + N'DBCC SHRINKFILE(2, {size}) WITH NO_INFOMSGS;';
				SET @command = REPLACE(@command, N'{database}', @currentDatabase);
				SET @command = REPLACE(@command, N'{size}', @targetSize);

				IF @PrintOnly = 1 BEGIN
					PRINT @command; 
					SET @outcome = N'';
				  END;
				ELSE BEGIN
					
					EXEC @returnValue = dbo.[execute_command]
					    @Command = @command, 
					    @ExecutionType = N'SQLCMD', 
					    @IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS]', 
					    @Results = @executionResults OUTPUT;
					
					IF @returnValue = 0
						SET @outcome = N'SUCCESS';	
					ELSE 
						SET @outcome = N'ERROR: ' + CAST(@executionResults AS nvarchar(MAX));
				END;
				
			END TRY 
			BEGIN CATCH 
				SET @outcome = N'EXCEPTION: ' + CAST(ERROR_LINE() AS sysname ) + N' - ' + ERROR_MESSAGE();
			END	CATCH

			INSERT INTO [#operations] ([database_name], [operation], [outcome])
			VALUES (@currentDatabase, @command, @outcome);

			FETCH NEXT FROM [shrinker] INTO @currentDatabase, @targetSize;
		END;

		CLOSE shrinker;
		DEALLOCATE [shrinker];

	END; 



	-- TODO: final operation... 
	--   a) go get a new 'logFileSizes' report... 
	--	b) report on any t-logs that are still > target... 

	-- otherwise... spit out whatever form of output/report would make sense at this point... where... we can bind #operations up as XML ... as a set of details about what happened here... 

	SET @SerializedOutput = NULL;
	EXEC dbo.[list_logfile_sizes]
	    @TargetDatabases = @TargetDatabases,
	    @DatabasesToExclude = @DatabasesToExclude,
	    @Priorities = @Priorities,
	    @ExcludeSimpleRecoveryDatabases = @ExcludeSimpleRecoveryDatabases,
	    @SerializedOutput = @SerializedOutput OUTPUT;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value('database_name[1]', 'sysname') [database_name], 
			[data].[row].value('recovery_model[1]', 'sysname') recovery_model, 
			[data].[row].value('database_size_gb[1]', 'decimal(20,1)') database_size_gb, 
			[data].[row].value('log_size_gb[1]', 'decimal(20,1)') log_size_gb,
			[data].[row].value('log_percent_used[1]', 'decimal(5,2)') log_percent_used, 
			--[data].[row].value('vlf_count[1]', 'int') vlf_count,
			--[data].[row].value('log_as_percent_of_db_size[1]', 'decimal(5,2)') log_as_percent_of_db_size,
			[data].[row].value('mimimum_allowable_log_size_gb[1]', 'decimal(20,1)') [initial_min_allowed_gbs]
		FROM 
			@SerializedOutput.nodes('//database') [data]([row])
	)

	SELECT 
		[origin].[database_name], 
		[origin].[database_size_gb], 
		[origin].[log_size_gb] [original_log_size_gb], 
		[origin].[target_log_size], 
		x.[log_size_gb] [current_log_size_gb], 
		CASE WHEN (x.[log_size_gb] - @LogFileSizingBufferInGBs) <= [origin].[target_log_size] THEN 'SUCCESS' ELSE 'FAILURE' END [shrink_outcome], 
		CAST((
			SELECT  
				[row_id] [operation/@id],
				[timestamp] [operation/@timestamp],
				[operation],
				[outcome]		
			FROM 
				[#operations] o 
			WHERE 
				o.[database_name] = x.[database_name]
			ORDER BY 
				[o].[row_id]
			FOR XML PATH('operation'), ROOT('operations')) AS xml) [xml_operations]		
	FROM 
		[shredded] x 
		INNER JOIN [#logSizes] origin ON [x].[database_name] = [origin].[database_name]
	ORDER BY 
		[origin].[row_id];

	-- TODO: send email alerts based on outcomes above (specifically, pass/fail and such).

	-- in terms of output: 
	--		want to see those that PASSED and those that FAILED> 
	--			also? I'd like to see a summary of how much disk was reclaimed ... and how much stands to be reclaimed if/when we fix the 'FAILURE' outcomes. 
	--				so, in other words, some sort of header... 
	--		and... need the output sorted by a) failures first, then successes, b) row_id... (that way... it's clear which ones passed/failed). 
	--		

	--	also... MIGHT want to look at removing the WITH NO_INFOMSGS switch from the DBCC SHRINKFILE operations... 
	--			cuz.. i'd like to collect/gather the friggin errors - they seem to consistently keep coming back wiht 'end of file' crap - which is odd, given that I'm running checkpoint up the wazoo. 

	RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
--- Tools
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.[normalize_text]', 'P') IS NOT NULL 
	DROP PROC dbo.[normalize_text];
GO

CREATE PROC dbo.[normalize_text]
	@InputStatement			nvarchar(MAX)		= NULL, 
	@NormalizedOutput		nvarchar(MAX)		OUTPUT, 
	@ParametersOutput		nvarchar(MAX)		OUTPUT, 
	@ErrorInfo				nvarchar(MAX)		OUTPUT
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-- effectively, just putting a wrapper around sp_get_query_template - to account for the scenarios/situations where it throws an error or has problems.

	/*
		Problem Scenarios: 
			a. multi-statement batches... 
					b. requires current/accurate schema  - meaning that it HAS to be run (effectively) in the same db as where the statement was defined... (or a close enough proxy). 
						ACTUALLY, i think this might have been a limitation of the SQL Server 2005 version - pretty sure it doesn't cause problems (at all) on 2016 (and... likely 2008+)... 

					YEAH, this is NO longer valid... 
					specifically, note the 2x remarks/limitations listed in the docs (for what throws an error): 
						https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-get-query-template-transact-sql?view=sql-server-2017


			c. statements without any parameters - i.e., those without a WHERE clause... 

			d. implied: sprocs or other EXEC operations (or so I'd 100% expect). 
				CORRECT - as per this 'example': 

						DECLARE @normalized nvarchar(max), @params nvarchar(max); 
						EXEC sp_get_query_template    
							N'EXEC Billing.dbo.AddDayOff N''2018-11-13'', ''te3st day'';', 
							@normalized OUTPUT, 
							@params OUTPUT; 

						SELECT @normalized, @params;

				totally throws an excption - as expected... 



		So, just account for those concerns and provide fixes/work-arounds/hacks for all of those... 
			
	
	*/

	SET @InputStatement = ISNULL(LTRIM(RTRIM(@InputStatement)), '');
	DECLARE @multiStatement bit = 0;
	DECLARE @noParams bit = 0; 
	DECLARE @isExec bit = 0; 

	-- check for multi-statement batches (using SIMPLE/BASIC batch scheme checks - i.e., NOT worth getting carried away on all POTENTIAL permutations of how this could work). 
	IF (@InputStatement LIKE N'% GO %') OR (@InputStatement LIKE N';' AND @InputStatement NOT LIKE N'%sp_executesql%;%') 
		SET @multiStatement = 1; 

	-- TODO: if it's multi-statement, then 'split' on the terminator, parameterize the first statement, then the next, and so on... then 'chain' those together... as the output. 
	--		well, make this an option/switch... (i.e., an input parameter).


	-- again, looking for BASIC (non edge-case) confirmations here: 
	IF @InputStatement NOT LIKE N'%WHERE%' 
		SET @noParams = 1; 

	
	IF (@InputStatement LIKE N'Proc [Database%') OR (@InputStatement LIKE 'EXEC%') 
		SET @isExec = 1; 


	-- damn... this might be one of the smartest things i've done in a while... (here's hoping that it WORKS)... 
	IF COALESCE(@multiStatement, @noParams, @isExec, 0) = 0 BEGIN 
		
		DECLARE @errorMessage nvarchar(MAX);

		BEGIN TRY 
			SET @NormalizedOutput = NULL; 
			SET @ParametersOutput = NULL;
			SET @ErrorInfo = NULL;

			EXEC sp_get_query_template
				@InputStatement, 
				@NormalizedOutput OUTPUT, 
				@ParametersOutput OUTPUT;

		END TRY 
		BEGIN CATCH 
			
			SELECT @errorMessage = N'Error Number: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N'. Message: ' + ERROR_MESSAGE();
			SELECT @NormalizedOutput = @InputStatement, @ErrorInfo = @errorMessage;
		END CATCH

	END; 

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.extract_statement','P') IS NOT NULL
	DROP PROC dbo.extract_statement;
GO

CREATE PROC dbo.extract_statement
	@TargetDatabase					sysname, 
	@ObjectID						int, 
	@OffsetStart					int, 
	@OffsetEnd						int, 
	@Statement						nvarchar(MAX)		OUTPUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @sql nvarchar(2000) = N'
SELECT 
	@Statement = SUBSTRING([definition], (@offsetStart / 2) + 1, (CASE WHEN @offsetEnd < 1 THEN DATALENGTH([definition]) ELSE (@offsetEnd - @offsetStart)/2 END) + 1) 
FROM 
	{TargetDatabase}.sys.[sql_modules] 
WHERE 
	[object_id] = @ObjectID; ';

	SET @sql = REPLACE(@sql, N'{TargetDatabase}', @TargetDatabase);

	EXEC sys.[sp_executesql] 
		@sql, 
		N'@ObjectID int, @OffsetStart int, @OffsetEnd int, @Statement nvarchar(MAX) OUTPUT', 
		@ObjectID = @ObjectID, 
		@OffsetStart = @OffsetStart, 
		@OffsetEnd = @OffsetEnd, 
		@Statement = @Statement OUTPUT; 

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.extract_waitresource','P') IS NOT NULL
	DROP PROC dbo.extract_waitresource;
GO

CREATE PROC dbo.extract_waitresource
	@WaitResource				sysname, 
	@DatabaseMappings			nvarchar(MAX)			= NULL,
	@Output						nvarchar(2000)			= NULL    OUTPUT
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF NULLIF(@WaitResource, N'') IS NULL BEGIN 
		SET @Output = N'';
		RETURN 0;
	END;
		
	IF @WaitResource = N'0:0:0' BEGIN 
		SET @Output = N'[0:0:0] - UNIDENTIFIED_RESOURCE';  -- Paul Randal Identified this on twitter on 2019-08-06: https://twitter.com/PaulRandal/status/1158810119670358016
                                                           -- specifically: when the last wait type is PAGELATCH, the last resource isn't preserved - so we get 0:0:0 - been that way since 2005. 
                                                           --      and, I honestly wonder if that could/would be the case with OTHER scenarios? 
		RETURN 0;
	END;

    IF @WaitResource LIKE N'ACCESS_METHODS_DATASET_PARENT%' BEGIN 
        SET @Output = N'[SYSTEM].[PARALLEL_SCAN (CXPACKET)].[' + @WaitResource + N']';
        RETURN 0;
    END;

	IF @WaitResource LIKE '%COMPILE]' BEGIN -- just change the formatting so that it matches 'rules processing' details below... 
		SET @WaitResource = N'COMPILE: ' + REPLACE(REPLACE(@WaitResource, N' [COMPILE]', N''), N'OBJECT: ', N'');
	END;

	IF @WaitResource LIKE '%[0-9]%:%[0-9]%:%[0-9]%' AND @WaitResource NOT LIKE N'%: %' BEGIN -- this is a 'shorthand' PAGE identifier: 
		SET @WaitResource = N'XPAGE: ' + @WaitResource;
	END;

	IF @WaitResource LIKE N'KEY: %' BEGIN 
		SET @WaitResource = REPLACE(REPLACE(@WaitResource, N' (', N':'), N')', N'');  -- extract to 'explicit' @part4... 
	END;

	IF @WaitResource LIKE N'RID: %' BEGIN 
		SET @WaitResource = REPLACE(@WaitResource, N'RID: ', N'ROW: '); -- standardize... 
	END;

	IF @WaitResource LIKE N'TABLE: %' BEGIN
		SET @WaitResource = REPLACE(@WaitResource, N'TABLE: ', N'TAB: '); -- standardize formatting... 
	END;

	CREATE TABLE #ExtractionMapping ( 
		row_id int NOT NULL, 
		[database_id] int NOT NULL,         -- source_id (i.e., from production)
        [metadata_name] sysname NOT NULL,   -- db for which OBJECT_ID(), PAGE/HOBT/KEY/etc. lookups should be executed against - LOCALLY
        [mapped_name] sysname NULL          -- friendly-name (i.e., if prod_db_name = widgets, and local meta-data-db = widgets_copyFromProd, friendly_name makes more sense as 'widgets' but will DEFAULT to widgets_copyFromProd (if friendly is NOT specified)
	); 

	IF NULLIF(@DatabaseMappings, N'') IS NOT NULL BEGIN
		INSERT INTO #ExtractionMapping ([row_id], [database_id], [metadata_name], [mapped_name])
		EXEC dbo.[shred_string] 
		    @Input = @DatabaseMappings, 
		    @RowDelimiter = N',',
		    @ColumnDelimiter = N'|'
	END;

	SET @WaitResource = REPLACE(@WaitResource, N' ', N'');
	DECLARE @parts table (row_id int, part nvarchar(200));

	INSERT INTO @parts (row_id, part) 
	SELECT [row_id], [result] FROM dbo.[split_string](@WaitResource, N':', 1);

	BEGIN TRY 
		DECLARE @waittype sysname, @part2 bigint, @part3 bigint, @part4 sysname, @part5 sysname;
		SELECT @waittype = part FROM @parts WHERE [row_id] = 1; 
		SELECT @part2 = CAST(part AS bigint) FROM @parts WHERE [row_id] = 2; 
		SELECT @part3 = CAST(part AS bigint) FROM @parts WHERE [row_id] = 3; 
		SELECT @part4 = part FROM @parts WHERE [row_id] = 4; 
		SELECT @part5 = part FROM @parts WHERE [row_id] = 5; 
	
		DECLARE @lookupSQL nvarchar(2000);
		DECLARE @objectName sysname;
		DECLARE @indexName sysname;
		DECLARE @objectID int;
		DECLARE @indexID int;
		DECLARE @error bit = 0;

		DECLARE @logicalDatabaseName sysname; 
		DECLARE @metaDataDatabaseName sysname;

		-- NOTE: _MAY_ need to override this in some resource types - but, it's used in SO many types (via @part2) that 'solving' for it here makes tons of sense). 
		SET @metaDataDatabaseName = ISNULL((SELECT [metadata_name] FROM [#ExtractionMapping] WHERE [database_id] = @part2), DB_NAME(@part2));
        SET @logicalDatabaseName = ISNULL((SELECT ISNULL([mapped_name], [metadata_name]) FROM [#ExtractionMapping] WHERE [database_id] = @part2), DB_NAME(@part2));

		IF @waittype = N'DATABASE' BEGIN
			IF @part3 = 0 
				SELECT @Output = QUOTENAME(@logicalDatabaseName) + N'- SCHEMA_LOCK';
			ELSE 
				SELECT @Output = QUOTENAME(@logicalDatabaseName) + N' - DATABASE_LOCK';

			RETURN 0;
		END; 

		IF @waittype = N'FILE' BEGIN 
            -- MKC: lookups are pointless -.. 
			--SET @lookupSQL = N'SELECT @objectName = [physical_name] FROM [Xcelerator].sys.[database_files] WHERE FILE_ID = ' + CAST(@part3 AS sysname) + N';';
			--EXEC [sys].[sp_executesql]
			--	@stmt = @lookupSQL, 
			--	@params = N'@objectName sysname OUTPUT', 
			--	@objectName = @objectName OUTPUT;

			--SELECT @Output = QUOTENAME(@logicalDatabaseName) + N' - FILE_LOCK (' + ISNULL(@objectName, N'FILE_ID: ' + CAST(@part3 AS sysname)) + N')';
            SELECT @Output = QUOTENAME(@logicalDatabaseName) + N' - FILE_LOCK (Data or Log file - Engine does not specify)';
			RETURN 0;
		END;

		-- TODO: test/verify output AGAINST real 'capture' info.... 
		IF @waittype = N'TAB' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects WHERE object_id = ' + CAST(@part3 AS sysname) + N';';	

			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;

			SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N' - TABLE_LOCK';
			RETURN 0;
		END;

		IF @waittype = N'KEY' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = o.[name], @indexName = i.[name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.partitions p INNER JOIN [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects o ON p.[object_id] = o.[object_id] INNER JOIN [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.indexes i ON [o].[object_id] = [i].[object_id] AND p.[index_id] = [i].[index_id] WHERE p.hobt_id = ' + CAST(@part3 AS sysname) + N';';

			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT, @indexName sysname OUTPUT', 
				@objectName = @objectName OUTPUT, 
				@indexName = @indexName OUTPUT;

			SET @Output = QUOTENAME(ISNULL(@metaDataDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N'.' + QUOTENAME(ISNULL(@indexName, 'INDEX_ID: -1')) + N'.[RANGE: (' + ISNULL(@part4, N'') + N')] - KEY_LOCK';
			RETURN 0;
		END;

		IF @waittype = N'OBJECT' OR @waittype = N'COMPILE' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects WHERE object_id = ' + CAST(@part3 AS sysname) + N';';	
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;		

			SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'OBJECT_ID: ' + CAST(@part3 AS sysname))) + N' - ' + @waittype +N'_LOCK';
			RETURN 0;
		END;

		IF @waittype IN(N'PAGE', N'XPAGE', N'EXTENT', N'ROW') BEGIN 

			CREATE TABLE #results (ParentObject varchar(255), [Object] varchar(255), Field varchar(255), [VALUE] varchar(255));
			SET @lookupSQL = N'DBCC PAGE('''+ @metaDataDatabaseName + ''', ' + CAST(@part3 AS sysname) + ', ' + @part4 + ', 1) WITH TABLERESULTS;'

			INSERT INTO #results ([ParentObject], [Object], [Field], [VALUE])
			EXECUTE (@lookupSQL);
		
			SELECT @objectID = CAST([VALUE] AS int) FROM [#results] WHERE [ParentObject] = N'PAGE HEADER:' AND [Field] = N'Metadata: ObjectId';
			SELECT @indexID = CAST([VALUE] AS int) FROM [#results] WHERE [ParentObject] = N'PAGE HEADER:' AND [Field] = N'Metadata: IndexId';
		
			SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects WHERE object_id = ' + CAST(@objectID AS sysname) + N';';	
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;

			SET @lookupSQL = N'SELECT @indexName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.indexes WHERE object_id = ' + CAST(@objectID AS sysname) + N' AND index_id = ' + CAST(@indexID AS sysname) + N';';	
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@indexName sysname OUTPUT', 
				@indexName = @indexName OUTPUT;

			IF @waittype = N'ROW' 
				SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N'.' + QUOTENAME(ISNULL(@indexName, 'INDEX_ID: ' + CAST(@indexID AS sysname))) + N'.[PAGE_ID: ' + ISNULL(@part4, N'')  + N'].[SLOT: ' + ISNULL(@part5, N'') + N'] - ' + @waittype + N'_LOCK';
			ELSE
				SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N'.' + QUOTENAME(ISNULL(@indexName, 'INDEX_ID: ' + CAST(@indexID AS sysname))) + N' - ' + @waittype + N'_LOCK';
			RETURN 0;
		END;
	END TRY 
	BEGIN CATCH 
		PRINT 'PROCESSING_EXCEPTION: Line: ' + CAST(ERROR_LINE() AS sysname) + N' - Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' -> ' + ERROR_MESSAGE();
		SET @error = 1;
	END CATCH

	-- IF we're still here - then either there was an exception 'shredding' the resource identifier - or we're in an unknown resource-type. (Either outcome, though, is that we're dealing with an unknown/non-implemented type.)
	SELECT @waittype [wait_type], @part2 [part2], @part3 [part3], @part4 [part4], @part5 [part5];

	IF @error = 1 
		SET @Output = QUOTENAME(@WaitResource) + N' - EXCEPTION_PROCESSING_WAIT_RESOURCE';
	ELSE
		SET @Output = QUOTENAME(@WaitResource) + N' - S4_UNKNOWN_WAIT_RESOURCE';

	RETURN -1;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.is_xml_empty','FN') IS NOT NULL
	DROP FUNCTION dbo.[is_xml_empty];
GO

CREATE FUNCTION dbo.[is_xml_empty] (@input xml)
RETURNS bit
	--WITH RETURNS NULL ON NULL INPUT  -- note, this WORKS ... but... uh, busts functionality cuz we don't want NULL if empty, we want 1... 
AS
    
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
    
    BEGIN; 
    	
    	DECLARE @output bit = 0;

        IF @input IS NULL   
            SET @output = 1;
    	
        IF DATALENGTH(@input) <= 5
    	    SET @output = 1;
    	
    	RETURN @output;
    END;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
--- SQL Server Agent Jobs
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_running_jobs','P') IS NOT NULL
	DROP PROC dbo.[list_running_jobs];
GO


CREATE PROC dbo.[list_running_jobs]
	@StartTime							datetime				= NULL, 
	@EndTime							datetime				= NULL, 
	@ExcludedJobs						nvarchar(MAX)			= NULL, 
	@PreFilterPaddingWeeks				int						= 1,							-- if @StartTime/@EndTime are specified, msdb.dbo.sysjobhistory stores start_dates as ints - so this is used to help pre-filter those results by @StartTime - N weeks and @EndTime + N weeks ... 
    @SerializedOutput					xml						= N'<default/>'			OUTPUT			-- when set to any non-null value (i.e., '') this will be populated with output - rather than having the output projected through the 'bottom' of the sproc (so that we can consume these details from other sprocs/etc.)
AS
	
	RAISERROR('Sorry. The S4 stored procedure dbo.list_running_jobs is NOT supported on SQL Server 2008/2008R2 instances.', 16, 1);
	RETURN -100;
GO

DECLARE @list_running_jobs nvarchar(MAX) = N'ALTER PROC dbo.[list_running_jobs]
	@StartTime							datetime				= NULL, 
	@EndTime							datetime				= NULL, 
	@ExcludedJobs						nvarchar(MAX)			= NULL, 
	@PreFilterPaddingWeeks				int						= 1,							-- if @StartTime/@EndTime are specified, msdb.dbo.sysjobhistory stores start_dates as ints - so this is used to help pre-filter those results by @StartTime - N weeks and @EndTime + N weeks ... 
    @SerializedOutput					xml						= N''<default/>''			OUTPUT			-- when set to any non-null value (i.e., '''') this will be populated with output - rather than having the output projected through the ''bottom'' of the sproc (so that we can consume these details from other sprocs/etc.)
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -----------------------------------------------------------------------------
    -- Validate Inputs: 

	IF (@StartTime IS NOT NULL AND @EndTime IS NULL) OR (@EndTime IS NOT NULL AND @StartTime IS NULL) BEGIN
        RAISERROR(''@StartTime and @EndTime must both either be specified - or both must be NULL (indicating that you''''d like to see jobs running right now).'', 16, 1);
        RETURN -1;
    END;

	IF @StartTime IS NOT NULL AND @EndTime < @StartTime BEGIN
        RAISERROR(''@Endtime must be greater than (or equal to) @StartTime.'', 16, 1);
        RETURN -2;		
	END;

	-----------------------------------------------------------------------------
	CREATE TABLE #RunningJobs (
		row_id int IDENTITY(1,1) NOT NULL, 
		job_name sysname NOT NULL, 
		job_id uniqueidentifier NOT NULL, 
		step_id int NOT NULL,
		step_name sysname NOT NULL, 
		start_time datetime NOT NULL, 
		end_time datetime NULL, 
		completed bit NULL
	);

    -----------------------------------------------------------------------------
    -- If there''s no filter, then we want jobs that are currently running (i.e., those who have started, but their stop time is NULL: 
	IF (@StartTime IS NULL) OR (@EndTime >= GETDATE()) BEGIN
		INSERT INTO [#RunningJobs] ( [job_name], [job_id], [step_name], [step_id], [start_time], [end_time], [completed])
		SELECT 
			j.[name] [job_name], 
			ja.job_id,
			js.[step_name] [step_name],
			js.[step_id],
			ja.[start_execution_date] [start_time], 
			NULL [end_time], 
			0 [completed]
		FROM 
			msdb.dbo.[sysjobactivity] ja 
			LEFT OUTER JOIN msdb.dbo.[sysjobhistory] jh ON [ja].[job_history_id] = [jh].[instance_id]
			INNER JOIN msdb.dbo.[sysjobs] j ON [ja].[job_id] = [j].[job_id] 
			INNER JOIN msdb.dbo.[sysjobsteps] js ON [ja].[job_id] = [js].[job_id] AND ISNULL([ja].[last_executed_step_id], 0) + 1 = [js].[step_id]
		WHERE 
			[ja].[session_id] = (SELECT TOP (1) [session_id] FROM msdb.dbo.[syssessions] ORDER BY [agent_start_date] DESC) 
			AND [ja].[start_execution_date] IS NOT NULL 
			AND [ja].[stop_execution_date] IS NULL;
	END;
	
	IF @StartTime IS NOT NULL BEGIN
		WITH starts AS ( 
			SELECT 
				instance_id,
				job_id, 
				step_id,
				step_name, 
				CAST((LEFT(run_date, 4) + ''-'' + SUBSTRING(CAST(run_date AS char(8)),5,2) + ''-'' + RIGHT(run_date,2) + '' '' + LEFT(REPLICATE(''0'', 6 - LEN(run_time)) + CAST(run_time AS varchar(6)), 2) + '':'' + SUBSTRING(REPLICATE(''0'', 6 - LEN(run_time)) + CAST(run_time AS varchar(6)), 3, 2) + '':'' + RIGHT(REPLICATE(''0'', 6 - LEN(run_time)) + CAST(run_time AS varchar(6)), 2)) AS datetime) AS [start_time],
				RIGHT((REPLICATE(N''0'', 6) + CAST([run_duration] AS sysname)), 6) [duration]
			FROM 
				msdb.dbo.[sysjobhistory] 
			WHERE 
				-- rather than a scan of the entire table - restrict things to 1 week before the specified start date and 1 week after the specified end date... 
				[run_date] >= CAST(CONVERT(char(8), DATEADD(WEEK, 0 - @PreFilterPaddingWeeks, @StartTime), 112) AS int)
				AND 
				[run_date] <= CAST(CONVERT(char(8), DATEADD(WEEK, @PreFilterPaddingWeeks, @EndTime), 112) AS int)
		), 
		ends AS ( 
			SELECT 
				instance_id,
				job_id, 
				step_id,
				step_name, 
				[start_time], 
				CAST((LEFT([duration], 2)) AS int) * 3600 + CAST((SUBSTRING([duration], 3, 2)) AS int) * 60 + CAST((RIGHT([duration], 2)) AS int) [total_seconds]
			FROM 
				starts
		),
		normalized AS ( 
			SELECT 
				instance_id,
				job_id, 
				step_id,
				step_name, 
				start_time, 
				DATEADD(SECOND, CASE WHEN total_seconds = 0 THEN 1 ELSE [ends].[total_seconds] END, start_time) end_time, 
				LEAD(step_id) OVER (PARTITION BY job_id ORDER BY instance_id) [next_job_step_id]  -- note, this isn''t 2008 compat... (and ... i don''t think i care... )
			FROM 
				ends
		)

		INSERT INTO [#RunningJobs] ( [job_name], [job_id], [step_name], [step_id], [start_time], [end_time], [completed])
		SELECT 
			[j].[name] [job_name],
			[n].[job_id], 
			ISNULL([js].[step_name], [n].[step_name]) [step_name],
			[n].[step_id],
			[n].[start_time],
			[n].[end_time], 
			CASE WHEN [n].[next_job_step_id] = 0 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END [completed]
		FROM 
			normalized n
			LEFT OUTER JOIN msdb.dbo.[sysjobs] j ON [n].[job_id] = [j].[job_id] -- allow this to be NULL - i.e., if we''re looking for a job that ran this morning at 2AM, it''s better to see that SOMETHING ran other than that a Job that existed (and ran) - but has since been deleted - ''looks'' like it didn''t run.
			LEFT OUTER JOIN msdb.dbo.[sysjobsteps] js ON [n].[job_id] = [js].[job_id] AND n.[step_id] = js.[step_id]
		WHERE 
			n.[step_id] <> 0 AND (
				-- jobs that start/stop during specified time window... 
				(n.[start_time] >= @StartTime AND n.[end_time] <= @EndTime)

				-- jobs that were running when the specified window STARTS (and which may or may not end during out time window - but the jobs were ALREADY running). 
				OR (n.[start_time] < @StartTime AND n.[end_time] > @StartTime)

				-- jobs that get started during our time window (and which may/may-not stop during our window - because, either way, they were running...)
				OR (n.[start_time] > @StartTime AND @EndTime > @EndTime)
			)
	END;

	-- Exclude any jobs specified: 
	DELETE FROM [#RunningJobs] WHERE [job_name] IN (SELECT [result] FROM dbo.[split_string](@ExcludedJobs, N'','', 1));
    
	-- TODO: are there any expansions/details we want to join from the Jobs themselves at this point? (or any other history info?) 
	
	-----------------------------------------------------------------------------
    -- Send output as XML if requested:
	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY...  

		SELECT @SerializedOutput = (
			SELECT 
				[job_name],
				[job_id],
				[step_name],
				[step_id],
				[start_time],
				CASE WHEN [completed] = 1 THEN [end_time] ELSE NULL END [end_time], 
				CASE WHEN [completed] = 1 THEN ''COMPLETED'' ELSE ''INCOMPLETE'' END [job_status]
			FROM 
				[#RunningJobs] 
			ORDER BY 
				[start_time]
			FOR XML PATH(''job''), ROOT(''jobs'')
		);

		RETURN 0;
	END;

	-----------------------------------------------------------------------------
	-- otherwise, project:
	SELECT 
		[job_name],
        [job_id],
        [step_name],
		[step_id],
        [start_time],
		CASE WHEN [completed] = 1 THEN [end_time] ELSE NULL END [end_time], 
		CASE WHEN [completed] = 1 THEN ''COMPLETED'' ELSE ''INCOMPLETE'' END [job_status]
	FROM 
		[#RunningJobs]
	ORDER BY 
		[start_time];

	RETURN 0;

 ';

IF (SELECT dbo.get_engine_version())> 10.5 
	EXEC sp_executesql @list_running_jobs;

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.is_job_running','FN') IS NOT NULL
	DROP FUNCTION dbo.is_job_running;
GO

CREATE FUNCTION dbo.is_job_running (@JobName sysname) 
RETURNS bit 
	WITH RETURNS NULL ON NULL INPUT
AS 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN;
		
		DECLARE @output bit = 0;

		IF EXISTS (
			SELECT 
				NULL
			FROM 
				msdb.dbo.sysjobs j 
				INNER JOIN msdb.dbo.sysjobactivity ja ON [j].[job_id] = [ja].[job_id] 
			WHERE 
				ja.[session_id] = (SELECT TOP (1) session_id FROM msdb.dbo.[syssessions] ORDER BY [agent_start_date] DESC)
				AND [ja].[start_execution_date] IS NOT NULL 
				AND [ja].[stop_execution_date] IS NULL -- i.e., still running
				AND j.[name] = @JobName
		)  
		  BEGIN 
			SET @output = 1;
		END;

		RETURN @output;

	END; 
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.translate_program_name_to_agent_job','P') IS NOT NULL
	DROP PROC dbo.[translate_program_name_to_agent_job];
GO

CREATE PROC dbo.[translate_program_name_to_agent_job]
    @ProgramName                    sysname, 
    @IncludeJobStepInOutput         bit         = 0, 
    @JobName                        sysname     = N''       OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    DECLARE @jobID uniqueidentifier;

    BEGIN TRY 

        DECLARE @jobIDString sysname = SUBSTRING(@ProgramName, CHARINDEX(N'Job 0x', @ProgramName) + 4, 34);
        DECLARE @currentStepString sysname = REPLACE(REPLACE(@ProgramName, LEFT(@ProgramName, CHARINDEX(N': Step', @ProgramName) + 6), N''), N')', N''); 

        SET @jobID = CAST((CONVERT(binary(16), @jobIDString, 1)) AS uniqueidentifier);
    
    END TRY
    BEGIN CATCH
        IF NULLIF(@JobName, N'') IS NOT NULL
            RAISERROR(N'Error converting Program Name: ''%s'' to SQL Server Agent JobID (Guid).', 16, 1, @ProgramName);

        RETURN -1;
    END CATCH

    DECLARE @output sysname = (SELECT [name] FROM msdb..sysjobs WHERE [job_id] = @jobID);

    IF @IncludeJobStepInOutput = 1
        SET @output = @output + N' (Step ' + @currentStepString + N')';

    IF @JobName IS NULL
        SET @JobName = @output; 
    ELSE 
        SELECT @output [job_name];

    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.get_last_job_completion','P') IS NOT NULL
	DROP PROC dbo.[get_last_job_completion];
GO

CREATE PROC dbo.[get_last_job_completion]
    @JobName                                            sysname                 = NULL, 
    @JobID                                              uniqueidentifier        = NULL, 
    @ReportJobStartOrEndTime                            sysname                 = N'START',                                 -- Report Last Completed Job START or END time.. 
    @ExcludeFailedOutcomes                              bit                     = 0,                                        -- when true, only reports on last-SUCCESSFUL execution.
    @LastTime                                           datetime                = '1900-01-01 00:00:00.000' OUTPUT
AS
    SET NOCOUNT ON; 
    
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    IF NULLIF(@JobName, N'') IS NULL AND @JobID IS NULL BEGIN 
        RAISERROR(N'Please specify either the @JobName or @JobID parameter to execute.', 16, 1);
        RETURN -1;
    END;

    IF UPPER(@ReportJobStartOrEndTime) NOT IN (N'START', N'END') BEGIN 
        RAISERROR('Valid values for @ReportJobStartOrEndTime are { START | END } only.', 16,1);
        RETURN -2;
    END;

    IF @JobID IS NULL BEGIN 
        SELECT @JobID = job_id FROM msdb..sysjobs WHERE [name] = @JobName;
    END;

    IF @JobName IS NULL BEGIN 
        RAISERROR(N'Invalid (non-existing) @JobID or @JobName provided.', 16, 1);
        RETURN -5;
    END;

    DECLARE @startTime datetime;
    DECLARE @duration sysname;
    
    SELECT 
        @startTime = msdb.dbo.agent_datetime(run_date, run_time), 
        @duration = RIGHT((REPLICATE(N'0', 6) + CAST([run_duration] AS sysname)), 6)
    FROM [msdb]..[sysjobhistory] 
    WHERE 
        [instance_id] = (

            SELECT MAX(instance_id) 
            FROM msdb..[sysjobhistory] 
            WHERE 
                [job_id] = @JobID 
                AND (
                        (@ExcludeFailedOutcomes = 0) 
                        OR 
                        (@ExcludeFailedOutcomes = 1 AND [run_status] = 1)
                    )
        );

    IF UPPER(@ReportJobStartOrEndTime) = N'START' BEGIN 
        IF @LastTime IS NOT NULL  -- i.e., parameter was NOT supplied because it's defaulted to 1900... 
            SELECT @startTime [start_time_of_last_successful_job_execution];
        ELSE 
            SET @LastTime = @startTime;

        RETURN 0;
    END; 
    
    -- otherwise, report on the end-time: 
    DECLARE @endTime datetime = DATEADD(SECOND, CAST((LEFT(@duration, 2)) AS int) * 3600 + CAST((SUBSTRING(@duration, 3, 2)) AS int) * 60 + CAST((RIGHT(@duration, 2)) AS int), @startTime); 

    IF @LastTime IS NOT NULL
        SELECT @endTime [completion_time_of_last_job_execution];
    ELSE 
        SET @LastTime = @endTime;

    RETURN 0;
GO    


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.get_last_job_completion_by_session_id','P') IS NOT NULL
	DROP PROC dbo.[get_last_job_completion_by_session_id];
GO

CREATE PROC dbo.[get_last_job_completion_by_session_id]
    @SessionID              int,
    @ExcludeFailures        bit                             = 1, 
    @LastTime               datetime                        = '1900-01-01 00:00:00.000' OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    DECLARE @success int = -1;
    DECLARE @jobName sysname; 
    DECLARE @lastExecution datetime;
    DECLARE @output datetime;

    DECLARE @programName sysname; 
    SELECT @programName = [program_name] FROM sys.[dm_exec_sessions] WHERE [session_id] = @SessionID;

    EXEC @success = dbo.translate_program_name_to_agent_job 
        @ProgramName = @programName, 
        @JobName = @jobName OUTPUT;

    IF @success = 0 BEGIN 
        EXEC @success = dbo.[get_last_job_completion]
            @JobName = @jobName, 
            @ReportJobStartOrEndTime = N'START', 
            @ExcludeFailedOutcomes = 1, 
            @LastTime = @lastExecution OUTPUT;

        IF @success = 0 
            SET @output = @lastExecution;
    END; 

    IF @output IS NULL 
        RETURN -1; 

    IF @LastTime IS NOT NULL 
        SELECT @output [completion_time_of_last_job_execution];
    ELSE 
        SET @LastTime = @output;

    RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- High-Availability (Setup, Monitoring, and Failover):
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.server_trace_flags','U') IS NOT NULL
	DROP TABLE dbo.server_trace_flags;
GO

CREATE TABLE dbo.server_trace_flags (
	[trace_flag] [int] NOT NULL,
	[status] [bit] NOT NULL,
	[global] [bit] NOT NULL,
	[session] [bit] NOT NULL,
	CONSTRAINT [PK_server_traceflags] PRIMARY KEY CLUSTERED ([trace_flag] ASC)
) 
ON [PRIMARY];

GO


-----------------------------------
-- v6.6 Changes to PARTNER (if present):
IF EXISTS (SELECT NULL FROM sys.servers WHERE UPPER([name]) = N'PARTNER' AND [is_linked] = 1) BEGIN 
	IF NOT EXISTS (SELECT NULL FROM sys.[sysservers] WHERE UPPER([srvname]) = N'PARTNER' AND [rpc] = 1) BEGIN
        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc', 
	        @optvalue = N'true';		

		PRINT N'Enabled RPC on PARTNER (for v6.6+ compatibility).';
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.[sysservers] WHERE UPPER([srvname]) = N'PARTNER' AND [rpcout] = 1) BEGIN
        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc out', 
	        @optvalue = N'true';
			
		PRINT N'Enabled RPC_OUT on PARTNER (for v6.6+ compatibility).';
	END;
END;

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.list_synchronizing_databases','TF') IS NOT NULL
	DROP FUNCTION dbo.list_synchronizing_databases;
GO


CREATE FUNCTION dbo.list_synchronizing_databases(
	@IgnoredDatabases			nvarchar(MAX)		= NULL, 
	@ExcludeSecondaries			bit					= 0
)
RETURNS @synchronizingDatabases table ( 
	server_name sysname, 
	sync_type sysname,
	[database_name] sysname, 
	[role] sysname
) 
AS 
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN;

		DECLARE @localServerName sysname = @@SERVERNAME;

		-- Mirrored DBs:
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		SELECT @localServerName [server_name], N'MIRRORED' sync_type, d.[name] [database_name], m.[mirroring_role_desc] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;
		
		IF @ExcludeSecondaries = 1 BEGIN 
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'AG' AND [role] = N'SECONDARY';
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'MIRRORED' AND [role] = N'MIRROR';
		END;

		IF NULLIF(@IgnoredDatabases, N'') IS NOT NULL BEGIN
			DELETE FROM @synchronizingDatabases WHERE [database_name] IN (SELECT [result] FROM dbo.[split_string](@IgnoredDatabases, N',', 1));
		END;

		RETURN;
	END;
GO


DECLARE @list_synchronizing_databases nvarchar(MAX) = N'
ALTER FUNCTION dbo.list_synchronizing_databases(
	@IgnoredDatabases			nvarchar(MAX)		= NULL, 
	@ExcludeSecondaries			bit					= 0
)
RETURNS @synchronizingDatabases table ( 
	server_name sysname, 
	sync_type sysname,
	[database_name] sysname, 
	[role] sysname
) 
AS
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	 
	BEGIN;

		DECLARE @localServerName sysname = @@SERVERNAME;

		-- Mirrored DBs:
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		SELECT @localServerName [server_name], N''MIRRORED'' sync_type, d.[name] [database_name], m.[mirroring_role_desc] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;

		-- AG''d DBs (2012 + only):
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		SELECT @localServerName [server_name], N''AG'' [sync_type], d.[name] [database_name], hars.role_desc FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id;

		IF @ExcludeSecondaries = 1 BEGIN 
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N''AG'' AND [role] = N''SECONDARY'';
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N''MIRRORED'' AND [role] = N''MIRROR'';
		END;

		IF NULLIF(@IgnoredDatabases, N'''') IS NOT NULL BEGIN
			DELETE FROM @synchronizingDatabases WHERE [database_name] IN (SELECT [result] FROM dbo.[split_string](@IgnoredDatabases, N'','', 1));
		END;

		RETURN;
	END;

 ';

IF (SELECT dbo.get_engine_version())> 10.5  
	EXEC sp_executesql @list_synchronizing_databases;

-----------------------------------
USE [admindb];
GO 

IF OBJECT_ID('dbo.is_primary_server','FN') IS NOT NULL
	DROP FUNCTION dbo.is_primary_server;
GO

CREATE FUNCTION dbo.is_primary_server()
RETURNS bit
AS 
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN
		DECLARE @output bit = 0;

		DECLARE @roleOfAlphabeticallyFirstSynchronizingDatabase sysname; 

		SELECT @roleOfAlphabeticallyFirstSynchronizingDatabase = (
			SELECT TOP (1)
				[role]
			FROM 
				dbo.[list_synchronizing_databases](NULL, 1)
			ORDER BY 
				[database_name]
		);

		IF @roleOfAlphabeticallyFirstSynchronizingDatabase IN (N'PRIMARY', N'PRINCIPAL')
			SET @output = 1;
			
		RETURN @output;
	END;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.is_primary_database','FN') IS NOT NULL
	DROP FUNCTION dbo.is_primary_database;
GO


CREATE FUNCTION dbo.is_primary_database(@DatabaseName sysname)
RETURNS bit
AS
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN 
		DECLARE @description sysname;
				
		-- Check for Mirrored Status First: 
		SELECT 
			@description = mirroring_role_desc
		FROM 
			sys.database_mirroring 
		WHERE
			database_id = DB_ID(@DatabaseName);
	
		IF @description = 'PRINCIPAL'
			RETURN 1;

		-- if no matches, return 0
		RETURN 0;
	END;
GO


DECLARE @is_primary_database nvarchar(MAX) = N'
ALTER FUNCTION dbo.is_primary_database(@DatabaseName sysname)
RETURNS bit
AS
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	BEGIN 
		DECLARE @description sysname;
				
		-- Check for Mirrored Status First: 
		SELECT 
			@description = mirroring_role_desc
		FROM 
			sys.database_mirroring 
		WHERE
			database_id = DB_ID(@DatabaseName);
	
		IF @description = ''PRINCIPAL''
			RETURN 1;

		-- Check for AG''''d state:
		SELECT 
			@description = 	hars.role_desc
		FROM 
			sys.databases d
			INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
		WHERE 
			d.database_id = DB_ID(@DatabaseName);
	
		IF @description = ''PRIMARY''
			RETURN 1;
	
		-- if no matches, return 0
		RETURN 0;
	END;

 ';

IF (SELECT dbo.get_engine_version())> 10.5  
	EXEC sp_executesql @is_primary_database;

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.compare_jobs','P') IS NOT NULL
	DROP PROC dbo.compare_jobs;
GO

CREATE PROC dbo.compare_jobs 
	@TargetJobName			sysname = NULL, 
	@IgnoredJobs			nvarchar(MAX) = NULL,			-- technically, should throw an error if this is specified AND @TargetJobName is ALSO specified, but... instead, will just ignore '@ignored' if a specific job is specified. 
	@IgnoreEnabledState		bit = 0
AS
	SET NOCOUNT ON; 
	
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	IF NULLIF(@TargetJobName,N'') IS NOT NULL BEGIN -- the request is for DETAILS about a specific job. 


		-- Make sure Job exists on Local and Remote: 
		CREATE TABLE #LocalJob (
			job_id uniqueidentifier, 
			[name] sysname
		);

		CREATE TABLE #RemoteJob (
			job_id uniqueidentifier, 
			[name] sysname
		);

		INSERT INTO #LocalJob (job_id, [name])
		SELECT 
			sj.job_id, 
			sj.[name]
		FROM 
			msdb.dbo.sysjobs sj
		WHERE
			sj.[name] = @TargetJobName;

		INSERT INTO #RemoteJob (job_id, [name])
		EXEC master.sys.sp_executesql N'SELECT 
			sj.job_id, 
			sj.[name]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
		WHERE
			sj.[name] = @TargetJobName;', N'@TargetJobName sysname', @TargetJobName = @TargetJobName;

		IF NOT EXISTS (SELECT NULL FROM #LocalJob lj INNER JOIN #RemoteJob rj ON rj.[name] = lj.name) BEGIN
			RAISERROR('Job specified by @TargetJobName does NOT exist on BOTH servers.', 16, 1);
			RETURN -2;
		END


		DECLARE @localJobId uniqueidentifier;
		DECLARE @remoteJobId uniqueidentifier;

		SELECT @localJobId = job_id FROM #LocalJob WHERE [name] = @TargetJobName;
		SELECT @remoteJobId = job_id FROM #RemoteJob WHERE [name] = @TargetJobName;

		DECLARE @remoteJob table (
			[server] sysname NULL,
			[name] sysname NOT NULL,
			[enabled] tinyint NOT NULL,
			[description] nvarchar(512) NULL,
			[start_step_id] int NOT NULL,
			[owner_sid] varbinary(85) NOT NULL,
			[notify_level_email] int NOT NULL,
			[operator_name] sysname NOT NULL,
			[category_name] sysname NOT NULL,
			[job_step_count] int NOT NULL
		);

		INSERT INTO @remoteJob ([server], [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		EXECUTE master.sys.sp_executesql N'SELECT 
			@remoteServerName [server],
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.name, ''local'') operator_name,
			ISNULL(sc.name, ''local'') [category_name],
			ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
			LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE 
			sj.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;


		-- Output top-level job details:
		WITH jobs AS ( 
			SELECT 
				@localServerName [server],
				sj.[name], 
				sj.[enabled], 
				sj.[description], 
				sj.start_step_id,
				sj.owner_sid, 
				sj.notify_level_email, 
				ISNULL(so.[name], 'local') operator_name,
				ISNULL(sc.[name], 'local') [category_name],
				ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
			FROM 
				msdb.dbo.sysjobs sj
				LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
				LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
			WHERE 
				sj.job_id = @localJobId

			UNION 

			SELECT 
				[server] COLLATE SQL_Latin1_General_CP1_CI_AS,
                [name] COLLATE SQL_Latin1_General_CP1_CI_AS,
                [enabled],
                [description] COLLATE SQL_Latin1_General_CP1_CI_AS,
                start_step_id,
                owner_sid,
                notify_level_email,
                operator_name COLLATE SQL_Latin1_General_CP1_CI_AS,
                category_name COLLATE SQL_Latin1_General_CP1_CI_AS,
                job_step_count
			FROM 
				@remoteJob
		)

		SELECT 
			'JOB' [type], 
			[server],
			[name],
			[enabled],
			[description],
			start_step_id,
			owner_sid,
			notify_level_email,
			operator_name,
			category_name,
			job_step_count
		FROM 
			jobs 
		ORDER BY 
			[name], [server];


		DECLARE @remoteJobSteps table (
			[step_id] int NOT NULL,
			[server] sysname NULL,
			[step_name] sysname NOT NULL,
			[subsystem] nvarchar(40) NOT NULL,
			[command] nvarchar(max) NULL,
			[on_success_action] tinyint NOT NULL,
			[on_fail_action] tinyint NOT NULL,
			[database_name] sysname NULL
		);

		INSERT INTO @remoteJobSteps ([step_id], [server], [step_name], [subsystem], [command], [on_success_action], [on_fail_action], [database_name])
		EXEC master.sys.sp_executesql N'SELECT 
			step_id, 
			@remoteServerName [server],
			step_name, 
			subsystem, 
			command, 
			on_success_action, 
			on_fail_action, 
			[database_name]
		FROM 
			PARTNER.msdb.dbo.sysjobsteps r
		WHERE 
			r.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;

		-- Job Steps: 
		WITH steps AS ( 
			SELECT 
				step_id, 
				@localServerName [server],
				step_name COLLATE Latin1_General_BIN [step_name], 
				subsystem COLLATE Latin1_General_BIN [subsystem], 
				command COLLATE Latin1_General_BIN [command], 
				on_success_action, 
				on_fail_action, 
				[database_name] COLLATE Latin1_General_BIN [database_name]
			FROM 
				msdb.dbo.sysjobsteps l
			WHERE 
				l.job_id = @localJobId

			UNION 

			SELECT 
				[step_id], 
				[server], 
				[step_name], 
				[subsystem], 
				[command], 
				[on_success_action], 
				[on_fail_action], 
				[database_name]
			FROM 
				@remoteJobSteps
		)

		SELECT 
			'JOB-STEP' [type],
			step_id, 
			[server],
			step_name, 
			subsystem, 
			command, 
			on_success_action, 
			on_fail_action, 
			[database_name]			
		FROM 
			steps
		ORDER BY 
			step_id, [server];


		DECLARE @remoteJobSchedules table (
			[server] sysname NULL,
			[name] sysname NOT NULL,
			[enabled] int NOT NULL,
			[freq_type] int NOT NULL,
			[freq_interval] int NOT NULL,
			[freq_subday_type] int NOT NULL,
			[freq_subday_interval] int NOT NULL,
			[freq_relative_interval] int NOT NULL,
			[freq_recurrence_factor] int NOT NULL,
			[active_start_date] int NOT NULL,
			[active_end_date] int NOT NULL,
			[active_start_time] int NOT NULL,
			[active_end_time] int NOT NULL
		);

		INSERT INTO @remoteJobSchedules ([server], [name], [enabled], [freq_type], [freq_interval], [freq_subday_type], [freq_subday_interval], [freq_relative_interval], [freq_recurrence_factor], [active_start_date], [active_end_date], [active_start_time], [active_end_time])
		EXEC master.sys.sp_executesql N'SELECT 
			@remoteServerName [server],
			ss.name,
			ss.[enabled], 
			ss.freq_type, 
			ss.freq_interval, 
			ss.freq_subday_type, 
			ss.freq_subday_interval, 
			ss.freq_relative_interval, 
			ss.freq_recurrence_factor, 
			ss.active_start_date, 
			ss.active_end_date,
			ss.active_start_time,
			ss.active_end_time
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE 
			sjs.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;	

		WITH schedules AS (

			SELECT 
				@localServerName [server],
				ss.[name] COLLATE Latin1_General_BIN [name],
				ss.[enabled], 
				ss.freq_type, 
				ss.freq_interval, 
				ss.freq_subday_type, 
				ss.freq_subday_interval, 
				ss.freq_relative_interval, 
				ss.freq_recurrence_factor, 
				ss.active_start_date, 
				ss.active_end_date, 
				ss.active_start_time,
				ss.active_end_time
			FROM 
				msdb.dbo.sysjobschedules sjs
				INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE 
				sjs.job_id = @localJobId

			UNION

			SELECT 
				[server],
                [name],
                [enabled],
                [freq_type],
                [freq_interval],
                [freq_subday_type],
                [freq_subday_interval],
                [freq_relative_interval],
                [freq_recurrence_factor],
                [active_start_date],
                [active_end_date],
                [active_start_time],
                [active_end_time]
			FROM 
				@remoteJobSchedules
		)

		SELECT 
			'SCHEDULE' [type],
			[name],
			[server],
			[enabled], 
			freq_type, 
			freq_interval, 
			freq_subday_type, 
			freq_subday_interval, 
			freq_relative_interval, 
			freq_recurrence_factor, 
			active_start_date, 
			active_end_date, 
			active_start_time,
			active_end_time
		FROM 
			schedules
		ORDER BY 
			[name], [server];

		-- bail, we're done. 
		RETURN 0;

	END;

	  -- If we're still here, we're looking at high-level details for all jobs (except those listed in @IgnoredJobs). 

	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredJobs, N',', 1);

	CREATE TABLE #LocalJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	CREATE TABLE #RemoteJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	-- Load Details: 
	INSERT INTO #LocalJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.name, 'local') operator_name,
		ISNULL(sc.name, 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
	WHERE
		sj.name NOT IN (SELECT name FROM #IgnoredJobs); 

	INSERT INTO #RemoteJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	EXEC master.sys.sp_executesql N'SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.name, ''local'') operator_name,
		ISNULL(sc.name, ''local'') [category_name],
		ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		PARTNER.msdb.dbo.sysjobs sj
		LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id;';

	DELETE FROM [#RemoteJobs] WHERE [name] IN (SELECT [name] FROM [#IgnoredJobs]);

	SELECT 
		N'ONLY ON ' + @localServerName [difference], * 
	FROM 
		#LocalJobs 
	WHERE
		[name] NOT IN (SELECT name FROM #RemoteJobs)
		AND [name] NOT IN (SELECT name FROM #IgnoredJobs)

	UNION SELECT 
		N'ONLY ON ' + @remoteServerName [difference], *
	FROM 
		#RemoteJobs
	WHERE 
		[name] NOT IN (SELECT name FROM #LocalJobs)
		AND [name] NOT IN (SELECT name FROM #IgnoredJobs);


	WITH names AS ( 
		SELECT
			lj.[name]
		FROM 
			#LocalJobs lj
			INNER JOIN #RemoteJobs rj ON rj.[name] = lj.[name]
		WHERE
			(@IgnoreEnabledState = 0 AND (lj.[enabled] != rj.[enabled]))
			OR lj.start_step_id != rj.start_step_id
			OR lj.owner_sid != rj.owner_sid
			OR lj.notify_level_email != rj.notify_level_email
			OR lj.operator_name != rj.operator_name
			OR lj.job_step_count != rj.job_step_count
			OR lj.category_name != rj.category_name
	), 
	core AS ( 
		SELECT 
			@localServerName [server],
            lj.[name],
            lj.[enabled],
            lj.[description],
            lj.start_step_id,
            lj.owner_sid,
            lj.notify_level_email,
            lj.operator_name,
            lj.category_name,
            lj.job_step_count
		FROM 
			#LocalJobs lj 
		WHERE 
			lj.[name] IN (SELECT [name] FROM names)

		UNION SELECT 
			@remoteServerName [server],
            rj.[name],
            rj.[enabled],
            rj.[description],
            rj.start_step_id,
            rj.owner_sid,
            rj.notify_level_email,
            rj.operator_name,
            rj.category_name,
            rj.job_step_count
		FROM 
			#RemoteJobs rj 
		WHERE 
			rj.[name] IN (SELECT [name] FROM names)
	)

	SELECT 
		[core].[server],
        [core].[name],
        [core].[enabled],
        [core].[description],
        [core].[start_step_id],
        [core].[owner_sid],
        [core].[notify_level_email],
        [core].[operator_name],
        [core].[category_name],
        [core].[job_step_count] 
	FROM
		core 
	ORDER BY 
		[name], [server];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.process_synchronization_failover','P') IS NOT NULL
	DROP PROC dbo.process_synchronization_failover;
GO

CREATE PROC dbo.process_synchronization_failover 
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname = N'Alerts', 
	@PrintOnly					bit		= 0					-- for testing (i.e., to validate things work as expected)
AS
	SET NOCOUNT ON;

	IF @PrintOnly = 0
		WAITFOR DELAY '00:00:05.00'; -- No, really, give things about 5 seconds (just to let db states 'settle in' to synchronizing/synchronized).

	DECLARE @serverName sysname = @@SERVERNAME;
	DECLARE @username sysname;
	DECLARE @report nvarchar(200);

	DECLARE @orphans table (
		UserName sysname,
		UserSID varbinary(85)
	);

	-- Start by querying current/event-ing server for list of databases and states:
	DECLARE @databases table (
		[db_name] sysname NOT NULL, 
		[sync_type] sysname NOT NULL, -- 'Mirrored' or 'AvailabilityGroup'
		[ag_name] sysname NULL, 
		[primary_server] sysname NULL, 
		[role] sysname NOT NULL, 
		[state] sysname NOT NULL, 
		[is_suspended] bit NULL,
		[is_ag_member] bit NULL,
		[owner] sysname NULL,   -- interestingly enough, this CAN be NULL in some strange cases... 
		[jobs_status] nvarchar(max) NULL,  -- whether we were able to turn jobs off or not and what they're set to (enabled/disabled)
		[users_status] nvarchar(max) NULL, 
		[other_status] nvarchar(max) NULL
	);

	-- account for Mirrored databases:
	INSERT INTO @databases ([db_name], [sync_type], [role], [state], [owner])
	SELECT 
		d.[name] [db_name],
		N'MIRRORED' [sync_type],
		dm.mirroring_role_desc [role], 
		dm.mirroring_state_desc [state], 
		sp.[name] [owner]
	FROM sys.database_mirroring dm
	INNER JOIN sys.databases d ON dm.database_id = d.database_id
	LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
	WHERE 
		dm.mirroring_guid IS NOT NULL
	ORDER BY 
		d.[name];

	-- account for AG databases:
	INSERT INTO @databases ([db_name], [sync_type], [ag_name], [primary_server], [role], [state], [is_suspended], [is_ag_member], [owner])
	SELECT
		dbcs.[database_name] [db_name],
		N'AVAILABILITY_GROUP' [sync_type],
		ag.[name] [ag_name],
		ISNULL(agstates.primary_replica, '') [primary_server],
		ISNULL(arstates.role_desc,'UNKNOWN') [role],
		ISNULL(dbrs.synchronization_state_desc, 'UNKNOWN') [state],
		ISNULL(dbrs.is_suspended, 0) [is_suspended],
		ISNULL(dbcs.is_database_joined, 0) [is_ag_member], 
		x.[owner]
	FROM
		master.sys.availability_groups AS ag
		LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states AS agstates ON ag.group_id = agstates.group_id
		INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
		INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON ar.replica_id = arstates.replica_id AND arstates.is_local = 1
		INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		LEFT OUTER JOIN master.sys.dm_hadr_database_replica_states AS dbrs ON dbcs.replica_id = dbrs.replica_id AND dbcs.group_database_id = dbrs.group_database_id
		LEFT OUTER JOIN (SELECT d.name, sp.name [owner] FROM master.sys.databases d INNER JOIN master.sys.server_principals sp ON d.owner_sid = sp.sid) x ON x.name = dbcs.database_name
	ORDER BY
		ag.name ASC,
		dbcs.database_name;

	-- process:
	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[db_name], 
		[role],
		[state]
	FROM 
		@databases
	ORDER BY 
		[db_name];

	DECLARE @currentDatabase sysname, @currentRole sysname, @currentState sysname; 
	DECLARE @enabledOrDisabled bit; 
	DECLARE @jobsStatus nvarchar(max);
	DECLARE @usersStatus nvarchar(max);
	DECLARE @otherStatus nvarchar(max);

	DECLARE @ownerChangeCommand nvarchar(max);

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		IF @currentState IN ('SYNCHRONIZED','SYNCHRONIZING') BEGIN 
			IF @currentRole IN (N'PRIMARY', N'PRINCIPAL') BEGIN 
				-----------------------------------------------------------------------------------------------
				-- specify jobs status:
				SET @enabledOrDisabled = 1;

				-----------------------------------------------------------------------------------------------
				-- set database owner to 'sa' if it's not owned currently by 'sa':
				IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE name = @currentDatabase AND owner_sid = 0x01) BEGIN 
					SET @ownerChangeCommand = N'ALTER AUTHORIZATION ON DATABASE::[' + @currentDatabase + N'] TO sa;';

					IF @PrintOnly = 1
						PRINT @ownerChangeCommand;
					ELSE 
						EXEC sp_executesql @ownerChangeCommand;
				END

				-----------------------------------------------------------------------------------------------
				-- attempt to fix any orphaned users: 
				DELETE FROM @orphans;
				SET @report = N'[' + @currentDatabase + N'].dbo.sp_change_users_login ''Report''';

				INSERT INTO @orphans
				EXEC(@report);

				DECLARE fixer CURSOR LOCAL FAST_FORWARD FOR
				SELECT UserName FROM @orphans;

				OPEN fixer;
				FETCH NEXT FROM fixer INTO @username;

				WHILE @@FETCH_STATUS = 0 BEGIN

					BEGIN TRY 
						IF @PrintOnly = 1 
							PRINT 'Processing Orphans for Principal Database ' + @currentDatabase
						ELSE
							EXEC sp_change_users_login @Action = 'Update_One', @UserNamePattern = @username, @LoginName = @username;  -- note: this only attempts to repair bindings in situations where the Login name is identical to the User name
					END TRY 
					BEGIN CATCH 
						-- swallow... 
					END CATCH

					FETCH NEXT FROM fixer INTO @username;
				END

				CLOSE fixer;
				DEALLOCATE fixer;

				----------------------------------
				-- Report on any logins that couldn't be corrected:
				DELETE FROM @orphans;

				INSERT INTO @orphans
				EXEC(@report);

				IF (SELECT COUNT(*) FROM @orphans) > 0 BEGIN 
					SET @usersStatus = N'Orphaned Users Detected (attempted repair did NOT correct) : ';
					SELECT @usersStatus = @usersStatus + UserName + ', ' FROM @orphans;

					SET @usersStatus = LEFT(@usersStatus, LEN(@usersStatus) - 1); -- trim trailing , 
					END
				ELSE 
					SET @usersStatus = N'No Orphaned Users Detected';					

			  END 
			ELSE BEGIN -- we're NOT the PRINCIPAL instance:
				SELECT 
					@enabledOrDisabled = 0,  -- make sure all jobs are disabled
					@usersStatus = N'', -- nothing will show up...  
					@otherStatus = N''; -- ditto
			  END

		  END
		ELSE BEGIN -- db isn't in SYNCHRONIZED/SYNCHRONIZING state... 
			-- can't do anything because of current db state. So, disable all jobs for db in question, and 'report' on outcome. 
			SELECT 
				@enabledOrDisabled = 0, -- preemptively disable
				@usersStatus = N'Unable to process - due to database state',
				@otherStatus = N'Database in non synchronized/synchronizing state';
		END

		-----------------------------------------------------------------------------------------------
		-- Process Jobs (i.e. toggle them on or off based on whatever value was set above):
		BEGIN TRY 
			DECLARE toggler CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				sj.job_id, sj.name
			FROM 
				msdb.dbo.sysjobs sj
				INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
			WHERE 
				LOWER(sc.name) = LOWER(@currentDatabase);

			DECLARE @jobid uniqueidentifier; 
			DECLARE @jobname sysname;

			OPEN toggler; 
			FETCH NEXT FROM toggler INTO @jobid, @jobname;

			WHILE @@FETCH_STATUS = 0 BEGIN 
		
				IF @PrintOnly = 1 BEGIN 
					PRINT 'EXEC msdb.dbo.sp_updatejob @job_name = ''' + @jobname + ''', @enabled = ' + CAST(@enabledOrDisabled AS varchar(1)) + ';'
				  END
				ELSE BEGIN
					EXEC msdb.dbo.sp_update_job
						@job_id = @jobid, 
						@enabled = @enabledOrDisabled;
				END

				FETCH NEXT FROM toggler INTO @jobid, @jobname;
			END 

			CLOSE toggler;
			DEALLOCATE toggler;

			IF @enabledOrDisabled = 1
				SET @jobsStatus = N'Jobs set to ENABLED';
			ELSE 
				SET @jobsStatus = N'Jobs set to DISABLED';

		END TRY 
		BEGIN CATCH 

			SELECT @jobsStatus = N'ERROR while attempting to set Jobs to ' + CASE WHEN @enabledOrDisabled = 1 THEN ' ENABLED ' ELSE ' DISABLED ' END + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(20)) + N' -> ' + ERROR_MESSAGE();
		END CATCH

		-----------------------------------------------------------------------------------------------
		-- Update the status for this job. 
		UPDATE @databases 
		SET 
			[jobs_status] = @jobsStatus,
			[users_status] = @usersStatus,
			[other_status] = @otherStatus
		WHERE 
			[db_name] = @currentDatabase;

		FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;
	END

	CLOSE processor;
	DEALLOCATE processor;
	
	-----------------------------------------------------------------------------------------------
	-- final report/summary. 
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);
	DECLARE @message nvarchar(MAX) = N'';
	DECLARE @subject nvarchar(400) = N'';
	DECLARE @dbs nvarchar(4000) = N'';
	
	SELECT @dbs = @dbs + N'  DATABASE: ' + [db_name] + @crlf 
		+ CASE WHEN [sync_type] = N'AVAILABILITY_GROUP' THEN @tab + N'AG_MEMBERSHIP = ' + (CASE WHEN [is_ag_member] = 1 THEN [ag_name] ELSE 'DISCONNECTED !!' END) ELSE '' END + @crlf
		+ @tab + N'CURRENT_ROLE = ' + [role] + @crlf 
		+ @tab + N'CURRENT_STATE = ' + CASE WHEN is_suspended = 1 THEN N'SUSPENDED !!' ELSE [state] END + @crlf
		+ @tab + N'OWNER = ' + ISNULL([owner], N'NULL') + @crlf 
		+ @tab + N'JOBS_STATUS = ' + jobs_status + @crlf 
		+ @tab + CASE WHEN NULLIF(users_status, '') IS NULL THEN N'' ELSE N'USERS_STATUS = ' + users_status END
		+ CASE WHEN NULLIF(other_status,'') IS NULL THEN N'' ELSE @crlf + @tab + N'OTHER_STATUS = ' + other_status END + @crlf 
		+ @crlf
	FROM @databases
	ORDER BY [db_name];

	SET @subject = N'Database Failover Detected on ' + @serverName;
	SET @message = N'Post failover-response details are as follows: ';
	SET @message = @message + @crlf + @crlf + N'SERVER NAME: ' + @serverName + @crlf;
	SET @message = @message + @crlf + @dbs;

	IF @PrintOnly = 1 BEGIN 
		-- just Print out details:
		PRINT 'SUBJECT: ' + @subject;
		PRINT 'BODY: ' + @crlf + @message;

		END
	ELSE BEGIN
		-- send a message:
		EXEC msdb..sp_notify_operator 
			@profile_name = @MailProfileName, 
			@name = @OperatorName, 
			@subject = @subject,
			@body = @message;
	END;	

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_job_states','P') IS NOT NULL
	DROP PROC dbo.verify_job_states;
GO

CREATE PROC dbo.verify_job_states 
	@SendChangeNotifications	bit = 1,
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname	= N'Alerts', 
	@EmailSubjectPrefix			sysname = N'[SQL Agent Jobs-State Updates]',
	@PrintOnly					bit	= 0
AS 
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF @PrintOnly = 0 BEGIN -- if we're not running a 'manual' execution - make sure we have all parameters:
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @jobsStatus nvarchar(MAX) = N'';

	-- Start by querying for list of mirrored then AG'd database to process:
	DECLARE @targetDatabases table (
		[db_name] sysname NOT NULL, 
		[role] sysname NOT NULL, 
		[state] sysname NOT NULL, 
		[owner] sysname NULL
	);

	INSERT INTO @targetDatabases ([db_name], [role], [state], [owner])
	SELECT 
		d.[name] [db_name],
		dm.mirroring_role_desc [role], 
		dm.mirroring_state_desc [state], 
		sp.[name] [owner]
	FROM 
		sys.database_mirroring dm
		INNER JOIN sys.databases d ON dm.database_id = d.database_id
		LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
	WHERE 
		dm.mirroring_guid IS NOT NULL;

	INSERT INTO @targetDatabases ([db_name], [role], [state], [owner])
	SELECT 
		dbcs.[database_name] [db_name],
		ISNULL(arstates.role_desc,'UNKNOWN') [role],
		ISNULL(dbrs.synchronization_state_desc, 'UNKNOWN') [state],
		x.[owner]
	FROM 
		master.sys.availability_groups AS ag
		LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states AS agstates ON ag.group_id = agstates.group_id
		INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
		INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON ar.replica_id = arstates.replica_id AND arstates.is_local = 1
		INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		LEFT OUTER JOIN master.sys.dm_hadr_database_replica_states AS dbrs ON dbcs.replica_id = dbrs.replica_id AND dbcs.group_database_id = dbrs.group_database_id
		LEFT OUTER JOIN (SELECT d.name, sp.name [owner] FROM master.sys.databases d INNER JOIN master.sys.server_principals sp ON d.owner_sid = sp.sid) x ON x.name = dbcs.database_name;

	DECLARE @currentDatabase sysname, @currentRole sysname, @currentState sysname; 
	DECLARE @enabledOrDisabled bit; 
	DECLARE @countOfJobsToModify int;

	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[db_name], 
		[role],
		[state]
	FROM 
		@targetDatabases
	ORDER BY 
		[db_name];

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;

	WHILE @@FETCH_STATUS = 0 BEGIN;

		SET @enabledOrDisabled = 0; -- default to disabled. 

		-- if the db is synchronized/synchronizing AND PRIMARY, then enable jobs:
		IF (@currentRole IN (N'PRINCIPAL',N'PRIMARY')) AND (@currentState IN ('SYNCHRONIZED','SYNCHRONIZING')) BEGIN
			SET @enabledOrDisabled = 1;
		END;

		-- determine if there are any jobs OUT of sync with their expected settings:
		SELECT @countOfJobsToModify = ISNULL((
				SELECT COUNT(*) FROM msdb.dbo.sysjobs sj INNER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id WHERE LOWER(sc.name) = LOWER(@currentDatabase) AND sj.enabled != @enabledOrDisabled 
			), 0);

		IF @countOfJobsToModify > 0 BEGIN;

			BEGIN TRY 
				DECLARE toggler CURSOR LOCAL FAST_FORWARD FOR 
				SELECT 
					sj.job_id, sj.name
				FROM 
					msdb.dbo.sysjobs sj
					INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
				WHERE 
					LOWER(sc.name) = LOWER(@currentDatabase)
					AND sj.[enabled] <> @enabledOrDisabled;

				DECLARE @jobid uniqueidentifier; 
				DECLARE @jobname sysname;

				OPEN toggler; 
				FETCH NEXT FROM toggler INTO @jobid, @jobname;

				WHILE @@FETCH_STATUS = 0 BEGIN 
		
					IF @PrintOnly = 1 BEGIN 
						PRINT '-- EXEC msdb.dbo.sp_updatejob @job_name = ''' + @jobname + ''', @enabled = ' + CAST(@enabledOrDisabled AS varchar(1)) + ';'
					  END
					ELSE BEGIN
						EXEC msdb.dbo.sp_update_job
							@job_id = @jobid, 
							@enabled = @enabledOrDisabled;
					END

					SET @jobsStatus = @jobsStatus + @tab + N'- [' + ISNULL(@jobname, N'#ERROR#') + N'] to ' + CASE WHEN @enabledOrDisabled = 1 THEN N'ENABLED' ELSE N'DISABLED' END + N'.' + @crlf;

					FETCH NEXT FROM toggler INTO @jobid, @jobname;
				END 

				CLOSE toggler;
				DEALLOCATE toggler;

			END TRY 
			BEGIN CATCH 
				SELECT @errorMessage = @errorMessage + N'ERROR while attempting to set Jobs to ' + CASE WHEN @enabledOrDisabled = 1 THEN N' ENABLED ' ELSE N' DISABLED ' END + N'. [ Error: ' + CAST(ERROR_NUMBER() AS nvarchar(20)) + N' -> ' + ERROR_MESSAGE() + N']';
			END CATCH
		
			-- cleanup cursor if it didn't get closed:
			IF (SELECT CURSOR_STATUS('local','toggler')) > -1 BEGIN;
				CLOSE toggler;
				DEALLOCATE toggler;
			END
		END

		FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;
	END

	CLOSE processor;
	DEALLOCATE processor;

	IF (SELECT CURSOR_STATUS('local','processor')) > -1 BEGIN;
		CLOSE processor;
		DEALLOCATE processor;
	END

	IF (@jobsStatus <> N'') AND (@SendChangeNotifications = 1) BEGIN;

		DECLARE @serverName sysname;
		SELECT @serverName = @@SERVERNAME; 

		SET @jobsStatus = N'The following changes were made to SQL Server Agent Jobs on ' + @serverName + ':' + @crlf + @jobsStatus;

		IF @errorMessage <> N'' 
			SET @jobsStatus = @jobsStatus + @crlf + @crlf + N'The following Error Details were also encountered: ' + @crlf + @tab + @errorMessage;

		DECLARE @emailSubject nvarchar(2000) = @EmailSubjectPrefix + N' Change Report for ' + @serverName;

		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
			PRINT @jobsStatus;

		  END
		ELSE BEGIN 
			EXEC msdb.dbo.sp_notify_operator 
				@profile_name = @MailProfileName,
				@name = @OperatorName, 
				@subject = @emailSubject, 
				@body = @jobsStatus;
		END
	END

	RETURN 0;

GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.populate_trace_flags','P') IS NOT NULL
	DROP PROC dbo.[populate_trace_flags];
GO

CREATE PROC dbo.[populate_trace_flags]

AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	TRUNCATE TABLE dbo.[server_trace_flags];

	INSERT INTO dbo.[server_trace_flags] (
		[trace_flag],
		[status],
		[global],
		[session]
	)
	EXECUTE ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_online','P') IS NOT NULL
	DROP PROC dbo.[verify_online];
GO

CREATE PROC dbo.[verify_online]

AS
    SET NOCOUNT ON; 

    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_partner','P') IS NOT NULL
	DROP PROC dbo.[verify_partner];
GO

CREATE PROC dbo.[verify_partner]
	@Error				nvarchar(MAX)			= N''			OUTPUT
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @return int;
	DECLARE @output nvarchar(MAX);

	DECLARE @partnerTest nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.verify_online;'

	DECLARE @results xml;
	EXEC @return = admindb.dbo.[execute_command]
		@Command = @partnerTest,
		@ExecutionType = N'EXEC',
		@ExecutionAttemptsCount = 0,
		@IgnoredResults = N'[COMMAND_SUCCESS]',
		@Results = @results OUTPUT;

	IF @return <> 0 BEGIN 
		SET @output = (SELECT @results.value('(/results/result)[1]', 'nvarchar(MAX)'));
	END;

	IF @output IS NOT NULL BEGIN
		IF @Error IS NULL 
			SET @Error = @output; 
		ELSE 
			SELECT @output [Error];
	END;

	RETURN @return;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_job_synchronization','P') IS NOT NULL
	DROP PROC dbo.verify_job_synchronization;
GO

CREATE PROC [dbo].[verify_job_synchronization]
	@IgnoredJobs			nvarchar(MAX)		= '',
	@MailProfileName		sysname				= N'General',	
	@OperatorName			sysname				= N'Alerts',	
	@PrintOnly				bit						= 0					-- output only to console - don't email alerts (for debugging/manual execution, etc.)
AS 
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	---------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END;

	EXEC @return = dbo.verify_partner 
		@Error = @returnMessage OUTPUT; 

	IF @return <> 0 BEGIN 
		-- S4-229: this (current) response is a hack - i.e., sending email/message DIRECTLY from this code-block violates DRY
		--			and is only in place until dbo.verify_job_synchronization is rewritten to use a process bus.
		IF @PrintOnly = 1 BEGIN 
			PRINT 'PARTNER is disconnected/non-accessible. Terminating early. Connection Details/Error:';
			PRINT '     ' + @returnMessage;
		  END;
		ELSE BEGIN 
			DECLARE @hackSubject nvarchar(200), @hackMessage nvarchar(MAX);
			SELECT 
				@hackSubject = N'PARTNER server is down/non-accessible.', 
				@hackMessage = N'Job Synchronization Checks can not continue as PARTNER server is down/non-accessible. Connection Error Details: ' + NCHAR(13) + NCHAR(10) + @returnMessage; 

			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @hackSubject,
				@body = @hackMessage;
		END;

		RETURN 0;
	END;

	----------------------------------------------
	-- Determine which server to run checks on:
	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;	 

	---------------------------------------------
	-- processing

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;


	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		server_name sysname, 
		sync_type sysname,
		[database_name] sysname, 
		[role] sysname
	);

	-- grab a list of all synchronizing LOCAL databases:
	INSERT INTO @synchronizingDatabases (
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	)
	SELECT 
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	FROM 
		dbo.list_synchronizing_databases(NULL, 0);

	-- we also need a list of synchronizing/able databases on the 'secondary' server:
	DECLARE @delayedSyntaxCheckHack nvarchar(max) = N'
		SELECT 
			[server_name],
			[sync_type],
			[database_name], 
			[role]
		FROM 
			OPENQUERY([PARTNER], ''SELECT * FROM [admindb].dbo.[list_synchronizing_databases](NULL, 0)'');';

	INSERT INTO @synchronizingDatabases (
		[server_name],
		[sync_type],
		[database_name], 
		[role]
	)
	EXEC sp_executesql @delayedSyntaxCheckHack;	

	----------------------------------------------
	-- establish which jobs to ignore (if any):
	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredJobs, N',', 1);

	----------------------------------------------
	-- create a container for output/differences. 
	CREATE TABLE #Divergence (
		row_id int IDENTITY(1,1) NOT NULL,
		[name] nvarchar(100) NOT NULL, 
		[description] nvarchar(300) NOT NULL
	);

	---------------------------------------------------------------------------------------------
	-- Process server-level jobs (jobs that aren't mapped to a Mirrored/AG'd database). 
	--		here we're just looking for differences in enabled states and/or differences between the job definitions/details from one server to the next. 
	CREATE TABLE #LocalJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	CREATE TABLE #RemoteJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	CREATE TABLE #DisableConfusedJobs (
		[name] sysname NOT NULL
	);

	-- Load Details: 
	INSERT INTO #LocalJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.[name], 'local') operator_name,
		ISNULL(sc.[name], 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id;

	INSERT INTO #RemoteJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	EXEC master.sys.sp_executesql N'SELECT 
	sj.job_id, 
	sj.[name], 
	sj.[enabled], 
	sj.[description], 
	sj.start_step_id,
	sj.owner_sid, 
	sj.notify_level_email, 
	ISNULL(so.name, ''local'') operator_name,
	ISNULL(sc.name, ''local'') [category_name],
	ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
FROM 
	PARTNER.msdb.dbo.sysjobs sj
	LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
	LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id';

	-- Remove Ignored Jobs: 
	DELETE x 
	FROM 
		[#LocalJobs] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE ignored.[name];
	
	DELETE x 
	FROM 
		[#RemoteJobs] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name];

	----------------------------------------------
	-- Process high-level details about each job
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		[name],
		N'Server-Level job exists on ' + @localServerName + N' only.'
	FROM 
		#LocalJobs 
	WHERE
		[name] NOT IN (SELECT [name] FROM #RemoteJobs)
		AND [category_name] NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName);

	INSERT INTO #Divergence ([name], [description])
	SELECT 
		[name], 
		N'Server-Level job exists on ' + @remoteServerName + N' only.'
	FROM 
		#RemoteJobs
	WHERE
		[name] NOT IN (SELECT [name] FROM #LocalJobs)
		AND [category_name] NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName);

	-- account for 3x scenarios for 'Disabled' (job category/convention) jobs: a) category set as disabled on ONE server but not the other, b) set to disabled (both servers) but JOB is enabled on one or both servers 
	INSERT INTO #Divergence ([name], [description])
	OUTPUT 
		[Inserted].[name] INTO [#DisableConfusedJobs]
	SELECT 
		lj.[name], 
		'Job-Mapping Problem. The Job ' + lj.[name] + N' exists on both servers - but has a job-category of [' + lj.[category_name] + N'] on ' + @localServerName + N' and a job-category of [' + rj.[category_name] + N'] on ' + @remoteServerName + N'.'
	FROM 
		[#LocalJobs] lj 
		INNER JOIN [#RemoteJobs] rj ON lj.[name] = rj.[name] 
	WHERE 
		(UPPER(lj.[category_name]) <> UPPER(rj.[category_name]))
		AND (
			UPPER(lj.[category_name]) = N'DISABLED' 
			OR 
			UPPER(rj.[category_name]) = N'DISABLED'
		);

	WITH conjoined AS ( 
		SELECT 
			@localServerName [server_name], 
			[name] [job_name]
		FROM 
			[#LocalJobs] 
		WHERE 
			UPPER([category_name]) = N'DISABLED' AND [enabled] = 1

		UNION 

		SELECT 
			@remoteServerName [server_name], 
			[name] [job_name]
		FROM 
			[#RemoteJobs] 
		WHERE 
			UPPER([category_name]) = N'DISABLED' AND [enabled] = 1
	) 
		
	INSERT INTO #Divergence ([name], [description])
	OUTPUT 
		[Inserted].[name] INTO [#DisableConfusedJobs]
	SELECT 
		[job_name], 
		N'Job [' + [job_name] + N'] on server ' + [server_name] + N' has a job-category of ''Disabled'', but the job is currently ENABLED.'
	FROM 
		[conjoined] 
	WHERE 
		[job_name] NOT IN (SELECT job_name FROM [#DisableConfusedJobs]);

	-- account for any job differences (not already accounted for)
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		lj.[name], 
		-- TODO: create GUIDANCE that covers how to use dbo.compare_jobs for this exact job.
		N'Differences between Server-Level job details between servers (owner, enabled, category name, job-steps count, start-step, notification, etc).'
	FROM 
		#LocalJobs lj
		INNER JOIN #RemoteJobs rj ON rj.[name] = lj.[name]
	WHERE
		lj.[name] NOT IN (SELECT [name] FROM [#DisableConfusedJobs])
		AND lj.category_name NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName) 
		AND rj.category_name NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName)
		AND 
		(
			lj.[enabled] <> rj.[enabled]
			OR lj.[description] <> rj.[description]
			OR lj.start_step_id <> rj.start_step_id
			OR lj.owner_sid <> rj.owner_sid
			OR lj.notify_level_email <> rj.notify_level_email
			OR lj.operator_name <> rj.operator_name
			OR lj.job_step_count <> rj.job_step_count
			OR lj.category_name <> rj.category_name
		);



	----------------------------------------------
	-- now check the job steps/schedules/etc. 
	CREATE TABLE #LocalJobSteps (
		step_id int, 
		[checksum] int
	);

	CREATE TABLE #RemoteJobSteps (
		step_id int, 
		[checksum] int
	);

	CREATE TABLE #LocalJobSchedules (
		schedule_name sysname, 
		[checksum] int
	);

	CREATE TABLE #RemoteJobSchedules (
		schedule_name sysname, 
		[checksum] int
	);

	DECLARE server_level_checker CURSOR LOCAL FAST_FORWARD FOR
	SELECT 
		[local].job_id local_job_id, 
		[remote].job_id remote_job_id, 
		[local].name 
	FROM 
		#LocalJobs [local]
		INNER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name];

	DECLARE @localJobID uniqueidentifier, @remoteJobId uniqueidentifier, @jobName sysname;
	DECLARE @localCount int, @remoteCount int;

	OPEN server_level_checker;
	FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
	
		-- check jobsteps first:
		DELETE FROM #LocalJobSteps;
		DELETE FROM #RemoteJobSteps;

		INSERT INTO #LocalJobSteps (step_id, [checksum])
		SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM msdb.dbo.sysjobsteps
		WHERE job_id = @localJobID;

		INSERT INTO #RemoteJobSteps (step_id, [checksum])
		EXEC master.sys.sp_executesql N'SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM PARTNER.msdb.dbo.sysjobsteps
		WHERE job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

		IF @localCount <> @remoteCount
			INSERT INTO #Divergence ([name], [description]) 
			VALUES (
				@jobName, 
				N'Job Step Counts between servers are NOT the same.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				@jobName, 
				N'Job Step details between servers are NOT the same.'
			FROM 
				#LocalJobSteps ljs 
				INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
			WHERE	
				ljs.[checksum] <> rjs.[checksum];
		END;

		-- Now Check Schedules:
		DELETE FROM #LocalJobSchedules;
		DELETE FROM #RemoteJobSchedules;

		INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
		SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			msdb.dbo.sysjobschedules sjs
			INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @localJobID;

		INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
		EXEC master.sys.sp_executesql N'SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

		IF @localCount <> @remoteCount
			INSERT INTO #Divergence ([name], [description]) 
			VALUES (
				@jobName, 
				N'Job Schedule Counts between servers are different.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence ([name], [description])
			SELECT
				@jobName, 
				N'Job Schedule Details between servers are different.'
			FROM 
				#LocalJobSchedules ljs
				INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
			WHERE 
				ljs.[checksum] <> rjs.[checksum];

		END;

		FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;
	END;

	CLOSE server_level_checker;
	DEALLOCATE server_level_checker;

	---------------------------------------------------------------------------------------------
	-- Process Batch-Jobs. 

	-- Check on job details for batch-jobs:
	TRUNCATE TABLE #LocalJobs;
	TRUNCATE TABLE #RemoteJobs;

	DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
	SELECT DISTINCT 
		[database_name]
	FROM 
		@synchronizingDatabases
	ORDER BY 
		[database_name];

	DECLARE @currentMirroredDB sysname; 

	OPEN looper;
	FETCH NEXT FROM looper INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		TRUNCATE TABLE #LocalJobs;
		TRUNCATE TABLE #RemoteJobs;
		
		INSERT INTO #LocalJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		SELECT 
			sj.job_id, 
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.[name], 'local') operator_name,
			ISNULL(sc.[name], 'local') [category_name],
			ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			msdb.dbo.sysjobs sj
			LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.[name]) = UPPER(@currentMirroredDB);

		INSERT INTO #RemoteJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		EXEC master.sys.sp_executesql N'SELECT 
			sj.job_id, 
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.[name], ''local'') operator_name,
			ISNULL(sc.[name], ''local'') [category_name],
			ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
			LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.[name]) = UPPER(@currentMirroredDB);', N'@currentMirroredDB sysname', @currentMirroredDB = @currentMirroredDB;

		-- Remove Ignored Jobs: 
		DELETE x 
		FROM 
			[#LocalJobs] x 
			INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE ignored.[name];
	
		DELETE x 
		FROM 
			[#RemoteJobs] x 
			INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name];

		DELETE [#LocalJobs] WHERE [name] IN (SELECT [name] FROM [#DisableConfusedJobs]);
		DELETE [#RemoteJobs] WHERE [name] IN (SELECT [name] FROM [#DisableConfusedJobs]);

		------------------------------------------
		-- Now start comparing differences: 

		-- local  only:
-- TODO: create separate checks/messages for jobs existing only on one server or the other AND the whole 'OR is disabled' on one server or the other). 
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[local].[name], 
			N'Batch-Job for database [' + @currentMirroredDB + N'] exists on ' + @localServerName + N' only.'
		FROM 
			#LocalJobs [local]
			LEFT OUTER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name]
		WHERE 
			[remote].[name] IS NULL;

		-- remote only:
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[remote].[name], 
			N'Batch-Job for database [' + @currentMirroredDB + N'] exists on ' + @remoteServerName + N' only.'
		FROM 
			#RemoteJobs [remote]
			LEFT OUTER JOIN #LocalJobs [local] ON [remote].[name] = [local].[name]
		WHERE 
			[local].[name] IS NULL;

		-- differences:
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[local].[name], 
			N'Batch-Job for database [' + @currentMirroredDB + N'] is different between servers (owner, start-step, notification, etc).'
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [remote].[name] = [local].[name]
		WHERE
			[local].start_step_id <> [remote].start_step_id
			OR [local].owner_sid <> [remote].owner_sid
			OR [local].notify_level_email <> [remote].notify_level_email
			OR [local].operator_name <> [remote].operator_name
			OR [local].job_step_count <> [remote].job_step_count
			OR [local].category_name <> [remote].category_name;
		
		-- Process Batch-Job enabled states. There are three possible scenarios or situations to be aware of: 
		--		a) job.categoryname = '[a synchronizing db name] AND job.enabled = 0 on the PRIMARY (which it shouldn't be, because unless category is set to disabled, this job will be re-enabled post-failover). 
		--		b) job.categoryname = 'DISABLED' on the SECONDARY and job.enabled = 1... which is bad. Shouldn't be that way. 
		--		c) job.categoryname = '[a synchronizing db name]' and job.enabled != to what should be set for the current role (i.e., enabled on PRIMARY and disabled on SECONDARY). 
		--			only local variant of scenario c = scenario a, and the remote/partner variant of c = scenario b. 
		IF (SELECT dbo.is_primary_database(@currentMirroredDB)) = 1 BEGIN 
			-- report on any batch jobs that are disabled on the primary:
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is disabled on ' + @localServerName + N' (PRIMARY). Following a failover, this job will be re-enabled on the secondary. To prevent job from being re-enabled following failovers, set job category to ''Disabled''.'
			FROM 
				#LocalJobs
			WHERE
				[enabled] = 0 
				AND [category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName);
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is enabled on ' + @remoteServerName + N' (SECONDARY). Batch-Jobs (Jobs WHERE Job.CategoryName = NameOfASynchronizedDatabase), should be disabled on the SECONDARY and enabled on the PRIMARY.'
			FROM 
				#RemoteJobs
			WHERE
				[enabled] = 1 
				AND category_name IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName);
		  END 
		ELSE BEGIN -- otherwise, simply 'flip' the logic:
			-- report on any mirroring jobs that are disabled on the primary:
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is disabled on ' + @remoteServerName + N' (PRIMARY). Following a failover, this job will be re-enabled on the secondary. To prevent job from being re-enabled following failovers, set job category to ''Disabled''.'
			FROM 
				#RemoteJobs
			WHERE
				[enabled] = 0 
				AND [category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName); 		
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is enabled on ' + @localServerName + N' (SECONDARY). Batch-Jobs (Jobs WHERE Job.CategoryName = NameOfASynchronizedDatabase), should be disabled on the SECONDARY and enabled on the PRIMARY.'
			FROM 
				#LocalJobs
			WHERE
				[enabled] = 1 
				AND category_name IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName); 
		END

		---------------
		-- job-steps processing:
		TRUNCATE TABLE #LocalJobSteps;
		TRUNCATE TABLE #RemoteJobSteps;
		TRUNCATE TABLE #LocalJobSchedules;
		TRUNCATE TABLE #RemoteJobSchedules;

		DECLARE checker CURSOR LOCAL FAST_FORWARD FOR
		SELECT 
			[local].job_id local_job_id, 
			[remote].job_id remote_job_id, 
			[local].[name] 
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name];

		OPEN checker;
		FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;

		WHILE @@FETCH_STATUS = 0 BEGIN 
	
			-- check jobsteps first:
			DELETE FROM #LocalJobSteps;
			DELETE FROM #RemoteJobSteps;

			INSERT INTO #LocalJobSteps (step_id, [checksum])
			SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [detail]
			FROM msdb.dbo.sysjobsteps
			WHERE job_id = @localJobID;

			INSERT INTO #RemoteJobSteps (step_id, [checksum])
			EXEC master.sys.sp_executesql N'SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [detail]
			FROM PARTNER.msdb.dbo.sysjobsteps
			WHERE job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

			IF @localCount <> @remoteCount
				INSERT INTO #Divergence ([name], [description]) 
				VALUES (
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Step Counts between servers are NOT the same.'
				);
			ELSE BEGIN 
				INSERT INTO #Divergence
				SELECT 
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Step details between servers are NOT the same.'
				FROM 
					#LocalJobSteps ljs 
					INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
				WHERE	
					ljs.[checksum] <> rjs.[checksum];
			END;

			-- Now Check Schedules:
			DELETE FROM #LocalJobSchedules;
			DELETE FROM #RemoteJobSchedules;

			INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
			SELECT 
				ss.name,
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				msdb.dbo.sysjobschedules sjs
				INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @localJobID;


			INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
			EXEC master.sys.sp_executesql N'SELECT 
				ss.[name],
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				PARTNER.msdb.dbo.sysjobschedules sjs
				INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

			IF @localCount <> @remoteCount
				INSERT INTO #Divergence (name, [description])
				VALUES (
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Schedule Counts between servers are different.'
				);
			ELSE BEGIN 
				INSERT INTO #Divergence (name, [description])
				SELECT
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Schedule Details between servers are different.'
				FROM 
					#LocalJobSchedules ljs
					INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
				WHERE 
					ljs.[checksum] <> rjs.[checksum];

			END;

			FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;
		END;

		CLOSE checker;
		DEALLOCATE checker;

		---------------

		FETCH NEXT FROM looper INTO @currentMirroredDB;
	END 

	CLOSE looper;
	DEALLOCATE looper;

	---------------------------------------------------------------------------------------------
	-- X) Report on any problems or discrepencies:
	DELETE x 
	FROM 
		[#Divergence] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name]
	WHERE 
		[ignored].[name] IS NOT NULL;

	IF(SELECT COUNT(*) FROM #Divergence) > 0 BEGIN 

		DECLARE @subject nvarchar(200) = 'SQL Server Agent Job Synchronization Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = 'Problems detected with the following SQL Server Agent Jobs: '
		+ @crlf;

		SELECT 
			@message = @message + @tab + N'- ' + name + N' -> ' + [description] + @crlf
		FROM 
			#Divergence
		ORDER BY 
			row_id;

		SELECT @message += @crlf + @tab + N'NOTE: Jobs can be synchronized by scripting them on the Primary and running scripts on the Secondary.'
			+ @crlf + @tab + @tab + N'To Script Multiple Jobs at once: SSMS > SQL Server Agent Jobs > F7 -> then shift/ctrl + click to select multiple jobs simultaneously.';

		SELECT @message += @crlf + @tab + N'NOTE: If a Job is assigned to a Mirrored DB (Job Category Name) on ONE server but not the other, it will likely '
			+ @crlf + @tab + @tab + N'show up 2x in the list of problems - once as a Server-Level job on one Server only, and once as a Mirrored-DB Job on the other server.';

		IF @PrintOnly = 1 BEGIN 
			-- just Print out details:
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;

		  END
		ELSE BEGIN
			-- send a message:
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject,
				@body = @message;
		END;
	END;

	DROP TABLE #LocalJobs;
	DROP TABLE #RemoteJobs;
	DROP TABLE #Divergence;
	DROP TABLE #LocalJobSteps;
	DROP TABLE #RemoteJobSteps;
	DROP TABLE #LocalJobSchedules;
	DROP TABLE #RemoteJobSchedules;
	DROP TABLE #IgnoredJobs;
	DROP TABLE [#DisableConfusedJobs];

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_server_synchronization','P') IS NOT NULL
	DROP PROC dbo.verify_server_synchronization;
GO

CREATE PROC dbo.verify_server_synchronization 
	@IgnoreSynchronizedDatabaseOwnership	    bit		            = 0,					
	@IgnoredMasterDbObjects				        nvarchar(MAX)       = NULL,
	@IgnoredLogins						        nvarchar(MAX)       = NULL,
	@IgnoredAlerts						        nvarchar(MAX)       = NULL,
	@IgnoredLinkedServers				        nvarchar(MAX)       = NULL,
    @IgnorePrincipalNames                       bit                 = 1,                -- e.g., WinName1\Administrator and WinBox2Name\Administrator should both be treated as just 'Administrator'
	@MailProfileName					        sysname             = N'General',					
	@OperatorName						        sysname             = N'Alerts',					
	@PrintOnly							        bit		            = 0						
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

    CREATE TABLE #bus ( 
        [row_id] int IDENTITY(1,1) NOT NULL, 
        [channel] sysname NOT NULL DEFAULT (N'warning'),  -- ERROR | WARNING | INFO | CONTROL | GUIDANCE | OUTCOME (for control?)
        [timestamp] datetime NOT NULL DEFAULT (GETDATE()),
        [parent] int NULL,
        [grouping_key] sysname NULL, 
        [heading] nvarchar(1000) NULL, 
        [body] nvarchar(MAX) NULL, 
        [detail] nvarchar(MAX) NULL, 
        [command] nvarchar(MAX) NULL
    );

	EXEC @return = dbo.verify_partner 
		@Error = @returnMessage OUTPUT; 

	IF @return <> 0 BEGIN 
		INSERT INTO [#bus] (
			[channel],
			[heading],
			[body], 
			[detail]
		)
		VALUES	(
			N'ERROR', 
			N'PARTNER is down/inaccessible.', 
			N'Synchronization Checks against PARTNER server cannot be conducted as connection attempts against PARTNER from ' + @@SERVERNAME + N' failed.', 
			@returnMessage
		)
		
		GOTO REPORTING;
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END; 

	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;

	IF OBJECT_ID('admindb.dbo.server_trace_flags', 'U') IS NULL BEGIN 
		RAISERROR('Table dbo.server_trace_flags is not present in master. Synchronization check can not be processed.', 16, 1);
		RETURN -6;
	END

	-- Start by updating dbo.server_trace_flags on both servers:
	EXEC dbo.[populate_trace_flags];
	EXEC sp_executesql N'EXEC [PARTNER].[admindb].dbo.populate_trace_flags; ';

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

    ---------------------------------------
	-- Server Level Configuration/Settings: 
	DECLARE @remoteConfig table ( 
		configuration_id int NOT NULL, 
		value_in_use sql_variant NULL
	);	

	INSERT INTO @remoteConfig (configuration_id, value_in_use)
	EXEC master.sys.sp_executesql N'SELECT configuration_id, value_in_use FROM PARTNER.master.sys.configurations;';

    INSERT INTO [#bus] (
        [grouping_key],
        [heading], 
        [body]
    )
    SELECT 
        N'sys.configurations' [grouping_key], 
        N'Setting ' + QUOTENAME([source].[name]) + N' is different between servers.' [heading], 
        N'Value on ' + @localServerName + N' = ' + CAST([source].[value_in_use] AS sysname) + N'. Value on ' + @remoteServerName + N' = ' + CAST([target].[value_in_use] AS sysname) + N'.' [body]
	FROM 
		master.sys.configurations [source]
		INNER JOIN @remoteConfig [target] ON [source].[configuration_id] = [target].[configuration_id]
	WHERE 
		[source].value_in_use <> [target].value_in_use;

    ---------------------------------------
	-- Trace Flags: 
	DECLARE @remoteFlags TABLE (
		trace_flag int NOT NULL, 
		[status] bit NOT NULL, 
		[global] bit NOT NULL, 
		[session] bit NOT NULL
	);
	
	INSERT INTO @remoteFlags ([trace_flag], [status], [global], [session])
	EXEC sp_executesql N'SELECT [trace_flag], [status], [global], [session] FROM PARTNER.admindb.dbo.server_trace_flags;';
	
	-- local only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'trace flag' [grouping_key], 
        N'Trace Flag ' + CAST(trace_flag AS sysname) + N' exists only on ' + @localServerName + N'.' [heading] 
	FROM 
		admindb.dbo.server_trace_flags 
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM admindb.dbo.server_trace_flags);

	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'trace flag' [grouping_key],
        N'Trace Flag ' + CAST(trace_flag AS sysname) + N' exists only on ' + @remoteServerName + N'.' [heading]  
	FROM 
		admindb.dbo.server_trace_flags 
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM @remoteFlags);

	-- different values: 
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'trace flag' [grouping_key],
        N'Trace Flag Enabled Value is Different Between Servers.' [heading]
	FROM 
		admindb.dbo.server_trace_flags [x]
		INNER JOIN @remoteFlags [y] ON x.trace_flag = y.trace_flag 
	WHERE 
		x.[status] <> y.[status]
		OR x.[global] <> y.[global]
		OR x.[session] <> y.[session];

	---------------------------------------
	-- Make sure sys.messages.message_id #1480 is set so that is_event_logged = 1 (for easier/simplified role change (failover) notifications). Likewise, make sure 1440 is still set to is_event_logged = 1 (the default). 
	DECLARE @remoteMessages table (
		language_id smallint NOT NULL, 
		message_id int NOT NULL, 
		is_event_logged bit NOT NULL
	);

	INSERT INTO @remoteMessages (language_id, message_id, is_event_logged)
	EXEC sp_executesql N'SELECT language_id, message_id, is_event_logged FROM PARTNER.master.sys.messages WHERE message_id IN (1440, 1480);';
    
    -- local:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'error messages' [grouping_key],
        N'The is_event_logged property for message_id ' + CAST(message_id AS sysname) + N' on ' + @localServerName + N' is not set to 1.' [heading]
	FROM 
		sys.messages 
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	-- remote:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading] 
    )    
    SELECT 
        N'error messages' [grouping_key],
        N'The is_event_logged property for message_id ' + CAST(message_id AS sysname) + N' on ' + @remoteServerName + N' is not set to 1.' [heading]
	FROM 
		sys.messages 
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	---------------------------------------
	-- admindb checks: 
	DECLARE @localAdminDBVersion sysname;
	DECLARE @remoteAdminDBVersion sysname;

	SELECT @localAdminDBVersion = version_number FROM admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM admindb..version_history);
	EXEC sys.sp_executesql N'SELECT @remoteVersion = version_number FROM PARTNER.admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM PARTNER.admindb.dbo.version_history);', N'@remoteVersion sysname OUTPUT', @remoteVersion = @remoteAdminDBVersion OUTPUT;

	IF @localAdminDBVersion <> @remoteAdminDBVersion BEGIN
        INSERT INTO [#bus] (
            [grouping_key],
            [heading], 
            [body]
        )    
        SELECT 
            N'admindb (s4 versioning)' [grouping_key],
            N'S4 Database versions are different betweent servers.' [heading], 
            N'Version on ' + @localServerName + N' is ' + @localAdminDBVersion + '. Version on' + @remoteServerName + N' is ' + @remoteAdminDBVersion + N'.' [body];
	END;

    DECLARE @localAdvancedValue sysname; 
    DECLARE @remoteAdvancedValue sysname; 

    SELECT @localAdvancedValue = setting_value FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling';
    EXEC sys.sp_executesql N'SELECT @remoteAdvancedValue = setting_value FROM PARTNER.admindb.dbo.settings WHERE [setting_key] = N''advanced_s4_error_handling'';', N'@remoteAdvancedValue sysname OUTPUT', @remoteAdvancedValue = @remoteAdvancedValue OUTPUT;

    IF ISNULL(@localAdvancedValue, N'0') <> ISNULL(@remoteAdvancedValue, N'0') BEGIN 
        INSERT INTO [#bus] (
            [grouping_key],
            [heading], 
            [body]
        )
        SELECT 
            N'admindb (s4 versioning)' [grouping_key],
            N'S4 Advanced Error Handling configuration settings are different betweent servers.' [heading], 
            N'Value on ' + @localServerName + N' is ' + @localAdvancedValue + '. Value on' + @remoteServerName + N' is ' + @remoteAdvancedValue + N'.' [body];
    END; 

	---------------------------------------
	-- Mirrored database ownership:
	IF @IgnoreSynchronizedDatabaseOwnership = 0 BEGIN 
		DECLARE @localOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL, 
			owner_sid varbinary(85) NULL
		);

		-- mirrored (local) dbs: 
		INSERT INTO @localOwners ([name], sync_type, owner_sid)
		SELECT d.[name], N'Mirrored' [sync_type], d.owner_sid FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL; 

		-- AG'd (local) dbs: 
        IF (SELECT admindb.dbo.get_engine_version()) >= 11.0 BEGIN
			INSERT INTO @localOwners ([name], sync_type, owner_sid)
			EXEC master.sys.sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM sys.databases WHERE replica_id IS NOT NULL;';  -- has to be dynamic sql - otherwise replica_id will throw an error during sproc creation... 
		END

		DECLARE @remoteOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL,
			owner_sid varbinary(85) NULL
		);

		-- Mirrored (remote) dbs:
		INSERT INTO @remoteOwners ([name], sync_type, owner_sid) 
		EXEC sp_executesql N'SELECT d.[name], ''Mirrored'' [sync_type], d.owner_sid FROM PARTNER.master.sys.databases d INNER JOIN PARTNER.master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL;';

		-- AG'd (local) dbs: 
		IF (SELECT admindb.dbo.get_engine_version()) >= 11.0 BEGIN
			INSERT INTO @remoteOwners ([name], sync_type, owner_sid)
			EXEC sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM [PARTNER].[master].sys.databases WHERE replica_id IS NOT NULL;';			
		END

        INSERT INTO [#bus] (
            [grouping_key],
            [heading], 
            [body]
        )    
        SELECT 
            N'databases' [grouping_key], 
			[local].sync_type + N' database owners for database ' + QUOTENAME([local].[name]) + N' are different between servers.' [heading], 
            N'To correct: a) Execute a manual failover of database ' + QUOTENAME([local].[name]) + N', and then b) EXECUTE { ALTER AUTHORIZATION ON DATABASE::[' + [local].[name] + N'] TO [sa];  }. NOTE: All synchronized databases should be owned by SysAdmin.'
            -- TODO: instructions on how to fix and/or CONTROL directives TO fix... (only, can't 'fix' this issue with mirrored/AG'd databases).
		FROM 
			@localOwners [local]
			INNER JOIN @remoteOwners [remote] ON [local].[name] = [remote].[name]
		WHERE
			[local].owner_sid <> [remote].owner_sid;

	END

	---------------------------------------
	-- Linked Servers:
	DECLARE @IgnoredLinkedServerNames TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @IgnoredLinkedServerNames([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredLinkedServers, N',', 1);

	DECLARE @remoteLinkedServers table ( 
		[server_id] int NOT NULL,
		[name] sysname NOT NULL,
		[location] nvarchar(4000) NULL,
		[provider_string] nvarchar(4000) NULL,
		[catalog] sysname NULL,
		[product] sysname NOT NULL,
		[data_source] nvarchar(4000) NULL,
		[provider] sysname NOT NULL,
		[is_remote_login_enabled] bit NOT NULL,
		[is_rpc_out_enabled] bit NOT NULL,
		[is_collation_compatible] bit NOT NULL,
		[uses_remote_collation] bit NOT NULL,
		[collation_name] sysname NULL,
		[connect_timeout] int NULL,
		[query_timeout] int NULL,
		[is_remote_proc_transaction_promotion_enabled] bit NULL,
		[is_system] bit NOT NULL,
		[lazy_schema_validation] bit NOT NULL
	);

	INSERT INTO @remoteLinkedServers ([server_id], [name], [location], provider_string, [catalog], product, [data_source], [provider], is_remote_login_enabled, is_rpc_out_enabled, is_collation_compatible, uses_remote_collation,
		 collation_name, connect_timeout, query_timeout, is_remote_proc_transaction_promotion_enabled, is_system, lazy_schema_validation)
	EXEC master.sys.sp_executesql N'SELECT [server_id], [name], [location], provider_string, [catalog], product, [data_source], [provider], is_remote_login_enabled, is_rpc_out_enabled, is_collation_compatible, uses_remote_collation, collation_name, connect_timeout, query_timeout, is_remote_proc_transaction_promotion_enabled, is_system, lazy_schema_validation FROM PARTNER.master.sys.servers;';

	-- local only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'linked servers' [grouping_key], 
        N'Linked Server definition for ' + QUOTENAME([local].[name]) + N' exists on ' + @localServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		sys.servers [local]
		LEFT OUTER JOIN @remoteLinkedServers [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].server_id > 0 
		AND [local].[name] <> 'PARTNER'
		AND [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [remote].[name] IS NULL;

	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'linked servers' [grouping_key], 
        N'Linked Server definition for ' + QUOTENAME([remote].[name]) + N' exists on ' + @remoteServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteLinkedServers [remote]
		LEFT OUTER JOIN master.sys.servers [local] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[remote].server_id > 0 
		AND [remote].[name] <> 'PARTNER'
		AND [remote].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [local].[name] IS NULL;
	
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'linked servers' [grouping_key], 
		N'Linked Server Definition for ' + QUOTENAME([local].[name]) + N' exists on both servers but is different.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		sys.servers [local]
		INNER JOIN @remoteLinkedServers [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND ( 
			[local].product COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].product
			OR [local].[provider] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[provider]
			-- Sadly, PARTNER is a bit of a pain/problem - it has to exist on both servers - but with slightly different versions:
			OR (
				CASE 
					WHEN [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = 'PARTNER' AND [local].[data_source] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[data_source] THEN 0 -- non-true (i.e., non-'different' or non-problematic)
					ELSE 1  -- there's a problem (because data sources are different, but the name is NOT 'Partner'
				END 
				 = 1  
			)
			OR [local].[location] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[location]
			OR [local].provider_string COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].provider_string
			OR [local].[catalog] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[catalog]
			OR [local].is_remote_login_enabled <> [remote].is_remote_login_enabled
			OR [local].is_rpc_out_enabled <> [remote].is_rpc_out_enabled
			OR [local].is_collation_compatible <> [remote].is_collation_compatible
			OR [local].uses_remote_collation <> [remote].uses_remote_collation
			OR [local].collation_name COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].collation_name
			OR [local].connect_timeout <> [remote].connect_timeout
			OR [local].query_timeout <> [remote].query_timeout
			OR [local].is_remote_proc_transaction_promotion_enabled <> [remote].is_remote_proc_transaction_promotion_enabled
			OR [local].is_system <> [remote].is_system
			OR [local].lazy_schema_validation <> [remote].lazy_schema_validation
		);

	---------------------------------------
	-- Logins:
	DECLARE @ignoredLoginName TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredLoginName([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredLogins, N',', 1);

	DECLARE @remotePrincipals table ( 
		[principal_id] int NOT NULL,
		[name] sysname NOT NULL,
        [simplified_name] sysname NULL,
		[sid] varbinary(85) NULL,
		[type] char(1) NOT NULL,
		[is_disabled] bit NULL, 
        [password_hash] varbinary(256) NULL
	);

	INSERT INTO @remotePrincipals ([principal_id], [name], [sid], [type], [is_disabled], [password_hash])
	EXEC master.sys.sp_executesql N'
    SELECT 
        p.[principal_id], 
        p.[name], 
        p.[sid], 
        p.[type], 
        p.[is_disabled], 
        l.[password_hash]
    FROM 
        [PARTNER].[master].sys.server_principals p
        LEFT OUTER JOIN [PARTNER].[master].sys.sql_logins l ON p.[principal_id] = l.[principal_id]
    WHERE 
        p.[principal_id] > 10 
        AND p.[name] NOT LIKE ''##%##'' AND p.[name] NOT LIKE ''NT %\%'';';

	DECLARE @localPrincipals table ( 
		[principal_id] int NOT NULL,
		[name] sysname NOT NULL,
        [simplified_name] sysname NULL,
		[sid] varbinary(85) NULL,
		[type] char(1) NOT NULL,
		[is_disabled] bit NULL, 
        [password_hash] varbinary(256) NULL
	);

	INSERT INTO @localPrincipals ([principal_id], [name], [sid], [type], [is_disabled], [password_hash])
    SELECT 
        p.[principal_id], 
        p.[name], 
        p.[sid], 
        p.[type], 
        p.[is_disabled], 
        l.[password_hash]
    FROM 
        [master].sys.server_principals p
        LEFT OUTER JOIN [master].sys.sql_logins l ON p.[principal_id] = l.[principal_id]
    WHERE 
        p.[principal_id] > 10 
        AND p.[name] NOT LIKE '##%##' AND p.[name] NOT LIKE 'NT %\%';

    IF @IgnorePrincipalNames = 1 BEGIN 
        UPDATE @localPrincipals
        SET 
            [simplified_name] = REPLACE([name], @localServerName + N'\', N''),
            [sid] = 0x0
        WHERE 
            [type] = 'U'
            AND [name] LIKE @localServerName + N'\%'; 
            
        UPDATE @remotePrincipals
        SET 
            [simplified_name] = REPLACE([name], @remoteServerName + N'\', N''), 
            [sid] = 0x0
        WHERE 
            [type] = 'U' -- Windows Only... 
            AND [name] LIKE @remoteServerName + N'\%';
    END;

    -- local only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'logins' [grouping_key], 
		N'Login ' + QUOTENAME([local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS) + N' exists on ' + QUOTENAME(@localServerName) + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@localPrincipals [local]
	WHERE 
		ISNULL([local].[simplified_name], [local].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT ISNULL([simplified_name], [name]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @remotePrincipals)
		AND [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
			SELECT 
				x.[name] COLLATE SQL_Latin1_General_CP1_CI_AS 
			FROM 
				@localPrincipals x 
				INNER JOIN @ignoredLoginName i ON x.[name] LIKE i.[name]
		);

	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'logins' [grouping_key], 
		N'Login ' + QUOTENAME([remote].[name] COLLATE SQL_Latin1_General_CP1_CI_AS) + N' exists on ' + QUOTENAME(@remoteServerName) + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remotePrincipals [remote]
	WHERE 
		ISNULL([remote].[simplified_name], [remote].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT ISNULL([simplified_name], [name]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @localPrincipals)
		AND [remote].[name] NOT IN (
			SELECT 
				x.[name] COLLATE SQL_Latin1_General_CP1_CI_AS 
			FROM 
				@remotePrincipals x 
				INNER JOIN @ignoredLoginName i ON x.[name] LIKE i.[name]
		);

	-- differences
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'logins' [grouping_key], 
		N'Definition for Login ' + QUOTENAME([local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS) + N' is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
        @localPrincipals [local]
        INNER JOIN @remotePrincipals [remote] ON ISNULL([local].[simplified_name], [local].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS = ISNULL([remote].[simplified_name], [remote].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS
	WHERE
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
			SELECT 
				x.[name] COLLATE SQL_Latin1_General_CP1_CI_AS 
			FROM 
				@localPrincipals x 
				INNER JOIN @ignoredLoginName i ON x.[name] LIKE i.[name]			
		)
		AND (
			[local].[sid] <> [remote].[sid]
			OR [local].password_hash <> [remote].password_hash  
			OR [local].is_disabled <> [remote].is_disabled
		);

    -- (server) role memberships: 
    DECLARE @localMemberRoles table ( 
        [login_name] sysname NOT NULL, 
        [simplified_name] sysname NULL, 
        [role] sysname NOT NULL
    );

    DECLARE @remoteMemberRoles table ( 
        [login_name] sysname NOT NULL, 
        [simplified_name] sysname NULL, 
        [role] sysname NOT NULL
    );	
    
    -- note, explicitly including NT SERVICE\etc and other 'built in' service accounts as we want to check for any differences in role memberships:
    INSERT INTO @localMemberRoles (
        [login_name],
        [role]
    )
    SELECT 
	    p.[name] [login_name],
	    [roles].[name] [role_name]
    FROM 
	    sys.server_principals p 
	    INNER JOIN sys.server_role_members m ON p.principal_id = m.member_principal_id
	    INNER JOIN sys.server_principals [roles] ON m.role_principal_id = [roles].principal_id
    WHERE 
	    p.principal_id > 10 AND p.[name] NOT LIKE '##%##';

    INSERT INTO @remoteMemberRoles (
        [login_name],
        [role]
    )
    EXEC sys.[sp_executesql] N'
    SELECT 
	    p.[name] [login_name],
	    [roles].[name] [role_name]
    FROM 
	    [PARTNER].[master].sys.server_principals p 
	    INNER JOIN [PARTNER].[master].sys.server_role_members m ON p.principal_id = m.member_principal_id
	    INNER JOIN [PARTNER].[master].sys.server_principals [roles] ON m.role_principal_id = [roles].principal_id
    WHERE 
	    p.principal_id > 10 AND p.[name] NOT LIKE ''##%##''; ';
        
    IF @IgnorePrincipalNames = 1 BEGIN 
        UPDATE @localMemberRoles
        SET 
            [simplified_name] = REPLACE([login_name], @localServerName + N'\', N'')
        WHERE 
            [login_name] LIKE @localServerName + N'\%';

        UPDATE @remoteMemberRoles
        SET 
            [simplified_name] = REPLACE([login_name], @remoteServerName + N'\', N'')
        WHERE 
            [login_name] LIKE @remoteServerName + N'\%';        
    END;

    -- local not in remote:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )   
    SELECT 
        N'logins' [grouping_key], 
        N'Login ' + QUOTENAME([local].[login_name]) + N' is a member of server role ' + QUOTENAME([local].[role]) + N' on server ' + QUOTENAME(@localServerName) + N' only.' [heading]
    FROM 
        @localMemberRoles [local] 
    WHERE 
        (ISNULL([local].[simplified_name], [local].[login_name]) + N'.' + [local].[role]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
            SELECT (ISNULL([simplified_name], [login_name]) + N'.' + [role]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @remoteMemberRoles
        )
        AND [local].[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
			SELECT 
				x.[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS 
			FROM 
				@localMemberRoles x 
				INNER JOIN @ignoredLoginName i ON x.[login_name] LIKE i.[name]
		);

    -- remote not in local:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )   
    SELECT 
        N'logins' [grouping_key], 
        N'Login ' + QUOTENAME([remote].[login_name]) + N' is a member of server role ' + QUOTENAME([remote].[role]) + N' on server ' + QUOTENAME(@remoteServerName) + N' only.' [heading]
    FROM 
        @remoteMemberRoles [remote] 
    WHERE 
        (ISNULL([remote].[simplified_name], [remote].[login_name]) + N'.' + [remote].[role]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
            SELECT (ISNULL([simplified_name], [login_name]) + N'.' + [role]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @localMemberRoles
        )
        AND [remote].[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
			SELECT 
				x.[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS 
			FROM 
				@remoteMemberRoles x 
				INNER JOIN @ignoredLoginName i ON x.[login_name] LIKE i.[name]
		);
    
    ---------------------------------------
	-- Endpoints? 
	--		[add if needed/desired.]

	---------------------------------------
	-- Server Level Triggers?
	--		[add if needed/desired.]

	---------------------------------------
	-- Other potential things to check/review:
	--		Audit Specs
	--		XEs 
	--		credentials/proxies
	--		service accounts (i.e., SQL Server and SQL Server Agent)
	--		perform volume maint-tasks, lock pages in memory... 
	--		etc...

	---------------------------------------
	-- Operators:
	-- local only

	DECLARE @remoteOperators table (
		[name] sysname NOT NULL,
		[enabled] tinyint NOT NULL,
		[email_address] nvarchar(100) NULL
	);

	INSERT INTO @remoteOperators ([name], [enabled], email_address)
	EXEC master.sys.sp_executesql N'SELECT [name], [enabled], email_address FROM PARTNER.msdb.dbo.sysoperators;';

    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key], 
		N'Operator ' + QUOTENAME([local].[name]) + N' exists on ' + @localServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		msdb.dbo.sysoperators [local]
		LEFT OUTER JOIN @remoteOperators [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[remote].[name] IS NULL;

	-- remote only
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key], 	
        N'Operator ' + QUOTENAME([remote].[name]) + N' exists on ' + @remoteServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteOperators [remote]
		LEFT OUTER JOIN msdb.dbo.sysoperators [local] ON [remote].[name] = [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS
	WHERE 
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS IS NULL;

	-- differences (just checking email address in this particular config):
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key], 
		N'Defintion for Operator ' + QUOTENAME([local].[name]) + N' is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		msdb.dbo.sysoperators [local]
		INNER JOIN @remoteOperators [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].[enabled] <> [remote].[enabled]
		OR [local].[email_address] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[email_address];

	---------------------------------------
	-- Alerts:
	DECLARE @ignoredAlertName TABLE (
		entry_id int IDENTITY(1,1) NOT NULL,
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredAlertName([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredAlerts, N',', 1);

	DECLARE @remoteAlerts table (
		[name] sysname NOT NULL,
		[message_id] int NOT NULL,
		[severity] int NOT NULL,
		[enabled] tinyint NOT NULL,
		[delay_between_responses] int NOT NULL,
		[notification_message] nvarchar(512) NULL,
		[include_event_description] tinyint NOT NULL,
		[database_name] nvarchar(512) NULL,
		[event_description_keyword] nvarchar(100) NULL,
		[job_id] uniqueidentifier NOT NULL,
		[has_notification] int NOT NULL,
		[performance_condition] nvarchar(512) NULL,
		[category_id] int NOT NULL
	);

	INSERT INTO @remoteAlerts ([name], message_id, severity, [enabled], delay_between_responses, notification_message, include_event_description, [database_name], event_description_keyword,
			job_id, has_notification, performance_condition, category_id)
	EXEC master.sys.sp_executesql N'SELECT [name], message_id, severity, [enabled], delay_between_responses, notification_message, include_event_description, [database_name], event_description_keyword, job_id, has_notification, performance_condition, category_id FROM PARTNER.msdb.dbo.sysalerts;';

	-- local only
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'alerts' [grouping_key], 
		N'Alert ' + QUOTENAME([local].[name]) + N' exists on ' + @localServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		msdb.dbo.sysalerts [local]
		LEFT OUTER JOIN @remoteAlerts [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE
		[remote].[name] IS NULL
		AND [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @ignoredAlertName);

    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'alerts' [grouping_key], 
		N'Alert ' + QUOTENAME([remote].[name]) + N' exists on ' + @remoteServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteAlerts [remote]
		LEFT OUTER JOIN msdb.dbo.sysalerts [local] ON [remote].[name] = [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS
	WHERE
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS IS NULL
		AND [remote].[name] NOT IN (SELECT [name] FROM @ignoredAlertName);

	-- differences:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key],  
		N'Definition for Alert ' + QUOTENAME([local].[name]) + N' is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM	
		msdb.dbo.sysalerts [local]
		INNER JOIN @remoteAlerts [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @ignoredAlertName)
		AND (
		[local].message_id <> [remote].message_id
		OR [local].severity <> [remote].severity
		OR [local].[enabled] <> [remote].[enabled]
		OR [local].delay_between_responses <> [remote].delay_between_responses
		OR [local].notification_message COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].notification_message
		OR [local].include_event_description <> [remote].include_event_description
		OR [local].[database_name] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[database_name]
		OR [local].event_description_keyword COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].event_description_keyword
		-- JobID is problematic. If we have a job set to respond, it'll undoubtedly have a diff ID from one server to the other. So... we just need to make sure ID <> 'empty' on one server, while not on the other, etc. 
		OR (
			CASE 
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 0 -- no problem
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id <> N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem - one alert is 'empty' and the other is not. 
				WHEN [local].job_id <> N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem (inverse of above). 
				WHEN ([local].job_id <> N'00000000-0000-0000-0000-000000000000' AND [remote].job_id <> N'00000000-0000-0000-0000-000000000000') AND ([local].job_id <> [remote].job_id) THEN 0 -- they're both 'non-empty' so... we assume it's good
			END 
			= 1
		)
		OR [local].has_notification <> [remote].has_notification
		OR [local].performance_condition COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].performance_condition
		OR [local].category_id <> [remote].category_id
		);

	---------------------------------------
	-- Objects in Master Database:  
	DECLARE @localMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	DECLARE @ignoredMasterObjects TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredMasterObjects([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredMasterDbObjects, N',', 1);

	INSERT INTO @localMasterObjects ([object_name])
	SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM master.sys.objects WHERE [type] IN ('U','V','P','FN','IF','TF') AND is_ms_shipped = 0 AND [name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @ignoredMasterObjects);
	
	DECLARE @remoteMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	INSERT INTO @remoteMasterObjects ([object_name])
	EXEC master.sys.sp_executesql N'SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;';
	DELETE FROM @remoteMasterObjects WHERE [object_name] IN (SELECT [name] FROM @ignoredMasterObjects);

	-- local only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'master objects' [grouping_key], 
		N'Object ' + QUOTENAME([local].[object_name]) + N' exists in the master database on ' + @localServerName + N' only.'  [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@localMasterObjects [local]
		LEFT OUTER JOIN @remoteMasterObjects [remote] ON [local].[object_name] = [remote].[object_name]
	WHERE
		[remote].[object_name] IS NULL;
	
	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'master objects' [grouping_key], 
		N'Object ' + QUOTENAME([remote].[object_name]) + N' exists in the master database on ' + @remoteServerName + N' only.'  [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteMasterObjects [remote]
		LEFT OUTER JOIN @localMasterObjects [local] ON [remote].[object_name] = [local].[object_name]
	WHERE
		[local].[object_name] IS NULL;

	CREATE TABLE #Definitions (
		row_id int IDENTITY(1,1) NOT NULL, 
		[location] sysname NOT NULL, 
		[object_name] sysname NOT NULL, 
		[type] char(2) NOT NULL,
		[hash] varbinary(MAX) NULL
	);

	INSERT INTO #Definitions ([location], [object_name], [type], [hash])
	SELECT 
		'local', 
		[name], 
		[type], 
		CASE 
			WHEN [type] IN ('V','P','FN','IF','TF') THEN 
				CASE
					-- HASHBYTES barfs on > 8000 chars. So, using this: http://www.sqlnotes.info/2012/01/16/generate-md5-value-from-big-data/
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
					ELSE HASHBYTES('SHA1', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		master.sys.objects o
		LEFT OUTER JOIN master.sys.sql_modules sm ON o.[object_id] = sm.[object_id]
		INNER JOIN @localMasterObjects x ON o.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[object_name];

	DECLARE localtabler CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'local';

	DECLARE @currentObjectName sysname;
	DECLARE @checksum bigint = 0;

	OPEN localtabler;
	FETCH NEXT FROM localtabler INTO @currentObjectName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0;

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		SELECT @checksum = @checksum + [local].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.[name], c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM master.sys.columns c INNER JOIN master.sys.objects o ON o.object_id = c.object_id WHERE o.[name] = @currentObjectName
		) [local];

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'local';

		FETCH NEXT FROM localtabler INTO @currentObjectName;
	END 

	CLOSE localtabler;
	DEALLOCATE localtabler;

	INSERT INTO #Definitions ([location], [object_name], [type], [hash])
	EXEC master.sys.sp_executesql N'SELECT 
		''remote'', 
		o.[name], 
		[type], 
		CASE 
			WHEN [type] IN (''V'',''P'',''FN'',''IF'',''TF'') THEN 
				CASE
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
					ELSE HASHBYTES(''SHA1'', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		PARTNER.master.sys.objects o
		LEFT OUTER JOIN PARTNER.master.sys.sql_modules sm ON o.object_id = sm.object_id
		INNER JOIN (SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0) x ON o.[name] = x.[name];';

	DECLARE remotetabler CURSOR LOCAL FAST_FORWARD FOR
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'remote';

	OPEN remotetabler;
	FETCH NEXT FROM remotetabler INTO @currentObjectName; 

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0; -- otherwise, it'll get passed into sp_executesql with the PREVIOUS value.... 

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		EXEC master.sys.sp_executesql N'SELECT @checksum = ISNULL(@checksum,0) + [remote].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.[name], c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM PARTNER.master.sys.columns c INNER JOIN PARTNER.master.sys.objects o ON o.object_id = c.object_id WHERE o.[name] = @currentObjectName
		) [remote];', N'@checksum bigint OUTPUT, @currentObjectName sysname', @checksum = @checksum OUTPUT, @currentObjectName = @currentObjectName;

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'remote';

		FETCH NEXT FROM remotetabler INTO @currentObjectName; 
	END 

	CLOSE remotetabler;
	DEALLOCATE remotetabler;

    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'master objects' [grouping_key], 
		N'The Definition for object ' + QUOTENAME([local].[object_name]) + N' (in the master database) is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		(SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'local') [local]
		INNER JOIN (SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'remote') [remote] ON [local].object_name = [remote].object_name
	WHERE 
		[local].[hash] <> [remote].[hash];
	
	------------------------------------------------------------------------------
	-- Report on any discrepancies: 
REPORTING:
	IF(SELECT COUNT(*) FROM #bus) > 0 BEGIN 

		DECLARE @subject nvarchar(300) = N'SQL Server Synchronization Check Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = N'The following synchronization issues were detected: ' + @crlf + @crlf;

        SELECT 
            @message = @message + @tab +  UPPER([channel]) + N': ' + [heading] + CASE WHEN [body] IS NOT NULL THEN @crlf + @tab + @tab + ISNULL([body], N'') ELSE N'' END + @crlf + @crlf
        FROM 
            #bus
        ORDER BY 
            [row_id];


		IF @PrintOnly = 1 BEGIN 
			-- just Print out details:
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;

		  END
		ELSE BEGIN
			-- send a message:
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject,
				@body = @message;
		END;

	END 

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_data_synchronization','P') IS NOT NULL
	DROP PROC dbo.verify_data_synchronization;
GO

CREATE PROC dbo.verify_data_synchronization 
	@IgnoredDatabases						nvarchar(MAX)		= NULL,
	@RPOThreshold							sysname				= N'10 seconds',
	@RTOThreshold							sysname				= N'40 seconds',
	
	@AGSyncCheckIterationCount				int					= 8, 
	@AGSyncCheckDelayBetweenChecks			sysname				= N'1800 milliseconds',
	@ExcludeAnomolousSyncDeviations			bit					= 0,    -- Primarily for Ghosted Records Cleanup... 
	
	@EmailSubjectPrefix						nvarchar(50)		= N'[Data Synchronization Problems] ',
	@MailProfileName						sysname				= N'General',	
	@OperatorName							sysname				= N'Alerts',	
	@PrintOnly								bit					= 0
AS
	SET NOCOUNT ON;

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	---------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END;

	EXEC @return = dbo.verify_partner 
		@Error = @returnMessage OUTPUT; 

	IF @return <> 0 BEGIN 
		-- S4-229: this (current) response is a hack - i.e., sending email/message DIRECTLY from this code-block violates DRY
		--			and is only in place until dbo.verify_job_synchronization is rewritten to use a process bus.
		IF @PrintOnly = 1 BEGIN 
			PRINT 'PARTNER is disconnected/non-accessible. Terminating early. Connection Details/Error:';
			PRINT '     ' + @returnMessage;
		  END;
		ELSE BEGIN 
			DECLARE @hackSubject nvarchar(200), @hackMessage nvarchar(MAX);
			SELECT 
				@hackSubject = N'PARTNER server is down/non-accessible.', 
				@hackMessage = N'Job Synchronization Checks can not continue as PARTNER server is down/non-accessible. Connection Error Details: ' + NCHAR(13) + NCHAR(10) + @returnMessage; 

			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @hackSubject,
				@body = @hackMessage;
		END;

		RETURN 0;
	END;

	----------------------------------------------
	-- Determine which server to run checks on. 
	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;
        
    ----------------------------------------------
	-- Determine the last time this job ran: 
    DECLARE @lastCheckupExecutionTime datetime;
    EXEC [dbo].[get_last_job_completion_by_session_id] 
        @SessionID = @@SPID, 
        @ExcludeFailures = 1, 
        @LastTime = @lastCheckupExecutionTime OUTPUT; 

    SET @lastCheckupExecutionTime = ISNULL(@lastCheckupExecutionTime, DATEADD(HOUR, -2, GETDATE()));

    IF DATEDIFF(DAY, @lastCheckupExecutionTime, GETDATE()) > 2
        SET @lastCheckupExecutionTime = DATEADD(HOUR, -2, GETDATE())

    DECLARE @syncCheckSpanMinutes int = DATEDIFF(MINUTE, @lastCheckupExecutionTime, GETDATE());

    IF @syncCheckSpanMinutes <= 1 
        RETURN 0; -- no sense checking on history if it's just been a minute... 
    
	-- convert vectors to seconds: 
	DECLARE @rpoSeconds decimal(20, 2);
	DECLARE @rtoSeconds decimal(20, 2);

	DECLARE @vectorOutput bigint, @vectorError nvarchar(max); 
    EXEC dbo.translate_vector 
        @Vector = @RPOThreshold, 
        @Output = @vectorOutput OUTPUT, -- milliseconds
		@ProhibitedIntervals = N'DAY, WEEK, MONTH, QUARTER, YEAR',
        @Error = @vectorError OUTPUT; 

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -1;
	END;

	SET @rpoSeconds = @vectorOutput / 1000.0;
	
    EXEC dbo.translate_vector 
        @Vector = @RTOThreshold, 
        @Output = @vectorOutput OUTPUT, -- milliseconds
		@ProhibitedIntervals = N'DAY, WEEK, MONTH, QUARTER, YEAR',
        @Error = @vectorError OUTPUT; 

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -1;
	END;

	SET @rtoSeconds = @vectorOutput / 1000.0;

	IF @rtoSeconds > 2764800.0 OR @rpoSeconds > 2764800.0 BEGIN 
		RAISERROR(N'@RPOThreshold and @RTOThreshold values can not be set to > 1 month.', 16, 1);
		RETURN -10;
	END;

	IF @rtoSeconds < 2.0 OR @rpoSeconds < 2.0 BEGIN 
		RAISERROR(N'@RPOThreshold and @RTOThreshold values can not be set to less than 2 seconds.', 16, 1);
		RETURN -10;
	END;

	-- translate @AGSyncCheckDelayBetweenChecks into waitfor value. 
	DECLARE @waitFor sysname;
	SET @vectorError = NULL;

	EXEC dbo.[translate_vector_delay] 
		@Vector = @AGSyncCheckDelayBetweenChecks, 
		@ParameterName = N'@AGSyncCheckDelayBetweenChecks', 
		@Output = @waitFor OUTPUT, 
		@Error = @vectorError OUTPUT;

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -20;
	END;

    ----------------------------------------------
    -- Begin Processing: 
	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', 
		N'@remoteName sysname OUTPUT', 
		@remoteName = @remoteServerName OUTPUT;

	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		[server_name] sysname, 
		[sync_type] sysname,
		[database_name] sysname, 
		[role] sysname
	);

	-- grab a list of SYNCHRONIZING (primary) databases (excluding any we're instructed to NOT watch/care about):
	INSERT INTO @synchronizingDatabases (
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	)
	SELECT 
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	FROM 
		dbo.list_synchronizing_databases(@IgnoredDatabases, 1);

	----------------------------------------------
	DECLARE @errors TABLE (
		error_id int IDENTITY(1,1) NOT NULL,
		errorMessage nvarchar(MAX) NOT NULL
	);

	-- http://msdn.microsoft.com/en-us/library/ms366320(SQL.105).aspx
	DECLARE @output TABLE ( 
		[database_name] sysname,
		[role] int, 
		mirroring_state int, 
		witness_status int, 
		log_generation_rate int, 
		unsent_log int, 
		send_rate int, 
		unrestored_log int, 
		recovery_rate int,
		transaction_delay int,
		transactions_per_sec int, 
		average_delay int, 
		time_recorded datetime,
		time_behind datetime,
		local_time datetime
	);

	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @transdelayMilliseconds int;
	DECLARE @averagedelay int;

	----------------------------------------------
	-- Process Mirrored Databases: 
	DECLARE m_checker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@synchronizingDatabases
	WHERE 
		[sync_type] = N'MIRRORED'
	ORDER BY 
		[database_name];

	DECLARE @currentMirroredDB sysname;

	OPEN m_checker;
	FETCH NEXT FROM m_checker INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		DELETE FROM @output;
		SET @errorMessage = N'';

		-- Force an explicit update of the mirroring stats - so that we get the MOST recent details:
		EXEC msdb.sys.sp_dbmmonitorupdate @database_name = @currentMirroredDB;

		INSERT INTO @output
		EXEC msdb.sys.sp_dbmmonitorresults 
			@database_name = @currentMirroredDB,
			@mode = 0, -- just give us the last row - to check current status
			@update_table = 0;  -- This SHOULD be set to 1 - but can/will cause issues with 'nested' INSERT EXEC calls (i.e., a bit of a 'bug'). So... the previous call updates... and we just read the recently updated results. 
		
		IF (SELECT COUNT(*) FROM @output) < 1 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Monitoring not working correctly.'
				+ @crlf + @tab + @tab + N'Database Mirroring Monitoring Failure for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';
				
			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END; 

		IF (SELECT TOP(1) mirroring_state FROM @output) <> 4 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Mirroring Disabled'
				+ @crlf + @tab + @tab + N'Synchronization Failure for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END

		-- check on the witness if needed:
		IF EXISTS (SELECT mirroring_witness_state_desc FROM sys.database_mirroring WHERE database_id = DB_ID(@currentMirroredDB) AND NULLIF(mirroring_witness_state_desc, N'UNKNOWN') IS NOT NULL) BEGIN 
			IF (SELECT TOP(1) witness_status FROM @output) <> 1 BEGIN
				SET @errorMessage = N'Mirroring Failure - Witness Down'
					+ @crlf + @tab + @tab + N'Witness Failure. Witness is currently not enabled or monitoring for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';

				INSERT INTO @errors (errorMessage)
				VALUES (@errorMessage);
			END;
		END;

		DELETE FROM @output; 
		INSERT INTO @output
		EXEC msdb.sys.sp_dbmmonitorresults 
			@database_name = @currentMirroredDB,
			@mode = 1,  -- give us rows from the last 2 hours:
			@update_table = 0;

		-- make sure that metrics are even working - if we get any NULLs in transaction_delay/average_delay, 
		--		then it's NOT working correctly (i.e. it's somehow not seeing everything it needs to in order
		--		to report - and we need to throw an error):
		SELECT @transdelayMilliseconds = MIN(ISNULL(transaction_delay,-1)) FROM	@output 
		WHERE local_time >= @lastCheckupExecutionTime;

		IF @transdelayMilliseconds < 0 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Synchronization Metrics Unavailable'
				+ @crlf + @tab + @tab + N'Metrics for transaction_delay and average_delay unavailable for monitoring (i.e., SQL Server Mirroring Monitor is ''busted'') for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END;

		-- check for problems with transaction delay:
		SELECT @transdelayMilliseconds = MAX(ISNULL(transaction_delay,0)) FROM @output
		WHERE local_time >= @lastCheckupExecutionTime;
		IF @transdelayMilliseconds > (@rpoSeconds * 1000.0) BEGIN 
			SET @errorMessage = N'Mirroring Alert - Delays Applying Data to Secondary'
				+ @crlf + @tab + @tab + N'Max Trans Delay of ' + CAST(@transdelayMilliseconds AS nvarchar(30)) + N'ms in last ' + CAST(@syncCheckSpanMinutes as sysname) + N' minutes is greater than allowed threshold of ' + CAST((@rpoSeconds * 1000.0) as sysname) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 

		-- check for problems with transaction delays on the primary:
		SELECT @averagedelay = MAX(ISNULL(average_delay,0)) FROM @output
		WHERE local_time >= @lastCheckupExecutionTime;
		IF @averagedelay > (@rtoSeconds * 1000.0) BEGIN 

			SET @errorMessage = N'Mirroring Alert - Transactions Delayed on Primary'
				+ @crlf + @tab + @tab + N'Max(Avg) Trans Delay of ' + CAST(@averagedelay AS nvarchar(30)) + N'ms in last ' + CAST(@syncCheckSpanMinutes as sysname) + N' minutes is greater than allowed threshold of ' + CAST((@rtoSeconds * 1000.0) as sysname) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 		

		FETCH NEXT FROM m_checker INTO @currentMirroredDB;
	END;

	CLOSE m_checker; 
	DEALLOCATE m_checker;
	
	----------------------------------------------
	-- Process AG'd Databases: 
	IF (SELECT dbo.[get_engine_version]()) <= 10.5
		GOTO REPORTING;

	DECLARE @downNodes nvarchar(MAX);
	DECLARE @currentAGName sysname;
	DECLARE @currentAGId uniqueidentifier;
	DECLARE @syncHealth tinyint;

	DECLARE @processedAgs table ( 
		agname sysname NOT NULL
	);

	DECLARE ag_checker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@synchronizingDatabases
	WHERE 
		[sync_type] = N'AG'
	ORDER BY 
		[database_name];

	DECLARE @currentAGdDatabase sysname; 

	OPEN ag_checker;
	FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN 
	
		SET @currentAGName = N'';
		SET @currentAGId = NULL;
		EXEC sys.sp_executesql N'SELECT @currentAGName = ag.[name], @currentAGId = ag.group_id FROM sys.availability_groups ag INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id INNER JOIN sys.databases d ON ar.replica_id = d.replica_id WHERE d.[name] = @currentAGdDatabase;', 
			N'@currentAGdDatabase sysname, @currentAGName sysname OUTPUT, @currentAGId uniqueidentifier OUTPUT', 
			@currentAGdDatabase = @currentAGdDatabase, 
			@currentAGName = @currentAGName OUTPUT, 
			@currentAGId = @currentAGId OUTPUT;

		IF NOT EXISTS (SELECT NULL FROM @processedAgs WHERE agname = @currentAGName) BEGIN
		
			-- Make sure there's an active primary:
-- TODO: in this new, streamlined, code... this check (at this point) is pointless. 
--		need to check this well before we get to the CURSOR for processing AGs, AG'd dbs... 
--			also, there might be a quicker/better way to get a 'list' of all dbs in a 'bad' (non-primary'd) state right out of the gate. 
--			AND, either way I slice it, i'll have to tackle this via sp_executesql - to account for lower-level servers. 
			--SELECT @primaryReplica = agstates.primary_replica
			--FROM sys.availability_groups ag 
			--LEFT OUTER JOIN sys.dm_hadr_availability_group_states agstates ON ag.group_id = agstates.group_id
			--WHERE 
			--	ag.[name] = @currentAGdDatabase;
			
			--IF ISNULL(@primaryReplica,'') = '' BEGIN 
			--	SET @errorMessage = N'MAJOR PROBLEM: No Replica is currently defined as the PRIMARY for Availability Group [' + @currentAG + N'].';

			--	INSERT INTO @errors (errorMessage)
			--	VALUES(@errorMessage);
			--END 

			-- Check on Status of all members:
			SET @downNodes = N'';
			EXEC master.sys.sp_executesql N'SELECT @downNodes = @downNodes +  member_name + N'','' FROM sys.dm_hadr_cluster_members WHERE member_state <> 1;', N'@downNodes nvarchar(MAX) OUTPUT', @downNodes = @downNodes OUTPUT; 
			IF LEN(@downNodes) > LEN(N'') BEGIN 
				SET @downNodes = LEFT(@downNodes, LEN(@downNodes) - 1); 
			
				SET @errorMessage = N'WARNING: The following WSFC Cluster Member Nodes are currently being reported as offline: ' + @downNodes + N'.';	

				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END

			-- Check on AG Health Status: 
			SET @syncHealth = 0;
			EXEC master.sys.sp_executesql N'SELECT @syncHealth = synchronization_health FROM sys.dm_hadr_availability_replica_states WHERE group_id = @currentAGId;', N'@currentAGId uniqueidentifier, @syncHealth tinyint OUTPUT', @currentAGId = @currentAGId, @syncHealth = @syncHealth OUTPUT;
			IF @syncHealth <> 2 BEGIN
				SELECT @errorMessage = N'WARNING: Current Health Status of Availability Group [' + @currentAGName + N'] Is Showing NON-HEALTHY.'
			
				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END; 

			-- Check on Synchronization Status of each db:
			SET @syncHealth = 0;
			EXEC master.sys.sp_executesql N'SELECT @syncHealth = synchronization_health FROM sys.dm_hadr_availability_replica_states WHERE group_id = @currentAGId;', N'@currentAGId uniqueidentifier, @syncHealth tinyint OUTPUT', @currentAGId = @currentAGId, @syncHealth = @syncHealth OUTPUT;
			IF @syncHealth <> 2 BEGIN
				SELECT @errorMessage = N'WARNING: The Synchronization Status for one or more Members of the Availability Group [' + @currentAGName + N'] Is Showing NON-HEALTHY.'
			
				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END;

			-- mark the current AG as processed (so that we don't bother processing multiple dbs (and getting multiple errors/messages) if/when they're all in the same AG(s)). 
			INSERT INTO @processedAgs ([agname])
			VALUES(@currentAGName);
		END;
		-- otherwise, we've already run checks on the availability group itself. 

		FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;
	END;

	CLOSE ag_checker;
	DEALLOCATE ag_checker;

	IF EXISTS (SELECT NULL FROM @synchronizingDatabases WHERE [sync_type] = N'AG') BEGIN

		CREATE TABLE [#metrics] (
			[row_id] int IDENTITY(1, 1) NOT NULL,
			[database_name] sysname NOT NULL,
			[iteration] int NOT NULL,
			[timestamp] datetime NOT NULL,
			[synchronization_delay (RPO)] decimal(20, 2) NOT NULL,
			[recovery_time (RTO)] decimal(20, 2) NOT NULL,
			-- raw data: 
			[redo_queue_size] decimal(20, 2) NULL,
			[redo_rate] decimal(20, 2) NULL,
			[primary_last_commit] datetime NULL,
			[secondary_last_commit] datetime NULL, 
			[ignore_rpo_as_anomalous] bit NOT NULL CONSTRAINT DF_metrics_anomalous DEFAULT (0)
		);

		DECLARE @agSyncCheckSQL nvarchar(MAX) = N'
			WITH [metrics] AS (
				SELECT
					[adc].[database_name],
					[drs].[last_commit_time],
					CAST([drs].[redo_queue_size] AS decimal(20,2)) [redo_queue_size],   -- KB of log data not yet ''checkpointed'' on the secondary... 
					CAST([drs].[redo_rate] AS decimal(20,2)) [redo_rate],		-- avg rate (in KB) at which redo (i.e., inverted checkpoints) are being applied on the secondary... 
					[drs].[is_primary_replica] [is_primary]
				FROM
					[sys].[dm_hadr_database_replica_states] AS [drs]
					INNER JOIN [sys].[availability_databases_cluster] AS [adc] ON [drs].[group_id] = [adc].[group_id] AND [drs].[group_database_id] = [adc].[group_database_id]
			), 
			[primary] AS ( 
				SELECT
					[database_name],
					[last_commit_time] [primary_last_commit]
				FROM
					[metrics]
				WHERE
					[is_primary] = 1

			), 
			[secondary] AS ( 
				SELECT
					[database_name],
					[last_commit_time] [secondary_last_commit], 
					[redo_rate], 
					[redo_queue_size]
				FROM
					[metrics]
				WHERE
					[is_primary] = 0
			) 

			SELECT 
				p.[database_name], 
				@iterations [iteration], 
				GETDATE() [timestamp],
				DATEDIFF(SECOND, ISNULL(s.[secondary_last_commit], GETDATE()), ISNULL(p.[primary_last_commit], DATEADD(MINUTE, -10, GETDATE()))) [synchronization_delay (RPO)],
				CAST((CASE 
					WHEN s.[redo_queue_size] = 0 THEN 0 
					ELSE ISNULL(s.[redo_queue_size], 0) / s.[redo_rate]
				END) AS decimal(20, 2)) [recovery_time (RTO)],
				s.[redo_queue_size], 
				s.[redo_rate], 
				p.[primary_last_commit], 
				s.[secondary_last_commit]
			FROM 
				[primary] p 
				INNER JOIN [secondary] s ON p.[database_name] = s.[database_name]; ';

		DECLARE @iterations int = 1; 
		WHILE @iterations < @AGSyncCheckIterationCount BEGIN

			INSERT INTO [#metrics] (
				[database_name],
				[iteration],
				[timestamp],
				[synchronization_delay (RPO)],
				[recovery_time (RTO)],
				[redo_queue_size],
				[redo_rate],
				[primary_last_commit],
				[secondary_last_commit]
			)
			EXEC sp_executesql 
				@agSyncCheckSQL, 
				N'@iterations int', 
				@iterations = @iterations;				

			WAITFOR DELAY @waitFor;

			SET @iterations += 1;
		END;

		IF @ExcludeAnomolousSyncDeviations = 1 BEGIN 

			WITH derived AS ( 

				SELECT 
					[database_name],
					CAST(MAX([synchronization_delay (RPO)]) AS decimal(20, 2)) [max],
					CAST(AVG([synchronization_delay (RPO)]) AS decimal(20, 2)) [mean], 
					CAST(STDEV([synchronization_delay (RPO)]) AS decimal(20, 2)) [deviation]
				FROM 
					[#metrics] 
				GROUP BY 
					[database_name]

			), 
			db_iterations AS ( 
	
				SELECT 
					(
						SELECT TOP 1 x.row_id 
						FROM [#metrics] x 
						WHERE x.[synchronization_delay (RPO)] = d.[max] AND [x].[database_name] = d.[database_name] 
						ORDER BY x.[synchronization_delay (RPO)] DESC
					) [row_id]
				FROM 
					[derived] d
				WHERE 
					d.mean - d.[deviation] < 0 -- biz-rule - only if/when deviation 'knocks everything' negative... 
					AND d.[max] > ([d].[mean] + d.[deviation] + ABS([d].[mean] - d.[deviation]))
			)

			UPDATE m 
			SET 
				m.[ignore_rpo_as_anomalous] = 1 
			FROM 
				[#metrics] m 
				INNER JOIN [db_iterations] x ON m.[row_id] = x.[row_id];
		END;

		WITH violations AS ( 
			SELECT 
				[database_name],
				CAST(AVG([synchronization_delay (RPO)]) AS decimal(20, 2)) [rpo (seconds)],
				CAST(AVG([recovery_time (RTO)]) AS decimal(20,2 )) [rto (seconds)], 
				CAST((
					SELECT 
						[x].[iteration] [@iteration], 
						[x].[timestamp] [@timestamp],
						[x].[ignore_rpo_as_anomalous],
						[x].[synchronization_delay (RPO)] [rpo], 
						[x].[recovery_time (RTO)] [rto],
						[x].[redo_queue_size], 
						[x].[redo_rate], 
						[x].[primary_last_commit], 
						[x].[secondary_last_commit]
					FROM 
						[#metrics] x 
					WHERE 
						x.[database_name] = m.[database_name]
					ORDER BY 
						[x].[row_id] 
					FOR XML PATH('detail'), ROOT('details')
				) AS xml) [raw_data]
			FROM 
				[#metrics] m
			WHERE 
				m.[ignore_rpo_as_anomalous] = 0  -- note: these don't count towards rpo values - but they ARE included in serialized xml output (for review/analysis purposes). 
			GROUP BY
				[database_name]
		) 

		INSERT INTO @errors (
			[errorMessage]
		)
		SELECT 
			N'AG Alert - SLA Warning(s) for ' + QUOTENAME([database_name]) + @crlf + @tab + @tab + N'RPO and RTO values are currently set at [' + @RPOThreshold + N'] and [' + @RTOThreshold + N'] - but are currently polling at an AVERAGE of [' + CAST([rpo (seconds)] AS sysname) + N' seconds] AND [' + CAST([rto (seconds)] AS sysname) + N' seconds] for database ' + QUOTENAME([database_name])  + N'. Raw XML Data: ' + CAST([raw_data] AS nvarchar(MAX))
		FROM 
			[violations]
		WHERE 
			[violations].[rpo (seconds)] > @rpoSeconds OR [violations].[rto (seconds)] > @rtoSeconds
		ORDER BY 
			[database_name];

	END;

REPORTING:
	-- 
	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';

		SET @errorMessage = N'The following errors were detected: ' + @crlf;

		SELECT @errorMessage = @errorMessage + @tab + N'- ' + errorMessage + @crlf
		FROM @errors
		ORDER BY error_id;

		IF @PrintOnly = 1 BEGIN
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @errorMessage;
		  END
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.add_synchronization_partner','P') IS NOT NULL
	DROP PROC dbo.[add_synchronization_partner];
GO

CREATE PROC dbo.[add_synchronization_partner]
    @PartnerName                            sysname		= NULL,			-- hard-coded name of partner - e.g., SQL2 (if we're running on SQL1).
	@PartnerNames							sysname		= NULL,			-- specify 2x server names, e.g., SQL1 and SQL2 - and the sproc will figure out self and partner accordingly. 
    @ExecuteSetupOnPartnerServer            bit         = 1     -- by default, attempt to create a 'PARTNER' on the PARTNER, that... points back here... 
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    -- TODO: verify @PartnerName input/parameters. 
	SET @PartnerName = NULLIF(@PartnerName, N'');
	SET @PartnerNames = NULLIF(@PartnerNames, N'');

	IF @PartnerName IS NULL AND @PartnerNames IS NULL BEGIN 
		RAISERROR('Please Specify a value for either @PartnerName (e.g., ''SQL2'' if executing on SQL1) or for @PartnerNames (e.g., ''SQL1,SQL2'' if running on either SQL1 or SQL2).', 16, 1);
		RETURN - 2;
	END;

	IF @PartnerName IS NULL BEGIN 
		DECLARE @serverNames table ( 
			server_name sysname NOT NULL
		);

		INSERT INTO @serverNames (
			server_name
		)
		SELECT CAST([result] AS sysname) FROM dbo.[split_string](@PartnerNames, N',', 1);

		DELETE FROM @serverNames WHERE [server_name] = @@SERVERNAME;

		IF(SELECT COUNT(*) FROM @serverNames) <> 1 BEGIN
			RAISERROR('Invalid specification for @PartnerNames specified - please specify 2 server names, where one is the name of the currently executing server.', 16, 1);
			RETURN -10;
		END;

		SET @PartnerName = (SELECT TOP 1 server_name FROM @serverNames);
	END;

    -- TODO: account for named instances... 
    DECLARE @remoteHostName sysname = N'tcp:' + @PartnerName;
    DECLARE @errorMessage nvarchar(MAX);
    DECLARE @serverName sysname = @@SERVERNAME;

    IF EXISTS (SELECT NULL FROM sys.servers WHERE UPPER([name]) = N'PARTNER') BEGIN 
        RAISERROR('A definition for PARTNER already exists as a Linked Server.', 16, 1);
        RETURN -1;
    END;

    BEGIN TRY
        EXEC master.dbo.sp_addlinkedserver 
	        @server = N'PARTNER', 
	        @srvproduct = N'', 
	        @provider = N'SQLNCLI', 
	        @datasrc = @remoteHostName, 
	        @catalog = N'master';

        EXEC master.dbo.sp_addlinkedsrvlogin 
	        @rmtsrvname = N'PARTNER',
	        @useself = N'True',
	        @locallogin = NULL,
	        @rmtuser = NULL,
	        @rmtpassword = NULL;

        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc', 
	        @optvalue = N'true';

        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc out', 
	        @optvalue = N'true';

        
        PRINT 'Definition for PARTNER server (pointing to ' + @PartnerName + N') successfully registered on ' + @serverName + N'.';

    END TRY 
    BEGIN CATCH 
        SELECT @errorMessage = N'Unexepected error while attempting to create definition for PARTNER on local/current server. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
        RAISERROR(@errorMessage, 16, 1);
        RETURN -20;
    END CATCH;

    IF @ExecuteSetupOnPartnerServer = 1 BEGIN
        DECLARE @localHostName sysname = @@SERVERNAME;

        DECLARE @command nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.add_synchronization_partner @localHostName, 0;';

        BEGIN TRY 
            EXEC sp_executesql 
                @command, 
                N'@localHostName sysname', 
                @localHostName = @localHostName;

        END TRY 

        BEGIN CATCH
            SELECT @errorMessage = N'Unexepected error while attempting to DYNAMICALLY create definition for PARTNER on remote/partner server. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -40;

        END CATCH;
    END;

    RETURN 0;
GO    


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.add_failover_processing','P') IS NOT NULL
	DROP PROC dbo.[add_failover_processing];
GO

CREATE PROC dbo.[add_failover_processing]
    @SqlServerAgentFailoverResponseJobName              sysname         = N'Synchronization - Failover Response',
    @SqlServerAgentJobNameCategory                      sysname         = N'Synchronization',
	@MailProfileName			                        sysname         = N'General',
	@OperatorName				                        sysname         = N'Alerts', 
    @ExecuteSetupOnPartnerServer                        bit = 1
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
    
    DECLARE @errorMessage nvarchar(MAX);

    -- enable logging on 1480 - if needed. 
    IF EXISTS (SELECT NULL FROM sys.messages WHERE [message_id] = 1480 AND [is_event_logged] = 0) BEGIN
        BEGIN TRY 
            EXEC master..sp_altermessage
	            @message_id = 1480, 
                @parameter = 'WITH_LOG', 
                @parameter_value = TRUE;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected problem enabling message_id 1480 for WITH_LOG on server [' + @@SERVERNAME + N'. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -10;
        END CATCH;
    END;

    -- job creation: 
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.syscategories WHERE [name] = @SqlServerAgentJobNameCategory AND category_class = 1) BEGIN
        
        BEGIN TRY
            EXEC msdb.dbo.sp_add_category 
                @class = N'JOB', 
                @type = N'LOCAL', 
                @name = @SqlServerAgentJobNameCategory;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected problem creating job category [' + @SqlServerAgentJobNameCategory + N'] on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -20;
        END CATCH;
    END;

    DECLARE @jobID uniqueidentifier;
    DECLARE @failoverHandlerCommand nvarchar(MAX) = N'EXEC [admindb].dbo.process_synchronization_failover{CONFIGURATION};
GO'

    IF UPPER(@OperatorName) = N'ALERTS' AND UPPER(@MailProfileName) = N'GENERAL' 
        SET @failoverHandlerCommand = REPLACE(@failoverHandlerCommand, N'{CONFIGURATION}', N'');
    ELSE 
        SET @failoverHandlerCommand = REPLACE(@failoverHandlerCommand, N'{CONFIGURATION}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N'@MailProfileName = ''' + @MailProfileName + N''', @OperatorName = ''' + @OperatorName + N''' ');

    BEGIN TRANSACTION;

    BEGIN TRY

        EXEC msdb.dbo.[sp_add_job]
            @job_name = @SqlServerAgentFailoverResponseJobName,
            @enabled = 1,
            @description = N'Automatically executed in response to a synchronized database failover event.',
            @category_name = @SqlServerAgentJobNameCategory,
            @owner_login_name = N'sa',
            @notify_level_email = 2,
            @notify_email_operator_name = @OperatorName,
            @delete_level = 0,
            @job_id = @jobID OUTPUT;

        -- TODO: might need a version check here... i.e., this behavior is new to ... 2017? (possibly 2016?) (or I'm on drugs) (eithe way, NOT clearly documented as of 2019-07-29)
        EXEC msdb.dbo.[sp_add_jobserver] 
            @job_name = @SqlServerAgentFailoverResponseJobName, 
            @server_name = N'(LOCAL)';

        EXEC msdb.dbo.[sp_add_jobstep]
            @job_name = @SqlServerAgentFailoverResponseJobName, 
            @step_id = 1,
            @step_name = N'Respond to Failover',
            @subsystem = N'TSQL',
            @command = @failoverHandlerCommand,
            @cmdexec_success_code = 0,
            @on_success_action = 1,
            @on_success_step_id = 0,
            @on_fail_action = 2,
            @on_fail_step_id = 0,
            @database_name = N'admindb',
            @flags = 0;
    
        COMMIT TRANSACTION;
    END TRY 
    BEGIN CATCH 
        SELECT @errorMessage = N'Unexpected error creating failover response-handling job on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
        RAISERROR(@errorMessage, 16, 1);
        ROLLBACK TRANSACTION;
        RETURN -25;
    END CATCH;

    -- enable alerts - and map to job: 
    BEGIN TRY 
		DECLARE @1480AlertName sysname = N'1480 - Partner Role Change';

        IF EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE [message_id] = 1480 AND [name] = @1480AlertName)
            EXEC msdb.dbo.[sp_delete_alert] @name = N'1480 - Partner Role Change';

        EXEC msdb.dbo.[sp_add_alert]
            @name = @1480AlertName,
            @message_id = 1480,
            @enabled = 1,
            @delay_between_responses = 5,
            @include_event_description_in = 0,
            @job_name = @SqlServerAgentFailoverResponseJobName;
    END TRY 
    BEGIN CATCH 
        SELECT @errorMessage = N'Unexpected error mapping Alert 1480 to response-handling job on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
        RAISERROR(@errorMessage, 16, 1);
        RETURN -30;
    END CATCH;

    IF @ExecuteSetupOnPartnerServer = 1 BEGIN

        DECLARE @command nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.[add_failover_processing]
    @SqlServerAgentFailoverResponseJobName = @SqlServerAgentFailoverResponseJobName,
    @SqlServerAgentJobNameCategory = @SqlServerAgentJobNameCategory,      
    @MailProfileName = @MailProfileName,
    @OperatorName =  @OperatorName,				          
    @ExecuteSetupOnPartnerServer = 0; ';

        BEGIN TRY 
            EXEC sp_executesql 
                @command, 
                N'@SqlServerAgentFailoverResponseJobName sysname, @SqlServerAgentJobNameCategory sysname, @MailProfileName sysname, @OperatorName sysname', 
                @SqlServerAgentFailoverResponseJobName = @SqlServerAgentFailoverResponseJobName, 
                @SqlServerAgentJobNameCategory = @SqlServerAgentJobNameCategory, 
                @MailProfileName = @MailProfileName, 
                @OperatorName = @OperatorName;

        END TRY
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexected error while attempting to create job [' + @SqlServerAgentFailoverResponseJobName + N'] on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1); 
            RETURN -30;
        END CATCH;
    END;
    
    RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.create_sync_check_jobs','P') IS NOT NULL
	DROP PROC dbo.[create_sync_check_jobs];
GO

CREATE PROC dbo.[create_sync_check_jobs]
	@Action											sysname				= N'TEST',				-- 'TEST | CREATE' are the 2x options - i.e., test/output what we'd see... or ... create the jobs. 	
	@ServerAndJobsSyncCheckJobStart					sysname				= N'00:01:00', 
	@DataSyncCheckJobStart							sysname				= N'00:03:00', 
	@TimeZoneForUtcOffset							sysname				= NULL,					-- IF the server is running on UTC time, this is the time-zone you want to adjust backups to (i.e., 2AM UTC would be 4PM pacific - not a great time for full backups. Values ...   e.g., 'Central Standard Time', 'Pacific Standard Time', 'Eastern Daylight Time' 
	@ServerAndJobsSyncCheckJobRunsEvery				sysname				= N'30 minutes', 
	@DataSyncCheckJobRunsEvery						sysname				= N'20 minutes',
	@IgnoreSynchronizedDatabaseOwnership			bit		            = 0,					
	@IgnoredMasterDbObjects							nvarchar(MAX)       = NULL,
	@IgnoredLogins									nvarchar(MAX)       = NULL,
	@IgnoredAlerts									nvarchar(MAX)       = NULL,
	@IgnoredLinkedServers							nvarchar(MAX)       = NULL,
    @IgnorePrincipalNames							bit                 = 1,  
	@IgnoredJobs									nvarchar(MAX)		= NULL,
	@IgnoredDatabases								nvarchar(MAX)		= NULL,
	@RPOThreshold									sysname				= N'10 seconds',
	@RTOThreshold									sysname				= N'40 seconds',
	@AGSyncCheckIterationCount						int					= 8, 
	@AGSyncCheckDelayBetweenChecks					sysname				= N'1800 milliseconds',
	@ExcludeAnomolousSyncDeviations					bit					= 0,    -- Primarily for Ghosted Records Cleanup... 	
	@JobsNamePrefix									sysname				= N'Synchronization - ',		
	@JobsCategoryName								sysname				= N'SynchronizationChecks',							
	@JobOperatorToAlertOnErrors						sysname				= N'Alerts',	
	@ProfileToUseForAlerts							sysname				= N'General',
	@OverWriteExistingJobs							bit					= 0
AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	-- TODO: validate inputs... 

	-- translate 'local' timezone to UTC-zoned servers:
	IF @TimeZoneForUtcOffset IS NOT NULL BEGIN 
		DECLARE @utc datetime = GETUTCDATE();
		DECLARE @atTimeZone datetime = @utc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZoneForUtcOffset;

		SET @ServerAndJobsSyncCheckJobStart = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @ServerAndJobsSyncCheckJobStart);
		SET @DataSyncCheckJobStart = DATEADD(MINUTE, 0 - (DATEDIFF(MINUTE, @utc, @atTimeZone)), @DataSyncCheckJobStart);
	END;

	DECLARE @serverAndJobsStart time, @dataStart time;
	SELECT 
		@serverAndJobsStart		= CAST(@ServerAndJobsSyncCheckJobStart AS time), 
		@dataStart				= CAST(@DataSyncCheckJobStart AS time);

	IF NULLIF(@Action, N'') IS NULL SET @Action = N'TEST';

	IF UPPER(@Action) NOT IN (N'TEST', N'CREATE') BEGIN 
		RAISERROR('Invalid option specified for parameter @Action. Valid options are ''TEST'' (test/show sync-check outputs without creating a job) and ''CREATE'' (create sync-check jobs).', 16, 1);
		RETURN -1;
	END;

	-- vNEXT: MAYBE look at extending the types of intervals allowed?
	-- Verify minutes-only sync-check intervals. 
	IF @ServerAndJobsSyncCheckJobRunsEvery IS NULL BEGIN 
		RAISERROR('Parameter @ServerAndJobsSyncCheckJobRunsEvery cannot be left empty - and specifies how frequently (in minutes) the server/job sync-check job runs - e.g., N''20 minutes''.', 16, 1);
		RETURN -2;
	  END
	ELSE BEGIN
		IF @ServerAndJobsSyncCheckJobRunsEvery NOT LIKE '%minute%' BEGIN 
			RAISERROR('@ServerAndJobsSyncCheckJobRunsEvery can only specify values defined in minutes - e.g., N''5 minutes'', or N''10 minutes'', etc.', 16, 1);
			RETURN -3;
		END;
	END;

	IF @DataSyncCheckJobRunsEvery IS NULL BEGIN 
		RAISERROR('Parameter @DataSyncCheckJobRunsEvery cannot be left empty - and specifies how frequently (in minutes) the data sync-check job runs - e.g., N''20 minutes''.', 16, 1);
		RETURN -4;
	  END
	ELSE BEGIN
		IF @DataSyncCheckJobRunsEvery NOT LIKE '%minute%' BEGIN 
			RAISERROR('@DataSyncCheckJobRunsEvery can only specify values defined in minutes - e.g., N''5 minutes'', or N''10 minutes'', etc.', 16, 1);
			RETURN -5;
		END;
	END;

--vNEXT:
	--IF UPPER(@Action) = N'TEST' BEGIN
	--	PRINT 'TODO: Output all parameters - to make config easier... ';
	--	-- SEE https://overachieverllc.atlassian.net/browse/S4-304 for more details. Otherwise, effecively: SELECT [name] FROM sys.parameters WHERE object_id = @@PROCID;
	--END;
	
	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

	DECLARE @serverSyncTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[verify_server_synchronization]
	@IgnoreSynchronizedDatabaseOwnership = {ingoreOwnership},
	@IgnoredMasterDbObjects = {ignoredMasterObjects},
	@IgnoredLogins = {ignoredLogins},
	@IgnoredAlerts = {ignoredAlerts},
	@IgnoredLinkedServers = {ignoredLinkedServers},
	@IgnorePrincipalNames = {ignorePrincipals},{operator}{profile}
	@PrintOnly = {printOnly}; ';

	DECLARE @jobsSyncTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[verify_job_synchronization] 
	@IgnoredJobs = {ignoredJobs},{operator}{profile}
	@PrintOnly = {printOnly}; ';

	DECLARE @dataSyncTemplate nvarchar(MAX) = N'EXEC admindb.dbo.[verify_data_synchronization]
	@IgnoredDatabases = {ignoredDatabases},{rpo}{rto}{checkCount}{checkDelay}{excludeAnomalies}{operator}{profile}
	@PrintOnly = {printOnly}; ';
	
	-----------------------------------------------------------------------------
	-- Process Server Sync Checks:
	DECLARE @serverBody nvarchar(MAX) = @serverSyncTemplate;
	
	IF @IgnoreSynchronizedDatabaseOwnership = 1 
		SET @serverBody = REPLACE(@serverBody, N'{ingoreOwnership}', N'1');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ingoreOwnership}', N'0');

	IF NULLIF(@IgnoredMasterDbObjects, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredMasterObjects}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredMasterObjects}', N'N''' + @IgnoredMasterDbObjects + N'''');

	IF NULLIF(@IgnoredLogins, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLogins}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLogins}', N'N''' + @IgnoredLogins + N'''');

	IF  NULLIF(@IgnoredAlerts, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredAlerts}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredAlerts}', N'N''' + @IgnoredAlerts + N'''');

	IF  NULLIF(@IgnoredLinkedServers, N'') IS NULL 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLinkedServers}', N'NULL');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignoredLinkedServers}', N'N''' + @IgnoredLinkedServers + N'''');

	IF @IgnorePrincipalNames = 1
		SET @serverBody = REPLACE(@serverBody, N'{ignorePrincipals}', N'1');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{ignorePrincipals}', N'0');

	IF UPPER(@Action) = N'TEST' 
		SET @serverBody = REPLACE(@serverBody, N'{printOnly}', N'1');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{printOnly}', N'0');

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @serverBody = REPLACE(@serverBody, N'{operator}', N'');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @serverBody = REPLACE(@serverBody, N'{profile}', N'');
	ELSE 
		SET @serverBody = REPLACE(@serverBody, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-----------------------------------------------------------------------------
	-- Process Job Sync Checks
	DECLARE @jobsBody nvarchar(MAX) = @jobsSyncTemplate;

	IF NULLIF(@IgnoredJobs, N'') IS NULL 
		SET @jobsBody = REPLACE(@jobsBody, N'{ignoredJobs}', N'NULL');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{ignoredJobs}', N'''' + @IgnoredJobs + N'''');

	IF UPPER(@Action) = N'TEST' 
		SET @jobsBody = REPLACE(@jobsBody, N'{printOnly}', N'1');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{printOnly}', N'0');

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @jobsBody = REPLACE(@jobsBody, N'{operator}', N'');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @jobsBody = REPLACE(@jobsBody, N'{profile}', N'');
	ELSE 
		SET @jobsBody = REPLACE(@jobsBody, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');

	-----------------------------------------------------------------------------
	-- Process Data Sync Checks

	DECLARE @dataBody nvarchar(MAX) = @dataSyncTemplate;

	IF NULLIF(@IgnoredDatabases, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{ignoredDatabases}', N'NULL');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{ignoredDatabases}', N'N''' + @IgnoredDatabases + N'''');

	IF NULLIF(@RPOThreshold, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{rpo}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{rpo}', @crlfTab + N'@RPOThreshold = N''' + @RPOThreshold + N''',');

	IF NULLIF(@RTOThreshold, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{rto}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{rto}', @crlfTab + N'@RTOThreshold = N''' + @RTOThreshold + N''',');

	IF @AGSyncCheckIterationCount IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{checkCount}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{checkCount}', @crlfTab + N'@AGSyncCheckIterationCount = ' + CAST(@AGSyncCheckIterationCount AS sysname) + N',');

	IF NULLIF(@AGSyncCheckDelayBetweenChecks, N'') IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{checkDelay}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{checkDelay}', @crlfTab + N'@AGSyncCheckDelayBetweenChecks = N''' + @AGSyncCheckDelayBetweenChecks + N''',');

	IF @ExcludeAnomolousSyncDeviations IS NULL 
		SET @dataBody = REPLACE(@dataBody, N'{excludeAnomalies}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{excludeAnomalies}', @crlfTab + N'@ExcludeAnomolousSyncDeviations = ' + CAST(@ExcludeAnomolousSyncDeviations AS sysname) + N',');

	IF UPPER(@Action) = N'TEST' 
		SET @dataBody = REPLACE(@dataBody, N'{printOnly}', N'1');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{printOnly}', N'0');

	IF NULLIF(@JobOperatorToAlertOnErrors, N'') IS NULL
		SET @dataBody = REPLACE(@dataBody, N'{operator}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{operator}', @crlfTab + N'@OperatorName = N''' + @JobOperatorToAlertOnErrors + N''', ');

	IF NULLIF(@ProfileToUseForAlerts, N'') IS NULL
		SET @dataBody = REPLACE(@dataBody, N'{profile}', N'');
	ELSE 
		SET @dataBody = REPLACE(@dataBody, N'{profile}', @crlfTab + N'@MailProfileName = N''' + @ProfileToUseForAlerts + N''', ');
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	IF UPPER(@Action) = N'TEST' BEGIN
		
		PRINT N'NOTE: Operating in Test Mode. ';
		PRINT N'	SET @Action = N''CREATE'' when ready to create actual jobs... ' + @crlf + @crlf;
		PRINT N'EXECUTING synchronization-check calls as follows: ' + @crlf + @crlf;
		PRINT @serverBody + @crlf + @crlf;
		PRINT @jobsBody + @crlf + @crlf;
		PRINT @dataBody + @crlf + @crlf; 

		PRINT N'OUTPUT FROM EXECUTION of the above operations FOLLOWS:';
		PRINT N'--------------------------------------------------------------------------------------------------------';

		EXEC sp_executesql @serverBody;
		EXEC sp_executesql @jobsBody;
		EXEC sp_executesql @dataBody;


		PRINT N'--------------------------------------------------------------------------------------------------------';
		

		RETURN 0;
	END;

	-----------------------------------------------------------------------------
	-- Create the Server and Jobs Sync-Check Job:
	DECLARE @jobID uniqueidentifier; 
	DECLARE @currentJobName sysname = @JobsNamePrefix + N'Verify Server and Jobs';

	EXEC dbo.[create_agent_job]
		@TargetJobName = @currentJobName,
		@JobCategoryName = @JobsCategoryName,
		@AddBlankInitialJobStep = 0,  -- not for these jobs, they should be fairly short in execution... 
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobID OUTPUT;
	
	-- Add a schedule: 
	DECLARE @dateAsInt int = CAST(CONVERT(sysname, GETDATE(), 112) AS int);
	DECLARE @startTimeAsInt int = CAST((LEFT(REPLACE(CONVERT(sysname, @serverAndJobsStart, 108), N':', N''), 6)) AS int);
	DECLARE @scheduleName sysname = @currentJobName + ' Schedule';

	DECLARE @frequencyMinutes int;
	DECLARE @outcome int; 
	DECLARE @error nvarchar(MAX);

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @ServerAndJobsSyncCheckJobRunsEvery,
		@ValidationParameterName = N'@ServerAndJobsSyncCheckJobRunsEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;
		   	
	-- TODO: scheduling logic here isn't as robust as it is in ...dbo.enable_disk_monitoring (and... i should expand the logic in THAT sproc, and move it out to it's own sub-sproc - i.e., pass in an @JobID and other params to a sproc called something like dbo.add_agent_job_schedule
	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobID,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 4,		-- daily								
		@freq_interval = 1, -- every 1 days							
		@freq_subday_type = 4,	-- minutes			
		@freq_subday_interval = @frequencyMinutes, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;	

	DECLARE @compoundJobStep nvarchar(MAX) = N'-- Server Synchronization Checks: 
' + @serverBody + N'

-- Jobs Synchronization Checks: 
' + @jobsBody;

	EXEC msdb..sp_add_jobstep
		@job_id = @jobID,
		@step_id = 1,
		@step_name = N'Synchronization Checks for Server Objects and Jobs Details',
		@subsystem = N'TSQL',
		@command = @compoundJobStep,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 1,
		@retry_interval = 1;

	-----------------------------------------------------------------------------
	-- Create the Data Sync-Check Job:

	SET @currentJobName = @JobsNamePrefix + N'Data-Sync Verification';
	SET @jobID = NULL;

	EXEC dbo.[create_agent_job]
		@TargetJobName = @currentJobName,
		@JobCategoryName = @JobsCategoryName,
		@AddBlankInitialJobStep = 0,  -- not for these jobs, they should be fairly short in execution... 
		@OperatorToAlertOnErrorss = @JobOperatorToAlertOnErrors,
		@OverWriteExistingJobDetails = @OverWriteExistingJobs,
		@JobID = @jobID OUTPUT;

	-- Add a schedule: 

	SET @startTimeAsInt = CAST((LEFT(REPLACE(CONVERT(sysname, @dataStart, 108), N':', N''), 6)) AS int);
	SET @scheduleName = @currentJobName + ' Schedule';

	EXEC @outcome = dbo.[translate_vector]
		@Vector = @DataSyncCheckJobRunsEvery,
		@ValidationParameterName = N'@DataSyncCheckJobRunsEvery',
		@ProhibitedIntervals = N'MILLISECOND,SECOND,HOUR,DAY,WEEK,MONTH,YEAR',
		@TranslationDatePart = 'MINUTE',
		@Output = @frequencyMinutes OUTPUT,
		@Error = @error OUTPUT;

	IF @outcome <> 0 BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN @outcome;
	END;

	-- TODO: scheduling logic here isn't as robust as it is in ...dbo.enable_disk_monitoring (and... i should expand the logic in THAT sproc, and move it out to it's own sub-sproc - i.e., pass in an @JobID and other params to a sproc called something like dbo.add_agent_job_schedule
	EXEC msdb.dbo.sp_add_jobschedule 
		@job_id = @jobID,
		@name = @scheduleName,
		@enabled = 1, 
		@freq_type = 4,		-- daily								
		@freq_interval = 1, -- every 1 days							
		@freq_subday_type = 4,	-- minutes			
		@freq_subday_interval = @frequencyMinutes, 
		@freq_relative_interval = 0, 
		@freq_recurrence_factor = 0, 
		@active_start_date = @dateAsInt, 
		@active_start_time = @startTimeAsInt;

	-- Add job Body: 
	DECLARE @singleBody nvarchar(MAX) = N'-- Data Synchronization Checks: 
' + @dataBody;

	EXEC msdb..sp_add_jobstep
		@job_id = @jobID,
		@step_id = 1,
		@step_name = N'Data Synchronization + Topology Health Checks',
		@subsystem = N'TSQL',
		@command = @singleBody,
		@on_success_action = 1,
		@on_success_step_id = 0,
		@on_fail_action = 2,
		@on_fail_step_id = 0,
		@database_name = N'admindb',
		@retry_attempts = 1,
		@retry_interval = 1;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_synchronization_setup','P') IS NOT NULL
	DROP PROC dbo.[verify_synchronization_setup];
GO

CREATE PROC dbo.[verify_synchronization_setup]

AS
    SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

    IF OBJECT_ID('tempdb..#ERRORs') IS NOT NULL
	    DROP TABLE #Errors;

    CREATE TABLE #Errors (
	    ErrorId int IDENTITY(1,1) NOT NULL, 
	    SectionID int NOT NULL, 
	    Severity varchar(20) NOT NULL, -- INFO, WARNING, ERROR
	    ErrorText nvarchar(2000) NOT NULL
    );

    -------------------------------------------------------------------------------------
    -- 0. Core Configuration Details/Needs:

    -- Database Mail
    IF (SELECT value_in_use FROM sys.configurations WHERE name = 'Database Mail XPs') != 1 BEGIN
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 0, N'ERROR', N'Database Mail has not been set up or configured.';
    END

    DECLARE @profileInfo TABLE (
	    profile_id int NULL, 
	    name sysname NULL, 
	    [description] nvarchar(256) NULL
    )
    INSERT INTO	@profileInfo (profile_id, name, description)
    EXEC msdb.dbo.sysmail_help_profile_sp;

    IF NOT EXISTS (SELECT NULL FROM @profileInfo) BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 0, N'ERROR', N'A Database Mail Profile has not been created.';
    END 

    -- SQL Agent can talk to Database Mail and a profile has been configured: 
    declare @DatabaseMailProfile nvarchar(255)
    exec master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
     IF @DatabaseMailProfile IS NULL BEGIN 
 	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 0, N'ERROR', N'The SQL Server Agent has not been configured to Use Database Mail.';
     END 

    -- Operators (at least one configured)
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators) BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 0, N'WARNING', N'No SQL Server Agent Operator was detected.';
    END 

    -------------------------------------------------------------------------------------
    -- 1. 
    -- PARTNER linked server definition.
    DECLARE @linkedServers TABLE (
	    SRV_NAME sysname NULL, 
	    SRV_PROVIDERNAME nvarchar(128) NULL, 
	    SRV_PRODUCT nvarchar(128) NULL,
	    SRV_DATASOURCE nvarchar(4000) NULL, 
	    SRV_PROVIDERSTRING nvarchar(4000) NULL,
	    SRV_LOCATION nvarchar(4000) NULL, 
	    SRV_CAT sysname NULL
    )

    INSERT INTO @linkedServers 
    EXEC sp_linkedservers

    IF NOT EXISTS (SELECT NULL FROM @linkedServers WHERE SRV_NAME = N'PARTNER') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 1, N'ERROR', N'Linked Server definition for PARTNER not found (synchronization checks won''t work).';
    END

    -------------------------------------------------------------------------------------
    -- 2.Server and Job Synchronization Checks

    -- check for missing code/objects:
    DECLARE @ObjectNames TABLE (
	    name sysname
    )

    INSERT INTO @ObjectNames (name)
    VALUES 
    (N'server_trace_flags'),
    (N'is_primary_database'),
    (N'verify_server_synchronization'),
    (N'verify_job_synchronization');

    INSERT INTO #Errors (SectionID, Severity, ErrorText)
    SELECT 
	    2, 
	    N'ERROR',
	    N'Object [' + x.name + N'] was not found in the [admindb] database.'
    FROM 
	    @ObjectNames x
	    LEFT OUTER JOIN admindb..sysobjects o ON o.name = x.name
    WHERE 
	    o.name IS NULL;

    -- warn if there aren't any job steps with verify_server_synchronization or verify_job_synchronization referenced.
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%verify_server_synchronization%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [dbo].[verify_server_synchronization] was not found.';
    END 

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%verify_job_synchronization%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [dbo].[verify_job_synchronization] was not found.';
    END 

	-- ditto on data-synch checks: 
	IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%verify_data_synchronization%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [dbo].[verify_data_synchronization] was not found.';
    END 
    -------------------------------------------------------------------------------------
    -- 3. Mirroring Failover

    -- Mirroring Failover Messages (WITH LOG):
    IF NOT EXISTS (SELECT NULL FROM master.sys.messages WHERE language_id = 1033 AND message_id = 1440 AND is_event_logged = 1) BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 3, N'WARNING', N'Message ID 1440 is not set to use the WITH_LOG option.';
    END

    IF NOT EXISTS (SELECT NULL FROM master.sys.messages WHERE language_id = 1033 AND message_id = 1480 AND is_event_logged = 1) BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 3, N'ERROR', N'Message ID 1480 is not set to use the WITH_LOG option.';
    END


    -- objects/code:
    DELETE FROM @ObjectNames;
    INSERT INTO @ObjectNames (name)
    VALUES 
    (N'server_trace_flags'),
    (N'process_synchronization_failover');

    INSERT INTO #Errors (SectionID, Severity, ErrorText)
    SELECT 
	    3, 
	    N'ERROR',
	    N'Object [' + x.name + N'] was not found in the admindb database.'
    FROM 
	    @ObjectNames x
	    LEFT OUTER JOIN admindb..sysobjects o ON o.name = x.name
    WHERE 
	    o.name IS NULL;

    --DELETE FROM @ObjectNames;
    --INSERT INTO @ObjectNames (name)
    --VALUES 
    --(N'sp_fix_orphaned_users');

    --INSERT INTO #Errors (SectionID, Severity, ErrorText)
    --SELECT 
    --	3, 
    --	N'ERROR', 
    --	N'Object [' + x.name + N'] was not found in the master database.'
    --FROM 
    --	@ObjectNames x
    --	LEFT OUTER JOIN admindb..sysobjects o ON o.name = x.name
    --WHERE 
    --	o.name IS NULL;


    -- Alerts for 1440/1480
    --IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE message_id = 1440) BEGIN 
    --	INSERT INTO #Errors (SectionID, Severity, ErrorText)
    --	SELECT 3, N'INFO', N'An Alert to Trap Failover with a Database as the Primary has not been configured.';
    --END

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE message_id = 1480) BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 3, N'ERROR', N'A SQL Server Agent Alert has not been set up to ''trap'' Message 1480 (database failover).';
    END

    -- Warn if no job to respond to failover:
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%process_synchronization_failover%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 3, N'WARNING', N'A SQL Server Agent Job that calls [process_synchronization_failover] (to handle database failover) was not found.';
    END 


    -------------------------------------------------------------------------------------
    -- 4. Monitoring. 

    -- objects/code:
    DELETE FROM @ObjectNames;
    INSERT INTO @ObjectNames (name)
    VALUES 
    (N'verify_data_synchronization');

    INSERT INTO #Errors (SectionID, Severity, ErrorText)
    SELECT 
	    4, 
	    N'ERROR',
	    N'Object [' + x.name + N'] was not found in the master database.'
    FROM 
	    @ObjectNames x
	    LEFT OUTER JOIN admindb.sys.sysobjects o ON o.name = x.name
    WHERE 
	    o.name IS NULL;

    IF EXISTS(SELECT * FROM sys.[database_mirroring] WHERE [mirroring_guid] IS NOT NULL) BEGIN
	    -- If Mirrored dbs are present:
	    -- Make sure the 'stock' MS job "Database Mirroring Monitor Job" is present. 
	    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobs WHERE name = 'Database Mirroring Monitor Job') BEGIN 
		    INSERT INTO #Errors (SectionID, Severity, ErrorText)
		    SELECT 4, N'ERROR', N'The SQL Server Agent (initially provided by Microsoft) entitled ''Database Mirroring Monitor Job'' is not present. Please recreate.';
	    END;
    END; 

    -- Make sure there's a health-check job:
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%data_synchronization_checks%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 4, N'WARNING', N'A SQL Server Agent Job that calls [data_synchronization_checks] (to run health checks) was not found.';
    END 


    -------------------------------------------------------------------------------------
    -- 5. Backups

    -- objects/code:
    DELETE FROM @ObjectNames;
    INSERT INTO @ObjectNames (name)
    VALUES 
    (N'backup_databases');

    INSERT INTO #Errors (SectionID, Severity, ErrorText)
    SELECT 
	    5, 
	    N'ERROR',
	    N'Object [' + x.[name] + N'] was not found in the admin database.'
    FROM 
	    @ObjectNames x
	    LEFT OUTER JOIN admindb.dbo.sysobjects o ON o.name = x.name
    WHERE 
	    o.name IS NULL;

    DECLARE @settingValue sysname; 
    SELECT @settingValue = ISNULL([setting_value], N'0') FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling';

    IF @settingValue <> N'1' BEGIN
        INSERT INTO #Errors (SectionID, Severity, ErrorText)
        SELECT 5, N'WARNING', N'admindb.dbo.[backup_databases] requires advanced error handling capabilities enabled. Please execute admindb.dbo.enable_advanced_capabilities to enable advanced capabilities.';
    END;

    -- warnings for backups:
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%backup_databases%FULL%SYSTEM%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 5, N'INFO', N'No SQL Server Agent Job to execute backups of System Databases was found.';	
    END

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%backup_databases%FULL%' AND command NOT LIKE '%backup_databases%FULL%system%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 5, N'INFO', N'No SQL Server Agent Job to execute FULL backups of User Databases was found.';	
    END

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%backup_databases%LOG%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 5, N'INFO', N'No SQL Server Agent Job to execute Transaction Log backups of User Databases was found.';	
    END

    -------------------------------------------------------------------------------------
    -- 6. Reporting 
    IF EXISTS (SELECT NULL FROM #Errors)
	    SELECT SectionID [Section], Severity, ErrorText [Detail] FROM #Errors ORDER BY ErrorId;
    ELSE 
	    SELECT 'All Checks Completed - No Issues Detected.' [Outcome];

    RETURN 0;
GO


------------------------------------------------------------------------------------------------------------------------------------------------------
-- Auditing:
------------------------------------------------------------------------------------------------------------------------------------------------------

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.generate_audit_signature','P') IS NOT NULL
	DROP PROC dbo.generate_audit_signature;
GO


CREATE PROC dbo.generate_audit_signature 
	@AuditName					sysname, 
	@IncludeGuidInHash			bit			= 1, 
	@AuditSignature				bigint		= -1 OUTPUT
AS
	
	RAISERROR('Sorry. The S4 stored procedure dbo.generate_audit_signature is NOT supported on SQL Server 2008/2008R2 instances.', 16, 1);
	RETURN -100;
GO

DECLARE @generate_audit_signature nvarchar(MAX) = N'ALTER PROC dbo.generate_audit_signature 
	@AuditName					sysname, 
	@IncludeGuidInHash			bit			= 1, 
	@AuditSignature				bigint		= -1 OUTPUT
AS
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @hash int = 0;
	DECLARE @auditID int; 

	SELECT 
		@auditID = audit_id
	FROM 
		sys.[server_audits] 
	WHERE 
		[name] = @AuditName;

	IF @auditID IS NULL BEGIN 
		SET @errorMessage = N''Specified Server Audit Name: ['' + @AuditName + N''] does NOT exist. Please check your input and try again.'';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END;

	DECLARE @hashes table ( 
			[hash] bigint NOT NULL
	);

	IF @IncludeGuidInHash = 1
		SELECT @hash = CHECKSUM([name], [audit_guid], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;
	ELSE 
		SELECT @hash = CHECKSUM([name], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;

	INSERT INTO @hashes ([hash])
	VALUES (@hash);

	-- hash storage details (if file log storage is used):
	IF EXISTS (SELECT NULL FROM sys.[server_audits] WHERE [name] = @AuditName AND [type] = ''FL'') BEGIN
		SELECT 
			@hash = CHECKSUM(max_file_size, max_files, reserve_disk_space, log_file_path) 
		FROM 
			sys.[server_file_audits] 
		WHERE 
			[audit_id] = @auditID;  -- note, log_file_name will always be different because of the GUIDs. 

		INSERT INTO @hashes ([hash])
		VALUES (@hash);
	END

	IF @AuditSignature = -1
		SELECT SUM([hash]) [audit_signature] FROM @hashes; 
	ELSE	
		SELECT @AuditSignature = SUM(hash) FROM @hashes;

	RETURN 0;

 ';

IF (SELECT dbo.get_engine_version())> 10.5 
	EXEC sp_executesql @generate_audit_signature;

-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.generate_specification_signature','P') IS NOT NULL
	DROP PROC dbo.generate_specification_signature;
GO

CREATE PROC dbo.generate_specification_signature 
	@Target										sysname				= N'SERVER',			-- SERVER | 'db_name' - SERVER is default and represents a server-level specification, whereas a db_name will specify that this is a database specification).
	@SpecificationName							sysname,
	@IncludeParentAuditIdInSignature			bit					= 1,
	@SpecificationSignature						bigint				= -1    OUTPUT
AS
	SET NOCOUNT ON; 
	
	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 
	
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @specificationScope sysname;

	 IF NULLIF(@Target, N'') IS NULL OR @Target = N'SERVER'
		SET @specificationScope = N'SERVER';
	ELSE 
		SET @specificationScope = N'DATABASE';

	CREATE TABLE #specificationDetails (
		audit_action_id varchar(10) NOT NULL, 
		class int NOT NULL, 
		major_id int NOT NULL, 
		minor_id int NOT NULL, 
		audited_principal_id int NOT NULL, 
		audited_result nvarchar(60) NOT NULL, 
		is_group bit NOT NULL 
	);

	DECLARE @hash int = 0;
	DECLARE @hashes table ( 
			[hash] bigint NOT NULL
	);

	DECLARE @specificationID int; 
	DECLARE @auditGUID uniqueidentifier;
	DECLARE @createDate datetime;
	DECLARE @modifyDate datetime;
	DECLARE @isEnabled bit;

	DECLARE @sql nvarchar(max) = N'
		SELECT 
			@specificationID = [{1}_specification_id], 
			@auditGUID = [audit_guid], 
			@createDate = [create_date],
			@modifyDate = [modify_date],
			@isEnabled = [is_state_enabled] 
		FROM 
			[{0}].sys.[{1}_audit_specifications] 
		WHERE 
			[name] = @SpecificationName;';

	DECLARE @specificationSql nvarchar(MAX) = N'
		SELECT 
			[audit_action_id], 
			[class], 
			[major_id],
			[minor_id], 
			[audited_principal_id], 
			[audited_result], 
			[is_group]
		FROM
			[{0}].sys.[{1}_audit_specification_details]  
		WHERE 
			 [{1}_specification_id] = @specificationID
		ORDER BY 
			[major_id];'; 

	IF @specificationScope = N'SERVER' BEGIN

		SET @sql = REPLACE(@sql, N'{0}', N'master');
		SET @sql = REPLACE(@sql, N'{1}', N'server');
		SET @specificationSql = REPLACE(@specificationSql, N'{0}', N'master');
		SET @specificationSql = REPLACE(@specificationSql, N'{1}', N'server');		

	  END
	ELSE BEGIN 

		-- Make sure the target database exists:
		DECLARE @databases table (
			[database_name] sysname NOT NULL
		); 

		INSERT INTO @databases([database_name])
		EXEC dbo.list_databases
			@Targets = @Target, 
			@Exclusions = N'[DEV]';

		IF NOT EXISTS (SELECT NULL FROM @databases WHERE LOWER([database_name]) = LOWER(@Target)) BEGIN
			SET @errorMessage = N'Specified @Target database [' + @Target + N'] does not exist. Please check your input and try again.';
			RAISERROR(@errorMessage, 16, 1);
			RETURN -1;
		END;

		SET @sql = REPLACE(@sql, N'{0}', @Target);
		SET @sql = REPLACE(@sql, N'{1}', N'database');
		SET @specificationSql = REPLACE(@specificationSql, N'{0}', @Target);
		SET @specificationSql = REPLACE(@specificationSql, N'{1}', N'database');
	END; 

	EXEC sys.sp_executesql 
		@stmt = @sql, 
		@params = N'@SpecificationName sysname, @specificationID int OUTPUT, @auditGuid uniqueidentifier OUTPUT, @isEnabled bit OUTPUT, @createDate datetime OUTPUT, @modifyDate datetime OUTPUT', 
		@SpecificationName = @SpecificationName, @specificationID = @specificationID OUTPUT, @auditGUID = @auditGUID OUTPUT, @isEnabled = @isEnabled OUTPUT, @createDate = @createDate OUTPUT, @modifyDate = @modifyDate OUTPUT;

	IF @specificationID IS NULL BEGIN
		SET @errorMessage = N'Specified '+ CASE WHEN @specificationScope = N'SERVER' THEN N'Server' ELSE N'Database' END + N' Audit Specification Name: [' + @SpecificationName + N'] does NOT exist. Please check your input and try again.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -2;		
	END;		

	-- generate/store a hash of the specification details:
	IF @IncludeParentAuditIdInSignature = 1 
		SELECT @hash = CHECKSUM(@SpecificationName, @auditGUID, @specificationID, @createDate, @modifyDate, @isEnabled);
	ELSE	
		SELECT @hash = CHECKSUM(@SpecificationName, @specificationID, @createDate, @modifyDate, @isEnabled);

	INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));

	INSERT INTO [#specificationDetails] ([audit_action_id], [class], [major_id], [minor_id], [audited_principal_id], [audited_result], [is_group])
	EXEC sys.[sp_executesql] 
		@stmt = @specificationSql, 
		@params = N'@specificationID int', 
		@specificationID = @specificationID;

	DECLARE @auditActionID char(4), @class tinyint, @majorId int, @minorInt int, @principal int, @result nvarchar(60), @isGroup bit; 
	DECLARE details CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[audit_action_id], 
		[class], 
		[major_id],
		[minor_id], 
		[audited_principal_id], 
		[audited_result], 
		[is_group]
	FROM
		[#specificationDetails]
	ORDER BY 
		[audit_action_id];

	OPEN [details]; 
	FETCH NEXT FROM [details] INTO @auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup;

	WHILE @@FETCH_STATUS = 0 BEGIN 

		SELECT @hash = CHECKSUM(@auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup)
		
		INSERT INTO @hashes ([hash]) 
		VALUES (CAST(@hash AS bigint));

		FETCH NEXT FROM [details] INTO @auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup;
	END;	

	CLOSE [details];
	DEALLOCATE [details];

	IF @SpecificationSignature = -1
		SELECT SUM([hash]) [audit_signature] FROM @hashes; 
	ELSE	
		SELECT @SpecificationSignature = SUM(hash) FROM @hashes;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO


IF OBJECT_ID('dbo.verify_audit_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_audit_configuration;
GO

CREATE PROC dbo.verify_audit_configuration 
	@AuditName							sysname, 
	@OptionalAuditSignature				bigint				= NULL, 
	@IncludeAuditIdInSignature			bit					= 1,
	@ExpectedEnabledState				sysname				= N'ON',   -- ON | OFF
	@EmailSubjectPrefix					nvarchar(50)		= N'[Audit Configuration] ',
	@MailProfileName					sysname				= N'General',	
	@OperatorName						sysname				= N'Alerts',	
	@PrintOnly							bit					= 0	
AS 
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF UPPER(@ExpectedEnabledState) NOT IN (N'ON', N'OFF') BEGIN
		RAISERROR('Allowed values for @ExpectedEnabledState are ''ON'' or ''OFF'' - no other values are allowed.', 16, 1);
		RETURN -1;
	END;

	DECLARE @errorMessage nvarchar(MAX);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) NOT NULL
	);

	-- make sure audit exists and and verify is_enabled status:
	DECLARE @auditID int; 
	DECLARE @isEnabled bit;

	SELECT 
		@auditID = audit_id, 
		@isEnabled = is_state_enabled 
	FROM 
		sys.[server_audits] 
	WHERE 
		[name] = @AuditName;
	
	IF @auditID IS NULL BEGIN 
		SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] does not currently exist on [' + @@SERVERNAME + N'].';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
		GOTO ALERTS;
	END;

	-- check on enabled state: 
	IF UPPER(@ExpectedEnabledState) = N'ON' BEGIN 
		IF @isEnabled <> 1 BEGIN
			SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] expected is_enabled state was: ''ON'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	  END; 
	ELSE BEGIN 
		IF @isEnabled <> 0 BEGIN 
			SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] expected is_enabled state was: ''OFF'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	END; 

	-- If we have a checksum, verify that as well: 
	IF @OptionalAuditSignature IS NOT NULL BEGIN 
		DECLARE @currentSignature bigint = NULL;
		DECLARE @returnValue int; 

		EXEC @returnValue = dbo.generate_audit_signature
			@AuditName = @AuditName, 
			@IncludeGuidInHash = @IncludeAuditIdInSignature,
			@AuditSignature = @currentSignature OUTPUT;

		IF @returnValue <> 0 BEGIN 
				SELECT @errorMessage = N'ERROR: Problem generating audit signature for [' + @AuditName + N'] on ' + @@SERVERNAME + N'.';
				INSERT INTO @errors([error]) VALUES (@errorMessage);			
		  END;
		ELSE BEGIN
			IF @OptionalAuditSignature <> @currentSignature BEGIN
				SELECT @errorMessage = N'WARNING: Expected signature for Audit [' + @AuditName + N'] (with a value of ' + CAST(@OptionalAuditSignature AS sysname) + N') did NOT match currently generated signature (with value of ' + CAST(@currentSignature AS sysname) + N').';
				INSERT INTO @errors([error]) VALUES (@errorMessage);	
			END;
		END;
	END;

ALERTS:
	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';
		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9);

		SET @errorMessage = N'The following conditions were detected: ' + @crlf;

		SELECT @errorMessage = @errorMessage + @tab + N'- ' + error + @crlf
		FROM @errors
		ORDER BY error_id;

		IF @PrintOnly = 1 BEGIN
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @errorMessage;
		  END
		ELSE BEGIN 
			EXEC msdb.dbo.sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO


-----------------------------------
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_specification_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_specification_configuration;
GO

CREATE PROC dbo.verify_specification_configuration 
	@Target									sysname				= N'SERVER',		--SERVER | 'db_name' - SERVER represents a server-level specification whereas a specific dbname represents a db-level specification.
	@SpecificationName						sysname, 
	@ExpectedEnabledState					sysname				= N'ON',   -- ON | OFF
	@OptionalSpecificationSignature			bigint				= NULL, 
	@IncludeParentAuditIdInSignature		bit					= 1,		-- i.e., defines setting of @IncludeParentAuditIdInSignature when original signature was signed. 
	@EmailSubjectPrefix						nvarchar(50)		= N'[Audit Configuration] ',
	@MailProfileName						sysname				= N'General',	
	@OperatorName							sysname				= N'Alerts',	
	@PrintOnly								bit					= 0	
AS	
	SET NOCOUNT ON; 

	-- [v7.6.3167.2.2] - License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639 

	IF UPPER(@ExpectedEnabledState) NOT IN (N'ON', N'OFF') BEGIN
		RAISERROR('Allowed values for @ExpectedEnabledState are ''ON'' or ''OFF'' - no other values are allowed.', 16, 1);
		RETURN -1;
	END;

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) NOT NULL
	);

	DECLARE @specificationScope sysname;

	 IF NULLIF(@Target, N'') IS NULL OR @Target = N'SERVER'
		SET @specificationScope = N'SERVER';
	ELSE 
		SET @specificationScope = N'DATABASE';

	DECLARE @sql nvarchar(max) = N'
		SELECT 
			@specificationID = [{1}_specification_id], 
			@auditGUID = [audit_guid], 
			@isEnabled = [is_state_enabled] 
		FROM 
			[{0}].sys.[{1}_audit_specifications] 
		WHERE 
			[name] = @SpecificationName;';

	-- make sure specification (and target db - if db-level spec) exist and grab is_enabled status: 
	IF @specificationScope = N'SERVER' BEGIN	
		SET @sql = REPLACE(@sql, N'{0}', N'master');
		SET @sql = REPLACE(@sql, N'{1}', N'server');
	  END;
	ELSE BEGIN 
		
		-- Make sure the target database exists:
		DECLARE @databases table (
			[database_name] sysname NOT NULL
		); 

		INSERT INTO @databases([database_name])
		EXEC dbo.list_databases
			@Targets = @Target, 
			@ExcludeDev = 1;

		IF NOT EXISTS (SELECT NULL FROM @databases WHERE LOWER([database_name]) = LOWER(@Target)) BEGIN
			SET @errorMessage = N'Specified @Target database [' + @Target + N'] does not exist. Please check your input and try again.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
			GOTO ALERTS;
		END;

		SET @sql = REPLACE(@sql, N'{0}', @Target);
		SET @sql = REPLACE(@sql, N'{1}', N'database');
	END;

	DECLARE @specificationID int; 
	DECLARE @isEnabled bit; 
	DECLARE @auditGUID uniqueidentifier;

	-- fetch details: 
	EXEC sys.[sp_executesql]
		@stmt = @sql, 
		@params = N'@specificationID int OUTPUT, @isEnabled bit OUTPUT, @auditGUID uniqueidentifier OUTPUT', 
		@specificationID = @specificationID OUTPUT, @isEnabled = @isEnabled OUTPUT, @auditGUID = @auditGUID OUTPUT;

	-- verify spec exists: 
	IF @auditGUID IS NULL BEGIN
		SET @errorMessage = N'WARNING: Specified @SpecificationName [' + @SpecificationName + N'] does not exist in @Target database [' + @Target + N'].';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
		GOTO ALERTS;
	END;

	-- check on/off state:
	IF UPPER(@ExpectedEnabledState) = N'ON' BEGIN 
		IF @isEnabled <> 1 BEGIN
			SELECT @errorMessage = N'WARNING: Specification [' + @SpecificationName + N'] expected is_enabled state was: ''ON'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	  END; 
	ELSE BEGIN 
		IF @isEnabled <> 0 BEGIN 
			SELECT @errorMessage = N'WARNING: Specification [' + @SpecificationName + N'] expected is_enabled state was: ''OFF'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	END; 

	-- verify signature: 
	IF @OptionalSpecificationSignature IS NOT NULL BEGIN 
		DECLARE @currentSignature bigint = 0;
		DECLARE @returnValue int; 

		EXEC @returnValue = dbo.generate_specification_signature
			@Target = @Target, 
			@SpecificationName = @SpecificationName, 
			@IncludeParentAuditIdInSignature = @IncludeParentAuditIdInSignature,
			@SpecificationSignature = @currentSignature OUTPUT;

		IF @returnValue <> 0 BEGIN 
				SELECT @errorMessage = N'ERROR: Problem generating specification signature for [' + @SpecificationName + N'] on ' + @@SERVERNAME + N'.';
				INSERT INTO @errors([error]) VALUES (@errorMessage);			
		  END;
		ELSE BEGIN
			IF @OptionalSpecificationSignature <> @currentSignature BEGIN
				SELECT @errorMessage = N'WARNING: Expected signature for Specification [' + @SpecificationName + N'] (with a value of ' + CAST(@OptionalSpecificationSignature AS sysname) + N') did NOT match currently generated signature (with value of ' + CAST(@currentSignature AS sysname) + N').';
				INSERT INTO @errors([error]) VALUES (@errorMessage);	
			END;
		END;
	END;

ALERTS:

	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';
		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9);

		SET @errorMessage = N'The following conditions were detected: ' + @crlf;

		SELECT @errorMessage = @errorMessage + @tab + N'- ' + error + @crlf
		FROM @errors
		ORDER BY error_id;

		IF @PrintOnly = 1 BEGIN
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @errorMessage;
		  END
		ELSE BEGIN 
			EXEC msdb.dbo.sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO	


----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 5. Update version_history with details about current version (i.e., if we got this far, the deployment is successful). 
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DECLARE @CurrentVersion varchar(20) = N'7.6.3167.2';
DECLARE @VersionDescription nvarchar(200) = N'Minor BugFixes + UTC-DateTime Offsets for Created Jobs and other streamlining/optimization';
DECLARE @InstallType nvarchar(20) = N'Install. ';

IF EXISTS (SELECT NULL FROM dbo.[version_history] WHERE CAST(LEFT(version_number, 3) AS decimal(2,1)) >= 4)
	SET @InstallType = N'Update. ';

SET @VersionDescription = @InstallType + @VersionDescription;

-- Add current version info:
IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @CurrentVersion) BEGIN
	INSERT INTO dbo.version_history (version_number, [description], deployed)
	VALUES (@CurrentVersion, @VersionDescription, GETDATE());
END;
GO

-----------------------------------
SELECT * FROM dbo.version_history;
GO
