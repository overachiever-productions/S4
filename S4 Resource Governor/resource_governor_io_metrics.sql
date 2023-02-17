/*
	vNEXT: 
		add options to include/exclude default/internal... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.resource_governor_io_metrics','P') IS NOT NULL
	DROP PROC dbo.[resource_governor_io_metrics];
GO

CREATE PROC dbo.[resource_governor_io_metrics]
	@Mode				sysname	= N'READ_AND_WRITE'		-- READ | WRITE | READ_AND_WRITE
AS
    SET NOCOUNT ON; 

	SET @Mode = ISNULL(NULLIF(@Mode, N''), N'READ_AND_WRITE');

	-- {copyright}

	IF UPPER(@Mode) IN (N'READ', N'READ_AND_WRITE') BEGIN
		SELECT 
			[p].[name] + N' (' + CAST([p].[pool_id] AS sysname) + N')' [pool],
			[p].[statistics_start_time],
			[p].[min_iops_per_volume] [iops_min],
			[p].[max_iops_per_volume] [iops_max],
			' ' [ ],
			CAST(CAST([p].[read_bytes_total] AS decimal(24,2)) / 1073741824.0 AS decimal(24,1))  [read_gb],
			FORMAT([p].[read_io_completed_total], N'N0') [total_reads],
				--CAST(CAST(CAST([p].[read_bytes_total] as decimal(24,2)) / 1048576.0 as decimal(24,1)) / [p].[read_io_completed_total] as decimal(24,3))  [avg_read_mb],
			FORMAT([p].[read_io_queued_total], N'N0')  [queued_reads],  -- queued (cuz of stalls/throughput/etc.)
			FORMAT([p].[read_io_throttled_total], N'N0')  [throttled_reads],  -- throttled cuz of policy... 
			CAST((CAST([p].[read_io_stall_total_ms] AS decimal(24,2)) / CAST([p].[read_io_completed_total] AS decimal(24,2))) AS decimal(12,3)) [avg_stall],
			CAST((CAST([p].[read_io_stall_queued_ms] AS decimal(24,2)) / CAST([p].[read_io_completed_total] AS decimal(24,2))) AS decimal(12,3)) [queued_stall],
			FORMAT([p].[io_issue_violations_total], N'N0') [io_violations],
			CAST((CAST([p].[io_issue_delay_total_ms] AS decimal(24,2)) / CAST([p].[io_issue_violations_total] AS decimal(24,2))) AS decimal(18,3)) [avg_violation_ms]
		FROM  
			sys.[dm_resource_governor_resource_pools] [p];
	END;

	IF UPPER(@Mode) IN (N'WRITE', N'READ_AND_WRITE') BEGIN
		SELECT 
			[p].[name] + N' (' + CAST([p].[pool_id] AS sysname) + N')' [pool],
			[p].[statistics_start_time],
			[p].[min_iops_per_volume] [iops_min],
			[p].[max_iops_per_volume] [iops_max],
			' ' [ ],
			CAST(CAST([p].[write_bytes_total] as decimal(24,2)) / 1073741824.0 as decimal(24,1))  [write_gb],
			FORMAT([p].[write_io_completed_total], N'N0') [total_writes],
			FORMAT([p].[write_io_queued_total], N'N0')  [queued_writes],  -- queued (cuz of stalls/throughput/etc.)
			FORMAT([p].[write_io_throttled_total], N'N0')  [throttled_writes],  -- throttled cuz of policy... 
			CAST((CAST([p].[write_io_stall_total_ms] as decimal(24,2)) / CAST([p].[write_io_completed_total] as decimal(24,2))) as decimal(12,3)) [avg_stall],
			CAST((CAST([p].[write_io_stall_queued_ms] as decimal(24,2)) / CAST([p].[write_io_completed_total] as decimal(24,2))) as decimal(12,3)) [queued_stall],
			FORMAT([p].[io_issue_violations_total], N'N0') [io_violations],
			CAST((CAST([p].[io_issue_delay_total_ms] as decimal(24,2)) / CAST([p].[io_issue_violations_total] as decimal(24,2))) as decimal(18,3)) [avg_violation_ms]
		FROM 
			sys.[dm_resource_governor_resource_pools] [p];
	END;

	RETURN 0;
GO