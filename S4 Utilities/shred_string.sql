
/*

	USAGE: 
		dynamically shreds a string into rows, then columns by means of delimeters. 

		Example Usages: 

				-- simple example: 
				DECLARE @Input nvarchar(MAX) = N'7:Xclelerator:Xcelerator_Clone5, 5:BayCare, 5:admindb:admindb_fake';
				EXEC admindb.dbo.shred_string @Input, N',', N':';


				-- using WITH RESULTSETS to 'refine' the output: 
				DECLARE @Input nvarchar(MAX) = N'7:Xclelerator:Xcelerator_Clone5, 5:BayCare, 5:admindb:admindb_fake';
				EXEC admindb.dbo.shred_string @Input, N',', N':'
				WITH RESULT SETS ( 
					(
						row_id int, 
						database_id int, 
						database_name sysname, 
						metadata_database sysname
					)
				);

*/

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

	-- {copyright}

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