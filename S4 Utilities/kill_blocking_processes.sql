/*

	.OBJECT 
	dbo.kill_blocking_processes

	.SYNOPSIS 

	.DESCRIPTION 

	.PARAMETER @BlockingCountThreshold
	REQUIRED 
	DEFAULT = 1
	Number of blocked processes that MUST be blocked by a lead-blocker before it will be considered for action (KILL or ALERT). 

	.PARAMETER @AlertThreshold 
	DEFAULT = NULL 
	CONVENTION = VECTOR
	Does NOT need to be set. If set, must be a lower threshold than @KillThreshold (unless @KillThreshold is not set - in which case this sproc
	will only raise alerts and will NOT KILL blocking processes). 
	When set, any lead-blocker that is blocking >= @BlockingCountThreshold that is NOT removed (excluded) via any predicates, will cause an alert
	to be raised/sent each time a lead-blocker is detected when it is a) blocking >= @BlockingCountThreshold and b) at least one of those processes
	has been running (not necessarily blocked) for > @AlerthThreshold. 

	.PARAMETER @KillThreshold 
	DEFAULT = 90 seconds
	CONVENTION = VECTOR
	Does NOT need to be set. If set, must be a higher threshold than @AlertThreshold (if @AlertThreshold is non-NULL). 
	When set, any lead-blocker that has been blocking >= @BlockingCountThresholds where one (or more) of the blocked processes has been running (not
	necessarily blocked) for > @KillThreshold, will be targeted for an automated KILL operation (unless the process in question is a SYSTEM process/spid). 

	.PARAMTER @ExcludeBackupsAndRestores
	REQUIRED
	DEFAULT = 1
	When set to true (1), prevents attempts to KILL or ALERT against any lead-blockers that are either BACKUP or RESTORE operations. 

	.PARAMETER @ExcludeSqlServerAgentJobs 
	REQUIRED
	DEFAULT = 1 
	When set to true (1), prevents SQL Server Agent Jobs from being ALERT'd or KILL'd when they would otherwise match or be slated for processing. 

	.PARAMETER @Databases 
	CONVENTION = STANDARD_PREDICATE (@Databases)

	.PAREMETER @Applications
	CONVENTION = STANDARD_PREDICATE (@Applications)

	... 

	.PARAMETER @KillType 
	REQUIRED 
	ENUM { KILL | CAPTURE_ONLY }
	DEFAULT = KILL 
	Specifies the behavior for any lead-blockers that would 'normally' be KILL'd or ALERT'd (against). 
	When set to KILL, behavior of sproc is to either KILL or ALERT as otherwise specified. 
	When set to CAPTURE_ONLY, sproc behavior is to IDENTIFY lead blockers and capture to admindb.dbo.killed_processes WITHOUT executing KILL or ALERT operations.
	Useful for diagnostics and/or monitoring only - to help confirm that problems exist - vs taking any action. 

	.PARAMETER @SendAlerts 
	DEFAULT = 1 
	When set to true (1), causes alerts (summary email) to be sent for any rows matched via KILL or ALERT specifications. 
	When set to false (0), still executes KILL operations if `@KillType = N'KILL'`, but does not send alerts. 
	Set to `0` when KILLing lead-blockers is an ongoing hack due to technical debt or other problems that don't need to add alerts to your inbox. 

	.PARAMETER @OperatorName 

	.PARAMETER @MailProfileName 

	.PARAMETER @EmailSubjectPrefix 

	.PARAMETER @PrintOnly 

	.REMARK
	This sproc is a glorified hack. It is designed to both a) automate the process of KILL'ing problematic lead-blockers while b) capturing specific details about the 
	blocked-processes being 'held up' or blocked when a lead-blocker is KILL'd. 

	This sproc also provides options to merely alert-upon or report-on problematic lead-blockers rather than execute KILL operations against them. (Just be aware that if you're
	using this sproc to watch for lead blockers and alert/email when they're found and have this running, say, every 30 seconds, a lead-blocker CAN run for minutes or 10s of minutes
	in plenty of scenarios meaning that a) you'll get a number of email alerts, b) NOTHING will be done to kill the lead-blocker (unless someone responds to emails/alerts) meaning
	that end-users and/or processes blocked by the lead-blocker WILL continue to be blocked/stalled. 
		
	A number of predicates can be used to EXCLUDE (or white-list for KILL / ALERT purposes) lead-blockers that would, otherwise, be KILL'd or ALERT'd against due
	to the # of blocked-processes they have caused and/or the amount of time the longest of those blocked-processes has been running. 

	NOTE: There is no way to determine how long a SPID has been truly BLOCKED vs has-been-running (i.e., could be a longer-running report or query and MIGHT have been
	running for 10s of seconds BEFORE getting blocked for just a few seconds when this sproc runs) - so there ARE some inherant issues with the way this sproc is forced
	to use [duration] (total execution time) of BLOCKED PROCESSES to assess whether or not a lead-blocker SHOULD be killed. 




	.RESULT 
	When @PrintOnly = 1, will print KILL commands and a summary of actions that WOULD HAVE BEEN taken had @PrintOnly been set to 0. 
	Otherwise, if @SendAlerts is set to 1 (true), procedure will send an email summary for any lead-blockers matching @AlertThreshold AND
	will also send a summary of outcomes (KILL operations) for any lead-blockers exceeding @KillThreshold (if specified). 
	In cases where any lead-blockers exist and have been blocking 1 or more processes for MORE than the minimum of either @AlertThreshold OR @KillThreshold,  
	this procedure WILL dump a blocked-processes snapshot into dbo.killed_processes - even IF predicates/filters otherwise REMOVE lead-blockers from being
	KILL'd or ALERT'd against. 


	.EXAMPLE
	TITLE = Setting `@AlertThreshold` and `@KillThreshold` dynamically during different parts of the day.
	Assume that you want to have an email alert kick off after 40 seconds of blocking from 7AM - 5PM each day - to allow admins to potentially RESPOND to problems
	with lead blockers (and then want a failsafe to KILL lead-blockers after 140 seconds of blocking - to prevent blocking from causing too many problems) - but also
	want to 'just KILL' operations after 120+ seconds 'after hours' without any attempt at alerts. 

	```sql

	DECLARE @alertThreshold sysname = NULL, @killThreshold sysname = N'121 seconds';
	IF CAST(FORMAT(GETDATE(), N'HH') AS int) BETWEEN 7 AND 17 BEGIN
		SELECT 
			@alertThreshold = N'40 seconds', 
			@killThreshold = N'140 seconds'
	END;

	--SELECT @alertThreshold;
	--SELECT @killThreshold;

	EXEC [admindb].dbo.[kill_blocking_processes]
		@BlockingCountThreshold = 1,
		@AlertThreshold = @alertThreshold,
		@KillThreshold = @killThreshold,
		@Databases = N'problem-db-name-here',
		@Applications = N'app_that_causes_blocking.exe',
		@Principals = N'problem-app-login',
		@KillType = N'KILL',
		@SendAlerts = 1,
		@PrintOnly = 0;

	```


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[kill_blocking_processes]','P') IS NOT NULL
	DROP PROC dbo.[kill_blocking_processes];
GO

CREATE PROC dbo.[kill_blocking_processes]
	@BlockingCountThreshold					int					= 1,					-- CAN, obviously, be set higher, but 1x blocked spid can be a major problem.... 
	@AlertThreshold							sysname				= NULL, 
	@KillThreshold							sysname				= N'90 seconds',		-- What about adding? {DISABLED} | {INFINITE}
	@ExcludeBackupsAndRestores				bit					= 1,					-- ALL exclude/allow directives apply to ROOT blocker only.
	@ExcludeSqlServerAgentJobs				bit					= 1,	
	@Databases								nvarchar(MAX)		= NULL,
	@Applications							nvarchar(MAX)		= NULL, 
	@Principals								nvarchar(MAX)		= NULL, 
	@Hosts									nvarchar(MAX)		= NULL, 
	@IPs									nvarchar(MAX)		= NULL, 
	@Statements								nvarchar(MAX)		= NULL,
	@KillType								sysname				= N'KILL',			-- KILL | CAPTURE_ONLY
	@SendAlerts								bit					= 1,
	@OperatorName							sysname				= N'Alerts',
	@MailProfileName						sysname				= N'General',
	@EmailSubjectPrefix						nvarchar(50)		= N'[Blocked Processes]',
	@PrintOnly								bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Parameter Defaults / Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @BlockingCountThreshold = ISNULL(@BlockingCountThreshold, 2);
	
	IF @AlertThreshold IS NULL
		SET @KillThreshold = ISNULL(NULLIF(@KillThreshold, N''), N'90 seconds');	
	
	SET @AlertThreshold = NULLIF(@AlertThreshold, N'');
	SET @ExcludeBackupsAndRestores = ISNULL(@ExcludeBackupsAndRestores, 1);
	SET @ExcludeSqlServerAgentJobs = ISNULL(@ExcludeSqlServerAgentJobs, 1);

	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @IPs = NULLIF(@IPs, N'');
	SET @Statements = NULLIF(@Statements, N'');

	SET @KillType = UPPER(ISNULL(NULLIF(@KillType, N''), N'KILL'));
	SET @SendAlerts = ISNULL(@SendAlerts, 1);

	IF @KillType NOT IN (N'KILL', N'CAPTURE_ONLY') BEGIN 
		RAISERROR(N'Invalid @KillType Specified: [%s]. Allowed Values are { KILL | CAPTURE_ONLY }.', 16, 1);
		RETURN -10;
	END;

	DECLARE @alertThresholdMilliseconds bigint = -1, @killThresholdMilliseconds bigint = -1, @vectorError nvarchar(MAX);

	IF @AlertThreshold IS NOT NULL BEGIN 
		EXEC admindb.dbo.[translate_vector]
			@Vector = @AlertThreshold,
			@ValidationParameterName = N'@AlertThreshold',
			@Output = @alertThresholdMilliseconds OUTPUT,
			@Error = @vectorError OUTPUT; 

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1);
			RETURN -10;  
		END;
	END;

	IF @KillThreshold IS NOT NULL BEGIN 
		SET @vectorError = NULL;
		EXEC admindb.dbo.[translate_vector]
			@Vector = @KillThreshold,
			@ValidationParameterName = N'@KillThreshold',
			@Output = @killThresholdMilliseconds OUTPUT,
			@Error = @vectorError OUTPUT; 

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1);
			RETURN -10;  
		END;
	END;

	IF @killThresholdMilliseconds > 0 BEGIN
		IF @alertThresholdMilliseconds > @killThresholdMilliseconds BEGIN 
			RAISERROR(N'@AlertThreshold my NOT be greater than @KillThreshold.', 16, 1);
			RETURN -11;
		END;
	END;

	IF @alertThresholdMilliseconds < 1 AND @killThresholdMilliseconds < 1 BEGIN
		RAISERROR(N'@AlertThreshold or @KillThreshold must be set - both can NOT be NULL (or zero).', 16, 1);
		RETURN -12;
	END;

	DECLARE @action sysname = N'';
	IF @alertThresholdMilliseconds > 0 SET @action = @action + N'ALERT';
	IF @killThresholdMilliseconds > 0 SET @action = @action + N'KILL';

	DECLARE @minThreshold bigint = (SELECT MIN(n) FROM (VALUES(@alertThresholdMilliseconds), (@killThresholdMilliseconds)) x(n) WHERE n > 0);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Check for ANY Blocking:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #snapshot (
		[database] sysname NULL,
		[blocking_chain] nvarchar(400) NULL,
		[blocking_session_id] nvarchar(4000) NULL,
		[session_id] nvarchar(4000) NULL,
		[command] sysname NULL,
		[status] sysname NOT NULL,
		[statement] nvarchar(MAX) NULL,
		[wait_time] int NULL,
		[wait_type] sysname NULL,
		[wait_resource] nvarchar(256) NOT NULL,
		[is_system] bit NOT NULL,
		[duration] bigint NULL,
		[transaction_state] varchar(11) NOT NULL,
		[isolation_level] varchar(14) NULL,
		[transaction_type] varchar(8) NOT NULL,
		[context] xml NULL
	);

	INSERT INTO [#snapshot] (
		[database],
		[blocking_chain],
		[blocking_session_id],
		[session_id],
		[command],
		[status],
		[statement],
		[wait_time],
		[wait_type],
		[wait_resource],
		[duration],
		[is_system],
		[transaction_state],
		[isolation_level],
		[transaction_type],
		[context]
	)
	EXEC dbo.[list_collisions] 
		@TargetDatabases = N'{ALL}', 
		@IncludePlans = 0, 
		@IncludeContext = 1, 
		@UseInputBuffer = 1, 
		@FormatTimeSpans = 0, 
		@ExcludeFullTextCollisions = 0;

	DELETE FROM [#snapshot] WHERE [session_id] IS NULL; -- no idea why/how this one happens... but it occasionally does. 

	IF NOT EXISTS (SELECT NULL FROM [#snapshot]) BEGIN
		RETURN 0; -- short-circuit (i.e., nothing to do or report).
	END;

	DECLARE @maxWait int = (SELECT MAX(wait_time) FROM [#snapshot] WHERE [wait_time] IS NOT NULL);
	IF @maxWait < @minThreshold BEGIN 
		RETURN 0;
	END;

	DECLARE @message nvarchar(MAX);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Shred / Extract Details on ANY Blocking > @minThreshold:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	BEGIN TRY 
		WITH shredded AS ( 
			SELECT 
				[database],
				CAST([session_id] AS int) [session_id], 
				CAST((REPLACE(LEFT([blocking_chain], PATINDEX(N'% >%', [blocking_chain])), N' ' + CHAR(187) + N' ', N'')) AS int) [blocker],
				[blocking_chain],
				[command],
				[status],
				[statement],
				[wait_time],
				[wait_type],
				[wait_resource],
				[duration],
				[is_system],
				[transaction_state],
				[isolation_level],
				[transaction_type],
				[context].value(N'(/context/program_name)[1]', N'sysname') [program_name],
				[context].value(N'(/context/host_name)[1]', N'sysname') [host_name], 
				[context].value(N'(/context/ip_address)[1]', N'sysname') [ip_address],
				[context].value(N'(/context/login_name)[1]', N'sysname') [login_name]
			FROM 
				[#snapshot]
		) 

		SELECT 
			[x].[database],
			[x].[session_id],
			[x].[blocking_chain],
			(SELECT COUNT(*) FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id]) [blocked_count],
			ISNULL([x].[command], N'<orphaned>') [command],
			[x].[status],
			[x].[statement],
			[x].[wait_type], 
			[x].[wait_resource],
			[x].[duration],
			[x].[is_system],
			CASE
				WHEN [x].[transaction_state] = N'#Unknown#' THEN N'<orphaned>' 
				ELSE [x].[transaction_state]
			END [transaction_state],
			[x].[isolation_level],
			[x].[transaction_type],
			[x].[program_name] [application], 
			[x].[host_name] [host], 
			[x].[ip_address] [ip],
			[x].[login_name] [principal], 
			CAST(NULL AS sysname) [action], 
			CAST(NULL AS nvarchar(MAX)) [outcome]
		INTO 
			[#leads]
		FROM 
			[shredded] x
		WHERE 
			[x].[blocker] = 0
			AND (SELECT MAX(wait_time) FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id]) > (@minThreshold);
	END TRY 
	BEGIN CATCH 
		SELECT @message = N'Exception Identifying Blockers: [' + ERROR_MESSAGE() + N'] on line [' + CAST(ERROR_LINE() AS sysname) + N'].';
		GOTO SendMessage;
	END CATCH;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predication / Filters:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @Databases IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_databases ([row_id] int IDENTITY(1,1) NOT NULL, [database] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [database]));
	END;
	
	IF @Applications IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_applications ([row_id] int IDENTITY(1,1) NOT NULL, [application] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [application]));
	END; 

	IF @Hosts IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_hosts ([row_id] int IDENTITY(1,1) NOT NULL, [host] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [host])); 
	END;

	IF @IPs IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_ips ([row_id] int IDENTITY(1,1) NOT NULL, [ip] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [ip]));		
	END;

	IF @Principals IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_principals ([row_id] int IDENTITY(1,1) NOT NULL, [principal] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [principal]));
	END;

	IF @Statements IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_statements ([row_id] int IDENTITY(1,1) NOT NULL, [statement] nvarchar(MAX) NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude]));
	END;

	DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
	EXEC dbo.[core_predicates]
		@Databases = @Databases,
		@Applications = @Applications,
		@Hosts = @Hosts,
		@IPs = @IPs,
		@Principals = @Principals,
		@Statements = @Statements,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	CREATE TABLE [#actionable](
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database] sysname NULL,
		[session_id] int NULL,
		[blocked_count] int NULL,
		[command] sysname NOT NULL,
		[status] sysname NOT NULL,
		[statement] nvarchar(MAX) NULL,
		[wait_type] sysname NULL,
		[wait_resource] nvarchar(256) NULL,
		[duration] sysname NULL,
		[is_system] [bit] NOT NULL,
		[transaction_state] nvarchar(11) NOT NULL,
		[isolation_level] varchar(14) NULL,
		[transaction_type] varchar(8) NOT NULL,
		[application] sysname NULL,
		[host] sysname NULL,
		[ip] sysname NULL,
		[principal] sysname NULL,
		[action] sysname NULL,
		[outcome] nvarchar(MAX) NULL
	);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[x].[database],
	[x].[session_id],
	[x].[blocked_count],
	[x].[command],
	[x].[status],
	[x].[statement],
	[x].[wait_type],
	[x].[wait_resource],
	[x].[duration],
	[x].[is_system],
	[x].[transaction_state],
	[x].[isolation_level],
	[x].[transaction_type],
	[x].[application],
	[x].[host],
	[x].[ip],
	[x].[principal] 
FROM 
	[#leads] [x]{joins}
WHERE
	1 = 1{filters}
ORDER BY 
	[x].[duration] DESC; ';

	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);

	INSERT INTO [#actionable]
	(
		[database],
		[session_id],
		[blocked_count],
		[command],
		[status],
		[statement],
		[wait_type],
		[wait_resource],
		[duration],
		[is_system],
		[transaction_state],
		[isolation_level],
		[transaction_type],
		[application],
		[host],
		[ip],
		[principal]
	)
	EXEC sys.sp_executesql 
		@sql;

	UPDATE [l] 
	SET 
		[l].[action] = N'REMOVED_BY_STANDARD_PREDICATES'
	FROM 
		[#leads] [l] 
		LEFT OUTER JOIN [#actionable] [x] ON [l].[session_id] = [x].[session_id]
	WHERE
		[x].[session_id] IS NULL;		
	
	DELETE FROM [#actionable] 
	WHERE 
		blocked_count < @BlockingCountThreshold;

	IF @ExcludeSqlServerAgentJobs = 1 BEGIN 
		DELETE FROM [#actionable] WHERE [application] LIKE N'SQLAgent - TSQL JobStep%';
	END;

	IF @ExcludeBackupsAndRestores = 1 BEGIN 
		DELETE FROM [#actionable] 
		WHERE 
			[command] LIKE N'%BACKUP%'
			OR 
			[command] LIKE N'%RESTORE%'
			OR 
			[command] LIKE N'%DBCC%';
	END;

	UPDATE [l] 
	SET 
		[l].[action] = N'REMOVED_BY_CUSTOM_PREDICATES'
	FROM 
		[#leads] [l] 
		LEFT OUTER JOIN [#actionable] [x] ON [l].[session_id] = [x].[session_id]
	WHERE
		[x].[session_id] IS NULL;

	DELETE FROM [#actionable] 
	WHERE 
		[command] = N'KILLED/ROLLBACK';

	UPDATE [l] 
	SET 
		[l].[action] = N'ALREAD_IN_KILL_STATE'
	FROM 
		[#leads] [l] 
		LEFT OUTER JOIN [#actionable] [x] ON [l].[session_id] = [x].[session_id]
	WHERE
		[x].[session_id] IS NULL;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process any remaining results:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @exit bit = 0;
	IF NOT EXISTS (SELECT NULL FROM [#actionable]) BEGIN 
		SET @exit = 1;
		GOTO Capture_Snapshot;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Mark Actionable Rows for Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @action LIKE N'%KILL%' BEGIN
		UPDATE [#actionable]
		SET 
			[action] = N'KILL'
		WHERE
			[duration] > @killThresholdMilliseconds;
	END;

	IF @action LIKE N'%ALERT%' BEGIN
		UPDATE [#actionable]
		SET 
			[action] = N'ALERT'
		WHERE 
			[action] IS NULL
			AND [duration] > @alertThresholdMilliseconds;
	END;

	UPDATE [#actionable] 
	SET 
		[action] = N'BLOCKER'
	WHERE 
		[action] IS NULL; 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- KILL killable SPIDS:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF EXISTS (SELECT NULL FROM [#actionable] WHERE [action] = N'KILL') BEGIN 
		DECLARE @rowId int, @sessionId int, @isSystem bit;
		DECLARE @command sysname;	

		DECLARE @errorMessage nvarchar(MAX), @errorLine int;
	
		DECLARE [killer] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[row_id],
			[session_id], 
			[is_system]
		FROM 
			[#actionable]
		WHERE 
			[action] = N'KILL'
		ORDER BY 
			[duration] DESC;
	
		OPEN [killer];
		FETCH NEXT FROM [killer]INTO @rowId, @sessionId, @isSystem;
	
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			IF @isSystem = 0 OR @KillType <> N'KILL' BEGIN 
				SET @command = N'KILL ' + CAST(@sessionId AS sysname) + N';';
		
				IF @PrintOnly = 1 BEGIN
					PRINT @command;

					UPDATE [#actionable] SET [outcome] = N'@PrintOnly = 1.' WHERE [row_id] = @rowId;
				  END;
				ELSE BEGIN
					BEGIN TRY
						EXEC(@command);

						UPDATE [#actionable] SET [outcome] = N'KILLED.' WHERE [row_id] = @rowId;
					END TRY 
					BEGIN CATCH 
						SELECT 
						@errorLine = ERROR_LINE(), 
						@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();

						UPDATE [#actionable] SET [outcome] = @errorMessage WHERE [row_id] = @rowId;

					END CATCH;
				END;
			  END;
			ELSE BEGIN 
				IF @isSystem = 1 BEGIN 
					UPDATE [#actionable] SET [outcome] = N'SYSTEM-PROCESS - COULD NOT KILL.' WHERE [row_id] = @rowId;
				  END;
				ELSE BEGIN 
					UPDATE [#actionable] SET [outcome] = N'@KillType = CAPTURE_ONLY.' WHERE [row_id] = @rowId;
				END;
			END;

			FETCH NEXT FROM [killer]INTO @rowId, @sessionId, @isSystem;
		END;
	
		CLOSE [killer];
		DEALLOCATE [killer];
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Snapshot:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
Capture_Snapshot:
	DECLARE @snapshot xml, @snapshotId int;
	DECLARE @parameters xml;

	SELECT @parameters = (SELECT 
		@BlockingCountThreshold [@BlockingCountThreshold],
		@AlertThreshold [@AlertThreshold],
		@KillThreshold [@KillThreshold],
		@ExcludeBackupsAndRestores [@ExcludeBackupsAndRestores],
		@ExcludeSqlServerAgentJobs [@ExcludeSqlServerAgentJobs],
		@Databases [@Databases],
		@Applications [@Applications],
		@Principals [@Principals],
		@Hosts [@Hosts],
		@IPs [@IPs],
		@Statements [@Statements],
		@KillType [@KillType],
		@SendAlerts [@SendAlerts],
		@OperatorName [@OperatorName],
		@MailProfileName [@MailProfileName],
		@EmailSubjectPrefix [@EmailSubjectPrefix],
		@PrintOnly [@PrintOnly]
	FOR 
		XML PATH(N'values'), ROOT(N'parameter'), TYPE);

	WITH shredded AS ( 
		SELECT 
			[database],
			CAST([session_id] AS int) [session_id], 
			CAST((REPLACE(LEFT([blocking_chain], PATINDEX(N'% >%', [blocking_chain])), N' ' + CHAR(187) + N' ', N'')) AS int) [blocker],
			[blocking_chain],
			[command],
			[status],
			[statement],
			[wait_time],
			[wait_type],
			[wait_resource],
			[duration],
			[is_system],
			[transaction_state],
			[isolation_level],
			[transaction_type],
			[context].value(N'(/context/program_name)[1]', N'sysname') [program_name],
			[context].value(N'(/context/host_name)[1]', N'sysname') [host_name], 
			[context].value(N'(/context/ip_address)[1]', N'sysname') [ip_address],
			[context].value(N'(/context/login_name)[1]', N'sysname') [login_name]
		FROM 
			[#snapshot]
	) 

	SELECT @snapshot = (
		SELECT 
			[x].[database],
			[x].[session_id],
			[x].[blocking_chain],
			(SELECT COUNT(*) FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id]) [blocked_count],
			ISNULL([x].[command], N'<orphaned>') [command],
			[x].[status],
			[x].[statement],
			[x].[wait_type], 
			[x].[wait_resource],
			[x].[duration],
			[x].[is_system],
			CASE
				WHEN [x].[transaction_state] = N'#Unknown#' THEN N'<orphaned>' 
				ELSE [x].[transaction_state]
			END [transaction_state],
			[x].[isolation_level],
			[x].[transaction_type],
			[x].[program_name] [application], 
			[x].[host_name] [host], 
			[x].[ip_address] [ip],
			[x].[login_name] [principal], 
			COALESCE([a].[action], [l].[action], N'VICTIM') [action],
			ISNULL([a].[outcome], N'') [outcome]
		FROM 
			[shredded] [x]
			LEFT OUTER JOIN [#actionable] [a] ON [x].[session_id] = [a].[session_id]
			LEFT OUTER JOIN [#leads] [l] ON [x].[session_id] = [l].[session_id]
		FOR XML PATH(N'row'), ROOT(N'blocked_processes'), TYPE, ELEMENTS XSINIL
	);

	DECLARE @count int = 0, @killCount int = 0;

	SELECT @count = COUNT(*) FROM [#snapshot] WHERE [duration] > @minThreshold;
	SELECT @killCount = COUNT(*) FROM [#actionable] WHERE [outcome] = N'KILLED';

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
		N'blocking_processes', 
		@PrintOnly, 
		@count, 
		@killCount, 
		SUSER_NAME(), 
		(SELECT [program_name] FROM sys.[dm_exec_sessions] WHERE [session_id] = @@SPID), 
		@parameters,
		@snapshot
	);
	SELECT @snapshotId = SCOPE_IDENTITY();

	IF @exit = 1 OR @SendAlerts = 0 BEGIN 
		RETURN 0;
	END;

SendMessage:

	DECLARE @body nvarchar(MAX) = N'';
	SELECT 
		@body = @body + CASE WHEN [action] IN (N'KILL', N'ALERT', N'BLOCKER') THEN N'BLOCKER: ' ELSE  N'  VICTIM: ' END +
		CASE WHEN ISNULL([action], N'VICTIM') = N'VICTIM' THEN N'' ELSE @crlf + @tab + N'ACTION					: ' + ISNULL([action], N'') END + 
		CASE WHEN NULLIF([outcome], N'') IS NULL THEN N'' ELSE @crlf + @tab + N'OUTCOME				: ' + [outcome] END +
		@crlf + @tab + N'database				:' + ISNULL([database], N'') +
		@crlf + @tab + N'Session Id             : ' + CAST(ISNULL([session_id], -1) AS sysname) +
		@crlf + @tab + N'Blocking Chain			: ' + CAST(ISNULL([blocking_chain], -1) AS sysname) + 
		@crlf + @tab + N'Status                 : ' + ISNULL([status], N'') +
		@crlf + @tab + N'Command                : ' + ISNULL([command], N'') +
		@crlf + @tab + N'Run Time               : ' + ISNULL([duration], N'') + 
		@crlf + @tab + N'Transaction State      : ' + ISNULL([transaction_state], N'') +
		@crlf + @tab + N'Isolation Level        : ' + ISNULL([isolation_level], N'#UNKNOWN#') +
		@crlf + @tab + N'Program Name           : ' + ISNULL([application], N'') +
		@crlf + @tab + N'Host                   : ' + ISNULL([host], N'') +
		@crlf + @tab + N'Login                  : ' + ISNULL([principal], N'') +
		@crlf + @tab + N'Statement: [' + 
		@crlf + @tab + @tab + REPLACE(RTRIM(ISNULL([statement], N'')), @crlf, @crlf + @tab + @tab) +
		@crlf + @crlf + @tab + N']' +
		@crlf + @crlf
	FROM 
		dbo.[view_killed_blocking_processes]()
	WHERE 
		[instance_id] = @snapshotId;

	DECLARE @subject sysname; 
	SET @subject = ISNULL(@EmailSubjectPrefix, N'') + N' - Blocking Processes were Detected';
	SET @message = N'The following blocking processes were detected on ' + @@SERVERNAME + N' and processed as follows: ' + @crlf + @crlf;
	SET @message = @message + @body; 
	SET @message = @message + @crlf + @crlf; 
	SET @message = @message + N'For more details run the following: { SELECT * FROM admindb.dbo.[view_killed_blocking_processes]() WHERE [instance_id] = ' + CAST(@snapshotId AS sysname) + N'; }.';

	IF @PrintOnly = 1 BEGIN 
		PRINT N'SUBJECT: ' + @subject; 
		PRINT N'BODY: ' + @message;
	  END; 
	ELSE BEGIN 
		EXEC [msdb]..[sp_notify_operator] 
			@profile_name = @MailProfileName,
			@name = @OperatorName, 
			@subject = @subject, 
			@body = @message;	
	END;

	RETURN 0;
GO