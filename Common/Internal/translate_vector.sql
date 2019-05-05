/*


	NOTE: 
		dbo.translate_vector is primarily designed as an INTERNAL/HELPER routine - meaning: 
			- vectors (while very useful) aren't very 'friendly
			- to the point where this simply 'translates' a vector into something a bit MORE useable/viable - that can be used for timestamps and the likes. 
			- likewise, if/when timestamps are calculated using vectors, there are some Vector Intervals that won't make sense to use (i.e., maybe you don't want backups retained for MILLISECONDs? or don't want a job to run for YEARS)
				which is why there are OPTIONAL parameters for: 
					- ProhibitedIntervals
					- ValidationParameterName


		an interval is 2 things: 
			- a number/value
			- an interval (i.e., similar to a date part - OR 'backup')


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector','P') IS NOT NULL
	DROP PROC dbo.translate_vector;
GO

CREATE PROC dbo.translate_vector
	@Vector									sysname						= NULL, 
	@ValidationParameterName				sysname						= NULL, 
	@ProhibitedIntervals					sysname						= NULL,								
	@TranslationDatePart					sysname						= N'MILLISECOND',					-- The 'DATEPART' value you want to convert BY/TO. Allowed Values: { MILLISECONDS | SECONDS | MINUTES | HOURS | DAYS | WEEKS | MONTHS | YEARS }
	@Output									bigint						= NULL		OUT, 
	@Error									nvarchar(MAX)				= NULL		OUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------

	-- convert @TranslationDatePart to a sanitized version of itself:
	IF @TranslationDatePart IS NULL OR @TranslationDatePart NOT IN ('MILLISECOND', 'SECOND', 'MINUTE', 'HOUR', 'DAY', 'MONTH', 'YEAR') BEGIN 
		SET @Error = N'Invalid @TranslationDatePart value specified. Allowed values are: { [MILLISECOND(S)|MS] | [SECOND(S)|S] | [MINUTE(S)|M|N] | [HOUR(S)|H] | [DAY(S)|D] | [WEEK(S)|W] | [MONTH(S)|MO] | [YEAR(S)|Y] }.';
		RETURN -12;
	END;

	IF @ProhibitedIntervals IS NULL
		SET @ProhibitedIntervals = N'BACKUP';

	IF dbo.[count_matches](@ProhibitedIntervals, N'BACKUP') < 1
		SET @ProhibitedIntervals = @ProhibitedIntervals + N', BACKUP';

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @interval sysname;
	DECLARE @duration bigint;

	EXEC dbo.parse_vector 
		@Vector = @Vector, 
		@ValidationParameterName  = @ValidationParameterName, 
		@ProhibitedIntervals = @ProhibitedIntervals, 
		@IntervalType = @interval OUTPUT, 
		@Value = @duration OUTPUT, 
		@Error = @errorMessage OUTPUT; 

	IF @errorMessage IS NOT NULL BEGIN 
		SET @Error = @errorMessage;
		RETURN -10;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @now datetime = GETDATE();
	
	BEGIN TRY 

		DECLARE @command nvarchar(400) = N'SELECT @difference = DATEDIFF(' + @TranslationDatePart + N', @now, (DATEADD(' + @interval + N', ' + CAST(@duration AS sysname) + N', @now)));'
		EXEC sp_executesql 
			@command, 
			N'@now datetime, @difference bigint OUTPUT', 
			@now = @now, 
			@difference = @Output OUTPUT;

	END TRY 
	BEGIN CATCH
		SELECT @Error = N'EXCEPTION: ' + CAST(ERROR_MESSAGE() AS sysname) + N' - ' + ERROR_MESSAGE();
		RETURN -30;
	END CATCH

	RETURN 0;
GO	