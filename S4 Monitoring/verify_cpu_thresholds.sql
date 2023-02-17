/*
				DECLARE @jobStaTime datetime;
				DECLARE @jobEndTime datetime; 

				-- Case 1: single boundary: 
				SET @jobStaTime = '2021-02-25 12:59:00.000';
				SET @jobEndTime = '2021-02-25 12:59:10.000';
						-- ([b].[start_time] <= @jobStaTime AND [b].[end_time] >= @jobEndTime)


				-- Case 2: multiple boundaries in scope of history: 
				--SET @jobStaTime = '2021-02-25 12:55:00.000';
				--SET @jobEndTime = '2021-02-25 12:58:10.000';
				--		-- (@jobEndTime > b.[start_time] AND @jobStaTime < b.[end_time])


				---- Case 3: job already running at start of our scope and runs 1 or more boundaries:
				--SET @jobStaTime = '2021-02-25 12:46:00.000';
				--SET @jobEndTime = '2021-02-25 12:48:10.000';
				--		-- SAME predicate as Case 2:
				--		-- (@jobEndTime > b.[start_time] AND @jobStaTime < b.[end_time])


				---- Case 4: job running at END of our scope for 1 or more boundaries but hasn't stopped (still running):
				--SET @jobStaTime = '2021-02-25 13:05:10.000';
				--SET @jobEndTime = '2021-02-25 13:08:10.000';
				--		-- SAME predicate as Case 2:
				--		-- (@jobEndTime > b.[start_time] AND @jobStaTime < b.[end_time])


				---- Case 5: Job running OUTSIDE of our scope:
				--SET @jobStaTime = '2021-02-25 12:46:10.000';
				--SET @jobEndTime = '2021-02-25 12:46:40.000';
				--		-- SAME predicate as Case 2:
						-- (@jobEndTime > b.[start_time] AND @jobStaTime < b.[end_time])

				-- tested for before AND after... 
				--SET @jobStaTime = '2021-02-25 13:07:10.000';
				--SET @jobEndTime = '2021-02-25 13:07:40.000';


	TODO:
		- tune for alerts - i.e., current config sets it to alert IF there's a single MINUTE where CPU > @CpuAlertThreshold... 
			which means that emails like this show up: 
								Specified Threshold Exceeded. Avg CPU usage of 25 over last 20 minutes.

			which is kind of lame... 
				only... what's actually going on in the above is ... the CPU has been at 76% for the last 7/20 minutes
					which IS a problem. 
				But that title sucks. 


			Maybe all'z I need to do is set it to a message that says: 
							Specified Threshold Exceeded. CPU averaged {value of avg when OVER threshold}% usage {n} times over last {whatever} minutes.

					That way we get to see that the avg was X over N violations/minutes

					i.e., something along those lines is cleaner/better. 
				

	vNEXT:
		- Optimization Idea - if ... CPU has been < @Threshold for all minutes reported/checked... then don't BOTHER looking for 'exceptions' caused by various jobs... 
			or, in other words, if there's NOTHING to report because there have NOT been ANY problems, don't bother running a bunch of checks/comparisons to see what jobs might've caused problems (as there weren't any problems).

	
		EXEC [admindb].dbo.[verify_cpu_thresholds]
			@CpuAlertThreshold = 60,
			@JobsToIgnoreCpuFrom = N'User Databases.LOG Backups',
			@PrintOnly = 1;




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_cpu_thresholds','P') IS NOT NULL
	DROP PROC dbo.[verify_cpu_thresholds];
GO

CREATE PROC dbo.[verify_cpu_thresholds]
	@CpuAlertThreshold					int					= 80, 
	@KernelPercentThreshold				decimal(5,2)		= 5.10,		-- WHEN > 0 will cause 10x kernel-time checks over 10 seconds and if AVERAGE of kernel time % > @Threshold, will send alerts.
	@JobsToIgnoreCpuFrom				nvarchar(MAX)		= NULL, 
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[CPU Checks] ', 
	@PrintOnly							bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	SET @CpuAlertThreshold = ISNULL(@CpuAlertThreshold, 80);
	SET @KernelPercentThreshold = ISNULL(@KernelPercentThreshold, 0);
	SET @JobsToIgnoreCpuFrom = NULLIF(@JobsToIgnoreCpuFrom, N'');
	SET @EmailSubjectPrefix = ISNULL(NULLIF(@EmailSubjectPrefix, N''), N'[CPU Checks] ');

	IF @CpuAlertThreshold > 99 OR @CpuAlertThreshold < 1 BEGIN 
		RAISERROR(N'@CpuAlertThreshold values must be between 1 and 99 - and represent overall CPU usage percentage.', 16, 1);
		RETURN -1;
	END;
	
	---------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;  /* Required for @KernelPercent checks (i.e., we're using powershell) */
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

    ----------------------------------------------
	-- Determine the last time this job ran: 
    DECLARE @now datetime = GETDATE();
	DECLARE @lastCheckupExecutionTime datetime;
    EXEC [dbo].[get_last_job_completion_by_session_id] 
        @SessionID = @@SPID, 
        @ExcludeFailures = 1, 
        @LastTime = @lastCheckupExecutionTime OUTPUT; 

	SET @lastCheckupExecutionTime = ISNULL(@lastCheckupExecutionTime, DATEADD(MINUTE, -20, GETDATE()));

    IF DATEDIFF(MINUTE, @lastCheckupExecutionTime, GETDATE()) > 20
        SET @lastCheckupExecutionTime = DATEADD(MINUTE, -20, GETDATE())

    DECLARE @syncCheckSpanMinutes int = DATEDIFF(MINUTE, @lastCheckupExecutionTime, GETDATE());

    IF @syncCheckSpanMinutes <= 1 
        RETURN 0; -- no sense checking on history if it's just been a minute... 

	----------------------------------------------
	-- get CPU history for the last N minutes:
	DECLARE @cpuHistory xml; 
	EXEC dbo.list_cpu_history 
		@SerializedOutput = @cpuHistory OUTPUT;

	-- and get a list of jobs running in the last N minutes: 
	DECLARE @runningJobs xml;
	EXEC dbo.[list_running_jobs]
		@StartTime = @lastCheckupExecutionTime,
		@EndTime = @now,
		@SerializedOutput = @runningJobs OUTPUT;
	
	CREATE TABLE #running_jobs (
		row_id int IDENTITY(1,1) NOT NULL, 
		job_name sysname NOT NULL, 
		start_time datetime NULL, 
		end_time datetime NULL, 
		[status] sysname NULL 
	);

	WITH shredded AS (
		SELECT 
			[data].[row].value(N'job_name[1]', N'sysname') job_name, 
			[data].[row].value(N'start_time[1]', N'datetime') start_time, 
			[data].[row].value(N'end_time[1]', N'datetime') end_time, 
			[data].[row].value(N'job_status[1]', N'sysname') job_status 			
		FROM 
			@runningJobs.nodes(N'//job') [data]([row])
	)

	INSERT INTO [#running_jobs] (
		[job_name],
		[start_time],
		[end_time],
		[status]
	)
	SELECT 
		[job_name], 
		[start_time], 
		[end_time], 
		[job_status]
	FROM 
		[shredded];

	IF @JobsToIgnoreCpuFrom IS NULL BEGIN 
		DELETE FROM [#running_jobs];  -- there are no 'exceptions' to track against - remove all jobs... 
	  END;
	ELSE BEGIN 
		-- NOTE: it's a bit counter-intuitive, but we only want to keep jobs that we can EXCLUDE cpu-usage from:
		DELETE FROM [#running_jobs] 
		WHERE 
			[job_name] NOT IN (
				SELECT [result] FROM dbo.[split_string](@JobsToIgnoreCpuFrom, N',', 1)
			);
	END;

	----------------------------------------------
	-- manage intersection of CPU history + running jobs: 
	CREATE TABLE #cpu_history (
		row_id int IDENTITY(1,1) NOT NULL, 
		[start_time] datetime NOT NULL, 
		[end_time] datetime NOT NULL,
		sql_cpu_usage int NOT NULL, 
		other_process_usage int NOT NULL, 
		idle_cpu int NOT NULL, 
		--[job_running] bit DEFAULT (0)
		running_jobs nvarchar(MAX) NULL
	);

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'timestamp[1]', N'datetime') [timestamp], 
			[data].[row].value(N'sql_cpu_usage[1]', N'int') [sql_cpu_usage],
			[data].[row].value(N'other_process_usage[1]', N'int') [other_process_usage],
			[data].[row].value(N'system_idle[1]', N'int') [idle_cpu]
		FROM 
			@cpuHistory.nodes(N'//entry') [data]([row])
	)
	INSERT INTO [#cpu_history] (
		[start_time],
		[end_time],
		[sql_cpu_usage],
		[other_process_usage],
		[idle_cpu]
	)
	SELECT 
		[timestamp] [start_time],
		LEAD([timestamp], 1, [timestamp]) OVER (ORDER BY [shredded].[timestamp]) [end_time],
		[sql_cpu_usage],
		[other_process_usage],
		[idle_cpu]
	FROM 
		[shredded] 
	WHERE 
		[shredded].[timestamp] >= @lastCheckupExecutionTime;

	IF EXISTS (SELECT NULL FROM [#running_jobs]) BEGIN 

		DECLARE @minStart datetime, @maxEnd datetime;
		SELECT 
			@minStart = MIN(start_time), 
			@maxEnd = MAX(end_time) 
		FROM 
			[#cpu_history];
		
		-- vNEXT: there are 5x cases to address via set theory: 
		--			a) jobs that don't run at all during our window (shouldn't exist but... whatever) 
		--			b) jobs that start + end within a single 1-minute interval.
		--			c) jobs spanning multiple 1 minute intervals. 
		--			d) jobs running when our first interval starts and running 1 or more intervals. 
		--			e) jobs running 1 or more intervals before our total window ends (i.e., jobs running 'now')
		--	I could NOT seem to even address a, b, c via set-based operations... so I went with a cursor instead. sigh. 
		--	that said, after, cough, over an HOUR of trial/error and then giving up and creating a 'matrix' I could view/proof-against, 
		--			the 'formula' is: (@jobEndTime > boundary.[start_time] AND @jobStaTime < boundary.[end_time])
		DECLARE @jobName sysname, @jobStart datetime, @jobEnd datetime;
		SELECT 
			@minStart = MIN(start_time), 
			@maxEnd = MAX(end_time) 
		FROM 
			[#cpu_history];

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT job_name, ISNULL(start_time, @minStart), ISNULL(end_time, @maxEnd) FROM [#running_jobs];
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @jobName, @jobStart, @jobEnd;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			UPDATE [#cpu_history] 
			SET 
				[running_jobs] = CASE WHEN [running_jobs] IS NULL THEN @jobName ELSE [running_jobs] + N', ' + @jobName END 
			WHERE 
				(@jobEnd >= [start_time] AND @jobStart <= [end_time])			
		
			FETCH NEXT FROM [walker] INTO @jobName, @jobStart, @jobEnd;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

	END;

	IF @KernelPercentThreshold > 0 BEGIN 
		DECLARE @output xml, @errorMessage nvarchar(MAX);
		EXEC [admindb].dbo.[execute_command]
			@Command = N'(Get-Counter -Counter ''\Processor(_Total)\% Privileged Time'' -MaxSamples 10).CounterSamples.CookedValue;',
			@ExecutionType = N'POSH',
			@IgnoredResults = N'',
			@SafeResults = N'{ALL}',	/* treat all results as safe... */
			@ErrorResults = N'',
			@PrintOnly = 0,
			@Outcome = @output OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;	
			
		DECLARE @kernelAverage decimal(5,2);
		WITH shredded AS ( 
			SELECT 
				--[data].[row].value(N'@result_id[1]', N'int') [result_id], 
				[data].[row].value(N'.[1]', N'decimal(16,12)') [value]
			FROM 
				@output.nodes(N'//result_row') [data]([row])
		)

		SELECT 
			@kernelAverage = AVG([value])
		FROM 
			[shredded];


		IF @kernelAverage > @KernelPercentThreshold BEGIN
			PRINT 'TODO: figure out how to create an alert about kernel-time > @threshold... '
		END;
	END;

	-- Report on CPU usage exceptions/problems: 
	IF EXISTS (SELECT NULL FROM [#cpu_history] WHERE [running_jobs] IS NULL AND ([sql_cpu_usage] + [other_process_usage]) > @CpuAlertThreshold) BEGIN
		DECLARE @xmlSummary xml;
		DECLARE @subject sysname;
		DECLARE @message nvarchar(MAX);

		SELECT @xmlSummary = (
			SELECT
				start_time, 
				end_time, 
				[sql_cpu_usage], 
				[other_process_usage], 
				[idle_cpu], 
				[running_jobs]
			FROM 
				[#cpu_history] 
			--WHERE 
			--	[running_jobs] IS NULL  -- ignore CPU values from rows where a job-to-ignore-cpu-from is running... 
			--	AND ([sql_cpu_usage] + [other_process_usage]) >= @CpuAlertThreshold
			ORDER BY 
				row_id
			FOR XML PATH('entry'), ROOT('history')
		);

		DECLARE @avg int; 
		DECLARE @avgCount int;
		SELECT 
			@avg = AVG([sql_cpu_usage] + [other_process_usage]), 
			@avgCount = COUNT(*)
		FROM 
			[#cpu_history] 
		WHERE 
			[running_jobs] IS NULL
			AND ([sql_cpu_usage] + [other_process_usage]) > @CpuAlertThreshold;

		SET @subject = @EmailSubjectPrefix + N' - ' + CAST(@CpuAlertThreshold AS sysname) + N'% Utilization Threshold Exceeded. CPU averaged ' + CAST(@avg AS sysname) + N'% utilization ' + CAST(@avgCount AS sysname) + CASE WHEN @avgCount = 1 THEN N' once' ELSE N' minutes' END + N' over last ' + CAST(@syncCheckSpanMinutes AS sysname) + N' minutes.';
		SET @message = N'CPU utlization on ' + @@SERVERNAME + N' during the last ' + CAST(@syncCheckSpanMinutes AS sysname) + N' minutes exceeded @CpuAlertThreshold value of ' + CAST(@CpuAlertThreshold AS sysname) + N'% utilization ' + CASE WHEN @avgCount = 1 THEN N' once.' ELSE CAST(@avgCount AS sysname) END + N' times.';
		SET @message = @message + N'
			Summary Data: 
			
			' + CAST(@xmlSummary AS nvarchar(MAX));

		IF @PrintOnly = 1 BEGIN 
			PRINT @subject;
			PRINT @message;
		  END;
		ELSE BEGIN 
			
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName, -- operator name
				@subject = @subject, 
				@body = @message;	
		END;
	END;

	RETURN 0;
GO