/*

	-- TODO: as part of cleanup, I should probably DATEADD(DAY, 30, eventstore_settings.retention_days) ... 
	--		and then remove Extractions/ETL details > (above) days old... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_data_cleanup]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_data_cleanup];
GO

CREATE PROC dbo.[eventstore_data_cleanup]

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Get Sessions to Process:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT 
		[setting_id],
		[event_store_key],
		[target_table],
		[retention_days]
	FROM 
		dbo.[eventstore_settings];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Batch Process Each Table as Needed:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/

	-- TODO: either ... pass these commands into batcher or ... set up some 'batcher-light' logic in here... 
	--	WHERE the challenge is that I'm going to POTENTIALLY need to execute DELETE operations in a database OTHER than the admindb. 
	--		which ... isn't that much of a problem ... other than that I need to create some code that effectively matches the 'batcher' interface
	--			and which can/will both run in other databases (if/as needed) AND return results to this (the caller) ... for handling/processing, etc. 

		DECLARE @statement nvarchar(MAX) = N'USE [{db}];
	DELETE FROM [{x}].[{table_name}] WHERE [timestamp] < @cutoff';


