/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_versionstore_transactions','P') IS NOT NULL
	DROP PROC dbo.[list_versionstore_transactions];
GO

CREATE PROC dbo.[list_versionstore_transactions]

AS
    SET NOCOUNT ON; 

	-- {copyright}
	SELECT 
		[v].[session_id],
		CASE 
			WHEN [v].[elapsed_time_seconds] > 1209600 THEN N'> 2 weeks'
			ELSE dbo.[format_timespan]([v].[elapsed_time_seconds] * 1000)
		END [duration],
		[v].[elapsed_time_seconds],
		N'' [ ],
		[v].[transaction_id] [tx_id],
		[s].[is_user_transaction] [is_user_tx],
		[s].[open_transaction_count] [open_tx_count],
		CASE 
			WHEN [v].[transaction_sequence_num] IS NULL THEN N'non-snapshot'
			ELSE CASE [v].[is_snapshot]
				WHEN 0 THEN N'statement (RCSI)'
				WHEN 1 THEN N'transaction (SI)'
			END
		END [scope],
		CASE [a].[transaction_state]
			WHEN 1 THEN N'initializing'
			WHEN 2 THEN N'initialized'
			WHEN 3 THEN N'active'
			WHEN 4 THEN N'ended (read-only)'
			WHEN 5 THEN N'resolving'
			WHEN 6 THEN N'committed'
			WHEN 7 THEN N'rolling-back'
			WHEN 8 THEN N'rolled-back'
		END [state],		
		[a].[name],
		CASE [a].[transaction_type] 
			WHEN 1 THEN N'read/write'
			WHEN 2 THEN N'read-only' 
			WHEN 3 THEN N'system'
			WHEN 4 THEN N'distributed'
		END [tx_type],
		[s].[enlist_count] [request_count]
	INTO 
		#core
	FROM 
		sys.[dm_tran_active_snapshot_database_transactions] [v] 
		LEFT OUTER JOIN sys.[dm_tran_active_transactions] [a] ON [v].[transaction_id] = [a].[transaction_id] 
		LEFT OUTER JOIN sys.[dm_tran_session_transactions] [s] ON [v].[session_id] = [s].[session_id]
	ORDER BY 
		[v].[elapsed_time_seconds] DESC;

	SELECT 
		session_id, 
		CAST(N'<timeout>' AS nvarchar(MAX)) [statement], 
		CAST(NULL AS xml) [plan]
	INTO 
		#details
	FROM 
		[#core];

	-- TODO: implement non-blocking logic for below (i.e., will need to do a cursor, with LOCK_TIMEOUT per each row/entry... as per S4-151). 
	-- NOTE: the implementation below is a hack (it's clean/simple - but WILL block and does EVERYTHING in a single 'gulp'). 
	UPDATE x 
	SET 
		x.[statement] = t.[text], 
		x.[plan] = p.[query_plan]
	FROM 
		[#details] x 
		LEFT OUTER JOIN sys.[dm_exec_requests] r ON [x].[session_id] = [r].[session_id]  
		OUTER APPLY sys.[dm_exec_sql_text](r.[plan_handle]) t
		OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) p
	WHERE 
		x.[statement] = N'<timeout>';

	-- this is sort of a hack/bypass of the above ... but it's also separate from the above too - in the sense that the HACK/NOTE above is about LOCKING/BLOCKING
	-- whereas.. this bit of logic is focused more on situations where a transaction does NOT have an active request (i.e., a zombie). 
	UPDATE x 
	SET 
		x.[statement] = N'BUFFER:: ' + b.[event_info]
	FROM 
		[#details] x 
		OUTER APPLY sys.[dm_exec_input_buffer](x.[session_id], NULL) b
	WHERE 
		x.[statement] IS NULL;

	-- TODO: look at providing a link/reference/update to 'last_plan' for rows in #detail where plan IS NULL. 
	--		can't remember if there is such a thing (but there might, actually, be one in sys.sysprocesses? )

	SELECT 
		[c].[session_id],
		[c].[duration],
		[c].[ ],
		[c].[tx_id],
		[c].[is_user_tx],
		[c].[open_tx_count],
		[c].[scope],
		[c].[state],
		[c].[name],
		[c].[tx_type],
		[c].[request_count], 
		N' ' [_], 
		[d].[statement],
		[d].[plan]
	FROM 
		[#core] [c] 
		INNER JOIN [#details] [d] ON [c].[session_id] = [d].[session_id] 
	ORDER BY 
		[c].[elapsed_time_seconds] DESC;

