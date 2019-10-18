/*
	Obviously, PRINT 'xyz' is how to print. 
	Only, sometimes you'll need to print something with a LENGTH > 4K characters. 

	That's what this sproc does. (It just keeps spitting out 4k chunks until the 'print' operation is done.) 


    vNEXT: 
        Add in a delimiter - or, at least, an OPTION for one - i.e., a BIT field only... 
            which would basically work as follows: 
                - instead of chunking at 4000 chars a pop, we chunk at 3996 (i.e., @chunkSize will have to be dynamically set in a variable based on @MarkBoundaries being 0 or 1
                - if this is chunk number 0... and @MarkBoundaries = 1... do nothing BEFORE printing. 
                - if @chunkNumber > 0 ... and we still have @chars to process... PRINT N'-- 4K characters reached by dbo.print_long_string' + @crlf + N''* /   (without spaces... sigh)... 
                
                - always end everything that we print out (except for the 'short-circuit if we don't have @chunkSize left)... 
                    with a PRINT @substring + N'/ *'  (only... don't include spaces obviously - doing that here so it doesn't break comments).


            that way we'd get something like the exact following: 

... 
... AND someValue = 1 A/*
-- 4K charactgers reached by dbo.print_long_string
*/ND this is the rest of the text 
... 
.. 
so that we're JUST inserting INLINE comments right into the middle of a statement and that it SHOULD (unless we're in the middle of inline comments (sigh)... be ignored... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.print_long_string','P') IS NOT NULL
	DROP PROC dbo.print_long_string;
GO

CREATE PROC dbo.print_long_string 
	@Input				nvarchar(MAX)
AS
	SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @totalLen int;
	SELECT @totalLen = LEN(@Input);

	IF @totalLen < 4000 BEGIN 
		PRINT @Input;
		RETURN 0; -- done
	END 

	DECLARE @chunkLocation int = 0;
	DECLARE @substring nvarchar(4000);

	WHILE @chunkLocation <= @totalLen BEGIN 
		SET @substring = SUBSTRING(@Input, @chunkLocation, 4000);
		
		PRINT @substring;

		SET @chunkLocation += 4000;
	END;

	RETURN 0;
GO