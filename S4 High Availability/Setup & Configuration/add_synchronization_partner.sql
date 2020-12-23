/*

    TODO: 
        - account for NAMED instances. 
        - Parameter validation... 
                                

    
    EXAMPLE / TEST:

            Hard-coded PartnerName:
				EXEC dbo.add_synchronization_partner
					@PartnerName = N'SQL-130-2B', 
					@ExecuteSetupOnPartnerServer = 1;


			Specifying BOTH server names - and executing on both servers independantly: 
				EXEC dbo.add_synchronization_partner
					@PartnerNames = N'AWS-SQL-1, AWS-SQL-2', 
					@ExecuteSetupOnPartnerServer = 0;
				


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.add_synchronization_partner','P') IS NOT NULL
	DROP PROC dbo.[add_synchronization_partner];
GO

CREATE PROC dbo.[add_synchronization_partner]
    @PartnerName                            sysname		= NULL,			-- hard-coded name of partner - e.g., SQL2 (if we're running on SQL1).
	@PartnerNames							sysname		= NULL,			-- specify 2x server names, e.g., SQL1 and SQL2 - and the sproc will figure out self and partner accordingly. 
    @ExecuteSetupOnPartnerServer            bit         = 1     -- by default, attempt to create a 'PARTNER' on the PARTNER, that... points back here... 
AS
    SET NOCOUNT ON; 

	-- {copyright}

    -- TODO: verify @PartnerName input/parameters. 
	SET @PartnerName = NULLIF(@PartnerName, N'');
	SET @PartnerNames = NULLIF(@PartnerNames, N'');

	IF @PartnerName IS NULL AND @PartnerNames IS NULL BEGIN 
		RAISERROR('Please Specify a value for either @PartnerName (e.g., ''SQL2'' if executing on SQL1) or for @PartnerNames (e.g., ''SQL1,SQL2'' if running on either SQL1 or SQL2).', 16, 1);
		RETURN - 2;
	END;

	IF @PartnerName IS NULL BEGIN 
		DECLARE @serverNames table ( 
			server_name sysname NOT NULL
		);

		INSERT INTO @serverNames (
			server_name
		)
		SELECT CAST([result] AS sysname) FROM dbo.[split_string](@PartnerNames, N',', 1);

		DELETE FROM @serverNames WHERE [server_name] = @@SERVERNAME;

		IF(SELECT COUNT(*) FROM @serverNames) <> 1 BEGIN
			RAISERROR('Invalid specification for @PartnerNames specified - please specify 2 server names, where one is the name of the currently executing server.', 16, 1);
			RETURN -10;
		END;

		SET @PartnerName = (SELECT TOP 1 server_name FROM @serverNames);
	END;

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

	-- As part of setting up for failover, make sure the AG XE is enabled as well: 
	IF (SELECT [admindb].dbo.[get_engine_version]()) >= 11.0 BEGIN 
		
		DECLARE @startupState bit; 
		SELECT @startupState = startup_state FROM sys.[server_event_sessions] WHERE [name] = N'AlwaysOn_health';

		IF @startupState IS NOT NULL AND @startupState <> 1 BEGIN 
			DECLARE @sql nvarchar(MAX) = N'ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE = ON); ';
			EXEC sys.sp_executesql @sql;
		END

		IF NOT EXISTS (SELECT NULL FROM sys.[dm_xe_sessions] WHERE [name] = N'AlwaysOn_health') BEGIN
			SET @sql = N'ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START; ';

			EXEC sys.sp_executesql @sql;
		END;
	END;

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