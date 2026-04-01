/*
	INTERNAL

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.normalize_file_path','FN') IS NOT NULL
	DROP FUNCTION dbo.[normalize_file_path];
GO

CREATE FUNCTION dbo.[normalize_file_path] (@FilePath nvarchar(400))
RETURNS nvarchar(400)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output nvarchar(400) = @FilePath;
    	
		IF(RIGHT(@FilePath, 1) = N'\')
			SET @output = LEFT(@FilePath, LEN(@FilePath) - 1);    	
    	
    	RETURN @output;
    
    END;
GO