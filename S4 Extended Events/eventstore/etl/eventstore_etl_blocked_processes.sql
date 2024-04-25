/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_blocked_processes]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_blocked_processes];
GO

CREATE PROC dbo.[eventstore_etl_blocked_processes]
	@SessionName				sysname			= N'blocked_processes', 
	@EventStoreTarget			sysname			= N'admindb.dbo.eventstore_blocked_processes',
	@InitializeDaysBack			int				= 30
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @SessionName = ISNULL(NULLIF(@SessionName, N''), N'blocked_processes');
	SET @EventStoreTarget = ISNULL(NULLIF(@EventStoreTarget, N''), N'admindb.dbo.eventstore_blocked_processes');
	SET @InitializeDaysBack = ISNULL(@InitializeDaysBack, 30);

	DECLARE @etlSQL nvarchar(MAX) = N'
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- XEL Data Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH shredded AS ( 
		SELECT 
			[nodes].[row].value(N''(@timestamp)[1]'', N''datetime2'') AS [timestamp],
			[nodes].[row].value(N''(data[@name="database_name"]/value)[1]'',N''nvarchar(128)'') AS [database_name],
			[nodes].[row].value(N''(data[@name="duration"]/value)[1]'', N''bigint'') AS [duration],
			[nodes].[row].value(N''(data/value/blocked-process-report/@monitorLoop)[1]'', N''int'') AS [report_id],

			-- blockER:
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@spid)[1]'', N''int'') [blocking_spid],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@ecid)[1]'', N''int'') [blocking_ecid],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@xactid)[1]'', N''bigint'') [blocking_xactid],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/inputbuf)[1]'', N''nvarchar(max)'') [blocking_request],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@waitresource)[1]'', N''nvarchar(80)'') [blocking_resource],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@waittime)[1]'', N''int'') [blocking_wait_time],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@trancount)[1]'', N''int'') [blocking_tran_count],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@clientapp)[1]'', N''nvarchar(128)'') [blocking_client_app],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@hostname)[1]'', N''nvarchar(128)'') [blocking_host_name],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@loginname)[1]'', N''nvarchar(128)'') [blocking_login_name],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@isolationlevel)[1]'', N''nvarchar(128)'') [blocking_isolation_level],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/executionStack/frame/@stmtstart)[1]'', N''int'') [blocking_start_offset],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/executionStack/frame/@stmtend)[1]'', N''int'') [blocking_end_offset],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocking-process/process/@status)[1]'', N''nvarchar(128)'') [blocking_status],

			-- blockED
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@spid)[1]'', N''int'') [blocked_spid],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@ecid)[1]'', N''int'') [blocked_ecid],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@xactid)[1]'', N''bigint'') [blocked_xactid],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/inputbuf)[1]'', N''nvarchar(max)'') [blocked_request],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@waitresource)[1]'', N''nvarchar(80)'') [blocked_resource],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@waittime)[1]'', N''int'') [blocked_wait_time],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@trancount)[1]'', N''int'') [blocked_tran_count],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@logused)[1]'', N''int'') [blocked_log_used],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@clientapp)[1]'', N''nvarchar(128)'') [blocked_client_app],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@hostname)[1]'', N''nvarchar(128)'') [blocked_host_name],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@loginname)[1]'', N''nvarchar(128)'') [blocked_login_name],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@isolationlevel)[1]'', N''nvarchar(128)'') [blocked_isolation_level],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@lockMode)[1]'', N''nvarchar(128)'') [blocked_lock_mode],
			[nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/@status)[1]'', N''nvarchar(128)'') [blocked_status], 

			-- NOTE: this EXPLICITLY pulls only the FIRST frame''s details (there can be MULTIPLE per ''batch'').
			ISNULL([nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/executionStack/frame/@stmtstart)[1]'', N''int''), 0) [blocked_start_offset],
			ISNULL([nodes].[row].value(N''(data/value/blocked-process-report/blocked-process/process/executionStack/frame/@stmtend)[1]'', N''int''), 0) [blocked_end_offset],
			[nodes].[row].query(N''.'') [raw_xml]
		FROM 
			@EventData.nodes(N''//event'') [nodes]([row])
		WHERE 
			[nodes].[row].value(N''(@name)[1]'', N''sysname'') = N''blocked_process_report''
	)

	SELECT
		IDENTITY(int, 1, 1) [row_id],
		[s].[timestamp],
		[s].[database_name],
		CAST(([s].[duration]/1000000.0) as decimal(24,2)) [seconds_blocked],
		[s].[report_id],
		CAST([s].[blocking_spid] as sysname) + CASE WHEN [s].[blocking_ecid] = 0 THEN N'' '' ELSE N'' '' + QUOTENAME([s].blocking_ecid, N''()'') END [blocking_id], 
		CAST([s].[blocked_spid] as sysname) + CASE WHEN [s].[blocked_ecid] = 0 THEN N'' '' ELSE N'' '' + QUOTENAME([s].blocked_ecid, N''()'') END [blocked_id],
		[s].[blocking_xactid],
		[s].[blocking_request],
		CAST(N'''' AS nvarchar(MAX)) [normalized_blocking_request],
		CAST(N'''' AS nvarchar(MAX)) [blocking_sproc_statement],
		[s].[blocking_resource] [blocking_resource_id], 
		CAST(N'''' AS varchar(2000)) [blocking_resource],
-- TODO: is //event/data/@lock_mode/value ... the lock_mode of the BLOCKER? seems like it is... i just need to confirm this with some ''real'' data... 
---			actually... guessing it''s the lock mode for the BLOCKED process... 
--		and, if it is, then i need to add a new [blocking_lock_mode] column into the mix. 
		[s].[blocking_wait_time],
		[s].[blocking_tran_count],
		[s].[blocking_isolation_level],
		[s].[blocking_status],
		ISNULL([s].[blocking_start_offset], 0) [blocking_start_offset],
		ISNULL([s].[blocking_end_offset], 0) [blocking_end_offset],

		[s].[blocking_host_name],
		[s].[blocking_login_name],
		[s].[blocking_client_app],
		

		[s].[blocked_spid],
		[s].[blocked_ecid],
		[s].[blocked_xactid],
		[s].[blocked_request],
		CAST(N'''' AS nvarchar(MAX)) [normalized_blocked_request],
		CAST(N'''' AS nvarchar(MAX)) [blocked_sproc_statement],
		CAST(N'''' AS sysname) [blocked_weight],
		[s].[blocked_resource] [blocked_resource_id],
		CAST(N'''' AS varchar(2000)) [blocked_resource],

		[s].[blocked_wait_time],
		[s].[blocked_tran_count],
		[s].[blocked_log_used],
		[s].[blocked_lock_mode],
		[s].[blocked_isolation_level],
		[s].[blocked_status],

		ISNULL([s].[blocked_start_offset], 0) [blocked_start_offset],
		ISNULL([s].[blocked_end_offset], 0) [blocked_end_offset],
		[s].[blocked_host_name],
		[s].[blocked_login_name],
		[s].[blocked_client_app],
		[s].[raw_xml] [report]
	INTO 
		#data
	FROM 
		[shredded] s
	ORDER BY 
		[s].[report_id]; 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Statement Extraction: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @rowID int;
	DECLARE @statement nvarchar(MAX); 	
	
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[database_name],
		blocking_request [request], 
		blocking_start_offset, 
		blocking_end_offset, 
		CAST('''' AS nvarchar(MAX)) [definition] 
	INTO 
		#statement_blocking
	FROM 
		[#data] 
	WHERE 
		[blocking_request] LIKE N''%Object Id = [0-9]%''
	GROUP BY 
		[database_name], [blocking_request], [blocking_start_offset], [blocking_end_offset];

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[database_name],
		blocked_request [request], 
		blocked_start_offset, 
		blocked_end_offset, 
		CAST('''' AS nvarchar(MAX)) [definition]
	INTO 
		#statement_blocked
	FROM 
		[#data] 
	WHERE 
		[blocked_request] LIKE N''%Object Id = [0-9]%''
	GROUP BY 
		[database_name], [blocked_request], [blocked_start_offset], [blocked_end_offset];

	DECLARE @sproc sysname;
	DECLARE @sourceDatabase sysname;
	DECLARE @objectId int;
	DECLARE @start int;
	DECLARE @end int;

	DECLARE extracting CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, [database_name], request, blocking_start_offset, blocking_end_offset FROM [#statement_blocking];

	OPEN [extracting];
	FETCH NEXT FROM [extracting] INTO @rowID, @sourceDatabase, @sproc, @start, @end;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @objectId = CAST(REPLACE(RIGHT(@sproc, CHARINDEX('' = '', REVERSE(@sproc))), '']'', '''') AS int);
		SET @statement = NULL; 

		EXEC dbo.[extract_statement]
			@TargetDatabase = @sourceDatabase,
			@ObjectID = @objectId, 
			@OffsetStart = @start, 
			@OffsetEnd = @end,
			@Statement = @statement OUTPUT;

		UPDATE [#statement_blocking]
		SET 
			[definition] = @statement 
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [extracting] INTO @rowID, @sourceDatabase, @sproc, @start, @end;
	END;

	CLOSE [extracting];
	DEALLOCATE [extracting];

	--------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE extracted CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, [database_name], request, blocked_start_offset, blocked_end_offset FROM [#statement_blocked];

	OPEN [extracted];
	FETCH NEXT FROM [extracted] INTO @rowID, @sourceDatabase, @sproc, @start, @end;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @objectId = CAST(REPLACE(RIGHT(@sproc, CHARINDEX('' = '', REVERSE(@sproc))), '']'', '''') AS int);
		SET @statement = NULL; 

		EXEC dbo.[extract_statement]
			@TargetDatabase = @sourceDatabase,
			@ObjectID = @objectId,
			@OffsetStart = @start,
			@OffsetEnd = @end,
			@Statement = @statement OUTPUT;

		UPDATE [#statement_blocked]
		SET 
			[definition] = @statement 
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [extracted] INTO @rowID, @sourceDatabase, @sproc, @start, @end;
	END;

	CLOSE [extracted];
	DEALLOCATE [extracted];

	UPDATE d 
	SET 
		d.[blocking_sproc_statement] = x.[definition]
	FROM 
		[#data] d 
		INNER JOIN [#statement_blocking] x ON ISNULL(d.[normalized_blocking_request], d.[blocking_request]) = x.[request]
			AND d.[blocking_start_offset] = x.[blocking_start_offset] AND d.[blocking_end_offset] = x.[blocking_end_offset];

	UPDATE d 
	SET 
		d.[blocked_sproc_statement] = x.[definition]
	FROM 
		[#data] d 
		INNER JOIN [#statement_blocked] x ON ISNULL(d.[normalized_blocked_request], d.[blocked_request]) = x.[request]
			AND d.[blocked_start_offset] = x.[blocked_start_offset] AND d.[blocked_end_offset] = x.[blocked_end_offset];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Wait Resource Extraction: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		blocking_resource_id, 
		CAST('''' AS nvarchar(MAX)) [definition]
	INTO 
		#resourcing
	FROM 
		[#data] 
	GROUP BY 
		blocking_resource_id; 
		
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		blocked_resource_id, 
		CAST('''' AS nvarchar(MAX)) [definition]
	INTO 
		#resourced
	FROM 
		[#data] 
	GROUP BY 
		blocked_resource_id; 
		
	DECLARE @resourceID nvarchar(80);
	DECLARE @resource nvarchar(2000);
	
	DECLARE resourcing CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, blocking_resource_id FROM [#resourcing];

	OPEN [resourcing];
	FETCH NEXT FROM [resourcing] INTO @rowID, @resourceID;

	WHILE @@FETCH_STATUS = 0 BEGIN

		EXEC dbo.[extract_waitresource]
			@WaitResource = @resourceID,
			@Output = @resource OUTPUT;

		UPDATE [#resourcing] 
		SET 
			[definition] = @resource
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [resourcing] INTO @rowID, @resourceID;
	END;

	CLOSE [resourcing];
	DEALLOCATE [resourcing];

	DECLARE resourced CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, blocked_resource_id FROM [#resourced];

	OPEN [resourced];
	FETCH NEXT FROM [resourced] INTO @rowID, @resourceID;

	WHILE @@FETCH_STATUS = 0 BEGIN

		EXEC dbo.[extract_waitresource]
			@WaitResource = @resourceID,
			@Output = @resource OUTPUT;

		UPDATE [#resourced] 
		SET 
			[definition] = @resource
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [resourced] INTO @rowID, @resourceID;
	END;

	CLOSE [resourced];
	DEALLOCATE [resourced];

	UPDATE d 
	SET 
		d.blocking_resource = x.[definition]
	FROM 
		[#data] d 
		INNER JOIN [#resourcing] x ON d.[blocking_resource_id] = x.[blocking_resource_id];

	UPDATE d 
	SET 
		d.blocked_resource = x.[definition]
	FROM 
		[#data] d 
		INNER JOIN [#resourced] x ON d.[blocked_resource_id] = x.[blocked_resource_id];		
		
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Output / Project + Store:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	USE [{targetDatabase}];
	
	INSERT INTO [{targetSchema}].[{targetTable}] (
		[timestamp],
		[database_name],
		[seconds_blocked],
		[report_id],
		[blocking_id],
		[blocked_id],
		[blocking_xactid],
		[blocking_request],
		[blocking_sproc_statement],
		[blocking_resource_id],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_tran_count],
		[blocking_isolation_level],
		[blocking_status],
		[blocking_start_offset],
		[blocking_end_offset],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_spid],
		[blocked_ecid],
		[blocked_xactid],
		[blocked_request],
		[blocked_sproc_statement],
		[blocked_resource_id],
		[blocked_resource],
		[blocked_wait_time],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_lock_mode],
		[blocked_isolation_level],
		[blocked_status],
		[blocked_start_offset],
		[blocked_end_offset],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report]
	)
	SELECT 
		[timestamp],
		[database_name],
		[seconds_blocked],
		[report_id],
		[blocking_id],
		[blocked_id],
		[blocking_xactid],
		[blocking_request],
		--[normalized_blocking_request],
		[blocking_sproc_statement],
		[blocking_resource_id],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_tran_count],
		[blocking_isolation_level],
		[blocking_status],
		[blocking_start_offset],
		[blocking_end_offset],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_spid],
		[blocked_ecid],
		[blocked_xactid],
		[blocked_request],
		--[normalized_blocked_request],
		[blocked_sproc_statement],
		[blocked_resource_id],
		[blocked_resource],
		[blocked_wait_time],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_lock_mode],
		[blocked_isolation_level],
		[blocked_status],
		[blocked_start_offset],
		[blocked_end_offset],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report]
	FROM 
		[#data]
	ORDER BY 
		row_id; ';

	DECLARE @return int;
	EXEC @return = dbo.[eventstore_etl_session] 
		@SessionName = @SessionName, 
		@EventStoreTarget = @EventStoreTarget, 
		@TranslationDML = @etlSQL, 
		@InitializeDaysBack = @InitializeDaysBack;
	
	RETURN @return; 
GO