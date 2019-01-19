

/*

			

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.is_system_database','FN') IS NOT NULL
	DROP FUNCTION dbo.is_system_database;
GO

CREATE FUNCTION dbo.is_system_database(@DatabaseName sysname) 
	RETURNS bit
AS 
	BEGIN 
		DECLARE @output bit = 0;
		DECLARE @override sysname; 

		IF UPPER(@DatabaseName) IN (N'MASTER', N'MSDB', N'MODEL')
			SET @output = 1; 

		IF UPPER(@DatabaseName) = N'TEMPDB'  -- not sure WHY this would ever be interrogated, but... it IS a system database.
			SET @output = 1;
		
		-- by default, the [admindb] is treated as a system database (but this can be overwritten as a setting in dbo.settings).
		IF UPPER(@DatabaseName) = N'ADMINDB' BEGIN
			SET @output = 1;

			SELECT @override = setting_value FROM dbo.settings WHERE setting_key = N'admindb_is_system_db';

			IF @override = N'0'	-- only overwrite if a) the setting is there/defined AND the setting's value = 0 (i.e., false).
				SET @output = 0;
		END;

		-- same with the distribution database... 
		IF UPPER(@DatabaseName) = N'DISTRIBUTION' BEGIN
			SET @output = 1;
			
			SELECT @override = setting_value FROM dbo.settings WHERE setting_key = N'distribution_is_system_db';

			IF @override = N'0'	-- only overwrite if a) the setting is there/defined AND the setting's value = 0 (i.e., false).
				SET @output = 0;
		END;

		RETURN @output;
	END; 
GO