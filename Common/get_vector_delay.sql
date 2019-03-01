

/*




*/


IF OBJECT_ID('dbo.get_vector_delay','P') IS NOT NULL
	DROP PROC dbo.get_vector_delay;
GO

CREATE PROC dbo.get_vector_delay
	@Vector					nvarchar(10)	= NULL, 
	@ParameterName			sysname			= NULL, 
	@Output					sysname			= NULL		OUT, 
	@Error					nvarchar(MAX)	= NULL		OUT
AS 
	SET NOCOUNT ON; 

	-- {copyright} 

	DECLARE @difference int;

	EXEC admindb.dbo.[get_vector]
	    @Vector = @Vector,
	    @ParameterName = @ParameterName,
	    @AllowedIntervals = N's,m,h',
	    @DatePart = N'MILLISECOND',
	    @Difference = @difference OUTPUT,
	    @Error = @Error OUTPUT;

	IF @Error IS NOT NULL BEGIN 
		RAISERROR(@Error, 16, 1); 
		RETURN -5;
	END;
	
	SELECT @Output = RIGHT([admindb].dbo.[format_timespan](@difference), 12);

	RETURN 0;
GO