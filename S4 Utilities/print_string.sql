/*
	OVERVIEW:
		T-SQL's PRINT is great - but ONLY prints up to the first 4K characters - then simply STOPS writing things out. 
		Use dbo.print_long_string when you want to print EVERYTHING within a ... long string. 


TODO: 
    set a dbo.options 'setting'/option to REMOVE/SQUELCH the warning I'm printing out if/when no-whitespace-per-current-4K-gap. 
        DON'T make this a parameter for the sproc. just don't care... but do care enough-ish to make it an OPTION.
        but ... won't EVEN set a default for it (will just CHECK in the sproc below to see if there's a match/value and then USE whatever I get back to handle print warning OR NOT). 


	SAMPLE TEST(s)

				DECLARE @longLine nvarchar(MAX) = N'0000. This is a line of Text and Stuff.';

				DECLARE @current int = 1; 
				WHILE @current < 1001 BEGIN 
					-- NOTE: comment/uncomment lines below to test execution with carriage returns or not... 
					--SET @longLine = @longLine + NCHAR(13) + NCHAR(10) + RIGHT(N'0000' + CAST(@current AS sysname), 4) +   N'. This is a line of Text and Stuff.';
					SET @longLine = @longLine + RIGHT(N'0000' + CAST(@current AS sysname), 4) +   N'. This is a line of Text and Stuff. ';

					SET @current = @current + 1;
				END;

				PRINT N'--------------------------------'

				EXEC [admindb].dbo.[print_long_string] @longLine;


DECLARE @a nvarchar(MAX) = REPLICATE(CAST(N'x' AS nvarchar(MAX)), 12088);
EXEC dbo.print_long_string @input = @a;
GO



-- B) Many ~75-char lines joined by CRLF => every chunk breaks on a line boundary
DECLARE @b nvarchar(MAX) =
    REPLICATE(CAST(N'SELECT col1, col2, col3 FROM dbo.SomeTable WHERE id = 12345 AND flag = 1;' AS nvarchar(MAX))
              + NCHAR(13) + NCHAR(10), 400);
EXEC dbo.print_long_string @input = @b;
GO

-- C) 11,000 chars of no whitespace, then 9,000 chars of words
--    => 2 NOTEs, then word-wrapped chunks
DECLARE @c nvarchar(MAX) =
      REPLICATE(CAST(N'x' AS nvarchar(MAX)), 11000)
    + REPLICATE(CAST(N'word ' AS nvarchar(MAX)), 1800);
EXEC dbo.print_long_string @input = @c;
GO



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.print_long_string','P') IS NOT NULL
	DROP PROC dbo.print_long_string;
GO

CREATE PROC dbo.print_long_string 
	@input				nvarchar(MAX)
AS
	SET NOCOUNT ON; 

	-- {copyright}

	IF @input IS NULL 
		RETURN 0; 

    DECLARE @maxPrintLength int = 4000;
	DECLARE @totalLength int = DATALENGTH(@input) / 2;  /* LEN() ignores trailing spaces */
	DECLARE @cr nchar(1) = NCHAR(13), @lf nchar(1) = NCHAR(10), @tab nchar(1) = NCHAR(9), @space nchar(1) = N' ';

	DECLARE @currentPosition int  = 1;  
	DECLARE @currentGulp nvarchar(4000), @reversedGulp nvarchar(4000), @currentGulpLength int;
	DECLARE @chunkLength int, @reverseSpace int, @reverseTab int, @targetBreak int; /* 1-based position of the break char within @currentGulp */

	IF @totalLength <= @maxPrintLength BEGIN 
		PRINT @input;
		RETURN 0;
	END;	

    WHILE @currentPosition <= @totalLength BEGIN
        IF @totalLength - @currentPosition + 1 <= @maxPrintLength
        BEGIN
            PRINT SUBSTRING(@input, @currentPosition, @maxPrintLength);
            BREAK;
        END;

        SET @currentGulp = SUBSTRING(@input, @currentPosition, @maxPrintLength);
        SET @currentGulpLength = DATALENGTH(@currentGulp) / 2;
        SET @reversedGulp = REVERSE(@currentGulp);

        /*-----------------------------------------------------------------------------------------------------
        -- Attempt to Break on CRLFs first (if present within the current gulp of 4K chars):
        -----------------------------------------------------------------------------------------------------*/
        SET @targetBreak = CHARINDEX(@LF, @reversedGulp COLLATE Latin1_General_BIN2);
        IF @targetBreak > 0 BEGIN
            SET @targetBreak = @currentGulpLength - @targetBreak + 1;
            SET @chunkLength = @targetBreak - 1;

            IF @chunkLength > 0 AND UNICODE(SUBSTRING(@currentGulp, @chunkLength, 1)) = 13
                SET @chunkLength -= 1;   /* drop the CR of a CRLF pair - i.e., avoid EXTRA (blank) lines... */

            PRINT SUBSTRING(@currentGulp, 1, @chunkLength);  
            SET @currentPosition += @targetBreak;
            CONTINUE;
        END;

        /*-----------------------------------------------------------------------------------------------------
        -- Attempt to Break on TAB/SPACE if present... :
        -----------------------------------------------------------------------------------------------------*/
        SET @reverseSpace = CHARINDEX(@space, @reversedGulp COLLATE Latin1_General_BIN2);
        SET @reverseTab = CHARINDEX(@tab, @reversedGulp COLLATE Latin1_General_BIN2);

        SET @targetBreak = CASE
            WHEN @reverseSpace      = 0             THEN @reverseTab
            WHEN @reverseTab        = 0             THEN @reverseSpace
            WHEN @reverseSpace      < @reverseTab   THEN @reverseSpace
            ELSE @reverseTab
        END;

        IF @targetBreak > 0 AND @targetBreak < @currentGulpLength BEGIN
            SET @targetBreak = @currentGulpLength - @targetBreak + 1;
            PRINT SUBSTRING(@currentGulp, 1, @targetBreak - 1);
            SET @currentPosition += @targetBreak;                     /* same as above - skip/avoid dumping current whitespace char into output */
            CONTINUE;
        END;

        /*-----------------------------------------------------------------------------------------------------
        -- no whitespace (crlf, space, tab) ... so, dump a .. note:
        -----------------------------------------------------------------------------------------------------*/
        PRINT SUBSTRING(@currentGulp, 1, @maxPrintLength);
        PRINT N'-- dbo.print_string: NO whitespace found in previous gulp of 4000 characters... ';
        SET @currentPosition += @maxPrintLength;
    END;

	RETURN 0;
GO