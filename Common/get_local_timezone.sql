/*
		
	SELECT [admindb].dbo.[get_local_timezone]();

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




