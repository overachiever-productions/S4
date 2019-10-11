/*
	vNEXT (maybe?): 
	   .. if a job for processing already exists???> just use it? 
            and/or MAYBE I should put the fact that there's a job for processing failover into the settings table?
                and then do some comparisons against that? 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.add_failover_processing','P') IS NOT NULL
	DROP PROC dbo.[add_failover_processing];
GO

CREATE PROC dbo.[add_failover_processing]
    @SqlServerAgentFailoverResponseJobName              sysname         = N'Synchronization Failover Response',
    @SqlServerAgentJobNameCategory                      sysname         = N'Synchronization',
	@MailProfileName			                        sysname         = N'General',
	@OperatorName				                        sysname         = N'Alerts', 
    @ExecuteSetupOnPartnerServer                        bit = 1
AS
    SET NOCOUNT ON; 

    -- {copyright}
    
    DECLARE @errorMessage nvarchar(MAX);

    -- enable logging on 1480 - if needed. 
    IF EXISTS (SELECT NULL FROM sys.messages WHERE [message_id] = 1480 AND [is_event_logged] = 0) BEGIN
        BEGIN TRY 
            EXEC master..sp_altermessage
	            @message_id = 1480, 
                @parameter = 'WITH_LOG', 
                @parameter_value = TRUE;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected problem enabling message_id 1480 for WITH_LOG on server [' + @@SERVERNAME + N'. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -10;
        END CATCH;
    END;

    -- job creation: 
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.syscategories WHERE [name] = @SqlServerAgentJobNameCategory AND category_class = 1) BEGIN
        
        BEGIN TRY
            EXEC msdb.dbo.sp_add_category 
                @class = N'JOB', 
                @type = N'LOCAL', 
                @name = @SqlServerAgentJobNameCategory;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected problem creating job category [' + @SqlServerAgentJobNameCategory + N'] on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -20;
        END CATCH;
    END;

    DECLARE @jobID uniqueidentifier;
    DECLARE @failoverHandlerCommand nvarchar(MAX) = N'EXEC [admindb].dbo.process_synchronization_failover{CONFIGURATION};
GO'

    IF UPPER(@OperatorName) = N'ALERTS' AND UPPER(@MailProfileName) = N'GENERAL' 
        SET @failoverHandlerCommand = REPLACE(@failoverHandlerCommand, N'{CONFIGURATION}', N'');
    ELSE 
        SET @failoverHandlerCommand = REPLACE(@failoverHandlerCommand, N'{CONFIGURATION}', NCHAR(13) + NCHAR(10) + NCHAR(9) + N'@MailProfileName = ''' + @MailProfileName + N''', @OperatorName = ''' + @OperatorName + N''' ');

    BEGIN TRANSACTION;

    BEGIN TRY

        EXEC msdb.dbo.[sp_add_job]
            @job_name = @SqlServerAgentFailoverResponseJobName,
            @enabled = 1,
            @description = N'Automatically executed in response to a synchronized database failover event.',
            @category_name = @SqlServerAgentJobNameCategory,
            @owner_login_name = N'sa',
            @notify_level_email = 2,
            @notify_email_operator_name = @OperatorName,
            @delete_level = 0,
            @job_id = @jobID OUTPUT;

        -- TODO: might need a version check here... i.e., this behavior is new to ... 2017? (possibly 2016?) (or I'm on drugs) (eithe way, NOT clearly documented as of 2019-07-29)
        EXEC msdb.dbo.[sp_add_jobserver] 
            @job_name = @SqlServerAgentFailoverResponseJobName, 
            @server_name = N'(LOCAL)';

        EXEC msdb.dbo.[sp_add_jobstep]
            @job_name = @SqlServerAgentFailoverResponseJobName, 
            @step_id = 1,
            @step_name = N'Respond to Failover',
            @subsystem = N'TSQL',
            @command = @failoverHandlerCommand,
            @cmdexec_success_code = 0,
            @on_success_action = 1,
            @on_success_step_id = 0,
            @on_fail_action = 2,
            @on_fail_step_id = 0,
            @database_name = N'admindb',
            @flags = 0;
    
        COMMIT TRANSACTION;
    END TRY 
    BEGIN CATCH 
        SELECT @errorMessage = N'Unexpected error creating failover response-handling job on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
        RAISERROR(@errorMessage, 16, 1);
        ROLLBACK TRANSACTION;
        RETURN -25;
    END CATCH;

    -- enable alerts - and map to job: 
    BEGIN TRY 
		DECLARE @1480AlertName sysname = N'1480 - Partner Role Change';

        IF EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE [message_id] = 1480 AND [name] = @1480AlertName)
            EXEC msdb.dbo.[sp_delete_alert] @name = N'1480 - Partner Role Change';

        EXEC msdb.dbo.[sp_add_alert]
            @name = @1480AlertName,
            @message_id = 1480,
            @enabled = 1,
            @delay_between_responses = 5,
            @include_event_description_in = 0,
            @job_name = @SqlServerAgentFailoverResponseJobName;
    END TRY 
    BEGIN CATCH 
        SELECT @errorMessage = N'Unexpected error mapping Alert 1480 to response-handling job on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
        RAISERROR(@errorMessage, 16, 1);
        RETURN -30;
    END CATCH;

    IF @ExecuteSetupOnPartnerServer = 1 BEGIN

        DECLARE @command nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.[add_failover_processing]
    @SqlServerAgentFailoverResponseJobName = @SqlServerAgentFailoverResponseJobName,
    @SqlServerAgentJobNameCategory = @SqlServerAgentJobNameCategory,      
    @MailProfileName = @MailProfileName,
    @OperatorName =  @OperatorName,				          
    @ExecuteSetupOnPartnerServer = 0; ';

        BEGIN TRY 
            EXEC sp_executesql 
                @command, 
                N'@SqlServerAgentFailoverResponseJobName sysname, @SqlServerAgentJobNameCategory sysname, @MailProfileName sysname, @OperatorName sysname', 
                @SqlServerAgentFailoverResponseJobName = @SqlServerAgentFailoverResponseJobName, 
                @SqlServerAgentJobNameCategory = @SqlServerAgentJobNameCategory, 
                @MailProfileName = @MailProfileName, 
                @OperatorName = @OperatorName;

        END TRY
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexected error while attempting to create job [' + @SqlServerAgentFailoverResponseJobName + N'] on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1); 
            RETURN -30;
        END CATCH;
    END;
    
    RETURN 0;
GO