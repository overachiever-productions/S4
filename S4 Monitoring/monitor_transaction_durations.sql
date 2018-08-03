

/*

	-- TODO: probably want/need to change this sproc's name... 

	-- TODO: show 'status' of the query - i.e., running, runnable, sleeping, etc..... that info will be CRITICAL in determining what's up... 
	--			so... list that as the first 'metric'... 


*/



IF OBJECT_ID('dbo.monitor_transaction_durations','P') IS NOT NULL
	DROP PROC dbo.monitor_transaction_durations;
GO

CREATE PROC dbo.monitor_transaction_durations	
	@ExcludeSystemProcesses				bit					= 1,				
	@ExcludedDatabases					nvarchar(MAX)		= NULL,				-- N'master, msdb'  -- recommended that tempdb NOT be excluded... (long running txes in tempdb are typically going to be a perf issue - typically (but not always).
	@ExcludedCommands					nvarchar(MAX)		= NULL,				-- N'TASK MANAGER, BRKR TASK, etc..'
	@ExcludedLastWaitTypes				nvarchar(MAX)		= NULL,				-- N'XE_DISPATCHER_WAIT, BROKER_TO_FLUSH, etc..'
	@AlertThreshold						sysname				= N'10m', 
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[ALERT:] ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON;

	-- {copyright}

	SET @AlertThreshold = LTRIM(RTRIM(@AlertThreshold));
	DECLARE @durationType char(1);
	DECLARE @durationValue int;

	SET @durationType = LOWER(RIGHT(@AlertThreshold,1));

	-- Only approved values are allowed: (s[econd], m[inutes], h[ours], d[ays], w[eeks]). 
	IF @durationType NOT IN ('s','m','h','d','w') BEGIN 
		RAISERROR('Invalid @Retention value specified. @Retention must take the format of #L - where # is a positive integer, and L is a SINGLE letter [m | h | d | w | b] for minutes, hours, days, weeks, or backups (i.e., a specific number of most recent backups to retain).', 16, 1);
		RETURN -10000;	
	END 

	-- a WHOLE lot of negation going on here... but, this is, insanely, right:
	IF NOT EXISTS (SELECT 1 WHERE LEFT(@AlertThreshold, LEN(@AlertThreshold) - 1) NOT LIKE N'%[^0-9]%') BEGIN 
		RAISERROR('Invalid @Retention specified defined (more than one non-integer value found in @Retention value). Please specify an integer and then either [ m | h | d | w | b ] for minutes, hours, days, weeks, or backups (specific number of most recent backups) to retain.', 16, 1);
		RETURN -10001;
	END
	
	SET @durationValue = CAST(LEFT(@AlertThreshold, LEN(@AlertThreshold) -1) AS int);

	DECLARE @transactionCutoffTime datetime = NULL; 

	IF @durationType = 's'
		SET @transactionCutoffTime = DATEADD(SECOND, 0 - @durationValue, GETDATE());

	IF @durationType = 'm'
		SET @transactionCutoffTime = DATEADD(MINUTE, 0 - @durationValue, GETDATE());

	IF @durationType = 'h'
		SET @transactionCutoffTime = DATEADD(HOUR, 0 - @durationValue, GETDATE());

	IF @durationType = 'd'
		SET @transactionCutoffTime = DATEADD(DAY, 0 - @durationValue, GETDATE());

	IF @durationType = 'w'
		SET @transactionCutoffTime = DATEADD(WEEK, 0 - @durationValue, GETDATE());
		
	IF @transactionCutoffTime >= GETDATE() BEGIN; 
			RAISERROR('Invalid @AlertThreshold specification. Specified value is in the future.', 16, 1);
			RETURN -10;
	END;		
	
	SELECT 
		[dtat].[transaction_id],
        [dtat].[transaction_begin_time], 
		[dtst].[session_id],
        [dtst].[enlist_count] [active_requests],
        [dtst].[is_user_transaction],
        [dtst].[open_transaction_count]
	INTO 
		#LongRunningTransactions
	FROM 
		sys.[dm_tran_active_transactions] dtat
		LEFT OUTER JOIN sys.[dm_tran_session_transactions] dtst ON dtat.[transaction_id] = dtst.[transaction_id]
	WHERE 
		[dtst].[session_id] IS NOT NULL
		AND [dtat].[transaction_begin_time] < @transactionCutoffTime
	ORDER BY 
		[dtat].[transaction_begin_time];

	IF NOT EXISTS(SELECT NULL FROM [#LongRunningTransactions]) 
		RETURN 0;  -- nothing to report on... 

	IF @ExcludeSystemProcesses = 1 BEGIN 
		DELETE lrt 
		FROM 
			[#LongRunningTransactions] lrt
			LEFT OUTER JOIN sys.[dm_exec_sessions] des ON lrt.[session_id] = des.[session_id]
		WHERE 
			des.[is_user_process] = 0
			OR des.[session_id] < 50;		
	END;

	IF NULLIF(@ExcludedDatabases, N'') IS NOT NULL BEGIN 
		DELETE lrt 
		FROM 
			[#LongRunningTransactions] lrt
			LEFT OUTER JOIN sys.[dm_exec_sessions] des ON lrt.[session_id] = des.[session_id]
		WHERE 
			des.[database_id] IN (SELECT d.database_id FROM sys.databases d LEFT OUTER JOIN dbo.[split_string](@ExcludedDatabases, N',') ss ON d.[name] = ss.[result] WHERE ss.[result] IS NOT NULL);
	END;

	-- Grab Statements
	WITH handles AS ( 
		SELECT 
			sp.spid [session_id], 
			sp.[sql_handle]
		FROM 
			sys.[sysprocesses] sp
			INNER JOIN [#LongRunningTransactions] lrt ON sp.[spid] = lrt.[session_id]
	)

	SELECT 
		[session_id],
		t.[text] [statement]
	INTO 
		#Statements
	FROM 
		handles h
		OUTER APPLY sys.[dm_exec_sql_text](h.[sql_handle]) t;
	
	-- Assemble output/report: 
	DECLARE @line nvarchar(200) = REPLICATE(N'-', 200);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9); 
	DECLARE @messageBody nvarchar(MAX) = N'';

	SELECT 
		@messageBody = @messageBody + @line + @crlf
		+ '- session_id [' + CAST(lrt.[session_id] AS sysname) + N'] has been running in database ' +  QUOTENAME(DB_NAME([dtdt].[database_id]) + N'[]') + N' for a duration of: ' + dbo.[format_timespan](DATEDIFF(MILLISECOND, lrt.[transaction_begin_time], GETDATE())) + N'.' + @crlf 
		+ @tab + N'METRICS: ' + @crlf
		+ @tab + @tab + N'[is_user_transaction: ' + CAST(lrt.[is_user_transaction] AS sysname) + N'],' + @crlf 
		+ @tab + @tab + N'[open_transaction_count: '+ CAST(lrt.[open_transaction_count] AS sysname) + N'],' + @crlf
		+ @tab + @tab + N'[active_requests: ' + CAST(lrt.[active_requests] AS sysname) + N'], ' + @crlf 
		+ @tab + @tab + N'[is_tempdb_enlisted: ' + CAST([dtdt].[tempdb_enlisted] AS sysname) + N'], ' + @crlf 
		+ @tab + @tab + N'[log_record (count|bytes): (' + CAST([dtdt].[log_record_count] AS sysname) + N') | ( ' + CAST([dtdt].[log_bytes_used] AS sysname) + N') ]' + @crlf
		+ @crlf
        + @tab + N'STATEMENT' + @crlf + @crlf
		+ @tab + @tab + REPLACE(s.[statement], @crlf, @crlf + @tab + @tab)
	FROM 
		[#LongRunningTransactions] lrt
		LEFT OUTER JOIN ( 
			SELECT 
				x.transaction_id,
				MAX(x.database_id) [database_id], -- max isn''t always logical/best. But with tempdb_enlisted + enlisted_db_count... it''s as good as it gets... 
				SUM(CASE WHEN x.database_id = 2 THEN 1 ELSE 0 END) [tempdb_enlisted],
				COUNT(x.database_id) [enlisted_db_count],
				MAX(x.[database_transaction_log_record_count]) [log_record_count],
				MAX(x.[database_transaction_log_bytes_used]) [log_bytes_used]
			FROM 
				sys.[dm_tran_database_transactions] x WITH(NOLOCK)
			GROUP BY 
				x.transaction_id
		) dtdt ON lrt.[transaction_id] = dtdt.[transaction_id]
		LEFT OUTER JOIN [#Statements] s ON lrt.[session_id] = s.[session_id]

	IF @PrintOnly = 1 BEGIN 
		PRINT @messageBody;
	  END;
	ELSE BEGIN 

		DECLARE @message nvarchar(MAX) = N'The following long-running transactions (and associated) details were found - which exceed the @AlertThreshold of ['  + @AlertThreshold + N'.' + @crlf
			+ @tab + N'(Details about how to resolve/address potential problems follow AFTER identified long-running transactions.)' + @crlf 
			+ @messageBody 
			+ @crlf 
			+ @crlf 
			+ @line + @crlf
			+ @line + @crlf 
			+ @tab + N'to ... resolve... look at running KILL(xxx) where xxx = session_id of the query that is long-running. you MAY wish to verify that the query is still running first by means of executing admindb.dbo.list_transactions - and has the same spid, etc. [TODO: make this easier to follow and simple to address/etc.'
			+ @crlf + @crlf
			+ @tab + N'if you are unable to find a specific spid to kill and/or want to simply attempt a ''nuclear option'' with a rollback, execute ALTER DATABASE [dbname] SET SINGLE_USER WITH ROLLBACK AFTER 10 SECONDS; NOTE that this will require the long-running tx to rollback - which can take a long time, etc. '

		DECLARE @subject nvarchar(200); 
		DECLARE @txCount int; 
		SET @txCount = (SELECT COUNT(*) FROM [#LongRunningTransactions]); 

		SET @subject = @EmailSubjectPrefix + 'Long-Running Transaction Detected';
		IF @txCount > 1 SET @subject = @EmailSubjectPrefix + CAST(@txCount AS sysname) + ' Long-Running Transactions Detected';

		EXEC msdb..sp_notify_operator
			@profile_name = @MailProfileName,
			@name = @OperatorName,
			@subject = @subject, 
			@body = @message;
	END;

	RETURN 0;
GO

