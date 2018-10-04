
/*
	
	vNEXT:
		-- add lock_timeout and deadlock_priority from sys.dm_exec_requests... 
		


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
	@IncludeStatements				bit			= 0, 
	@IncludePlans					bit			= 0, 
	@ExcludeSystemProcesses			bit			= 0, 
	@ExcludeSelf					bit			= 1, 
	@IncludeBoundSessions			bit			= 0, -- seriously, i bet .00x% of transactions would ever even use this - IF that ... 
	@IncludeDTCDetails				bit			= 0
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	CREATE TABLE #core (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[session_id] int NOT NULL,
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
		[log_record_count] bigint NOT NULL,
		[log_bytes_used] bigint NOT NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	SELECT {TOP}
		[dtst].[session_id],
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
		INNER JOIN sys.[dm_tran_session_transactions] dtst WITH(NOLOCK) ON [dtat].[transaction_id] = [dtst].[transaction_id]
		INNER JOIN ( 
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

--TODO: sys.dm_exec_sessions.is_user_process (and sys.dm_exec_sessions.open_transaction_count - which isn't available in all versions (it's like 2012 or so))... would work for filtering here too.
	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND dtst.session_id > 50 AND [dtst].[is_user_transaction] = 1 ');
		END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND dtst.session_id <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

	--PRINT @topSQL;

	INSERT INTO [#core] ([session_id], [database_id], [duration], [enlisted_db_count], [tempdb_enlisted], [transaction_type], [transaction_state], [enlist_count], 
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
		r.[status], 
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

	IF @IncludeStatements = 1 BEGIN
		
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

	DECLARE @projectionSQL nvarchar(MAX) = N'
	SELECT 
        [c].[session_id],
		ISNULL([h].blocking_session_id, 0) [blocked_by],
        DB_NAME([c].[database_id]) [database],
        dbo.format_timespan([c].[duration]) [duration],
		h.[status],
		{statement}
		CAST((''<context>
			<transaction>
				<current_state>'' + ISNULL(c.transaction_state,'''') + N''</current_state>
				<isolation_level>'' + ISNULL(h.isolation_level, '''') + N''</isolation_level>
				<active_request_count>'' + ISNULL(CAST(c.enlist_count as sysname), ''0'') + N''</active_request_count>
				<open_transaction_count>'' + ISNULL(CAST(c.open_transaction_count as sysname), ''0'') + N''</open_transaction_count>
				{dtc}
				<statement>
					<sql_statement_source>'' + ISNULL(h.statement_source, '''') + N''</sql_statement_source>
					<sql_handle offset_start="'' + CAST(ISNULL(h.[statement_start_offset], 0) as sysname) + N''" offset_end="'' + CAST(ISNULL(h.[statement_end_offset], 0) as sysname) + N''">'' + ISNULL(CONVERT(nvarchar(128), h.[statement_handle], 1), '''') + N''</sql_handle>
					<plan_handle>'' + ISNULL(CONVERT(nvarchar(128), h.[plan_handle], 1), '''') + N''</plan_handle>
					{statementXML}
				</statement>
				<waits>
					<wait_time>'' + dbo.format_timespan(h.wait_time) + N''</wait_time>
					<wait_resource>'' + ISNULL([h].[wait_resource], '''') + N''</wait_resource>
					<wait_type>'' + ISNULL([h].[wait_type], '''') + N''</wait_type>
					<last_wait_type>'' + ISNULL([h].[last_wait_type], '''') + N''</last_wait_type>
				</waits>
				<databases>
					<enlisted_db_count>'' + CAST(c.enlisted_db_count AS sysname) + N''</enlisted_db_count>
					<is_tempdb_enlisted>'' + CAST(c.tempdb_enlisted as char(1)) + N''</is_tempdb_enlisted>
					<primary_db>'' + ISNULL(DB_NAME([c].[database_id]), '''') + N''</primary_db>
				</databases>
			</transaction>
			<time>
				<cpu_time>'' + dbo.format_timespan([h].cpu_time) + N''</cpu_time>
				<duration>'' + dbo.format_timespan([c].[duration]) + N''</duration>
				<wait_time>'' + dbo.format_timespan([h].wait_time) + N''</wait_time>
				<time_since_session_last_request_start>'' + dbo.format_timespan(DATEDIFF(MILLISECOND, des.last_request_start_time, GETDATE())) + N''</time_since_session_last_request_start>
				<last_session_request_start>'' + ISNULL(CONVERT(sysname, des.[last_request_start_time], 121), '''') + N''</last_session_request_start>
			</time>
			<connection>
				<login_name>'' + ISNULL(des.[login_name], '''') + N''</login_name>
				<program_name>'' + ISNULL(des.[program_name], '''') + N''</program_name>
				<host_name>'' + ISNULL(des.[host_name], '''') + N''</host_name>
			</connection>
		</context>'') as xml) [context],
		{system}
		N'''' + ISNULL(CAST(c.log_record_count as sysname), ''0'') + N'' - '' + ISNULL(CAST(c.log_bytes_used as sysname),''0'') + N''''		[log_used (count - bytes)]
		{plan}
		{bound}
	FROM 
		[#core] c 
		LEFT OUTER JOIN #handles h ON c.session_id = h.session_id
		LEFT OUTER JOIN sys.dm_exec_sessions des ON c.session_id = des.session_id
		{statementJOIN}
		{planJOIN}
	ORDER BY 
		[c].[row_number];';


	IF @IncludeStatements = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'[s].[statement],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'LEFT OUTER JOIN #statements s ON c.session_id = s.session_id');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementXML}', N'<text>'' + (SELECT ISNULL([s].[statement], '''') FOR XML PATH('''')) + N''</text>');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementXML}', N'');
	END; 

	IF @IncludePlans = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan}', N', [p].[query_plan]');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{planJOIN}', N'LEFT OUTER JOIN #plans p ON c.session_id = p.session_id');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{planJOIN}', N'');
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


	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{system}', N'');
	  END;
	ELSE BEGIN -- include system processes (and show diff between system and user)
		SET @projectionSQL = REPLACE(@projectionSQL, N'{system}', N'[c].[is_user_transaction],');
	END; 



--PRINT @projectionSQL;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO