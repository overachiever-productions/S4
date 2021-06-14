/*


		Test Cases: 
			SELECT dbo.[extract_directory_from_fullpath](N'D:\SQLData\TeamSupportNA4_63127479.ldf');

			SELECT dbo.[extract_directory_from_fullpath](N'D:\SQLData\TeamSupport45\TeamSupportNA4_63127479.ldf');

			SELECT dbo.[extract_directory_from_fullpath](N'\\backups\serverx\filename.ext');


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.extract_directory_from_fullpath','FN') IS NOT NULL
	DROP FUNCTION dbo.[extract_directory_from_fullpath];
GO

CREATE FUNCTION dbo.[extract_directory_from_fullpath] (@FullFileName nvarchar(2000))
RETURNS sysname
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output sysname = N'';
		DECLARE @delimiter sysname = N'\'; -- hard-coded for now, but needs to be diff with linux... 

		DECLARE @isUncPath bit = 0; 
		IF @FullFileName LIKE N'\\%' SET @isUncPath = 1;

		WITH parts AS ( 
			SELECT 
				row_id, 
				[result]
			FROM 
				dbo.[split_string](@FullFileName, @delimiter, 1)
		)
		SELECT 
			@output = @output + [result] + @delimiter
		FROM 
			parts 
		WHERE 
			row_id <> (SELECT MAX(row_id) FROM [parts])
		ORDER BY 
			row_id;

		SELECT @output = dbo.normalize_file_path(@output);

		IF @isUncPath = 1 SET @output = @delimiter + @output;

    	RETURN @output;
    END;
GO