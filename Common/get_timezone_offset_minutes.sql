/*
	

		SELECT admindb.dbo.[get_timezone_offset_minutes]('{SERVER_LOCAL}');

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_timezone_offset_minutes','FN') IS NOT NULL
	DROP FUNCTION dbo.[get_timezone_offset_minutes];
GO

CREATE FUNCTION dbo.[get_timezone_offset_minutes] (@TimeZone sysname)
RETURNS int
AS
    
	-- {copyright}
    
    BEGIN; 
    	IF NULLIF(@TimeZone, N'') IS NULL 
			SET @TimeZone = N'{SERVER_LOCAL}';

    	DECLARE @output int;
		DECLARE @atTimeZone datetime;
		DECLARE @utc datetime = GETUTCDATE();

		IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
			SET @TimeZone = dbo.[get_local_timezone]();
    	
    	SELECT @atTimeZone = @utc AT TIME ZONE 'UTC' AT TIME ZONE @TimeZone;
    	
    	SELECT @output = DATEDIFF(MINUTE, @utc, @atTimeZone);
    	
    	RETURN @output;
    
    END;
GO