/*
	Obviously, PRINT 'xyz' is how to print. 
	Only, sometimes you'll need to print something with a LENGTH > 4K characters. 

	That's what this sproc does. (It just keeps spitting out 4k chunks until the 'print' operation is done.) 

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