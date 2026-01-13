/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.remove_whitespace', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[remove_whitespace];
GO

CREATE FUNCTION dbo.[remove_whitespace] (@text nvarchar(MAX))
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output nvarchar(MAX) = @text;

        SET @output = REPLACE(@output, N' ', N'');
        SET @output = REPLACE(@output, NCHAR(13), N'');
        SET @output = REPLACE(@output, NCHAR(10), N'');
        SET @output = REPLACE(@output, NCHAR(9), N'');
    	
    	RETURN @output;
    
    END;
GO