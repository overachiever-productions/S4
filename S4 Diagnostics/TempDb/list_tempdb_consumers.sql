/*

    STUB: 
        - 'members' of this 'family' of logic/routines: 
            dbo.assess_tempd_configuration
            dbo.assess_tempdb_contention
            dbo.list_tempdb_consumers 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_tempdb_consumers','P') IS NOT NULL
	DROP PROC dbo.list_tempdb_consumers;
GO

CREATE PROC dbo.list_tempdb_consumers


AS
    SET NOCOUNT ON; 

    -- {copyright}

    /*
    
        Implement weaponized version of this:
            D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Diagnostics\tempdb space consumers.sql

        or this: 
            (bottom part):
            D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Diagnostics\tempdb diagnostics.sql
    
    
    */