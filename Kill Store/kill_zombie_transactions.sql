/*

	--DBCC OPENTRAN('tempdb');


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[kill_zombie_transactions]','P') IS NOT NULL
	DROP PROC dbo.[kill_zombie_transactions];
GO

CREATE PROC dbo.[kill_zombie_transactions]
	@rollback								sysname				= N'1 second',				-- { IMMEDIATE | <n seconds> } - i..e, can be 'immediate' or a vector. 
	@report_threshold						sysname				= N'90 seconds',			-- { <n seconds> | <n minutes> | <n hours> | <n days> } - i.e., can be a vector.
	@kill_threshold							sysname				= N'90 seconds',			-- { <n seconds> | <n minutes> | <n hours> | <n days> } - i.e., can be a vector.
	@exclude_backups_and_restores			bit					= 1,					
	@exclude_sqlagent_jobs					bit					= 1,	
	@databases								nvarchar(MAX)		= NULL,
	@applications							nvarchar(MAX)		= NULL, 
	@principals								nvarchar(MAX)		= NULL, 
	@roles									nvarchar(MAX)		= NULL,						
	@hosts									nvarchar(MAX)		= NULL, 
	@ips									nvarchar(MAX)		= NULL, 
	@statements								nvarchar(MAX)		= NULL,
	@mode									sysname				= N'CAPTURE',				-- CAPTURE | CAPTURE_AND_KILL
	@SendAlerts								bit					= 1,
	@OperatorName							sysname				= N'Alerts',
	@MailProfileName						sysname				= N'General',
	@EmailSubjectPrefix						nvarchar(50)		= N'[Zombied Transactions]',
	@PrintOnly								bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @report_threshold = ISNULL(NULLIF(@report_threshold, N''), N'90 seconds');
	SET @exclude_backups_and_restores = ISNULL(@exclude_backups_and_restores, 1);
	SET @exclude_sqlagent_jobs = ISNULL(@exclude_sqlagent_jobs, 1);

	SET @databases = NULLIF(@databases, N'');
	SET @applications = NULLIF(@applications, N'');
	SET @principals = NULLIF(@principals, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @IPs = NULLIF(@IPs, N'');
	SET @Statements = NULLIF(@Statements, N'');

	SET @mode = UPPER(ISNULL(NULLIF(@mode, N''), N'CAPTURE'));
	SET @SendAlerts = ISNULL(@SendAlerts, 1);

	IF @mode NOT IN (N'CAPTURE', N'CAPTURE_AND_KILL') BEGIN 
		RAISERROR(N'Invalid @KillType Specified: [%s]. Allowed Values are { CAPTURE | CAPTURE_AND_KILL }.', 16, 1);
		RETURN -10;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Check for Zombies:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @zombiesXml xml;
	EXEC dbo.[zombie_transactions]
		@idle_threshold = @report_threshold,
		@serialized_output = @zombiesXml OUTPUT;
	
	--IF @zombiesXml IS NULL
	--	RETURN 0;

	SELECT 
		[d].[row].value(N'(session_id/text())[1]', N'int') [session_id],
		[d].[row].value(N'(databases/text())[1]', N'nvarchar(MAX)') [database],		/*  NOTE ... converting [databases] to [database] to allow core_predicate JOINS/predication */
		[d].[row].value(N'(principal/text())[1]', N'nvarchar(MAX)') [principal],
		[d].[row].value(N'(host/text())[1]', N'nvarchar(MAX)') [host],
		[d].[row].value(N'(ip/text())[1]', N'nvarchar(MAX)') [ip],
		[d].[row].value(N'(application/text())[1]', N'nvarchar(MAX)') [application],
		[d].[row].value(N'(status/text())[1]', N'nvarchar(MAX)') [status],
		[d].[row].value(N'(open_transactions/text())[1]', N'int') [open_transactions],
		[d].[row].query(N'(resources)[1]') [resources],
		[d].[row].value(N'(idle_time/text())[1]', N'nvarchar(MAX)') [idle_time],
		[d].[row].value(N'(tx_name/text())[1]', N'nvarchar(MAX)') [tx_name],
		[d].[row].value(N'(tx_start/text())[1]', N'datetime') [tx_start],
		[d].[row].value(N'(transaction_state/text())[1]', N'nvarchar(MAX)') [transaction_state],
		[d].[row].value(N'(statement/text())[1]', N'nvarchar(MAX)') [statement], 
		CAST(NULL AS sysname) [kill_action] 
	INTO 
		#candidates
	FROM 
		@zombiesXml.nodes('/zombie_like_transactions/session') [d]([row]);	

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predication / Filters:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @databases IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_databases ([row_id] int IDENTITY(1,1) NOT NULL, [database] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [database]));
	END;
	
	IF @applications IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_applications ([row_id] int IDENTITY(1,1) NOT NULL, [application] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [application]));
	END; 

	IF @Hosts IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_hosts ([row_id] int IDENTITY(1,1) NOT NULL, [host] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [host])); 
	END;

	IF @IPs IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_ips ([row_id] int IDENTITY(1,1) NOT NULL, [ip] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [ip]));		
	END;

	IF @principals IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_principals ([row_id] int IDENTITY(1,1) NOT NULL, [principal] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [principal]));
	END;

	IF @Statements IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_statements ([row_id] int IDENTITY(1,1) NOT NULL, [statement] nvarchar(MAX) NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude]));
	END;

	DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
	EXEC dbo.[core_predicates]
		@Databases = @databases,
		@Applications = @applications,
		@Hosts = @Hosts,
		--@IPs = @IPs,
		@Principals = @principals,
		@Statements = @Statements,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[x].[session_id],
	[x].[database] [databases],
	[x].[principal],
	[x].[host],
	[x].[ip],
	[x].[application],
	[x].[status],
	[x].[open_transactions],
	[x].[resources],
	[x].[idle_time],
	[x].[tx_name],
	[x].[tx_start],
	[x].[transaction_state],
	[x].[statement]
FROM 
	[#candidates] [x]{joins}
WHERE 
	1 = 1{filters}';

	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);

	CREATE TABLE [#actionable] (
		[session_id] int NULL,
		[databases] nvarchar(MAX) NULL,
		[principal] nvarchar(MAX) NULL,
		[host] nvarchar(MAX) NULL,
		[ip] nvarchar(MAX) NULL,
		[application] nvarchar(MAX) NULL,
		[status] nvarchar(MAX) NULL,
		[open_transactions] int NULL,
		[resources] xml NULL,
		[idle_time] nvarchar(MAX) NULL,
		[tx_name] nvarchar(MAX) NULL,
		[tx_start] datetime NULL,
		[transaction_state] nvarchar(MAX) NULL,
		[statement] nvarchar(MAX) NULL
	);

	INSERT INTO [#actionable]
	(
		[session_id],
		[databases],
		[principal],
		[host],
		[ip],
		[application],
		[status],
		[open_transactions],
		[resources],
		[idle_time],
		[tx_name],
		[tx_start],
		[transaction_state],
		[statement]
	)
	EXEC sys.sp_executesql 
		@sql;

	UPDATE [c]
	SET 
		[c].[kill_action] = N'REMOVED_BY_CORE_PREDICATES'
	FROM 
		#candidates [c]
		LEFT OUTER JOIN #actionable [a] ON [c].[session_id] = [a].[session_id]
	WHERE 
		[a].[session_id] IS NULL;
	
	IF @mode = N'CAPTURE_ONLY' BEGIN
		UPDATE [#candidates]
		SET
			[kill_action]	= N'CAPTURE_ONLY'
		WHERE
			[kill_action] IS NULL;

		GOTO REPORTING;
	END;

	UPDATE [#candidates]
	SET
		[kill_action]	= N'KILLABLE'
	WHERE 
		[kill_action] IS NULL;

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
		@rollback [@Rollback],
		@report_threshold [@IdleThreshold],
		@exclude_backups_and_restores [@ExcludeBackupsAndRestores],
		@exclude_sqlagent_jobs [@ExcludeSqlServerAgentJobs],
		@databases [@Databases],
		@applications [@Applications],
		@principals [@Principals],
		@Hosts [@Hosts],
		@IPs [@IPs],
		@Statements [@Statements],
		@mode [@KillType],
		@SendAlerts [@SendAlerts],
		@OperatorName [@OperatorName],
		@MailProfileName [@MailProfileName],
		@EmailSubjectPrefix [@EmailSubjectPrefix],
		@PrintOnly [@PrintOnly]
	FOR 
		XML PATH(N'values'), ROOT(N'parameter'), TYPE);

	SELECT @snapshot = (
		SELECT
			[session_id] [@session_id],
			[kill_action] [@outcome],
			[database] [@databases],
			[principal] [@principal],
			[host] [@host],
			[ip] [@ip],
			[application] [@application],
			[status] [@status],
			[open_transactions] [@open_transactions],
			[idle_time] [@idle_time],
			[tx_name] [@tx_name],
			[tx_start] [@tx_start],
			[transaction_state] [@transaction_state],
			[statement],
			[resources]
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
		GETDATE(),	-- timestamp
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