/*

-- TODO: thread count is off/wrong... (should, 'simply', be the count of either request_ids or execution_context_ids (ecids)... 

/*
        TODO: 
            For SQL Server 2014 (SP2 ...hmmmm) + ... 
                use sys.dm_exec_input_buffer instead of DBCC INPUTBUFFER ... not JUST cuz it's newer/better
                    but... because it's SET-BASED: 
                        https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-input-buffer-transact-sql?view=sql-server-2017
                        (i.e., notice Example B - via CROSS-APPLY)  
                            (and yeah, okay, fine, likely just some 'hack' under the covers... but, still, if this is ever going to be optimized, it'd be in the DMV - not the undocumented? DBCC command).

   
        TODO:
            document these details (in terms of how they apply to dbo.list_processes - or... more specifically: DOCUMENT dbo.list_processes and what the outputs all mean/etc.)
                            -- docs: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-db-task-space-usage-transact-sql?view=sql-server-2017

                            -- doesn't have the task_address and is_remote_task columns in 10.0 / 10.5
                            SELECT * FROM sys.[dm_db_task_space_usage];


                            -- doesn't have the user_objects_deferred_dealloc_page_count column in 10.0 / 10.5
                            SELECT * FROM sys.[dm_db_session_space_usage];



*/




-- 2014 SP2 + 
--			looks fairly interesting: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-input-buffer-transact-sql?view=sql-server-2017   (I can't get the parameters column to return ANYTHING... even when I bind it to 'active' sessions via sys.dm_exec_requests and so on... 
--						yeah... i've now found this 2x: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-input-buffer-transact-sql?view=sql-server-2017

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
	@TopNRows								int			= -1,		-- TOP is only used if @TopNRows > 0. 
	@OrderBy								sysname		= N'CPU',	-- CPU | DURATION | READS | WRITES | MEMORY
	@ExcludeMirroringProcesses				bit			= 1,		-- optional 'ignore' wait types/families.
	@ExcludeNegativeDurations				bit			= 1,		-- exclude service broker and some other system-level operations/etc. 
	@ExcludeBrokerProcesses					bit			= 1,		-- need to document that it does NOT block ALL broker waits (and, that it ONLY blocks broker WAITs - i.e., that's currently the ONLY way it excludes broker processes - by waits).
	@ExcludeFTSDaemonProcesses				bit			= 1,
    --@ExcludeCDCProcesses                    bit         = 1,      -- vNEXT: looks like, sadly, either have to watch for any/some/all? of the following: program_name = SQLAgent Job ID that ... is a CDC task (sigh)... statement_text = 'waitfor delay @waittime' (see this all the time), and/or NAME of the object_id/sproc being executed is ... sys.sp_cdc_scan...  and that's JUST to ignore the LOG READER when it's idle... might have to look at other waits when active/etc. 
	@ExcludeSystemProcesses					bit			= 1,			-- spids < 50... 
	@ExcludeSelf							bit			= 1,	
	@IncludePlanHandle						bit			= 0,	
	@IncludeIsolationLevel					bit			= 0,
	@IncludeBlockingSessions				bit			= 1,		-- 'forces' inclusion of spids CAUSING blocking even if they would not 'naturally' be pulled back by TOP N, etc. 
	@IncudeDetailedMemoryStats				bit			= 0,		-- show grant info... 
	@IncludeExtendedDetails					bit			= 1,
    @IncludeTempdbUsageDetails              bit         = 1,
	@ExtractCost							bit			= 1	
AS 
	SET NOCOUNT ON; 

	IF UPPER(@OrderBy) NOT IN (N'CPU', N'DURATION', N'READS', N'WRITES', 'MEMORY') BEGIN 
		RAISERROR('@OrderBy may only be set to the following values { CPU | DURATION | READS | WRITES | MEMORY } (and is implied as being in DESC order.', 16, 1);
		RETURN -1;
	END;

	-- {copyright}

	CREATE TABLE #core (
		[row_source] sysname NOT NULL,
		[session_id] smallint NOT NULL,
		[blocked_by] smallint NULL,
		[isolation_level] smallint NULL,
		[status] nvarchar(30) NOT NULL,
		[wait_type] nvarchar(60) NULL,
        [wait_resource] nvarchar(256) NOT NULL,
		[command] nvarchar(32) NULL,
		[granted_memory] bigint NULL,
		[requested_memory] bigint NULL,
        [query_cost] float NULL,
		[ideal_memory] bigint NULL,
		[cpu] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[duration] int NOT NULL,
		[wait_time] int NULL,
		[database_id] smallint NULL,
		[login_name] sysname NULL,
		[program_name] sysname NULL,
		[host_name] sysname NULL,
		[percent_complete] real NULL,
		[open_tran] int NULL,
        [tempdb_details] nvarchar(MAX) NULL,
		[sql_handle] varbinary(64) NULL,
		[plan_handle] varbinary(64) NULL, 
		[statement_start_offset] int NULL, 
		[statement_end_offset] int NULL,
		[statement_source] sysname NOT NULL DEFAULT N'REQUEST', 
		[row_number] int IDENTITY(1,1) NOT NULL,
		[text] nvarchar(max) NULL
	);

	DECLARE @topSQL nvarchar(MAX) = N'
	WITH [core] AS (
		SELECT {TOP}
			N''ACTIVE_PROCESS'' [row_source],
			r.[session_id], 
			r.[blocking_session_id] [blocked_by],
			s.[transaction_isolation_level] [isolation_level],
			r.[status],
			r.[wait_type],
            r.[wait_resource],
			r.[command],
			g.[granted_memory_kb],
			g.[requested_memory_kb],
			g.[ideal_memory_kb],
            g.[query_cost],
			r.[cpu_time] [cpu], 
			r.[reads], 
			r.[writes], 
			r.[total_elapsed_time] [duration],
			r.[wait_time],
			r.[database_id],
			s.[login_name],
			s.[program_name],
			s.[host_name],
			r.[percent_complete],
			r.[open_transaction_count] [open_tran],
            {TempDBDetails},
			r.[sql_handle],
			r.[plan_handle],
			r.[statement_start_offset], 
			r.[statement_end_offset]
		FROM 
			sys.dm_exec_requests r
			INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
			LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id AND r.[plan_handle] = g.[plan_handle]
		WHERE
			-- TODO: if wait_types to exclude gets ''stupid large'', then instead of using an IN()... go ahead and create a CTE/derived-table/whatever and do a JOIN instead... 
			ISNULL(r.wait_type, '''') NOT IN(''BROKER_TO_FLUSH'',''HADR_FILESTREAM_IOMGR_IOCOMPLETION'', ''BROKER_EVENTHANDLER'', ''BROKER_TRANSMITTER'',''BROKER_TASK_STOP'', ''MISCELLANEOUS'' {ExcludeMirroringWaits} {ExcludeFTSWaits} {ExcludeBrokerWaits})
			{ExcludeSystemProcesses}
			{ExcludeSelf}
			{ExcludeNegative}
			{ExcludeFTS}
		{TopOrderBy}
	){blockersCTE} 
	
	SELECT 
		[row_source],
		[session_id],
		[blocked_by],
		[isolation_level],
		[status],
		[wait_type],
        [wait_resource],
		[command],
		[granted_memory_kb],
		[requested_memory_kb],
		[ideal_memory_kb],
        [query_cost],
		[cpu],
		[reads],
		[writes],
		[duration],
		[wait_time],
		[database_id],
		[login_name],
		[program_name],
		[host_name],
		[percent_complete],
		[open_tran],
        [tempdb_details],
		[sql_handle],
		[plan_handle],
		[statement_start_offset],
		[statement_end_offset]
	FROM 
		[core] 

	{blockersUNION} 

	{OrderBy};';

	DECLARE @blockersCTE nvarchar(MAX) = N', 
	[blockers] AS ( 
		SELECT 
			N''BLOCKING_SPID'' [row_source],
			[s].[session_id],
			ISNULL([r].[blocking_session_id], x.[blocked]) [blocked_by],
			[s].[transaction_isolation_level] [isolation_level],
			[s].[status],
			ISNULL([r].[wait_type], x.[lastwaittype]) [wait_type],
            ISNULL([r].[wait_resource], N'''') [wait_resource],
			ISNULL([r].[command], x.[cmd]) [command],
			ISNULL([g].[granted_memory_kb],	(x.[memusage] * 8096)) [granted_memory_kb],
			ISNULL([g].[requested_memory_kb], -1) [requested_memory_kb],
			ISNULL([g].[ideal_memory_kb], -1) [ideal_memory_kb],
            ISNULL([g].[query_cost], -1) [query_cost],
			ISNULL([r].[cpu_time], 0 - [s].[cpu_time]) [cpu],
			ISNULL([r].[reads], 0 - [s].[reads]) [reads],
			ISNULL([r].[writes], 0 - [s].[writes]) [writes],
			ISNULL([r].[total_elapsed_time], 0 - [s].[total_elapsed_time]) [duration],
			ISNULL([r].[wait_time],	x.[waittime]) [wait_time],
			[x].[dbid] [database_id],					-- sys.dm_exec_sessions has this - from 2012+ 
			[s].[login_name],
			[s].[program_name],
			[s].[host_name],
			0 [percent_complete],
			x.[open_tran] [open_tran],	  -- sys.dm_exec_sessions has this - from 2012+
            {TempDBDetails},
			ISNULL([r].[sql_handle], (SELECT c.most_recent_sql_handle FROM sys.[dm_exec_connections] c WHERE c.[most_recent_session_id] = s.[session_id])) [sql_handle],
			[r].[plan_handle],
			ISNULL([r].[statement_start_offset], x.[stmt_start]) [statement_start_offset],
			ISNULL([r].[statement_end_offset], x.[stmt_end]) [statement_end_offset]

		FROM 
			sys.dm_exec_sessions s 
			INNER JOIN sys.[sysprocesses] x ON s.[session_id] = x.[spid] -- ugh... i hate using this BUT there are details here that are just NOT anywhere else... 
			LEFT OUTER JOIN sys.dm_exec_requests r ON s.session_id = r.[session_id] 
			LEFT OUTER JOIN sys.[dm_exec_query_memory_grants] g ON s.[session_id] = g.[session_id] AND r.[plan_handle] = g.[plan_handle] 
		WHERE 
			s.[session_id] NOT IN (SELECT session_id FROM [core])
			AND s.[session_id] IN (SELECT blocked_by FROM [core])
	) ';

	DECLARE @blockersUNION nvarchar(MAX) = N'
	UNION 

	SELECT 
		[row_source],
		[session_id],
		[blocked_by],
		[isolation_level],
		[status],
		[wait_type],
        [wait_resource],
		[command],
		[granted_memory_kb],
		[requested_memory_kb],
		[ideal_memory_kb],
        [query_cost],
		[cpu],
		[reads],
		[writes],
		[duration],
		[wait_time],
		[database_id],
		[login_name],
		[program_name],
		[host_name],
		[percent_complete],
		[open_tran],
        [tempdb_details],
		[sql_handle],
		[plan_handle],
		[statement_start_offset],
		[statement_end_offset] 
	FROM 
		[blockers]	
	';

    DECLARE @mergedTempdbMetricsAsACorrelatedSubQuery nvarchar(MAX) = N'
	        N''<tempdb_usage>'' + 
		        ISNULL((
			            (SELECT 
				            COUNT(*) [@allocation_count],
				            CAST(ISNULL((SUM(u.user_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@tempdb_mb], 
				            CAST(ISNULL((SUM(u.internal_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@spill_mb]
			            FROM 
				            sys.dm_db_task_space_usage u 
			            WHERE 
				            u.session_id = s.session_id AND (u.user_objects_alloc_page_count > 0 OR u.internal_objects_alloc_page_count > 0)
			            GROUP BY 
				            u.session_id
			            FOR 
				            XML PATH(''request'')))
		            , N''<request />'')
		        + 
		        ISNULL((
		            (SELECT 
			            COUNT(*) [@allocation_count],
			            CAST(ISNULL((SUM(u.user_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@tempdb_mb], 
			            CAST(ISNULL((SUM(u.internal_objects_alloc_page_count / 128.0)), 0) as decimal(22,1)) [@spill_mb]
		            FROM 
			            sys.dm_db_session_space_usage u 
		            WHERE 
			            u.session_id = s.session_id AND (u.user_objects_alloc_page_count > 0 OR u.internal_objects_alloc_page_count > 0)
		            GROUP BY 
			            u.session_id
		            FOR 
			            XML PATH(''session'')))
		            , N''<session />'') + N''</tempdb_usage>'' [tempdb_details]';

	SET @topSQL = REPLACE(@topSQL, N'{OrderBy}', N'ORDER BY [row_source], ' + QUOTENAME(LOWER(@OrderBy)) + N' DESC');

    -- must be processed before @IncludeBlockingSessions:
    IF @IncludeTempdbUsageDetails = 1 BEGIN 
        SET @topSQL = REPLACE(@topSQL, N'{TempDBDetails}', @mergedTempdbMetricsAsACorrelatedSubQuery);
        SET @blockersCTE = REPLACE(@blockersCTE, N'{TempDBDetails}', @mergedTempdbMetricsAsACorrelatedSubQuery);
      END; 
    ELSE BEGIN 
        SET @topSQL = REPLACE(@topSQL, N'{TempDBDetails}', N'NULL [tempdb_details]');
        SET @blockersCTE = REPLACE(@blockersCTE, N'{TempDBDetails}', N'NULL [tempdb_details]');
    END;

	IF @IncludeBlockingSessions = 1 BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{blockersCTE} ', @blockersCTE);
		SET @topSQL = REPLACE(@topSQL, N'{blockersUNION} ', @blockersUNION);
	  END;
	ELSE BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{blockersCTE} ', N'');
		SET @topSQL = REPLACE(@topSQL, N'{blockersUNION} ', N'');
	END;

	IF @TopNRows > 0 BEGIN
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'TOP(' + CAST(@TopNRows AS sysname) + N') ');
		SET @topSQL = REPLACE(@topSQL, N'{TopOrderBy}', N'ORDER BY ' + CASE LOWER(@OrderBy) WHEN 'cpu' THEN 'r.[cpu_time]' WHEN 'duration' THEN 'r.[total_elapsed_time]' WHEN 'memory' THEN 'g.[granted_memory_kb]' ELSE LOWER(@OrderBy) END + N' DESC');
	  END;
	ELSE BEGIN 
		SET @topSQL = REPLACE(@topSQL, N'{TOP}', N'');
		SET @topSQL = REPLACE(@topSQL, N'{TopOrderBy}', N'');
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

--EXEC dbo.[print_long_string] @Input = @topSQL;
--RETURN 0;

	INSERT INTO [#core] (
		[row_source],
		[session_id],
		[blocked_by],
		[isolation_level],
		[status],
		[wait_type],
        [wait_resource],
		[command],
		[granted_memory],
		[requested_memory],
		[ideal_memory],
        [query_cost],
		[cpu],
		[reads],
		[writes],
		[duration],
		[wait_time],
		[database_id],
		[login_name],
		[program_name],
		[host_name],
		[percent_complete],
		[open_tran],
        [tempdb_details],
		[sql_handle],
		[plan_handle],
		[statement_start_offset],
		[statement_end_offset]
	)
	EXEC sys.[sp_executesql] @topSQL; 

	IF NOT EXISTS (SELECT NULL FROM [#core]) BEGIN 
		RETURN 0; -- short-circuit - there's nothing to see here... 
	END;

	-- populate sql_handles for sessions without current requests: 
	UPDATE x 
	SET 
		x.[sql_handle] = c.[most_recent_sql_handle],
		x.[statement_source] = N'CONNECTION'
	FROM 
		[#core] x 
		INNER JOIN sys.[dm_exec_connections] c ON x.[session_id] = c.[most_recent_session_id]
	WHERE 
		x.[sql_handle] IS NULL;

	-- load statements: 
	SELECT 
		x.[session_id], 
		t.[text] [batch_text], 
		SUBSTRING(t.[text], (x.[statement_start_offset]/2) + 1, ((CASE WHEN x.[statement_end_offset] = -1 THEN DATALENGTH(t.[text]) ELSE x.[statement_end_offset] END - x.[statement_start_offset])/2) + 1) [statement_text]
	INTO 
		#statements 
	FROM 
		[#core] x 
		OUTER APPLY sys.[dm_exec_sql_text](x.[sql_handle]) t;

	-- load plans: 
	SELECT 
		x.[session_id], 
		p.query_plan [batch_plan]
	INTO 
		#plans 
	FROM 
		[#core] x 
		OUTER APPLY sys.dm_exec_query_plan(x.plan_handle) p

    CREATE TABLE #statementPlans (
        session_id int NOT NULL, 
        [statement_plan] xml 
    );

	DECLARE @loadPlans nvarchar(MAX) = N'
	SELECT 
		x.session_id, 
		' + CASE WHEN (SELECT dbo.[get_engine_version]()) > 10.5 THEN N'TRY_CAST' ELSE N'CAST' END + N'(q.[query_plan] AS xml) [statement_plan]
	FROM 
		[#core] x 
		OUTER APPLY sys.dm_exec_text_query_plan(x.[plan_handle], x.statement_start_offset, x.statement_end_offset) q ';

    INSERT INTO [#statementPlans] (
        [session_id],
        [statement_plan]
    )
	EXEC [sys].[sp_executesql] @loadPlans;

	IF @ExtractCost = 1 BEGIN
        
        WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
        SELECT
            p.[session_id],
--TODO: look at whether or not a more explicit path with provide any perf benefits (less tempdb usage, less CPU/less time, etc.)
            p.batch_plan.value('(/ShowPlanXML/BatchSequence/Batch/Statements/StmtSimple/@StatementSubTreeCost)[1]', 'float') [plan_cost]
		INTO 
			#costs
        FROM
            [#plans] p;
    END;

    DECLARE @tempdbExtractionCTE nvarchar(MAX) = N'
    WITH extracted AS (
        SELECT 
            session_id,
            details.value(''(tempdb_usage[1]/request[1]/@tempdb_mb)'', N''decimal(22,1)'') [request_tempdb_mb],
            details.value(''(tempdb_usage[1]/request[1]/@spill_mb)'', N''decimal(22,1)'') [request_spills_mb],
            details.value(''(tempdb_usage[1]/session[1]/@tempdb_mb)'', N''decimal(22,1)'') [session_tempdb_mb],
            details.value(''(tempdb_usage[1]/session[1]/@spill_mb)'', N''decimal(22,1)'') [session_spills_mb]
        FROM 
            (SELECT 
                [session_id],
                CAST([tempdb_details] AS xml) [details]
            FROM 
                [#core]) x
    )
    ' ;

    DECLARE @tempdbDetailsSummary nvarchar(MAX) = N'
        CAST(ISNULL(x.[session_spills_mb], 0.0) AS sysname) + N'' '' + CASE WHEN NULLIF(x.[request_spills_mb], 0.0) IS NULL THEN N'''' ELSE N'' ('' + CAST(x.[request_spills_mb] AS sysname) + N'')'' END[spills_mb - s (r)],
        CAST(ISNULL(x.[session_tempdb_mb], 0.0) AS sysname) + N'' '' + CASE WHEN NULLIF(x.[request_tempdb_mb], 0.0) IS NULL THEN N'''' ELSE N'' ('' + CAST(x.[request_tempdb_mb] AS sysname) + N'')'' END[tempdb_mb - s (r)],
    ';

	DECLARE @projectionSQL nvarchar(MAX) = N'{tempdbExtractionCTE}
    SELECT 
		c.[session_id],
		c.[blocked_by],  
		CASE WHEN c.[database_id] = 0 THEN ''resourcedb'' ELSE DB_NAME(c.database_id) END [db_name],
		{isolation_level}
		c.[command], 
        c.[status], 
		c.[wait_type],
        c.[wait_resource],
		--t.[batch_text],  
		t.[statement_text],
		{extractCost}        
		c.[cpu],
		c.[reads],
		c.[writes],
		{memory}
		dbo.format_timespan(c.[duration]) [elapsed_time], 
		dbo.format_timespan(c.[wait_time]) [wait_time],
        {tempdbDetails}
		ISNULL(c.[program_name], '''') [program_name],
		c.[login_name],
		c.[host_name],
		{plan_handle}
		{extended_details}
		sp.[statement_plan],
        p.[batch_plan]
	FROM 
		[#core] c
		INNER JOIN #statements t ON c.session_id = t.session_id
		INNER JOIN #plans p ON c.session_id = p.session_id
		INNER JOIN #statementPlans sp ON c.session_id = sp.session_id
		{extractJoin}
        {tempdbUsageJoin}
	ORDER BY
		[row_number];'

	IF @IncludeIsolationLevel = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'CASE c.isolation_level WHEN 0 THEN ''Unspecified'' WHEN 1 THEN ''ReadUncomitted'' WHEN 2 THEN ''Readcomitted'' WHEN 3 THEN ''Repeatable'' WHEN 4 THEN ''Serializable'' WHEN 5 THEN ''Snapshot'' END [isolation_level],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{isolation_level}', N'');
	END;

	IF @IncudeDetailedMemoryStats = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'ISNULL(CAST((c.granted_memory / 1024.0) as decimal(20,2)),0) [granted_mb], ISNULL(CAST((c.requested_memory / 1024.0) as decimal(20,2)),0) [requested_mb], ISNULL(CAST((c.ideal_memory  / 1024.0) as decimal(20,2)),0) [ideal_mb],');
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{memory}', N'ISNULL(CAST((c.granted_memory / 1024.0) as decimal(20,2)),0) [granted_mb],');
	END; 

	IF @IncludePlanHandle = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'c.[statement_source], c.[plan_handle], ');
	  END; 
	ELSE BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{plan_handle}', N'');
	END; 

	IF @IncludeExtendedDetails = 1 BEGIN
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extended_details}', N'c.[percent_complete], c.[open_tran], (SELECT COUNT(x.session_id) FROM sys.dm_os_waiting_tasks x WHERE x.session_id = c.session_id) [thread_count], ')
	  END;
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extended_details}', N'');
	END; 

	IF @ExtractCost = 1 BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractCost}', N'CAST(pc.[plan_cost] as decimal(20,2)) [plan_cost], CAST(c.[query_cost] as decimal(20,2)) [grant_cost], ');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractJoin}', N'LEFT OUTER JOIN #costs pc ON c.[session_id] = pc.[session_id]');
	  END
	ELSE BEGIN 
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractCost}', N'');
		SET @projectionSQL = REPLACE(@projectionSQL, N'{extractJoin}', N'');
	END;

    IF @IncludeTempdbUsageDetails = 1 BEGIN 
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbDetails}', @tempdbDetailsSummary);
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbExtractionCTE}', @tempdbExtractionCTE);
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbUsageJoin}', N'LEFT OUTER JOIN extracted x ON c.[session_id] = x.[session_id] ');
      END;
    ELSE BEGIN 
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbDetails}', N'');
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbExtractionCTE}', N'');
        SET @projectionSQL = REPLACE(@projectionSQL, N'{tempdbUsageJoin}', N'');
    END;

--EXEC dbo.print_long_string @projectionSQL;
--RETURN 0;

	-- final output:
	EXEC sys.[sp_executesql] @projectionSQL;

	RETURN 0;
GO