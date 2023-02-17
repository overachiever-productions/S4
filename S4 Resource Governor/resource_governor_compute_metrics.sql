/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.resource_governor_compute_metrics','P') IS NOT NULL
	DROP PROC dbo.[resource_governor_compute_metrics];
GO

CREATE PROC dbo.[resource_governor_compute_metrics]
	@Mode				sysname			= N'POOL_AND_WORKGROUP'		-- POOL | WORKGROUP | POOL_AND_WORKGROUP
AS
    SET NOCOUNT ON; 

	--{copyright}

	SET @Mode = ISNULL(NULLIF(@Mode, N''), N'POOL_AND_WORKGROUP');
	
	IF UPPER(@Mode) IN (N'POOL', N'POOL_AND_WORKGROUP') BEGIN 
		SELECT 
			[p].[name] + N' (' + CAST([p].[pool_id] AS sysname) + N')' [pool],
			CAST([p].[min_cpu_percent] AS sysname) + N' - ' + CAST([p].[max_cpu_percent] AS sysname) [cpu_%_range],
			[p].[cap_cpu_percent] [cpu_cap],
			CAST([p].[min_memory_percent] AS sysname) + N' - ' + CAST([p].[max_memory_percent] AS sysname) [mem_%_range],
			CAST([p].[max_memory_kb] / 1048576.0 AS decimal(22,2)) [max_gb],
			CAST([p].[target_memory_kb] / 1048576.0 AS decimal(22,2)) [target_gb],
			CAST([p].[used_memory_kb] / 1048576.0 AS decimal(22,2)) [used_gb],
			' ' [ ],
			[p].[statistics_start_time],
			FORMAT([p].[total_cpu_active_ms], N'N0') [total_cpu],
			--FORMAT([p].[total_cpu_usage_ms], N'N0') [total_cpu],
			FORMAT([p].[total_cpu_delayed_ms], N'N0') [yielded_cpu],
			FORMAT([p].[total_cpu_usage_preemptive_ms], N'N0') [preemptive_cpu],
			FORMAT([p].[total_cpu_violation_sec], N'N0') [violation_seconds],
			FORMAT([p].[total_cpu_violation_delay_ms], N'N0') [violation_delays],		
			' ' [_],
			CAST([p].[cache_memory_kb] / 1048576.0 AS decimal(22,2)) [cache_gb],
			CAST([p].[compile_memory_kb]/ 1048576.0 AS decimal(22,2)) [compile_gb],
			CAST([p].[used_memgrant_kb] / 1048576.0 AS decimal(22,2)) [used_grant_gb],
			FORMAT([p].[total_memgrant_count], N'N0') [grants],
			FORMAT([p].[total_memgrant_timeout_count], N'N0') [grant_timeouts],
			FORMAT([p].[out_of_memory_count], N'N0') [failed_grants],
			FORMAT([p].[active_memgrant_count], N'N0') [current_grant],
			--CAST([p].[active_memgrant_kb] / 1048576.0 AS decimal(22,2)) [current_grant_gb],
			FORMAT([p].[memgrant_waiter_count], N'N0') [grants_pending]
		FROM 
			sys.[dm_resource_governor_resource_pools] [p]
	END;

	IF UPPER(@Mode) IN (N'WORKGROUP', N'POOL_AND_WORKGROUP') BEGIN 
		SELECT 
			[w].[name] + N' (' + CAST([w].[group_id] AS sysname) + N')' [workgroup],
			[p].[name] + N' (' + CAST([w].[pool_id] AS sysname) + N')' [pool],
			[w].[importance],
			[w].[request_max_memory_grant_percent] [max_grant_%],
			[w].[request_max_cpu_time_sec] [max_cpu_sec],
			[w].[request_memory_grant_timeout_sec] [grant_sec],
			[w].[group_max_requests] [max_requests],
			[w].[max_dop],
			N' ' [ ],
			--DATEDIFF(MILLISECOND, [w].[statistics_start_time], GETDATE()) [stats], 
			[w].[statistics_start_time],
			FORMAT([w].[total_request_count], N'N0') [total_requests],
			FORMAT([w].[total_queued_request_count], N'N0') [total_queued],
			[w].[active_request_count] [running],
			[w].[queued_request_count] [queued],
			FORMAT([w].[total_cpu_limit_violation_count], N'N0') [cpu_violations],
			FORMAT([w].[total_cpu_usage_ms], N'N0') [total_cpu],
			FORMAT([w].[max_request_cpu_time_ms], N'N0') [largest_cpu],
			--[w].[blocked_task_count],
			--[w].[total_lock_wait_count],
			--[w].[total_lock_wait_time_ms],
			FORMAT([w].[total_query_optimization_count], N'N0') [optimizations],
			FORMAT([w].[total_suboptimal_plan_generation_count], N'N0') [suboptimal_grants],
			FORMAT([w].[total_reduced_memgrant_count], N'N0') [reduced_grants],
			CAST((CAST([w].[max_request_grant_memory_kb] AS decimal(24,2)) / 1024.0) AS decimal(24,1)) [largest_grant_mb],  -- to MB... 
			[w].[active_parallel_thread_count] [parallel_threads],
			[w].[effective_max_dop],
			FORMAT([w].[total_cpu_usage_preemptive_ms], N'N0') [preemptive_ms]

			-- 2019+ only:
			--[request_max_memory_grant_percent_numeric] and... don't care about getting % as a float vs int... 
		FROM 
			sys.[dm_resource_governor_workload_groups] [w]
			INNER JOIN sys.[dm_resource_governor_resource_pools] [p] ON [w].[pool_id] = [p].[pool_id];
	END;

	RETURN 0;
GO