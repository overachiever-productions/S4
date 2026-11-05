/*

	DEFINITIONS: 
		- A 'TRUE ZOMBIE' is a session that ... 
			these are FAIRLY rare and typically (not always) caused by both a) bad code, and b) specifically (what makes the code bad-ish) is XACT_ABORT ON... 
		- BUT, while the above can/will block the snot out stuff... 
			sessions with OPEN transactions that haven't DONE anything in a long time (i.e., just sitting with OPEN transactions) are also a problem 
				and can cause major problems. These 'zombie-like' sessions are also WAY more common. 

		Finally, there's no true/viable way to distinguish between true zombies vs zombie-like operations. 
		So .. this diagnostic returns anything that has the SYMPTOMs of a zombie (which are the same symptoms of zombie-like operations).


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[zombie_transactions]', N'P') IS NOT NULL
	DROP PROC dbo.[zombie_transactions];
GO

CREATE PROC dbo.[zombie_transactions]
	@idle_threshold					sysname				= N'90 seconds',
	@sort_by						sysname				= N'IDLE',						-- IDLE | SESSION_ID | LOG_USED					
	@serialized_output				xml					= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @idle_threshold = ISNULL(NULLIF(@idle_threshold, N''), N'90 seconds');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predicates:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @idleThresholdMilliseconds bigint = -1, @vectorError nvarchar(MAX);

	IF @idle_threshold IS NOT NULL BEGIN 
		EXEC admindb.dbo.[translate_vector]
			@Vector = @idle_threshold,
			@ValidationParameterName = N'@IdleThreshold',
			@Output = @idleThresholdMilliseconds OUTPUT,
			@Error = @vectorError OUTPUT; 

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1);
			RETURN -10;  
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Identify Potential Zombie-Like Sessions:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT
		[s].[session_id],
		[s].[login_name],
		[s].[host_name],
		[s].[program_name],
		[s].[status], 
		[s].[open_transaction_count] [open_transactions],
		DATEDIFF_BIG(MILLISECOND, [s].[last_request_end_time], GETDATE()) [idle_milliseconds],
		[at].[transaction_id] [tx_id],
		[at].[name] [tx_name],
		[at].[transaction_begin_time] [tx_start],
		CASE [at].[transaction_state]
			WHEN 0 THEN 'Not fully initialized'
			WHEN 1 THEN 'Initialized but not started'
			WHEN 2 THEN 'Active'
			WHEN 3 THEN 'Ended (Read-only)'
			WHEN 4 THEN 'Commit initiated'
			WHEN 5 THEN 'Commit - Awaiting Resolution'
			WHEN 6 THEN 'Committed'
			WHEN 7 THEN 'Rollback - Started'
			WHEN 8 THEN 'Rollback - Completed'
			ELSE 'Unknown'
		END AS [transaction_state],
		[s].[database_id],
		[i].[event_info] [last_statement]
	INTO 
		#potential_zombies
	FROM
		[sys].[dm_exec_sessions] [s]
		INNER JOIN [sys].[dm_tran_session_transactions] [st] ON [st].[session_id] = [s].[session_id]
		INNER JOIN [sys].[dm_tran_active_transactions] [at] ON [at].[transaction_id] = [st].[transaction_id]
		OUTER APPLY [sys].[dm_exec_input_buffer]([s].[session_id], NULL) [i]
	WHERE
		[s].[is_user_process] = 1 
		AND [s].[open_transaction_count] > 0 
		AND [s].[status] = N'sleeping' 
		AND NOT EXISTS (SELECT NULL FROM [sys].[dm_exec_requests] [r] WHERE [r].[session_id] = [s].[session_id])
		AND DATEDIFF_BIG(MILLISECOND, [s].[last_request_end_time], GETUTCDATE()) > @idleThresholdMilliseconds
	ORDER BY
		[at].[transaction_begin_time];

	IF NOT EXISTS (SELECT 1 FROM #potential_zombies)
		RETURN 0;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Identify Locked Resources held by zombie-like sessions:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT
		[l].[request_session_id] [session_id],
		[l].[resource_type] + CASE WHEN [resource_subtype] <> N'' THEN N' - ' + [resource_subtype] ELSE N'' END  [resource_type],
		[l].[resource_database_id] [database_id],
		[l].[request_mode],
		[l].[request_status],
		[l].[request_owner_type], 
		COUNT(*) [count]
	INTO 
		#zombie_resources 
	FROM
		[sys].[dm_tran_locks] [l]
	GROUP BY 
		[l].[request_session_id],
		[l].[resource_type],
		[l].[resource_subtype],
		[l].[resource_database_id],
		[l].[request_mode],
		[l].[request_status],
		[l].[request_owner_type];

	WITH aggregated AS ( 
		SELECT 
			[session_id],
			[database_id]
		FROM 
			[#zombie_resources] 
		GROUP BY 
			[session_id], 
			[database_id]
	)

	SELECT 
		[session_id], 
		STRING_AGG(DB_NAME([database_id]), N', ') WITHIN GROUP (ORDER BY [database_id]) [databases] 
	INTO 
		#databases_by_session
	FROM 
		aggregated 
	GROUP BY 
		[session_id];

	WITH [session] AS ( 
		SELECT [session_id], STRING_AGG(DB_NAME([database_id]), N', ') WITHIN GROUP (ORDER BY [database_id]) [databases] FROM #zombie_resources GROUP BY [session_id]
	), 
	[session_db] AS ( 
		SELECT [session_id], [database_id] FROM #zombie_resources GROUP BY [session_id], [database_id]
	) 

	SELECT 
		[session_id],
		(
			SELECT 
				DB_NAME([database_id]) [@database], 
				(
					SELECT 
						CAST([dt].[database_transaction_log_bytes_used] / 1024. AS decimal(10,2)) 
					FROM 
						[sys].[dm_tran_session_transactions] [st] 
						INNER JOIN [sys].[dm_tran_active_transactions] [at] ON [at].[transaction_id] = [st].[transaction_id] 
						INNER JOIN [sys].[dm_tran_database_transactions] [dt] ON [dt].[transaction_id] = [at].[transaction_id]
					WHERE 
						[st].[session_id] = [mid].[session_id]
						AND dt.database_id = [mid].[database_id]
				) [@log_kb_used],
				(
					SELECT 
						[resource_type] [@resource_type],
						[request_mode] [@request_mode],
						[request_status] [@request_status],
						[request_owner_type] [@request_owner_type],
						[count] [@count]
					FROM 
						#zombie_resources [inner]
					WHERE 
						[mid].[session_id] = [inner].[session_id]
						AND [mid].[database_id] = [inner].[database_id]	
					FOR XML PATH(N'resource'), TYPE
				)
			FROM 
				session_db [mid] 
			WHERE
				[mid].[session_id] = [session].[session_id]

			FOR XML PATH(N'database'), ROOT(N'databases'), TYPE
		) [resources]
	INTO 
		#resources_xml
	FROM 
		[session];

/*---------------------------------------------------------------------------------------------------------------------------------------------------
-- Get-Tempdb (LOG) usage for all sessions: 
---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT
		[st].[session_id],
		--[at].[name] [tran_name],
		[dt].[database_transaction_log_record_count] [record_count],
		CAST([dt].[database_transaction_log_bytes_used] / 1048576. AS decimal(12, 2)) [log_used_mb],
		CAST([dt].[database_transaction_log_bytes_reserved] / 1048576. AS decimal(12, 2)) [log_reserved_mb]
	INTO 
		#log_usage
	FROM
		[tempdb].[sys].[dm_tran_database_transactions] [dt]
		INNER JOIN [tempdb].[sys].[dm_tran_active_transactions] [at] ON [at].[transaction_id] = [dt].[transaction_id]
		LEFT OUTER JOIN [tempdb].[sys].[dm_tran_session_transactions] [st] ON [st].[transaction_id] = [dt].[transaction_id]
	WHERE
		[dt].[database_id] = 2 AND [st].[session_id] IS NOT NULL
	ORDER BY
		[dt].[database_transaction_log_bytes_used] + [dt].[database_transaction_log_bytes_reserved] DESC;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Intermediate Results + Checks for Missing [statement]:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT
		[z].[session_id],
		[d].[databases],
		[z].[login_name] [principal],
		[z].[host_name] [host],
		(SELECT [e].[client_net_address] FROM sys.[dm_exec_connections] [e] WHERE [z].[session_id] = [e].[session_id] AND [e].[parent_connection_id] IS NULL) [ip],
		[z].[program_name] [application],
		[z].[status],
		(SELECT COUNT(*) FROM sys.[dm_exec_connections] [e] WHERE [z].[session_id] = [e].[session_id]) [session_conn_count], /* Good ol' MARS (sigh) */
		(SELECT SUM([open_transactions]) FROM [#potential_zombies] [z2] WHERE [z2].[session_id] = [z].[session_id]) [open_tx_count],
		[dbo].[format_timespan]([z].[idle_milliseconds]) [idle_time],
		[z].[idle_milliseconds],
		[z].[tx_id],
		[l].[record_count],
		[l].[log_used_mb],
		[l].[log_reserved_mb],
		[x].[resources],
		[z].[tx_name],
		[z].[tx_start],
		[z].[transaction_state],
		[z].[database_id],
		[z].[last_statement] [statement]
	INTO 
		#intermediate
	FROM
		[#potential_zombies] [z]
		INNER JOIN #databases_by_session [d] ON [z].[session_id] = [d].[session_id]
		INNER JOIN [#resources_xml] [x] ON [z].[session_id] = [x].[session_id]
		LEFT OUTER JOIN [#log_usage] [l] ON [z].[session_id] = [l].[session_id]
	ORDER BY
		[z].[session_id];

	UPDATE
		[x]
	SET
		[x].[statement] = COALESCE([t].[text], N'  [SqlHandle: ' + CONVERT(sysname, ISNULL([e].[most_recent_sql_handle], 0), 1)) + N']'
	FROM
		[sys].[dm_exec_connections] [e]
		INNER JOIN [#intermediate] [x] ON [e].[session_id] = [x].[session_id]
		OUTER APPLY [sys].dm_exec_sql_text([e].[most_recent_sql_handle]) [t]
	WHERE
		[x].[statement] IS NULL AND [e].[parent_connection_id] IS NOT NULL;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Project or Return:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF dbo.is_xml_empty(@serialized_output) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				[session_id],
				[databases],
				[principal],
				[host],
				[ip],
				[application],
				[status],
				[session_conn_count]
				[open_tx_count],
				[idle_time],
				[resources],
				[tx_name],
				[tx_start],
				[transaction_state],
				REPLACE([statement] COLLATE Latin1_General_BIN, char(0x0), N'') [statement]
			FROM
				#intermediate
			FOR XML PATH(N'session'), ROOT(N'zombie_transactions'), TYPE
		);
		RETURN 0;
	END;

	SELECT 
		[session_id],
		[databases],
		[principal],
		[application],
		[status],
		[transaction_state] [tx_state],
		[tx_name],
		[idle_time],
		[session_conn_count],
		[open_tx_count],
		[record_count],
		[log_used_mb],
		[log_reserved_mb],
		[resources],
		[tx_start],
		[host],
		[ip],
		[statement]
	FROM
		#intermediate
	ORDER BY 
		[idle_milliseconds] DESC;

	RETURN 0;
GO