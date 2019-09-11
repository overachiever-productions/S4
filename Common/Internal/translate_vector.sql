/*

	TODO:
		- add overflow protection for ALL interval types... 
			i.e., do ABS on the @value ... and then ... for the @intervalType... run a check BEFORE doing DATEDIFF and explain what's up (if the interval/value is too large).


	TODO/REFACTOR:
		- @TranslationDatePart is about as stupid/generic/confusing as possible. 
			change it to @OutputInterval or @TargetInveralType or @TargetDatePart or ... something. 

		- make it so that SECONDs/SECOND are both equally valid inputs (i.e., see the 'failing' test case in the sigs/tests section. 
			i need to be able to PARSE 'intervals' easily/repeatedly (i don't know that I want to extract this logic from dbo.parse_vector into ... parse_interval... 
				(and then have parse_vector ... use parse_interval to get the interval and then derive/determine the value... )
					cuz... that seems almost obscene in terms of avoiding DRY... but, it probably makes the MOST sense long-term and... for DRY... 




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

        TESTS / SIGNATURES: 


                -- expect error - backups aren't handled by this code: 

                            DECLARE @output bigint, @error nvarchar(max); 
                            EXEC dbo.translate_vector 
                                @Vector = N'4 backups', 
                                @Output = @output OUTPUT, 
                                @Error = @error OUTPUT; 

                            SELECT @output, @error;
                            GO

                -- translate 1200 milliseconds into... milliseconds. 

                            DECLARE @output bigint, @error nvarchar(max); 
                            EXEC dbo.translate_vector 
                                @Vector = N'1200 milliseconds', 
                                @Output = @output OUTPUT, 
                                @Error = @error OUTPUT; 

                            SELECT @output, @error;
                            GO
				
				-- translate 1200 milliseconds into... seconds. 

                            DECLARE @output bigint, @error nvarchar(max); 
                            EXEC dbo.translate_vector 
                                @Vector = N'1200 milliseconds', 
								@TranslationDatePart = 'SECOND',   -- note value is SECOND... but SECONDs works... 
                                @Output = @output OUTPUT, 
                                @Error = @error OUTPUT; 

                            SELECT @output, @error;
                            GO


				-- TODO: make this test/scenario WORK (i.e. SECONDs __SHOULD___ be allowed).
				-- translate 1200 milliseconds into... seconds. 

                            DECLARE @output bigint, @error nvarchar(max); 
                            EXEC dbo.translate_vector 
                                @Vector = N'1200 milliseconds', 
								@TranslationDatePart = 'SECONDS',   -- note value is SECOND... but SECONDs works... 
                                @Output = @output OUTPUT, 
                                @Error = @error OUTPUT; 

                            SELECT @output, @error;
                            GO







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