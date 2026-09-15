/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[column_widths]', N'P') IS NOT NULL
	DROP PROC dbo.[column_widths];
GO

CREATE PROC dbo.[column_widths]
	@database				sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SELECT
		[c].[object_id],
		SCHEMA_NAME([o].[schema_id]) [schema_name],
		OBJECT_NAME([c].[object_id]) [object_name],
		[c].[column_id],
		[c].[name] AS [column_name],
		[t].[name] AS [type_name],
		[c].[max_length],
		[c].[precision],
		[c].[scale],
		[c].[is_nullable],
		CASE 
			WHEN [t].[name] = N'bit' THEN 1 -- simplify to 1 byte, even though it can be stored as a bit in SQL Server; this is for estimation purposes
			WHEN [t].[name] = N'tinyint' THEN 1
			WHEN [t].[name] = N'smallint' THEN 2
			WHEN [t].[name] = N'int' THEN 4
			WHEN [t].[name] = N'bigint' THEN 8
			WHEN [t].[name] = N'smallmoney' THEN 4
			WHEN [t].[name] = N'money' THEN 8
			WHEN [t].[name] IN (N'decimal', N'numeric') THEN 
				CASE
					WHEN [c].[precision] <= 9 THEN 5
					WHEN [c].[precision] <= 19 THEN 9
					WHEN [c].[precision] <= 28 THEN 13
					ELSE 17
				END
			WHEN [t].[name] = N'real' THEN 4
			WHEN [t].[name] = N'float' THEN CASE WHEN [c].[precision] <= 24 THEN 4 ELSE 8 END
			WHEN [t].[name] = N'date' THEN 3
			WHEN [t].[name] = N'time' 
				THEN CASE
					WHEN [c].[scale] <= 2 THEN 3
					WHEN [c].[scale] <= 4 THEN 4
					ELSE 5
				END
			WHEN [t].[name] = N'smalldatetime' THEN 4
			WHEN [t].[name] = N'datetime' THEN 8
			WHEN [t].[name] = N'datetime2' THEN
				CASE
					WHEN [c].[scale] <= 2 THEN 6
					WHEN [c].[scale] <= 4 THEN 7
					ELSE 8
				END
			WHEN [t].[name] = N'datetimeoffset' 
				THEN CASE
					WHEN [c].[scale] <= 2 THEN 8
					WHEN [c].[scale] <= 4 THEN 9
					ELSE 10
				END
			WHEN [t].[name] IN (N'char', N'varchar', N'binary') THEN [c].[max_length]
			WHEN [t].[name] IN(N'varchar', N'nvarchar', N'varbinary') THEN
				CASE
					WHEN [c].[max_length] = -1 THEN 16  -- row-overlflow (i.e., pointer)
					ELSE [c].[max_length]
				END
			WHEN [t].[name] = N'text' THEN 16 
			WHEN [t].[name] = N'ntext' THEN 16
			WHEN [t].[name] = N'image' THEN 16
			WHEN [t].[name] = N'xml' THEN 16
			WHEN [t].[name] = N'uniqueidentifier' THEN 16
			WHEN [t].[name] = N'sysname' THEN [c].[max_length]
			WHEN [t].[name] = N'sql_variant' THEN 8016 -- up to 8016 bytes; using max
			WHEN [t].[name] = N'hierarchyid' THEN 892 -- variable, max shown
			WHEN [t].[name] = N'geography' THEN [c].[max_length]
			WHEN [t].[name] = N'geometry' THEN [c].[max_length]
			WHEN [t].[name] = N'rowversion' THEN 8
			WHEN [t].[name] = N'timestamp' THEN 8
			ELSE [c].[max_length]
		END [data_width]
	FROM
		[sys].[columns] [c]
		INNER JOIN [sys].[types] [t] ON [c].[user_type_id] = [t].[user_type_id]
		INNER JOIN sys.[objects] [o] ON [c].[object_id] = [o].[object_id];
GO