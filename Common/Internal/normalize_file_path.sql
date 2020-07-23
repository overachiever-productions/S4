/*
	INTERNAL

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.normalize_file_path','FN') IS NOT NULL
	DROP FUNCTION dbo.[normalize_file_path];
GO

CREATE FUNCTION dbo.[normalize_file_path] (@FilePath sysname)
RETURNS sysname
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output sysname;
    	
		IF(RIGHT(@FilePath, 1) = N'\')
			SET @output = LEFT(@FilePath, LEN(@FilePath) - 1);    	
    	
    	RETURN @output;
    
    END;
GO