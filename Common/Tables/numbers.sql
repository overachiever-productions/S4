/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'[dbo].[numbers]', N'U') IS NULL BEGIN 
	CREATE TABLE [dbo].[numbers] (
		[number] int NOT NULL 
		CONSTRAINT PK_numbers_by_number PRIMARY KEY CLUSTERED ([number])
	);
END
GO

IF NOT EXISTS (SELECT NULL FROM sys.[key_constraints] WHERE [name] = N'PK_numbers_by_number') BEGIN
	IF EXISTS (SELECT NULL FROM sys.indexes WHERE [name] = N'CLIX_numbers_by_number') BEGIN
		DROP INDEX CLIX_numbers_by_number ON dbo.[numbers];
	END;
 
	ALTER TABLE dbo.[numbers] ADD CONSTRAINT PK_numbers_by_number PRIMARY KEY CLUSTERED ([number]);
END;

IF dbo.[get_engine_version]() >= 14.00 BEGIN
	DECLARE @sql nvarchar(MAX) = N'ALTER INDEX [PK_numbers_by_number] ON [dbo].[numbers] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);
	ALTER TABLE [dbo].[numbers] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);';	

	EXEC sys.sp_executesql 
		@sql;
END;

IF NOT EXISTS (SELECT NULL FROM dbo.[numbers]) BEGIN
	INSERT INTO [numbers] ([number])
	SELECT TOP (50000) 
		ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
	FROM sys.all_objects o1 
	CROSS JOIN sys.all_objects o2;
END; 
GO 

-- Sanity Check: 
IF NOT EXISTS (SELECT NULL FROM dbo.[numbers] WHERE [number] = 50000) BEGIN
	SELECT N'Table dbo.numbers does NOT have 50K rows.' [critical_error];

	RAISERROR(N'Fatal Error. Table dbo.Numbers not Populated Correctly.', 20, 1) WITH LOG;
END;