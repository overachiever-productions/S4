/*

	-- TODO: backups... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.parse_vector','P') IS NOT NULL
	DROP PROC dbo.parse_vector;
GO

CREATE PROC dbo.parse_vector
	@Vector									sysname					, 
	@ValidationParameterName				sysname					= NULL,
	@ProhibitedIntervals					sysname					= NULL,				-- by default, ALL intervals are allowed... 
	@IntervalType							sysname					OUT, 
	@Value									bigint					OUT, 
	@Error									nvarchar(MAX)			OUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ValidationParameterName = ISNULL(NULLIF(@ValidationParameterName, N''), N'@Vector');
	IF @ValidationParameterName LIKE N'@%'
		SET @ValidationParameterName = REPLACE(@ValidationParameterName, N'@', N'');

	DECLARE @intervals table ( 
		[key] sysname NOT NULL, 
		[interval] sysname NOT NULL
	);

	INSERT INTO @intervals ([key],[interval]) 
	SELECT [key], [interval] 
	FROM (VALUES 
			(N'B', N'BACKUP'), (N'BACKUP', N'BACKUP'),
			(N'MILLISECOND', N'MILLISECOND'), (N'MS', N'MILLISECOND'), (N'SECOND', N'SECOND'), (N'S', N'SECOND'),(N'MINUTE', N'MINUTE'), (N'M', N'MINUTE'), 
			(N'N', N'MINUTE'), (N'HOUR', N'HOUR'), (N'H', 'HOUR'), (N'DAY', N'DAY'), (N'D', N'DAY'), (N'WEEK', N'WEEK'), (N'W', N'WEEK'),
			(N'MONTH', N'MONTH'), (N'MO', N'MONTH'), (N'QUARTER', N'QUARTER'), (N'Q', N'QUARTER'), (N'YEAR', N'YEAR'), (N'Y', N'YEAR')
	) x ([key], [interval]);

	SET @Vector = LTRIM(RTRIM(UPPER(REPLACE(@Vector, N' ', N''))));
	DECLARE @boundary int, @intervalValue sysname, @interval sysname;
	SET @boundary = PATINDEX(N'%[^0-9]%', @Vector) - 1;

	IF @boundary < 1 BEGIN 
		SET @Error = N'Invalid Vector format specified for parameter @' + @ValidationParameterName + N'. Format must be in ''XX nn'' or ''XXnn'' format - where XX is an ''integer'' duration (e.g., 72) and nn is an interval-specifier (e.g., HOUR, HOURS, H, or h).';
		RETURN -1;
	END;

	SET @intervalValue = LEFT(@Vector, @boundary);
	SET @interval = UPPER(REPLACE(@Vector, @intervalValue, N''));

	IF @interval LIKE '%S' AND @interval NOT IN ('S', 'MS')
		SET @interval = LEFT(@interval, LEN(@interval) - 1); 

	IF NOT @interval IN (SELECT [key] FROM @intervals) BEGIN
		SET @Error = N'Invalid interval specifier defined for @' + @ValidationParameterName + N'. Valid interval specifiers are { [MILLISECOND(S)|MS] | [SECOND(S)|S] | [MINUTE(S)|M|N] | [HOUR(S)|H] | [DAY(S)|D] | [WEEK(S)|W] | [MONTH(S)|MO] | [QUARTER(S)|Q] | [YEAR(S)|Y] }';
		RETURN -10;
	END;

	--  convert @interval to a sanitized version of itself:
	SELECT @interval = [interval] FROM @intervals WHERE [key] = @interval;

	-- check for prohibited intervals: 
	IF NULLIF(@ProhibitedIntervals, N'') IS NOT NULL BEGIN 
		-- delete INTERVALS based on keys - e.g., if ms is prohibited, we don't want to simply delete the MS entry - we want to get all 'forms' of it (i.e., MS, MILLISECOND, etc.)
		DELETE FROM @intervals WHERE [interval] IN (SELECT [interval] FROM @intervals WHERE [key] IN (SELECT [result] FROM dbo.[split_string](@ProhibitedIntervals, N',', 1)));
		
		IF @interval NOT IN (SELECT [interval] FROM @intervals) BEGIN
			SET @Error = N'The interval-specifier [' + @interval + N'] is not permitted in this operation type. Prohibited intervals for this operation are: ' + @ProhibitedIntervals + N'.';
			RETURN -30;
		END;
	END;

	SELECT 
		@IntervalType = @interval, 
		@Value = CAST(@intervalValue AS bigint);

	RETURN 0;
GO