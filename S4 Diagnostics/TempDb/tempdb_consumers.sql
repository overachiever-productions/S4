/*


	TODO: 
		tempdb and spills as 'categories' are NOT descriptive enough. 
			I'm seeing 'spills' which are NOT being recorded by sys.dm_exec_query_stats as SPILLS. 

			Microsoft also does a great job of delineating: 
				1. task vs space usage: 
					https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-session-space-usage-transact-sql?view=sql-server-ver17#remarks
				2. user vs internal objects:  
					https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-session-space-usage-transact-sql?view=sql-server-ver17#user-objects

	TODO: 
		THIS is a concern: 
			| Work table caching, temporary table caching, and deferred drop operations affect the number of pages allocated and deallocated in a specified task.

			FROM: https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-task-space-usage-transact-sql?view=sql-server-ver17#remarks 
			i.e., WHAT happens if/when there's, say, a 2GB temp table that is cached and/or DEFERRED for deallocation? 
				deferred_dealloc at the SESSION level would let me see what's going on at the SESSSION level. 
			
			BUT ... I don't know what my insight into CACHED objects is at task/session level. 



	.RESULTS 
		/table ... 
		- active_user		| decimal(10,3) | IN-FLIGHT temp tables/variables (in GB)
		- active_sys		| decimal(10,3) | IN-FLIGHT spills (in GB)
		- total_user		| decimal(10,3) | Session-Lifetime temp objects (in GB)
		- total_sys			| decimal(10,3) | Session-Lifetime spills (in GB)


	.REMARKS

	#### 'Negative' tempdb usage
	Note that it IS possible for tasks (currently executing operations) and/or sessions to have NEGATIVE tempdb usage. 
	This occurs when the # of `dealloc` pages is GREATER THAN the # of `alloc` pages. 
	- This is a 'normal' / expected behavior ... and is NOT an error. 
	- It can occur when a session has completed some operations that have deallocated tempdb space, but still has some other operations that are actively using tempdb space. 
	- It can also occur when a session has completed all operations, but still has some tempdb space allocated (e.g., for version store or other internal objects).
	Feel free to take a look at this yourself by running the following: 
	```sql

	SELECT * FROM sys.dm_db_task_space_usage 
	WHERE 
		(user_objects_alloc_page_count - user_objects_dealloc_page_count < 0)
		OR 
		(internal_objects_alloc_page_count - internal_objects_alloc_page_count < 0);
	```

	And/or a similar operation against `sys.dm_db_session_space_usage` will show similar results. 

	Importantly, though, `dbo.tempdb_consumers` INTENTIONALLY shows these 'negative' values as they CAN be helpful in tracking down who/what is EITHER using 
	the tempdb right now and/or has JUST BEEN using larger allocations (that might've JUST 'barely' been deallocated).



*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[tempdb_consumers]', N'P') IS NOT NULL
	DROP PROC dbo.[tempdb_consumers];
GO

CREATE PROC dbo.[tempdb_consumers]
	@serialized_output				xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 
	

	-- {copyright}
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Total Space (available vs used):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @serializedOutput xml;
	EXEC dbo.[tempdb_details]
		@serialized_output = @serializedOutput OUTPUT;

	DECLARE @tempdbDetails table ( 
		[row_id] int IDENTITY(1,1) NOT NULL,	
		[path] sysname NOT NULL,
		[value] sysname NOT NULL 
	);

	INSERT INTO @tempdbDetails ([path], [value])
	SELECT 
		[t].[f].value(N'@path[1]', N'sysname') [path], 
		[t].[f].value(N'.', N'sysname') [v]
	FROM 
		@serializedOutput.nodes(N'//tempdb/facet') AS [t]([f])
	WHERE 
		[t].[f].value(N'@classification[1]', N'sysname') = N'INFO'
		AND [t].[f].value(N'@path[1]', N'sysname') NOT LIKE N'%disks';

	DECLARE @sizeString sysname = REPLACE((SELECT [value] FROM @tempdbDetails WHERE [path] = N'data_files.total_size'), N'GB', N'');
	DECLARE @totalSize decimal(10,3) = CAST(@sizeString AS decimal(10,3));

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Consumers:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH [tasks] AS ( 
		SELECT 
			[session_id],
			COUNT([exec_context_id]) [threads],
			SUM([user_objects_alloc_page_count] - [user_objects_dealloc_page_count]) [user],
			SUM([internal_objects_alloc_page_count] - [internal_objects_dealloc_page_count]) [internal]
		FROM 
			sys.[dm_db_task_space_usage]
		GROUP BY 
			[session_id]
	), 
	[usage] AS ( 
		SELECT 
			[session_id],
			ISNULL([user_objects_alloc_page_count], 0) - ISNULL([user_objects_dealloc_page_count], 0) [session_user],
			ISNULL([internal_objects_alloc_page_count], 0) - ISNULL([internal_objects_dealloc_page_count], 0) [session_internal], 
			ISNULL([user_objects_deferred_dealloc_page_count], 0) [session_user_deferred]
		FROM 
			sys.[dm_db_session_space_usage]
	),
	[requests] AS ( 
		SELECT 
			[r].[session_id],
			[r].[start_time],
			[r].[status],
			[r].[command],
			[r].[sql_handle],
			[r].[statement_start_offset],
			[r].[statement_end_offset],
			[r].[plan_handle],
			[r].[database_id],
			[r].[blocking_session_id],
			[r].[wait_type],
			[r].[wait_time],
			[r].[last_wait_type],
			[r].[wait_resource],
			[r].[open_transaction_count],
			[r].[percent_complete],
			OBJECT_NAME([t].[objectid], [t].[dbid]) [module],
			SUBSTRING([t].[text], ([r].[statement_start_offset] / 2) + 1, (CASE WHEN [r].[statement_end_offset] < 1 THEN DATALENGTH([t].[text]) ELSE ([r].[statement_end_offset] - [r].[statement_start_offset])/2 END) + 1) [statement]
		FROM 
			sys.[dm_exec_requests] [r]
			OUTER APPLY sys.[dm_exec_sql_text]([r].[sql_handle]) [t]
			OUTER APPLY sys.dm_exec_query_plan([r].[plan_handle]) [p]
	)

	SELECT 
		[s].[session_id],
		[s].[host_name],
		[s].[program_name],
		[s].[login_name],
		CASE WHEN [r].[session_id] IS NULL THEN N'inactive' ELSE [s].[status] END [status],
		[s].[last_request_start_time],
		[s].[is_user_process],
		[s].[database_id],
		[s].[open_transaction_count], 
		[t].[threads], 
		[r].[plan_handle],
		[r].[statement_start_offset],
		[r].[statement_end_offset],
		CAST(ISNULL([t].[user], 0) * .00000762 AS decimal(10,3)) [live_user],    -- instead of * 8 / 1048576 ... could use * .00000762 as well. odd ... but, works. 
		CAST(ISNULL([t].[internal], 0) * .00000762 AS decimal(10,3)) [live_sys], 
		CAST(ISNULL([u].[session_user], 0) * .00000762 AS decimal(10,3)) [total_user],
		CAST(ISNULL([u].[session_internal], 0) * .00000762 AS decimal(10,3)) [total_sys], 
		CAST(ISNULL([u].[session_user_deferred], 0) * .00000762 AS decimal(10,3)) [total_deferred],
		CASE WHEN [r].[module] IS NOT NULL THEN N'MODULE: [' + [r].[module] + N']' ELSE [r].[command] END [operation],
		[r].[statement], 
		CAST(N'' AS nvarchar(MAX)) [statement_plan], 
		CAST(0.0 AS decimal(10,3)) [active], 
		CAST(0.0 AS decimal(10,3)) [total]
	INTO 
		#consumers
	FROM 
		sys.[dm_exec_sessions] [s]
		LEFT OUTER JOIN [requests] [r] ON [s].[session_id] = [r].[session_id]
		LEFT OUTER JOIN [usage] [u] ON [s].[session_id] = [u].[session_id]
		LEFT OUTER JOIN [tasks] [t] ON [s].[session_id] = [t].[session_id]
	WHERE 
		[s].[database_id] > 0;

	UPDATE [x]
	SET 
		[x].[active] = CAST(ISNULL([x].[live_user], 0) + ISNULL([x].[live_sys], 0) AS decimal(10,3)),
		[x].[total] = CAST(ISNULL([x].[total_user], 0) + ISNULL([x].[total_sys], 0) - ISNULL([x].[total_deferred], 0) AS decimal(10,3)), 
		[x].[statement_plan] = CASE WHEN [x].[statement_end_offset] > 0 THEN [sp].[query_plan] ELSE NULL END
	FROM 
		[#consumers] [x]
		OUTER APPLY sys.[dm_exec_text_query_plan]([x].[plan_handle], [x].[statement_start_offset], [x].[statement_end_offset]) [sp]
	WHERE 
		[session_id] IS NOT NULL; 


	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SELECT 
		[c].[session_id],
		[c].[live_user],
		[c].[live_sys],
		[c].[total_user],
		[c].[total_sys],
		[c].[total_deferred],

		CAST(ABS([c].[active]) * 100. / @totalSize AS decimal(6,3)) [active_%],
		CAST(ABS([c].[total]) * 100. / @totalSize AS decimal(6,3)) [total_%],

		[c].[last_request_start_time],
		[c].[is_user_process],
		[c].[open_transaction_count] [tx_count],
		[c].[threads] [task_count],
		[c].[status],
		[d].[name] [database],
		[c].[host_name],
		[c].[program_name],
		[c].[login_name] [principal],

		[b].[event_info] [batch], 
		[c].[operation], 
		[c].[statement], 
		
		[p].[query_plan] [command_plan], 
		
		CASE 
			WHEN TRY_CAST([c].[statement_plan] AS xml) IS NULL THEN (SELECT NCHAR(13) + NCHAR(10) + NCHAR(9) + N'This plan is too large to display. Remove the TOP line, and the BOTTOM line, then save as .sqlplan and open.' + NCHAR(13) + NCHAR(10) +
				REPLACE([c].[statement_plan], N'</ShowPlanXML>', N'</ShowPlanXML>' + NCHAR(13) + NCHAR(10)) [processing-instruction(Plan_Too_Large)] FOR XML PATH(N''), TYPE) 
			ELSE TRY_CAST([c].[statement_plan] AS xml)
		END [statement_plan]
	FROM 
		#consumers [c]
		LEFT OUTER JOIN sys.[databases] [d] ON [c].[database_id] = [d].[database_id]
		OUTER APPLY sys.dm_exec_query_plan([c].[plan_handle]) [p]
		OUTER APPLY sys.[dm_exec_input_buffer]([c].[session_id], NULL) [b]
	WHERE 
		([c].[live_user] + [c].[live_sys] + [c].[total_user] + [c].[total_sys]) <> 0
	ORDER BY 
		ABS([c].[active]) + ABS([c].[total]) DESC;

	RETURN 0;
GO	