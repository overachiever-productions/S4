/*


		SELECT dbo.[is_primary_server]();
	


*/

USE [admindb];
GO 

IF OBJECT_ID('dbo.is_primary_server','FN') IS NOT NULL
	DROP FUNCTION dbo.is_primary_server;
GO

CREATE FUNCTION dbo.is_primary_server()
RETURNS bit
AS 
	-- {copyright}

	BEGIN
		DECLARE @output bit = 0;

		DECLARE @roleOfAlphabeticallyFirstSynchronizingDatabase sysname; 

		SELECT @roleOfAlphabeticallyFirstSynchronizingDatabase = (
			SELECT TOP (1)
				[role]
			FROM 
				dbo.[list_synchronizing_databases](NULL, 1)
			ORDER BY 
				[database_name]
		);

		IF @roleOfAlphabeticallyFirstSynchronizingDatabase IN (N'PRIMARY', N'PRINCIPAL')
			SET @output = 1;
			
		RETURN @output;
	END;
GO