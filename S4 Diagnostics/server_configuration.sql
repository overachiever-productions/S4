/*

	TODO: 
		- The basics below are calculated/written-for SQL Server 2019. 
		- Need to see if I'm missing anything for 2019. 
		- And then need to see if/what I should REMOVE for 2017, 2016, etc. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[server_configuration]', 'P') IS NOT NULL
	DROP PROC dbo.[server_configuration];
GO

CREATE PROC dbo.[server_configuration]
	@mode							sysname =		'NON_DEFAULTS',				-- { ALL_SETTINGS | PENDING_CHANGES | NON_DEFAULTS }
	@serialized_output				xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @mode = UPPER(ISNULL(@mode, N'NON_DEFAULTs'));

	IF @mode NOT IN (N'ALL_SETTINGS', N'PENDING_CHANGES', N'NON_DEFAULTS') BEGIN
		RAISERROR (N'Invalid @mode specified. Valid options are: ALL_SETTINGS, PENDING_CHANGES, NON_DEFAULTS.', 16, 1);
		RETURN -5;
	END;

	DECLARE @config_defaults TABLE (
		[name] nvarchar(35),
		default_value sql_variant
	);

	INSERT INTO @config_defaults ([name], [default_value]) 
	VALUES 
		(N'access check cache bucket count', 0), 
		(N'access check cache quota', 0), 
		(N'Ad Hoc Distributed Queries', 0), 
		(N'affinity I/O mask', 0), 
		(N'affinity mask', 0), 
		(N'affinity64 I/O mask', 0), 
		(N'affinity64 mask', 0), 
		(N'Agent XPs', 1), 
		(N'allow polybase export',  0), 
		(N'allow updates', 0), 
		(N'automatic soft-NUMA disabled',  0),  
		(N'awe enabled', 0), 
		(N'backup checksum default',  0),  
		(N'backup compression default', 0), 
		(N'blocked process threshold (s)', 0), 
		(N'c2 audit mode', 0), 
		(N'clr enabled', 0), 
		(N'common criteria compliance enabled', 0), 
		(N'contained database authentication',  0), 
		(N'cost threshold for parallelism', 5), 
		(N'cross db ownership chaining', 0), 
		(N'cursor threshold', -1), 
		(N'Database Mail XPs', 0), 
		(N'default full-text language', 1033), 
		(N'default language', 0), 
		(N'default trace enabled', 1), 
		(N'disallow results from triggers', 0), 
		(N'EKM provider enabled', 0), 
		(N'external scripts enabled', 0), 
		(N'filestream access level', 0), 
		(N'fill factor (%)', 0), 
		(N'ft crawl bandwidth (max)', 100), 
		(N'ft crawl bandwidth (min)', 0), 
		(N'ft notify bandwidth (max)', 100), 
		(N'ft notify bandwidth (min)', 0), 
		(N'index create memory (KB)', 0), 
		(N'in-doubt xact resolution', 0), 
		(N'hadoop connectivity',  0), 
		(N'lightweight pooling', 0), 
		(N'locks', 0), 
		(N'max degree of parallelism', 0), 
		(N'max full-text crawl range', 4), 
		(N'max server memory (MB)', 2147483647), 
		(N'max text repl size (B)', 65536), 
		(N'max worker threads', 0), 
		(N'media retention', 0), 
		(N'min memory per query (KB)', 1024), 
		(N'min server memory (MB)', 0),  -- NOTE: SQL Server apparently changes this one 'in-flight' on a regular basis
		(N'nested triggers', 1), 
		(N'network packet size (B)', 4096), 
		(N'Ole Automation Procedures', 0), 
		(N'open objects', 0), 
		(N'optimize for ad hoc workloads', 0), 
		(N'PH timeout (s)', 60), 
		(N'polybase network encryption', 1), 
		(N'precompute rank', 0), 
		(N'priority boost', 0), 
		(N'query governor cost limit', 0), 
		(N'query wait (s)', -1), 
		(N'recovery interval (min)', 0), 
		(N'remote access', 1), 
		(N'remote admin connections', 0), 
		(N'remote data archive', 0), 
		(N'remote login timeout (s)', 10), 
		(N'remote proc trans', 0), 
		(N'remote query timeout (s)', 600), 
		(N'Replication XPs', 0), 
		(N'scan for startup procs', 0), 
		(N'server trigger recursion', 1), 
		(N'set working set size', 0), 
		(N'show advanced options', 0), 
		(N'SMO and DMO XPs', 1), 
		(N'SQL Mail XPs', 0), 
		(N'transform noise words', 0), 
		(N'two digit year cutoff', 2049), 
		(N'user connections', 0), 
		(N'user options', 0), 
		(N'xp_cmdshell', 0);

	IF dbo.[get_engine_version]() > 16 BEGIN
		INSERT INTO @config_defaults ([name],  default_value) 
		VALUES 
			 ('clr strict security', 1), 
			 ('column encryption enclave type', 0), 
			 ('tempdb metadata memory-optimized', 0), 
			 ('ADR cleaner retry timeout (min)', 15), 
			 ('ADR Preallocation Factor', 4), 
			 ('version high part of SQL Server', 1048576), 
			 ('version low part of SQL Server', 277610498), 
			 ('Data processed daily limit in TB', 2147483647), 
			 ('Data processed weekly limit in TB', 2147483647), 
			 ('Data processed monthly limit in TB', 2147483647), 
			 ('ADR Cleaner Thread Count', 1), 
			 ('hardware offload enabled', 0), 
			 ('hardware offload config', 0), 
			 ('hardware offload mode', 0), 
			 ('backup compression algorithm', 0), 
			 ('max RPC request params (KB)', 0), 
			 ('allow filesystem enumeration', 1), 
			 ('polybase enabled', 0), 
			 ('suppress recovery model errors', 0), 
			 ('openrowset auto_create_statistics', 1), 
			 ('external xtp dll gen util enabled', 0);
	END;

	IF [dbo].[get_engine_version]() > 17 BEGIN
		INSERT INTO @config_defaults ([name],  default_value) 
		VALUES 
			('ADR cleaner lock timeout (s)', 5), 
			('SLOG memory quota (%)', 75), 
			('max RPC request params (KB)', 0), 
			('max UCS send boxcars', 256), 
			('availability group commit time (ms)', 0), 
			('tiered memory enabled', 0), 
			('max server tiered memory (MB)', 2147483647), 
			('allow filesystem enumeration', 1), 
			('polybase enabled', 0), 
			('suppress recovery model errors', 0), 
			('openrowset auto_create_statistics', 1), 
			('external rest endpoint enabled', 0), 
			('external xtp dll gen util enabled', 0), 
			('external AI runtimes enabled', 0), 
			('allow server scoped db credentials', 0); 
	END;

	CREATE TABLE #output ( 
		[configuration_id] int NOT NULL, 
		[name] nvarchar(35) NOT NULL, 
		[value] int NOT NULL, 
		[value_in_use] int NOT NULL, 
		[default_value] int NOT NULL
	);
	
	IF @mode = N'ALL_SETTINGS' BEGIN 
		INSERT INTO [#output] ([configuration_id], [name], [value], [value_in_use], [default_value])
		SELECT 
			[c].[configuration_id],
			[c].[name],
			CAST([c].[value] AS int) [value],
			CAST([c].[value_in_use] AS int) [value_in_use], 
			[d].[default_value]
		FROM 
			sys.[configurations] [c]
			INNER JOIN @config_defaults [d] ON [c].[name] = [d].[name]
		ORDER BY 
			[c].[configuration_id];

GOTO Project;
	END; 

	IF @mode = N'PENDING_CHANGES' BEGIN 
		INSERT INTO [#output] ([configuration_id], [name], [value], [value_in_use], [default_value])
		SELECT 
			[c].[configuration_id],
			[c].[name],
			CAST([c].[value] AS int) [value],
			CAST([c].[value_in_use] AS int) [value_in_use], 
			[d].[default_value]
		FROM 
			sys.[configurations] [c]
			INNER JOIN @config_defaults [d] ON [c].[name] = [d].[name]
		WHERE
			[c].[value] != [c].[value_in_use]
		ORDER BY 
			[c].[configuration_id];

GOTO Project;
	END;

	INSERT INTO [#output] ([configuration_id], [name], [value], [value_in_use], [default_value])
	SELECT
		[c].[configuration_id],
		[c].[name],
		CAST([value] AS int) [value],
		CAST([value_in_use] AS int) [value_in_use],
		CAST([d].[default_value] AS int) [default_value]
	FROM
		[sys].[configurations] [c]
		INNER JOIN @config_defaults [d] ON [c].[name] = [d].[name]
	WHERE
		[c].[value] != [c].[value_in_use] OR [c].[value_in_use] != [d].[default_value]
	ORDER BY
		[c].[name];

Project:
	
	IF @mode <> N'ALL_SETTINGS' AND EXISTS (SELECT NULL FROM [#output] WHERE [configuration_id] = 1543) BEGIN 
		DELETE FROM [#output] WHERE [configuration_id] = 1543 AND [value_in_use] IN(0, 16) AND [value] IN (0,16);
	END;
	
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				--[configuration_id],
				[name] [@name],
				[value] [@config_value],
				[value_in_use] [@value_in_use], 
				[default_value] [@default]
			FROM 
				#output
			ORDER BY 
				[configuration_id]
			FOR XML PATH(N'configuration'), ROOT(N'configurations'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		--[configuration_id],
		[name],
		[value],
		[value_in_use]
	FROM 
		#output
	ORDER BY 
		[configuration_id];
	
	RETURN 0;
GO