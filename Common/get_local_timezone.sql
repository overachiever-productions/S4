/*
		
	SELECT [admindb].dbo.[get_local_timezone]();


SELECT GETDATE() [now], GETUTCDATE() [utc];


SELECT 
	[row_id],
	[timestamp], 
	DATEADD(HOUR, -8, [timestamp]) [manual], 
	[timestamp] AT TIME ZONE 'Pacific Standard Time' [at time zone], 
	CAST([timestamp] AT TIME ZONE 'Pacific Standard Time' AS datetime) [pacific_cast], 
	CONVERT(datetime, [timestamp] AT TIME ZONE 'Pacific Standard Time', 1) [pacific_convert]
FROM 
	[dbo].[all_blocking_feb15]


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_local_timezone','FN') IS NOT NULL
	DROP FUNCTION dbo.[get_local_timezone];
GO

CREATE FUNCTION dbo.[get_local_timezone]()
RETURNS sysname
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output sysname;
    	
		EXEC sys.[xp_regread]
			'HKEY_LOCAL_MACHINE',
			'SYSTEM\CurrentControlSet\Control\TimeZoneInformation',
			'TimeZoneKeyName',
			@output OUTPUT; 

    	RETURN @output;
    
    END;
GO