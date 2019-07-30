/*
	DEPENDENCIES:
		- Mirroring. 
		- PARTNER linked server definitions. 
		- dbo.server_trace_flags (Table)
		- dbo.is_primary_database (UDF)
		- dbo.server_synchronization_checks (sproc)
		- dbo.job_synchronization_checks (sproc)

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple	


	PARAMETERS:
		<MailProfileName, sysname, General> = Name of the Mail Profile Used to send email alerts when differences encountered. 
		<OperatorName, sysname, Alerts> = Name of the Operator to send alerts to. 


		NOTE: Server Configuration details (like maxdop, max memory, trace flags/etc.), can't be ignored by scripts in their present form - as these are system-wide changes that will impact EVERYTHING running 
			on the server - and SHOULD be 100% identical between servers. 

		NOTE: all 'Ignored' parameters require entries to be in comma-delimited format - i.e., @IgnoredLogins = N'Mike,Sandobal,Aisha,SomeAppName,etc';
		<IgnoredMasterDbObjects, nvarchar(400),> = Names of user-defined tables, views, UDFs, and sprocs to ignore in the master databases of either server. 
		<IgnoredAlerts,sysname,> = Names of any Alerts that should NOT be compared/evaluated between servers. 
		<IgnoredLogins,nvarchar(400),> = Names of any logins to ignore. 
		<IgnoredLinkedServers,nvarchar(400),> = Names of any LinkedServers to ignore between servers.

		<IgnoredJobs,nvarchar(max),> = Full-names of any jobs you don't want to run synchronization checks against. (e.g., N'Agent history clean up: distribution,Replication agents checkup,Distribution clean up: distribution,etc.'

*/



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
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Monitoring - Server and Job Synchronization Checks', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=2, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'Regular checkups on Server settings/configurations and SQL Server Agent Jobs.', 
		@category_name=N'Monitoring', 
		@owner_login_name=N'sa', 
		@notify_email_operator_name=N'<OperatorName, sysname, Alerts>', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Run Synchronization Checks', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0,
	    @subsystem=N'TSQL', 
		@command=N'-- check on server-level details/objects:
EXEC admindb.dbo.server_synchronization_checks 
    @MailProfileName = N''<MailProfileName, sysname, General>'',
    @OperatorName = N''<OperatorName, sysname, Alerts>'',
    @IgnoredMasterDbObjects = N''<IgnoredMasterDbObjects, nvarchar(400),>'', 
    @IgnoredAlerts = N''<IgnoredAlerts,sysname,>'', 
    @IgnoredLogins = N''<IgnoredLogins,nvarchar(400),>'',
    @IgnoredLinkedServers = N''<IgnoredJobs,nvarchar(max),>'';

-- Check on Jobs (Server-Level and for Mirrored DBs):
EXEC admindb.dbo.job_synchronization_checks
    @MailProfileName = N''<MailProfileName, sysname, General>'', 
    @OperatorName = N''<OperatorName, sysname, Alerts>'', 
    @IgnoredJobs = ''<IgnoredJobs,nvarchar(max),>'';', 
		@database_name=N'admindb', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Server and Jobs Synchronization Checks Schedule', 
		@enabled=1, 
		@freq_type=4, 
		@freq_interval=1, 
		@freq_subday_type=4, 
		@freq_subday_interval=15, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20160514, 
		@active_end_date=99991231, 
		@active_start_time=500, 
		@active_end_time=235959, 
		@schedule_uid=N'0147c3fc-7640-4957-9535-ef95530779c5'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:

GO


