/*

    STUB: 
        - 'members' of this 'family' of logic/routines: 
            dbo.assess_tempd_configuration
            dbo.assess_tempdb_contention
            dbo.list_tempdb_consumers 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.assess_tempdb_contention','P') IS NOT NULL
	DROP PROC dbo.assess_tempdb_contention;
GO

CREATE PROC dbo.assess_tempdb_contention


AS
    SET NOCOUNT ON; 

    -- {copyright}

    /*
    
        POSSIBLY throw in a switch @DiagnosticType that alternates between
            D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Diagnostics\tempdb diagnostics.sql

            a. basic contention - i.e., contention right here, right now? 
            b. metricized version. 
            c. so-called tactical nuke version... 
                which would either be the DEFAULT or the ONLY option... 
                    POSSBILY specify duration and 'wait' times as @Parameters... 

    
    
    
    
    */