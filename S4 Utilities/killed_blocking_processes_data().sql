/*

	REFACTOR: 
		dbo.killed_blocking_processes() .... not sure why I have 'view' in front of this. 
			might've been some odd idea for an 'action word' (cough: verb) at the front. 
			But... a) meh, b) sounds too much like a VIEW...  and c) makes this too long. 
		NOTE: there's a reference to this UDF in ... dbo.kill_blocking_processes. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[killed_blocking_processes_data]','IF') IS NOT NULL
	DROP FUNCTION dbo.[killed_blocking_processes_data];
GO

CREATE FUNCTION dbo.[killed_blocking_processes_data]()
RETURNS table
AS
    
	-- {copyright}
	RETURN
	WITH core AS ( 

		SELECT 
			[s].[row_id] [instance_id],
			LAG([s].[row_id], 1, -1) OVER (ORDER BY [s].[row_id]) [previous_id],
			[s].[timestamp],
			[s].[print_only],

			[nodes].[row].value(N'(action)[1]', N'sysname') [action],
			[nodes].[row].value(N'(outcome)[1]', N'sysname') [outcome],
			[nodes].[row].value(N'(database)[1]', N'sysname') [database],
			[nodes].[row].value(N'(blocking_chain)[1]', N'sysname') [blocking_chain],
			[nodes].[row].value(N'(session_id)[1]', N'int') [session_id],
			[nodes].[row].value(N'(command)[1]', N'sysname') [command],
			[nodes].[row].value(N'(status)[1]', N'sysname') [status],
			[nodes].[row].value(N'(statement)[1]', N'nvarchar(MAX)') [statement],
			[nodes].[row].value(N'(duration)[1]', N'sysname') [duration],
			[nodes].[row].value(N'(wait_type)[1]', N'sysname') [wait_type],
			[nodes].[row].value(N'(wait_resource)[1]', N'sysname') [wait_resource],
			[nodes].[row].value(N'(is_system)[1]', N'sysname') [is_system],
			[nodes].[row].value(N'(transaction_state)[1]', N'sysname') [transaction_state],
			[nodes].[row].value(N'(transaction_type)[1]', N'sysname') [transaction_type], 
			[nodes].[row].value(N'(isolation_level)[1]', N'sysname') [isolation_level],
			[nodes].[row].value(N'(application)[1]', N'sysname') [application],
			[nodes].[row].value(N'(host)[1]', N'sysname') [host],
			[nodes].[row].value(N'(ip)[1]', N'sysname') [ip],
			[nodes].[row].value(N'(principal)[1]', N'sysname') [principal]

		FROM 
			dbo.[killed_processes] [s]
			OUTER APPLY [s].[snapshot].nodes(N'blocked_processes/row') [nodes]([row])
		WHERE 
			[type] = N'blocking_processes'

	) 

	SELECT 
		[instance_id],
		CASE WHEN [instance_id] = [previous_id] THEN N'' ELSE CAST([instance_id] AS sysname) END [id],
		CASE WHEN [instance_id] = [previous_id] THEN N'' ELSE CONVERT(sysname, [timestamp], 120) END[timestamp],
		[database],
		[blocking_chain],
		[session_id],
		[command],
		[status],
		N'' [ ],
		[action],
		[outcome],
		[statement],
		[duration],
		[wait_type],
		[wait_resource],
		[is_system],
		[transaction_state], 
		[transaction_type], 
		[isolation_level],
		[application], 
		[host], 
		[ip], 
		[principal]		
	FROM 
		core;
GO