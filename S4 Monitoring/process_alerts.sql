
/*
	PURPOSES:
		- Severity 17+ alerts are great - only, sometimes, there's 'noise' in the sense that SOME errors don't really need to be addressed at all. 
		- vNEXT: Or, while some Severity 17+ errors can/should be ignored if/when there's a single error (within a long duration of time) - whereas multiple/successive (or a 'burst' of errors) should NOT be ignored. 
		- vNEXT: Some alerts/error types should have some sort processing/operation tackled. (Granted, Alerts allow this 'out of the box' - but also require explicit wire-up of jobs to tackle - which isn't always the best option. 

	OVERVIEW:
		[Sadly, there's no SIMPLE way to do this... instead, we have to a) set up a job that'll take raw alert 'input', run it through a sproc, and let THAT define whether or not to 'forward' the alert or simply 'swallow'/ignore it]... 

	FODDER:
		https://docs.microsoft.com/en-us/sql/ssms/agent/use-tokens-in-job-steps?view=sql-server-2017

	PREREQUISITES:
		A. SQL Server Agent > Properties > Alert System > [x] - Replace tokens for all job responses to alerts.
		B. Configured/Defined Alerts (SQL Server Agent > Alerts). 

	DEPENDENCIES:
		- dbo.alert_responses (table)

	DEPLOYMENT:
		1. Match Pre-Requisites. 
		2. Create Sproc Below - Making sure to remove/add any alerts you want to exclude/include from future alerts. 
		3. Create a new job (sample/example is below) - i.e., called "Process Alerts" (or whatever). 

				The 'body' of the job step being configured should look as follows: 
				
				
							DECLARE @ErrorNumber int, @Severity int;
							SET @ErrorNumber = CONVERT(int, N'$(ESCAPE_SQUOTE(A-ERR))');
							SET @Severity = CONVERT(int, N'$(ESCAPE_NONE(A-SEV))');

							EXEC admindb.dbo.process_alerts
								@ErrorNumber = @ErrorNumber, 
								@Severity = @Severity,
								@Message = N'$(ESCAPE_SQUOTE(A-MSG))';


		4. Modify all alerts that you wish to have processed by this logic to use the JOB you created (from step 3) as the response (instead of sending an email). 
			SQL Server Agent > Alerts > Alert [i.e., specific alert to modify] > Properties > Responses > [x] - Execute job -> [job-name-from-step-3] (and uncheck 'Notify operators').


	SAMPLE EXECUTION EXAMPLE: 
		(NOTE: This tests the sproc, not the JOB.)


		-- fake error - that'll get sent/forwarded: 
		EXEC admindb.dbo.process_alerts
			@ErrorNumber = 100001, 
			@Severity = 19,
			@Message = N'Totally fake error number and message detected.';

		-- example of an ignored (by S4 default) 
		EXEC admindb.dbo.process_alerts
			@ErrorNumber = 17806, 
			@Severity = 20,
			@Message = N'SSPI handshake failed with error code 0x88976, state 14 while establishing a connection with integrated security; the connection has been closed.';		


*/


USE [admindb];
GO

IF OBJECT_ID('dbo.process_alerts','P') IS NOT NULL
	DROP PROC dbo.process_alerts;
GO

CREATE PROC dbo.process_alerts 
	@ErrorNumber				int, 
	@Severity					int, 
	@Message					nvarchar(2048),
	@OperatorName				sysname					= N'Alerts',
	@MailProfileName			sysname					= N'General'
AS 
	SET NOCOUNT ON; 

	DECLARE @response nvarchar(2000); 

	SELECT @response = response FROM dbo.alert_responses 
	WHERE 
		message_id = @ErrorNumber
		AND is_enabled = 1;

	IF NULLIF(@response, N'') IS NOT NULL BEGIN 

		IF UPPER(@response) = N'[IGNORE]' BEGIN 
			
			-- this is an explicitly ignored alert. print the error details (which'll go into the SQL Server Agent Job log), then bail/return: 
			PRINT '[IGNORED] Error. Severity: ' + CAST(@Severity AS sysname) + N', ErrorNumber: ' + CAST(@ErrorNumber AS sysname) + N', Message: '  + @Message;
			RETURN 0;
		END;

		-- vNEXT:
			-- add additional processing options here. 
	END;

	------------------------------------
	-- If we're still here, then there were now 'special instructions' for this specific error/alert(so send an email with details): 

	DECLARE @body nvarchar(MAX) = N'DATE/TIME: {0}

DESCRIPTION: {1}

ERROR NUMBER: {2}' ;

	SET @body = REPLACE(@body, '{0}', CONVERT(nvarchar(20), GETDATE(), 100));
	SET @body = REPLACE(@body, '{1}', @Message);
	SET @body = REPLACE(@body, '{2}', @ErrorNumber);

	DECLARE @subject nvarchar(256) = N'SQL Server Alert System: ''Severity {0}'' occurred on {1}';

	SET @subject = REPLACE(@subject, '{0}', @Severity);
	SET @subject = REPLACE(@subject, '{1}', @@SERVERNAME); 
	
	EXEC msdb.dbo.sp_notify_operator
		@profile_name = @MailProfileName, 
		@name = @OperatorName,
		@subject = @subject, 
		@body = @body;

	RETURN 0;

GO




/*

----------------------------------------------------------------------------------------------------------------------
-- Job Creation (Step 3):
--	NOTE: script below ASSUMES convention of 'Alerts' as operator to notify in case of problems... 

USE [msdb];
GO

BEGIN TRANSACTION;
	DECLARE @ReturnCode int;
	SELECT @ReturnCode = 0;
	IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'Monitoring' AND category_class=1) BEGIN
		EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'Monitoring';
		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback;
	END;

	DECLARE @jobId BINARY(16);
	EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Process Alerts', 
			@enabled=1, 
			@notify_level_eventlog=0, 
			@notify_level_email=2, 
			@notify_level_netsend=0, 
			@notify_level_page=0, 
			@delete_level=0, 
			@description=N'NOTE: This job responds to alerts (and filters out specific error messages/ids) and therefore does NOT have a schedule.', 
			@category_name=N'Monitoring', 
			@owner_login_name=N'sa', 
			@notify_email_operator_name=N'Alerts', 
			@job_id = @jobId OUTPUT;
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

	EXEC @ReturnCode = msdb.dbo.sp_add_jobstep 
			@job_id=@jobId, 
			@step_name=N'Filter and Send Alerts', 
			@step_id=1, 
			@cmdexec_success_code=0, 
			@on_success_action=1, 
			@on_success_step_id=0, 
			@on_fail_action=2, 
			@on_fail_step_id=0, 
			@retry_attempts=0, 
			@retry_interval=0, 
			@os_run_priority=0, @subsystem=N'TSQL', 
			@command=N'DECLARE @ErrorNumber int, @Severity int;
SET @ErrorNumber = CONVERT(int, N''$(ESCAPE_SQUOTE(A-ERR))'');
SET @Severity = CONVERT(int, N''$(ESCAPE_NONE(A-SEV))'');

EXEC admindb.dbo.process_alerts 
	@ErrorNumber = @ErrorNumber, 
	@Severity = @Severity,
	@Message = N''$(ESCAPE_SQUOTE(A-MSG))'';', 
			@database_name=N'admindb', 
			@flags=0;
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1;
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
	IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
	COMMIT TRANSACTION;
	GOTO EndSave;
	QuitWithRollback:
		IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
	EndSave:

GO


*/