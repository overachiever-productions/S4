/*

	TODO: 
		Test how anonymouse SMTP works (or is configured) 
			as in ... i don't even NEED to have some 'relayed' server setup somewhere... 
				I just need to verify how to correctly set/configure database mail to 'talk' to a server that's ONLY using anonymous/opem-relays/etc.

		- Make Idempotent... 
			e.g., say we're able to create 'General' as a profile... then everything crashes/burns from there ... can't let a re-run of this sproc crash/burn on PK violation of 'General' as an ADDED profile - and so on.
    
	NOTE: 
		for 'mass' deploy operations (i.e., multiple nodes in an AG...)
			it'd be spiffy to either a) create a new sproc or b) wire in an @param that'd enable something like an array of definitions for the display name. 
				e.g., say I'm installing / deploying this sproc against 2x AG nodes via Registered Servers/Multi-Server 'query'.
					boxes are WIN-XXX1 and WIN-UUXY2 ... and have respective IPs of *.111.110 and *.112.110 or whatever... 
						it'd be cool to specify either of the following 'strings' as @SmtpOutgoingDisplayName: 
							by IP			=> N'%.111.110|SQLA, %.112.110|SQLB' 
							or, by name		=> N'%XXX1|SQLA, %XY2|SQLB' ... and have this tackle these details as needed... 

								SELECT 
									CONNECTIONPROPERTY('local_net_address'), 
									CONNECTIONPROPERTY('client_net_address'); ... i.e., as examples of how to parse IPs and such... (not sure how we account for multiple IPs but... then again, whatever we're CONNECTED to would be the client_net_address and should be good enough. 

																and... of course, there's always @@SERVERNAME... 
																SELECT SERVERPROPERTY('ComputerNamePhysicalNetBIOS'), @@SERVERNAME;

				


    EXAMPLE EXECUTION   (favoring convention over configuration):
            EXEC dbo.[configure_database_mail]
                @OperatorEmail = N'mike@overachiever.net',
                @SmtpAccountName = N'AWS - East',
                @SmtpOutgoingEmailAddress = N'alerts@overachiever.net',
                @SmtpServerName = N'email-smtp.us-east-1.amazonaws.com',
                @SmptUserName = N'A***************27',
                @SmtpPassword = N'Akb*********************************x', 
				@SmtpOutgoingDisplayName = N'SQL01';  -- or POD7-SQL2, etc... 



	

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.configure_database_mail','P') IS NOT NULL
	DROP PROC dbo.configure_database_mail;
GO

CREATE PROC dbo.configure_database_mail
    @ProfileName                    sysname             = N'General', 
    @OperatorName                   sysname             = N'Alerts', 
    @OperatorEmail                  sysname, 
    @SmtpAccountName                sysname             = N'Default SMTP Account', 
    @SmtpAccountDescription         sysname             = N'Defined/Created by S4',
    @SmtpOutgoingEmailAddress       sysname,
    @SmtpOutgoingDisplayName        sysname             = NULL,            -- e.g., SQL1 or POD2-SQLA, etc.  Will be set to @@SERVERNAME if NULL 
    @SmtpServerName                 sysname, 
    @SmtpPortNumber                 int                 = 587, 
    @SmtpRequiresSSL                bit                 = 1, 
    @SmtpAuthType                   sysname             = N'BASIC',         -- WINDOWS | BASIC | ANONYMOUS
    @SmptUserName                   sysname				= NULL,
    @SmtpPassword                   sysname				= NULL, 
	@SendTestEmailUponCompletion	bit					= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	SET @SmtpAccountName = ISNULL(NULLIF(@SmtpAccountName, N''), N'Default SMTP Account');

	-----------------------------------------------------------------------------
	-- Verify that the SQL Server Agent is running
	IF NOT EXISTS (SELECT NULL FROM sys.[dm_server_services] WHERE [servicename] LIKE '%Agent%' AND [status_desc] = N'Running') BEGIN
		RAISERROR('SQL Server Agent Service is NOT running. Please ensure that it is running (and/or that this is not an Express Edition of SQL Server) before continuing.', 16, 1);
		RETURN -100;
	END;

	-----------------------------------------------------------------------------
    IF NULLIF(@ProfileName, N'') IS NULL OR NULLIF(@OperatorName, N'') IS NULL OR NULLIF(@OperatorEmail, N'') IS NULL BEGIN 
        RAISERROR(N'@ProfileName, @OperatorName, and @OperatorEmail are all REQUIRED parameters.', 16, 1);
        RETURN -1;
    END;

    IF NULLIF(@SmtpOutgoingEmailAddress, N'') IS NULL OR NULLIF(@SmtpServerName, N'') IS NULL OR NULLIF(@SmtpAuthType, N'') IS NULL BEGIN 
        RAISERROR(N'@SmtpOutgoingEmailAddress, @SmtpServerName, and @SmtpAuthType are all REQUIRED parameters.', 16, 1);
        RETURN -2;
    END;

    IF UPPER(@SmtpAuthType) NOT IN (N'WINDOWS', N'BASIC', N'ANONYMOUS') BEGIN 
        RAISERROR(N'Valid options for @SmtpAuthType are { WINDOWS | BASIC | ANONYMOUS }.', 16, 1);
        RETURN -3;
    END;

    IF @SmtpPortNumber IS NULL OR @SmtpRequiresSSL IS NULL OR @SmtpRequiresSSL NOT IN (0, 1) BEGIN 
        RAISERROR(N'@SmtpPortNumber and @SmtpRequiresSSL are both REQUIRED Parameters. @SmtpRequiresSSL must also have a value of 0 or 1.', 16, 1);
        RETURN -4;
    END;

    IF NULLIF(@SmtpOutgoingDisplayName, N'') IS NULL 
        SELECT @SmtpOutgoingDisplayName = @@SERVERNAME;

    --------------------------------------------------------------
    -- Enable Mail XPs: 
	DECLARE @reconfigure bit = 0;
    IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'show advanced options' AND [value_in_use] = 0) BEGIN
        EXEC sp_configure 'show advanced options', 1; 
        
		SET @reconfigure = 1;
    END;

    IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'Database Mail XPs' AND [value_in_use] = 0) BEGIN
        EXEC sp_configure 'Database Mail XPs', 1; 
	    
		SET @reconfigure = 1;
    END;

	IF @reconfigure = 1 BEGIN
		RECONFIGURE;
	END;

    --------------------------------------------------------------
    -- Create Profile: 
    DECLARE @profileID int; 
	SELECT @profileID = profile_id FROM msdb.dbo.[sysmail_profile] WHERE [name] = @ProfileName;
	
	IF @profileID IS NULL BEGIN 
		EXEC msdb.dbo.[sysmail_add_profile_sp] 
			@profile_name = @ProfileName, 
			@description = N'S4-Created Profile... ', 
			@profile_id = @profileID OUTPUT;		
	END;

    --------------------------------------------------------------
    -- Create an Account: 
    DECLARE @accountID int; 
    DECLARE @useDefaultCredentials bit = 0;  -- username/password. 
    IF UPPER(@SmtpAuthType) = N'WINDOWS' SET @useDefaultCredentials = 1;  -- use windows. 
    IF UPPER(@SmtpAuthType) = N'ANONYMOUS' SET @useDefaultCredentials = 0;  

	SELECT @accountID = account_id FROM msdb.dbo.[sysmail_account] WHERE [name] = @SmtpAccountName;
	IF @accountID IS NULL BEGIN 
		EXEC msdb.dbo.[sysmail_add_account_sp]
			@account_name = @SmtpAccountName,
			@email_address = @SmtpOutgoingEmailAddress,
			@display_name = @SmtpOutgoingDisplayName,
			--@replyto_address = N'',
			@description = @SmtpAccountDescription,
			@mailserver_name = @SmtpServerName,
			@mailserver_type = N'SMTP',
			@port = @SmtpPortNumber,
			@username = @SmptUserName,
			@password = @SmtpPassword,
			@use_default_credentials = @useDefaultCredentials,
			@enable_ssl = @SmtpRequiresSSL,
			@account_id = @accountID OUTPUT;
	  END;
	ELSE BEGIN 
		EXEC msdb.dbo.[sysmail_update_account_sp]
			@account_id = @accountID,
			@account_name = @SmtpAccountName,
			@email_address = @SmtpOutgoingEmailAddress,
			@display_name = @SmtpOutgoingDisplayName,
			--@replyto_address = N'',
			@description = @SmtpAccountDescription,
			@mailserver_name = @SmtpServerName,
			@mailserver_type = N'SMTP',
			@port = @SmtpPortNumber,
			@username = @SmptUserName,
			@password = @SmtpPassword,
			@use_default_credentials = @useDefaultCredentials,
			@enable_ssl = @SmtpRequiresSSL;
	END;

    --------------------------------------------------------------
    -- Bind Account to Profile:
	IF NOT EXISTS (SELECT NULL FROM msdb.dbo.[sysmail_profileaccount] WHERE [profile_id] = @profileID AND [account_id] = @accountID) BEGIN
		EXEC msdb.dbo.sysmail_add_profileaccount_sp 
			@profile_id = @profileID,
			@account_id = @accountID, 
			@sequence_number = 1;  
	END;

    --------------------------------------------------------------
    -- set as default: 
    EXEC msdb.dbo.sp_set_sqlagent_properties 
	    @databasemail_profile = @ProfileName,
        @use_databasemail = 1;

    --------------------------------------------------------------
    -- Create Operator: 
	IF NOT EXISTS (SELECT NULL FROM msdb.dbo.[sysoperators] WHERE [name] = @OperatorName AND [email_address] = @OperatorEmail) BEGIN
		EXEC msdb.dbo.[sp_add_operator]
			@name = @OperatorName,
			@enabled = 1,
			@email_address = @OperatorEmail;
	END;

    --------------------------------------------------------------
    -- Enable SQL Server Agent to use Database Mail and enable tokenization:
    EXEC msdb.dbo.[sp_set_sqlagent_properties]  -- NON-DOCUMENTED SPROC: 
        @alert_replace_runtime_tokens = 1,
        @use_databasemail = 1,
        @databasemail_profile = @ProfileName;

    -- define a default operator:
    EXEC master.dbo.sp_MSsetalertinfo 
        @failsafeoperator = @OperatorName, 
		@notificationmethod = 1;

    --------------------------------------------------------------
    -- vNext: bind operator and profile to dbo.settings as 'default' operator/profile details. 

	/*
	
		UPSERT... 
			dbo.settings: 
				setting_type	= SINGLETON
				setting_key		= s4_default_profile
				setting_value	= @ProfileName


		UPSERT 
			dbo.settings: 
				setting_type	= SINGLETON
				setting_key		= s4_default_operator
				setting_value	= @OperatorName				
	
		THEN... 
			need some sort of check/validation/CYA at the start of this processs
				that avoids configuring mail IF the values above are already set? 
					or something along those lines... 


			because... this process isn't super idempotent (or is it?)

	*/

	IF @SendTestEmailUponCompletion = 0 
		RETURN 0;

	--------------------------------------------------------------
	-- Send a test email - to verify that the SQL Server Agent can correctly send email... 

	DECLARE @version sysname = (SELECT [version_number] FROM dbo.version_history WHERE [version_id] = (SELECT MAX([version_id]) FROM dbo.[version_history]));
	DECLARE @body nvarchar(MAX) = N'Test Email - Configuration Validation.

If you''re seeing this, the SQL Server Agent on ' + @SmtpOutgoingDisplayName + N' has been correctly configured to 
allow alerts via the SQL Server Agent.

Triggered by dbo.configure_database_mail. S4 version ' + @version + N'.

';
	EXEC msdb.dbo.[sp_notify_operator] 
		@profile_name = @ProfileName, 
		@name = @OperatorName, 
		@subject = N'', 
		@body = @body;

    RETURN 0;
GO