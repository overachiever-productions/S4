/*

	TODO: 
		- Account for ENCRYPTED sprocs/etc... 
				righnt now this just spits out a big fat NULL when sprocs are ENCRYPTED... 
					- initial fix = determine if sproc is encrypted and put in #encrypted# instead of NULL... 
						(or just ISNULL(x, '#encrypted#') or whatever... 

					- longer term: undo the encryption and extract the lines 
						AFTER testing to ensure that ... encrypted extraction lines actually match-up as expected... 
	
		- Add error handling... cuz there's NONE currently.

		- also, with the EXCEPTION of the need to target a specific database, this could be done as a scalar UDF quite well/nicely... 
			can't remember if we can make TEMPORARY scalar UDFs (seems like not), but that'd be a clean way to do this too... 
				i.e., UPDATE trace_data SET bad_statement = #extract_statement(object_id, start, end)... 


				that said, here's why this sproc exists. 
					frequently - when extracting data (especially from XE and other traces)... here's how that looks: 
						a) I'm 'in' database XYZ - which is something like <clientName>_BlockingDataFromXyz
						b) i've got a READ_ONLY copy of their db (via DBCC CLONEDATABASE) called ... <client>X
						... and i have to 'burrow' into that second db to get the statement details.. 
							and... i can't really create a UDF in there... so that I could do SELECT <clientX>.dbo.UdfVariant(x, y, z)... 


							
DECLARE @Statement nvarchar(MAX);
EXEC dbo.[extract_statement]
    @TargetDatabase = 'Xcelerator4', -- sysname
    @ObjectID = 1288365096, -- int
    @OffsetStart = 48872, -- int
    @OffsetEnd = 48922, -- int
    @Statement = @Statement OUTPUT;

SELECT @Statement;


*/

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

	-- {copyright}

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