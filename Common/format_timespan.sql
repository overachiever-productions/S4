/*


TODO: 
	- Account for the following details/'spans' - as in ... currently just assuming hhh:mm:ss as 'max-ish' inputs. 
		instead... allow for 'stupid' inputs - cuz they can/will happen. and... even 'non-stupid' things like... days, weeks, or months could and SHOULD be viable as values passed into this piglet. 
			e.g., "22.8 days" should be a VIABLE output, and even "18.7 months" or ... "22.56 years" and so on... 

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

		IF @Milliseconds IS NULL OR @Milliseconds = 0	
			SET @output = N'000:00:00.000';

		IF @Milliseconds > 0 BEGIN
			SET @output = RIGHT('000' + CAST(@Milliseconds / 3600000 as sysname), 3) + N':' + RIGHT('00' + CAST((@Milliseconds / (60000) % 60) AS sysname), 2) + N':' + RIGHT('00' + CAST(((@Milliseconds / 1000) % 60) AS sysname), 2) + N'.' + RIGHT('000' + CAST((@Milliseconds) AS sysname), 3)
		END;

		IF @Milliseconds < 0 BEGIN
			SET @output = N'-' + RIGHT('000' + CAST(ABS(@Milliseconds / 3600000) as sysname), 3) + N':' + RIGHT('00' + CAST(ABS((@Milliseconds / (60000) % 60)) AS sysname), 2) + N':' + RIGHT('00' + CAST((ABS((@Milliseconds / 1000) % 60)) AS sysname), 2) + N'.' + RIGHT('000' + CAST(ABS((@Milliseconds)) AS sysname), 3)
		END;


		RETURN @output;
	END;
GO