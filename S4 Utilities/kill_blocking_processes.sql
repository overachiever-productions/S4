/*
	NOTES: 
		- This sproc is a HACK. It's designed to kill leaked connections causing locking/blocking problems. 
			It's a hack because apps shouldn't be leaking connections. But, sometimes they do ... and the results
			can be seriously ugly. 


		- 'Business' logic: 
			> Any operation with a [status] of 'connected' is an S4/admindb convention to show that the request is 'orphaned' or leaked - i.e., there's no current connection. 
			> Otherwise, anything that's been blocking any other process for a MAX([duration]) > @BlockingThresholdSeconds should be killed. 

	vNEXT:
		- add in some logic that will IGNORE lead-blockers that come from the DAC... 

		- add in an option to REPORT on blockings by any excluded spids ... and... a threshold, i.e., something like @reportExcludedBlockersAfter '70 seconds' or whatever... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.kill_blocking_processes','P') IS NOT NULL
	DROP PROC dbo.[kill_blocking_processes];
GO

CREATE PROC dbo.[kill_blocking_processes]
	@BlockingThresholdSeconds				int					= 60,
	@ExcludeBackupsAndRestores				bit					= 1,			-- ALL exclude/allow directives apply to ROOT blocker only.
	@ExcludeSqlServerAgentJobs				bit					= 1,			
	@AllowedApplicationNames				nvarchar(MAX)		= NULL,			-- All @Allows** params will limit to ONLY lead-blockers via OR on @Allowed values
	@AllowedHostNames						nvarchar(MAX)		= NULL,			--			 and will, further, be EXCLUDED by @Excluded*** 
	@AllowedLogins							nvarchar(MAX)		= NULL,
	@ExcludedApplicationNames				nvarchar(MAX)		= NULL,			
	@ExcludedDatabases						nvarchar(MAX)		= NULL,
	@OperatorName							sysname				= N'Alerts',
	@MailProfileName						sysname				= N'General',
	@EmailSubjectPrefix						nvarchar(50)		= N'[Blocked Processes]',
	@PrintOnly								bit					= 0								-- Instead of EXECUTING commands, they're printed to the console only. 	

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @BlockingThresholdSeconds = ISNULL(@BlockingThresholdSeconds, 30);
	SET @ExcludeSqlServerAgentJobs = ISNULL(@ExcludeSqlServerAgentJobs, 1);
	SET @ExcludedApplicationNames = NULLIF(@ExcludedApplicationNames, N'');

	SET @AllowedApplicationNames = NULLIF(@AllowedApplicationNames, N'');
	SET @AllowedHostNames = NULLIF(@AllowedHostNames, N'');
	SET @AllowedLogins = NULLIF(@AllowedLogins, N'');

	DECLARE @message nvarchar(MAX);

	CREATE TABLE #results (
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
		[duration] nvarchar(128) NULL,
		[transaction_state] varchar(11) NOT NULL,
		[isolation_level] varchar(14) NULL,
		[transaction_type] varchar(8) NOT NULL,
		[context] xml NULL
	);

	INSERT INTO [#results] (
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
		@ExcludeFullTextCollisions = 0;

	IF EXISTS (SELECT NULL FROM [#results]) BEGIN 

		DELETE FROM [#results] WHERE [session_id] IS NULL; -- no idea why/how this one happens... but it occasionally does. 

		IF @ExcludedDatabases IS NOT NULL BEGIN 
			DELETE r
			FROM 
				[#results] r
				INNER JOIN (SELECT [result] FROM dbo.[split_string](@ExcludedDatabases, N', ', 1)) x ON r.[database] LIKE x.[result];
		END;

		IF NOT EXISTS (SELECT NULL FROM [#results]) BEGIN
			RETURN 0; -- short-circuit (i.e., nothing to do or report).
		END;

		-- Blocked processes happen all the time - at a transient level. Don't bother processing if nothing has been blocked for > @BlockingThresholdSeconds
		DECLARE @maxWait int = (SELECT MAX(wait_time) FROM [#results] WHERE [wait_time] IS NOT NULL);
		IF @maxWait < (@BlockingThresholdSeconds * 1000) BEGIN 
			RETURN 0;
		END;
	END;

	IF NOT EXISTS (SELECT NULL FROM [#results]) BEGIN
		RETURN 0; -- short-circuit (i.e., nothing to do or report).
	END;
	
	BEGIN TRY 
		WITH shredded AS ( 
			SELECT 
				[database]	,
				CAST([session_id] AS int) [session_id], 
				CAST((REPLACE(LEFT([blocking_chain], PATINDEX(N'% >%', [blocking_chain])), N' ' + CHAR(187) + N' ', N'')) AS int) [blocker],
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
				[context].value(N'(/context/login_name)[1]', N'sysname') [login_name]
			FROM 
				[#results]
		) 

		SELECT 
			[x].[database],
			[x].[session_id],
			(SELECT COUNT(*) FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id]) [blocked_count],
			dbo.[format_timespan]((SELECT MAX(wait_time) FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id])) [max_blocked_time],
			ISNULL([x].[command], N'<orphaned>') [command],
			[x].[status],
			[x].[statement],
			(SELECT TOP (1) x2.[wait_type] FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id] ORDER BY x2.[wait_time] DESC) [wait_type],
			(SELECT TOP (1) x2.[wait_resource] FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id] ORDER BY [x2].[wait_time] DESC) [blocked_resource],
			[x].[duration],
			[x].[is_system],
			CASE
				WHEN [x].[transaction_state] = N'#Unknown#' THEN N'<orphaned>' 
				ELSE [x].[transaction_state]
			END [transaction_state],
			[x].[isolation_level],
			[x].[transaction_type],
			[x].[program_name], 
			[x].[host_name], 
			[x].[login_name]
		INTO 
			#leadBlockers
		FROM 
			[shredded] x
		WHERE 
			[x].[blocker] = 0
			AND (SELECT MAX(wait_time) FROM [shredded] x2 WHERE [x2].[blocker] = x.[session_id]) > (@BlockingThresholdSeconds * 1000);
	
	END TRY 
	BEGIN CATCH 
		SELECT @message = N'Exception Identifying Blockers: [' + ERROR_MESSAGE() + N'] on line [' + CAST(ERROR_LINE() AS sysname) + N'].';
		GOTO SendMessage;
	END CATCH
	
	/* Additional short-circuit (no sense allowing/excluding if there are NO blocked processes */
	IF NOT EXISTS (SELECT NULL FROM [#leadBlockers]) BEGIN
		RETURN 0; -- short-circuit (i.e., nothing to do or report).
	END;
	
	/* Now that we know who the lead-blockers are, check for @Allowed/Inclusions - and then EXCLUDE by any @ExludeXXXX params. */
	DECLARE @allowedApps table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[app_name] sysname NOT NULL
	); 

	IF @AllowedApplicationNames IS NOT NULL BEGIN 
		INSERT INTO @allowedApps ([app_name])
		SELECT [result] FROM dbo.[split_string](@AllowedApplicationNames, N', ', 1);
		
		DELETE x 
		FROM 
			[#leadBlockers] x  
			INNER JOIN @allowedApps t ON x.[program_name] NOT LIKE t.[app_name];
	END;

	DECLARE @allowedHosts table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[host_name] sysname NOT NULL
	); 

	IF @AllowedHostNames IS NOT NULL BEGIN 
		INSERT INTO @allowedHosts ([host_name])
		SELECT [result] FROM dbo.[split_string](@AllowedHostNames, N', ', 1);

		DELETE x 
		FROM 
			[#leadBlockers] x 
			INNER JOIN @allowedHosts t ON [x].[host_name] NOT LIKE [t].[host_name];
	END;

	DECLARE @targetLogins table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[login_name] sysname NOT NULL
	); 

	IF @AllowedLogins IS NOT NULL BEGIN 
		INSERT INTO @targetLogins ([login_name])
		SELECT [result] FROM dbo.[split_string](@AllowedLogins, N', ', 1);

		DELETE x 
		FROM 
			[#leadBlockers] x 
			INNER JOIN @targetLogins t ON [x].[login_name] NOT LIKE [t].[login_name];

	END;

	DECLARE @leadBlockers int;
	SELECT @leadBlockers = COUNT(*) FROM [#leadBlockers]; -- used down below... 

	-- Now that we know who the root blockers are... check for exclusions:
	DECLARE @excludedApps table (
		row_id int IDENTITY(1,1) NOT NULL, 
		[app_name] sysname NOT NULL 
	);

	IF @ExcludeSqlServerAgentJobs = 1 BEGIN 
		INSERT INTO @excludedApps ([app_name])
		VALUES	(N'SQLAgent - TSQL JobStep%');
	END;

	IF @ExcludedApplicationNames IS NOT NULL BEGIN 
		INSERT INTO @excludedApps ([app_name])
		SELECT [result] FROM dbo.[split_string](@ExcludedApplicationNames, N', ', 1);
	END;

	IF EXISTS (SELECT NULL FROM @excludedApps) BEGIN 
		DELETE b
		FROM 
			[#leadBlockers] b 
			INNER JOIN @excludedApps x ON b.[program_name] LIKE x.[app_name];
	END;

	IF @ExcludeBackupsAndRestores = 1 BEGIN 
		DELETE FROM [#leadBlockers]
		WHERE 
			[command] LIKE N'%BACKUP%'
			OR 
			[command] LIKE N'%RESTORE%'
	END;

	-- Remove any processes ALREADY KILL'd (i.e., zombies - don't want to tell them to 'die!!' again): 
	DELETE FROM [#leadBlockers] 
	WHERE 
		[command] = N'KILLED/ROLLBACK';

	IF NOT EXISTS (SELECT NULL FROM [#leadBlockers]) BEGIN 
		RETURN 0; -- nothing tripped expected thresholds... 
	END;

	/*	IF we're still here, there are spids to kill (though they might be system) 
		So, serialize a snapshot of the issues we're seeing.
	*/
	DECLARE @collisionSnapshot xml = (
		SELECT 
			[r].[database],
			CASE WHEN [x].[session_id] IS NULL THEN 0 ELSE 1 END [should_kill],
			[r].[blocking_chain],
			[r].[session_id],
			[r].[command],
			[r].[status],
			[r].[statement],
			[r].[wait_time],
			[r].[wait_type],
			[r].[wait_resource],
			[r].[is_system],
			[r].[duration],
			[r].[transaction_state],
			[r].[isolation_level],
			[r].[transaction_type],
			[r].[context]
		FROM 
			[#results] [r]
			LEFT OUTER JOIN [#leadBlockers] [x] ON [r].[session_id] = [x].[session_id]
		FOR XML PATH('row'), ROOT('blockers'), TYPE
	);

	DECLARE @blockedProcesses int, @blockersToKill int;
	SELECT @blockedProcesses = COUNT(*) FROM [#results];
	SELECT @blockersToKill = COUNT(*) FROM [#leadBlockers];  -- we gathered ALL before, now we're left with just those to kill.
	DECLARE @snapshotId int;

	INSERT INTO dbo.[kill_blocking_process_snapshots] (
		[timestamp],
		[print_only],
		[blocked_processes],
		[lead_blockers],
		[blockers_to_kill],
		[snapshot]
	)
	VALUES	(
		GETDATE(),
		@PrintOnly,
		@blockedProcesses, 
		@leadBlockers,
		@blockersToKill, 
		@collisionSnapshot
	);

	SELECT @snapshotId = SCOPE_IDENTITY();  -- vNEXT ... use this to do updates (against new columns to add) for ... POST kill metrics (count etc.)

	DECLARE @sessionId int, @isSystem bit;
	DECLARE @command sysname;
	DECLARE [killer] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[session_id], [is_system]
	FROM 
		[#leadBlockers];
	
	OPEN [killer];
	FETCH NEXT FROM [killer]INTO @sessionId, @isSystem;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		IF @isSystem = 0 BEGIN 
			SET @command = N'KILL ' + CAST(@sessionId AS sysname) + N';';
		
			IF @PrintOnly = 1
				PRINT @command;
			ELSE BEGIN
				BEGIN TRY
					EXEC(@command);
				END TRY 
				BEGIN CATCH 

				END CATCH;
			END;
		END;

		FETCH NEXT FROM [killer]INTO @sessionId, @isSystem;
	END;
	
	CLOSE [killer];
	DEALLOCATE [killer];

	DECLARE @body nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	SELECT 
		@body = @body + CASE WHEN [is_system] = 1 THEN N'!COULD_NOT_KILL! (SYSTEM PROCESS) -> ' ELSE N'KILLED -> ' END + 
			@crlf + @tab + N'SESSION ID             : ' + CAST(ISNULL([session_id], -1) AS sysname) +
			@crlf + @tab + N'Blocked Operations     : ' + CAST(ISNULL([blocked_count], -1) AS sysname) + 
			@crlf + @tab + N'Max Blocked Duration   : ' + ISNULL([max_blocked_time], N'#ERROR#') + 
			@crlf + @tab + N'Status                 : ' + [status] +
			@crlf + @tab + N'Command                : ' + ISNULL([command], N'') +
			@crlf + @tab + N'Wait Type              : ' + ISNULL([wait_type], N'') +
			@crlf + @tab + N'Blocked Resource       : ' + ISNULL([blocked_resource], N'') +
			@crlf + @tab + N'Run Time               : ' + ISNULL([duration], N'') + 
			@crlf + @tab + N'Transaction State      : ' + ISNULL([transaction_state], N'') +
			@crlf + @tab + N'Isolation Level        : ' + ISNULL([isolation_level], N'#UNKNOWN#') +
			@crlf + @tab + N'Program Name           : ' + ISNULL([program_name], N'') +
			@crlf + @tab + N'Host                   : ' + ISNULL([host_name], N'') +
			@crlf + @tab + N'Login                  : ' + ISNULL([login_name], N'') +
			@crlf + @tab + N'Statement: [' + 
			@crlf + @tab + @tab + REPLACE(RTRIM(ISNULL([statement], N'')), @crlf, @crlf + @tab + @tab) +
			@crlf + @crlf + @tab + N']' +
			@crlf + @crlf
	FROM 
		[#leadBlockers] 
	ORDER BY 
		[blocked_count] DESC, [max_blocked_time] DESC;

	DECLARE @subject sysname; 

	SET @subject = ISNULL(@EmailSubjectPrefix, N'') + N' - Blocking Processes were KILLED';
	SET @message = N'The following blocking processes were detected and _KILLED_ on ' + @@SERVERNAME + N' because they exceeded blocking thresholds of ' + CAST(@BlockingThresholdSeconds AS sysname) + N' seconds: ' + @crlf + @crlf;
	SET @message = @message + @body; 

SendMessage:
	IF @PrintOnly = 1 BEGIN 
		PRINT N'SUBJECT: ' + @subject; 
		PRINT N'BODY: ' + @message;
	  END; 
	ELSE BEGIN 
		EXEC [msdb]..[sp_notify_operator] 
			@profile_name = @MailProfileName,
			@name = @OperatorName, -- operator name
			@subject = @subject, 
			@body = @message;	
	END;

	RETURN 0;
GO