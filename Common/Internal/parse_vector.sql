/*

	-- vNEXT: 
        the whole "Valid interval specifiers are ... " error message is ... techniical true... 
            as in, that lists ALL valid/optional intervals. 
            but... 
                i need to tweak that so that it only spits out intervals that are ... permitted in the current operation
                    Or, in other words I need to: 
                        a) add a new column to @intervals - say, [option_specifier]
                        b)  load the value with the whole 'specifier' for a given thing - e.g., days are DAY(S)|D whereas milliseconds are MILLISECOND(S)|MS
                        c) serialize a list of these that are allowed by means of excluding any prohibited... and then 'chaining' the remaining entries... 



    TESTS / SIGNATURES: 


            -- Expect exception - weet isn't a valid value: 

                        DECLARE @type sysname, @value bigint, @error nvarchar(MAX); 
                        EXEC admindb.dbo.parse_vector
                            @Vector = N'2 weets', 
                            @IntervalType = @type OUTPUT, 
                            @Value = @value OUTPUT, 
                            @Error = @error OUTPUT;

                        SELECT @value, @type, @error;
                        GO
            
            -- Expect exception - week is legit, but it's PROHIBITED in the operation calling this routine:

                        DECLARE @type sysname, @value bigint, @error nvarchar(MAX); 
                        EXEC admindb.dbo.parse_vector
                            @Vector = N'2 weeks', -- also try: 2w 2week 2 week, etc. 
                            @ProhibitedIntervals = N'WEEK,MONTH',
                            @IntervalType = @type OUTPUT, 
                            @Value = @value OUTPUT, 
                            @Error = @error OUTPUT;

                        SELECT @value, @type, @error;
                        GO


            -- expect 1200 MILLISECOND (i.e., 1200 milliseconds)

                        DECLARE @type sysname, @value bigint, @error nvarchar(MAX); 
                        EXEC admindb.dbo.parse_vector
                            @Vector = N'1200 milliseconds',
                            @ProhibitedIntervals = N'WEEK,MONTH',
                            @IntervalType = @type OUTPUT, 
                            @Value = @value OUTPUT, 
                            @Error = @error OUTPUT;

                        SELECT @value, @type, @error;
                        GO

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
		DELETE FROM @intervals WHERE [interval] IN (SELECT [interval] FROM @intervals WHERE UPPER([key]) IN (SELECT UPPER([result]) FROM dbo.[split_string](@ProhibitedIntervals, N',', 1)));
		
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