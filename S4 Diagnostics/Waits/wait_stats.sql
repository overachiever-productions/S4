/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.wait_stats','P') IS NOT NULL
	DROP PROC dbo.[wait_stats];
GO

CREATE PROC dbo.[wait_stats]
	@top								int				= 20,	
	@vector_tag							sysname			= NULL,
	@exclusions							nvarchar(MAX)	= N'{NOISE}',  -- Current options are [ NULL | NONE | {NOISE} ] where NULL is the same as NONE|{NONE}
	--@ExcludeSynchronizationWaits		bit				= 1,
	--@ExcludeOtherWaitTypeHere			bit				= x
	@serialized_output					xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @vector_tag = NULLIF(@vector_tag, N'');
	SET @exclusions = NULLIF(@exclusions, N'');
	SET @exclusions = NULLIF(@exclusions, N'NONE');
	SET @exclusions = NULLIF(@exclusions, N'{NONE}');

	/* 
		Special thanks to Glenn Berry (blog: https://glennsqlperformance.com/glenns-blog/ | Twitter: @GlennAlanBerry ) for core concepts and 
		ideas behind this aggregation of wait-stats diagnostic.
	*/

	CREATE TABLE #exclusions ( 
		[wait_type] sysname	
	);
	
	IF @exclusions IS NOT NULL BEGIN

		SET @exclusions = UPPER(@exclusions);

		IF @exclusions LIKE N'%{NOISE}%' BEGIN
			INSERT INTO [#exclusions] ([wait_type])
			VALUES 
				(N'AZURE_IMDS_VERSIONS'), (N'BROKER_EVENTHANDLER'), (N'BROKER_RECEIVE_WAITFOR'), (N'BROKER_TASK_STOP'), (N'BROKER_TO_FLUSH'), (N'BROKER_TRANSMITTER'), 
				(N'CHECKPOINT_QUEUE'),(N'CHKPT'), (N'CLR_AUTO_EVENT'), (N'CLR_MANUAL_EVENT'), (N'CLR_SEMAPHORE'), (N'DBMIRROR_DBM_EVENT'), (N'DBMIRROR_EVENTS_QUEUE'), 
				(N'DBMIRROR_WORKER_QUEUE'), (N'DBMIRRORING_CMD'), (N'DIRTY_PAGE_POLL'), (N'DISPATCHER_QUEUE_SEMAPHORE'), (N'EXECSYNC'), (N'FSAGENT'), 
				(N'FT_IFTS_SCHEDULER_IDLE_WAIT'), (N'FT_IFTSHC_MUTEX'), (N'HADR_CLUSAPI_CALL'), (N'HADR_FILESTREAM_IOMGR_IOCOMPLETIO(N'), (N'HADR_LOGCAPTURE_WAIT'), 
				(N'HADR_NOTIFICATION_DEQUEUE'), (N'HADR_TIMER_TASK'), (N'HADR_WORK_QUEUE'), (N'HTBUILD_AGG'), (N'HTDELETE_AGG'), (N'KSOURCE_WAKEUP'), 
				(N'LAZYWRITER_SLEEP'), (N'LOGMGR_QUEUE'), (N'MEMORY_ALLOCATION_EXT'), (N'ONDEMAND_TASK_QUEUE'),(N'PARALLEL_REDO_DRAIN_WORKER'), 
				(N'PARALLEL_REDO_LOG_CACHE'), (N'PARALLEL_REDO_TRAN_LIST'), (N'PARALLEL_REDO_WORKER_SYNC'), (N'PARALLEL_REDO_WORKER_WAIT_WORK'),
				(N'PREEMPTIVE_HADR_LEASE_MECHANISM'), (N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS'), (N'PREEMPTIVE_OS_LIBRARYOPS'), (N'PREEMPTIVE_OS_COMOPS'), 
				(N'PREEMPTIVE_OS_PIPEOPS'), (N'PREEMPTIVE_OS_AUTHENTICATIONOPS'), (N'PREEMPTIVE_OS_GENERICOPS'), (N'PREEMPTIVE_OS_VERIFYTRUST'), 
				(N'PREEMPTIVE_OS_DELETESECURITYCONTEXT'), (N'PREEMPTIVE_OS_REPORTEVENT'), (N'PREEMPTIVE_OS_FILEOPS'), (N'PREEMPTIVE_OS_DEVICEOPS'), 
				(N'PREEMPTIVE_OS_QUERYREGISTRY'), (N'PREEMPTIVE_OS_WRITEFILE'), (N'PREEMPTIVE_OS_WRITEFILEGATHER'), (N'PREEMPTIVE_XE_CALLBACKEXECUTE'), 
				(N'PREEMPTIVE_XE_DISPATCHER'), (N'PREEMPTIVE_XE_GETTARGETSTATE'), (N'PREEMPTIVE_XE_SESSIONCOMMIT'), (N'PREEMPTIVE_XE_TARGETINIT'), 
				(N'PREEMPTIVE_XE_TARGETFINALIZE'), (N'POPULATE_LOCK_ORDINALS'), (N'PWAIT_ALL_COMPONENTS_INITIALIZED'), (N'PWAIT_DIRECTLOGCONSUMER_GETNEXT'), 
				(N'PVS_PREALLOCATE'), (N'PWAIT_EXTENSIBILITY_CLEANUP_TASK'), (N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'), (N'QDS_ASYNC_QUEUE'), 
				(N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'), (N'REQUEST_FOR_DEADLOCK_SEARCH'), (N'RESOURCE_QUEUE'), (N'SERVER_IDLE_CHECK'), 
				(N'SLEEP_BPOOL_FLUSH'), (N'SLEEP_DBSTARTUP'), (N'SLEEP_DCOMSTARTUP'), (N'SLEEP_MASTERDBREADY'), (N'SLEEP_MASTERMDREADY'), (N'SLEEP_PHYSMASTERDBREADY'), 
				(N'SLEEP_MASTERUPGRADED'), (N'SLEEP_MSDBSTARTUP'), (N'SLEEP_SYSTEMTASK'), (N'SLEEP_TASK'), (N'SLEEP_TEMPDBSTARTUP'), (N'SNI_HTTP_ACCEPT'), 
				(N'SOS_WORK_DISPATCHER'), (N'SP_SERVER_DIAGNOSTICS_SLEEP'), (N'SOS_WORKER_MIGRATION'), (N'VDI_CLIENT_OTHER'), (N'SQLTRACE_BUFFER_FLUSH'), 
				(N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP'), (N'SQLTRACE_WAIT_ENTRIES'), (N'STARTUP_DEPENDENCY_MANAGER'), (N'WAIT_FOR_RESULTS'), 
				(N'WAITFOR_TASKSHUTDOW(N'), (N'WAIT_XTP_HOST_WAIT'), (N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG'), (N'WAIT_XTP_CKPT_CLOSE'), (N'WAIT_XTP_RECOVERY'), 
				(N'XE_BUFFERMGR_ALLPROCESSED_EVENT'), (N'XE_DISPATCHER_JOI(N'), (N'XE_DISPATCHER_WAIT'), (N'XE_LIVE_TARGET_TVF'), (N'XE_TIMER_EVENT');	
		END;

		-- if {FT}
		-- if {HA} 
		-- if {etc} 

	END;
	
	SELECT
		[wait_type],
		[waiting_tasks_count] [count],
		CAST([wait_time_ms] / 1000. AS decimal(22,2)) [wait],
		CAST([max_wait_time_ms] / 1000. AS decimal(22,2)) [max],
		CAST([signal_wait_time_ms] / 1000. AS decimal(22,2)) [signal]
	INTO 
		#current
	FROM
		[sys].[dm_os_wait_stats]
	WHERE
		[wait_time_ms] > 100;
	
	IF EXISTS (SELECT NULL FROM [#exclusions]) 
		DELETE [#current] WHERE [wait_type] IN (SELECT [wait_type] FROM [#exclusions]);
	
	IF @vector_tag IS NOT NULL BEGIN 
		DECLARE @cached_date datetime, @cached_xml xml;

		DECLARE @current xml = (
			SELECT 
				[count] [@count],
				[wait] [@wait],
				[max] [@max],
				[signal] [@signal],
				[wait_type] [*]
			FROM 
				[#current]
			FOR XML PATH(N'wait'), ROOT(N'waits'), TYPE
		);
		
		EXEC dbo.[inserlect_cache]
			@vector_type = @@PROCID,
			@vector_key = @vector_tag,
			@current_xml = @current,
			@cached_date = @cached_date OUTPUT,
			@cached_xml = @cached_xml OUTPUT;
		
		IF @cached_date IS NOT NULL BEGIN
			TRUNCATE TABLE [#current];

-- TODO: need to verify that logic for "wait X was in cached, but isn't in current" works. 
--			and that logic for "wait wasn't in cached, but now it's substantial in current" works as well. 
--				just need to make sure I can get BOTH wait-types (i.e., from both scenarios) in place. 
--				from there, it's an ORDER BY (vectored)[wait] DESC.
--					and a COALESCE on [old_name], [new_name]
			WITH [old] AS (
				SELECT 
					[w].[wait].value(N'(text())[1]', N'sysname') [type],
					[w].[wait].value(N'(@count)[1]', N'bigint') [count],
					[w].[wait].value(N'(@wait)[1]', N'decimal(22,2)') [wait],
					[w].[wait].value(N'(@max)[1]', N'decimal(22,2)') [max],
					[w].[wait].value(N'(@signal)[1]', N'decimal(22,2)') [signal]
				FROM 
					@cached_xml.nodes(N'//waits/wait') [w]([wait])
			), 
			[current] AS ( 
				SELECT 
					[w].[wait].value(N'(text())[1]', N'sysname') [type],
					[w].[wait].value(N'(@count)[1]', N'bigint') [count],
					[w].[wait].value(N'(@wait)[1]', N'decimal(22,2)') [wait],
					[w].[wait].value(N'(@max)[1]', N'decimal(22,2)') [max],
					[w].[wait].value(N'(@signal)[1]', N'decimal(22,2)') [signal]
				FROM 
					@current.nodes(N'//waits/wait') [w]([wait])				

			), 
			[vectored] AS ( 
				SELECT 
					[old].[type],
					[old].[count],
					[old].[wait],
					[old].[max],
					[old].[signal],
					[current].[type] [new_type],
					[current].[count] [new_count],
					[current].[wait] [new_wait],
					[current].[max] [new_max],
					[current].[signal] [new_signal] 
				FROM 
					[old] 
					LEFT OUTER JOIN [current] ON [old].[type] = [current].[type]
			) 

			INSERT INTO [#current] ([wait_type], [count], [wait], [max], [signal])
			SELECT 
				COALESCE([type], [new_type]) [wait_type],
				ISNULL([new_count], 0)	- ISNULL([count], 0) [count],
				ISNULL([new_wait], 0)	- ISNULL([wait], 0) [wait],
				ISNULL([new_max], 0)	- ISNULL([max], 0) [max],
				ISNULL([new_signal], 0) - ISNULL([signal], 0) [signal]
			FROM 
				[vectored]
			ORDER BY 
				ISNULL([vectored].[new_wait], 0) - ISNULL([wait], 0) DESC;
		END;
	END;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Summarize:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT TOP(@top)
		IDENTITY(int, 1,1) [row_id],
		[wait_type],
		[count] [total_count],
		[wait] [total_seconds],
		--[signal] [signal_seconds], 
		--[wait] - [signal] [resource_seconds], 

		CASE WHEN SUM([count]) OVER () = 0 THEN 0 ELSE CAST([count] * 100. / SUM([count]) OVER () AS decimal(5,2)) END [count_pct], 
		CASE WHEN SUM([wait]) OVER () = 0 THEN 0 ELSE CAST([wait] * 100. / SUM([wait]) OVER () AS decimal(5,2)) END [wait_pct], 
		CASE WHEN SUM([signal]) OVER () = 0 THEN 0 ELSE CAST([signal] * 100. / SUM([signal]) OVER () AS decimal(5,2)) END [signal_pct], 
		CASE WHEN SUM(([wait] - [signal])) OVER () = 0 THEN 0 ELSE CAST(([wait] - [signal]) * 100. / SUM(([wait] - [signal])) OVER () AS decimal(5,2)) END [resource_pct],

		CASE WHEN SUM([count]) OVER () = 0 THEN 0 ELSE CAST([wait] / [count] AS decimal(22,2)) END [avg_seconds],
		[max] [max_seconds],
		CASE WHEN SUM([count]) OVER () = 0 THEN 0 ELSE CAST([signal] / [count] AS decimal(22,2)) END [avg_signal],
		CASE WHEN SUM([count]) OVER () = 0 THEN 0 ELSE CAST(([wait] - [signal]) / [count] AS decimal(22,2)) END [avg_resource]
	INTO 
		#final
	FROM 
		[#current]
	WHERE 
		[count] > 0
	ORDER BY 
		[wait] DESC;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Return or Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		
		SELECT @serialized_output = (
			SELECT
				[row_id] [@row_id],
				[total_count] [@total_count],
				[total_seconds] [@total_seconds],
				[count_pct] [@count_pct],
				[wait_pct] [@wait_pct],
				[signal_pct] [@signal_pct],
				[resource_pct] [@resource_pct],
				[avg_seconds] [@avg_seconds],
				[max_seconds] [@max_seconds],
				[avg_signal] [@avg_signal],
				[avg_resource] [@avg_resource],
				[wait_type] [*]
			FROM 
				[#final]
			ORDER BY 
				[row_id]
			FOR XML PATH(N'wait'), ROOT(N'waits'), TYPE
		);

		RETURN 0;
	END;

	SELECT
		[row_id],
		[wait_type],
		[total_count],
		[total_seconds],
		[count_pct],
		[wait_pct],
		[signal_pct],
		[resource_pct],
		[avg_seconds],
		[max_seconds],
		[avg_signal],
		[avg_resource]	
	FROM 
		[#final]
	ORDER BY 
		[row_id];
	
	RETURN 0;
GO