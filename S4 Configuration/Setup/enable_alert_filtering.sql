/*
    TODO: 
        - add error handling (try/catch/etc.)

		- ALL is a bad-ish default. Might make more sense to use tokens ... e.g.., SEVERITY and IO and so on ... and default to jsut SEVERITY?

    vNEXT: 
        - at least 2x ... inline/in-code... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.enable_alert_filtering','P') IS NOT NULL
	DROP PROC dbo.[enable_alert_filtering];
GO

CREATE PROC dbo.[enable_alert_filtering]
    @TargetAlerts                   nvarchar(MAX)           = N'{ALL}', 
    @ExcludedAlerts                 nvarchar(MAX)           = NULL,                        -- N'%18, %4605%, Severity%, etc..'. NOTE: 1480, if present, is filtered automatically.. 
    @AlertsProcessingJobName        sysname                 = N'Filter Alerts', 
    @AlertsProcessingJobCategory    sysname                 = N'Alerting',
	@OperatorName				    sysname					= N'Alerts',
	@MailProfileName			    sysname					= N'General'
AS
    SET NOCOUNT ON; 

	-- {copyright}

    ------------------------------------
    -- create a 'response' job: 
    DECLARE @errorMessage nvarchar(MAX);

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.syscategories WHERE [name] = @AlertsProcessingJobCategory AND category_class = 1) BEGIN
        
        BEGIN TRY
            EXEC msdb.dbo.sp_add_category 
                @class = N'JOB', 
                @type = N'LOCAL', 
                @name = @AlertsProcessingJobCategory;
        END TRY 
        BEGIN CATCH 
            SELECT @errorMessage = N'Unexpected problem creating job category [' + @AlertsProcessingJobCategory + N'] on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            RETURN -20;
        END CATCH;
    END;

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobs WHERE [name] = @AlertsProcessingJobName) BEGIN 
    
        -- vNEXT: check to see if there isn't already a job 'out there' that's doing these exact same things - i.e., where the @command is pretty close to the same stuff 
        --          being done below. And, if it is, raise a WARNING... but don't raise an error OR kill execution... 
        DECLARE @command nvarchar(MAX) = N'
        DECLARE @ErrorNumber int, @Severity int;
        SET @ErrorNumber = CONVERT(int, N''$(ESCAPE_SQUOTE(A-ERR))'');
        SET @Severity = CONVERT(int, N''$(ESCAPE_NONE(A-SEV))'');

        EXEC admindb.dbo.process_alerts 
	        @ErrorNumber = @ErrorNumber, 
	        @Severity = @Severity,
	        @Message = N''$(ESCAPE_SQUOTE(A-MSG))'', 
            @OperatorName = N''{operator}'', 
            @MailProfileName = N''{profile}''; ';

        SET @command = REPLACE(@command, N'{operator}', @OperatorName);
        SET @command = REPLACE(@command, N'{profile}', @MailProfileName);
        
        BEGIN TRANSACTION; 

        BEGIN TRY 
            EXEC msdb.dbo.[sp_add_job]
                @job_name = @AlertsProcessingJobName,
                @enabled = 1,
                @description = N'Executed by SQL Server Agent Alerts - to enable logic/processing for filtering of ''noise'' alerts.',
                @start_step_id = 1,
                @category_name = @AlertsProcessingJobCategory,
                @owner_login_name = N'sa',
                @notify_level_email = 2,
                @notify_email_operator_name = @OperatorName,
                @delete_level = 0;

            -- TODO: might need a version check here... i.e., this behavior is new to ... 2017? (possibly 2016?) (or I'm on drugs) (eithe way, NOT clearly documented as of 2019-07-29)
            EXEC msdb.dbo.[sp_add_jobserver] 
                @job_name = @AlertsProcessingJobName, 
                @server_name = N'(LOCAL)';

            EXEC msdb.dbo.[sp_add_jobstep]
                @job_name = @AlertsProcessingJobName,
                @step_id = 1,
                @step_name = N'Process Alert Filtering',
                @subsystem = N'TSQL',
                @command = @command,
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
            SELECT @errorMessage = N'Unexpected error creating alert-processing/filtering job on server [' + @@SERVERNAME + N']. Error: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']';
            RAISERROR(@errorMessage, 16, 1);
            ROLLBACK TRANSACTION;
            RETURN -25;
        END CATCH;

      END;
    ELSE BEGIN 
        -- vNEXT: verify that the @OperatorName and @MailProfileName in job-step 1 are the same as @inputs... 
        PRINT 'TODO/vNEXT. [1]';
    END;

    ------------------------------------
    -- process targets/exclusions:
    DECLARE @inclusions table (
        [name] sysname NOT NULL 
    );

    DECLARE @targets table (
        [name] sysname NOT NULL 
    );

    IF UPPER(@TargetAlerts) = N'{ALL}' BEGIN 
        INSERT INTO @targets (
            [name] 
        )
        SELECT 
            s.[name] 
        FROM 
            msdb.dbo.[sysalerts] s
      END;
    ELSE BEGIN 
        INSERT INTO @inclusions (
            [name]
        )
        SELECT [result] FROM [dbo].[split_string](@TargetAlerts, N',', 1);

        INSERT INTO @targets (
            [name]
        )
        SELECT 
            a.[name]
        FROM 
            msdb.dbo.[sysalerts] a
            INNER JOIN @inclusions i ON a.[name] LIKE i.[name];
    END;

    DECLARE @exclusions table ( 
        [name] sysname NOT NULL
    );

    INSERT INTO @exclusions (
        [name]
    )
    VALUES (
        N'1480%'
    );

    IF NULLIF(@ExcludedAlerts, N'') IS NOT NULL BEGIN
        INSERT INTO @exclusions (
            [name]
        )
        SELECT [result] FROM dbo.[split_string](@ExcludedAlerts, N',', 1);
    END;
	
    DECLARE walker CURSOR LOCAL FAST_FORWARD FOR
    SELECT 
        [t].[name] 
    FROM 
        @targets [t]
        LEFT OUTER JOIN @exclusions x ON [t].[name] LIKE [x].[name]
    WHERE 
        x.[name] IS NULL;

    DECLARE @currentAlert sysname; 

    OPEN [walker]; 

    FETCH NEXT FROM [walker] INTO @currentAlert;

    WHILE @@FETCH_STATUS = 0 BEGIN
        
        IF EXISTS (SELECT NULL FROM msdb.dbo.[sysalerts] WHERE [name] = @currentAlert AND [has_notification] = 1) BEGIN
            EXEC msdb.dbo.[sp_delete_notification] 
                @alert_name = @currentAlert, 
                @operator_name = @OperatorName;
        END;
        
        IF NOT EXISTS (SELECT NULL FROM [msdb].dbo.[sysalerts] WHERE [name] = @currentAlert AND NULLIF([job_id], N'00000000-0000-0000-0000-000000000000') IS NOT NULL) BEGIN
            EXEC msdb.dbo.[sp_update_alert]
                @name = @currentAlert,
                @job_name = @AlertsProcessingJobName;
        END;
        
        FETCH NEXT FROM [walker] INTO @currentAlert;
    END;

    CLOSE [walker];
    DEALLOCATE [walker];

    RETURN 0;
GO