

/*
	DEPENDENCIES:
		- Mirroring. 
		- PARTNER linked server definitions. 
		- dbo.server_trace_flags (Table)
		- dbo.is_primary_database (UDF)
		- dbo.server_synchronization_checks (sproc)
		- dbo.job_synchronization_checks (sproc)
		- dbo.respond_to_db_failover (sproc)

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple	


	--PARAMETERS:
		<OperatorName, sysname, Alerts>		= name of the email operator to send alerts to... 
		<MailProfileName, sysname, General>	= name of mail profile...  
		<DelaySecondsBetweenResponses, int, 4> = number of seconds to wait 'between' responses - so we don't spam/overload inboxes/etc. 
		<SQLAgentResponseJob-Automatic, sysname, Automated Databases Failover Response>	= Name of the Job that will respond to a Role Change (i.e., Failover).

*/


-- 1: Create the Job that will respond to the Alert: 

USE [msdb];
GO

BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'Monitoring' AND category_class=1)
BEGIN
EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'Monitoring'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

END

DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'<SQLAgentResponseJob-Automatic, sysname, Automated Databases Failover Response>', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=2, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'Automatically Executed in response to a Failover Event. 
(NOT SCHEDULED)', 
		@category_name=N'Monitoring', 
		@owner_login_name=N'sa', 
		@notify_email_operator_name=N'<OperatorName, sysname, Alerts>', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Respond to Failover', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'EXEC admindb.dbo.respond_to_db_failover
	@MailProfileName = N''<MailProfileName, sysname, General>'', 
	@OperatorName = N''<OperatorName, sysname, Alerts>'';
GO
', 
		@database_name=N'admindb', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


-- 2: Create (and bind) the Alert that will trigger the Response-Handler Job:
USE [msdb];
GO

DECLARE @jobid uniqueidentifier;
SELECT @jobid = job_id FROM msdb.dbo.sysjobs WHERE name = N'<SQLAgentResponseJob-Automatic, sysname, Automated Databases Failover Response>';

EXEC msdb.dbo.sp_add_alert @name=N'1480 - Replica Role Change', 
		@message_id=1480, 
		@severity=0, 
		@enabled=1, 
		@delay_between_responses= <delaySecondsBetweenResponses, int, 2>, 
		@include_event_description_in=0, 
		@category_name=N'[Uncategorized]', 
		@job_id = @jobid;			-- binds the JOBID as the response. 
GO