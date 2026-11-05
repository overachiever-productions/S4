/*

	--DBCC OPENTRAN('tempdb');


	.PARAMTER 
	REQUIRED
	@mode { CAPTURE_ONLY | CAPTURE_AND_MARK | CAPTURE_AND_KILL } - i.e., can be a vector.

	| @mode | Description |
	|---|---|
	| CAPTURE_ONLY | No KILL operations. Just CAPTURE |
	| CAPTURE_AND_MARK | CAPTURE and MARK for KILL - but don't EXECUTE KILL |
	| CAPTURE_AND_KILL | CAPTURE and execute KILL |

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[kill_zombie_transactions]','P') IS NOT NULL
	DROP PROC dbo.[kill_zombie_transactions];
GO

CREATE PROC dbo.[kill_zombie_transactions]
	@report_threshold						sysname				= N'90 seconds',			-- { <n seconds> | <n minutes> | <n hours> | <n days> } - i.e., can be a vector.
	@mode									sysname				= N'CAPTURE_ONLY',				-- CAPTURE_ONLY | CAPTURE_AND_MARK | CAPTURE_AND_KILL
	@kill_threshold							sysname				= N'95 seconds',			-- { <n seconds> | <n minutes> | <n hours> | <n days> } - i.e., can be a vector.
	@rollback								sysname				= N'1 second',				-- { IMMEDIATE | <n seconds> } - i..e, can be 'immediate' or a vector. 
	@exclude_backups_and_restores			bit					= 0,					
	@exclude_sqlagent_jobs					bit					= 0,	
	@databases								nvarchar(MAX)		= NULL,
	@applications							nvarchar(MAX)		= NULL, 
	@principals								nvarchar(MAX)		= NULL, 
	@roles									nvarchar(MAX)		= NULL,						
	@hosts									nvarchar(MAX)		= NULL, 
	@ips									nvarchar(MAX)		= NULL, 
	@statements								nvarchar(MAX)		= NULL,
	
	@SendAlerts								bit					= 1,
	@OperatorName							sysname				= N'Alerts',
	@MailProfileName						sysname				= N'General',
	@EmailSubjectPrefix						nvarchar(50)		= N'[Zombied Transactions]',
	@PrintOnly								bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @report_threshold = ISNULL(NULLIF(@report_threshold, N''), N'90 seconds');
	SET @kill_threshold = ISNULL(NULLIF(@kill_threshold, N''), N'95 seconds');

	SET @mode = UPPER(ISNULL(NULLIF(@mode, N''), N'CAPTURE_ONLY'));
	SET @SendAlerts = ISNULL(@SendAlerts, 1);

	IF @mode NOT IN (N'CAPTURE_ONLY', N'CAPTURE_AND_MARK', N'CAPTURE_AND_KILL') BEGIN 
		RAISERROR(N'Invalid @mode Specified: [%s]. Allowed Values are { CAPTURE_ONLY | CAPTURE_AND_MARK | CAPTURE_AND_KILL }.', 16, 1);
		RETURN -10;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Check for Zombies:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @zombiesXml xml;
	EXEC dbo.[zombie_transactions]
		@idle_threshold = @report_threshold,
		@exclude_backups_and_restores = @exclude_backups_and_restores,
		@exclude_sqlagent_jobs = @exclude_sqlagent_jobs,
		@databases = @databases,
		@applications = @applications,
		@principals = @principals,
		@roles = @roles,
		@hosts = @hosts,
		@ips = @ips,
		@statements = @statements,
		@serialized_output = @zombiesXml OUTPUT
	
	IF @zombiesXml IS NULL
		RETURN 0;

	SELECT 
		[d].[row].value(N'(@session_id)[1]', N'int') [session_id],
		[d].[row].value(N'(@databases)[1]', N'nvarchar(MAX)') [databases],
		[d].[row].value(N'(@principal)[1]', N'nvarchar(MAX)') [principal],
		[d].[row].value(N'(@application)[1]', N'nvarchar(MAX)') [application],
        [d].[row].value(N'(@status)[1]', N'nvarchar(MAX)') [status],
        [d].[row].value(N'(@tx_name)[1]', N'nvarchar(MAX)') [tx_name],
		[d].[row].value(N'(@tx_state)[1]', N'nvarchar(MAX)') [tx_state],
        [d].[row].value(N'(@idle_milliseconds)[1]', N'bigint') [idle_milliseconds],
		[d].[row].value(N'(@idle_time)[1]', N'nvarchar(MAX)') [idle_time],
        [d].[row].value(N'(@conn_count)[1]', N'int') [conn_count],
        [d].[row].value(N'(@open_tx_count)[1]', N'int') [open_tx_count],
        [d].[row].value(N'(@tempdb_lrc)[1]', N'int') [tempdb_lrc],
		[d].[row].value(N'(@tempdb_log_used_mb)[1]', N'decimal(12,2)') [tempdb_log_used_mb],
        [d].[row].value(N'(@tempdb_log_reserved_mb)[1]', N'decimal(12,2)') [tempdb_log_reserved_mb],
		[d].[row].query(N'(resources)[1]') [resources],
		[d].[row].value(N'(@tx_start)[1]', N'datetime') [tx_start],
        [d].[row].value(N'(@host)[1]', N'nvarchar(MAX)') [host],
		[d].[row].value(N'(@ip)[1]', N'nvarchar(MAX)') [ip],
		[d].[row].value(N'(statement/text())[1]', N'nvarchar(MAX)') [statement], 
		CAST(NULL AS sysname) [kill_action] 
	INTO 
		#candidates
	FROM 
		@zombiesXml.nodes('/zombie_transactions/session') [d]([row]);	

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing type/mode
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @killThresholdMilliseconds bigint = -1, @vectorError nvarchar(MAX);
	IF @kill_threshold IS NOT NULL BEGIN 
		EXEC admindb.dbo.[translate_vector]
			@Vector = @kill_threshold,
			@ValidationParameterName = N'@kill_threshold',
			@Output = @killThresholdMilliseconds OUTPUT,
			@Error = @vectorError OUTPUT; 

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1);
			RETURN -10;  
		END;
	END;

	IF @mode = N'CAPTURE_ONLY' BEGIN
		UPDATE [#candidates]
		SET
			[kill_action] = N'CAPTURE_ONLY'
		WHERE
			[kill_action] IS NULL;

		GOTO REPORTING;
	END;

	UPDATE [#candidates]
	SET
		[kill_action] = CASE WHEN [idle_milliseconds] > @killThresholdMilliseconds THEN N'KILLABLE' ELSE N'UNDER_KILL_THRESHOLD' END
	WHERE 
		[kill_action] IS NULL;

	IF @mode = N'CAPTURE_AND_MARK'
		GOTO REPORTING;

	IF NOT EXISTS (SELECT NULL FROM #candidates WHERE [kill_action] = N'KILLABLE')
		GOTO REPORTING;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- KILL:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @sessionId int;
	DECLARE [killer] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[c].[session_id]
	FROM 
		#candidates [c]
	WHERE 
		[c].[kill_action] = N'KILLABLE';
	
	OPEN [killer];
	FETCH NEXT FROM [killer] INTO @sessionId;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		-- UGH... TODO: 
		--    IF @PrintONLy ... vs execute. AND ... put the EXECUTE in a try/catch 
		--			and the CATCH absolutely, 10000000%, needs to watch XACT_STATE() to prevent (lol) creating TRUE zombies. 

		PRINT N'KILLING ' + CAST(@sessionId AS sysname);

		UPDATE #candidates SET kill_action += N' -> (FAKE)KILLED' WHERE [session_id] = @sessionId;
	
		FETCH NEXT FROM [killer] INTO @sessionId;
	END;
	
	CLOSE [killer];
	DEALLOCATE [killer];

REPORTING:
	DECLARE @snapshot xml, @snapshotId int;
	DECLARE @parameters xml;
	
	SELECT @parameters = (SELECT 
		@rollback [@rollback],
		@report_threshold [@report_threshold],
		@kill_threshold [@kill_threshold],
		@exclude_backups_and_restores [@exclude_backups_and_restores],
		@exclude_sqlagent_jobs [@exclude_sqlagent_jobs],
		@databases [@databases],
		@applications [@applications],
		@principals [@principals],
		@Hosts [@hosts],
		@IPs [@ips],
		@Statements [@statements],
		@mode [@mode],
		@SendAlerts [@sendAlerts],
		@OperatorName [@operatorName],
		@MailProfileName [@mailProfileName],
		@EmailSubjectPrefix [@emailSubjectPrefix],
		@PrintOnly [@printOnly]	
	FOR 
		XML PATH(N'values'), ROOT(N'parameter'), TYPE);

	SELECT @snapshot = (
		SELECT
			[session_id] [@session_id],
			[databases] [@databases],
			[principal] [@principal],
			[application] [@application],
			[status] [@status],
			[tx_name] [@tx_name],
			[tx_state] [@tx_state],
			[idle_milliseconds] [@idle_milliseconds],
			[idle_time] [@idle_time],
			[conn_count] [@conn_count],
			[open_tx_count] [@open_tx_count],
			[tempdb_lrc] [@tempdb_lrc],
			[tempdb_log_used_mb] [@tempdb_log_used_mb],
			[tempdb_log_reserved_mb] [@tempdb_log_reserved_mb],
			[tx_start] [@tx_start],
			[host] [@host],
			[ip] [@ip],
			[kill_action] [@kill_action],
			[resources],
			[statement]
		FROM
			[#candidates]
		FOR XML PATH(N'session'), ROOT(N'snapshot'), TYPE
	);

	DECLARE @count int = 0, @killCount int = 0;

	SELECT @count = COUNT(*) FROM [#candidates];
	SELECT @killCount = COUNT(*) FROM [#candidates] WHERE [kill_action] LIKE  N'%KILLED';

	INSERT INTO dbo.[killed_processes]
	(
		[timestamp],
		[type],
		[print_only],
		[row_count],
		[kill_count],
		[executed_by],
		[app_name],
		[parameters],
		[snapshot]
	)
	VALUES
	(
		GETUTCDATE(),
		N'KILLED_ZOMBIES', 
		@PrintOnly, 
		@count, 
		@killCount, 
		SUSER_NAME(), 
		(SELECT [program_name] FROM sys.[dm_exec_sessions] WHERE [session_id] = @@SPID), 
		@parameters,
		@snapshot
	);

	SELECT @snapshotId = SCOPE_IDENTITY();

	IF @SendAlerts = 0 BEGIN 
		RETURN 0;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Send Alert:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	PRINT N'Sending Alerts to Operator: ' + @OperatorName;

	-- HMM... 
	--   @snapshotID will give me the 'row' / snapshot - including meta-data, etc. 
	-- RATHER than trying to summarize the snapshot via @body in TEXT... 
	--	I might just ... capture the entire @snapshotId ROW as @xml ... 
	--		and dump that as a compressed body? 
	--    ALONG with reporting on [timestamp], totalrows, killed rows, errors?
	--		 as 'kpis' in the report itself... 
	--       i.e., KPIs from meta-data ... payload as compressed snapshot... 

	RETURN 0;
GO