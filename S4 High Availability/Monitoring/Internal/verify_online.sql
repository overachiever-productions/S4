/*

	CONVENTIONS:
		- INTERNAL 

	PURPOSE / NOTES: 
		- See header for dbo.verify_partner;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_online','P') IS NOT NULL
	DROP PROC dbo.[verify_online];
GO

CREATE PROC dbo.[verify_online]

AS
    SET NOCOUNT ON; 

    RETURN 0;
GO
