/*

	DEFINITIONS: 
		- A 'TRUE ZOMBIE' is a session that ... 
			these are FAIRLY rare and typically (not always) caused by both a) bad code, and b) specifically (what makes the code bad-ish) is XACT_ABORT ON... 
		- BUT, while the above can/will block the snot out stuff... 
			sessions with OPEN transactions that haven't DONE anything in a long time (i.e., just sitting with OPEN transactions) are also a problem 
				and can cause major problems. These 'zombie-like' sessions are also WAY more common. 

		Finally, there's no true/viable way to distinguish between true zombies vs zombie-like operations. 
		So .. this diagnostic returns anything that has the SYMPTOMs of a zombie (which are the same symptoms of zombie-like operations).



	.PARAMETER @sort 		
	REQUIRED
	DEFAULT: `IDLE_TIME`
	VALID VALUES: `{	IDLE_TIME | SESSION_ID | TEMPDB_LRC | LOCKS_COUNT | LOG_USED }`
	| @sort Type | Description |
	|---|---|
	| IDLE_TIME | Sort by the amount of time the session has been idle (descending) |	
	| SESSION_ID | Sort by the session_id (ascending) |
	| TEMPDB_LRC | Sort by tempdb log record COUNTs (descending) |
	| LOCKS_COUNT | Sort by the number of locks held - across ALL databases (descending) |
	| LOG_USED | Sort by the amount of T-Log space used - against ALL databases (descending) |

	
	.RESULT

	.TABLE 
	| Column | Type | Description |
	|---|---|---|
	| session_id | smallint | The session_id of the zombie-like session |
	| databases | nvarchar(4000) | The databases that the zombie-like session has open transactions in |
	| principal | nvarchar(128) | The login_name of the zombie-like session |
	| host | nvarchar(128) | The host_name of the zombie-like session |
	| ip | nvarchar(48) | The client_net_address of the zombie-like session |
	| application | nvarchar(128) | The program_name of the zombie-like session |
	| status | nvarchar(30) | The status of the zombie-like session (i.e., sleeping) |
	| session_conn_count | int | The number of connections that the zombie-like session has open (i.e., MARS connections, etc.) |


	.REMARKS
	For the `@sort` parameter, the `TEMPDB_LRC` sort option allows easy identification of zombie-like sessions that are likely to PREVENT the tempdb's transaction log from being TRUNCATED. 


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[zombie_transactions]', N'P') IS NOT NULL
	DROP PROC dbo.[zombie_transactions];
GO

CREATE PROC dbo.[zombie_transactions]
	@idle_threshold							sysname				= N'90 seconds',
	@sort									sysname				= N'IDLE_TIME',						-- { IDLE_TIME | SESSION_ID | TEMPDB_LOG_RECORDS | LOCKS_COUNT | LOG_USED }
	@exclude_backups_and_restores			bit					= 0,					
	@exclude_sqlagent_jobs					bit					= 0,	
	@databases								nvarchar(MAX)		= NULL,
	@applications							nvarchar(MAX)		= NULL, 
	@principals								nvarchar(MAX)		= NULL, 
	@roles									nvarchar(MAX)		= NULL,						
	@hosts									nvarchar(MAX)		= NULL, 
	@ips									nvarchar(MAX)		= NULL, 
	@statements								nvarchar(MAX)		= NULL,	
	@serialized_output						xml					= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @idle_threshold = ISNULL(NULLIF(@idle_threshold, N''), N'90 seconds');
	SET @sort = UPPER(ISNULL(NULLIF(@sort, N''), N'IDLE_TIME'));

	SET @exclude_backups_and_restores = ISNULL(@exclude_backups_and_restores, 0);
	SET @exclude_sqlagent_jobs = ISNULL(@exclude_sqlagent_jobs, 0);
	SET @databases = NULLIF(@databases, N'');
	SET @applications = NULLIF(@applications, N'');
	SET @principals = NULLIF(@principals, N'');
	SET @roles = NULLIF(@roles, N'');
	SET @hosts = NULLIF(@hosts, N'');
	SET @ips = NULLIF(@ips, N'');
	SET @statements = NULLIF(@statements, N'');

	IF @sort NOT IN (N'IDLE_TIME', N'SESSION_ID', N'TEMPDB_LRC', N'LOCKS_COUNT', N'LOG_USED') BEGIN
		RAISERROR(N'Invalid @sort value. Valid values are: { IDLE_TIME | SESSION_ID | TEMPDB_LRC | LOCKS_COUNT	| LOG_USED }', 16, 1);
		RETURN -10;  
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predicates:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @idleThresholdMilliseconds bigint = -1, @vectorError nvarchar(MAX);

	IF @idle_threshold IS NOT NULL BEGIN 
		EXEC admindb.dbo.[translate_vector]
			@Vector = @idle_threshold,
			@ValidationParameterName = N'@idle_threshold',
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
				DB_NAME([database_id]) [@name], 
				ISNULL((
					SELECT 
						CAST([dt].[database_transaction_log_bytes_used] / 1024. AS decimal(10,2)) 
					FROM 
						[sys].[dm_tran_session_transactions] [st] 
						INNER JOIN [sys].[dm_tran_active_transactions] [at] ON [at].[transaction_id] = [st].[transaction_id] 
						INNER JOIN [sys].[dm_tran_database_transactions] [dt] ON [dt].[transaction_id] = [at].[transaction_id]
					WHERE 
						[st].[session_id] = [mid].[session_id]
						AND dt.database_id = [mid].[database_id]
				), 0) [@log_kb_used],
				(
					SELECT 
						[request_mode] [@request_mode],
						[resource_type] [@resource_type],
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
	-- Predication:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @databases IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_databases ([row_id] int IDENTITY(1,1) NOT NULL, [database] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [database]));
	END;
	
	IF @applications IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_applications ([row_id] int IDENTITY(1,1) NOT NULL, [application] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [application]));
	END; 

	IF @hosts IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_hosts ([row_id] int IDENTITY(1,1) NOT NULL, [host] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [host])); 
	END;

	IF @ips IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_ips ([row_id] int IDENTITY(1,1) NOT NULL, [ip] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [ip]));		
	END;

	IF @principals IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_principals ([row_id] int IDENTITY(1,1) NOT NULL, [principal] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [principal]));
	END;

	IF @statements IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_statements ([row_id] int IDENTITY(1,1) NOT NULL, [statement] nvarchar(MAX) NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude]));
	END;

	DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	EXEC dbo.[core_predicates]
		@Databases = @databases,
		@Applications = @applications,
		@Hosts = @hosts,
		@IPs = @ips,
		@Principals = @principals,
		@Statements = @statements,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	CREATE TABLE [#intermediate] (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[session_id] smallint NOT NULL,
		[databases] nvarchar(4000) NULL,
		[principal] nvarchar(128) NOT NULL,
		[host] nvarchar(128) NULL,
		[ip] nvarchar(48) NULL,
		[application] nvarchar(128) NULL,
		[status] nvarchar(30) NOT NULL,
		[session_conn_count] int NULL,
		[open_tx_count] int NULL,
		[idle_time] sysname NULL,
		[idle_milliseconds] bigint NULL,
		[tx_id] bigint NOT NULL,
		[tempdb_lrc] bigint NULL,
		[tempdb_log_used_mb] decimal(12, 2) NULL,
		[tempdb_log_reserved_mb] decimal(12, 2) NULL,
		[resources] xml NULL,
		[tx_name] nvarchar(32) NOT NULL,
		[tx_start] datetime NOT NULL,
		[transaction_state] varchar(28) NOT NULL,
		[database_id] smallint NOT NULL,
		[statement] nvarchar(MAX) NULL
	);

	DECLARE @orderBy nvarchar(MAX);
	SELECT @orderBy = CASE @sort
		WHEN N'IDLE_TIME' THEN N'[x].[idle_milliseconds] DESC'
		WHEN N'SESSION_ID' THEN N'[x].[session_id]'
		WHEN N'TEMPDB_LOG_RECORDS' THEN N'[x].[tempdb_lrc] DESC'
		WHEN N'LOCKS_COUNT' THEN N'DATALENGTH([x].[resources]) DESC'
		WHEN N'LOG_USED' THEN N'[x].[log_used_mb] DESC'
		ELSE N'[x].[idle_milliseconds] DESC'
	END;

	DECLARE @sql nvarchar(MAX) = N'WITH core AS (
	SELECT
		[z].[session_id],
		[d].[databases] [database],  -- tweaked spelling to allow for joins/predicates to filter vs [database]
		[z].[login_name] [principal],
		[z].[host_name] [host],
		(SELECT [e].[client_net_address] FROM sys.[dm_exec_connections] [e] WHERE [z].[session_id] = [e].[session_id] AND [e].[parent_connection_id] IS NULL) [ip],
		[z].[program_name] [application],
		[z].[status],
		(SELECT COUNT(*) FROM sys.[dm_exec_connections] [e] WHERE [z].[session_id] = [e].[session_id]) [session_conn_count], /* Good ol'' MARS (sigh) */
		(SELECT SUM([open_transactions]) FROM [#potential_zombies] [z2] WHERE [z2].[session_id] = [z].[session_id]) [open_tx_count],
		[dbo].[format_timespan]([z].[idle_milliseconds]) [idle_time],
		[z].[idle_milliseconds],
		[z].[tx_id],
		[l].[record_count] [tempdb_lrc],
		[l].[log_used_mb] [tempdb_log_used_mb],
		[l].[log_reserved_mb] [tempdb_log_reserved_mb],
		[x].[resources],
		CAST([x].[resources].value(N''xs:decimal(sum(/databases/database/@log_kb_used))'', N''decimal(10,2)'') AS decimal(10,2)) [log_used_mb],
		[z].[tx_name],
		[z].[tx_start],
		[z].[transaction_state],
		[z].[database_id],
		[z].[last_statement] [statement]
	FROM
		[#potential_zombies] [z]
		INNER JOIN #databases_by_session [d] ON [z].[session_id] = [d].[session_id]
		INNER JOIN [#resources_xml] [x] ON [z].[session_id] = [x].[session_id]
		LEFT OUTER JOIN [#log_usage] [l] ON [z].[session_id] = [l].[session_id]
)

SELECT
	[x].[session_id],
	[x].[database] [databases],
	[x].[principal],
	[x].[host],
	[x].[ip],
	[x].[application],
	[x].[status],
	[x].[session_conn_count],
	[x].[open_tx_count],
	[x].[idle_time],
	[x].[idle_milliseconds],
	[x].[tx_id],
	[x].[tempdb_lrc],
	[x].[tempdb_log_used_mb],
	[x].[tempdb_log_reserved_mb],
	[x].[resources],
	[x].[tx_name],
	[x].[tx_start],
	[x].[transaction_state],
	[x].[database_id],
	[x].[statement] 
FROM 
	[core] [x]{joins}
WHERE 
	1 = 1{filters}
ORDER BY
	{orderBy};';

	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);
	SET @sql = REPLACE(@sql, N'{orderBy}', @orderBy);

	INSERT INTO [#intermediate] (
		[session_id],
		[databases],
		[principal],
		[host],
		[ip],
		[application],
		[status],
		[session_conn_count],
		[open_tx_count],
		[idle_time],
		[idle_milliseconds],
		[tx_id],
		[tempdb_lrc],
		[tempdb_log_used_mb],
		[tempdb_log_reserved_mb],
		[resources],
		[tx_name],
		[tx_start],
		[transaction_state],
		[database_id],
		[statement]
	)
	EXEC sys.sp_executesql 
		@sql;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Checks for Missing [statement]:
-- well... crap. I can't predicate for statements and THEN look for more data 
-- have to move this up the stack.
-- https://overachieverllc.atlassian.net/browse/S4-997
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
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
				[session_id] [@session_id],
				[databases] [@databases],
				[idle_time] [@idle_time],
				[idle_milliseconds] [@idle_milliseconds],
				[status] [@status],
				[tx_name] [@tx_name],
				[transaction_state] [@tx_state],
				[session_conn_count] [@conn_count],
				[open_tx_count] [@open_tx_count],
				[tempdb_lrc] [@tempdb_lrc],
				[tempdb_log_used_mb] [@tempdb_log_used_mb], 
				[tempdb_log_reserved_mb] [@tempdb_log_reserved_mb],
				[tx_start] [@tx_start],
				[principal] [@principal],
				[application] [@application],
				[host] [@host],
				[ip] [@ip], 
				[resources],
				REPLACE([statement] COLLATE Latin1_General_BIN, char(0x0), N'') [statement]
			FROM
				#intermediate
			ORDER BY 
				[row_id]
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
		[tx_name],
		[transaction_state] [tx_state],
		[idle_time],
		[session_conn_count] [conn_count],
		[open_tx_count],
		[tempdb_lrc],
		CAST ([tempdb_log_used_mb] AS sysname) + CASE WHEN [tempdb_log_used_mb] = [tempdb_log_reserved_mb] THEN N'' ELSE N' (' + CAST([tempdb_log_reserved_mb] AS sysname) + N')' END [tempdb_log_mb (reserved)],
		[resources],
		[tx_start],
		[host],
		[ip],
		[statement]
	FROM
		#intermediate
	ORDER BY 
		[row_id];

	RETURN 0;
GO