/*
	Obviously, PRINT 'xyz' is how to print. 
	Only, sometimes you'll need to print something with a LENGTH > 4K characters. 

	That's what this sproc does. (It just keeps spitting out 4k chunks until the 'print' operation is done.) 


    vNEXT: 
        add in an optional @Delimiter sysname ... parameter... 
            and... when it's present then: 
                a) get it's length and substract that from the 4K 'gulps' we're spitting out and
                b) use it to signify start/end... of a 'chunk'. 

            COULD be something as simple as ***** 
                and... maybe I need an @StartDelimiter and an @EndDelimiter ... 
                    so... |****** and *****| might work or whatever... 
                        the idea that these'd make it super easy to see where something started or finished. 

            ALSO. 
                I might not really need to SUBSTRACT this from the length... i might just spit chunk/gulp ... then PRINT delimiter then print chunk/gulp... etc.

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