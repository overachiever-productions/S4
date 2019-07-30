/*

    TODO: 
        - account for NAMED instances. 
        - Parameter validation... 
                                

    
    EXAMPLE / TEST:

                

            NOTE: make sure to change the PARTNER name... 
            EXEC dbo.add_synchronization_partner
                N'SQL-130-2B', 
                1;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.add_synchronization_partner','P') IS NOT NULL
	DROP PROC dbo.[add_synchronization_partner];
GO

CREATE PROC dbo.[add_synchronization_partner]
    @PartnerName                            sysname, 
    @ExecuteSetupOnPartnerServer            bit         = 1     -- by default, attempt to create a 'PARTNER' on the PARTNER, that... points back here... 
AS
    SET NOCOUNT ON; 

    -- {copyright}

    -- TODO: verify @PartnerName input/parameters. 

    -- TODO: account for named instances... 
    DECLARE @remoteHostName sysname = N'tcp:' + @PartnerName;
    DECLARE @errorMessage nvarchar(MAX);
    DECLARE @serverName sysname = @@SERVERNAME;

    IF EXISTS (SELECT NULL FROM sys.servers WHERE UPPER([name]) = N'PARTNER') BEGIN 
        RAISERROR('A definition for PARTNER already exists as a Linked Server.', 16, 1);
        RETURN -1;
    END;

    BEGIN TRY
        EXEC master.dbo.sp_addlinkedserver 
	        @server = N'PARTNER', 
	        @srvproduct = N'', 
	        @provider = N'SQLNCLI', 
	        @datasrc = @remoteHostName, 
	        @catalog = N'master';

        EXEC master.dbo.sp_addlinkedsrvlogin 
	        @rmtsrvname = N'PARTNER',
	        @useself = N'True',
	        @locallogin = NULL,
	        @rmtuser = NULL,
	        @rmtpassword = NULL;

        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc', 
	        @optvalue = N'true';

        EXEC master.dbo.sp_serveroption 
	        @server = N'PARTNER', 
	        @optname = N'rpc out', 
	        @optvalue = N'true';

        
        PRINT 'Definition for PARTNER server (pointing to ' + @PartnerName + N') successfully registered on ' + @serverName + N'.';

    END TRY 
    BEGIN CATCH 
        SELECT @errorMessage = N'Unexepected error while attempting to create definition for PARTNER on local/current server. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
        RAISERROR(@errorMessage, 16, 1);
        RETURN -20;
    END CATCH;

    IF @ExecuteSetupOnPartnerServer = 1 BEGIN
        DECLARE @localHostName sysname = @@SERVERNAME;

        DECLARE @command nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.add_synchronization_partner @localHostName, 0;';

        BEGIN TRY 
            EXEC sp_executesql 
                @command, 
                N'@localHostName sysname', 
                @localHostName = @localHostName;

        END TRY 

        BEGIN CATCH
            SELECT @errorMessage = N'Unexepected error while attempting to DYNAMICALLY create definition for PARTNER on remote/partner server. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -40;

        END CATCH;
    END;

    RETURN 0;
GO    