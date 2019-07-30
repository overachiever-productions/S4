/*

    STUB: 
        - 'members' of this 'family' of logic/routines: 
            dbo.assess_tempd_configuration
            dbo.assess_tempdb_contention
            dbo.list_tempdb_consumers 

          

    FODDER: 
        - https://blogs.msdn.microsoft.com/sql_server_team/sql-server-2016-changes-in-default-behavior-for-autogrow-and-allocations-for-tempdb-and-user-databases/

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.assess_tempdb_configuration','P') IS NOT NULL
	DROP PROC dbo.assess_tempdb_configuration;
GO

CREATE PROC dbo.assess_tempdb_configuration


AS
    SET NOCOUNT ON; 

    -- {copyright}


    /*
    
        Weaponized version of the following checks/reviews: 
        1. File Checks
            SELECT * FROM [tempdb].sys.[database_files];
               
            - make sure all files are the same size and have same growth. 
            - make sure 1x .ldf file only. 

            - if 2016+ ensure tempdb.sys.filegroups.is_autogrow_all_files is set to 1
                otherwise, ensure that TF 1117 is set. 

            - if 2016+ ensure that sys.databases.is_mixed_page_allocation_on = 0 (no mixed pages) 
                otherwise, ensure that TF 1118 is set. 

        2. File Counts... 
            > core count? 
            < .5 core count? 
                if so... recommend addition

            etc. 
    
        3. what else? 
            (check for some of the semi-recent articles by Pam Lahoud on optimizations for tempdb and so on... ) 


    
    */