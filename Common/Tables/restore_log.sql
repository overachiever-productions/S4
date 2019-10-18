/*

	TODO:
		- (maybe?) Add Extended Property with Version # so that any FUTURE changes to table can be calculated as ALTER statements vs DROP/CREATE (to preserve existing data).
				

*/

USE [admindb];
GO

	-- {copyright}

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