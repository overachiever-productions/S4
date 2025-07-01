/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.corruption_check_history', N'U') IS NULL BEGIN 
	CREATE TABLE dbo.corruption_check_history (
		[check_id] int IDENTITY(1,1) NOT NULL, 
		[execution_id] uniqueidentifier NOT NULL, 
		[execution_date] date NOT NULL, 
		[database] sysname NOT NULL, 
		[check_start] datetime NOT NULL, 
		[check_end] datetime NOT NULL, 
		[check_succeeded] bit NOT NULL, 
		[results] xml NULL, 
		[errors] nvarchar(MAX) NULL, 
		CONSTRAINT PK_corruption_check_history PRIMARY KEY CLUSTERED (check_id)
	);

END;
GO 

IF dbo.[get_engine_version]() >= 14.00 BEGIN
	DECLARE @sql nvarchar(MAX) = N'ALTER INDEX [PK_corruption_check_history] ON [dbo].[corruption_check_history] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);
	ALTER TABLE [dbo].[corruption_check_history] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);';	

	EXEC sys.sp_executesql 
		@sql;
END;
GO