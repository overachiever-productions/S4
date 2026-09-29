/*
	OVERVIEW:
		T-SQL's PRINT is great - but ONLY prints up to the first 4K characters - then simply STOPS writing things out. 
		Use dbo.print_long_string when you want to print EVERYTHING within a ... long string. 


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

	IF @Input IS NULL 
		RETURN 0; 

	DECLARE @totalLength int = LEN(@Input); 
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	IF @totalLength <= 4000 BEGIN 
		PRINT @Input;
		RETURN 0;
	END;	

	DECLARE @currentLocation int = 1; -- NOT 0 based... 
	DECLARE @chunk nvarchar(4000);
	DECLARE @crlfLocation int;
	
	CREATE TABLE #chunks (
		row_id int IDENTITY(1,1) NOT NULL, 
		row_data nvarchar(MAX) NOT NULL 
	); 

	INSERT INTO [#chunks] ([row_data])
	SELECT [result] FROM dbo.[split_string](@Input, @crlf, 1);

	IF (SELECT COUNT(*) FROM [#chunks]) > 1 BEGIN 
		DECLARE @rowData nvarchar(MAX);
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT row_data FROM [#chunks] ORDER BY [row_id];
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @rowData;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			IF LEN(@rowData) > 4000 BEGIN 
				SET @totalLength = LEN(@rowData);
				WHILE @currentLocation <= @totalLength BEGIN
					SET @chunk = SUBSTRING(@rowData, @currentLocation, 4001); -- final arg = POSITION (not number of chars to take).
					
					SET @currentLocation = @currentLocation + (LEN(@chunk));

					PRINT @chunk;
				END;
			  END; 
			ELSE 
				PRINT @rowData; 

			FETCH NEXT FROM [walker] INTO @rowData;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		RETURN 0;
	END; 

	-- Otherwise, if we're still here... 
	SET @totalLength = LEN(@Input);
	WHILE @currentLocation <= @totalLength BEGIN
		SET @chunk = SUBSTRING(@Input, @currentLocation, 4001); -- final arg = POSITION (not number of chars to take).

		SET @currentLocation = @currentLocation + (LEN(@chunk));

		PRINT @chunk; 
	END;

	RETURN 0;
GO