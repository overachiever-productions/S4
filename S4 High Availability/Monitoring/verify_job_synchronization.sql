/*
	NOTES:
		- While 'Mirrored' Jobs should be any job where: 
				a) the database is mirrored/AG'd and 
				b) the Job.CategoryName = [A Mirrored DatabaseName], 
			Mirrored databases aren't, always, 100% mirrored. (They might be down, between mirroring sessions, or whatever.)
				As such, a Mirrored 'Job' (for the purposes of this script) is any Job where Job.CategoryName = [Name of a User Database]; 

	vNEXT:
		- Look at integrating the following script/logic/notes:
		-------------------------------------------------------------------------------------------------------------------------------------------------------------

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
	@IgnoredJobs				nvarchar(MAX)		= N'',
	@JobCategoryMapping			nvarchar(MAX)		= N'',					-- category-name: targetDbName, n2, n3, etc. 
	--@IgnoredJobCategories		nvarchar(MAX)		= 'IGNORED',			-- or maybe {IGNORED} as the actual name? 
	@MailProfileName			sysname				= N'General',	
	@OperatorName				sysname				= N'Alerts',	
	@PrintOnly					bit						= 0					-- output only to console - don't email alerts (for debugging/manual execution, etc.)
AS 
	SET NOCOUNT ON;

	-- {copyright}

	SET @IgnoredJobs = NULLIF(@IgnoredJobs, N'');
	SET @JobCategoryMapping = NULLIF(@JobCategoryMapping, N'');

	----------------------------------------------
	/* -- Determine which server to run checks on: */
	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;	

	---------------------------------------------
	/* -- Dependencies Validation: */
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
		/* -- S4-229: this (current) response is a hack - i.e., sending email/message DIRECTLY from this code-block violates DRY
		   --			and is only in place until dbo.verify_job_synchronization is rewritten to use a process bus. */
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

	/* ---------------------------------------------
	   -- processing */

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC sys.sp_executesql 
		N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', 
		N'@remoteName sysname OUTPUT', 
		@remoteName = @remoteServerName OUTPUT;

	/* -- start by loading a 'list' of all dbs that might be Mirrored or AG'd: */
	DECLARE @synchronizingDatabases table ( 
		server_name sysname, 
		sync_type sysname,
		[database_name] sysname, 
		[role] sysname
	);

	/* -- grab a list of all synchronizing LOCAL databases: */
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

	/* -- we also need a list of synchronizing/able databases on the 'secondary' server: */
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

	/* ----------------------------------------------
	   -- deserialize ignored jobs and mappedJobCategories: */
	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);
	
	CREATE TABLE #mappedCategories (
		row_id int NOT NULL, 
		category_name sysname NOT NULL,
		target_database sysname NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredJobs, N',', 1);

	IF @JobCategoryMapping IS NOT NULL BEGIN 
		INSERT INTO [#mappedCategories] (
			[row_id],
			[category_name],
			[target_database]
		)

		EXEC dbo.[shred_string] 
			@Input = @JobCategoryMapping, 
			@RowDelimiter = N',', 
			@ColumnDelimiter = N':';
	END;

	CREATE TABLE #Differences (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[job_name] nvarchar(100) NOT NULL, 
		[problem] sysname NOT NULL,
		[description] nvarchar(300) NOT NULL, 
		[detail] nvarchar(MAX) NULL
	);

	CREATE TABLE #LocalJobs (
		[job_id] uniqueidentifier, 
		[name] sysname NOT NULL, 
		[description] nvarchar(512) NULL, 
		[enabled] tinyint NOT NULL, 
		[owner_sid] varbinary(85) NOT NULL,
		[category_name] sysname NOT NULL,
		[start_step_id] int NOT NULL, 
		[notify_level_email] int NOT NULL, 
		[operator_name] sysname NOT NULL,
		[date_modified] datetime NOT NULL,
		[job_step_count] int NOT NULL, 
		[schedule_count] int NOT NULL,
		[mapped_category_name] sysname NULL,
	);

	CREATE TABLE #RemoteJobs (
		[job_id] uniqueidentifier, 
		[name] sysname NOT NULL, 
		[description] nvarchar(512) NULL, 
		[enabled] tinyint NOT NULL, 
		[owner_sid] varbinary(85) NOT NULL,
		[category_name] sysname NOT NULL,
		[start_step_id] int NOT NULL, 
		[notify_level_email] int NOT NULL, 
		[operator_name] sysname NOT NULL,
		[date_modified] datetime NOT NULL,
		[job_step_count] int NOT NULL, 
		[schedule_count] int NOT NULL,
		[mapped_category_name] sysname NULL,
	);

	INSERT INTO [#LocalJobs] (
		[job_id],
		[name],
		[description],
		[enabled],
		[owner_sid],
		[category_name],
		[start_step_id],
		[notify_level_email],
		[operator_name],
		[date_modified],
		[job_step_count],
		[schedule_count]
	)
	SELECT 
		sj.[job_id], 
		sj.[name], 
		sj.[description], 
		sj.[enabled], 
		sj.[owner_sid], 
		sc.[name] [category_name],
		sj.[start_step_id],
		sj.[notify_level_email], 
		ISNULL(so.[name], 'EMPTY') operator_name,
		[sj].[date_modified],
		(SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id) [job_step_count], 
		(SELECT COUNT(*) FROM msdb.dbo.[sysjobschedules] sjs WHERE sj.job_id = sjs.[job_id]) [schedule_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id;

	INSERT INTO [#RemoteJobs] (
		[job_id],
		[name],
		[description],
		[enabled],
		[owner_sid],
		[category_name],
		[start_step_id],
		[notify_level_email],
		[operator_name],
		[date_modified],
		[job_step_count],
		[schedule_count]
	)
	EXEC sp_executesql N'SELECT 
		sj.[job_id], 
		sj.[name], 
		sj.[description], 
		sj.[enabled], 
		sj.[owner_sid], 
		sc.[name] [category_name],
		sj.[start_step_id],
		sj.[notify_level_email], 
		ISNULL(so.[name], ''EMPTY'') operator_name,
		[sj].[date_modified],
		(SELECT COUNT(*) FROM PARTNER.msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id) [job_step_count], 
		(SELECT COUNT(*) FROM PARTNER.msdb.dbo.[sysjobschedules] sjs WHERE sj.job_id = sjs.[job_id]) [schedule_count]
	FROM 
		PARTNER.msdb.dbo.sysjobs sj
		LEFT OUTER JOIN PARTNER.msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id; ';

	/* Remove Ignored Jobs */ 
	DELETE x 
	FROM 
		[#LocalJobs] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE ignored.[name];
	
	DELETE x 
	FROM 
		[#RemoteJobs] x 
		INNER JOIN [#IgnoredJobs] ignored ON x.[name] LIKE [ignored].[name];

	/* Identify Jobs present on ONLY ONE server (and not the other): */
	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[name], 
		N'LOCAL_ONLY' [problem],
		CASE 
			WHEN ([category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE [server_name] = @localServerName)) THEN N'Batch job exists on [' + @localServerName + N'] only.'
			ELSE N'Server-Level job exists on [' + @localServerName + N'] only.'
		END [description]		
	FROM 
		[#LocalJobs] 
	WHERE 
		[name] NOT IN (SELECT [name] FROM [#RemoteJobs]);

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[name], 
		N'REMOTE_ONLY' [problem],
		CASE 
			WHEN ([category_name] IN (SELECT [database_name] FROM @synchronizingDatabases WHERE [server_name] = @remoteServerName)) THEN N'Batch job exists on [' + @remoteServerName + N'] only.'
			ELSE N'Server-Level job exists on [' + @remoteServerName + N'] only.'
		END [description]
	FROM 
		[#RemoteJobs] 
	WHERE 
		[name] NOT IN (SELECT [name] FROM [#LocalJobs]);

	/* Shred + align: */
	CREATE TABLE #PathAlignedDetails (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[job_name] sysname NOT NULL, 
		[path] sysname NOT NULL, 
		[local_value] nvarchar(512) NOT NULL, 
		[remote_value] nvarchar(512) NULL
	);

	WITH [serialized] AS ( 
		SELECT 
			[name], 
			(SELECT 
				[job_id],
				[name],
				ISNULL([description], N'') [description],
				[enabled],
				CONVERT(sysname, [owner_sid], 1) [owner_sid],
				[category_name],
				[start_step_id],
				[notify_level_email],
				[operator_name],
				[job_step_count],
				[schedule_count] 
			FROM [#LocalJobs] c2
			WHERE 
				[#LocalJobs].[name] = c2.[name]
			FOR XML RAW('x'), TYPE) [xml]
		FROM 
			[#LocalJobs]
	) 

	INSERT INTO [#PathAlignedDetails] (
		[job_name],
		[path],
		[local_value]
	)
	SELECT 
		s.[name] [job_name], 
		N'job.' + a.c.value(N'local-name(.)', 'nvarchar(512)') [path],
		a.c.value(N'.', 'sysname') [local_value]
	FROM 
		[serialized] s 
		CROSS APPLY s.[xml].nodes(N'x/@*') a(c);

	WITH [serialized] AS ( 
		SELECT 
			[name], 
			(SELECT 		
				[job_id],
				[name],
				ISNULL([description], N'') [description],
				[enabled],
				CONVERT(sysname, [owner_sid], 1) [owner_sid],
				[category_name],
				[start_step_id],
				[notify_level_email],
				[operator_name],
				[job_step_count],
				[schedule_count] 
			FROM [#RemoteJobs] c2
			WHERE 
				[#RemoteJobs].[name] = c2.[name]
			FOR XML RAW('x'), TYPE) [xml]
		FROM 
			[#RemoteJobs]
	), 
	[pathed] AS (
	SELECT 
			s.[name] [job_name], 
			N'job.' + a.c.value(N'local-name(.)', 'nvarchar(512)') [path],
			a.c.value(N'.', 'sysname') [remote_value]
		FROM 
			[serialized] s 
			CROSS APPLY s.[xml].nodes(N'x/@*') a(c)
	)

	UPDATE x 
	SET 
		x.[remote_value] = p.[remote_value]
	FROM 
		[#PathAlignedDetails] x 
		LEFT OUTER JOIN [pathed] p ON [x].[job_name] = [p].[job_name] AND x.[path] = p.[path];

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[job_name], 
		N'CORE_DIFFERENCES' [problem], 
		N'[' + [path] + N'] is different between servers.' [description]
	FROM 
		[#PathAlignedDetails]
	WHERE 
		[local_value] <> [remote_value]
		AND [path] NOT IN(N'job.job_id', N'job.enabled', N'job.job_step_count', N'job.schedule_count')  /* these paths are more complex - and checked distinctly/explicitly...  */
		AND [job_name] NOT IN (SELECT [job_name] FROM [#Differences] WHERE [problem] IN (N'LOCAL_ONLY', N'REMOTE_ONLY'));  /* No sense reporting on jobs that exist on only one box vs both...  */

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[job_name], 
		N'JOB_STEP_COUNT_DIFFERENCES' [problem], 
		N'Job Step Counts between servers are NOT the same.' [description]
	FROM 
		[#PathAlignedDetails]
	WHERE 
		[local_value] <> [remote_value]
		AND [path] = N'job.job_step_count'
		AND [job_name] NOT IN (SELECT [job_name] FROM [#Differences] WHERE [problem] IN (N'LOCAL_ONLY', N'REMOTE_ONLY'));  /* No sense reporting on jobs that exist on only one box vs both...  */

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[job_name], 
		N'JOB_STEP_COUNT_DIFFERENCES' [problem], 
		N'Schedule Counts between servers are NOT the same.' [description]
	FROM 
		[#PathAlignedDetails]
	WHERE 
		[local_value] <> [remote_value]
		AND [path] = N'job.schedule_count'
		AND [job_name] NOT IN (SELECT [job_name] FROM [#Differences] WHERE [problem] IN (N'LOCAL_ONLY', N'REMOTE_ONLY'));  /* No sense reporting on jobs that exist on only one box vs both...  */

	/* Check for Job-Step and Schedule Differences (but only on jobs where the counts (job-steps or schedules) are different) */
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

	/* vNEXT: Look at expanding these details via 'paths' as well, e.g., schedules.N.something for local vs remote and job_step.N.body_or_whatever (local vs remote) etc.*/
	DECLARE @jobName sysname; 
	DECLARE @localJobID uniqueidentifier, @remoteJobId uniqueidentifier;
	DECLARE [checker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[job_name] 
	FROM 
		[#PathAlignedDetails] 
	WHERE 
		[local_value] = [remote_value] AND [path] IN (N'job.job_step_count', N'job.schedule_count') 
	GROUP BY 
		[job_name];	
	
	OPEN [checker];
	FETCH NEXT FROM [checker] INTO @jobName;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
		SELECT 
			@localJobID = [local_value], 
			@remoteJobId = [remote_value]
		FROM 
			[#PathAlignedDetails]
		WHERE 
			[path] = N'job.job_id'
			AND [job_name] = @jobName;

		DELETE FROM #LocalJobSteps;
		DELETE FROM #RemoteJobSteps;

		INSERT INTO #LocalJobSteps (step_id, [checksum])
		SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM 
			msdb.dbo.sysjobsteps
		WHERE 
			job_id = @localJobID;

		INSERT INTO #RemoteJobSteps (step_id, [checksum])
		EXEC sys.sp_executesql N'SELECT 
			step_id, 
			CHECKSUM(step_name, subsystem, command, on_success_action, on_fail_action, [database_name]) [checksum]
		FROM 
			PARTNER.msdb.dbo.sysjobsteps
		WHERE 
			job_id = @remoteJobId;', 
		N'@remoteJobID uniqueidentifier', 
		@remoteJobId = @remoteJobId;

		/* vNEXT: account for proxies, logging, retry-counts, and all other job-step details... (vs just 'core' stuff I'm doing now) */
		INSERT INTO [#Differences] ([job_name],[problem],[description])
		SELECT 
			@jobName [job_name], 
			N'JOB_STEP_DIFFERENCES' [problem], 
			N'Job Step #' + CAST([ljs].[step_id] AS sysname) + ' is DIFFERENT between servers (step-name, subystem-type, target-database, success/failure action, or body).' [description]
		FROM 
			[#LocalJobSteps] ljs 
			INNER JOIN [#RemoteJobSteps] rjs ON [ljs].[step_id] = [rjs].[step_id] 
		WHERE 
			[ljs].[checksum] <> [rjs].[checksum];

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
		EXEC sys.sp_executesql N'SELECT 
			ss.name,
			CHECKSUM(ss.[enabled], ss.freq_type, ss.freq_interval, ss.freq_subday_type, ss.freq_subday_interval, ss.freq_relative_interval, 
				ss.freq_recurrence_factor, ss.active_start_date, ss.active_end_date, ss.active_start_time, ss.active_end_time) [checksum]
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE
			sjs.job_id = @remoteJobId;', 
		N'@remoteJobID uniqueidentifier', 
		@remoteJobId = @remoteJobId;

		INSERT INTO [#Differences] ([job_name],[problem],[description])
		SELECT 
			@jobName [job_name], 
			N'SCHEDULE_DIFFERENCES' [problem], 
			N'Schedule [' + [ljs].[schedule_name] + + N'] is DIFFERENT between servers.' [description]
		FROM 
			[#LocalJobSchedules] ljs	 
			INNER JOIN [#RemoteJobSchedules] rjs ON [ljs].[schedule_name] = [rjs].[schedule_name] 
		WHERE 
			ljs.[checksum] <> rjs.[checksum];

		FETCH NEXT FROM [checker] INTO @jobName;
	END;
	
	CLOSE [checker];
	DEALLOCATE [checker];
	
	/* Account for @JobCategoryMapping */
	UPDATE x 
		SET x.[mapped_category_name] = ISNULL(m.[target_database], x.[category_name])
	FROM 
		[#LocalJobs] x 
		LEFT OUTER JOIN [#mappedCategories] m ON x.[category_name] = m.[category_name];

	UPDATE x 
		SET x.[mapped_category_name] = ISNULL(m.[target_database], x.[category_name])
	FROM 
		[#RemoteJobs] x 
		LEFT OUTER JOIN [#mappedCategories] m ON x.[category_name] = m.[category_name];

	/* Check for batch-jobs disabled/enabled statuses need to be evaluated */
	WITH batch_jobs AS ( 
		/* NOTE: Explicitly IGNORING jobs only on one server or another at this point - those issues need to be fixed FIRST, then we can evaluate enabled/disabled logic as needed. */
		SELECT 
			[name],
			[enabled],
			[category_name],
			[mapped_category_name]
		FROM 
			[#LocalJobs]
		WHERE 
			[name] NOT IN (SELECT [job_name] FROM [#Differences] WHERE [problem] IN (N'LOCAL_ONLY', N'REMOTE_ONLY')) /* see notes below about this predicate being redundant */
			AND (
				[category_name] IN (SELECT [database_name] FROM @synchronizingDatabases)
				OR 
				[mapped_category_name] IN (SELECT [database_name] FROM @synchronizingDatabases)
				OR 
				(UPPER([category_name]) = N'DISABLED' OR UPPER([mapped_category_name]) = N'DISABLED')
			)
	), 
	enabled_states AS ( 
		SELECT 
			[job_name],
			[local_value],
			[remote_value] 
		FROM 
			[#PathAlignedDetails] 
		WHERE 
			[path] = N'job.enabled'
			AND [job_name] NOT IN (SELECT [job_name] FROM [#Differences] WHERE [problem] IN (N'LOCAL_ONLY', N'REMOTE_ONLY'))  /* this predicate is REDUNDANT. Leaving it in case initial/core logic change. */

	)
	SELECT 
		[j].[name] [job_name],
		[j].[category_name],
		[j].[mapped_category_name],
		[s].[local_value] [local_enabled],
		[s].[remote_value] [remote_enabled] 
	INTO 
		#batchJobEnabledStates
	FROM 
		batch_jobs j 
		LEFT OUTER JOIN [enabled_states] s ON j.[name] = s.[job_name];

	/* 3 scenarios for enabled/disabled problems: a) + b) incorrectly enabled/disabled on primary and/or secondary, 
		and c) disabled but not set category: disabled or d) category = disabled but jobs not disabled. sheesh */
	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[job_name], 
		N'DISABLED_ON_PRIMARY' [problem], 
		N'Batch-Job is DISABLED on PRIMARY server. *' [description]
	FROM 
		[#batchJobEnabledStates] 
	WHERE 
		(UPPER([category_name]) <> N'DISABLED' OR UPPER([mapped_category_name]) <>  N'DISABLED')
		AND [local_enabled] = 0;

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[job_name], 
		N'ENABLED_ON_SECONDARY' [problem], 
		N'Batch-Job is ENABLED on NON-PRIMARY server. *' [description]
	FROM 
		[#batchJobEnabledStates] 
	WHERE 
		(UPPER([category_name]) <> N'DISABLED' OR UPPER([mapped_category_name]) <>  N'DISABLED')
		AND [remote_enabled] = 1;

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[job_name], 
		N'ENABLED_WITH_CAT_DISABLED' [problem], 
		N'Job-Category is [Disabled] but Job is ENABLED. ' [description]
	FROM 
		[#batchJobEnabledStates] 
	WHERE 
		(UPPER([category_name]) = N'DISABLED' OR UPPER([mapped_category_name]) =  N'DISABLED')
		AND [local_enabled] = 1;

	/* Check for Server-Level Jobs with different enabled/disabled states between servers */
	WITH server_jobs AS ( 
		SELECT 
			[name], 
			[category_name], 
			[mapped_category_name]
		FROM 
			[#LocalJobs]
		WHERE 
			[name] NOT IN (SELECT [job_name] FROM [#batchJobEnabledStates])

		UNION 

		SELECT 
			[name], 
			[category_name], 
			[mapped_category_name]
		FROM 
			[#RemoteJobs]
		WHERE 
			[name] NOT IN (SELECT [job_name] FROM [#batchJobEnabledStates])

	), 
	enabled_states AS ( 
		SELECT 
			[job_name],
			[local_value] [local_enabled],
			[remote_value] [remote_enabled]
		FROM 
			[#PathAlignedDetails] 
		WHERE 
			[path] = N'job.enabled'
			AND [job_name] NOT IN (SELECT [job_name] FROM [#Differences] WHERE [problem] IN (N'LOCAL_ONLY', N'REMOTE_ONLY'))  /* this predicate is REDUNDANT. Leaving it in case initial/core logic change. */

	)

	INSERT INTO [#Differences] ([job_name],[problem],[description])
	SELECT 
		[s].[job_name],
		N'SERVERJOB_ENABLED_DISABLED' [problem], 
		N'Job-Enabled State is different between servers.' [description]
	FROM  
		[server_jobs] j 
		LEFT OUTER JOIN [enabled_states] s ON j.[name] = s.[job_name]
	WHERE 
		[s].[local_enabled] <> [s].[remote_enabled];


	IF(SELECT COUNT(*) FROM [#Differences]) > 0 BEGIN 

		DECLARE @subject nvarchar(200) = 'SQL Server Agent Job Synchronization Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = 'The following problems were detected with the following SQL Server Agent Jobs: '
		+ @crlf;

		DECLARE @description nvarchar(MAX);
		DECLARE @previousJobName sysname;
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[job_name],
			[description]
		FROM 
			[#Differences]
		ORDER BY 
			[job_name];		
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @jobName, @description;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
			IF @previousJobName IS NULL BEGIN
				SET @message = @message + @crlf + @tab + N'[' + @jobName + N'] ' + @crlf;
				SET @previousJobName = @jobName;
			END;

			IF @previousJobName <> @jobName BEGIN 
				SET @message = @message + @crlf + @tab + N'[' + @jobName + N'] ' + @crlf;
			END;
			
			SET @message = @message + @tab + @tab + N'- ' + @description + @crlf;

			SET @previousJobName = @jobName;
			FETCH NEXT FROM [walker] INTO @jobName, @description;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		IF EXISTS (SELECT NULL FROM [#Differences] WHERE [problem] IN (N'DISABLED_ON_PRIMARY', N'ENABLED_ON_SECONDARY')) BEGIN 
			SELECT @message += @crlf + N'* Batch-Jobs should be ENABLED on PRIMARY, and DISABLED on NON-PRIMARY.' + @crlf;
		END;

		SELECT @message += @crlf + N'NOTE: Jobs can be synchronized by scripting them on the Primary and running scripts on the Secondary.'
			+ @crlf + @tab + N'To Script Multiple Jobs at once: SSMS > SQL Server Agent Jobs > F7 -> then shift/ctrl + click to select multiple jobs simultaneously.';

		IF @PrintOnly = 1 BEGIN 
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;
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