/*


*/

USE [admindb];
GO

THROW 'not done yet.';

IF OBJECT_ID('[dbo].[numbers]', N'U') IS NULL BEGIN
	DECLARE @numbersDDL nvarchar(MAX) = N'CREATE TABLE dbo.[numbers] (
	[number] int NOT NULL 
){with};
	
CREATE CLUSTERED INDEX CLIX_numbers_by_number ON dbo.[numbers]([number]){with};	'; 

	IF dbo.[get_engine_version](1) >= 1300.4001 
		SET @numbersDDL = REPLACE(@numbersDDL, N'{with}', N' WITH (DATA_COMPRESSION = PAGE)');
	ELSE 
		SET @numbersDDL = REPLACE(@numbersDDL, N'{with}', N'');

	INSERT INTO [numbers] ([number])
	SELECT TOP (50000) 
		ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
	FROM sys.all_objects o1 
	CROSS JOIN sys.all_objects o2
END
GO

ALTER TABLE dbo.[numbers] WITH