/*
	NOTE: 
		this is an internal helper - to make it easier to assess previous versions. 
		But, uh, don't try calling it BEFORE the dbo.version_history table has been created. 
			And... since this is a UDF, there's no real way to dynamically execute anythin in here (i.e., it'd be GREAT to return 0 or 100 if the table
				doesn't exist... but there's no option to check for that and THEN run stuff... )
				
				
	SELECT dbo.get_s4_version('32.7.9998.1')

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_s4_version','FN') IS NOT NULL
	DROP FUNCTION dbo.[get_s4_version];
GO

CREATE FUNCTION dbo.[get_s4_version](@DefaultValueIfNoHistoryPresent varchar(20))
RETURNS decimal(3,1)
AS
    
    -- {copyright}
    
    BEGIN; 
    	
		DECLARE @output decimal(3,1); 
		DECLARE @currentVersion varchar(20);

		SELECT 
			@currentVersion = [version_number] 
		FROM 
			dbo.[version_history] 
		WHERE 
			version_id = (SELECT TOP 1 [version_id] FROM dbo.[version_history] ORDER BY [version_id] DESC);

		IF @currentVersion IS NULL 
			SET @currentVersion = @DefaultValueIfNoHistoryPresent;
			
		DECLARE @majorMinor varchar(10) = N'';
		SELECT @majorMinor = @majorMinor + [result] + CASE WHEN [row_id] = 1 THEN N'.' ELSE '' END FROM dbo.[split_string](@currentVersion, N'.', 1) WHERE [row_id] < 3 ORDER BY [row_id];

		SET @output = CAST(@majorMinor AS decimal(3,1));

    	RETURN @output;
    END;
GO




SELECT * FROM [dbo].[version_history];



