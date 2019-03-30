

/*

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.compare_jobs','P') IS NOT NULL
	DROP PROC dbo.compare_jobs;
GO

CREATE PROC dbo.compare_jobs 
	@TargetJobName			sysname = NULL, 
	@IgnoredJobs			nvarchar(MAX) = NULL,			-- technically, should throw an error if this is specified AND @TargetJobName is ALSO specified, but... instead, will just ignore '@ignored' if a specific job is specified. 
	@IgnoreEnabledState		bit = 0
AS
	SET NOCOUNT ON; 
	
	-- {copyright}

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	IF NULLIF(@TargetJobName,N'') IS NOT NULL BEGIN -- the request is for DETAILS about a specific job. 


		-- Make sure Job exists on Local and Remote: 
		CREATE TABLE #LocalJob (
			job_id uniqueidentifier, 
			[name] sysname
		);

		CREATE TABLE #RemoteJob (
			job_id uniqueidentifier, 
			[name] sysname
		);

		INSERT INTO #LocalJob (job_id, [name])
		SELECT 
			sj.job_id, 
			sj.[name]
		FROM 
			msdb.dbo.sysjobs sj
		WHERE
			sj.[name] = @TargetJobName;

		INSERT INTO #RemoteJob (job_id, [name])
		EXEC master.sys.sp_executesql N'SELECT 
			sj.job_id, 
			sj.[name]
		FROM 
			PARTNER.msdb.dbo.sysjobs sj
		WHERE
			sj.[name] = @TargetJobName;', N'@TargetJobName sysname', @TargetJobName = @TargetJobName;

		IF NOT EXISTS (SELECT NULL FROM #LocalJob lj INNER JOIN #RemoteJob rj ON rj.[name] = lj.name) BEGIN
			RAISERROR('Job specified by @TargetJobName does NOT exist on BOTH servers.', 16, 1);
			RETURN -2;
		END


		DECLARE @localJobId uniqueidentifier;
		DECLARE @remoteJobId uniqueidentifier;

		SELECT @localJobId = job_id FROM #LocalJob WHERE [name] = @TargetJobName;
		SELECT @remoteJobId = job_id FROM #RemoteJob WHERE [name] = @TargetJobName;

		DECLARE @remoteJob table (
			[server] sysname NULL,
			[name] sysname NOT NULL,
			[enabled] tinyint NOT NULL,
			[description] nvarchar(512) NULL,
			[start_step_id] int NOT NULL,
			[owner_sid] varbinary(85) NOT NULL,
			[notify_level_email] int NOT NULL,
			[operator_name] sysname NOT NULL,
			[category_name] sysname NOT NULL,
			[job_step_count] int NOT NULL
		);

		INSERT INTO @remoteJob ([server], [name], [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
		EXECUTE master.sys.sp_executesql N'SELECT 
			@remoteServerName [server],
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
			LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
		WHERE 
			sj.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;


		-- Output top-level job details:
		WITH jobs AS ( 
			SELECT 
				@localServerName [server],
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
				sj.job_id = @localJobId

			UNION 

			SELECT 
				[server] COLLATE SQL_Latin1_General_CP1_CI_AS,
                [name] COLLATE SQL_Latin1_General_CP1_CI_AS,
                [enabled],
                [description] COLLATE SQL_Latin1_General_CP1_CI_AS,
                start_step_id,
                owner_sid,
                notify_level_email,
                operator_name COLLATE SQL_Latin1_General_CP1_CI_AS,
                category_name COLLATE SQL_Latin1_General_CP1_CI_AS,
                job_step_count
			FROM 
				@remoteJob
		)

		SELECT 
			'JOB' [type], 
			[server],
			[name],
			[enabled],
			[description],
			start_step_id,
			owner_sid,
			notify_level_email,
			operator_name,
			category_name,
			job_step_count
		FROM 
			jobs 
		ORDER BY 
			[name], [server];


		DECLARE @remoteJobSteps table (
			[step_id] int NOT NULL,
			[server] sysname NULL,
			[step_name] sysname NOT NULL,
			[subsystem] nvarchar(40) NOT NULL,
			[command] nvarchar(max) NULL,
			[on_success_action] tinyint NOT NULL,
			[on_fail_action] tinyint NOT NULL,
			[database_name] sysname NULL
		);

		INSERT INTO @remoteJobSteps ([step_id], [server], [step_name], [subsystem], [command], [on_success_action], [on_fail_action], [database_name])
		EXEC master.sys.sp_executesql N'SELECT 
			step_id, 
			@remoteServerName [server],
			step_name, 
			subsystem, 
			command, 
			on_success_action, 
			on_fail_action, 
			[database_name]
		FROM 
			PARTNER.msdb.dbo.sysjobsteps r
		WHERE 
			r.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;

		-- Job Steps: 
		WITH steps AS ( 
			SELECT 
				step_id, 
				@localServerName [server],
				step_name COLLATE Latin1_General_BIN [step_name], 
				subsystem COLLATE Latin1_General_BIN [subsystem], 
				command COLLATE Latin1_General_BIN [command], 
				on_success_action, 
				on_fail_action, 
				[database_name] COLLATE Latin1_General_BIN [database_name]
			FROM 
				msdb.dbo.sysjobsteps l
			WHERE 
				l.job_id = @localJobId

			UNION 

			SELECT 
				[step_id], 
				[server], 
				[step_name], 
				[subsystem], 
				[command], 
				[on_success_action], 
				[on_fail_action], 
				[database_name]
			FROM 
				@remoteJobSteps
		)

		SELECT 
			'JOB-STEP' [type],
			step_id, 
			[server],
			step_name, 
			subsystem, 
			command, 
			on_success_action, 
			on_fail_action, 
			[database_name]			
		FROM 
			steps
		ORDER BY 
			step_id, [server];


		DECLARE @remoteJobSchedules table (
			[server] sysname NULL,
			[name] sysname NOT NULL,
			[enabled] int NOT NULL,
			[freq_type] int NOT NULL,
			[freq_interval] int NOT NULL,
			[freq_subday_type] int NOT NULL,
			[freq_subday_interval] int NOT NULL,
			[freq_relative_interval] int NOT NULL,
			[freq_recurrence_factor] int NOT NULL,
			[active_start_date] int NOT NULL,
			[active_end_date] int NOT NULL,
			[active_start_time] int NOT NULL,
			[active_end_time] int NOT NULL
		);

		INSERT INTO @remoteJobSchedules ([server], [name], [enabled], [freq_type], [freq_interval], [freq_subday_type], [freq_subday_interval], [freq_relative_interval], [freq_recurrence_factor], [active_start_date], [active_end_date], [active_start_time], [active_end_time])
		EXEC master.sys.sp_executesql N'SELECT 
			@remoteServerName [server],
			ss.name,
			ss.[enabled], 
			ss.freq_type, 
			ss.freq_interval, 
			ss.freq_subday_type, 
			ss.freq_subday_interval, 
			ss.freq_relative_interval, 
			ss.freq_recurrence_factor, 
			ss.active_start_date, 
			ss.active_end_date,
			ss.active_start_time,
			ss.active_end_time
		FROM 
			PARTNER.msdb.dbo.sysjobschedules sjs
			INNER JOIN PARTNER.msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
		WHERE 
			sjs.job_id = @remoteJobId;', N'@remoteServerName sysname, @remoteJobID uniqueidentifier', @remoteServerName = @remoteServerName, @remoteJobId = @remoteJobId;	

		WITH schedules AS (

			SELECT 
				@localServerName [server],
				ss.[name] COLLATE Latin1_General_BIN [name],
				ss.[enabled], 
				ss.freq_type, 
				ss.freq_interval, 
				ss.freq_subday_type, 
				ss.freq_subday_interval, 
				ss.freq_relative_interval, 
				ss.freq_recurrence_factor, 
				ss.active_start_date, 
				ss.active_end_date, 
				ss.active_start_time,
				ss.active_end_time
			FROM 
				msdb.dbo.sysjobschedules sjs
				INNER JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = sjs.schedule_id
			WHERE 
				sjs.job_id = @localJobId

			UNION

			SELECT 
				[server],
                [name],
                [enabled],
                [freq_type],
                [freq_interval],
                [freq_subday_type],
                [freq_subday_interval],
                [freq_relative_interval],
                [freq_recurrence_factor],
                [active_start_date],
                [active_end_date],
                [active_start_time],
                [active_end_time]
			FROM 
				@remoteJobSchedules
		)

		SELECT 
			'SCHEDULE' [type],
			[name],
			[server],
			[enabled], 
			freq_type, 
			freq_interval, 
			freq_subday_type, 
			freq_subday_interval, 
			freq_relative_interval, 
			freq_recurrence_factor, 
			active_start_date, 
			active_end_date, 
			active_start_time,
			active_end_time
		FROM 
			schedules
		ORDER BY 
			[name], [server];

		-- bail, we're done. 
		RETURN 0;

	END;

	  -- If we're still here, we're looking at high-level details for all jobs (except those listed in @IgnoredJobs). 

	CREATE TABLE #IgnoredJobs (
		[name] nvarchar(200) NOT NULL
	);

	INSERT INTO #IgnoredJobs ([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredJobs, N',', 1);

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

	-- Load Details: 
	INSERT INTO #LocalJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	SELECT 
		sj.job_id, 
		sj.name, 
		sj.[enabled], 
		sj.[description], 
		sj.start_step_id,
		sj.owner_sid, 
		sj.notify_level_email, 
		ISNULL(so.name, 'local') operator_name,
		ISNULL(sc.name, 'local') [category_name],
		ISNULL((SELECT COUNT(*) FROM msdb.dbo.sysjobsteps ss WHERE ss.job_id = sj.job_id),0) [job_step_count]
	FROM 
		msdb.dbo.sysjobs sj
		LEFT OUTER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id
		LEFT OUTER JOIN msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id
	WHERE
		sj.name NOT IN (SELECT name FROM #IgnoredJobs); 

	INSERT INTO #RemoteJobs (job_id, name, [enabled], [description], start_step_id, owner_sid, notify_level_email, operator_name, category_name, job_step_count)
	EXEC master.sys.sp_executesql N'SELECT 
		sj.job_id, 
		sj.name, 
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
		LEFT OUTER JOIN PARTNER.msdb.dbo.sysoperators so ON sj.notify_email_operator_id = so.id;';

	DELETE FROM [#RemoteJobs] WHERE [name] IN (SELECT [name] FROM [#IgnoredJobs]);

	SELECT 
		N'ONLY ON ' + @localServerName [difference], * 
	FROM 
		#LocalJobs 
	WHERE
		[name] NOT IN (SELECT name FROM #RemoteJobs)
		AND [name] NOT IN (SELECT name FROM #IgnoredJobs)

	UNION SELECT 
		N'ONLY ON ' + @remoteServerName [difference], *
	FROM 
		#RemoteJobs
	WHERE 
		[name] NOT IN (SELECT name FROM #LocalJobs)
		AND [name] NOT IN (SELECT name FROM #IgnoredJobs);


	WITH names AS ( 
		SELECT
			lj.[name]
		FROM 
			#LocalJobs lj
			INNER JOIN #RemoteJobs rj ON rj.[name] = lj.[name]
		WHERE
			(@IgnoreEnabledState = 0 AND (lj.[enabled] != rj.[enabled]))
			OR lj.start_step_id != rj.start_step_id
			OR lj.owner_sid != rj.owner_sid
			OR lj.notify_level_email != rj.notify_level_email
			OR lj.operator_name != rj.operator_name
			OR lj.job_step_count != rj.job_step_count
			OR lj.category_name != rj.category_name
	), 
	core AS ( 
		SELECT 
			@localServerName [server],
            lj.[name],
            lj.[enabled],
            lj.[description],
            lj.start_step_id,
            lj.owner_sid,
            lj.notify_level_email,
            lj.operator_name,
            lj.category_name,
            lj.job_step_count
		FROM 
			#LocalJobs lj 
		WHERE 
			lj.[name] IN (SELECT [name] FROM names)

		UNION SELECT 
			@remoteServerName [server],
            rj.[name],
            rj.[enabled],
            rj.[description],
            rj.start_step_id,
            rj.owner_sid,
            rj.notify_level_email,
            rj.operator_name,
            rj.category_name,
            rj.job_step_count
		FROM 
			#RemoteJobs rj 
		WHERE 
			rj.[name] IN (SELECT [name] FROM names)
	)

	SELECT 
		[core].[server],
        [core].[name],
        [core].[enabled],
        [core].[description],
        [core].[start_step_id],
        [core].[owner_sid],
        [core].[notify_level_email],
        [core].[operator_name],
        [core].[category_name],
        [core].[job_step_count] 
	FROM
		core 
	ORDER BY 
		[name], [server];

	RETURN 0;
GO