/*
	Hmmmmmm
		https://docs.microsoft.com/en-us/sql/t-sql/language-elements/sql-server-utilities-statements-backslash?view=sql-server-ver15

			interesting... what about using the \ character as a line-continuation character? 


	Obviously, PRINT is the best way to print... 
	Only, sometimes you'll need to PRINT something with a LENGTH > 4K characters. Only, PRINT terminates at the first 4K chars - period. 

	So, this sproc bypasses that - it just keeps spitting out ~4k chunks until the 'print' operation is done. 

	NOTE: dbo.print_long_string 'terminates' ~4K chunks on the last CRLF before the 4K boundary ... so that we don't truncate outputs 'mid line'... 



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

	DECLARE @totalLength int = LEN(@Input); 

	DECLARE @currentLocation int = 1; -- NOT 0 based... 
	DECLARE @chunk nvarchar(4000);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @crlfLocation int;

	IF @totalLength <= 4000 BEGIN 
		PRINT @Input;
		RETURN 0; -- done
	END;	

	WHILE @currentLocation <= @totalLength BEGIN
		SET @chunk = SUBSTRING(@Input, @currentLocation, 4001); -- final arg = POSITION (not number of chars to take).
		
		IF LEN(@chunk) = 4000 BEGIN 

			SET @crlfLocation = CHARINDEX(REVERSE(@crlf), REVERSE(@chunk));  -- get the last (in chunk) crlf... 

			IF @crlfLocation > 0 BEGIN 
				SELECT @chunk = SUBSTRING(@chunk, 0, (LEN(@chunk) - @crlfLocation));
			END;
		END;

		SET @currentLocation = @currentLocation + (LEN(@chunk));

		IF LEFT(@chunk, 2) = @crlf BEGIN 
			SET @chunk = RIGHT(@chunk, LEN(@chunk) - 2);
		END;

		PRINT @chunk;
	END;

	RETURN 0;
GO