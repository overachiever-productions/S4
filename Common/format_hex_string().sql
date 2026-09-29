/*

    - Formats a HEX value AS a string. 
    - For the version of this logic that formats HEX as HEX data, see dbo.format_hex. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_hex_string','FN') IS NOT NULL
	DROP FUNCTION dbo.[format_hex_string];
GO

CREATE FUNCTION dbo.[format_hex_string] (@hex_data varbinary(MAX), @prefix nvarchar(MAX), @format_width int, @left_padding int)
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output nvarchar(MAX) = N'';
    	DECLARE @inputString nvarchar(MAX) = ISNULL(@prefix, N'') + CONVERT(nvarchar(MAX), @hex_data, 1) + N';';
        DECLARE @current int = 1;
        DECLARE @substring nvarchar(MAX);
        DECLARE @first bit = 1;
        
        WHILE @current <= LEN(@inputString) BEGIN
            SET @substring = SUBSTRING(@inputString, @current, @format_width);
	        
            IF @left_padding > 0 BEGIN 
                IF @first = 1 BEGIN
                    SET @first = 0;
                    --SET @substring = @substring + SUBSTRING(REPLACE(@inputString, @prefix, N''), @current, @left_padding);
                    --SET @current = @current + @left_padding;
                  END;
                ELSE
                    SET @substring = REPLICATE(N' ', @left_padding) + @substring;
            END;

	        SET @output = @output + @substring + CHAR(13) + CHAR(10);

	        SET @current = @current + @format_width;
        END;    	
    	
        SET @output = LEFT(@output, LEN(@output) - 2);

    	RETURN @output;
    END;
GO