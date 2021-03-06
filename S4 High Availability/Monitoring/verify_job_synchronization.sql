/*

	DEPENDENCIES:
		- PARTNER (linked server to Mirroring 'partner')
		- admindb.dbo.is_primary_database()

	NOTES:
		- While 'Mirrored' Jobs should be any job where: 
				a) the database is mirrored/AG'd and 
				b) the Job.CategoryName = [A Mirrored DatabaseName], 
			Mirrored databases aren't, always, 100% mirrored. (They might be down, between mirroring sessions, or whatever.)
				As such, a Mirrored 'Job' (for the purposes of this script) is any Job where Job.CategoryName = [Name of a User Database]; 

	OVERVIEW:
		This sproc is made up of the following, main, components/operations: 
			A. Initialization.
			B. Checkup on Server-Level Jobs. 
			C. Checkup on any/all jobs on the server where enabled/disabled statuses do not match Job.CategoryName.
			D. Checkup on Jobs for synchronized databases (i.e., where Job.CategoryName = NameOfMirroredDatabase (a convention)). 
			E. Report on any/all discrepencies (either via email or to 'console' only - if @PrintOnly = 1). 

	vNEXT:
		- Look at integrating the following script/logic/notes:
-------------------------------------------------------------------------------------------------------------------------------------------------------------

				-- TODO: standardize this into a script/sproc/whatever... 
				--		and 
				--			a) add it to checks.   (I'm pretty sure i'm already tackling this logic - but... this seems like a way simple way to do this..., so... see if this would make more sense than existing check logic?)
				--			b) apply a similar/tweaked version to ... AG monitoring/etc. 

				-- TODO:
				--		have ANOTHER query that ... reports on JOBs WHERE:
				--				a) a mirrored database's name is in the string of the job-name (i.e., WHERE job_name LIKE '%db_name_for_each_mirrored_database%' - so... a JOIN instead of a WHERE...)
				--				b) the body of the job says: USE [mirrored_db_name_here]
				--				b.2( the ... 'default database' is also a mirrored db... 
				--				c) the CATEGORY of the JOB is not, then = db_name... 
				--			as a way of trying to find/report-on any jobs that might be dependent upon mirrored dbs... but which aren't 'conventioned' to the right category name... 
				--					provide an option for job-names to SKIP/IGNORE... 


				WITH mirrored AS ( 
					SELECT 
						d.name [db_name],
						dm.mirroring_role_desc [role], 
						dm.mirroring_state_desc [state]
					FROM sys.database_mirroring dm
					INNER JOIN sys.databases d ON dm.database_id = d.database_id
					LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
					WHERE 
						dm.mirroring_guid IS NOT NULL
				), 
				jobs AS ( 

					SELECT 
						j.name [job_name], 
						c.name [category],
						j.[enabled] 
					FROM 
						msdb..sysjobs j
						INNER JOIN msdb..syscategories c ON j.category_id = c.category_id
				),
				core AS (

					SELECT 
						j.job_name, 
						j.category, 
						j.[enabled] [is_enabled],
						CASE WHEN j.category = m.[db_name] THEN 1 ELSE 0 END [is_mirrored], 
						CASE WHEN m.[role] = 'PRINCIPAL' THEN 1 ELSE 0 END [is_primary], 
						CASE WHEN (j.category <> 'Disabled' AND m.[db_name] = j.category) THEN 1 ELSE 0 END [should_be_enabled]
					FROM 
						jobs j 
						LEFT OUTER JOIN mirrored m ON j.category = m.db_name
				)

				SELECT 
					*
				FROM 
					core 
				WHERE 
					is_enabled <> should_be_enabled
					AND (is_mirrored = 1 AND is_primary = 1)
				ORDER BY 
					category;
-------------------------------------------------------------------------------------------------------------------------------------------------------------


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_job_synchronization','P') IS NOT NULL
	DROP PROC dbo.verify_job_synchronization;
GO

CREATE PROC [dbo].[verify_job_synchronization]
	@IgnoredJobs			nvarchar(MAX)		= '',
	@MailProfileName		sysname				= N'General',	
	@OperatorName			sysname				= N'Alerts',	
	@PrintOnly				bit						= 0					-- output only to console - don't email alerts (for debugging/manual execution, etc.)
AS 
	SET NOCOUNT ON;

	-- {copyright}

	----------------------------------------------
	-- Determine which server to run checks on:
	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;	

	---------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END;

	EXEC @return = dbo.verify_partner 
		@Error = @returnMessage OUTPUT; 

	IF @return <> 0 BEGIN 
		-- S4-229: this (current) response is a hack - i.e., sending email/message DIRECTLY from this code-block violates DRY
		--			and is only in place until dbo.verify_job_synchronization is rewritten to use a process bus.
		IF @PrintOnly = 1 BEGIN 
			PRINT 'PARTNER is disconnected/non-accessible. Terminating early. Connection Details/Error:';
			PRINT '     ' + @returnMessage;
		  END;
		ELSE BEGIN 
			DECLARE @hackSubject nvarchar(200), @hackMessage nvarchar(MAX);
			SELECT 
				@hackSubject = N'PARTNER server is down/non-accessible.', 
				@hackMessage = N'Job Synchronization Checks can not continue as PARTNER server is down/non-accessible. Connection Error Details: ' + NCHAR(13) + NCHAR(10) + @returnMessage; 

			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @hackSubject,
				@body = @hackMessage;
		END;

		RETURN 0;
	END;

	---------------------------------------------
	-- processing

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;


	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		server_name sysname, 
		sync_type sysname,
		[database_name] sysname, 
		[role] sysname
	);

	-- grab a list of all synchronizing LOCAL databases:
	INSERT INTO @synchronizingDatabases (
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	)
	SELECT 
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	FROM 
		dbo.list_synchronizing_databases(NULL, 0);

	-- we also need a list of synchronizing/able databases on the 'secondary' server:
	DECLARE @delayedSyntaxCheckHack nvarchar(max) = N'
		SELECT 
			[server_name],
			[sync_type],
			[database_name], 
			[role]
		FROM 
			OPENQUERY([PARTNER], ''SELECT * FROM [admindb].dbo.[list_synchronizing_databases](NULL, 0)'');';

	INSERT INTO @synchronizingDatabases (
		[server_name],
		[sync_type],
		[database_name], 
		[role]
	)
	EXEC sp_executesql @delayedSyntaxCheckHack;	

	----------------------------------------------
	-- establish which jobs to ignore (if any):
	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredJobs, N',', 1);

	----------------------------------------------
	-- create a container for output/differences. 
	CREATE TABLE #Divergence (
		row_id int IDENTITY(1,1) NOT NULL,
		[name] nvarchar(100) NOT NULL, 
		[description] nvarchar(300) NOT NULL
	);

	---------------------------------------------------------------------------------------------
	-- Process server-level jobs (jobs that aren't mapped to a Mirrored/AG'd database). 
	--		here we're just looking for differences in enabled states and/or differences between the job definitions/details from one server to the next. 
	CREATE TABLE #LocalJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	CREATE TABLE #RemoteJobs (
		job_id uniqueidentifier, 
		[name] sysname, 
		[enabled] tinyint, 
		[description] nvarchar(512), 
		start_step_id int, 
		owner_sid varbinary(85),
		notify_level_email int, 
		operator_name sysname,
		category_name sysname,
		job_step_count int
	);

	CREATE TABLE #DisableConfusedJobs (
		[name] sysname NOT NULL
	);

	-- Load Details: 
	INSERT INTO #LocalJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.[name], 'local') operator_name,
		ISNULL(sc.[name], 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id;

	INSERT INTO #RemoteJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	EXEC master.sys.sp_executesql N'SELECT 
	sj.job_id, 
	sj.[name], 
	sj.[enabled], 
	sj.[description], 
	sj.start_step_id,
	sj.owner_sid, 
	sj.notify_level_email, 
	ISNULL(so.name, ''local'') operator_name,
	ISNULL(sc.name, ''local'') [category_name],
	ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
FROM 
	PARTNER.msdb.dbo.sysjobs sj
	LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
	LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id';

	-- Remove Ignored Jobs: 
	DELETE x 
	FROM 
		[#LocalJobs] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE ignored.[name];
	
	DELETE x 
	FROM 
		[#RemoteJobs] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name];

	----------------------------------------------
	-- Process high-level details about each job
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		[name],
		N'Server-Level job exists on ' + @localServerName + N' only.'
	FROM 
		#LocalJobs 
	WHERE
		[name] NOT IN (SELECT [name] FROM #RemoteJobs)
		AND [category_name] NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName);

	INSERT INTO #Divergence ([name], [description])
	SELECT 
		[name], 
		N'Server-Level job exists on ' + @remoteServerName + N' only.'
	FROM 
		#RemoteJobs
	WHERE
		[name] NOT IN (SELECT [name] FROM #LocalJobs)
		AND [category_name] NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName);

	-- account for 3x scenarios for 'Disabled' (job category/convention) jobs: a) category set as disabled on ONE server but not the other, b) set to disabled (both servers) but JOB is enabled on one or both servers 
	INSERT INTO #Divergence ([name], [description])
	OUTPUT 
		[Inserted].[name] INTO [#DisableConfusedJobs]
	SELECT 
		lj.[name], 
		'Job-Mapping Problem. The Job ' + lj.[name] + N' exists on both servers - but has a job-category of [' + lj.[category_name] + N'] on ' + @localServerName + N' and a job-category of [' + rj.[category_name] + N'] on ' + @remoteServerName + N'.'
	FROM 
		[#LocalJobs] lj 
		INNER JOIN [#RemoteJobs] rj ON lj.[name] = rj.[name] 
	WHERE 
		(UPPER(lj.[category_name]) <> UPPER(rj.[category_name]))
		AND (
			UPPER(lj.[category_name]) = N'DISABLED' 
			OR 
			UPPER(rj.[category_name]) = N'DISABLED'
		);

	WITH conjoined AS ( 
		SELECT 
			@localServerName [server_name], 
			[name] [job_name]
		FROM 
			[#LocalJobs] 
		WHERE 
			UPPER([category_name]) = N'DISABLED' AND [enabled] = 1

		UNION 

		SELECT 
			@remoteServerName [server_name], 
			[name] [job_name]
		FROM 
			[#RemoteJobs] 
		WHERE 
			UPPER([category_name]) = N'DISABLED' AND [enabled] = 1
	) 
		
	INSERT INTO #Divergence ([name], [description])
	OUTPUT 
		[Inserted].[name] INTO [#DisableConfusedJobs]
	SELECT 
		[job_name], 
		N'Job [' + [job_name] + N'] on server ' + [server_name] + N' has a job-category of ''Disabled'', but the job is currently ENABLED.'
	FROM 
		[conjoined] 
	WHERE 
		[job_name] NOT IN (SELECT job_name FROM [#DisableConfusedJobs]);

	-- account for any job differences (not already accounted for)
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		lj.[name], 
		-- TODO: create GUIDANCE that covers how to use dbo.compare_jobs for this exact job.
		N'Differences between Server-Level job details between servers (owner, enabled, category name, job-steps count, start-step, notification, etc).'
	FROM 
		#LocalJobs lj
		INNER JOIN #RemoteJobs rj ON rj.[name] = lj.[name]
	WHERE
		lj.[name] NOT IN (SELECT [name] FROM [#DisableConfusedJobs])
		AND lj.category_name NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName) 
		AND rj.category_name NOT IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName)
		AND 
		(
			lj.[enabled] <> rj.[enabled]
			OR lj.[description] <> rj.[description]
			OR lj.start_step_id <> rj.start_step_id
			OR lj.owner_sid <> rj.owner_sid
			OR lj.notify_level_email <> rj.notify_level_email
			OR lj.operator_name <> rj.operator_name
			OR lj.job_step_count <> rj.job_step_count
			OR lj.category_name <> rj.category_name
		);



	----------------------------------------------
	-- now check the job steps/schedules/etc. 
	CREATE TABLE #LocalJobSteps (
		step_id int, 
		[checksum] int
	);

	CREATE TABLE #RemoteJobSteps (
		step_id int, 
		[checksum] int
	);

	CREATE TABLE #LocalJobSchedules (
		schedule_name sysname, 
		[checksum] int
	);

	CREATE TABLE #RemoteJobSchedules (
		schedule_name sysname, 
		[checksum] int
	);

	DECLARE server_level_checker CURSOR LOCAL FAST_FORWARD FOR
	SELECT 
		[local].job_id local_job_id, 
		[remote].job_id remote_job_id, 
		[local].name 
	FROM 
		#LocalJobs [local]
		INNER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name];

	DECLARE @localJobID uniqueidentifier, @remoteJobId uniqueidentifier, @jobName sysname;
	DECLARE @localCount int, @remoteCount int;

	OPEN server_level_checker;
	FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
	
		-- check jobsteps first:
		DELETE FROM #LocalJobSteps;
		DELETE FROM #RemoteJobSteps;

		INSERT INTO #LocalJobSteps (step_id, [checksum])
		SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM msdb.dbo.sysjobsteps
		WHERE job_id = @localJobID;

		INSERT INTO #RemoteJobSteps (step_id, [checksum])
		EXEC master.sys.sp_executesql N'SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM PARTNER.msdb.dbo.sysjobsteps
		WHERE job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

		IF @localCount <> @remoteCount
			INSERT INTO #Divergence ([name], [description]) 
			VALUES (
				@jobName, 
				N'Job Step Counts between servers are NOT the same.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				@jobName, 
				N'Job Step details between servers are NOT the same.'
			FROM 
				#LocalJobSteps ljs 
				INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
			WHERE	
				ljs.[checksum] <> rjs.[checksum];
		END;

		-- Now Check Schedules:
		DELETE FROM #LocalJobSchedules;
		DELETE FROM #RemoteJobSchedules;

		INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
		SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			msdb.dbo.sysjobschedules sjs
			INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @localJobID;

		INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
		EXEC master.sys.sp_executesql N'SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

		SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
		SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

		IF @localCount <> @remoteCount
			INSERT INTO #Divergence ([name], [description]) 
			VALUES (
				@jobName, 
				N'Job Schedule Counts between servers are different.'
			);
		ELSE BEGIN 
			INSERT INTO #Divergence ([name], [description])
			SELECT
				@jobName, 
				N'Job Schedule Details between servers are different.'
			FROM 
				#LocalJobSchedules ljs
				INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
			WHERE 
				ljs.[checksum] <> rjs.[checksum];

		END;

		FETCH NEXT FROM server_level_checker INTO @localJobID, @remoteJobId, @jobName;
	END;

	CLOSE server_level_checker;
	DEALLOCATE server_level_checker;

	---------------------------------------------------------------------------------------------
	-- Process Batch-Jobs. 

	-- Check on job details for batch-jobs:
	TRUNCATE TABLE #LocalJobs;
	TRUNCATE TABLE #RemoteJobs;

	DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
	SELECT DISTINCT 
		[database_name]
	FROM 
		@synchronizingDatabases
	ORDER BY 
		[database_name];

	DECLARE @currentMirroredDB sysname; 

	OPEN looper;
	FETCH NEXT FROM looper INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		TRUNCATE TABLE #LocalJobs;
		TRUNCATE TABLE #RemoteJobs;
		
		INSERT INTO #LocalJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		SELECT 
			sj.job_id, 
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.[name], 'local') operator_name,
			ISNULL(sc.[name], 'local') [category_name],
			ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			msdb.dbo.sysjobs sj
			LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.[name]) = UPPER(@currentMirroredDB);

		INSERT INTO #RemoteJobs (job_id, [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		EXEC master.sys.sp_executesql N'SELECT 
			sj.job_id, 
			sj.[name], 
			sj.[enabled], 
			sj.[description], 
			sj.start_step_id,
			sj.owner_sid, 
			sj.notify_level_email, 
			ISNULL(so.[name], ''local'') operator_name,
			ISNULL(sc.[name], ''local'') [category_name],
			ISNULL((SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
			LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE
			UPPER(sc.[name]) = UPPER(@currentMirroredDB);', N'@currentMirroredDB sysname', @currentMirroredDB = @currentMirroredDB;

		-- Remove Ignored Jobs: 
		DELETE x 
		FROM 
			[#LocalJobs] x 
			INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE ignored.[name];
	
		DELETE x 
		FROM 
			[#RemoteJobs] x 
			INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name];

		DELETE [#LocalJobs] WHERE [name] IN (SELECT [name] FROM [#DisableConfusedJobs]);
		DELETE [#RemoteJobs] WHERE [name] IN (SELECT [name] FROM [#DisableConfusedJobs]);

		------------------------------------------
		-- Now start comparing differences: 

		-- local  only:
-- TODO: create separate checks/messages for jobs existing only on one server or the other AND the whole 'OR is disabled' on one server or the other). 
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[local].[name], 
			N'Batch-Job for database [' + @currentMirroredDB + N'] exists on ' + @localServerName + N' only.'
		FROM 
			#LocalJobs [local]
			LEFT OUTER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name]
		WHERE 
			[remote].[name] IS NULL;

		-- remote only:
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[remote].[name], 
			N'Batch-Job for database [' + @currentMirroredDB + N'] exists on ' + @remoteServerName + N' only.'
		FROM 
			#RemoteJobs [remote]
			LEFT OUTER JOIN #LocalJobs [local] ON [remote].[name] = [local].[name]
		WHERE 
			[local].[name] IS NULL;

		-- differences:
		INSERT INTO #Divergence ([name], [description])
		SELECT 
			[local].[name], 
			N'Batch-Job for database [' + @currentMirroredDB + N'] is different between servers (owner, start-step, notification, etc).'
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [remote].[name] = [local].[name]
		WHERE
			[local].start_step_id <> [remote].start_step_id
			OR [local].owner_sid <> [remote].owner_sid
			OR [local].notify_level_email <> [remote].notify_level_email
			OR [local].operator_name <> [remote].operator_name
			OR [local].job_step_count <> [remote].job_step_count
			OR [local].category_name <> [remote].category_name;
		
		-- Process Batch-Job enabled states. There are three possible scenarios or situations to be aware of: 
		--		a) job.categoryname = '[a synchronizing db name] AND job.enabled = 0 on the PRIMARY (which it shouldn't be, because unless category is set to disabled, this job will be re-enabled post-failover). 
		--		b) job.categoryname = 'DISABLED' on the SECONDARY and job.enabled = 1... which is bad. Shouldn't be that way. 
		--		c) job.categoryname = '[a synchronizing db name]' and job.enabled != to what should be set for the current role (i.e., enabled on PRIMARY and disabled on SECONDARY). 
		--			only local variant of scenario c = scenario a, and the remote/partner variant of c = scenario b. 
		IF (SELECT dbo.is_primary_database(@currentMirroredDB)) = 1 BEGIN 
			-- report on any batch jobs that are disabled on the primary:
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is disabled on ' + @localServerName + N' (PRIMARY). Following a failover, this job will be re-enabled on the secondary. To prevent job from being re-enabled following failovers, set job category to ''Disabled''.'
			FROM 
				#LocalJobs
			WHERE
				[enabled] = 0 
				AND [category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName);
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is enabled on ' + @remoteServerName + N' (SECONDARY). Batch-Jobs (Jobs WHERE Job.CategoryName = NameOfASynchronizedDatabase), should be disabled on the SECONDARY and enabled on the PRIMARY.'
			FROM 
				#RemoteJobs
			WHERE
				[enabled] = 1 
				AND category_name IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName);
		  END 
		ELSE BEGIN -- otherwise, simply 'flip' the logic:
			-- report on any mirroring jobs that are disabled on the primary:
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is disabled on ' + @remoteServerName + N' (PRIMARY). Following a failover, this job will be re-enabled on the secondary. To prevent job from being re-enabled following failovers, set job category to ''Disabled''.'
			FROM 
				#RemoteJobs
			WHERE
				[enabled] = 0 
				AND [category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @remoteServerName); 		
		
			-- report on ANY mirroring jobs that are enabled on the secondary. 
			INSERT INTO #Divergence ([name], [description])
			SELECT 
				[name], 
				N'Batch-Job is enabled on ' + @localServerName + N' (SECONDARY). Batch-Jobs (Jobs WHERE Job.CategoryName = NameOfASynchronizedDatabase), should be disabled on the SECONDARY and enabled on the PRIMARY.'
			FROM 
				#LocalJobs
			WHERE
				[enabled] = 1 
				AND category_name IN (SELECT [database_name] FROM @synchronizingDatabases WHERE server_name = @localServerName); 
		END

		---------------
		-- job-steps processing:
		TRUNCATE TABLE #LocalJobSteps;
		TRUNCATE TABLE #RemoteJobSteps;
		TRUNCATE TABLE #LocalJobSchedules;
		TRUNCATE TABLE #RemoteJobSchedules;

		DECLARE checker CURSOR LOCAL FAST_FORWARD FOR
		SELECT 
			[local].job_id local_job_id, 
			[remote].job_id remote_job_id, 
			[local].[name] 
		FROM 
			#LocalJobs [local]
			INNER JOIN #RemoteJobs [remote] ON [local].[name] = [remote].[name];

		OPEN checker;
		FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;

		WHILE @@FETCH_STATUS = 0 BEGIN 
	
			-- check jobsteps first:
			DELETE FROM #LocalJobSteps;
			DELETE FROM #RemoteJobSteps;

			INSERT INTO #LocalJobSteps (step_id, [checksum])
			SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [detail]
			FROM msdb.dbo.sysjobsteps
			WHERE job_id = @localJobID;

			INSERT INTO #RemoteJobSteps (step_id, [checksum])
			EXEC master.sys.sp_executesql N'SELECT 
				step_id, 
				CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [detail]
			FROM PARTNER.msdb.dbo.sysjobsteps
			WHERE job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSteps;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSteps;

			IF @localCount <> @remoteCount
				INSERT INTO #Divergence ([name], [description]) 
				VALUES (
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Step Counts between servers are NOT the same.'
				);
			ELSE BEGIN 
				INSERT INTO #Divergence
				SELECT 
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Step details between servers are NOT the same.'
				FROM 
					#LocalJobSteps ljs 
					INNER JOIN #RemoteJobSteps rjs ON rjs.step_id = ljs.step_id
				WHERE	
					ljs.[checksum] <> rjs.[checksum];
			END;

			-- Now Check Schedules:
			DELETE FROM #LocalJobSchedules;
			DELETE FROM #RemoteJobSchedules;

			INSERT INTO #LocalJobSchedules (schedule_name, [checksum])
			SELECT 
				ss.name,
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				msdb.dbo.sysjobschedules sjs
				INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @localJobID;


			INSERT INTO #RemoteJobSchedules (schedule_name, [checksum])
			EXEC master.sys.sp_executesql N'SELECT 
				ss.[name],
				CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
					ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_date, ss.active_end_time) [details]
			FROM 
				PARTNER.msdb.dbo.sysjobschedules sjs
				INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE
				sjs.job_id = @remoteJobId;', N'@remoteJobID uniqueidentifier', @remoteJobId = @remoteJobId;

			SELECT @localCount = COUNT(*) FROM #LocalJobSchedules;
			SELECT @remoteCount = COUNT(*) FROM #RemoteJobSchedules;

			IF @localCount <> @remoteCount
				INSERT INTO #Divergence (name, [description])
				VALUES (
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Schedule Counts between servers are different.'
				);
			ELSE BEGIN 
				INSERT INTO #Divergence (name, [description])
				SELECT
					@jobName + N' (for database ' + @currentMirroredDB + N')', 
					N'Job Schedule Details between servers are different.'
				FROM 
					#LocalJobSchedules ljs
					INNER JOIN #RemoteJobSchedules rjs ON rjs.schedule_name = ljs.schedule_name
				WHERE 
					ljs.[checksum] <> rjs.[checksum];

			END;

			FETCH NEXT FROM checker INTO @localJobID, @remoteJobId, @jobName;
		END;

		CLOSE checker;
		DEALLOCATE checker;

		---------------

		FETCH NEXT FROM looper INTO @currentMirroredDB;
	END 

	CLOSE looper;
	DEALLOCATE looper;

	---------------------------------------------------------------------------------------------
	-- X) Report on any problems or discrepencies:
	DELETE x 
	FROM 
		[#Divergence] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name]
	WHERE 
		[ignored].[name] IS NOT NULL;

	IF(SELECT COUNT(*) FROM #Divergence) > 0 BEGIN 

		DECLARE @subject nvarchar(200) = 'SQL Server Agent Job Synchronization Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = 'Problems detected with the following SQL Server Agent Jobs: '
		+ @crlf;

		SELECT 
			@message = @message + @tab + N'- ' + name + N' -> ' + [description] + @crlf
		FROM 
			#Divergence
		ORDER BY 
			row_id;

		SELECT @message += @crlf + @tab + N'NOTE: Jobs can be synchronized by scripting them on the Primary and running scripts on the Secondary.'
			+ @crlf + @tab + @tab + N'To Script Multiple Jobs at once: SSMS > SQL Server Agent Jobs > F7 -> then shift/ctrl + click to select multiple jobs simultaneously.';

		SELECT @message += @crlf + @tab + N'NOTE: If a Job is assigned to a Mirrored DB (Job Category Name) on ONE server but not the other, it will likely '
			+ @crlf + @tab + @tab + N'show up 2x in the list of problems - once as a Server-Level job on one Server only, and once as a Mirrored-DB Job on the other server.';

		IF @PrintOnly = 1 BEGIN 
			-- just Print out details:
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;

		  END
		ELSE BEGIN
			-- send a message:
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject,
				@body = @message;
		END;
	END;

	DROP TABLE #LocalJobs;
	DROP TABLE #RemoteJobs;
	DROP TABLE #Divergence;
	DROP TABLE #LocalJobSteps;
	DROP TABLE #RemoteJobSteps;
	DROP TABLE #LocalJobSchedules;
	DROP TABLE #RemoteJobSchedules;
	DROP TABLE #IgnoredJobs;
	DROP TABLE [#DisableConfusedJobs];

	RETURN 0;
GO