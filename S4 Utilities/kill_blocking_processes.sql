/*
	NOTES: 
		- This sproc is a HACK. It's designed to kill leaked connections causing locking/blocking problems. 
			It's a hack because apps shouldn't be leaking connections. But, sometimes they do ... and the results
			can be seriously ugly. 


		- 'Business' logic: 
			> Any operation with a [status] of 'connected' is an S4/admindb convention to show that the request is 'orphaned' or leaked - i.e., there's no current connection. 
			> Otherwise, anything that's been blocking any other process for a MAX([duration]) > @BlockingThresholdSeconds should be killed. 

	vNEXT:
		- Can't kill system spids - so ... should, potentially? add in logic that doesn't TRY and reports "DOH!!! this is a system spid!!!"

		- add in some logic that will IGNORE lead-blockers that come from the DAC... 

		- could also add in logic that INGOREs lead blockers from specific/wild-cardable logins - i.e., 'sa' in 'good'/secure environments, etc. 

		- add in an option to REPORT on blockings by any excluded spids ... and... a threshold, i.e., something like @reportExcludedBlockersAfter '70 seconds' or whatever... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.kill_blocking_processes','P') IS NOT NULL
	DROP PROC dbo.[kill_blocking_processes];
GO

CREATE PROC dbo.[kill_blocking_processes]
	@BlockingThresholdSeconds				int					= 60,
	@ExcludeBackupsAndRestores				bit					= 1,			-- applies to root blocker only
	@ExcludeSqlServerAgentJobs				bit					= 1,			-- applies to root blocker only
	@ExcludedApplicationNames				nvarchar(MAX)		= NULL,			-- applies to root blocker only	
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

	/* 

		MKC: ALTER + UPDATE below are a HACK to get around OCCASIONAL error like: "Conversion failed when converting the nvarchar value ' » 206 ' to data type int."
				i.e., vs attempt to REPLACE » + cast as int in 'single' operation (below).
	*/
	
	ALTER TABLE [#results] ADD [blocker] sysname; 
	UPDATE [#results] 
	SET 
		[blocker] = REPLACE(LEFT([blocking_chain], PATINDEX(N'% >%', [blocking_chain])), N' » ', N'') 
	WHERE 
		[blocking_chain] IS NOT NULL;

	BEGIN TRY 
		WITH shredded AS ( 
			SELECT 
				[database]	,
				CAST([session_id] AS int) [session_id], 
				--CAST(REPLACE(LEFT([blocking_chain], PATINDEX(N'% >%', [blocking_chain])), N' » ', N'') AS int) [blocker],
				CAST([blocker] AS int) [blocker],
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
		SELECT @message = N'Exception Identifying Blockers: [' + ERROR_MESSAGE() + N'] on line [' + CAST(ERROR_LINE() AS sysname) + N'.';
		GOTO SendMessage;
	END CATCH
	
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