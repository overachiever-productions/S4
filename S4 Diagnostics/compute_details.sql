/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[compute_details]','P') IS NOT NULL
	DROP PROC dbo.[compute_details];
GO

CREATE PROC dbo.[compute_details]
	@SerializedOutput				xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @signalWaits decimal(5,2);
	SELECT 
		@signalWaits = SUM([signal_wait_time_ms]) * 100. / SUM([wait_time_ms])
	FROM 
		sys.[dm_os_wait_stats]
	OPTION (RECOMPILE);

	-- processor type: 
	DECLARE @RegInfo table ([value] sysname, [data] sysname);
	INSERT INTO @RegInfo ([value],[data]) 
	EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', N'ProcessorNameString';

	WITH core AS ( 
		SELECT
			[virtual_machine_type_desc] [host],
			[numa_node_count] [numa_nodes],
			[softnuma_configuration_desc] [soft_numa],		-- off, on, manual
			[socket_count] [sockets],
			[cpu_count],
			[hyperthread_ratio] [ht_ratio],
			[sql_memory_model_desc] [memory_model],  -- conventional, lock_pages, large_pages
			CAST(CAST(ROUND([physical_memory_kb] / 1024. / 1024., 0) AS int) AS sysname) + N' (' +
			CAST(CAST(ROUND([committed_kb] / 1024. / 1024., 0) AS int) AS sysname) + N' / ' + 
			CAST(CAST(ROUND([committed_target_kb] / 1024. / 1024., 0) AS int) AS sysname) + N')' [memory_gb (c / t)],
			DATEDIFF(DAY, [sqlserver_start_time], GETDATE()) [days_up],
			CAST([process_kernel_time_ms] * 100. / DATEDIFF_BIG(MILLISECOND, [sqlserver_start_time], GETDATE()) AS decimal(6,3)) [up_percent_kernel],
			CAST([process_user_time_ms] * 100. / DATEDIFF_BIG(MILLISECOND, [sqlserver_start_time], GETDATE()) AS decimal(6,3)) [up_percent_user],
			@signalWaits [signal_wait_percent],
			CASE WHEN [max_workers_count] <> 512 THEN N' CUSTOM_MAX_WORKERS:' + CAST([max_workers_count] AS sysname) + N'; ' ELSE N'' END
				+ CASE WHEN [softnuma_configuration] = 1 THEN N' SOFT_NUMA; ' ELSE N'' END
				+ CASE WHEN [sql_memory_model_desc] = 'LARGE_PAGES' THEN N' LARGE_PAGES; ' ELSE N'' END [advanced_options],
		
			CASE WHEN [affinity_type_desc] <> N'AUTO' THEN N' MANUAL_AFFINITY; ' ELSE N'' END
				+ CASE WHEN [os_priority_class] <> 32 THEN N' MANUAL_PRIORITY; ' ELSE N'' END
				+ CASE WHEN [softnuma_configuration] = 2 THEN N' MANUAL_SOFT_NUMA; ' ELSE N'' END
				+ CASE WHEN [sql_memory_model_desc] = N'CONVENTIONAL' THEN ' CONVENTIONAL_MEMORY_MODULE; ' ELSE N'' END
			[smells]
		FROM 
			sys.[dm_os_sys_info]
	)

	SELECT 
		[host],
		[numa_nodes],
		[soft_numa],
		[sockets],
		[cpu_count],
		[ht_ratio],
		(SELECT [data] FROM @RegInfo) [processor_type],
		[memory_model],
		[memory_gb (c / t)],
		[days_up],
		[up_percent_kernel],
		[up_percent_user],
		[signal_wait_percent],
		REPLACE([advanced_options], N'  ', N' ') [advanced_options],
		REPLACE([smells], N'  ', N' ') [smells]
	INTO 
		#intermediate_compute
	FROM 
		[core];

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN
		SELECT @SerializedOutput = (
			SELECT 
				[host],
				[numa_nodes],
				[soft_numa],
				[sockets],
				[cpu_count],
				[ht_ratio],
				[processor_type],
				[memory_model],
				[memory_gb (c / t)] [memory],
				[days_up],
				[up_percent_kernel],
				[up_percent_user],
				[signal_wait_percent],
				[advanced_options],
				[smells] 
			FROM 
				[#intermediate_compute] 
			FOR XML PATH(N'compute'), TYPE, ELEMENTS XSINIL
		);
		
		RETURN 0;
	END;

	SELECT 
		[host],
		[numa_nodes],
		[soft_numa],
		[sockets],
		[cpu_count],
		[ht_ratio],
		[processor_type],
		[memory_model],
		[memory_gb (c / t)],
		[days_up],
		[up_percent_kernel],
		[up_percent_user],
		[signal_wait_percent],
		[advanced_options],
		[smells] 
	FROM 
		[#intermediate_compute];

	RETURN 0;
GO