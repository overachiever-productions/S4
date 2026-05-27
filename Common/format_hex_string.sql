/*

    - Formats a HEX value AS a string. 
    - For the version of this logic that formats HEX as HEX data, see dbo.format_hex. 

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.format_hex_string', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[format_hex_string];
GO

CREATE FUNCTION dbo.[format_hex_string] (
    @hex_data               varbinary(MAX), 
    @max_width              int                 = 220, 
    @per_row_padding        int                 = 0, 
    @first_line_padding     int                 = 0
)
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	DECLARE @output nvarchar(MAX) = N'';
    	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

        DECLARE @currentIndex int = 1; 
        DECLARE @substring nvarchar(MAX) = N''; 
        DECLARE @hexString nvarchar(MAX) = CONVERT(nvarchar(MAX), @hex_data, 1);
        DECLARE @rowWidth int;

        WHILE @currentIndex <= LEN(@hexString) BEGIN
            IF @substring = N''
                SET @rowWidth = @max_width - @per_row_padding - @first_line_padding;
            ELSE
                 SET @rowWidth = @max_width - @per_row_padding;

            SET @substring = SUBSTRING(@hexString, @currentIndex, @rowWidth);
            IF LEN(@substring) = @rowWidth SET @substring = @substring + @crlf;

            IF @per_row_padding > 0 SET @substring = REPLICATE(N' ', @per_row_padding) + @substring;

            SET @output = @output + @substring;
            SET @currentIndex = @currentIndex + @rowWidth;
        END;  
    	
    	RETURN @output;
    
    END;
GO