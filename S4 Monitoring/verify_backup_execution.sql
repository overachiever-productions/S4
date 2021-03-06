/*

EXEC admindb.dbo.verify_backup_execution
    @DatabasesToCheck = N'billing,maskedDB3',             -- nvarchar(max)
    @DatabasesToExclude = N'maskedDB3',           -- nvarchar(max)
    @FullBackupAlertThresholdHours = 24,  -- 2 hours - to throw warnings... 
    @LogBackupAlertThresholdMinutes = 20, --  2 minutes - ditto... 
    @MonitoredJobs = N'User Databases.Log Backups'

*/


/*

	TODO:

	vNEXT:
		- Add functionality for @DiffBackupAlertThresholdMinutes ... to optionally specify DIFF backup frequencies. 
				This isn't really needed for all dbs... and ... in some cases it'll mean setting up a job/execution that checks all DBs except 'bigdatabase' + another execution for 'big-database' that checks full/diff/t-log on different thresholds than 'other' databases.


		- I'm 'throwing' master and msdb into the 'mix' of dbs to check - period. 
				but... do i want to have those 'tied' to the same FULL backup thresholds? Seems like... NOT. 

				YEAH. Probably not. 
				In fact, guessing that I need an @SystemDBsFullBackupThresholdHours switch as well... and just default it to 24.... 


	Purpose/Goal
		- Can't have a backup job 'stuck' and just 'trying' but not failing. 
		- Also, don't want to have gone X time without T-Log backups being taken and such. 



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_backup_execution','P') IS NOT NULL
	DROP PROC dbo.verify_backup_execution;
GO

CREATE PROC dbo.verify_backup_execution 
	@DatabasesToCheck					nvarchar(MAX),
	@DatabasesToExclude					nvarchar(MAX)		= NULL,
	@FullBackupAlertThresholdHours		int, 
	@LogBackupAlertThresholdMinutes		int,
	@MonitoredJobs						nvarchar(MAX)		= NULL, 
	@AllowNonAccessibleSecondaries		bit					= 0,
	@MinimumElapsedSecondsToConsider	int					= 60,   -- if a specified backup job has been running < @MinimumElapsedSecondsToConsider, then there's NO reason to raise an alert. 
	@MaximumElapsedSecondsToIgnore		int					= 300,			-- if a backup job IS running longer than normal, but is STILL under @MaximumElapsedSecondsToIgnore, then there's no reason to raise an alert. 
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[Database Backups - Failed Checkups] ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs: 

	-- Operator Checks:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalild Operator Name Specified.', 16, 1);
			RETURN -4;
		END;
	END;

	-- Profile Checks:
	DECLARE @DatabaseMailProfile nvarchar(255);
	EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
	IF @DatabaseMailProfile != @MailProfileName BEGIN
		RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
		RETURN -5;
	END;

	-----------------------------------------------------------------------------

	DECLARE @outputs table (
		output_id int IDENTITY(1,1) NOT NULL, 
		[type] sysname NOT NULL, -- warning or error 
		[message] nvarchar(MAX)
	);

	DECLARE @errorMessage nvarchar(MAX) = '';

	-----------------------------------------------------------------------------
	-- Determine which databases to check:
	DECLARE @databaseToCheckForFullBackups table (
		[name] sysname NOT NULL
	);

	DECLARE @databaseToCheckForLogBackups table (
		[name] sysname NOT NULL
	);

	INSERT INTO @databaseToCheckForFullBackups ([name])
	EXEC dbo.list_databases 
		@Targets = @DatabasesToCheck,
		@Exclusions = @DatabasesToExclude; 

	INSERT INTO @databaseToCheckForLogBackups ([name])
	EXEC dbo.list_databases 
		@Targets = @DatabasesToCheck,
		@Exclusions = @DatabasesToExclude, 
		@ExcludeSimpleRecovery = 1;

	-----------------------------------------------------------------------------
	-- Determine which jobs to check:
	DECLARE @specifiedJobs table ( 
		jobname sysname NOT NULL
	);

	DECLARE @jobsToCheck table ( 
		jobname sysname NOT NULL, 
		jobid uniqueidentifier NULL
	);

	INSERT INTO @specifiedJobs (jobname)
	SELECT [result] FROM dbo.split_string(@MonitoredJobs, N',', 1) ORDER BY row_id;

	INSERT INTO @jobsToCheck (jobname, jobid)
	SELECT 
		s.jobname, 
		j.job_id [jobid]
	FROM 
		@specifiedJobs s
		LEFT OUTER JOIN msdb..sysjobs j ON s.jobname COLLATE SQL_Latin1_General_CP1_CI_AS = j.[name];

	-----------------------------------------------------------------------------
	-- backup checks:

	BEGIN TRY

		-- FULL Backup Checks: 
		DECLARE @backupStatuses table (
			backup_id int IDENTITY(1,1) NOT NULL,
			[database_name] sysname NOT NULL, 
			[backup_type] sysname NOT NULL, 
			[minutes_since_last_backup] int
		);

		WITH core AS (
			SELECT 
				b.[database_name] COLLATE SQL_Latin1_General_CP1_CI_AS [database_name],
				CASE b.[type] COLLATE SQL_Latin1_General_CP1_CI_AS	
					WHEN 'D' THEN 'FULL'
					WHEN 'I' THEN 'DIFF'
					WHEN 'L' THEN 'LOG'
					ELSE 'OTHER'  -- options include, F, G, P, Q, [NULL] 
				END [backup_type],
				MAX(b.backup_finish_date) [last_completion]
			FROM 
				@databaseToCheckForFullBackups x
				INNER JOIN msdb.dbo.backupset b ON x.[name] = b.[database_name] COLLATE SQL_Latin1_General_CP1_CI_AS
			WHERE
				b.is_damaged = 0
				AND b.has_incomplete_metadata = 0
				AND b.is_copy_only = 0
			GROUP BY 
				b.[database_name]  COLLATE SQL_Latin1_General_CP1_CI_AS, 
				b.[type]  COLLATE SQL_Latin1_General_CP1_CI_AS
		) 
	
		INSERT INTO @backupStatuses ([database_name], backup_type, minutes_since_last_backup)
		SELECT 
			[database_name],
			[backup_type],
			DATEDIFF(MINUTE, last_completion, GETDATE()) [minutes_since_last_backup]
		FROM 
			core
		ORDER BY 
			[core].[database_name];

		-- Grab a list of any dbs that were specified for checkups, but which aren't on the server - then report on those, and use the temp-table for exclusions from subsequent checks:
		DECLARE @phantoms table (
			[name] sysname NOT NULL
		);

		INSERT INTO @phantoms ([name])
		SELECT [name] FROM @databaseToCheckForFullBackups WHERE [name] NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM master.sys.databases WHERE state_desc = 'ONLINE');

		-- Remove non-accessible secondaries (Mirrored or AG'd) as needed/specified:
		IF @AllowNonAccessibleSecondaries = 1 BEGIN

			DECLARE @activeSecondaries table ( 
				[name] sysname NOT NULL
			);

			INSERT INTO @activeSecondaries ([name])
			SELECT [name] FROM master.sys.databases 
			WHERE [name] IN (SELECT d.[name] FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL AND m.mirroring_role_desc != 'PRINCIPAL' )
			OR [name] IN (
				SELECT d.name 
				FROM master.sys.databases d 
				INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
				WHERE hars.role_desc != 'PRIMARY'
			); -- grab any dbs that are in an AG where the current role != PRIMARY. 


			-- remove secondaries from any list of CHECKS and from the list of statuses we've pulled back (because evaluation is a comparison of BOTH sides of the union/join of these sets).
			DELETE FROM @backupStatuses WHERE [database_name] IN (SELECT [name] FROM @activeSecondaries);

			DELETE FROM @phantoms WHERE [name] IN (SELECT [name] FROM @activeSecondaries);
			DELETE FROM @databaseToCheckForFullBackups WHERE [name] IN (SELECT [name] FROM @activeSecondaries);
			DELETE FROM @databaseToCheckForLogBackups WHERE [name] IN (SELECT [name] FROM @activeSecondaries);

		END;

		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING',
			N'Database [' + [name] + N'] was configured for backup checks/verifications - but is NOT currently listed as an ONLINE database on the server.'
		FROM 
			@phantoms
		ORDER BY 
			[name];

		-- Report on databases that were specified for checks, but which have NEVER been backed-up:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING', 
			N'Database [' + [name] + '] has been configured for regular FULL backup checks/verifications - but has NEVER been backed up.'
		FROM 
			@databaseToCheckForFullBackups
		WHERE 
			[name] NOT IN (SELECT [database_name] FROM @backupStatuses WHERE backup_type = 'FULL')
			AND [name] NOT IN (SELECT [name] FROM @phantoms);
		
		-- Report on databases that were specified for checks, but which haven't had FULL backups in > @FullBackupAlertThresholdHours:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING' [type], 
			N'The last successful FULL backup for database [' + [database_name] + N'] was ' + CAST((minutes_since_last_backup / 60) AS sysname) + N' hours (and ' + CAST((minutes_since_last_backup % 60) AS sysname) + N' minutes) ago - which exceeds the currently specified value of ' + CAST(@FullBackupAlertThresholdHours AS sysname) + N' hours for @FullBackupAlertThresholdHours.'
		FROM 
			@backupStatuses
		WHERE 
			backup_type = 'FULL'
			AND minutes_since_last_backup > 60 * @FullBackupAlertThresholdHours
		ORDER BY 
			minutes_since_last_backup DESC;

		-- Report on User DBs specified for checkups that are set to NON-SIMPLE recovery, and which haven't had their T-Logs backed up:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING',
			N'Database [' + [name] + N'] has been configured for regular LOG backup checks/verifiation - but has NEVER had its Transaction Log backed up.'
		FROM 
			@databaseToCheckForLogBackups
		WHERE 
			[name] NOT IN (SELECT [database_name] FROM @backupStatuses WHERE backup_type = 'LOG')
			AND [name] NOT IN (SELECT [name] FROM @phantoms);

		-- Report on databases in NON-SIMPLE recovery mode that haven't had their T-Logs backed up in > @LogBackupAlertThresholdMinutes:
		INSERT INTO @outputs ([type], [message])
		SELECT 
			N'WARNING', 
			N'The last successful Transaction Log backup for database [' + [database_name] + N'] was ' + CAST((minutes_since_last_backup / 60) AS sysname) + N' hours (and ' + CAST((minutes_since_last_backup % 60) AS sysname) + N' minutes) ago - which exceeds the currently specified value of ' + CAST(@LogBackupAlertThresholdMinutes AS sysname) + N' minutes for @LogBackupAlertThresholdMinutes.'
		FROM 
			@backupStatuses
		WHERE 
			backup_type = 'LOG'
			AND minutes_since_last_backup > @LogBackupAlertThresholdMinutes
		ORDER BY 
			minutes_since_last_backup DESC;
	
	END TRY
	BEGIN CATCH
		SELECT @errorMessage = N'Exception during Backup Checks: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']'; 

		INSERT INTO @outputs ([type], [message])
		VALUES ('EXCEPTION', @errorMessage);

		SET @errorMessage = '';
	END CATCH

	-----------------------------------------------------------------------------
	-- job checks:


	IF (SELECT COUNT(*) FROM @jobsToCheck) > 0 BEGIN

		BEGIN TRY
			-- Warn about any jobs specified for checks that aren't actual jobs (i.e., where the names couldn't match a SQL Agent job).
			INSERT INTO @outputs ([type], [message])
			SELECT 
				N'WARNING', 
				N'Job [' + jobname + '] was configured for a regular checkup - but is NOT a VALID SQL Server Agent Job Name.'
			FROM 
				@jobsToCheck 
			WHERE 
				jobid IS NULL
			ORDER BY 
				jobname;

			-- otherwise, make sure that if the job is currently running, it hasn't exceeded 130% of the time it normally takes to run. 
			DECLARE @currentJobName sysname, @currentJobID uniqueidentifier;
			DECLARE @instanceCounts int, @avgRunDuration int;

			DECLARE @isExecuting bit, @elapsed int;
		
			DECLARE checker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT jobname, jobid FROM @jobsToCheck WHERE jobid IS NOT NULL; 

			OPEN checker;
			FETCH NEXT FROM checker INTO @currentJobName, @currentJobID;

			WHILE @@FETCH_STATUS = 0 BEGIN
				SET @isExecuting = 0;
				SET @elapsed = 0;

				WITH core AS ( 
					SELECT job_id, 
						DATEDIFF(SECOND, run_requested_date, GETDATE()) [elapsed] 
					FROM msdb.dbo.sysjobactivity 
					WHERE run_requested_date IS NOT NULL AND stop_execution_date IS NULL
				)

				SELECT 
					@isExecuting = CASE when job_id IS NULL THEN 0 ELSE 1 END, 
					@elapsed = elapsed 
				FROM 
					core
				WHERE 
					job_id = @currentJobID;

				-- 4.2.3.16822 Only check for 'long-running' jobs if a) duration is > @MinimumElapsedSecondsToConsider (i.e., don't alert for a job running 220% over normal IF 220% over normal is, say, 10 seconds TOTAL)
				--		 _AND_ b) if @elapsed is >  @MaximumElapsedSecondsToIgnore - i.e., don't alert if 'total elapsed' time is, say, 3 minutes - who cares...  (in 15 minutes when we run again, IF this job is still running (and that's a problem), THEN we'll get an alert). 
				IF (@isExecuting = 1) AND (@elapsed > @MinimumElapsedSecondsToConsider) AND (@elapsed > @MaximumElapsedSecondsToIgnore) BEGIN	

					-- check on execution durations:
					SELECT 
						@instanceCounts = COUNT(*), 
						@avgRunDuration = AVG(run_duration) 
					FROM (
						SELECT TOP(20)
							run_duration 
						FROM 
							msdb.dbo.sysjobhistory 
						WHERE 
							job_id = @currentJobID
							AND step_id = 0 AND run_status = 1 -- only grab metrics/durations for the ENTIRE duration of (successful only) executions.
						ORDER BY 
							run_date DESC, 
							run_time DESC
						) latest;
				

					IF @instanceCounts < 6 BEGIN 
						-- Arguably, we could send a 'warning' here ... but that's lame. At present, there is NOT a problem - because we don't have enough history to determine if this execution is 'out of scope' or not. 
						--		so, rather than causing false-alarms/red-herrings, just spit out a bit of info into the job history instead.
						PRINT 'History for job [' + @currentJobName + '] only contains information on the last ' + CAST(@instanceCounts AS sysname) + N' executions of the job. Meaning there is not enough history to determine abnormalities.'

				       END;
					ELSE BEGIN

						-- otherwise, if the current execution duration is > 220% of normal execution - raise an alert... 
						IF @elapsed > @avgRunDuration * 2.2 BEGIN
							INSERT INTO @outputs ([type], [message])
							SELECT 
								N'WARNING',
								N'Job [' + @currentJobName + N'] is currently running, and has been running for ' + CAST(@elapsed AS sysname) + N' seconds - which is greater than 220% of the average time it has taken to execute over the last ' + CAST(@instanceCounts AS sysname) + N' executions.'
						END;
					END;
				
				END;

				FETCH NEXT FROM checker INTO @currentJobName, @currentJobID;
			END;


		END TRY
		BEGIN CATCH
			SELECT @errorMessage = N'Exception during Job Checks: [' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE() + N']'; 

			INSERT INTO @outputs ([type], [message])
			VALUES ('EXCEPTION', @errorMessage);			
		END CATCH

		CLOSE checker;
		DEALLOCATE checker;

	END;  -- /IF JobChecks


	IF EXISTS (SELECT NULL FROM @outputs) BEGIN

		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9); 

		DECLARE @message nvarchar(MAX); 
		DECLARE @subject nvarchar(2000);

		IF EXISTS (SELECT NULL FROM @outputs WHERE [type] = 'EXCEPTION') 
			SET @subject = @EmailSubjectPrefix + N' Exceptions Detected';
		ELSE  
			SET @subject = @EmailSubjectPrefix + N' Warnings Detected';

		SET @message = N'The following problems were encountered during execution:' + @crlf + @crlf;

		--MKC: Insane. The following does NOT work. It returns only the LAST row from a multi-row 'set'. (remove the order-by, and ALL results return. Crazy.)
			--SELECT 
			--	@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
			--FROM 
			--	@outputs
			--ORDER BY 
			--	CASE WHEN [type] = 'EXCEPTION' THEN 0 ELSE 1 END ASC, output_id ASC;

		-- So, instead of combining 'types' of outputs, i'm just hacking this to concatenate 2x different result 'sets' or types of results. (I could try a CTE + Windowing Function... or .. something else, but this is easiest for now). 
		SELECT 
			@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
		FROM 
			@outputs
		WHERE 
			[type] = 'EXCEPTION'
		ORDER BY 
			output_id ASC;

		-- + this:
		SELECT 
			@message = @message + @tab + N'[' + [type] + N'] - ' + [message] + @crlf
		FROM 
			@outputs
		WHERE 
			[type] = 'WARNING'
		ORDER BY 
			output_id ASC;

		IF @PrintOnly = 1 BEGIN
			
			PRINT @subject;
			PRINT @message;

		  END
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @subject, 
				@body = @message;
		END;

	END;

	RETURN 0;
GO