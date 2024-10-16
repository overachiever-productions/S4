/*


*/

USE [admindb];
GO

IF OBJECT_ID('[dbo].[numbers]', N'U') IS NULL BEGIN
	CREATE TABLE dbo.[numbers] (
		[number] int NOT NULL 
	)
	WITH (DATA_COMPRESSION = PAGE);

	CREATE CLUSTERED INDEX CLIX_numbers_by_number ON dbo.[numbers]([number]) WITH (DATA_COMPRESSION = PAGE);

	INSERT INTO [numbers] ([number])
	SELECT TOP (50000) 
		ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
	FROM sys.all_objects o1 
	CROSS JOIN sys.all_objects o2
END
GO