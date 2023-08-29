/*

	NOTE: 
		- This is a FAIRLY anemic implementation. 
			- it's primarily for RE-HYDRATING xml that was nested into FOR XML() 
				... operations - like within dbo.execute_command (when output of
				execute_command is xml result-data... etc. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.xml_decode','FN') IS NOT NULL
	DROP FUNCTION dbo.[xml_decode];
GO

CREATE FUNCTION dbo.[xml_decode] (@Input nvarchar(MAX), @TransformLtAndGtOnly bit = 0)
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output nvarchar(MAX);

		-- https://stackoverflow.com/a/1091953

		SET @output = REPLACE(@Input, N'&lt;', N'<');
		SET @output = REPLACE(@output, N'&gt;', N'>');

		IF @TransformLtAndGtOnly = 0 BEGIN
    		SET @output = REPLACE(@output, N'&amp;', N'&');
    		SET @output = REPLACE(@output, N'&apos;', N'''');
    		SET @output = REPLACE(@output, N'&quot;', N'"');
    	END;

    	RETURN @output;
    
    END;
GO