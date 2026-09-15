/*

    POSSIBLE refactor: 
        format_aligned_text_width... 


    EXAMPLES: 
        Very Simple Examples: 


                SELECT N'|' + dbo.[format_text_width](N'This is some text', 25, N'RIGHT') + N'|';

                SELECT N'|' + dbo.[format_text_width](N'This is some text', 25, N'LEFT') + N'|';

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.format_text_width', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[format_text_width];
GO

CREATE FUNCTION dbo.[format_text_width] (@input nvarchar(MAX), @max_width int, @align sysname = N'LEFT')
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output nvarchar(MAX);
    	SET @output = @input;

    	IF LEN(@input) > @max_width 
            SET @output = LEFT(@input, @max_width - 1) + CAST(CHAR(133) AS nchar(1));
    	
    	IF @align <> N'RIGHT' BEGIN
            SET @output = LEFT(@output + REPLICATE(N' ', @max_width), @max_width);
          END;
        ELSE BEGIN
            SET @output = RIGHT(REPLICATE(N' ', @max_width) + @output, @max_width);
        END;

    	RETURN @output;
    
    END;
GO

