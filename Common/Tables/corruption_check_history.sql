/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[corruption_check_history]', N'U') IS NULL BEGIN 
	CREATE TABLE dbo.[corruption_check_history] (
		[check_id] int IDENTITY(1,1) NOT NULL, 
		[execution_id] uniqueidentifier NOT NULL, 
		[execution_date] date NOT NULL, 
		[database] sysname NOT NULL, 
		[check_start] datetime NOT NULL, 
		[check_end] datetime NOT NULL, 
		[check_succeeded] bit NOT NULL, 
		[results] xml NULL, 
		[errors] nvarchar(MAX) NULL, 
		CONSTRAINT [PK_corruption_check_history] PRIMARY KEY CLUSTERED ([check_id])
	);

END;
GO 

-- 12.4 addition: 
IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID(N'dbo.[corruption_check_history]') AND [name] = N'dop') BEGIN 
	
	BEGIN TRAN;

		CREATE TABLE dbo.[tmp_corruption_check_history] (
			[check_id] int IDENTITY(1,1) NOT NULL, 
			[execution_id] uniqueidentifier NOT NULL, 
			[execution_date] date NOT NULL, 
			[database] sysname NOT NULL, 
			[dop] tinyint NOT NULL,
			[check_start] datetime NOT NULL, 
			[check_end] datetime NOT NULL, 
			[check_succeeded] bit NOT NULL, 
			[results] xml NULL, 
			[errors] nvarchar(MAX) NULL, 
			CONSTRAINT [tmp_PK_corruption_check_history] PRIMARY KEY CLUSTERED ([check_id])
		);
		
		SET IDENTITY_INSERT dbo.[tmp_corruption_check_history] ON;

		IF EXISTS (SELECT NULL FROM dbo.corruption_check_history) BEGIN
			EXEC sys.sp_executesql 
				N'INSERT INTO dbo.tmp_corruption_check_history (check_id, execution_id, execution_date, [database], [dop], check_start, check_end, check_succeeded, results, errors)
				SELECT check_id, execution_id, execution_date, [database], 1, check_start, check_end, check_succeeded, results, errors FROM dbo.corruption_check_history';
		END;

		SET IDENTITY_INSERT dbo.[tmp_corruption_check_history] OFF;

		DROP TABLE dbo.corruption_check_history;

		EXEC sys.sp_rename N'dbo.tmp_corruption_check_history', N'corruption_check_history', 'OBJECT'; 
		EXEC sys.sp_rename N'dbo.corruption_check_history.tmp_PK_corruption_check_history', N'PK_corruption_check_history';

	COMMIT;
END;

IF dbo.[get_engine_version]() >= 14.00 BEGIN
	DECLARE @sql nvarchar(MAX) = N'ALTER INDEX [PK_corruption_check_history] ON [dbo].[corruption_check_history] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);
	ALTER TABLE [dbo].[corruption_check_history] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);';	

	EXEC sys.sp_executesql 
		@sql;
END;
GO