

/*


-- TODO: Parameter Validation.... 
-- TODO: test change to N'ORDER BY ' + LOWER(@OrderBy) + N' DESC' in @topSQL for IF @topRows > 0... 
--			pretty sure those changes make sense - but need to verify.

-- TODO: verify that aliased column ORDER BY operations work in versions of SQL Server prior to 2016... 

-- vNEXT: thread count column... (MIGHT make sense to make it optional... might make sense to just ALWAYS include it).
-- vNEXT: batch vs statement plans/text (i.e., offsets and the likes). 
-- vNEXT: detailed blocking info... (blocking chains if @DetailedBlockingInfo = 1 (expressed as xml)... 
-- vNEXT: temddb info (spills, usage, overhead, etc). 
-- vNEXT: exclude service broker tasks (background tasks)... i..e, where Command = BRKR TASK and last_wait_type = 'sleep_task' and elapsed_time < 0 (i.e., huge negative #s) and ... text = NULL... 
-- other wait types and so on... 



EXEC admindb.dbo.[list_processes]
    @TopNRows = 20,			-- > 0 = SELECT TOP... otherwise ALL rows... 
    @OrderBy = N'CPU',  -- CPU | READS | WRITES | DURATION | MEMORY
    @IncludePlanHandle = 1,
    @IncludeIsolationLevel = 0,
	@ExcludeFTSDaemonProcesses = 1,
    @ExcludeSystemProcesses = 1, 
    @ExcludeSelf = 1;


*/


USE [admindb];
GO


IF OBJECT_ID('dbo.list_processes','P') IS NOT NULL
	DROP PROC dbo.list_processes;
GO

CREATE PROC dbo.list_processes 
	@TopNRows								int			=	-1,		-- TOP is only used if @TopNRows > 0. 
	@OrderBy								sysname		= N'CPU',	-- CPU | DURATION | READS | WRITES | MEMORY
	@IncludePlanHandle						bit			= 1,	
	@ExtractExecutionCost					bit			= 0,	
	@IncludeIsolationLevel					bit			= 0,
	@ExecutionDetails						bit			= 1,		
	-- vNEXT				--@ShowBatchStatement					bit			= 0,		-- show outer statement if possible...
	-- vNEXT				---@ShowBatchPlan						bit			= 0,		-- grab a parent plan if there is one... 	
	-- vNEXT				--@DetailedBlockingInfo					bit			= 0,		-- xml 'blocking chain' and stuff... 
	@DetailedMemoryStats					bit			= 0,		-- show grant info... 
	-- vNEXT				--@DetailedTempDbStats					bit			= 0,		-- pull info about tempdb usage by session and such... 
	@ExcludeMirroringWaits					bit			= 1,		-- optional 'ignore' wait types/families.
	@ExcludeNegativeDurations				bit			= 1,		-- exclude service broker and some other system-level operations/etc. 
	-- vNEXT				--@ExcludeSOmeOtherSetOfWaitTypes		bit			= 1			-- ditto... 
	@ExcludeFTSDaemonProcesses				bit			= 1,
	@ExcludeSystemProcesses					bit			= 1,			-- spids < 50... 
	@ExcludeSelf							bit			= 1
AS 
	SET NOCOUNT ON; 

	CREATE TABLE #ranked (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[session_id] smallint NOT NULL,
		[cpu] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[duration] int NOT NULL,
		[memory] decimal(20,2) NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	SELECT {TOP}
		r.[session_id], 
		r.[cpu_time] [cpu], 
		r.[reads], 
		r.[writes], 
		r.[total_elapsed_time] [duration],
		ISNULL(CAST((g.granted_memory_kb / 1024.0) as decimal(20,2)),0) AS [memory]
	FROM 
		sys.[dm_exec_requests] r
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
	WHERE
		r.last_wait_type NOT IN(''BROKER_TO_FLUSH'',''HADR_FILESTREAM_IOMGR_IOCOMPLETION'', ''BROKER_EVENTHANDLER'', ''BROKER_TRANSMITTER'',''BROKER_TASK_STOP'', ''MISCELLANEOUS'' {ExcludeMirroringWaits} {ExcludeFTSWAITs} )
		{ExcludeSystemProcesses}
		{ExcludeSelf}
		{ExcludeNegative}
		{ExcludeFTS}
	{OrderBy};';

-- TODO: verify that aliased column ORDER BY operations work in versions of SQL Server prior to 2016... 
	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + LOWER(@OrderBy) + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + LOWER(@OrderBy) + N' DESC');
	END; 
		
	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND r.session_id > 50 ');
		END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'');
	END;

	IF @ExcludeMirroringWaits = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N',''DBMIRRORING_CMD'',''DBMIRROR_EVENTS_QUEUE'', ''DBMIRROR_WORKER_QUEUE''');
		END;
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND r.session_id <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

	IF @ExcludeNegativeDurations = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'AND r.total_elapsed_time > 0 ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'');
	END; 

	IF @ExcludeFTSDaemonProcesses = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWAITs}', N', ''FT_COMPROWSET_RWLOCK'', ''FT_IFTS_RWLOCK'', ''FT_IFTS_SCHEDULER_IDLE_WAIT'', ''FT_IFTSHC_MUTEX'', ''FT_IFTSISM_MUTEX'', ''FT_MASTER_MERGE'', ''FULLTEXT GATHERER'' ');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'AND r.command NOT LIKE ''FT%'' ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWAITs}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'');
	END; 


--PRINT @topSQL;

	INSERT INTO [#ranked] ([session_id], [cpu], [reads], [writes], [duration], [memory])
	EXEC sys.[sp_executesql] @topSQL; 

	CREATE TABLE #detail (
		[row_number] int NOT NULL,
		[session_id] smallint NOT NULL,
		[blocked_by] smallint NULL,
		[isolation_level] varchar(14) NULL,
		[status] nvarchar(30) NOT NULL,
		[last_wait_type] nvarchar(60) NOT NULL,
		[command] nvarchar(32) NOT NULL,
		[granted_mb] decimal(20,2) NOT NULL,
		[requested_mb] decimal(20,2) NOT NULL,
		[ideal_mb] decimal(20,2) NOT NULL,
		[text] nvarchar(max) NULL,
		[cpu_time] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[elapsed_time] int NOT NULL,
		[wait_time] int NOT NULL,
		[db_name] sysname NULL,
		[login_name] sysname NULL,
		[program_name] sysname NULL,
		[host_name] sysname NULL,
		[percent_complete] real NOT NULL,
		[open_tran] int NOT NULL,
		[sql_handle] varbinary(64) NULL,
		[plan_handle] varbinary(64) NULL
	);

	INSERT INTO [#detail] ([row_number], [session_id], [blocked_by], [isolation_level], [status], [last_wait_type], [command], [granted_mb], [requested_mb], [ideal_mb], 
		 [cpu_time], [reads], [writes], [elapsed_time], [wait_time], [db_name], [login_name], [program_name], [host_name], [percent_complete], [open_tran], [sql_handle], [plan_handle])
	SELECT
		x.[row_number],
		r.session_id, 
		r.blocking_session_id [blocked_by],
		CASE s.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
		END isolation_level,
		r.[status],
		r.last_wait_type,
		r.command, 
		x.[memory] [granted_mb],
		ISNULL(CAST((g.requested_memory_kb / 1024.0) as decimal(20,2)),0) AS requested_mb,
		ISNULL(CAST((g.ideal_memory_kb  / 1024.0) as decimal(20,2)),0) AS ideal_mb,	
		--t.[text],
		x.[cpu] [cpu_time],
		x.reads,
		x.writes,
		x.[duration] [elapsed_time],
		r.wait_time,
		DB_NAME(r.database_id) [db_name],
		s.[login_name],
		s.[program_name],
		s.[host_name],
		r.percent_complete,
		r.open_transaction_count [open_tran],
		r.[sql_handle],
		r.plan_handle
	FROM 
		sys.dm_exec_requests r
		INNER JOIN [#ranked] x ON r.[session_id] = x.[session_id]
		INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
	ORDER BY 
		x.[row_number]; 


	DECLARE @projectionSQL nvarchar(MAX) = N'
	SELECT 
		d.[session_id],
		d.[blocked_by],  -- vNext: this is either blocked_by or blocking_chain - which will be xml.. 
		{isolation_level}
		d.[command], 
		d.[status],
		d.[last_wait_type],
		{memory}
		t.[text],  -- statement_text?
		--{batch_text} ??? 
		d.[cpu_time],
		d.[reads],
		d.[writes], 
		CASE WHEN d.[elapsed_time] < 0 
			THEN N''-'' + RIGHT(''000'' + CAST([wait_time] / 3600000 as sysname), 3) + N'':'' + RIGHT(''00'' + CAST(([wait_time] / (60000) % 60) AS sysname), 2) + N'':'' + RIGHT(''00'' + CAST((([wait_time] / 1000) % 60) AS sysname), 2) + N''.'' + RIGHT(''000'' + CAST(([wait_time]) AS sysname), 3)
			ELSE RIGHT(''000'' + CAST([wait_time] / 3600000 as sysname), 3) + N'':'' + RIGHT(''00'' + CAST(([wait_time] / (60000) % 60) AS sysname), 2) + N'':'' + RIGHT(''00'' + CAST((([wait_time] / 1000) % 60) AS sysname), 2) + N''.'' + RIGHT(''000'' + CAST(([wait_time]) AS sysname), 3) 
		END [elapsed_time],
		RIGHT(''000'' + CAST([wait_time] / 3600000 as sysname), 3) + N'':'' + RIGHT(''00'' + CAST(([wait_time] / (60000) % 60) AS sysname), 2) + N'':'' + RIGHT(''00'' + CAST((([wait_time] / 1000) % 60) AS sysname), 2) + N''.'' + RIGHT(''000'' + CAST(([wait_time]) AS sysname), 3) [wait_time],
		d.[db_name],
		d.[login_name],
		d.[program_name],
		d.[host_name],
		{executionDetails}
		{plan_handle}
		--{extractCost}
		p.query_plan [batch_plan]
		--,{statement_plan} -- if i can get this working... 
	FROM 
		[#detail] d
		OUTER APPLY sys.dm_exec_sql_text(d.sql_handle) t
		OUTER APPLY sys.dm_exec_query_plan(d.plan_handle) p
	ORDER BY
		[row_number];'

	IF @IncludeIsolationLevel = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'd.[isolation_level],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'');
	END;

	IF @DetailedMemoryStats = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'd.[granted_mb], d.[requested_mb], d.[ideal_mb],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'd.[granted_mb],');
	END; 

	IF @ExecutionDetails = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{executionDetails}', N'd.[percent_complete], d.[open_tran], (SELECT COUNT(x.session_id) FROM sys.dm_os_waiting_tasks x WHERE x.session_id = d.session_id) [thread_count],');
	  END;
	ELSE BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{executionDetails}', N'');
	END;

	IF @IncludePlanHandle = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'd.[plan_handle],');
	  END; 
	ELSE BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'');
	END; 

--PRINT @projectionSQL;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO