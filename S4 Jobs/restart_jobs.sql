
/*

	NOTE: 
		This is really only designed to be run at Server Startup (i.e., as a job that does NOT run on a schedule - instead/rather, it will kick off when the SQL SErver Agent Starts up
			then, it'll look for any jobs that were 'in process' at/around the time of power-down and look to see if we need to restart any at a specific time... 



	NOTE: 
		there's a limitation/flaw/bug in the SQL Server Agent: 
			- it will NOT log anything into msdb.dbo.sysjobhistory until the FIRST job-step of the job has completed. 
			So, if you've got, say, a 10 step job, and the first job-step takes 2 minutes to execute and... your server crashes 1 minute into the execution of that first job step, there's NO way to see that the job was ever even started... 

			as a work-around, you may want to drop a quick job step into the FRONT of your jobs (make sure you double-check the start step and the next action step) that basically says: PRINT 'Marking Job as Started for SysJobHistory....';


	EXEC dbo.restart_jobs @PrintOnly = 1;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.restart_jobs','P') IS NOT NULL
	DROP PROC dbo.restart_jobs;
GO

CREATE PROC dbo.restart_jobs 
	@ExcludedJobs							nvarchar(MAX)		= NULL, 
	@AlertOnErrorOnly						bit					= 0,								-- when disabled, a summary of any jobs that were restarted (or that NO jobs were found to restart) will always be sent (along with any error info). otherwise, only reports if/when there are problems.
	@OnlyRestartRecentlyFailedJobs			bit					= 1,								-- when enabled, only jobs that failed within the last 10 minutes will be restarted.
    @OperatorName							sysname				= N'Alerts',
    @MailProfileName						sysname				= N'General',
    @EmailSubjectPrefix						nvarchar(50)		= N'[JOBS RESTART] ', 
	@PrintOnly								bit					= 0
AS 
	SET NOCOUNT ON; 

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Validate Inputs: 

    IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
        
        -- Operator Checks:
        IF ISNULL(@OperatorName, '') IS NULL BEGIN
            RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
            RETURN -2;
         END;
        ELSE BEGIN 
            IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
                RAISERROR('Invalild Operator Name Specified.', 16, 1);
                RETURN -2;
            END;
        END;

        -- Profile Checks:
        DECLARE @DatabaseMailProfile nvarchar(255)
        EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
        IF @DatabaseMailProfile <> @MailProfileName BEGIN
            RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
            RETURN -2;
        END; 
    END;

    -----------------------------------------------------------------------------
    -- Processing:
	DECLARE @serviceStartupTime datetime;
	DECLARE @attempts int = 0;
	DECLARE @serviceShutDownTime datetime;  -- which is the MAX(logEntryTime) from the log file that pre-dates the server startup... 
	DECLARE @error nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @errorsEncountered bit = 0;
	
	SELECT @serviceStartupTime = sqlserver_start_time FROM sys.[dm_os_sys_info];
	
	CREATE TABLE #Entries ( 
		LogDate datetime NOT NULL, 
		ProcessInfo sysname NOT NULL, 
		[Text] varchar(2048) NULL 
	);

	INSERT INTO [#Entries] ( [LogDate], [ProcessInfo], [Text])	
	EXEC sys.[xp_readerrorlog] 1, 1;
	SELECT @serviceShutDownTime = MAX(LogDate) FROM [#Entries];

	IF @serviceShutDownTime > @serviceStartupTime BEGIN

LoadShutDownTime: 
		DELETE FROM [#Entries];

		INSERT INTO [#Entries] ( [LogDate], [ProcessInfo], [Text])	
		EXEC sys.[xp_readerrorlog] 1, 1;

		SELECT @serviceShutDownTime = MAX(LogDate) FROM [#Entries];

		IF @serviceShutDownTime IS NULL AND @attempts < 4 BEGIN
			SET @attempts = @attempts + 1;
			GOTO LoadShutDownTime;
		END;
	END; 

	SET @serviceShutDownTime = DATEADD(SECOND, -40, @serviceShutDownTime);

	CREATE TABLE #JobsToRestart (
		job_name sysname NOT NULL, 
		job_id uniqueidentifier NOT NULL, 
		start_time datetime NOT NULL, 
		down_time datetime NOT NULL, 
		last_job_step_id int NOT NULL,
		last_attempted_step sysname NOT NULL, 
		command nvarchar(2000) NULL, 
		restart_outcome int NULL,
		errors nvarchar(MAX) NULL
	);

	-- Extract Job Execution Details: 
	DECLARE @output xml = N'';
	EXEC admindb.dbo.list_running_jobs 
		@StartTime = @serviceShutDownTime, 
		@EndTime = @serviceStartupTime,
		@ExcludedJobs = @ExcludedJobs,
		@SerializedOutput = @output OUTPUT;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value('job_name[1]', 'sysname') job_name, 
			[data].[row].value('job_id[1]', 'uniqueidentifier') job_id, 
			[data].[row].value('step_name[1]', 'sysname') step_name, 
			[data].[row].value('step_id[1]', 'int') step_id, 
			[data].[row].value('start_time[1]', 'datetime') start_time, 
			--[data].[row].value('end_time[1]', 'datetime') end_time, 
			[data].[row].value('job_status[1]', 'sysname') job_status 
		FROM 
			@output.nodes('//job') [data]([row])
	)

	INSERT INTO #JobsToRestart ([job_name], [job_id], [start_time], [down_time], [last_job_step_id], last_attempted_step)
	SELECT 
		job_name, 
		job_id, 
		start_time, 
		@serviceShutDownTime [down_time],
		step_id [last_job_step_id], 
		step_name [last_attempted_step]
	FROM 
		[shredded] 
	WHERE 
		[job_status] <> 'COMPLETED';

	DECLARE walker CURSOR LOCAL READ_ONLY FAST_FORWARD FOR 
	SELECT 
		job_name,
		job_id, 
		[last_job_step_id], 
		[last_attempted_step]
	FROM 
		[#JobsToRestart] 
	ORDER BY 
		[start_time];

	DECLARE @jobName sysname;
	DECLARE @jobID uniqueidentifier; 
	DECLARE @stepID int; 
	DECLARE @stepName sysname;
	DECLARE @command nvarchar(2000); 
	DECLARE @template nvarchar(1000) = N'-- Restart Job [{job_name}] (at step: {step_id}) ' + @crlf + N'EXEC @outcome = msdb.dbo.sp_start_job @job_id = ''{job_id}'', @step_name = ''{step_name}'';' + @crlf;
	DECLARE @outcome int;
	DECLARE @body nvarchar(MAX);
	DECLARE @summary nvarchar(MAX) = N'';

	IF EXISTS(SELECT NULL FROM [#JobsToRestart]) BEGIN
		IF (@OnlyRestartRecentlyFailedJobs = 1) AND DATEDIFF(MINUTE, @serviceStartupTime, GETDATE()) > 10 BEGIN 
			SET @errorsEncountered = 1;  -- even though this is 'by design' we've still hit an 'error' (i.e., something that should be reported on). 
			
			SELECT 
				@summary = @summary + 'details go here... things like... i dunno. job name, started, and ... stuff' + @crlf
			FROM 
				[#JobsToRestart] 
			ORDER BY 
				[start_time];

			SET @body = N'Non-Completed SQL Server Agent Jobs were detected. However, it has been > 10 minutes since the SQL Server Service on ' + @@SERVERNAME + N' has been started. Job restart processing will NOT be executed. (NOTE: you can force execution of stalled jobs by setting @OnlyRestartRecentlyFailedJobs = 0 and/or by executing this code with @PrintOnly = 1 and then running the output scripts for any SPECIFIC jobs you might wish to run.';
			SET @body = @body + @crlf + @crlf + N'Details of Non-Completed Jobs: ';
			SET @body = @body + @summary;

			GOTO SendOutputReport;
		END; 

		OPEN [walker]; 

		FETCH NEXT FROM	[walker] INTO @jobName, @jobID, @stepID, @stepName; 
		WHILE @@FETCH_STATUS = 0 BEGIN 
		
			SET @command = REPLACE(@template, N'{job_name}', @jobName);
			SET @command = REPLACE(@command, N'{job_id}', @jobID);
			SET @command = REPLACE(@command, N'{step_id}', @stepID);
			SET @command = REPLACE(@command, N'{step_name}', @stepName);

			BEGIN TRY 
				IF @PrintOnly = 1 
					PRINT @command 
				ELSE BEGIN 

					SET @error = NULL;
					SET @outcome = 0;

					-- https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-start-job-transact-sql?view=sql-server-2017
					EXEC master.sys.[sp_executesql] 
						@command, 
						N'@outcome int', 
						@output = @outcome;

					IF @outcome <> 0 
						SET @error = N'Uknown Problem. Exception was not thrown when attempting to restart job; however, sp_start_job did NOT return a 0 (success).';
				END;
			END TRY 
			BEGIN CATCH
				SET @errorsEncountered = 1;
				SET @output = 2;
				SELECT @error = N'Exception while attempting to restart job. [Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N'].';
			END CATCH

			UPDATE [#JobsToRestart] 
			SET 
				[command] = @command , 
				[restart_outcome] = @outcome, 
				[errors] = @error
			WHERE 
				[job_name] = @jobName AND
				[job_id] = @jobID;

			FETCH NEXT FROM	[walker] INTO @jobName, @jobID, @stepID, @stepName; 
		END;

		CLOSE [walker];
		DEALLOCATE [walker];

	END;

	DECLARE @jobSummary nvarchar(MAX);
	IF @AlertOnErrorOnly = 1 AND @errorsEncountered = 0 
		GOTO SendOutputReport;  -- skip reporting... 

	SELECT
		@summary = @summary + N'details of stuff go here... ' + @crlf
	FROM 
		[#JobsToRestart] 
	ORDER BY 
		[start_time];

	SET @body = N'some sort of header would go here... '; 
	SET @body = @body + @summary;

SendOutputReport: 

	IF @body IS NOT NULL BEGIN; -- if we've build up a 'body', then we have a message to send (otherwise, there was either nothing to report, or the 'need' to report was set to 0 via various options/switches). 
		
		DECLARE @emailSubject sysname; 


		IF @PrintOnly = 1 BEGIN
			PRINT @emailSubject;
			PRINT @body;

		  END;
		ELSE BEGIN
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @body;	
		END;
	END;

	RETURN 0;
GO	