/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[verify_datacollector_permissions]','P') IS NOT NULL
	DROP PROC dbo.[verify_datacollector_permissions];
GO

CREATE PROC dbo.[verify_datacollector_permissions]

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF EXISTS (SELECT NULL FROM [dbo].[settings] WHERE [setting_key] = N'data_collector_perms_set' AND [setting_value] = N'1') BEGIN
		RETURN 0;
	END;

	-- otherwise, check perms
	
	-- and if available ... modify dbo.settings. 


	-- and if NOT available ... 
	-- print instructions. 
