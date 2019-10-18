/*


		-- 'Fodder':
			SELECT * FROM sys.dm_exec_requests WHERE session_id IN (SELECT session_id FROM sys.dm_os_waiting_tasks WHERE session_id IS NOT NULL GROUP BY session_id HAVING COUNT(*) > 1);
			SELECT * FROM sys.sysprocesses WHERE spid IN (SELECT session_id FROM sys.dm_os_waiting_tasks WHERE session_id IS NOT NULL GROUP BY session_id HAVING COUNT(*) > 1);


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_parallel_processes','P') IS NOT NULL
	DROP PROC dbo.[list_parallel_processes];
GO

CREATE PROC dbo.[list_parallel_processes]

AS
    SET NOCOUNT ON; 

	-- {copyright}

	SELECT 
		[spid] [session_id],
		[ecid] [execution_id],
		[blocked],
		[dbid] [database_id],
		[cmd] [command],
		[lastwaittype] [wait_type],
		[waitresource] [wait_resource],
		[waittime] [wait_time],
		[status],
		[open_tran],
		[cpu],
		[physical_io],
		[memusage],
		[login_time],
		[last_batch],
		
		[hostname],
		[program_name],
		[loginame],
		[sql_handle],
		[stmt_start],
		[stmt_end]
	INTO
		#ecids
	FROM 
		sys.[sysprocesses] 
	WHERE 
		spid IN (SELECT session_id FROM sys.[dm_os_waiting_tasks] WHERE [session_id] IS NOT NULL GROUP BY [session_id] HAVING COUNT(*) > 1);

	IF NOT EXISTS(SELECT NULL FROM [#ecids]) BEGIN 
		-- short circuit.
		RETURN 0;
	END;


	--TODO: if 2016+ get dop from sys.dm_exec_requests... (or is waiting_tasks?)
	--TODO: execute a cleanup/sanitization of this info + extract code and so on... 
	SELECT 
		[session_id],
		[execution_id],
		[blocked],
		DB_NAME([database_id]) [database_name],
		[command],
		[wait_type],
		[wait_resource],
		[wait_time],
		[status],
		[open_tran],
		[cpu],
		[physical_io],
		[memusage],
		[login_time],
		[last_batch],
		[hostname],
		[program_name],
		[loginame]--,
		--[sql_handle],
		--[stmt_start],
		--[stmt_end]
	FROM 
		[#ecids] 
	ORDER BY 
		-- TODO: whoever is using the most CPU (by session_id) then by ecid... 
		[session_id], 
		[execution_id];

	RETURN 0;
GO