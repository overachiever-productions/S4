

/*

	TODO:
		- Still not sure about the name of this FN... 
			is ... is a verb (i.e., to be)... but still... 

			other options could/would be: 
					dbo.report_status(@dbname...) 
					dbo.treat_as_system(@dbname...)
					etc... 						

		- Need to put whether or not to treat admindb as a [SYSTEM] database in to a settings table... 
			that way, it doesn't get 'overwritten' per each code update... 

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

		IF UPPER(@DatabaseName) IN (N'MASTER', N'MSDB', N'MODEL')
			SET @output = 1; 

		IF UPPER(@DatabaseName) = N'TEMPDB'  -- not sure WHY this would ever be interrogated, but... it IS a system database.
			SET @output = 1;
		
		-- by default, the [admindb] is treated as a system database: 
		IF UPPER(@DatabaseName) = N'ADMINDB'
			SET @output = 1;

		RETURN @output;
	END; 
GO