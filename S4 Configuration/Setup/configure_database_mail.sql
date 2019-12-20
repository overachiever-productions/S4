/*

    
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
    @SmtpOutgoingDisplayName        sysname             = NULL,            -- set to @@SERVERNAME if NULL 
    @SmtpServerName                 sysname, 
    @SmtpPortNumber                 int                 = 587, 
    @SmtpRequiresSSL                bit                 = 1, 
    @SmtpAuthType                   sysname             = N'BASIC',         -- WINDOWS | BASIC | ANONYMOUS
    @SmptUserName                   sysname,
    @SmtpPassword                   sysname, 
	@SendTestEmailUponCompletion	bit					= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}

    -- TODO:
    --      validate all inputs.. 
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
    IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'show advanced options' AND [value_in_use] = 0) BEGIN
        EXEC sp_configure 'show advanced options', 1; 
        RECONFIGURE;
    END;

    IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'Database Mail XPs' AND [value_in_use] = 0) BEGIN
        EXEC sp_configure 'Database Mail XPs', 1; 
	    RECONFIGURE;
    END;

    --------------------------------------------------------------
    -- Create Profile: 
    DECLARE @profileID int; 

    EXEC msdb.dbo.[sysmail_add_profile_sp] 
        @profile_name = @ProfileName, 
        @description = N'S4-Created Profile... ', 
        @profile_id = @profileID OUTPUT;

    --------------------------------------------------------------
    -- Create an Account: 
    DECLARE @AccountID int; 
    DECLARE @useDefaultCredentials bit = 0;  -- username/password. 
    IF UPPER(@SmtpAuthType) = N'WINDOWS' SET @useDefaultCredentials = 1;  -- use windows. 
    IF UPPER(@SmtpAuthType) = N'ANONYMOUS' SET @useDefaultCredentials = NULL;  -- i think that's how this works. it's NOT documented: https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sysmail-add-account-sp-transact-sql?view=sql-server-2017

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
        @account_id = @AccountID OUTPUT;

    --------------------------------------------------------------
    -- Bind Account to Profile: 
    EXEC msdb.dbo.sysmail_add_profileaccount_sp 
	    @profile_id = @profileID,
        @account_id = @AccountID, 
        @sequence_number = 1;  -- primary/initial... 


    --------------------------------------------------------------
    -- set as default: 
    EXEC msdb.dbo.sp_set_sqlagent_properties 
	    @databasemail_profile = @ProfileName,
        @use_databasemail = 1;

    --------------------------------------------------------------
    -- Create Operator: 
    EXEC msdb.dbo.[sp_add_operator]
        @name = @OperatorName,
        @enabled = 1,
        @email_address = @OperatorEmail;

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

	--------------------------------------------------------------
	-- Send a test email - to verify that the SQL Server Agent can correctly send email... 

	DECLARE @body nvarchar(MAX) = N'Test Email - triggered by dbo.configure_database_mail.

If you''re seeing this, the SQL Server Agent on ' + @SmtpOutgoingDisplayName + N' has been correctly configured to 
allow alerts via the SQL Server Agent.
';
	EXEC msdb.dbo.[sp_notify_operator] 
		@profile_name = @ProfileName, 
		@name = @OperatorName, 
		@subject = N'', 
		@body = @body;
    RETURN 0;
GO