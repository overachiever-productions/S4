/*

    TODO: 
        - account for NAMED instances. 
        - Parameter validation... 
                                

	NOTE:
		- On SQL Server 2016 need to use SQLNCLI instead of MSOLEDBSQL... 


    
    EXAMPLE / TEST:

            Dynamic Determination of Partner Name (i.e., don't specify any values for @ServerNames):
				EXEC dbo.add_synchronization_partner
					@ExecuteSetupOnPartnerServer = 1;


			Specifying BOTH server names - and executing on both servers independantly: 
				EXEC dbo.add_synchronization_partner
					@ServerNames = N'AWS-SQL-1, AWS-SQL-2', 
					@ExecuteSetupOnPartnerServer = 0;
				


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.add_synchronization_partner','P') IS NOT NULL
	DROP PROC dbo.[add_synchronization_partner];
GO

CREATE PROC dbo.[add_synchronization_partner]
	@ServerNames							sysname		= NULL,			-- specify 2x server names, e.g., SQL1 and SQL2 - and the sproc will figure out self and partner accordingly. 
    @ExecuteSetupOnPartnerServers           bit         = 1,			-- by default, attempt to create a 'PARTNER' on the PARTNER, that... points back here... 
	@OverwritePartnerDefinitions			bit			= 0				-- MIGHT be one of the few cases where DEFAULTing to 1 makes sense... 
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @ServerNames = NULLIF(@ServerNames, N'');

	DECLARE @currentHost sysname = @@SERVERNAME;

	IF @ServerNames IS NULL BEGIN 
		SET @ServerNames = N'';

		SELECT 
			@ServerNames = @ServerNames + [member_name]  + N','
		FROM 
			sys.dm_hadr_cluster_members 
		WHERE 
			member_type = 0;

		IF @ServerNames <> N''
			SET @ServerNames = LEFT(@ServerNames, LEN(@ServerNames) -1);
	END;

	IF NULLIF(@ServerNames, N'') IS NULL BEGIN
		RAISERROR('Please Specify a value for either @PartnerName (e.g., ''SQL2'' if executing on SQL1) or for @ServerNames (e.g., ''SQL1,SQL2'' if running on either SQL1 or SQL2).', 16, 1);
		RETURN - 2;
	END;

	DECLARE @servers table ( 
		[server_name] sysname NOT NULL
	);

	INSERT INTO @servers ([server_name])
	SELECT CAST([result] AS sysname) FROM dbo.[split_string](@ServerNames, N',', 1);

	DELETE FROM @servers WHERE [server_name] = @@SERVERNAME;

	IF(SELECT COUNT(*) FROM @servers) <> 1 BEGIN
		RAISERROR('Invalid specification for @ServerNames specified - please specify 2 server names, where one is the name of the currently executing server.', 16, 1);
		RETURN -10;
	END;

	-- TODO: account for > 1 replica. 
	DECLARE @partnerName sysname = (SELECT TOP (1) [server_name] FROM @servers);

    -- TODO: account for named instances... 
    DECLARE @remoteHostName sysname = N'tcp:' + @PartnerName;
    DECLARE @errorMessage nvarchar(MAX);
    DECLARE @serverName sysname = @@SERVERNAME;

    IF EXISTS (SELECT NULL FROM sys.servers WHERE UPPER([name]) = N'PARTNER') BEGIN 
		
		IF @OverwritePartnerDefinitions = 1 BEGIN
			EXEC master.dbo.[sp_dropserver] 
				@server = N'PARTNER', 
				@droplogins = 'droplogins';
		  END;
		ELSE BEGIn
			RAISERROR('A definition for PARTNER already exists as a Linked Server. Either Manually Remove, or Specify @OverwritePartnerDefinitions = 1.', 16, 1);
			RETURN -1;
		END;
    END;

    BEGIN TRY
        EXEC master.dbo.sp_addlinkedserver 
	        @server = N'PARTNER', 
	        @srvproduct = N'', 
-- TODO: IF SQL Server 2016 or lower, use 'SQLNCLI' instead of MSOLEDBSQL
	        @provider = N'MSOLEDBSQL', 
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

    IF @ExecuteSetupOnPartnerServers = 1 BEGIN
        DECLARE @localHostName sysname = @@SERVERNAME;

        DECLARE @command nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.add_synchronization_partner @ExecuteSetupOnPartnerServers = 0, @OverwritePartnerDefinitions = {overwrite};';
		IF @OverwritePartnerDefinitions = 1 
			SET @command = REPLACE(@command, N'{overwrite}', N'1');
		ELSE 
			SET @command = REPLACE(@command, N'{overwrite}', N'0');

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