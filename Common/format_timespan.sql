/*





*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_timespan','FN') IS NOT NULL
	DROP FUNCTION dbo.format_timespan;
GO

CREATE FUNCTION dbo.format_timespan(@Milliseconds bigint)
RETURNS sysname
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