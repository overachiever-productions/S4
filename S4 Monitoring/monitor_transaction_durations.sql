

/*

	-- TODO: show 'status' of the query - i.e., running, runnable, sleeping, etc..... that info will be CRITICAL in determining what's up... 
	--			so... list that as the first 'metric'... 


*/

USE [admindb];
GO


IF OBJECT_ID('dbo.monitor_transaction_durations','P') IS NOT NULL
	DROP PROC dbo.monitor_transaction_durations;
GO

CREATE PROC dbo.monitor_transaction_durations	
	@ExcludeSystemProcesses				bit					= 1,				
	@ExcludedDatabases					nvarchar(MAX)		= NULL,				-- N'master, msdb'  -- recommended that tempdb NOT be excluded... (long running txes in tempdb are typically going to be a perf issue - typically (but not always).
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

	IF NOT EXISTS(SELECT NULL FROM [#LongRunningTransactions]) 
		RETURN 0;  -- filters removed anything to report on. 

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
		+ '- session_id [' + CAST(lrt.[session_id] AS sysname) + N'] has been running in database ' +  QUOTENAME(DB_NAME([dtdt].[database_id]), N'[]') + N' for a duration of: ' + dbo.[format_timespan](DATEDIFF(MILLISECOND, lrt.[transaction_begin_time], GETDATE())) + N'.' + @crlf 
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

	DECLARE @message nvarchar(MAX) = N'The following long-running transactions (and associated) details were found - which exceed the @AlertThreshold of ['  + @AlertThreshold + N'.' + @crlf
		+ @tab + N'(Details about how to resolve/address potential problems follow AFTER identified long-running transactions.)' + @crlf 
		+ @messageBody 
		+ @crlf 
		+ @crlf 
		+ @line + @crlf
		+ @line + @crlf 
		+ @tab + N'To resolve:  ' + @crlf
		+ @tab + @tab + N'First, execute the following statement against ' + @@SERVERNAME + N' to ensure that the long-running transaction is still causing problems: ' + @crlf
		+ @crlf
		+ @tab + @tab + @tab + @tab + N'EXEC admindb.dbo.list_transactions;' + @crlf 
		+ @crlf 
		+ @tab + @tab + N'If the same session_id is still listed and causing problems, you can attempt to KILL the session in question by running KILL X - where X is the session_id you wish to terminate. (So, if session_id 234 is causing problems, you would execute KILL 234; ' + @crlf 
		+ @tab + @tab + N'WARNING: KILLing an in-flight/long-running transaction is NOT an immediate operation. It typically takes around 75% - 150% of the time a transaction has taken to ''roll-forward'' in order to ''KILL'' or ROLLBACK a long-running operation. ' + @crlf
		+ @tab + @tab + @tab + N'Example: suppose it takes 10 minutes for a long-running transaction (like a large UPDATE or DELETE operation) to complete and/or get stuck - or it has been running for ~10 minutes when you attempt to KILL it.' + @crlf
		+ @tab + @tab + @tab + @tab + N'At this point (i.e., 10 minutes into an active transaction), you should ROUGHLY expect the rollback to take anywhere from 7 - 15 minutes to execute.' + @crlf
		+ @tab + @tab + @tab + @tab + N'NOTE: If a short/simple transaction (like running an UPDATE against a single row) executes and the gets ''orphaned'' (i.e., it somehow gets stuck and/or there was an EXPLICIT BEGIN TRAN and the operation is waiting on an explicit COMMIT), ' + @crlf
		+ @tab + @tab + @tab + @tab + @tab + N'Then, in this case the transactional ''overhead'' should have been minimal - meaning that a KILL operation should be very QUICK and almost immediate - because you are only rolling-back a few milliseconds'' or second''s worth of transactional overhead.' + @crlf 
		+ @tab + @tab + N'Once you KILL a session, the rollback proccess will begin (if there was a transaction in-flight). Keep checking admindb.dbo.list_transactions to see if the session in question is still running - and once it is DONE running blocked processes and other operations SHOULD start to work as normal again.' + @crlf
		+ @tab + @tab + @tab + N'IF you would like to see ROLLBACK process you can run: KILL ### WITH STATUSONLY; and SQL Server will USUALLY (but not always) provide a relatively accurate picture of how far along the rollback is. ' + @crlf 
		+ @crlf
		+ @tab + @tab + N'NOTE: If you are unable to determine the ''root'' blocker and/or are WILLING to effectively take the ENTIRE database ''down'' to fix problems with blocking/time-outs due to long-running transactions, you CAN kick the entire database in question into SINGLE_USER mode thereby forcing all ' + @crlf
		+ @tab + @tab + @tab + N'in-flight transactions to ROLLBACK - at the expense of (effectively) KILLing ALL connections into the database AND preventing new connections.' + @crlf
		+ @tab + @tab + @tab + N'As you might suspect, this is effectively a ''nuclear'' option - and can/will result in across-the-board down-time against the database in question. ' + @crlf
		+ @tab + @tab + @tab + N'WARNING: Knocking a database into SINGLE_USER mode will NOT do ANYTHING to ''speed up'' or decrease ROLLBACK time for any transactions in flight. In fact, because it KILLs ALL transactions in the target database, it can take LONGER in some cases to ''go'' SINGLE_USER mode ' + @crlf
		+ @tab + @tab + @tab + @tab + N'than finding/KILLing a root-blocker. Likewise, taking a database into SINGLE_USER mode is a semi-advanced operation and should NOT be done lightly.' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + N'To force a database into SINGLE_USER mode (and kill all connections/transactions), run the following from within the master database: ' + @crlf
		+ @crlf 
		+ @tab + @tab + @tab + @tab + N'ALTER DATABSE [targetDBNameHere] SET SINGLE_USER WITH ROLLBACK AFTER 5 SECONDS;' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + N'The command above will allow any/all connections and transactions currently active in the target database another 5 seconds to complete - while also blocking any NEW connections into the database. After 5 seconds (and you can obvious set this value as you would like), ' + @crlf
		+ @tab + @tab + @tab + @tab + N'all in-flight transactions will be KILLed and start the ROLLBACK process - and any active connections in the database will also be KILLed and kicked-out of the database in question.' + @crlf
		+ @tab + @tab + @tab + N'WARNING: Once a database has been put into SINGLE_USER mode it can ONLY be accessed by the session that switched the database into SINGLE_USER mode. As such, if you CLOSE your connection/session - ''control'' of the database ''falls'' to the next session that ' + @crlf
		+ @tab + @tab + @tab + @tab + N'accesses the database - and all OTHER connections are blocked - which means that IF you close your connection/session, you will have to ACTIVELY fight other processes for connection into the database before you can set it to MULTI_USER again - and clear it for production use.' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + N'Once a database has been put into SINGLE_USER mode (i.e., after the command has been executed and ALL in-flight transactions have been rolled-back and all connections have been terminated and the state of the database switches to SINGLE_USER mode), any transactional locking and blocking ' + @crlf
		+ @tab + @tab + @tab + @tab + N'in the target database will be corrected. At which point you can then return the database to active service by switching it back to MULTI_USER mode by executing the following: ' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + @tab + @tab + N'ALTER DATABASE [targetDatabaseInSINGLE_USERMode] SET MULTI_USER;' + @crlf 
		+ @crlf 
		+ @tab + @tab + @tab + @tab + N'Note, of course, that the command above can ONLY be executed (without throwing errors) by the session_id that currently ''owns'' the SINGLE_USER access into the database in question.' + @crlf;

	IF @PrintOnly = 1 BEGIN 
		PRINT @message;
	  END;
	ELSE BEGIN 

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
