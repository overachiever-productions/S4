/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'[dbo].[numbers]', N'U') IS NULL BEGIN 
	CREATE TABLE [dbo].[numbers] (
		[number] int NOT NULL 
		CONSTRAINT PK_numbers_by_number PRIMARY KEY CLUSTERED ([number])
	);

	IF dbo.[get_engine_version]() >= 14.00 BEGIN
		DECLARE @sql nvarchar(MAX) = N'ALTER INDEX [PK_numbers_by_number] ON [dbo].[numbers] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);
		ALTER TABLE [dbo].[numbers] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);';	

		EXEC sys.sp_executesql 
			@sql;
	END;

	INSERT INTO [numbers] ([number])
	SELECT TOP (50000) 
		ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
	FROM sys.all_objects o1 
	CROSS JOIN sys.all_objects o2;
END
GO