/*
	
	TODO:
		Add in either, stdev (for durations) and/or average durations for 90th_ntile. 

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[corruption_check_analytics]', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[corruption_check_analytics];
GO

CREATE FUNCTION dbo.[corruption_check_analytics] (@StartDate datetime, @EndDate datetime)
RETURNS table
AS
	-- {copyright}

    RETURN 
	WITH core AS ( 
		SELECT 
			[database], 
			DATEDIFF(MILLISECOND, check_start, check_end) [duration], 
			--NTILE(100) OVER (PARTITION BY [database] ORDER BY DATEDIFF(MILLISECOND, check_start, check_end)) [ntile],
			[check_succeeded]
		FROM 
			dbo.[corruption_check_history]
		WHERE 
			[check_start] >= ISNULL(@StartDate, DATEADD(DAY, -14, GETDATE()))
			AND [check_end] <= ISNULL(@EndDate, GETDATE())
	), 
	expanded AS (
		SELECT 
			[c].[database],
			COUNT(*) [operations],
			(SELECT COUNT([x].[database]) - SUM(CAST([x].[check_succeeded] AS int)) FROM core [x] WHERE [c].[database] = [x].[database]) [failures],
			AVG([c].[duration]) [avg_duration],
			MAX([c].[duration]) [max_duration]
			--,SUM(CAST([c].[duration] AS float) * CAST([c].[duration] AS float)) [squared]
		FROM 
			core [c]
		GROUP BY 
			[c].[database]
	)
    
	SELECT 
		[e].[database],
		[e].[operations],
		[e].[failures],
		[dbo].[format_timespan]([e].[avg_duration]) [avg_duration],
		[dbo].[format_timespan]([e].[max_duration]) [max_duration]
	FROM 
		[expanded] [e];
GO