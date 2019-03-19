/*

	TODO: 
		sys.os_sys_info.physical_memory_kb doesn't exist on 2008R2 or before...

	NOTE: 
		- Not really intended to be called directly. Should typically be called by dbo.script_server_configurations. 
		- For the 'v1' version of this script, we'll just be DOCUMENTING details - not configuring them as optional/executable scripts. 

	DEPENDENCIES:
		- dbo.get_engine_version() - S4 UDF.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.print_configuration','P') IS NOT NULL
	DROP PROC dbo.print_configuration;
GO

CREATE PROC dbo.print_configuration 

AS
	SET NOCOUNT ON;

	-- {copyright}

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- meta / formatting: 
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);

	DECLARE @sectionMarker nvarchar(2000) = N'--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
	
	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Hardware: 
	PRINT @sectionMarker;
	PRINT N'-- Hardware'
	PRINT @sectionMarker;	

	DECLARE @output nvarchar(MAX) = @crlf + @tab;
	SET @output = @output + N'-- Processors' + @crlf; 

	SELECT @output = @output
		+ @tab + @tab + N'PhysicalCpuCount: ' + CAST(cpu_count/hyperthread_ratio AS sysname) + @crlf
		+ @tab + @tab + N'HyperthreadRatio: ' + CAST([hyperthread_ratio] AS sysname) + @crlf
		+ @tab + @tab + N'LogicalCpuCount: ' + CAST(cpu_count AS sysname) + @crlf
	FROM 
		sys.dm_os_sys_info;

	DECLARE @cpuFamily sysname; 
	EXEC sys.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'HARDWARE\DESCRIPTION\System\CentralProcessor\0', N'ProcessorNameString', @cpuFamily OUT;

	SET @output = @output + @tab + @tab + N'ProcessorFamily: ' + @cpuFamily + @crlf;
	PRINT @output;

	SET @output = @crlf + @tab + N'-- Memory' + @crlf;
	SELECT @output = @output + @tab + @tab + N'PhysicalMemoryOnServer: ' + CAST(physical_memory_kb/1024 AS sysname) + N'MB ' + @crlf FROM sys.[dm_os_sys_info];
	SET @output = @output + @tab + @tab + N'MemoryNodes: ' + @crlf;

	SELECT @output = @output 
		+ @tab + @tab + @tab + N'NODE_ID: ' + CAST(node_id AS sysname) + N' - ' + node_state_desc + N' (OnlineSchedulerCount: ' + CAST(online_scheduler_count AS sysname) + N', CpuAffinity: ' + CAST(cpu_affinity_mask AS sysname) + N')' + @crlf
	FROM sys.dm_os_nodes;
	
	PRINT @output;

	SET @output = @crlf + @crlf + @tab + N'-- Disks' + @crlf;

	DECLARE @disks table (
		[volume_mount_point] nvarchar(256) NULL,
		[file_system_type] nvarchar(256) NULL,
		[logical_volume_name] nvarchar(256) NULL,
		[total_gb] decimal(18,2) NULL,
		[available_gb] decimal(18,2) NULL
	);

	INSERT INTO @disks ([volume_mount_point], [file_system_type], [logical_volume_name], [total_gb], [available_gb])
	SELECT DISTINCT 
		vs.volume_mount_point, 
		vs.file_system_type, 
		vs.logical_volume_name, 
		CONVERT(DECIMAL(18,2),vs.total_bytes/1073741824.0) AS [total_gb],
		CONVERT(DECIMAL(18,2), vs.available_bytes/1073741824.0) AS [available_gb]  
	FROM 
		sys.master_files AS f
		CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs; 

	SELECT @output = @output
		+ @tab + @tab + volume_mount_point + @crlf + @tab + @tab + @tab + N'Label: ' + logical_volume_name + N', FileSystem: ' + file_system_type + N', TotalGB: ' + CAST([total_gb] AS sysname)  + N', AvailableGB: ' + CAST([available_gb] AS sysname) + @crlf
	FROM 
		@disks 
	ORDER BY 
		[volume_mount_point];	

	PRINT @output + @crlf;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process Installation Details:
	PRINT @sectionMarker;
	PRINT N'-- Installation Details'
	PRINT @sectionMarker;

	DECLARE @properties table (
		row_id int IDENTITY(1,1) NOT NULL, 
		segment_name sysname, 
		property_name sysname
	);

	INSERT INTO @properties (segment_name, property_name)
	VALUES 
	(N'ProductDetails', 'Edition'), 
	(N'ProductDetails', 'ProductLevel'), 
	(N'ProductDetails', 'ProductUpdateLevel'),
	(N'ProductDetails', 'ProductVersion'),
	(N'ProductDetails', 'ProductMajorVersion'),
	(N'ProductDetails', 'ProductMinorVersion'),

	(N'InstanceDetails', 'ServerName'),
	(N'InstanceDetails', 'InstanceName'),
	(N'InstanceDetails', 'IsClustered'),
	(N'InstanceDetails', 'Collation'),

	(N'InstanceFeatures', 'FullTextInstalled'),
	(N'InstanceFeatures', 'IntegratedSecurityOnly'),
	(N'InstanceFeatures', 'FilestreamConfiguredLevel'),
	(N'InstanceFeatures', 'HadrEnabled'),
	(N'InstanceFeatures', 'InstanceDefaultDataPath'),
	(N'InstanceFeatures', 'InstanceDefaultLogPath'),
	(N'InstanceFeatures', 'ErrorLogFileName'),
	(N'InstanceFeatures', 'BuildClrVersion');

	DECLARE propertyizer CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		segment_name,
		property_name 
	FROM 
		@properties
	ORDER BY 
		row_id;

	DECLARE @segment sysname; 
	DECLARE @propertyName sysname;
	DECLARE @propertyValue sysname;
	DECLARE @segmentFamily sysname = N'';

	DECLARE @sql nvarchar(MAX);

	OPEN propertyizer; 

	FETCH NEXT FROM propertyizer INTO @segment, @propertyName;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @sql = N'SELECT @output = CAST(SERVERPROPERTY(''' + @propertyName + N''') as sysname);';

		EXEC sys.sp_executesql 
			@stmt = @sql, 
			@params = N'@output sysname OUTPUT', 
			@output = @propertyValue OUTPUT;

		IF @segment <> @segmentFamily BEGIN 
			SET @segmentFamily = @segment;

			PRINT @crlf + @tab + N'-- ' + @segmentFamily;
		END 
		
		PRINT @tab + @tab + @propertyName + ': ' + ISNULL(@propertyValue, N'NULL');

		FETCH NEXT FROM propertyizer INTO @segment, @propertyName;
	END;

	CLOSE propertyizer; 
	DEALLOCATE propertyizer;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Output Service Details:
	PRINT @crlf + @crlf;
	PRINT @sectionMarker;
	PRINT N'-- Service Details'
	PRINT @sectionMarker;	

	DECLARE @memoryType sysname = N'CONVENTIONAL';
	IF EXISTS (SELECT NULL FROM sys.dm_os_memory_nodes WHERE [memory_node_id] <> 64 AND [locked_page_allocations_kb] <> 0) 
		SET @memoryType = N'LOCKED';


	PRINT @crlf + @tab + N'-- LPIM CONFIG: ' +  @crlf + @tab + @tab + @memoryType;

	DECLARE @command nvarchar(MAX);
	SET @command = N'SELECT 
	servicename, 
	startup_type_desc, 
	service_account, 
	is_clustered, 
	cluster_nodename, 
	[filename] [path], 
	{0} ifi_enabled 
FROM 
	sys.dm_server_services;';	

	IF ((SELECT admindb.dbo.get_engine_version()) >= 13.00) -- ifi added to 2016+
		SET @command = REPLACE(@command, N'{0}', 'instant_file_initialization_enabled');
	ELSE 
		SET @command = REPLACE(@command, N'{0}', '''?''');


	DECLARE @serviceDetails table (
		[servicename] nvarchar(256) NOT NULL,
		[startup_type_desc] nvarchar(256) NOT NULL,
		[service_account] nvarchar(256) NOT NULL,
		[is_clustered] nvarchar(1) NOT NULL,
		[cluster_nodename] nvarchar(256) NULL,
		[path] nvarchar(256) NOT NULL,
		[ifi_enabled] nvarchar(1) NOT NULL
	);
	
	INSERT INTO @serviceDetails ([servicename],  [startup_type_desc], [service_account], [is_clustered], [cluster_nodename], [path], [ifi_enabled])
	EXEC master.sys.[sp_executesql] @command;

	SET @output = @crlf + @tab;

	SELECT 
		@output = @output 
		+ N'-- ' + [servicename] + @crlf 
		+ @tab + @tab + N'StartupType: ' + [startup_type_desc] + @crlf 
		+ @tab + @tab + N'ServiceAccount: ' + service_account + @crlf 
		+ @tab + @tab + N'IsClustered: ' + [is_clustered] + CASE WHEN [cluster_nodename] IS NOT NULL THEN + N' (' + cluster_nodename + N')' ELSE N'' END + @crlf  
		+ @tab + @tab + N'FilePath: ' + [path] + @crlf
		+ @tab + @tab + N'IFI Enabled: ' + [ifi_enabled] + @crlf + @crlf + @tab

	FROM 
		@serviceDetails;


	PRINT @output;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- TODO: Cluster Details (if/as needed). 


	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Global Trace Flags
	DECLARE @traceFlags table (
		[trace_flag] [int] NOT NULL,
		[status] [bit] NOT NULL,
		[global] [bit] NOT NULL,
		[session] [bit] NOT NULL
	)

	INSERT INTO @traceFlags (trace_flag, [status], [global], [session])
	EXECUTE ('DBCC TRACESTATUS() WITH NO_INFOMSGS');

	PRINT @sectionMarker;
	PRINT N'-- Trace Flags'
	PRINT @sectionMarker;

	SET @output = N'' + @crlf;

	SELECT @output = @output 
		+ @tab + N'-- ' + CAST([trace_flag] AS sysname) + N': ' + CASE WHEN [status] = 1 THEN 'ENABLED' ELSE 'DISABLED' END + @crlf
	FROM 
		@traceFlags 
	WHERE 
		[global] = 1;

	PRINT @output + @crlf;

	------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Configuration Settings (outside of norms): 

	DECLARE @config_defaults TABLE (
		[name] nvarchar(35) NOT NULL,
		default_value sql_variant NOT NULL
	);

	INSERT INTO @config_defaults (name, default_value) VALUES 
	('access check cache bucket count',0),
	('access check cache quota',0),
	('Ad Hoc Distributed Queries',0),
	('affinity I/O mask',0),
	('affinity mask',0),
	('affinity64 I/O mask',0),
	('affinity64 mask',0),
	('Agent XPs',1),
	('allow polybase export', 0),
	('allow updates',0),
	('automatic soft-NUMA disabled', 0), -- default is good in best in most cases
	('awe enabled',0),
	('backup checksum default', 0), -- this should really be 1
	('backup compression default',0),
	('blocked process threshold (s)',0),
	('c2 audit mode',0),
	('clr enabled',0),
	('clr strict', 1), -- 2017+ (enabled by default)
	('common criteria compliance enabled',0),
	('contained database authentication', 0),
	('cost threshold for parallelism',5),
	('cross db ownership chaining',0),
	('cursor threshold',-1),
	('Database Mail XPs',0),
	('default full-text language',1033),
	('default language',0),
	('default trace enabled',1),
	('disallow results from triggers',0),
	('EKM provider enabled',0),
	('external scripts enabled',0),  -- 2016+
	('filestream access level',0),
	('fill factor (%)',0),
	('ft crawl bandwidth (max)',100),
	('ft crawl bandwidth (min)',0),
	('ft notify bandwidth (max)',100),
	('ft notify bandwidth (min)',0),
	('index create memory (KB)',0),
	('in-doubt xact resolution',0),
	('hadoop connectivity', 0),  -- 2016+
	('lightweight pooling',0),
	('locks',0),
	('max degree of parallelism',0),
	('max full-text crawl range',4),
	('max server memory (MB)',2147483647),
	('max text repl size (B)',65536),
	('max worker threads',0),
	('media retention',0),
	('min memory per query (KB)',1024),
	('min server memory (MB)',0), -- NOTE: SQL Server apparently changes this one 'in-flight' on a regular basis
	('nested triggers',1),
	('network packet size (B)',4096),
	('Ole Automation Procedures',0),
	('open objects',0),
	('optimize for ad hoc workloads',0),
	('PH timeout (s)',60),
	('polybase network encryption',1),
	('precompute rank',0),
	('priority boost',0),
	('query governor cost limit',0),
	('query wait (s)',-1),
	('recovery interval (min)',0),
	('remote access',1),
	('remote admin connections',0),
	('remote data archive',0),
	('remote login timeout (s)',10),
	('remote proc trans',0),
	('remote query timeout (s)',600),
	('Replication XPs',0),
	('scan for startup procs',0),
	('server trigger recursion',1),
	('set working set size',0),
	('show advanced options',0),
	('SMO and DMO XPs',1),
	('SQL Mail XPs',0),
	('transform noise words',0),
	('two digit year cutoff',2049),
	('user connections',0),
	('user options',0),
	('xp_cmdshell',0);

	PRINT @sectionMarker;
	PRINT N'-- Modified Configuration Options'
	PRINT @sectionMarker;	

	SET @output = N'';

	SELECT @output = @output +
		+ @tab + N'-- ' + c.[name] + @crlf
		+ @tab + @tab + N'DEFAULT: ' + CAST([d].[default_value] AS sysname) + @crlf
		+ @tab + @tab + N'VALUE_IN_USE: ' +  CAST(c.[value_in_use] AS sysname) + @crlf
		+ @tab + @tab + N'VALUE: ' + CAST(c.[value] AS sysname) + @crlf + @crlf
	FROM sys.configurations c 
	INNER JOIN @config_defaults d ON c.name = d.name
	WHERE
		c.value <> c.value_in_use
		OR c.value_in_use <> d.default_value;
	

	PRINT @output;


		-- Server Log - config setttings (path and # to keep/etc.)

		-- base paths - backups, data, log... 

		-- count of all logins... 
		-- list of all logins with SysAdmin membership.

		-- list of all dbs, files/file-paths... and rough sizes/details. 

		-- DDL triggers. 

		-- endpoints. 

		-- linked servers. 

		-- credentials (list and detail - sans passwords/sensitive info). 

		-- Resource Governor Pools/settings/etc. 

		-- Audit Specs? (yes - though... guessing they're hard-ish to script?)  -- and these are things i can add-in later - i.e., 30 - 60 minutes here/there to add in audits, XEs, and the likes... 

		-- XEs ? (yeah... why not). 

		-- Mirrored DB configs. (partners, listeners, certs, etc.)

		-- AG configs + listeners and such. 

		-- replication pubs and subs

		-- Mail Settings. Everything. 
			-- profiles and which one is the default. 
			--		list of accounts per profile (in ranked order)
			-- accounts and all details. 


		-- SQL Server Agent - 
			-- config settings. 
			-- operators
			-- alerts
			-- operators
			-- JOBS... all of 'em.  (guessing I can FIND a script that'll do this for me - i.e., someone else has likely written it).


	RETURN 0;
GO