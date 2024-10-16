/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[list_top]','P') IS NOT NULL
	DROP PROC dbo.[list_top];
GO

CREATE PROC dbo.[list_top]
	@TopRequests			int			= 20
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @TopRequests = ISNULL(@TopRequests, 20);
	
	SELECT
		r.session_id, 
		r.blocking_session_id [blocked_by],

		DB_NAME(r.database_id) [db_name],	
		t.[text],
		r.cpu_time,
		r.reads,
		r.writes,
		r.total_elapsed_time [elapsed_time], 
		r.wait_time, 
		r.last_wait_type,
		ISNULL(CAST((g.granted_memory_kb / 1024.0) as decimal(20,2)),0) AS granted_mb, -- memory grants
		r.[status],
		r.command, 
		s.[program_name],
		s.[host_name],
		s.[login_name],
		r.percent_complete,
		CASE s.transaction_isolation_level 
			WHEN 0 THEN 'Unspecified' 
	        WHEN 1 THEN 'ReadUncomitted' 
	        WHEN 2 THEN 'Readcomitted' 
	        WHEN 3 THEN 'Repeatable' 
	        WHEN 4 THEN 'Serializable' 
	        WHEN 5 THEN 'Snapshot' 
		END isolation_level,		
		r.open_transaction_count [open_tran],
		TRY_CAST(tqp.query_plan AS xml) [statement_plan],
		p.query_plan [batch_plan],  -- plan for entire operation/query
		r.[plan_handle]
	FROM 
		sys.dm_exec_requests r
		INNER JOIN (
			SELECT TOP (@TopRequests) session_id FROM sys.dm_exec_requests 
			WHERE session_id > 50
				AND last_wait_type NOT IN (
					'BROKER_TO_FLUSH','HADR_FILESTREAM_IOMGR_IOCOMPLETION', 
					'BROKER_EVENTHANDLER','BROKER_TRANSMITTER','BROKER_TASK_STOP', 'BROKER_RECEIVE_WAITFOR', 'BROKER_TO_FLUSH', 
					'MISCELLANEOUS', 
					'FT_IFTSHC_MUTEX', 
					'DBMIRRORING_CMD','DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_WORKER_QUEUE', 
					'VDI_CLIENT_OTHER', 'HADR_WORK_QUEUE', 'HADR_NOTIFICATION_DEQUEUE'
				)
				AND [command] NOT IN ('BRKR TASK')
			ORDER BY cpu_time DESC		
		) x ON r.session_id = x.session_id
		INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
		OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
		OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) p
		OUTER APPLY sys.dm_exec_text_query_plan(r.plan_handle, r.statement_start_offset, r.statement_end_offset) tqp
		LEFT OUTER JOIN sys.dm_exec_query_memory_grants g ON r.session_id = g.session_id
	WHERE	
		r.session_id != @@SPID
	ORDER BY 
		r.cpu_time DESC;

	RETURN 0;
GO