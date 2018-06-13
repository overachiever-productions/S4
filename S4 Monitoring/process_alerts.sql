
/*
	PURPOSE:
		[Severity 17+ = good alerts. but sometimes... noise. this allows filtered removal of 'noise' alerts... so that ... admins/etc. don't become innured/complacent about alerts]


	OVERVIEW:
		[Sadly, there's no SIMPLE way to do this... instead, we have to a) set up a job that'll take raw alert 'input', run it through a sproc, and let THAT define whether or not to 'forward' the alert or simply 'swallow'/ignore it]... 

	FODDER:
		https://docs.microsoft.com/en-us/sql/ssms/agent/use-tokens-in-job-steps?view=sql-server-2017

	PREREQUISITES:
		A. SQL Server Agent > Properties > Alert System > [x] - Replace tokens for all job responses to alerts.
		B. Configured/Defined Alerts (SQL Server Agent > Alerts). 


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
		(NOTE: This tests the sproc, not the job/etc. )

		DECLARE @ErrorNumber int, @Severity int;
		SET @ErrorNumber = 100001
		SET @Severity = 19;

		EXEC admindb.dbo.process_alerts
			@ErrorNumber = @ErrorNumber, 
			@Severity = @Severity,
			@Message = N'fake message here.... ';


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

	DECLARE @ignoredErrorNumbers TABLE ( 
		[error_number] int NOT NULL
	);

	INSERT INTO @ignoredErrorNumbers ([error_number])
	VALUES
	(7886) -- A read operation on a large object failed while sending data to the client. Example of a common-ish error you MAY wish to ignore, etc.  
	,(17806) -- SSPI handshake failure
	,(18056) -- The client was unable to reuse a session with SPID ###, which had been reset for connection pooling. The failure ID is 8. 
	--,(otherIdHere)
	--,(etc)
	;

	IF EXISTS (SELECT NULL FROM @ignoredErrorNumbers WHERE [error_number] = @ErrorNumber)
		RETURN 0; -- this is an ignored alert - we're done.

	DECLARE @body nvarchar(MAX); 
	
	SET @body = N'DATE/TIME: {0}

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