/*

-- TODO: thread count is off/wrong... 


-- 2014 SP2 + 
--			looks fairly interesting: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-input-buffer-transact-sql?view=sql-server-2017   (I can't get the parameters column to return ANYTHING... even when I bind it to 'active' sessions via sys.dm_exec_requests and so on... 


FODDER 

	https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql?view=sql-server-2017




-- TODO: Parameter Validation.... 
-- TODO: test change to N'ORDER BY ' + LOWER(@OrderBy) + N' DESC' in @topSQL for IF @topRows > 0... 
--			pretty sure those changes make sense - but need to verify.

-- TODO: verify that aliased column ORDER BY operations work in versions of SQL Server prior to 2016... 

-- vNEXT: detailed blocking info... (blocking chains if @DetailedBlockingInfo = 1 (expressed as xml)... 
--			Andy Mallon has a great article on this stuff: https://am2.co/2017/10/finding-leader-blocker/


-- vNEXT: tempdb info (spills, usage, overhead, etc). as an optional parameter (i.e., @includetempdbmetrics)

-- vNEXT: @Formatter sysname ... a udf that can be used as an additional column to watch for any specific details a given org might want to grab.. 
--			give it the sql statement? and... maybe the plan? dunno...   (this'd let me grab the "/* ReportID: xxxx; OrgID: yyyyy */ if needed.. and give other people similar details. 
--			would'nt be allowed to be a 'filter'... just a formatter.... 
--				and... maybe the variable's value should be nvarchar(300) or something and look like N'udfNameHere|columnAlias|includedColumns?'  or something like that... 


-- FODDER: 
	-- AZURE: https://feedback.azure.com/forums/908035-sql-server/suggestions/34708300-parallel-select-into-from-sys-messages-causes-intr 
	--			not sure if that applies to non-Azure - but it's something to watch for... 


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
	@ExcludeMirroringProcesses				bit			= 1,		-- optional 'ignore' wait types/families.
	@ExcludeNegativeDurations				bit			= 1,		-- exclude service broker and some other system-level operations/etc. 
	@ExcludeBrokerProcesses					bit			= 1,		-- need to document that it does NOT block ALL broker waits (and, that it ONLY blocks broker WAITs - i.e., that's currently the ONLY way it excludes broker processes - by waits).
	-- vNEXT				--@ExcludeSOmeOtherSetOfWaitTypes		bit			= 1			-- ditto... 
	@ExcludeFTSDaemonProcesses				bit			= 1,
	@ExcludeSystemProcesses					bit			= 1,			-- spids < 50... 
	@ExcludeSelf							bit			= 1,	
	@IncludePlanHandle						bit			= 0,	
	@IncludeIsolationLevel					bit			= 0,
	-- vNEXT				--@DetailedBlockingInfo					bit			= 0,		-- xml 'blocking chain' and stuff... 
	@IncudeDetailedMemoryStats				bit			= 0,		-- show grant info... 
	@IncludeExtendedDetails					bit			= 1,
	-- vNEXT				--@DetailedTempDbStats					bit			= 0,		-- pull info about tempdb usage by session and such... 
	@ExtractCost							bit			= 1	
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	CREATE TABLE #ranked (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[session_id] smallint NOT NULL,
		[blocked_by] smallint NOT NULL,
		[cpu] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[duration] int NOT NULL,
		[memory] decimal(20,2) NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	SELECT {TOP}
		r.[session_id], 
		r.[blocking_session_id] [blocked_by],
		r.[cpu_time] [cpu], 
		r.[reads], 
		r.[writes], 
		r.[total_elapsed_time] [duration],
		ISNULL(CAST((g.granted_memory_kb / 1024.0) as decimal(20,2)),0) AS [memory]
	FROM 
		sys.[dm_exec_requests] r
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
	WHERE
		r.last_wait_type NOT IN(''BROKER_TO_FLUSH'',''HADR_FILESTREAM_IOMGR_IOCOMPLETION'', ''BROKER_EVENTHANDLER'', ''BROKER_TRANSMITTER'',''BROKER_TASK_STOP'', ''MISCELLANEOUS'' {ExcludeMirroringWaits} {ExcludeFTSWaits} {ExcludeBrokerWaits})
		{ExcludeSystemProcesses}
		{ExcludeSelf}
		{ExcludeNegative}
		{ExcludeFTS}
		
	{OrderBy};';

-- TODO: verify that aliased column ORDER BY operations work in versions of SQL Server prior to 2016... 
-- TODO: if i get gobs and gobs of excluded WAITs... then put them into a table to JOIN against vs using IN()... 
	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + LOWER(@OrderBy) + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY ' + LOWER(@OrderBy) + N' DESC');
	END; 

	IF @ExcludeSystemProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'AND (r.[session_id] > 50) AND (r.[database_id] <> 0) AND (r.[session_id] NOT IN (SELECT [session_id] FROM sys.[dm_exec_sessions] WHERE [is_user_process] = 0)) ');
	  END;	
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSystemProcesses}', N'');
	END;

	IF @ExcludeMirroringProcesses = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N',''DBMIRRORING_CMD'',''DBMIRROR_EVENTS_QUEUE'', ''DBMIRROR_WORKER_QUEUE''');
	  END;
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeMirroringWaits}', N'');
	END;

	IF @ExcludeSelf = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'AND r.[session_id] <> @@SPID');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeSelf}', N'');
	END; 

	IF @ExcludeNegativeDurations = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'AND r.[total_elapsed_time] > 0 ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeNegative}', N'');
	END; 

	IF @ExcludeFTSDaemonProcesses = 1 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWaits}', N', ''FT_COMPROWSET_RWLOCK'', ''FT_IFTS_RWLOCK'', ''FT_IFTS_SCHEDULER_IDLE_WAIT'', ''FT_IFTSHC_MUTEX'', ''FT_IFTSISM_MUTEX'', ''FT_MASTER_MERGE'', ''FULLTEXT GATHERER'' ');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'AND r.[command] NOT LIKE ''FT%'' ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTSWaits}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeFTS}', N'');
	END; 

	IF @ExcludeBrokerProcesses = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeBrokerWaits}', N', ''BROKER_RECEIVE_WAITFOR'', ''BROKER_TASK_STOP'', ''BROKER_TO_FLUSH'', ''BROKER_TRANSMITTER'' ');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{ExcludeBrokerWaits}', N'');
	END;

PRINT @topSQL;

	INSERT INTO [#ranked] ([session_id], [blocked_by], [cpu], [reads], [writes], [duration], [memory])
	EXEC sys.[sp_executesql] @topSQL; 

--MKC: S4-61. $100 says that I've already SOLVED this crap in dbo.list_collisions... or... maybe in dbo.list_transactions? 
-- grab any sessions that are BLOCKING the 'top' sessions listed above: 
INSERT INTO #ranked ([session_id], [blocked_by], [cpu], [reads], [writes], [duration], [memory])
SELECT
	r.[session_id], 
	r.[blocking_session_id] [blocked_by],
	r.[cpu_time] [cpu], 
	r.[reads],
	r.[writes], 
	r.[total_elapsed_time] [duration],
	ISNULL(CAST((g.granted_memory_kb / 1024.0) as decimal(20,2)),0) AS [memory]
FROM 
	#ranked x 
	INNER JOIN sys.dm_exec_requests r ON x.blocked_by = r.session_id 
	LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
WHERE 
	r.session_id NOT IN(SELECT session_id FROM #ranked);

	---- and... what if the request is STALLED? 
	--INSERT INTO #ranked ([session_id], [blocked_by], [cpu], [reads], [writes], [duration], [memory])
	--SELECT 
	--	s.[session_id], 
	--	-1, 
	--	-1,
	--	-1,
	--	-1,
	--	-1,
	--	-1
	--FROM 
	--	[#ranked] x 
	--	INNER JOIN sys.dm_exec_sessions s ON x.[blocked_by] = s.[session_id] 
	--WHERE 
	--	s.[session_id] NOT IN (SELECT session_id FROM #ranked);
		


	IF NOT EXISTS (SELECT NULL FROM [#ranked]) BEGIN 
		-- short-circuit - there's nothing to see here... 
		RETURN 0; 
	END;

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
		[plan_handle] varbinary(64) NULL, 
		[statement_start_offset] int NULL, 
		[statement_end_offset] int NULL,
		[statement_source] sysname NOT NULL DEFAULT N'REQUEST'
	);

	INSERT INTO [#detail] ([row_number], [session_id], [blocked_by], [isolation_level], [status], [last_wait_type], [command], [granted_mb], [requested_mb], [ideal_mb], 
		 [cpu_time], [reads], [writes], [elapsed_time], [wait_time], [db_name], [login_name], [program_name], [host_name], [percent_complete], [open_tran], 
		 [sql_handle], [plan_handle], [statement_start_offset], [statement_end_offset])
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
		CASE WHEN r.[database_id] = 0 THEN 'resourcedb' ELSE DB_NAME(r.database_id) END [db_name],
		s.[login_name],
		s.[program_name],
		s.[host_name],
		r.percent_complete,
		r.open_transaction_count [open_tran],
		r.[sql_handle],
		r.[plan_handle],
		r.[statement_start_offset], 
		r.[statement_end_offset]
	FROM 
		[#ranked] x
		INNER JOIN sys.dm_exec_requests r ON x.[session_id] = r.[session_id]
		INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id;

	-- populate sql_handles for sessions without current requests: 
	UPDATE x 
	SET 
		x.[sql_handle] = c.[most_recent_sql_handle],
		x.[statement_source] = N'CONNECTION'
	FROM 
		[#detail] x 
		INNER JOIN sys.[dm_exec_connections] c ON x.[session_id] = c.[most_recent_session_id]
	WHERE 
		x.[sql_handle] IS NULL;

	-- load statements: 
	SELECT 
		d.[session_id], 
		t.[text] [batch_text], 
		SUBSTRING(t.[text], (d.[statement_start_offset]/2) + 1, ((CASE WHEN d.[statement_end_offset] = -1 THEN DATALENGTH(t.[text]) ELSE d.[statement_end_offset] END - d.[statement_start_offset])/2) + 1) [statement_text]
	INTO 
		#statements 
	FROM 
		[#detail] d 
		OUTER APPLY sys.[dm_exec_sql_text](d.[sql_handle]) t;

--TODO: Implement this (i.e., as per dbo.list_collisions ... but ... here - so'z we can get statements if/when they're not in the request itself..).
	--IF @UseInputBuffer = 1 BEGIN
		
	--	DECLARE @sql nvarchar(MAX); 

	--	DECLARE filler CURSOR LOCAL FAST_FORWARD READ_ONLY FOR 
	--	SELECT 
	--		session_id 
	--	FROM 
	--		[#statements] 
	--	WHERE 
	--		[statement] IS NULL; 

	--	DECLARE @spid int; 
	--	DECLARE @bufferStatement nvarchar(MAX);

	--	CREATE TABLE #inputbuffer (EventType nvarchar(30), Params smallint, EventInfo nvarchar(4000))

	--	OPEN filler; 
	--	FETCH NEXT FROM filler INTO @spid;

	--	WHILE @@FETCH_STATUS = 0 BEGIN 
	--		TRUNCATE TABLE [#inputbuffer];

	--		SET @sql = N'EXEC DBCC INPUTBUFFER(' + STR(@spid) + N');';
			
	--		BEGIN TRY 
	--			INSERT INTO [#inputbuffer]
	--			EXEC @sql;

	--			SET @bufferStatement = (SELECT TOP (1) EventInfo FROM [#inputbuffer]);
	--		END TRY 
	--		BEGIN CATCH 
	--			SET @bufferStatement = N'#Error Extracting Statement from DBCC INPUTBUFFER();';
	--		END CATCH

	--		UPDATE [#statements] 
	--		SET 
	--			[statement_source] = N'BUFFER', 
	--			[statement] = @bufferStatement 
	--		WHERE 
	--			[session_id] = @spid;

	--		FETCH NEXT FROM filler INTO @spid;
	--	END;
		
	--	CLOSE filler; 
	--	DEALLOCATE filler;

	--END;

	-- load plans: 
	SELECT 
		d.[session_id], 
		p.query_plan [batch_plan]
	INTO 
		#plans 
	FROM 
		[#detail] d 
		OUTER APPLY sys.dm_exec_query_plan(d.plan_handle) p

	SELECT 
		d.session_id, 
		TRY_CAST(x.[query_plan] AS xml) [statement_plan]
	INTO 
		#statement_plans
	FROM 
		[#detail] d 
		OUTER APPLY sys.dm_exec_text_query_plan(d.[plan_handle], d.statement_start_offset, d.statement_end_offset) x


	IF @ExtractCost = 1 BEGIN
        
        WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT
            p.[session_id],
            p.batch_plan.value('(/ShowPlanXML/BatchSequence/Batch/Statements/StmtSimple/@StatementSubTreeCost)[1]', 'nvarchar(max)') [plan_cost]
		INTO 
			#costs
        FROM
            [#plans] p;
    END;

	DECLARE @projectionSQL nvarchar(MAX) = N'
	SELECT 
		d.[session_id],
		d.[blocked_by],  -- vNext: this is either blocked_by or blocking_chain - which will be xml.. 
		d.[db_name],
		{isolation_level}
		d.[command], 
		d.[last_wait_type],
		t.[batch_text],  
		t.[statement_text],
		d.[status], 
		{extractCost}
		d.[cpu_time],
		d.[reads],
		d.[writes],
		{memory}
		ISNULL(d.[program_name], '''') [program_name],
		dbo.format_timespan(d.[elapsed_time]) [elapsed_time], 
		dbo.format_timespan(d.[wait_time]) [wait_time],
		d.[login_name],
		d.[host_name],
		{plan_handle}
		{extended_details}
		p.[batch_plan], 
		sp.[statement_plan]
	FROM 
		[#detail] d
		INNER JOIN #statements t ON d.session_id = t.session_id
		INNER JOIN #plans p ON d.session_id = p.session_id
		INNER JOIN #statement_plans sp ON d.session_id = sp.session_id
		{extractJoin}
	ORDER BY
		[row_number];'

	IF @IncludeIsolationLevel = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'd.[isolation_level],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'');
	END;

	IF @IncudeDetailedMemoryStats = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'd.[granted_mb], d.[requested_mb], d.[ideal_mb],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'd.[granted_mb],');
	END; 

	IF @IncludePlanHandle = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'd.[statement_source], d.[plan_handle], ');
	  END; 
	ELSE BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'');
	END; 

	IF @IncludeExtendedDetails = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extended_details}', N'd.[percent_complete], d.[open_tran], (SELECT COUNT(x.session_id) FROM sys.dm_os_waiting_tasks x WHERE x.session_id = d.session_id) [thread_count], ')
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extended_details}', N'');
	END; 

	IF @ExtractCost = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractCost}', N'CAST((CAST([plan_cost] as float)) as decimal(20,2)) [plan_cost],');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractJoin}', N'LEFT OUTER JOIN #costs c ON d.[session_id] = c.[session_id]');
	  END
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractCost}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractJoin}', N'');
	END;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO