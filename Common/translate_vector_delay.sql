

/*

	Outputs the 'hh:mm:ss.xxx' for a WAITFOR DELAY statement/operation.
	

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector_delay','P') IS NOT NULL
	DROP PROC dbo.translate_vector_delay;
GO

CREATE PROC dbo.translate_vector_delay
	@Vector					nvarchar(10)	= NULL, 
	@ParameterName			sysname			= NULL, 
	@Output					sysname			= NULL		OUT, 
	@Error					nvarchar(MAX)	= NULL		OUT
AS 
	SET NOCOUNT ON; 

	-- {copyright} 

	DECLARE @difference int;

	EXEC admindb.dbo.translate_vector 
		@Vector = @Vector, 
		@ValidationParameterName = @ParameterName,
		@ProhibitedIntervals = 'DAY,WEEK,MONTH,QUARTER,YEAR',  -- days are overkill for any sort of WAITFOR delay specifier (that said, 38 HOURS would work... )  
		@TranslationInterval = N'MILLISECOND', 
		@Output = @difference OUTPUT, 
		@Error = @Error OUTPUT;

	IF @Error IS NOT NULL BEGIN 
		RAISERROR(@Error, 16, 1); 
		RETURN -5;
	END;
	
	SELECT @Output = RIGHT([admindb].dbo.[format_timespan](@difference), 12);

	RETURN 0;
GO