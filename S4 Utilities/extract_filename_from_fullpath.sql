/*


		Test Cases: 
			SELECT dbo.[extract_filename_from_fullpath](N'D:\SQLData\TeamSupportNA4_63127479.ldf');

			SELECT dbo.[extract_filename_from_fullpath](N'D:\SQLData\TeamSupport45\TeamSupportNA4_63127479.ldf');

			SELECT dbo.[extract_filename_from_fullpath](N'\\backups\serverx\filename.ext');


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.extract_filename_from_fullpath','FN') IS NOT NULL
	DROP FUNCTION dbo.[extract_filename_from_fullpath];
GO

CREATE FUNCTION dbo.[extract_filename_from_fullpath] (@FullFileName nvarchar(2000))
RETURNS sysname
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output sysname;
		DECLARE @delimiter sysname = N'\'; -- hard-coded for now, but needs to be diff with linux... 

		WITH parts AS ( 
			SELECT 
				row_id, 
				[result]
			FROM 
				dbo.[split_string](@FullFileName, @delimiter, 1)
		)
		SELECT 
			@output = [result]
		FROM 
			[parts] 
		WHERE 
			row_id = (SELECT MAX(row_id) FROM [parts]);
    	
    	RETURN @output;
    
    END;
GO