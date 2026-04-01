/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_deadlocks]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_deadlocks];
GO

CREATE PROC dbo.[eventstore_etl_deadlocks]
	@SessionName				sysname			= N'eventstore_deadlocks', 
	@EventStoreTarget			sysname			= N'admindb.dbo.eventstore_deadlocks',
	@InitializeDaysBack			int				= 5
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @SessionName = ISNULL(NULLIF(@SessionName, N''), N'eventstore_deadlocks');
	SET @EventStoreTarget = ISNULL(NULLIF(@EventStoreTarget, N''), N'admindb.dbo.eventstore_deadlocks');
	SET @InitializeDaysBack = ISNULL(@InitializeDaysBack, 5);		

	DECLARE @etlSQL nvarchar(MAX) = N'
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- XEL Data Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH core AS ( 
		SELECT 
			[nodes].[row].value(N''(@timestamp)[1]'', N''datetime2'') AS [timestamp], 
			ROW_NUMBER() OVER (ORDER BY [nodes].[row].value(N''(@timestamp)[1]'', N''datetime2'')) [deadlock_id], 
			[nodes].[row].query(N''.'') [data]
		FROM 
			@EventData.nodes(N''//event'') [nodes]([row])

	), 
	processes AS ( 
		SELECT 
			[c].[timestamp],
			[c].[deadlock_id],
			[nodes].[row].value(N''@id'', N''varchar(30)'') [process_id], 
			[nodes].[row].value(N''@lockMode'', N''varchar(10)'') [lock_mode], 
			[nodes].[row].value(N''@spid'', N''int'') [session_id], 
			[nodes].[row].value(N''@ecid'', N''int'') [ecid], 
			[nodes].[row].value(N''@clientapp'', N''varchar(100)'') [application_name], 
			[nodes].[row].value(N''@hostname'', N''varchar(100)'') [host_name], 
			[nodes].[row].value(N''@trancount'', N''int'') [transaction_count], 
			[nodes].[row].value(N''@waitresource'', N''varchar(200)'') [wait_resource], 
			[nodes].[row].value(N''@waittime'', N''int'') [wait_time], 
			[nodes].[row].value(N''@logused'', N''bigint'') [log_used], 
			[nodes].[row].value(N''(inputbuf)[1]'', N''nvarchar(max)'') [input_buffer],
			[nodes].[row].value(N''(executionStack/frame/@procname)[1]'', N''nvarchar(max)'') [proc],
			[nodes].[row].value(N''(executionStack/frame)[1]'', N''nvarchar(max)'') [statement],
			COUNT(*) OVER (PARTITION BY [c].[deadlock_id]) [process_count], 
			[c].[data]
		FROM 
			core c
			CROSS APPLY c.data.nodes(N''//deadlock/process-list/process'') [nodes]([row])
	), 
	victims AS ( 
		SELECT 
			[c].[deadlock_id], 
			[v].[values].value(N''@id'', N''varchar(20)'') [victim_id]
		FROM 
			core [c]
			CROSS APPLY [c].[data].nodes(N''//deadlock/victim-list/victimProcess'') v ([values])
	), 
	aggregated AS ( 
		SELECT 
			[c].[deadlock_id], 
			[p].[process_id],
			[p].[session_id],
			[p].[application_name],
			[p].[host_name], 
			[p].[input_buffer]
		FROM 
			[core] [c]
			INNER JOIN [processes] [p] ON [c].[deadlock_id] = [p].[deadlock_id]
			LEFT OUTER JOIN [victims] [v] ON [v].[deadlock_id] = [c].[deadlock_id] AND [p].[process_id] = [v].[victim_id]	
	) 

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[a].[deadlock_id],
		[p].[timestamp],  /* S4-536 - i.e., pre-projection here breaks ability to filter later on. */
		[p].[process_count],
		CASE WHEN [p].[ecid] = 0 THEN CAST(a.[session_id] AS sysname) ELSE CAST([a].[session_id] AS sysname) + N'' ('' + CAST([p].[ecid] AS sysname) + N'')'' END [session_id],
		[a].[application_name],
		[a].[host_name],
		[p].[transaction_count],
		[p].[lock_mode],
		([p].[wait_time]) [wait_time_ms],  
		[p].[log_used],
		[p].[wait_resource] [wait_resource_id],
		CAST('''' AS varchar(2000)) [wait_resource],
		[p].[proc],
		[p].[statement],
		[a].[input_buffer],
		[p].[data] [deadlock_graph]
	INTO 
		#shredded
	FROM 
		[aggregated] a 
		INNER JOIN [processes] p ON [a].[deadlock_id] = [p].[deadlock_id] AND [a].[process_id] = [p].[process_id]
	ORDER BY 
		--a.[deadlock_id], a.[line_id];
		[a].[deadlock_id];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Wait Resource Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[wait_resource_id], 
		CAST('''' AS nvarchar(MAX)) [definition]
	INTO 
		#waits
	FROM 
		[#shredded] 
	GROUP BY 
		[wait_resource_id]; 		

	DECLARE @rowID int;
	DECLARE @resourceID nvarchar(80);
	DECLARE @resource nvarchar(2000);
	
	DECLARE waiter CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, [wait_resource_id] FROM [#waits];

	OPEN [waiter];
	FETCH NEXT FROM [waiter] INTO @rowID, @resourceID;

	WHILE @@FETCH_STATUS = 0 BEGIN
		EXEC dbo.[extract_waitresource]
			@WaitResource = @resourceID,
			@Output = @resource OUTPUT;

		UPDATE #waits 
		SET 
			[definition] = @resource
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [waiter] INTO @rowID, @resourceID;
	END;

	CLOSE [waiter];
	DEALLOCATE [waiter];

	UPDATE s 
	SET 
		s.wait_resource = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#waits] x ON s.[wait_resource_id] = x.[wait_resource_id];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection / Storage: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	USE [{targetDatabase}];

	INSERT INTO [{targetSchema}].[{targetTable}] (
		[timestamp],
		[deadlock_id],
		[process_count],
		[session_id],
		[application_name],
		[host_name],
		[transaction_count],
		[lock_mode],
		[wait_time_ms],
		[log_used],
		[wait_resource_id],
		[wait_resource],
		[proc],
		[statement],
		[input_buffer],
		[deadlock_graph]
	)
	SELECT 
		[timestamp],
		[deadlock_id],
		[process_count],
		[session_id],
		[application_name],
		[host_name],
		[transaction_count],
		[lock_mode],
		[wait_time_ms],
		[log_used],
		[wait_resource_id],
		[wait_resource],
		[proc],
		[statement],
		[input_buffer],
		[deadlock_graph] 
	FROM 
		[#shredded]
	ORDER BY 
		[row_id]; ';	

	DECLARE @return int;
	EXEC @return = dbo.[eventstore_etl_session] 
		@SessionName = @SessionName, 
		@EventStoreTarget = @EventStoreTarget, 
		@TranslationDML = @etlSQL, 
		@InitializeDaysBack = @InitializeDaysBack;
	
	RETURN @return;
GO