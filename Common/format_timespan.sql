/*


TODO: 
	- Account for the following details/'spans' - as in ... currently just assuming hhh:mm:ss as 'max-ish' inputs. 
		instead... allow for 'stupid' inputs - cuz they can/will happen. and... even 'non-stupid' things like... days, weeks, or months could and SHOULD be viable as values passed into this piglet. 
			e.g., "22.8 days" should be a VIABLE output, and even "18.7 months" or ... "22.56 years" and so on... 

	AND, the way to address the above is ... have a different func/variant of this - that takes in start, end dates and let IT do the logic for determining this 'stuff'.
		er, well: 
			a) it might be - and definitely is in SOME ways - ESPECIALLY for OLDER SQL Server instances without DATEDIFF_BIG().. 
			b) and... it's definitely A way to simplify some of my calls/uses... 
			and
			c) I've started a STUBB for it at 
				D:\Dropbox\Repositories\S4\Common\format_time_difference.sql
		BUT
			it also makes sense to have dbo.format_timespan() report on things in DAYS whenever we're > x number of hours (where x is probably amount of hours for 3-4 days ...)

	SELECT DATEDIFF_BIG(MILLISECOND, '1900-01-01', GETDATE());
	-- 2147483647  -- int...   < 1 month... 
	-- 31557600000 -- 1 year
	-- 3785241531386 -- roughly 120 years... 
	-- 9223372036854775806 -- bigint



	-- BIGINT: 9223372036854775806 (milliseconds). 
	-- 1 years' worth of milliseconds: 
	-- 1000 * 60 * 60 * 24 * 3645.25 = 31557600000


	SELECT 9223372036854775806 / 31557600000
	-- 292,271,023   - so... 292M years... 


	SELECT DATEADD(MILLISECOND, -2147483647, GETDATE())



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_timespan','FN') IS NOT NULL
	DROP FUNCTION dbo.format_timespan;
GO

CREATE FUNCTION dbo.format_timespan(@Milliseconds bigint)
RETURNS sysname
WITH RETURNS NULL ON NULL INPUT
AS
	-- {copyright}
	BEGIN

		DECLARE @output sysname;

		IF @Milliseconds IS NULL OR @Milliseconds = 0 BEGIN
			SET @output = N'000:00:00.000';
			GOTO Negate;
		END;

		IF @Milliseconds > 259200000 BEGIN 
			SELECT @output = CASE  
				WHEN @Milliseconds > 33696000000 THEN CAST(CAST(ROUND(@Milliseconds / 31536000000.0, 1) AS decimal(4,1)) AS sysname) + N' years'
				WHEN @Milliseconds >  5443200000 THEN CAST(CAST(ROUND(@Milliseconds / 2592000000.0, 1) AS decimal(4,1)) AS sysname) + N' months'
				WHEN @Milliseconds >  1209600000 THEN CAST(CAST(ROUND(@Milliseconds / 604800000.0, 1) AS decimal(4,1)) AS sysname) + N' weeks'
				WHEN @Milliseconds >   259200000 THEN CAST(CAST(ROUND(@Milliseconds / 86400000.0, 1) AS decimal(4,1)) AS sysname) + N' days'
			END;	
			
			IF @output LIKE N'%.0%' 
				SET @output = REPLACE(@output, N'.0', N'');

			GOTO Negate;
		END 

		SET @output = RIGHT('000' + CAST(@Milliseconds / 3600000 as sysname), 3) + N':' + RIGHT('00' + CAST((@Milliseconds / (60000) % 60) AS sysname), 2) + N':' + RIGHT('00' + CAST(((@Milliseconds / 1000) % 60) AS sysname), 2) + N'.' + RIGHT('000' + CAST((@Milliseconds) AS sysname), 3)

Negate:
		IF @Milliseconds < 0 
			SET @output = N'- ' + @output;

		RETURN @output;
	END;
GO