/*


	NOTE: 
		dbo.translate_vector is primarily designed as an INTERNAL/HELPER routine - meaning: 
			- vectors (while very useful) aren't very 'friendly
			- to the point where this simply 'translates' a vector into something a bit MORE useable/viable - that can be used for timestamps and the likes. 
			- likewise, if/when timestamps are calculated using vectors, there are some Vector Intervals that won't make sense to use (i.e., maybe you don't want backups retained for MILLISECONDs? or don't want a job to run for YEARS)
				which is why there are OPTIONAL parameters for: 
					- ProhibitedIntervals
					- ValidationParameterName


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_vector','P') IS NOT NULL
	DROP PROC dbo.translate_vector;
GO

CREATE PROC dbo.translate_vector
	@Vector									sysname						= NULL, 
	@ValidationParameterName				sysname						= NULL, 
	@ProhibitedIntervals					sysname						= NULL,								-- By default, ALL intervals are allowed. 
	@TranslationInterval					sysname						= N'MS',							-- { MILLISECONDS | SECONDS | MINUTES | HOURS | DAYS | WEEKS | MONTHS | YEARS }
	@Output									bigint						= NULL		OUT, 
	@Error									nvarchar(MAX)				= NULL		OUT
AS
	SET NOCOUNT ON; 

	-- {copyright} 

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	SET @ValidationParameterName = ISNULL(NULLIF(@ValidationParameterName, N''), N'@Vector');
	IF @ValidationParameterName LIKE N'@%'
		SET @ValidationParameterName = REPLACE(@ValidationParameterName, N'@', N'');

	DECLARE @intervals table ( 
		[key] sysname NOT NULL, 
		[interval] sysname NOT NULL
	);

	INSERT INTO @intervals ([key],[interval]) 
	SELECT [key], [interval] 
	FROM (VALUES (
			'MILLISECOND', 'MILLISECOND'), ('MS', 'MILLISECOND'), ('SECOND', 'SECOND'), ('S', 'SECOND'),('MINUTE', 'MINUTE'), ('M', 'MINUTE'), 
			('N', 'MINUTE'), ('HOUR', 'HOUR'), ('H', 'HOUR'), ('DAY', 'DAY'), ('D', 'DAY'), ('WEEK', 'WEEK'), ('W', 'WEEK'),
			 ('MONTH', 'MONTH'), ('MO', 'MONTH'), ('QUARTER', 'QUARTER'), ('Q', 'QUARTER'), ('YEAR', 'YEAR'), ('Y', 'YEAR')
	) x ([key], [interval]);

	SET @Vector = LTRIM(RTRIM(UPPER(REPLACE(@Vector, N' ', N''))));
	DECLARE @boundary int, @duration sysname, @interval sysname;
	SET @boundary = PATINDEX(N'%[^0-9]%', @Vector) - 1;

	IF @boundary < 1 BEGIN 
		SET @Error = N'Invalid Vector format specified for parameter @' + @ValidationParameterName + N'. Format must be in ''XX nn'' or ''XXnn'' format - where XX is an ''integer'' duration (e.g., 72) and nn is an interval-specifier (e.g., HOUR, HOURS, H, or h).';
		RETURN -1;
	END;

	SET @duration = LEFT(@Vector, @boundary);
	SET @interval = UPPER(REPLACE(@Vector, @duration, N''));

	IF @interval LIKE '%S' AND @interval NOT IN ('S', 'MS')
		SET @interval = LEFT(@interval, LEN(@interval) - 1); 

	IF NOT @interval IN (SELECT [key] FROM @intervals) BEGIN
		SET @Error = N'Invalid interval specifier defined for @' + @ValidationParameterName + N'. Valid interval specifiers are { [MILLISECOND(S)|MS] | [SECOND(S)|S] | [MINUTE(S)|M|N] | [HOUR(S)|H] | [DAY(S)|D] | [WEEK(S)|W] | [MONTH(S)|MO] | [QUARTER(S)|Q] | [YEAR(S)|Y] }';
		RETURN -10;
	END;

	-- convert @TranslationInterval to a sanitized version of itself:
	SELECT @TranslationInterval = [interval] FROM @intervals WHERE [key] = @TranslationInterval;
	IF @TranslationInterval IS NULL OR @TranslationInterval NOT IN ('MILLISECOND', 'SECOND', 'MINUTE', 'HOUR', 'DAY', 'MONTH', 'YEAR') BEGIN 
		SET @Error = N'Invalid @TranslationInterval value specified. Allowed values are: { [MILLISECOND(S)|MS] | [SECOND(S)|S] | [MINUTE(S)|M|N] | [HOUR(S)|H] | [DAY(S)|D] | [WEEK(S)|W] | [MONTH(S)|MO] | [YEAR(S)|Y] }.';
		RETURN -12;
	END;

	--  convert @interval to a sanitized version of itself:
	SELECT @interval = [interval] FROM @intervals WHERE [key] = @interval;

	-- allow for prohibited intervals: 
	IF NULLIF(@ProhibitedIntervals, N'') IS NOT NULL BEGIN 

		-- delete INTERVALS based on keys - e.g., if ms is prohibited, we don't want to simply delete the MS entry - we want to get all 'forms' of it (i.e., MS, MILLISECOND, etc.)
		DELETE FROM @intervals WHERE [interval] IN (SELECT [interval] FROM @intervals WHERE [key] IN (SELECT [result] FROM dbo.[split_string](@ProhibitedIntervals, N',', 1)));
		
		IF @interval NOT IN (SELECT [interval] FROM @intervals) BEGIN
			SET @Error = N'The interval-specifier [' + @interval + N'] is not permitted in this operation type. Prohibited intervals for this operation are: [' + @ProhibitedIntervals + N'].';
			RETURN -30;
		END;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @now datetime = GETDATE();
	
	BEGIN TRY 

		DECLARE @command nvarchar(400) = N'SELECT @difference = DATEDIFF(' + @TranslationInterval + N', @now, (DATEADD(' + @interval + N', ' + @duration + N', @now)));'
		EXEC sp_executesql 
			@command, 
			N'@now datetime, @difference int OUTPUT', 
			@now = @now, 
			@difference = @Output OUTPUT;

	END TRY 
	BEGIN CATCH
		SELECT @Error = N'EXCEPTION: ' + CAST(ERROR_MESSAGE() AS sysname) + N' - ' + ERROR_MESSAGE();
		RETURN -30;
	END CATCH

	RETURN 0;
GO

	