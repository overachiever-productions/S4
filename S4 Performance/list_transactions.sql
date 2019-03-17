/*
	
	vNEXT:
		-- add lock_timeout and deadlock_priority from sys.dm_exec_requests... 
		-- extrapolate waits on any blocking threads.... 
		

	NEED to Document that is_user_transaction isn't the same as is_user_connection/session
		instead, this column (is_user_tx) tells us WHO or WHAT initiated the tx - user or ... system (implicit)

		at which point... maybe I just specify [transaction_type] of implicit | explicit


EXEC dbo.list_transactions 
	@TopNRows = -1, 
	@OrderBy = 'DURATION', 
	@IncludePlans = 1, 
	@IncludeStatements = 1, 
	@ExcludeSelf = 1, 
	@ExcludeSystemProcesses = 1;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_transactions','P') IS NOT NULL
	DROP PROC dbo.list_transactions;
GO

CREATE PROC dbo.list_transactions 
	@TopNRows						int			= -1, 
	@OrderBy						sysname		= N'DURATION',  -- DURATION | LOG_COUNT | LOG_SIZE   
	@ExcludeSystemProcesses			bit			= 0, 
	@ExcludeSelf					bit			= 1, 
	@IncludeContext					bit			= 1,	
	@IncludeStatements				bit			= 0, 
	@IncludePlans					bit			= 0, 
	@IncludeBoundSessions			bit			= 0, -- seriously, i bet .00x% of transactions would ever even use this - IF that ... 
	@IncludeDTCDetails				bit			= 0, 
	@IncludeLockedResources			bit			= 1, 
	@IncludeVersionStoreDetails		bit			= 0
AS
	SET NOCOUNT ON;

	-- {copyright}

	CREATE TABLE #core (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[session_id] int NOT NULL,
		[transaction_id] bigint NULL,
		[database_id] int NULL,
		[duration] int NULL,
		[enlisted_db_count] int NULL, 
		[tempdb_enlisted] bit NULL,
		[transaction_type] sysname NULL,
		[transaction_state] sysname NULL,
		[enlist_count] int NOT NULL,
		[is_user_transaction] bit NOT NULL,
		[is_local] bit NOT NULL,
		[is_enlisted] bit NOT NULL,
		[is_bound] bit NOT NULL,
		[open_transaction_count] int NOT NULL,
		[log_record_count] bigint NULL,
		[log_bytes_used] bigint NOT NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	SELECT {TOP}
		[dtst].[session_id],
		[dtat].[transaction_id],
		[dtdt].[database_id],
		DATEDIFF(MILLISECOND, [dtdt].[begin_time], GETDATE()) [duration],
		[dtdt].[enlisted_db_count], 
		[dtdt].[tempdb_enlisted],
		CASE [dtat].[transaction_type]
			WHEN 1 THEN ''Read/Write''
			WHEN 2 THEN ''Read-Only''
			WHEN 3 THEN ''System''
			WHEN 4 THEN ''Distributed''
			ELSE ''#Unknown#''
		END [transaction_type],
		CASE [dtat].[transaction_state]
			WHEN 0 THEN ''Initializing''
			WHEN 1 THEN ''Initialized''
			WHEN 2 THEN ''Active''
			WHEN 3 THEN ''Ended (read-only)''
			WHEN 4 THEN ''DTC commit started''
			WHEN 5 THEN ''Awaiting resolution''
			WHEN 6 THEN ''Committed''
			WHEN 7 THEN ''Rolling back...''
			WHEN 8 THEN ''Rolled back''
		END [transaction_state],
		[dtst].[enlist_count], -- # of active requests enlisted... 
		[dtst].[is_user_transaction],
		[dtst].[is_local],
		[dtst].[is_enlisted],
		[dtst].[is_bound],		-- active or not... 
		[dtst].[open_transaction_count], 
		[dtdt].[log_record_count],
		[dtdt].[log_bytes_used]
	FROM 
		sys.[dm_tran_active_transactions] dtat WITH(NOLOCK)
		LEFT OUTER JOIN sys.[dm_tran_session_transactions] dtst WITH(NOLOCK) ON [dtat].[transaction_id] = [dtst].[transaction_id]
		LEFT OUTER JOIN ( 
			SELECT 
				x.transaction_id,
				MAX(x.database_id) [database_id], -- max isn''t always logical/best. But with tempdb_enlisted + enlisted_db_count... it''s as good as it gets... 
				MIN(x.[database_transaction_begin_time]) [begin_time],
				SUM(CASE WHEN x.database_id = 2 THEN 1 ELSE 0 END) [tempdb_enlisted],
				COUNT(x.database_id) [enlisted_db_count],
				MAX(x.[database_transaction_log_record_count]) [log_record_count],
				MAX(x.[database_transaction_log_bytes_used]) [log_bytes_used]
			FROM 
				sys.[dm_tran_database_transactions] x WITH(NOLOCK)
			GROUP BY 
				x.transaction_id
		) dtdt ON [dtat].[transaction_id] = [dtdt].[transaction_id]
	WHERE 
		1 = 1 
		{ExcludeSystemProcesses}
		{ExcludeSelf}
	{OrderBy};';

	-- This is a bit ugly... but works... 
	DECLARE @orderByOrdinal nchar(2) = N'3'; -- duration. 
	IF UPPER(@OrderBy) = N'LOG_COUNT' SET @orderByOrdinal = N'12'; 
	IF UPPER(@OrderBy) = N'LOG_SIZE' SET @orderByOrdinal = N'13';

	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + @orderByOrdinal + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + @orderByOrdinal + N' DESC');
	END; 

	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND dtst.[session_id] > 50 AND [dtst].[is_user_transaction] = 1 AND (dtst.[session_id] NOT IN (SELECT session_id FROM sys.[dm_exec_sessions] WHERE [is_user_process] = 0))  ');
		END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND dtst.[session_id] <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

	INSERT INTO [#core] ([session_id], [transaction_id], [database_id], [duration], [enlisted_db_count], [tempdb_enlisted], [transaction_type], [transaction_state], [enlist_count], 
		[is_user_transaction], [is_local], [is_enlisted], [is_bound], [open_transaction_count], [log_record_count], [log_bytes_used])
	EXEC sys.[sp_executesql] @topSQL;

	CREATE TABLE #handles (
		session_id int NOT NULL, 
		statement_source sysname NOT NULL DEFAULT N'REQUEST',
		statement_handle varbinary(64) NULL, 
		plan_handle varbinary(64) NULL, 
		[status] nvarchar(30) NULL, 
		isolation_level varchar(14) NULL, 
		blocking_session_id int NULL, 
		wait_time int NULL, 
		wait_resource nvarchar(256) NULL, 
		[wait_type] nvarchar(60) NULL,
		last_wait_type nvarchar(60) NULL, 
		cpu_time int NULL, 
		[statement_start_offset] int NULL, 
		[statement_end_offset] int NULL
	);

	CREATE TABLE #statements (
		session_id int NOT NULL,
		statement_source sysname NOT NULL DEFAULT N'REQUEST',
		[statement] nvarchar(MAX) NULL
	);

	CREATE TABLE #plans (
		session_id int NOT NULL,
		query_plan xml NULL
	);

	INSERT INTO [#handles] ([session_id], [statement_handle], [plan_handle], [status], [isolation_level], [blocking_session_id], [wait_time], [wait_resource], [wait_type], [last_wait_type], [cpu_time], [statement_start_offset], [statement_end_offset])
	SELECT 
		c.[session_id], 
		r.[sql_handle] [statement_handle], 
		r.[plan_handle], 
		ISNULL(r.[status], N'Inactive'), 
		CASE r.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
			ELSE NULL
		END isolation_level,
		r.[blocking_session_id], 
		r.[wait_time], 
		r.[wait_resource], 
		r.[wait_type],
		r.[last_wait_type], 
		r.[cpu_time], 
		r.[statement_start_offset], 
		r.[statement_end_offset]
	FROM 
		[#core] c 
		LEFT OUTER JOIN sys.[dm_exec_requests] r WITH(NOLOCK) ON c.[session_id] = r.[session_id];

	UPDATE h
	SET 
		h.[statement_handle] = CAST(p.[sql_handle] AS varbinary(64)), 
		h.[statement_source] = N'SESSION'
	FROM 
		[#handles] h
		LEFT OUTER JOIN sys.[sysprocesses] p ON h.[session_id] = p.[spid] -- AND h.[request_handle] IS NULL don't really think i need this pushed-down predicate... but might be worth a stab... 
	WHERE 
		h.[statement_handle] IS NULL;

	IF @IncludeStatements = 1 OR @IncludeContext = 1 BEGIN
		
		INSERT INTO [#statements] ([session_id], [statement_source], [statement])
		SELECT 
			h.[session_id], 
			h.[statement_source], 
			t.[text] [statement]
		FROM 
			[#handles] h
			OUTER APPLY sys.[dm_exec_sql_text](h.[statement_handle]) t;
	END; 

	IF @IncludePlans = 1 BEGIN

		INSERT INTO [#plans] ([session_id], [query_plan])
		SELECT 
			h.session_id, 
			p.[query_plan]
		FROM 
			[#handles] h 
			OUTER APPLY sys.[dm_exec_query_plan](h.[plan_handle]) p
	END

	-- correlated sub-query:
	DECLARE @lockedResourcesSQL nvarchar(MAX) = N'
		CAST((SELECT 
			--dtl.[resource_type] [@resource_type],
			--dtl.[request_session_id] [@owning_session_id],
			--DB_NAME(dtl.[resource_database_id]) [@database],
			RTRIM(dtl.[resource_type] + N'': '' + CAST(dtl.[resource_database_id] AS sysname) + N'':'' + CASE WHEN dtl.[resource_type] = N''PAGE'' THEN CAST(dtl.[resource_description] AS sysname) ELSE CAST(dtl.[resource_associated_entity_id] AS sysname) END
				+ CASE WHEN dtl.[resource_type] = N''KEY'' THEN N'' '' + CAST(dtl.[resource_description] AS sysname) ELSE '''' END
				+ CASE WHEN dtl.[resource_type] = N''OBJECT'' AND dtl.[resource_lock_partition] <> 0 THEN N'':'' + CAST(dtl.[resource_lock_partition] AS sysname) ELSE '''' 
				END) [resource_identifier], 
			CASE WHEN dtl.resource_type = N''PAGE'' THEN dtl.[resource_associated_entity_id] ELSE NULL END [resource_identifier/@associated_hobt_id],
			dtl.[resource_subtype] [@resource_subtype],
			--dtl.[request_type] [transaction/@request_type],	-- will ALWAYS be ''LOCK''... 
			dtl.[request_mode] [transaction/@request_mode], 
			dtl.[request_status] [transaction/@request_status],
			dtl.[request_reference_count] [transaction/@reference_count],  -- APPROXIMATE (ont definitive).
			dtl.[request_owner_type] [transaction/@owner_type],
			dtl.[request_owner_id] [transaction/@transaction_id],		-- transactionID of the owner... can be ''overloaded'' with negative values (-4 = filetable has a db lock, -3 = filetable has a table lock, other options outlined in BOL).
			x.[waiting_task_address] [waits/waiting_task_address],
			x.[wait_duration_ms] [waits/wait_duration_ms], 
			x.[wait_type] [waits/wait_type],
			x.[blocking_session_id] [waits/blocking/blocking_session_id], 
			x.[blocking_task_address] [waits/blocking/blocking_task_address], 
			x.[resource_description] [waits/blocking/resource_description]
		FROM 
			sys.[dm_tran_locks] dtl WITH(NOLOCK)
			LEFT OUTER JOIN sys.[dm_os_waiting_tasks] x WITH(NOLOCK) ON dtl.[lock_owner_address] = x.[resource_address]
		WHERE 
			dtl.[request_session_id] = c.session_id
		FOR XML PATH (''resource''), ROOT(''locked_resources'')) AS xml) [locked_resources],	';
	
	DECLARE @contextSQL nvarchar(MAX) = N'
CAST((
	SELECT 
		-- transaction
			c2.transaction_id [transaction/@transaction_id], 
			c2.transaction_state [transaction/current_state],
			c2.transaction_type [transaction/transaction_type], 
			h2.isolation_level [transaction/isolation_level], 
			c2.enlist_count [transaction/active_request_count], 
			c2.open_transaction_count [transaction/open_transaction_count], 
		
			-- statement
				h2.statement_source [transaction/statement/statement_source], 
				ISNULL(h2.[statement_start_offset], 0) [transaction/statement/sql_handle/@offset_start], 
				ISNULL(h2.[statement_end_offset], 0) [transaction/statement/sql_handle/@offset_end],
				ISNULL(CONVERT(nvarchar(128), h2.[statement_handle], 1), '''') [transaction/statement/sql_handle], 
				h2.plan_handle [transaction/statement/plan_handle],
				ISNULL(s2.statement, N'''') [transaction/statement/sql_text],
			--/statement

			-- waits
				admindb.dbo.format_timespan(h2.wait_time) [transaction/waits/@wait_time], 
				h2.wait_resource [transaction/waits/wait_resource], 
				h2.wait_type [transaction/waits/wait_type], 
				h2.last_wait_type [transaction/waits/last_wait_type],
			--/waits

			-- databases 
				c2.enlisted_db_count [transaction/databases/enlisted_db_count], 
				c2.tempdb_enlisted [transaction/databases/is_tempdb_enlisted], 
				DB_NAME(c2.database_id) [transaction/databases/primary_db], 
			--/databases
		--/transaction 

		-- time 
			admindb.dbo.format_timespan(h2.cpu_time) [time/cpu_time], 
			admindb.dbo.format_timespan(h2.wait_time) [time/wait_time], 
			admindb.dbo.format_timespan(c2.duration) [time/duration], 
			admindb.dbo.format_timespan(DATEDIFF(MILLISECOND, des2.last_request_start_time, GETDATE())) [time/time_since_last_request_start], 
			ISNULL(CONVERT(sysname, des2.[last_request_start_time], 121), '''') [time/last_request_start]
		--/time
	FROM 
		[#core] c2 
		LEFT OUTER JOIN #handles h2 ON c2.session_id = h2.session_id
		LEFT OUTER JOIN sys.dm_exec_sessions des2 ON c2.session_id = des.session_id
		LEFT OUTER JOIN #statements s2 ON c2.session_id = s2.session_id
	WHERE 
		c2.session_id = c.session_id
		AND h2.session_id = c.session_id 
		AND des2.session_id = c.session_id
		AND s2.session_id = c.session_id
	FOR XML PATH(''''), ROOT(''context'')
	) as xml) [context],	';

	DECLARE @versionStoreSQL nvarchar(MAX) = N'
CAST((
	SELECT 
		[dtvs].[version_sequence_num] [@version_id],
		[dtst].[session_id] [@owner_session_id], 
		[dtvs].[database_id] [versioned_rowset/@database_id],
		[dtvs].[rowset_id] [versioned_rowset/@hobt_id],
		SUM([dtvs].[record_length_first_part_in_bytes]) + SUM([dtvs].[record_length_second_part_in_bytes]) [versioned_rowset/@total_bytes], 
		MAX([dtasdt].[elapsed_time_seconds]) [version_details/@total_seconds_old],
		CASE WHEN MAX(ISNULL([dtasdt].[commit_sequence_num],0)) = 0 THEN 1 ELSE 0 END [version_details/@is_active_transaction],
		MAX(CAST([dtasdt].[is_snapshot] AS tinyint)) [version_details/@is_snapshot],
		MAX([dtasdt].[max_version_chain_traversed]) [version_details/@max_chain_traversed], 
		MAX([dtvs].[status]) [version_details/@using_multipage_storage]
	FROM 
		sys.[dm_tran_session_transactions] dtst
		LEFT OUTER JOIN sys.[dm_tran_locks] dtl ON [dtst].[transaction_id] = dtl.[request_owner_id]
		LEFT OUTER JOIN sys.[dm_tran_version_store] dtvs ON dtl.[resource_database_id] = dtvs.[database_id] AND dtl.[resource_associated_entity_id] = [dtvs].[rowset_id]
		LEFT OUTER JOIN sys.[dm_tran_active_snapshot_database_transactions] dtasdt ON dtst.[session_id] = c.[session_id]
	WHERE 
		dtst.[session_id] = c.[session_id]
		AND [dtvs].[rowset_id] IS NOT NULL
	GROUP BY 
		[dtst].[session_id], [dtvs].[database_id], [dtvs].[rowset_id], [dtvs].[version_sequence_num]
	ORDER BY 
		[dtvs].[version_sequence_num]
	FOR XML PATH(''version''), ROOT(''versions'')
	) as xml) [version_store_data], '

	DECLARE @projectionSQL nvarchar(MAX) = N'
	SELECT 
        [c].[session_id],
		ISNULL([h].blocking_session_id, 0) [blocked_by],
        DB_NAME([c].[database_id]) [database],
        dbo.format_timespan([c].[duration]) [duration],
		h.[status],
		{statement}
		des.[login_name],
		des.[program_name], 
		des.[host_name],
		ISNULL(c.log_record_count, 0) [log_record_count], 
		ISNULL(c.log_bytes_used, 0) [log_bytes_used],
		--N'''' + ISNULL(CAST(c.log_record_count as sysname), ''0'') + N'' - '' + ISNULL(CAST(c.log_bytes_used as sysname),''0'') + N''''		[log_used (count - bytes)],
		{context}
		{locked_resources}
		{version_store}
		{plan}
		{bound}
		CASE WHEN [c].[is_user_transaction] = 1 THEN ''EXPLICIT'' ELSE ''IMPLICIT'' END [transaction_type]
	FROM 
		[#core] c 
		LEFT OUTER JOIN #handles h ON c.session_id = h.session_id
		LEFT OUTER JOIN sys.dm_exec_sessions des ON c.session_id = des.session_id
		{statementJOIN}
		{planJOIN}
	ORDER BY 
		[c].[row_number];';

	IF @IncludeContext = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{context}', @contextSQL);
	  END; 
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{context}', N'');
	END;

	IF @IncludeStatements = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'[s].[statement],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'LEFT OUTER JOIN #statements s ON c.session_id = s.session_id');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'');
	END; 

	IF @IncludePlans = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan}', N'[p].[query_plan],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{planJOIN}', N'LEFT OUTER JOIN #plans p ON c.session_id = p.session_id');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{planJOIN}', N'');
	END;

	IF @IncludeLockedResources = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{locked_resources}', @lockedResourcesSQL);
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{locked_resources}', N'');
	END;

	IF @IncludeVersionStoreDetails = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{version_store}', @versionStoreSQL);
	  END; 
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{version_store}', N'');
	END;

	IF @IncludeBoundSessions = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{bound}', N', [c].[is_bound]');
	  END; 
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{bound}', N'');
	END;

	IF @IncludeDTCDetails = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{dtc}', N'<dtc_detail is_local="'' + ISNULL(CAST(c.is_local as char(1)), ''0'') + N''" is_enlisted="'' + ISNULL(CAST(c.is_enlisted as char(1)), ''0'') + N''" />');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{dtc}', N'');
	END;

--EXEC admindb.dbo.[print_string] @Input = @projectionSQL;
--RETURN;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO