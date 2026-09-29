/*
	SCOPE / RATIONALE:
		STR() SHOULD right-align outputs ... but, the way it pads/indents is problematic. 
			This would fix the issue: https://sqlsunday.com/2018/06/12/right-align-columns-in-ssms/
			Except it doesn't account for separators ... 

		So... this admindb func accounts for:
			- decimal precision
			- right padding 
			- commas/separators 

	vNEXT:
		A. Look at some options to determine ratio of ' ' to non ' ' and add 'extra' spaces when needed (if that's even possible). 
			as in some 'fine tuning' the the approach to using 2x spaces for the equivalent of a digit. 
				AND, actually, seperator is a concern - i.e., it might be that ' ' is the same as ',' or '.' but ... not the same as '9' or whatever (in the grid view). 
			At any rate... look at addressing some logic for this down before the RETURN statement? 


		NICE: 
			https://jkorpela.fi/chars/spaces.html 
				there's such a thing as a "FIGURE SPACE" - or U+2007  ...which is a SPACE that's the same width as a figure/number.


			Commas: 
				U+002C (44) is ... the basic/standard comma
				U+FF64 (65380) is ... ideographic comma. it's ugly AND doesn't work... 
				U+FF0C (65292) - fullwidth comma is SUPPPPPPPPER close. better than normal comma i think... 

		B. Gotta fix the hard-coded 'en-US' as the default culture. 
			ideally, some sort of lookup to something like sys.languages would be key... 
				but, there's no CLR culture info there. 
			So, EITHER:
				a. I can find this via some sort of lookup to, say, the registry? 
				b. maybe there's another place it could be stored - relative to the CLR config - maybe info about the default app pool or something? 
					this was a great idea... I've searched .... everything - no dice. 
						everything =	sys.dm_os_host/etc. ... 
										sys.assembly_files, 
										sys.clr_.... everything (i.e., therea re 4x DMVs for CLR 'stuff' - nothing had this info).
				c. I create a new table in the admindb ... that can, effectively 'extend' sys.languages ... with a lang-culture (default) per each of the languages that ship with SQL Server?

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_number','FN') IS NOT NULL
	DROP FUNCTION dbo.[format_number];
GO

CREATE FUNCTION dbo.[format_number] (@Number decimal(38,6), @Length int = 14, @Decimal int = 2, @UseSeparator bit = 1, @FullWidthUnicode bit = 1, @Culture sysname = N'{DEFAULT}')
RETURNS sysname
AS
    
	-- {copyright}
    
    BEGIN; 
		SET @Length = ISNULL(@Length, 14);
		SET @Decimal = ISNULL(@Decimal, 2);
		SET @UseSeparator = ISNULL(@UseSeparator, 1);
		SET @FullWidthUnicode = ISNULL(@FullWidthUnicode, 1);
		SET @Culture = ISNULL(NULLIF(@Culture, N''), N'{DEFAULT}');

    	DECLARE @output sysname; 
		DECLARE @format sysname = N'N';
		IF @UseSeparator = 0 
			SET @format = N'F';

		IF @Decimal >= 0 BEGIN
			SET @format = @format + CAST(@Decimal AS sysname);
		  END;
		ELSE BEGIN 
			SET @format = @format  + N'0';
		END;

		IF UPPER(@Culture) = N'{DEFAULT}'
			SET @Culture = N'en-US'; /* TODO: see notes in header.  */

		SET @output = FORMAT(@Number, @format, @Culture);

		IF @Length > 0 BEGIN

			IF LEN(@output) > @Length 
				SET @output = N'..!';

			IF @FullWidthUnicode = 1 BEGIN
				DECLARE @NSpace nchar(1) = NCHAR(8199);  -- figure space (or space that's the width of a figure/number) - U+2007.
				DECLARE @NComma nchar(1) = NCHAR(65292); -- fullwidth comma - U+FF0C
				DECLARE @NDot nchar(1) = NCHAR(65294);

				SET @output = RIGHT(REPLICATE(@NSpace, (@Length - LEN(@output))) + @output, @Length);
				SET @output = REPLACE(@output, N',', @NComma);
				--SET @output = REPLACE(@output, N'.', @NDot);
			  END;
			ELSE BEGIN 
				/* This can ONLY approximate right-alignment... cuz of how ASCII/default font in SSMS/etc. provides different widths to space, comma, dot... */
				SET @output = RIGHT(REPLICATE(N' ', (@Length - LEN(@output))) + @output, @Length);
				SET @output = REPLACE(@output, N' ', N'  ');
			END;
		END;

    	RETURN @output;
    
    END;
GO