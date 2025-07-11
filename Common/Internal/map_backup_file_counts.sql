/*
		Uses a ROW-MAP to assign file-counts - based on size. 
			where a ROW-MAP is 5x rows - first is a 'slot' for 1 file, second is a slot for 2 files, 3rd is for 4 files, and so on (see file_counts CTE below for details). 
			And the VALUE we care about for each slot/row is ... the SIZE (cut-off). 

			i.e., with the logic above and an @SizeMap of N'10,40,80,120'
				a DB 39GB in size comes in just UNDER 40 - or ROW #2 - so ... 2 files
				If the DB had been 41 GB, it'd have been > 40 - or into ROW #3 - i.e., 4 files. 


		EXAMPLES: 
			SELECT admindb.dbo.map_backup_file_counts(N'10,40,80,120', 39);  -- 2 files for a 39GB db. 

			SELECT admindb.dbo.map_backup_file_counts(N'10,40,80,120', 41);  -- 4 files for a 41GB db. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[map_backup_file_counts]','FN') IS NOT NULL
	DROP FUNCTION dbo.[map_backup_file_counts];
GO

CREATE FUNCTION dbo.[map_backup_file_counts] (@SizingMap sysname, @CurrentDbSizeInGB int)
RETURNS int
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @fileCount int;
    	
		WITH file_counts AS ( 
			SELECT * FROM (VALUES(1, 1),(2, 2),(3, 4),(4, 6), (5, 8)) fc(row_id, file_count)
		), 
		extracted AS ( 
			SELECT 
				[row_id],
				CAST([result] AS int) [result]
			FROM 
				dbo.[split_string](@SizingMap, N',', 1)
	
		), 
		matched AS ( 
			SELECT 
				MAX([row_id]) + 1 [row_id]
			FROM 
				[extracted] 
			WHERE 
				[result] <= @CurrentDbSizeInGB
		) 

		SELECT 
			@fileCount = [x].[file_count]
		FROM 
			[matched] [m]
			INNER JOIN [file_counts] [x] ON [m].[row_id] = [x].[row_id];    	
    	
    	RETURN @fileCount;
    
    END;
GO