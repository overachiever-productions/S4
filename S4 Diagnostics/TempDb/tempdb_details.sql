/*


	SQLMONITOR.ing - CONDITIONS to watch for: 
		- ANY/ALL smells. 
		- ANY/ALL warnings.
		- PLUS:
			- spills, temp-tables, version store are > xxxx thresholds. 
			- tempdb_log > Nx of tempdb_data. 
			- FILE-GROWTH can/could/will EXCEDE avaialable disk space. 
					THIS one's a bit tricky. 
					if a single log|data file has a MAX-GROWTH > [available_disk_space_on_its_drive] ... then I need to know. 
					BUT ... if SUM(log|data_growth_by_disk) > [available_disk_space_on_drives_by_GROUPED] ... then I need to know. 

	SCOPE
		- PRESENTATION 

		<tempdb> 
			<facet classification="warning|smell|information" path="config.x|size.x|files.y|perf.n">detail here </facet>
			<facet classification="warning|smell|information" path="config.x|size.x|files.y|perf.n">detail here </facet>
			<facet classification="warning|smell|information" path="config.x|size.x|files.y|perf.n">detail here </facet>
		</tempdb>


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[tempdb_details]','P') IS NOT NULL
	DROP PROC dbo.[tempdb_details];
GO

CREATE PROC dbo.[tempdb_details]
	@serialized_output				xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Collect Core Details and Metrics:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #disk_space (
		[drive] sysname NOT NULL, 
		[available_gbs] decimal(22,2) NOT NULL
	);

	WITH gbs AS ( 
		SELECT DISTINCT
			s.volume_mount_point [drive],
			CAST(s.available_bytes / 1073741824 AS decimal(24,2)) [available_gbs]
		FROM 
			sys.master_files f
			CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) s
	) 
	INSERT INTO [#disk_space] ([drive], [available_gbs])
	SELECT 
		[drive],
		[available_gbs]
	FROM 
		gbs 
	ORDER BY 
		[gbs].[drive];

	SELECT
		[file_id],
		ISNULL([io_stall_read_ms] / NULLIF([num_of_reads], 0), 0) [avg_read_latency],
		ISNULL([io_stall_write_ms] / NULLIF([num_of_writes], 0), 0) [avg_write_latency], 
        CAST([num_of_bytes_read] / (1024. * 1024. * 1024.) AS decimal(24,3)) [read_gbs], 
		CAST([num_of_bytes_written] / (1024. * 1024. * 1024.) AS decimal(24,3)) [written_gbs], 
		CAST(ISNULL(NULLIF([num_of_reads], 0), 0) / 1024. AS decimal(24,3)) [avg_read_kb],
		CAST(ISNULL(NULLIF([num_of_writes], 0), 0) / 1024. AS decimal(24,3)) [avg_write_kb], 
		CASE WHEN [io_stall_queued_read_ms] = 0 THEN 0 ELSE 1 END [rg_queued_read_latency],
		CASE WHEN [io_stall_queued_write_ms] = 0 THEN 0 ELSE 1 END [rg_queued_write_latency]
	INTO 
		#latencies
	FROM
		[sys].dm_io_virtual_file_stats(2, NULL);

	CREATE TABLE #tempdb_files (
		[file_id] int NOT NULL,
		[name] sysname NULL,
		[physical_name] nvarchar(260) NOT NULL,
		[type_desc] nvarchar(60) NULL,
		[state_desc] nvarchar(60) NULL,
		[size] int NOT NULL,
		[max_size] int NOT NULL,
		[growth] int NOT NULL,
		[is_percent_growth] bit NOT NULL
	); 

	INSERT INTO [#tempdb_files] ([file_id], [name], [type_desc], [physical_name], [state_desc], [size], [max_size], [growth], [is_percent_growth])
	SELECT 
		[file_id],
		[name],
		[type_desc],
		[physical_name],
		[state_desc],
		[size],
		[max_size],
		[growth],
		[is_percent_growth]
	FROM 
		sys.[master_files] 
	WHERE 
		[database_id] = 2
	ORDER BY 
		[file_id];

	CREATE TABLE #log_space (
		[reserved_gb] decimal(22,3) NOT NULL,
		[used_gb] decimal(23,3) NOT NULL,
		[used_percent] decimal(5,1) NOT NULL
	);
	DECLARE @sql nvarchar(MAX) = N'USE [tempdb];
	INSERT INTO [#log_space] ([reserved_gb], [used_gb], [used_percent])
	SELECT 
		CAST(ROUND([total_log_size_in_bytes] / (1024. * 1024. * 1024.), 1) AS decimal(24, 3)) [reserved_gb],
		CAST(ROUND([used_log_space_in_bytes] / (1024. * 1024. * 1024.), 1) AS decimal(24, 3)) [used_gb],
		CAST([used_log_space_in_percent] AS decimal(5,1)) [used_percent]
	FROM 
		sys.[dm_db_log_space_usage]; ';
	EXEC sys.sp_executesql @sql;

	CREATE TABLE #tempdb_space (
		[total_size] decimal(22,3) NOT NULL,
		[free_space] decimal(22,3) NOT NULL,
		[temp_tables] decimal(22,3) NOT NULL,
		[work_tables] decimal(22,3) NOT NULL,
		[version_store] decimal(22,3) NOT NULL,
		[tiny_tables] decimal(22,3) NOT NULL
	);
	SET @sql = N'USE [tempdb];
INSERT INTO [#tempdb_space] ([total_size], [free_space], [temp_tables], [work_tables], [version_store], [tiny_tables])
SELECT
	CAST(SUM([total_page_count]) * 8. / (1024. * 1024.) AS decimal(22,3)) [total_size],
	CAST(SUM(ISNULL(unallocated_extent_page_count, 0)) * 8. / (1024. * 1024.) AS decimal(22,3)) [free_space],
	CAST(SUM(ISNULL(user_object_reserved_page_count, 0)) * 8. / (1024. * 1024.) AS decimal(22,3)) [temp_tables],
	CAST(SUM(ISNULL(internal_object_reserved_page_count, 0)) * 8. / (1024. * 1024.) AS decimal(22,3)) [work_tables],
	CAST(SUM(ISNULL(version_store_reserved_page_count, 0)) * 8. / (1024. * 1024.) AS decimal(22,3)) [version_store],
	CAST(SUM(ISNULL(mixed_extent_page_count, 0)) * 8. / (1024. * 1024.) AS decimal(22,3)) [tiny_tables]
FROM 
	sys.[dm_db_file_space_usage];';
	EXEC sys.sp_executesql @sql;

	CREATE TABLE #config_settings (
		[scope] sysname NOT NULL, 
		[option_name] sysname NOT NULL, 
		[default_value] sysname NOT NULL, 
		[set_value] sysname NOT NULL, 
		[classification] sysname NOT NULL, 
	);

	INSERT INTO [#config_settings] ([scope], [option_name], [default_value], [set_value], [classification])
	SELECT 
		N'setting' [scope],
		[d].[default_name] [option_name],
		[d].[default_value] [default_value],
		[s].[default_value] [set_value], 
		N'CONFIG' [classification]
	FROM 
		dbo.database_defaults(2) [d]
		INNER JOIN dbo.database_settings(2) [s] ON [d].[default_name] = [s].[default_name] 
	WHERE 
		[d].[default_value] <> [s].[default_value];

-- SCOPED configs didn't become a thing until ... 14.x? or ... when? 
	INSERT INTO [#config_settings] ([scope], [option_name], [default_value], [set_value], [classification])
	SELECT 
		N'scoped_configuration' [scope],
		[c].[name] [option_name],
		N'fudge' [default_value],
		CAST([c].[value] AS sysname) [set_value], 
		N'CONFIG' [classification]
	FROM 
		tempdb.sys.[database_scoped_configurations] [c]
		INNER JOIN dbo.database_scoped_defaults(2) [d] ON [c].[name] = [d].[option_name]
	WHERE 
		[c].[is_value_default] <> 1;

	CREATE TABLE #trace_status (
		[flag] int NOT NULL, 
		[status] int NOT NULL, 
		[global] bit NOT NULL, 
		[session] bit NOT NULL
	);
	INSERT INTO #trace_status ([flag], [status], [global], [session])
	EXEC ('DBCC TRACESTATUS(-1)');

	DECLARE @rgTempdbLimitsInPlace bit = 0;

	SET @sql = N'
	IF (SELECT dbo.[engine_version](N''RTM'')) > 17.1000 BEGIN
		IF EXISTS (SELECT NULL FROM sys.[resource_governor_configuration] WHERE [is_enabled] = 1) BEGIN
			IF EXISTS (SELECT NULL FROM sys.[resource_governor_workload_groups] WHERE [group_max_tempdb_data_mb] IS NOT NULL OR [group_max_tempdb_data_mb] IS NOT NULL)
				SET @rgTempdbLimitsInPlace = 1;
		END;
	END; ';

	EXEC sys.[sp_executesql] 
		@sql, 
		N'@rgTempdbLimitsInPlace bit = 0 OUTPUT', 
		@rgTempdbLimitsInPlace = @rgTempdbLimitsInPlace OUTPUT;

	DECLARE @tempdbCollation sysname = (SELECT [collation_name] FROM sys.databases WHERE name = N'tempdb');
	DECLARE @tempdbCompat tinyint = (SELECT [compatibility_level] FROM sys.databases WHERE name = N'tempdb');

---------------------------------------------------------
UPDATE [#latencies] SET [avg_read_latency] = 28, [avg_write_latency] = 95 WHERE [file_id] = 2;
UPDATE [#latencies] SET [rg_queued_read_latency] = 12, [rg_queued_write_latency] = 4 WHERE [file_id] = 2;
UPDATE [#tempdb_files] SET [is_percent_growth] = 1 WHERE [file_id] = 3;
UPDATE [#tempdb_files] SET [state_desc] = N'RECOVERING' WHERE [file_id] = 4;
UPDATE [#tempdb_files] SET [growth] = 4096 WHERE [file_id] = 5;
	--SELECT * FROM [#latencies];
--SELECT * FROM [#disk_space];
--SELECT * FROM [#tempdb_files];

INSERT INTO [#config_settings] ([scope], [option_name], [default_value], [set_value], [classification])
VALUES (
	N'scoped_configuration', -- scope - sysname
	N'LAST_QUERY_PLAN_STATS',
	N'0',
	N'1',
	N'CONFIG'
);

INSERT INTO [#trace_status] ([flag], [status], [global], [session])
VALUES (
	1117, -- flag - bit
	1, -- status - int
	1, -- global - bit
	0 -- session - bit
);

INSERT INTO [#trace_status] ([flag], [status], [global], [session])
VALUES (
	3427, -- flag - bit
	1, -- status - int
	1, -- global - bit
	0 -- session - bit
);

---------------------------------------------------------
	DECLARE @message sysname
	CREATE TABLE #outputs (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[classification] sysname NOT NULL, 
		[context] sysname NOT NULL, 
		[detail] sysname NOT NULL 
	);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- INFO:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @xml xml = (SELECT * FROM [#tempdb_space] FOR XML PATH(N'attribute'), TYPE);
	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		N'INFO' [classification],
		N'data_files.' + [x].[r].value(N'local-name(.)', N'sysname') [context],
		[x].[r].value(N'.', N'nvarchar(MAX)') + N'GB' [detail]
	FROM 
		@xml.nodes(N'//attribute/*') AS [x]([r]);

	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		CASE WHEN COUNT(*) > 8 THEN N'SMELL' ELSE N'INFO' END [classification],
		N'data_files.count', 
		COUNT(*) [detail]
	FROM 
		[#tempdb_files]
	WHERE 
		[type_desc] = N'ROWS';

	DECLARE @disks nvarchar(MAX) = N'';
	WITH disks AS ( 
		SELECT 
			DISTINCT(LEFT([physical_name], 3)) [disk]
		FROM 
			[#tempdb_files]
	)
	SELECT 
		@disks = @disks + [x].[drive] + N', free_gb=' + CAST([x].[available_gbs] AS sysname) + N'; ' 
	FROM 
		disks [d]
		INNER JOIN [#disk_space] [x] ON [d].[disk] = [x].[drive];
	IF @disks LIKE N'%,%' SET @disks = LEFT(@disks, LEN(@disks) - 1);

	INSERT INTO [#outputs] ([classification], [context], [detail])
	VALUES (N'INFO', N'data_files.disks', @disks);

	SELECT @xml = (SELECT * FROM [#log_space] FOR XML PATH(N'attribute'), TYPE);
	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		N'INFO' [classification],
		N'log_files.' + [x].[r].value(N'local-name(.)', N'sysname') [context],
		[x].[r].value(N'.', N'nvarchar(MAX)') + CASE WHEN [x].[r].value(N'local-name(.)', N'sysname') LIKE N'%percent' THEN N'%' ELSE N'GB' END [detail]
	FROM 
		@xml.nodes(N'//attribute/*') AS [x]([r]);

	SET @disks = N'';
	SELECT @disks = @disks + [name] + N'=' + LEFT([physical_name], 1) + N', ' FROM [#tempdb_files] WHERE [type_desc] = N'ROWS';
	SET @disks = LEFT(@disks, LEN(@disks) - 1);

	INSERT INTO [#outputs] ([classification], [context], [detail])
	VALUES (N'INFO', N'data_files.disks', @disks);

		SET @disks = N'';
	SELECT @disks = @disks + [name] + N'=' + LEFT([physical_name], 1) + N', ' FROM [#tempdb_files] WHERE [type_desc] = N'LOG';
	SET @disks = LEFT(@disks, LEN(@disks) - 1);

	INSERT INTO [#outputs] ([classification], [context], [detail])
	VALUES (N'INFO', N'log_files.disks', @disks);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- PERF:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @files nvarchar(MAX) = N'';
	SELECT 
		@files = @files + QUOTENAME([f].[name]) + N', '
	FROM 
		#latencies [l]
		INNER JOIN [#tempdb_files] [f] ON [l].[file_id] = [f].[file_id]
	WHERE 
		[l].[avg_read_latency] < 2 AND [l].[avg_write_latency] < 2
	ORDER BY 
		[f].[file_id];

	IF @files LIKE N'%,%' SET @files = LEFT(@files, LEN(@files) - 1);
	INSERT INTO [#outputs] ([classification], [context], [detail])
	VALUES (N'PERF', N'latency.under_2ms', @files);

	IF EXISTS (SELECT NULL FROM #latencies [l] WHERE [l].[avg_read_latency] >= 2 OR [l].[avg_write_latency] >= 2) BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		SELECT 
			CASE WHEN [l].[avg_read_latency] > 30 OR [l].[avg_write_latency] > 30 THEN N'PERF-WARNING' ELSE N'PERF' END [classification], 
			CASE WHEN [l].[avg_read_latency] > 30 OR [l].[avg_write_latency] > 30 THEN N'latency.over_30ms' ELSE N'latency.over_2ms' END [context], 
			QUOTENAME([f].[name]) + N': read=' + CAST([l].[avg_read_latency] AS sysname) + N'ms, write=' + CAST([l].[avg_write_latency] AS sysname) + N'ms'
				+ N', gbs_read=' + CAST([l].[read_gbs] AS sysname) + N', avg_read_kb=' + CAST([l].[avg_read_kb] AS sysname) 
				+ N', gbs_written=' + CAST([l].[written_gbs] AS sysname) + N', avg_write_kb=' + CAST([l].[avg_write_kb] AS sysname) [detail]
		FROM 
			[#latencies] [l]
			INNER JOIN [#tempdb_files] [f] ON [l].[file_id] = [f].[file_id]
		WHERE 
			[l].[avg_read_latency] >= 2 OR [l].[avg_write_latency] >= 2;
	END;

	IF EXISTS (SELECT NULL FROM #latencies [l] WHERE [l].[rg_queued_read_latency] > 0 OR [l].[rg_queued_write_latency] > 0) BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		SELECT 
			N'PERF-WARNING' [classification], 
			N'latency.resource_governor' [context], 
			QUOTENAME([f].[name]) + N': rg_read_latency: ' + CAST([l].[rg_queued_read_latency] AS sysname) 
			+ N', rg_write_latency=' + CAST([l].[rg_queued_write_latency] AS sysname) [detail]
		FROM 
			[#latencies] [l]
			INNER JOIN [#tempdb_files] [f] ON [l].[file_id] = [f].[file_id]
		WHERE 
			[l].[rg_queued_read_latency] > 0 OR [l].[rg_queued_write_latency] > 0;
	END;
	
	DECLARE @mismatchedCollations int = (SELECT COUNT(*) FROM sys.databases WHERE [collation_name] <> @tempdbCollation);
	IF @mismatchedCollations > 0 BEGIN
		SET @message = N'mismatch_count=' + CAST(@mismatchedCollations AS sysname)
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'PERF-WARNING', N'config.collation_mismatch', @message);  /* NOTE: Contained DBs can/will 'cause' this. That and ... poor config. */
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- ADVANCED:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		N'ADVANCED' [classification], 
		N'config.advanced_trace_flag' [context], 
		N'TF3427=ENABLED (optimized memory_optimized)' [detail]
	FROM 
		[#trace_status]
	WHERE 
		[flag] = 3427 AND [status] = 1;

	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		N'ADVANCED' [classification], 
		N'config.advanced_option' [context], 
		N'[tempdb metadata memory-optimized]=1'
	FROM 
		sys.[configurations] 
	WHERE 
		[name] = N'tempdb metadata memory-optimized'
		AND (CAST([value] AS int) = 1 OR CAST([value_in_use] AS int) = 1);

	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		N'ADVANCED' [classification], 
		N'config.advanced_trace_flag' [context], 
		N'TF7470=ENABLED (additional spill overhead)'
	FROM 
		[#trace_status]
	WHERE 
		[flag] = 7470 AND [status] = 1;

	 IF @rgTempdbLimitsInPlace = 1 BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'ADVANCED', N'config.resource_governor', N'RG=ENABLED, TEMPDB_LIMITS=ENABLED');
	 END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- CONFIG:
	--	NOTE: Config SMELLs and WARNINGs are coded explicitly as SMELL and WARNING classifications - not CONFIG-WARN/CONFIG-SMELL. 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF EXISTS (SELECT NULL FROM [#config_settings]) BEGIN
		-- With tempdb ... MOST non-defaults are going to be WARNINGS or SMELLS.... so, EXCLUDE (NOT IN()) vs INCLUDE(IN())... 
		UPDATE [#config_settings] SET [classification] = 'CONFIG-WARNING' WHERE [option_name] NOT IN (N'is_encrypted', N'collation_name', N'owner_sid', N'compatibility_level', N'MAXDOP', N'QUERY_OPTIMIZER_HOTFIXES', N'VERBOSE_TRUNCATION_WARNINGS');
		UPDATE [#config_settings] SET [classification] = 'CONFIG-SMELL' WHERE [classification] <> N'CONFIG-WARNING' AND [option_name] NOT IN (N'is_encrypted', N'QUERY_OPTIMIZER_HOTFIXES');

		INSERT INTO [#outputs] ([classification], [context], [detail])
		SELECT 
			CASE WHEN [classification] LIKE N'CONFIG-%' THEN REPLACE([classification], N'CONFIG-', N'') ELSE [classification] END [classification], 
			N'config.' + CASE WHEN [scope] = N'scoped_configuration' THEN 'explicit_scope' ELSE N'explicit_setting' END [context], 
			[option_name] + N'=' + [set_value] + N'; default=' + [default_value] [detail]
		FROM 
			[#config_settings];
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- SMELL:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [is_percent_growth] = 1 AND [type_desc] = N'ROWS') BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N', ' FROM [#tempdb_files] WHERE [is_percent_growth] = 1 AND [type_desc] = N'ROWS';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES(N'SMELL', N'data_files.using_percent_growth', @files);
	END;

	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [is_percent_growth] = 1 AND [type_desc] = N'LOG') BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N', ' FROM [#tempdb_files] WHERE [is_percent_growth] = 1 AND [type_desc] = N'LOG';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES(N'SMELL', N'log_files.using_percent_growth', @files);
	END;

	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [state_desc] <> N'ONLINE' AND [type_desc] = N'ROWS') BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=' + [state_desc] + N', ' FROM [#tempdb_files] WHERE [state_desc] <> N'ONLINE' AND [type_desc] = N'ROWS';
		SET @files = LEFT(@files, LEN(@files) - 1);
		
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES(N'SMELL', N'data_files.not_online', @files);
	END;

	IF (SELECT COUNT(DISTINCT [max_size]) FROM [#tempdb_files] WHERE [type_desc] = N'ROWS') > 1 BEGIN
		/* This is a SMELL because in SOME cases there's an argument for letting 1x file grow LARGER as an 'overspill'. NOT great ... but... not quite a WARN either.  */
		INSERT INTO [#outputs] ([classification], [context], [detail])
		SELECT 
			N'SMELL' [classification], 
			N'files.different_max_sizes' [context], 
			QUOTENAME([name]) + N'=' + CAST([max_size] AS sysname)
		FROM 
			[#tempdb_files]
		WHERE 
			[type_desc] = N'ROWS'
			AND [max_size] <> -1;
	END;

	INSERT INTO [#outputs] ([classification], [context], [detail])
	SELECT 
		N'SMELL' [classification], 
		CASE WHEN [growth] <= 4096 THEN N'files.small_growth' ELSE N'files.large_growth' END [context],
		QUOTENAME([name]) + N'=' + CAST([growth] * 8 / 1024 AS sysname) + N'MB'
	FROM 
		[#tempdb_files]
	WHERE 
		[growth] <= 4096 OR [growth] >= 524288  -- < 32MB or > 4GB growth
		AND [type_desc] = N'ROWS';

	IF (SELECT dbo.[engine_version](N'RTM')) >= 12.2000 BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		SELECT 
			N'SMELL' [classification], 
			N'config.surplus_trace_flag' [context],
			N'TF' + CAST([flag] AS sysname) + N'=ENABLED (' + CASE WHEN [flag] = 1118 THEN N'uniform extent allocation)' ELSE N'tempdb data file growth)' END [detail]
		FROM 
			[#trace_status] 
		WHERE 
			([flag] = 1118 AND [status] = 1) OR ([flag] = 1117 AND [status] = 1);
	  END;
	ELSE BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		SELECT 
			N'WARNING' [classification], 
			N'config.surplus_trace_flag' [context],
			N'TF' + CAST([flag] AS sysname) + N'=NOT_ENABLED (' + CASE WHEN [flag] = 1118 THEN N'uniform extent allocation)' ELSE N'tempdb data file growth)' END [detail]
		FROM 
			[#trace_status] 
		WHERE 
			([flag] = 1118 AND [status] = 1) OR ([flag] = 1117 AND [status] = 1);		
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- WARNING:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [state_desc] <> N'ONLINE' AND [type_desc] = N'ROWS') BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=' + [state_desc] + N', ' FROM [#tempdb_files] WHERE [state_desc] <> N'ONLINE' AND [type_desc] = N'ROWS';
		SET @files = LEFT(@files, LEN(@files) - 1);
		
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES(N'WARNING', N'log_files.not_online', @files);
	END;	
	
	IF @tempdbCollation <> (SELECT CAST(SERVERPROPERTY(N'Collation') AS sysname)) BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'config.collation', N'tempdb collation (' + @tempdbCollation + N') does not match server collation (' + CAST(SERVERPROPERTY(N'Collation') AS sysname) + N')');
	END;

	IF EXISTS (SELECT NULL FROM sys.dm_server_services WHERE [servicename] LIKE N'SQL Server (%' AND [instant_file_initialization_enabled] = N'N') BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'config.ifi', N'instant_file_initialization_enabled=''N''');
	END;
	
	IF @tempdbCompat <> (SELECT [compatibility_level] FROM sys.databases WHERE name = N'master') BEGIN
		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'config.compat', N'tempdbcompat=' + CAST(@tempdbCompat AS sysname) + N', master_compat=' + CAST((SELECT [compatibility_level] FROM sys.databases WHERE name = N'master') AS sysname));
	END;

	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [physical_name] LIKE N'C:\%' AND [type_desc] = N'ROWS') BEGIN 
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=' + [name] + N', ' FROM [#tempdb_files] WHERE [physical_name] LIKE N'C:\%' AND [type_desc] = N'ROWS';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'data_files.on_c_drive', @files);
	END;

	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [physical_name] LIKE N'C:\%' AND [type_desc] = N'LOG') BEGIN 
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=' + [name] + N', ' FROM [#tempdb_files] WHERE [physical_name] LIKE N'C:\%' AND [type_desc] = N'LOG';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'log_files.on_c_drive', @files);
	END;

	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [max_size] = -1 AND [type_desc] = N'ROWS') BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=-1, ' FROM [#tempdb_files] WHERE [max_size] = -1 AND [type_desc] = N'ROWS';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'data_files.unlimited_growth', @files);
	END;

	IF EXISTS (SELECT NULL FROM [#tempdb_files] WHERE [max_size] = -1 AND [type_desc] = N'LOG') BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=-1, ' FROM [#tempdb_files] WHERE [max_size] = -1 AND [type_desc] = N'LOG';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'log_files.unlimited_growth', @files);
	END;

	IF (SELECT DISTINCT COUNT([growth]) FROM [#tempdb_files] WHERE [type_desc] = N'ROWS') > 1 BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N'=' + CAST([growth] * 8 / 1024 AS sysname) + N'MB, ' FROM [#tempdb_files] WHERE [type_desc] = N'ROWS';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'files.heterogeneous_growth', @files);
	END; 

	IF (SELECT COUNT(*) FROM [#tempdb_files] WHERE [type_desc] = N'LOG') > 1 BEGIN
		SET @files = N'';
		SELECT @files = @files + QUOTENAME([name]) + N', ' FROM [#tempdb_files] WHERE [type_desc] = N'LOG';
		SET @files = LEFT(@files, LEN(@files) - 1);

		INSERT INTO [#outputs] ([classification], [context], [detail])
		VALUES (N'WARNING', N'log_files.multiple_log_files', @files);
	END;


	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- PROJECT or RETURN:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/


	SELECT 
		[classification],
		[context],
		[detail] 
	FROM 
		[#outputs]
	ORDER BY 
		[row_id];

	RETURN 0; 
GO