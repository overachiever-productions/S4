/*

	NOTE: 
		Maxes out at 350 Hours - i.e., can't set a delay > 2weeks (336) and some change... 

	Outputs the 'hh:mm:ss.xxx' for a WAITFOR DELAY statement/operation.
	

    TESTS / SIGNATURES: 

        -- expect error (month not valid): 

                DECLARE @output sysname, @error nvarchar(MAX); 
                EXEC admindb.dbo.translate_vector_delay 
                    @Vector = N'1 month', 
                    @Output = @output OUTPUT, 
                    @Error = @error OUTPUT; 

        -- expect an exception (> 48 hours): 

                DECLARE @output sysname, @error nvarchar(MAX); 
                EXEC admindb.dbo.translate_vector_delay 
                    @Vector = N'53 hours',     
                    @Output = @output OUTPUT, 
                    @Error = @error OUTPUT; 


        -- expect 2 hours and 3 minutes: 

                DECLARE @output sysname, @error nvarchar(MAX); 
                EXEC admindb.dbo.translate_vector_delay 
                    @Vector = N'123 minutes',     
                    @Output = @output OUTPUT, 
                    @Error = @error OUTPUT;

                SELECT @error, @output;

        -- expect 800ms: 

                DECLARE @output sysname, @error nvarchar(MAX); 
                EXEC admindb.dbo.translate_vector_delay 
                    @Vector = N'800 ms',     
                    @Output = @output OUTPUT, 
                    @Error = @error OUTPUT;

                SELECT @error, @output;

        -- expect 1.2 seconds: 

                DECLARE @output sysname, @error nvarchar(MAX); 
                EXEC admindb.dbo.translate_vector_delay 
                    @Vector = N'1200 milliseconds',     
                    @Output = @output OUTPUT, 
                    @Error = @error OUTPUT;

                SELECT @error, @output;
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector_delay','P') IS NOT NULL
	DROP PROC dbo.translate_vector_delay;
GO

CREATE PROC dbo.translate_vector_delay
	@Vector								sysname     	= NULL, 
	@ParameterName						sysname			= NULL, 
	@Output								sysname			= NULL		OUT, 
	@Error								nvarchar(MAX)	= NULL		OUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @difference int;

	EXEC dbo.translate_vector 
		@Vector = @Vector, 
		@ValidationParameterName = @ParameterName,
		@ProhibitedIntervals = N'DAY,WEEK,MONTH,QUARTER,YEAR',  -- days are overkill for any sort of WAITFOR delay specifier (that said, 38 HOURS would work... )  
		@Output = @difference OUTPUT, 
		@Error = @Error OUTPUT;

	IF @difference > 187200100 BEGIN 
		RAISERROR(N'@Vector can not be > 52 Hours when defining a DELAY value.', 16, 1);
		RETURN -2;
	END; 

	IF @Error IS NOT NULL BEGIN 
		RAISERROR(@Error, 16, 1); 
		RETURN -5;
	END;
	
	SELECT @Output = RIGHT(dbo.[format_timespan](@difference), 12);

	RETURN 0;
GO