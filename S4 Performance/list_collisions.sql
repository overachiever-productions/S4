/*

	NOTE: 
		This report isn't just designed to grab blocked proceses ONLY. It also grabs the processes that are BLOCKING as well. 


	NOTE: 
		- Not currently (and likely ever) supported in SQL Server 2008/R2.
		- Dynamic ALTER statements as part of deployment. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_collisions', 'P') IS NOT NULL
	DROP PROC dbo.list_collisions;
GO

CREATE PROC dbo.list_collisions 
	@TargetDatabases								nvarchar(max)	= N'[ALL]',  -- allowed values: [ALL] | [SYSTEM] | [USER] | 'name, other name, etc'; -- this is an EXCLUSIVE list... as in, anything not explicitly mentioned is REMOVED. 
	@IncludePlans									bit				= 1, 
	@IncludeContext									bit				= 1,
	@UseInputBuffer									bit				= 0,     -- for any statements (query_handles) that couldn't be pulled from sys.dm_exec_requests and then (as a fallback) from sys.sysprocesses, this specifies if we should use DBCC INPUTBUFFER(spid) or not... 
	@ExcludeFullTextCollisions						bit				= 1   
	--@MinimumWaitThresholdInMilliseconds				int			= 200	
	--@ExcludeSystemProcesses							bit			= 1		-- TODO: this needs to be restricted to ... blocked only? or... how's that work... (what if i don't care that a system process is blocked... but that system process is blocking a user process? then what?
AS 
	SET NOCOUNT ON;

	-- {copyright}

	IF NULLIF(@TargetDatabases, N'') IS NULL
		SET @TargetDatabases = N'[ALL]';

	WITH blocked AS (
		SELECT 
			session_id, 
			blocking_session_id
		FROM 
			sys.dm_exec_requests
		WHERE 
			ISNULL(blocking_session_id, 0) <> 0
	), 
	collisions AS ( 
		SELECT 
			session_id 
		FROM 
			blocked 
		UNION 
		SELECT 
			blocking_session_id
		FROM 
			blocked
	)

	SELECT 
		s.session_id, 
		r.database_id,	--MKC: S4-1: 2008/R2 don't have s.database_id - so I 'dumbed this down' to use r(equest). But my original intention in using s.database_id was to cast a 'wide' net relative to which db the SPID is (or WAS) in. 
		r.wait_time, 
		ISNULL(r.blocking_session_id, 0) blocking_session_id, 
		s.session_id [blocked_session_id],
		r.command,
		ISNULL(r.[status], 'connected') [status],
		ISNULL(r.[total_elapsed_time], DATEDIFF(MILLISECOND, s.last_request_start_time, GETDATE())) [duration],
		ISNULL(r.wait_resource, '') wait_resource,
		CASE [dtat].[transaction_type]
			WHEN 1 THEN 'Read/Write'
			WHEN 2 THEN 'Read-Only'
			WHEN 3 THEN 'System'
			WHEN 4 THEN 'Distributed'
					ELSE '#Unknown#'
		END [transaction_scope],		
		CASE [dtat].[transaction_state]
			WHEN 0 THEN 'Initializing'
			WHEN 1 THEN 'Initialized'
			WHEN 2 THEN 'Active'
			WHEN 3 THEN 'Ended (read-only)'
			WHEN 4 THEN 'DTC commit started'
			WHEN 5 THEN 'Awaiting resolution'
			WHEN 6 THEN 'Committed'
			WHEN 7 THEN 'Rolling back...'
			WHEN 8 THEN 'Rolled back'
			ELSE NULL
		END [transaction_state],
		CASE r.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
			ELSE NULL
		END [isolation_level],
		CASE WHEN dtst.is_user_transaction = 1 THEN 'EXPLICIT' ELSE 'IMPLICIT' END [transaction_type], 
		(SELECT MAX(open_tran) FROM sys.sysprocesses p WHERE s.session_id = p.spid) [open_transaction_count], 
		N'REQUEST' [statement_source],
		r.sql_handle [statement_handle], 
		r.plan_handle, 
		r.statement_start_offset, 
		r.statement_end_offset
	INTO 
		#core
	FROM 
		sys.[dm_exec_sessions] s 
		LEFT OUTER JOIN sys.[dm_exec_requests] r ON s.[session_id] = r.[session_id]
		LEFT OUTER JOIN sys.dm_tran_session_transactions dtst ON r.session_id = dtst.session_id
		LEFT OUTER JOIN sys.dm_tran_active_transactions dtat ON dtst.transaction_id = dtat.transaction_id
	WHERE 
		s.session_id IN (SELECT session_id FROM collisions);

	IF @ExcludeFullTextCollisions = 1 BEGIN 
		DELETE FROM [#core]
		WHERE [command] LIKE 'FT%';
	END;

	IF @TargetDatabases <> N'[ALL]' BEGIN
		DECLARE @dbnames nvarchar(max);
		EXEC dbo.load_databases 
			@Targets = @TargetDatabases, 
			@ExcludeSecondaries = 1,
			@Output = @dbnames OUTPUT; 

		DELETE FROM #core 
		WHERE 
			database_id NOT IN (SELECT database_id FROM sys.databases WHERE [name] IN (SELECT [result] FROM dbo.split_string(@dbnames, N',', 1)));
	END; 

	IF NOT EXISTS(SELECT NULL FROM [#core]) BEGIN
		-- SELECT 'no collisions' [outcome];  -- TODO: if this isn't running 'unattended' then... have it spit out the select/outcome... 
		RETURN 0; -- short-circuit.
	END;

	--------------------------------------------------------
	-- Extract Statements: 

	UPDATE c 
	SET 
		c.statement_handle = CAST(p.[sql_handle] AS varbinary(64)),
		c.statement_source = N'SESSION'
	FROM 
		#core c 
		LEFT OUTER JOIN sys.sysprocesses p ON c.session_id = p.spid
	WHERE 
		c.statement_handle IS NULL;

	SELECT 
		c.[session_id], 
		c.[statement_source], 
		t.[text] [statement]
	INTO 
		#statements 
	FROM 
		#core c 
		OUTER APPLY sys.[dm_exec_sql_text](c.[statement_handle]) t;
	
	IF @UseInputBuffer = 1 BEGIN
		
		DECLARE @sql nvarchar(MAX); 

		DECLARE filler CURSOR LOCAL FAST_FORWARD READ_ONLY FOR 
		SELECT 
			session_id 
		FROM 
			[#statements] 
		WHERE 
			[statement] IS NULL; 

		DECLARE @spid int; 
		DECLARE @bufferStatement nvarchar(MAX);

		CREATE TABLE #inputbuffer (EventType nvarchar(30), Params smallint, EventInfo nvarchar(4000))

		OPEN filler; 
		FETCH NEXT FROM filler INTO @spid;

		WHILE @@FETCH_STATUS = 0 BEGIN 
			TRUNCATE TABLE [#inputbuffer];

			SET @sql = N'EXEC DBCC INPUTBUFFER(' + STR(@spid) + N');';
			
			BEGIN TRY 
				INSERT INTO [#inputbuffer]
				EXEC @sql;

				SET @bufferStatement = (SELECT TOP (1) EventInfo FROM [#inputbuffer]);
			END TRY 
			BEGIN CATCH 
				SET @bufferStatement = N'#Error Extracting Statement from DBCC INPUTBUFFER();';
			END CATCH

			UPDATE [#statements] 
			SET 
				[statement_source] = N'BUFFER', 
				[statement] = @bufferStatement 
			WHERE 
				[session_id] = @spid;

			FETCH NEXT FROM filler INTO @spid;
		END;
		
		CLOSE filler; 
		DEALLOCATE filler;

	END;

	IF @IncludePlans = 1 BEGIN 
		
		SELECT 
			c.[session_id], 
			p.[query_plan]
		INTO 
			#plans
		FROM 
			[#core] c 
			OUTER APPLY sys.[dm_exec_query_plan](c.[plan_handle]) p;
	END; 

	IF @IncludeContext = 1 BEGIN; 
		
		SELECT 
			c.[session_id], 
			(
				SELECT 
					[c].[statement_source],
					[c].[statement_handle],
					[c].[plan_handle],
					[c].[statement_start_offset],
					[c].[statement_end_offset],
					[c].[statement_source],	
					[s].[login_name], 
					[s].[host_name], 
					[s].[program_name]			
				FROM 
					#core c2 
					LEFT OUTER JOIN sys.[dm_exec_sessions] s ON c2.[session_id] = [s].[session_id]
				WHERE 
					c2.[session_id] = c.[session_id]
				FOR 
					XML PATH('context')
			) [context]
		INTO 
			#context
		FROM 
			#core  c;
	END;
	
	-------------------------------------------
	-- Generate Blocking Chains: 
	WITH chainedSessions AS ( 
		
		SELECT 
			0 [level], 
			session_id, 
			blocking_session_id, 
			blocked_session_id,
			CAST((N' ' + CHAR(187) + N' ' + CAST([blocked_session_id] AS sysname)) AS nvarchar(400)) [blocking_chain]
		FROM 
			#core 
		WHERE 
			[blocking_session_id] = 0 -- anchor to root... 

		UNION ALL 

		SELECT 
			([x].[level] + 1) [level], 
			c.session_id, 
			c.[blocking_session_id], 
			c.[blocked_session_id],
			CAST((x.[blocking_chain] + N' > ' + CAST(c.[blocked_session_id] AS sysname)) AS nvarchar(400)) [blocking_chain]
		FROM 
			[#core] c
			INNER JOIN [chainedSessions] x ON [c].[blocking_session_id] = x.blocked_session_id
	)

	SELECT 
		[session_id], 
		[level],
		[blocking_chain]
	INTO 
		#chain 
	FROM 
		[chainedSessions]
	ORDER BY 
		[level], [session_id];

	DECLARE @finalProjection nvarchar(MAX);

	SET @finalProjection = N'
	SELECT 
		CASE WHEN ISNULL(c.[database_id], 0) = 0 THEN ''resourcedb'' ELSE DB_NAME(c.[database_id]) END [database],
		[x].[blocking_chain],
        CASE WHEN c.[blocking_session_id] = 0 THEN N'' - '' ELSE REPLICATE(''   '', x.[level]) + CAST([c].[blocking_session_id] AS sysname) END [blocking_session_id],
        REPLICATE(''   '', x.[level]) + CAST(([c].[blocked_session_id]) AS sysname) [session_id],
        [c].[command],
        [c].[status],
        RTRIM(LTRIM([s].[statement])) [statement],
		[c].[wait_time],
	[c].[duration],		-- some sort of a bug here... 
        [c].[wait_resource],
        ISNULL([c].[transaction_scope], '') [transaction_scope],
        ISNULL([c].[transaction_state], N'') [transaction_state],
        [c].[isolation_level],
        [c].[transaction_type],
        [c].[open_transaction_count]
		{context}
		{query_plan}
	FROM 
		[#core] c 
		LEFT OUTER JOIN #chain x ON [c].[session_id] = [x].[session_id]
		LEFT OUTER JOIN [#context] cx ON [c].[session_id] = [cx].[session_id]
		LEFT OUTER JOIN [#statements] s ON c.[session_id] = s.[session_id] 
		LEFT OUTER JOIN [#plans] p ON [c].[session_id] = [p].[session_id]
	ORDER BY 
		x.level, c.wait_time DESC;
	';

	IF @IncludeContext = 1
		SET @finalProjection = REPLACE(@finalProjection, N'{context}', N' ,CAST(cx.[context] AS xml) [context] ');
	ELSE 
		SET @finalProjection = REPLACE(@finalProjection, N'{context}', N'');

	IF @IncludePlans = 1 
		SET @finalProjection = REPLACE(@finalProjection, N'{query_plan}', N' ,[p].[query_plan] ');
	ELSE 
		SET @finalProjection = REPLACE(@finalProjection, N'{query_plan}', N'');

	-- final projection:
	EXEC sp_executesql @finalProjection;

	RETURN 0;
GO