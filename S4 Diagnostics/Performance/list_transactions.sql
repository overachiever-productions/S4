
/*
	
	vNEXT:
		-- add transaction_isolation from sys.dm_exec_requests... (which means I'll query that table for everything ... not just IF @IncludeStatements or @IncludePlans... is set to 1
		-- and add 'status' from ... sys.dm_exec_requests... 




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
			WHEN 0 THEN ''Initializing...''
			WHEN 1 THEN ''Initialized''
			WHEN 2 THEN ''Active...''
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
		plan_handle varbinary(64) NULL
	);

	CREATE TABLE #statements (
		session_id int NOT NULL,
		[statement] nvarchar(MAX) NULL
	);

	CREATE TABLE #plans (
		session_id int NOT NULL,
		query_plan xml NULL
	);

	IF @IncludeStatements = 1 OR @IncludePlans = 1 BEGIN

		INSERT INTO [#handles] ([session_id], [statement_handle], [plan_handle])
		SELECT 
			c.[session_id], 
			r.[sql_handle] [statement_handle], 
			r.[plan_handle]
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
	END;

	IF @IncludeStatements = 1 BEGIN
		
		INSERT INTO [#statements] ([session_id], [statement])
		SELECT 
			h.[session_id], 
			CASE 
				WHEN h.[statement_source] = N'SESSION' THEN N'SESSION::: ' + t.[text]
				ELSE t.[text]
			END [statement]
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
        DB_NAME([c].[database_id]) [database],
        dbo.format_timespan([c].[duration]) [duration],
		[c].[enlisted_db_count],
		[c].[tempdb_enlisted],
		{statement}
        [c].[transaction_type],
        [c].[transaction_state],
        [c].[enlist_count] [active_requests],
        {system}
        [c].[open_transaction_count],
        [c].[log_record_count],
        [c].[log_bytes_used]
		{plan}
		{bound}
		{dtc}
	FROM 
		[#core] c 
		{statementJOIN}
		{planJOIN}
	ORDER BY 
		[c].[row_number];';


	IF @IncludeStatements = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'[s].[statement],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'LEFT OUTER JOIN #statements s ON c.session_id = s.session_id');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statement}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{statementJOIN}', N'');
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
		SET @projectionSQL = REPLACE(@projectionSQL, N'{dtc}', N', [c].[is_local], [c].[is_enlisted]');
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