/*

	NOTE: 
		Maxes out at 350 Hours - i.e., can't set a delay > 2weeks (336) and some change... 

	Outputs the 'hh:mm:ss.xxx' for a WAITFOR DELAY statement/operation.
	

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector_delay','P') IS NOT NULL
	DROP PROC dbo.translate_vector_delay;
GO

CREATE PROC dbo.translate_vector_delay
	@Vector								nvarchar(10)	= NULL, 
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
		@ProhibitedIntervals = 'DAY,WEEK,MONTH,QUARTER,YEAR',  -- days are overkill for any sort of WAITFOR delay specifier (that said, 38 HOURS would work... )  
		@Output = @difference OUTPUT, 
		@Error = @Error OUTPUT;

	IF @difference > 1260000 BEGIN 
		RAISERROR(N'@Vector can not be > 350 Hours (i.e., 2+ weeks) when defining a DELAY value.', 16, 1);
		RETURN -2;
	END; 

	IF @Error IS NOT NULL BEGIN 
		RAISERROR(@Error, 16, 1); 
		RETURN -5;
	END;
	
	SELECT @Output = RIGHT(dbo.[format_timespan](@difference), 12);

	RETURN 0;
GO