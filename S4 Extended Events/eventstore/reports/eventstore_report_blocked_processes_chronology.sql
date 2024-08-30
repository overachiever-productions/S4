/*

	vNEXT:
		MIGHT make sense to call 'phantom' blocking 'system' blocking instead? 
		IF I do that here, though, do it in other reports/etc.


	FODDER: 
		- Notes/Info about EMPTY processes: 
			https://dba.stackexchange.com/questions/168646/empty-blocking-process-in-blocked-process-report



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_blocked_processes_chronology]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_blocked_processes_chronology];
GO

CREATE PROC dbo.[eventstore_report_blocked_processes_chronology]
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@UseDefaults				bit				= 1, 
	@IncludeSelfBlocking		bit				= 1, 
	@IncludePhantomBlocking		bit				= 1,
	@Databases					nvarchar(MAX)	= NULL,
	@Applications				nvarchar(MAX)	= NULL, 
	@Hosts						nvarchar(MAX)	= NULL, 
	@Principals					nvarchar(MAX)	= NULL,
	@Statements					nvarchar(MAX)	= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TimeZone = NULLIF(@TimeZone, N'');

	SET @IncludeSelfBlocking = ISNULL(@IncludeSelfBlocking, 1);
	SET @IncludePhantomBlocking = ISNULL(@IncludePhantomBlocking, 1);
	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Statements = NULLIF(@Statements, N'');	

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metadata + Preferences
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreKey sysname = N'BLOCKED_PROCESSES';
	DECLARE @reportType sysname = N'PROBLEMS';
	DECLARE @fullyQualifiedTargetTable sysname, @outcome int = 0;

	EXEC @outcome = dbo.[eventstore_get_target_by_key]
		@EventStoreKey = @eventStoreKey,
		@TargetTable = @fullyQualifiedTargetTable OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;
	
	IF @UseDefaults = 1 BEGIN
		PRINT 'Loading Defaults...';

		DECLARE @defaultTimeZone sysname, @defaultStartTime datetime, @defaultPredicates nvarchar(MAX);
		EXEC dbo.[eventstore_get_report_preferences]
			@EventStoreKey = @eventStoreKey,
			@ReportType = @reportType,
			@Granularity = NULL,
			@PreferredTimeZone = @defaultTimeZone OUTPUT,
			@PreferredStartTime = @defaultStartTime OUTPUT,
			@PreferredPredicates = @defaultPredicates OUTPUT;

		IF @TimeZone IS NULL SET @TimeZone = @defaultTimeZone;
		IF @Start IS NULL BEGIN 
			SET @Start = ISNULL(@defaultStartTime, DATEADD(HOUR, -24, GETUTCDATE())); 
			SET @End = GETUTCDATE();
		END;

		IF NULLIF(@defaultPredicates, N'') IS NOT NULL BEGIN 
			DECLARE @predicates table ([key] sysname NOT NULL, [value] sysname NOT NULL);
			INSERT INTO @predicates ([key], [value]) 
			SELECT 
				LEFT([result], CHARINDEX(N':', [result]) - 1) [key], 
				SUBSTRING([result], CHARINDEX(N':', [result]) + 1, LEN([result])) [value]
			FROM  
				dbo.[split_string](@defaultPredicates, N';', 1);

		IF @Databases IS NULL SELECT @Databases = [value] FROM @predicates WHERE [key] = N'@Databases';
 		IF @Applications IS NULL SELECT @Applications = [value] FROM @predicates WHERE [key] = N'@Applications';
		IF @Hosts IS NULL SELECT @Hosts = [value] FROM @predicates WHERE [key] = N'@Hosts';
		IF @Principals IS NULL SELECT @Principals = [value] FROM @predicates WHERE [key] = N'@Principals';
		IF @Statements IS NULL SELECT @Statements = [value] FROM @predicates WHERE [key] = N'@Statements';
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Zone Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @timeZoneTransformType sysname = N'NONE';
	IF @TimeZone IS NOT NULL BEGIN 
		IF (SELECT [dbo].[get_engine_version]()) < 13.00 BEGIN
			RAISERROR(N'@TimeZone is only supported on SQL Server 2016+.', 16, 1);
			RETURN -110;			
		END;

		IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
			SET @TimeZone = dbo.[get_local_timezone]();

		DECLARE @timeZoneOffsetMinutes int = (dbo.[get_timezone_offset_minutes](@TimeZone));

		IF @TimeZone IS NULL
			SET @timeZoneTransformType = N'OUTPUT-ONLY';
		ELSE 
			SET @timeZoneTransformType = N'ALL';
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predicate Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	-- N / A

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @End IS NULL SET @End = GETUTCDATE();

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metrics Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @filters nvarchar(MAX) = N'';
	DECLARE @joins nvarchar(MAX) = N'';

	CREATE TABLE #metrics (
		[row_id] int NOT NULL,
		[timestamp] [datetime2](7) NOT NULL,
		[database] [nvarchar](128) NOT NULL,
		[type] sysname NOT NULL,
		[seconds_blocked] [decimal](24, 2) NOT NULL,
		[report_id] [int] NOT NULL,
		[blocking_id] sysname NULL,  -- ''self blockers'' can/will be NULL
		[blocked_id] sysname NOT NULL,
		[blocking_xactid] [bigint] NULL,  -- ''self blockers'' can/will be NULL
		[blocking_request] [nvarchar](MAX) NOT NULL,
		[blocking_sproc_statement] [nvarchar](MAX) NOT NULL,
		[blocking_resource_id] [nvarchar](80) NULL,
		[blocking_resource] [varchar](2000) NOT NULL,
		[blocking_wait_time] [int] NULL,
		[blocking_tran_count] [int] NULL,  -- ''self blockers'' can/will be NULL
		[blocking_isolation_level] [nvarchar](128) NULL,   -- ''self blockers'' can/will be NULL
		[blocking_status] sysname NULL,
		[blocking_start_offset] [int] NULL,
		[blocking_end_offset] [int] NULL,
		[blocking_host_name] sysname NULL,
		[blocking_login_name] sysname NULL,
		[blocking_client_app] sysname NULL,
		[blocked_xactid] [bigint] NULL,  -- can be NULL
		[blocked_request] [nvarchar](max) NOT NULL,
		[blocked_sproc_statement] [nvarchar](max) NOT NULL,
		[blocked_resource_id] [nvarchar](80) NOT NULL,
		[blocked_resource] [varchar](2000) NULL,  -- can be NULL if/when there isn''t an existing translation
		[blocked_wait_time] [int] NOT NULL,
		[blocked_tran_count] [int] NOT NULL,
		[blocked_log_used] [int] NOT NULL,
		[blocked_lock_mode] sysname NULL, -- CAN be NULL
		[blocked_isolation_level] [nvarchar](128) NULL,
		[blocked_status] sysname NOT NULL,
		[blocked_start_offset] [int] NOT NULL,
		[blocked_end_offset] [int] NOT NULL,
		[blocked_host_name] sysname NULL,
		[blocked_login_name] sysname NULL,
		[blocked_client_app] sysname NULL,
		[report] [xml] NOT NULL
	);

	CREATE CLUSTERED INDEX CLIX_#metrics_by_report_id ON [#metrics] ([report_id]);

	/*  NOTE: 
			@IncludeSelfBlocking and @IncludePhantomBlocking
				Are handled as 'post-predicates' (i.e., they're SIMPLY deleted if not wanted.
	*/

	DECLARE @rowId int;
	IF @Databases IS NOT NULL BEGIN 
		DECLARE @databasesValues table (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[databases_value] sysname NOT NULL 
		); 

		CREATE TABLE #expandedDatabases (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [database_name])
		);

		INSERT INTO @databasesValues ([databases_value])
		SELECT [result] FROM dbo.[split_string](@Databases, N',', 1);

		INSERT INTO [#expandedDatabases] ([database_name], [is_exclude])
		SELECT 
			CASE WHEN [databases_value] LIKE N'-%' THEN RIGHT([databases_value], LEN([databases_value]) -1) ELSE [databases_value] END [database_name],
			CASE WHEN [databases_value] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			@databasesValues 
		WHERE 
			[databases_value] NOT LIKE N'%{%';

		IF EXISTS (SELECT NULL FROM @databasesValues WHERE [databases_value] LIKE N'%{%') BEGIN 
			DECLARE @databasesToken sysname, @dbTokenAbsolute sysname;
			DECLARE @databasesXml xml;

			DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				[row_id], 
				[databases_value]
			FROM 
				@databasesValues 
			WHERE 
				[databases_value] LIKE N'%{%';
			
			OPEN [walker];
			FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			
			WHILE @@FETCH_STATUS = 0 BEGIN
				
				SET @outcome = 0;
				SET @databasesXml = NULL;
				SELECT @dbTokenAbsolute = CASE WHEN @databasesToken LIKE N'-%' THEN RIGHT(@databasesToken, LEN(@databasesToken) -1) ELSE @databasesToken END;

				EXEC @outcome = dbo.[list_databases_matching_token]
					@Token = @dbTokenAbsolute,
					@SerializedOutput = @databasesXml OUTPUT;

				IF @outcome <> 0 
					RETURN @outcome; 

				WITH shredded AS ( 
					SELECT
						[data].[row].value('@id[1]', 'int') [row_id], 
						[data].[row].value('.[1]', 'sysname') [database_name]
					FROM 
						@databasesXml.nodes('//database') [data]([row])
				) 
				
				INSERT INTO [#expandedDatabases] ([database_name], [is_exclude])
				SELECT 
					[database_name], 
					CASE WHEN @databasesToken LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
				FROM 
					shredded
				WHERE 
					[database_name] NOT IN (SELECT [database_name] FROM [#expandedDatabases])
				ORDER BY 
					[row_id];
				
				FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			END;
			
			CLOSE [walker];
			DEALLOCATE [walker];
		END;

		IF EXISTS (SELECT NULL FROM [#expandedDatabases] WHERE [is_exclude] = 0) BEGIN 
			SET @joins = @joins + @crlftab + N'INNER JOIN [#expandedDatabases] [d] ON [d].[is_exclude] = 0 AND [e].[database] LIKE [d].[database_name]';
		END; 

		IF EXISTS (SELECT NULL FROM [#expandedDatabases] WHERE [is_exclude] = 1) BEGIN 
			SET @joins = @joins + @crlftab + N'LEFT OUTER JOIN [#expandedDatabases] [dx] ON [dx].[is_exclude] = 1 AND [e].[database] LIKE [dx].[database_name]';
			SET @filters = @filters + @crlftab + N'AND [dx].[database_name] IS NULL';
		END; 
	END;

	IF @Applications IS NOT NULL BEGIN 
		CREATE TABLE #applications (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[application_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [application_name]) 
		);

		INSERT INTO [#applications] ([application_name], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [application_name], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			[dbo].[split_string](@Applications, N',', 1);

		IF EXISTS (SELECT NULL FROM [#applications] WHERE [is_exclude] = 0) BEGIN 
			SET @joins = @joins + @crlftab + N'INNER JOIN [#applications] [a] ON [a].[is_exclude] = 0 AND [e].[application_name] LIKE [a].[application_name]';
		END; 

		IF EXISTS (SELECT NULL FROM [#applications] WHERE [is_exclude] = 1) BEGIN
			SET @joins = @joins + @crlftab + N'LEFT OUTER JOIN [#applications] [ax] ON [ax].[is_exclude] = 1 AND [e].[application_name] LIKE [ax].[application_name]';
			SET @filters = @filters + @crlftab + N'AND [ax].[application_name] IS NULL';
		END;
	END;

	IF @Hosts IS NOT NULL BEGIN 
		CREATE TABLE #hosts (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[host_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [host_name])
		); 

		INSERT INTO [#hosts] ([host_name], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [host], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM	
			dbo.[split_string](@Hosts, N',', 1);

		IF EXISTS (SELECT NULL FROM [#hosts] WHERE [is_exclude] = 0) BEGIN
			SET @joins = @joins + @crlftab + N'INNER JOIN [#hosts] [h] ON [h].[is_exclude] = 0 AND [e].[host_name] LIKE [h].[host_name]';
		END;
		
		IF EXISTS (SELECT NULL FROM [#hosts] WHERE [is_exclude] = 1) BEGIN
			SET @joins = @joins + @crlftab + N'LEFT OUTER JOIN [#hosts] [hx] ON [hx].[is_exclude] = 1 AND [e].[host_name] LIKE [hx].[host_name]';
			SET @filters = @filters + @crlftab + N'AND [hx].[host_name] IS NULL';
		END;
	END;

	IF @Principals IS NOT NULL BEGIN
		CREATE TABLE #principals (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[principal] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [principal])
		); 

		INSERT INTO [#principals] ([principal], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [principal],
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			[dbo].[split_string](@Principals, N',', 1);

		IF EXISTS (SELECT NULL FROM [#principals] WHERE [is_exclude] = 0) BEGIN 
			SET @joins = @joins + @crlftab + N'INNER JOIN [#principals] [p] ON [p].[is_exclude] = 0 AND [p].[principal] LIKE [e].[user_name]';
		END; 

		IF EXISTS (SELECT NULL FROM [#principals] WHERE [is_exclude] = 1) BEGIN 
			SET @joins = @joins + @crlftab + N'LEFT OUTER JOIN [#principals] [px] ON [p].[is_exclude] = 1 AND [e].[user_name] LIKE [px].[principal]';
			SET @filters = @filters + @crlftab + N'AND [px].[principal] IS NULL';
		END; 
	END;

	IF @Statements IS NOT NULL BEGIN 
		CREATE TABLE #statements (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[statement] nvarchar(MAX) NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude]) 
		);

		INSERT INTO [#statements] ([statement], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [statement],
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]			
		FROM 
			dbo.[split_string](@Statements, N', ', 1);

		IF EXISTS (SELECT NULL FROM [#statements] WHERE [is_exclude] = 0) BEGIN 
			SET @joins = @joins + @crlftab + N'INNER JOIN [#statements] [s] ON [s].[is_exclude] = 0 AND [e].[statement] LIKE [s].[statement]';
		END;

		IF EXISTS (SELECT NULL FROM [#statements] WHERE [is_exclude] = 1) BEGIN 
			SET @joins = @joins  + @crlftab + N'LEFT OUTER JOIN [#statements] [sx] ON [sx].[is_exclude] = 1 AND [e].[statement] LIKE [sx].[statement]';
			SET @filters = @filters + @crlftab + N'AND [sx].[statement] IS NULL';
		END;
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[e].[row_id],
	[e].[timestamp],
	[e].[database],
	CASE 
		WHEN [e].[blocked_xactid] IS NOT NULL AND [e].[blocking_xactid] IS NOT NULL THEN N''STANDARD''
		WHEN [e].[blocked_xactid] IS NOT NULL AND [e].[blocking_xactid] IS NULL THEN N''SELF''
		WHEN [e].[blocked_xactid] IS NULL AND [e].[blocking_xactid] IS NOT NULL THEN ''PHANTOM''
	END [type],
	[e].[seconds_blocked],
	[e].[report_id],
	[e].[blocking_id],
	[e].[blocked_id],
	[e].[blocking_xactid],
	[e].[blocking_request],
	[e].[blocking_sproc_statement],
	[e].[blocking_resource_id],
	[e].[blocking_resource],
	[e].[blocking_wait_time],
	[e].[blocking_tran_count],
	[e].[blocking_isolation_level],
	[e].[blocking_status],
	[e].[blocking_start_offset],
	[e].[blocking_end_offset],
	[e].[blocking_host_name],
	[e].[blocking_login_name],
	[e].[blocking_client_app],
	[e].[blocked_xactid],
	[e].[blocked_request],
	[e].[blocked_sproc_statement],
	[e].[blocked_resource_id],
	[e].[blocked_resource],
	[e].[blocked_wait_time],
	[e].[blocked_tran_count],
	[e].[blocked_log_used],
	[e].[blocked_lock_mode],
	[e].[blocked_isolation_level],
	[e].[blocked_status],
	[e].[blocked_start_offset],
	[e].[blocked_end_offset],
	[e].[blocked_host_name],
	[e].[blocked_login_name],
	[e].[blocked_client_app],
	[e].[report] 
FROM 
	{SourceTable} [e]{joins}
WHERE 
	[e].[timestamp] >= @Start 
	AND [e].[timestamp] <= @End{filters}
ORDER BY 
	[e].[row_id]';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @fullyQualifiedTargetTable);
	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);

	DECLARE @timeRangeString nvarchar(MAX) = N'Time-Range is ' + CONVERT(sysname, @Start, 121) + N' - ' + CONVERT(sysname, @End, 121) + N' (' + ISNULL(@TimeZone, N'UTC') + N').';

	IF (@timeZoneOffsetMinutes IS NOT NULL) AND (@timeZoneTransformType = N'ALL') BEGIN 
		SELECT 
			@Start = CAST((@Start AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime), 
			@End   = CAST((@End   AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime);

		SET @timeRangeString = @timeRangeString + N' Translated to ' + CONVERT(sysname, @Start, 121) + N' - ' + CONVERT(sysname, @End, 121) + N' (UTC).';
	END;

	PRINT @timeRangeString;
	PRINT N'';
	
	INSERT INTO [#metrics]
	(
		[row_id],
		[timestamp],
		[database],
		[type],
		[seconds_blocked],
		[report_id],
		[blocking_id],
		[blocked_id],
		[blocking_xactid],
		[blocking_request],
		[blocking_sproc_statement],
		[blocking_resource_id],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_tran_count],
		[blocking_isolation_level],
		[blocking_status],
		[blocking_start_offset],
		[blocking_end_offset],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_xactid],
		[blocked_request],
		[blocked_sproc_statement],
		[blocked_resource_id],
		[blocked_resource],
		[blocked_wait_time],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_lock_mode],
		[blocked_isolation_level],
		[blocked_status],
		[blocked_start_offset],
		[blocked_end_offset],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/* 'Post Predicates' */
	IF @IncludeSelfBlocking = 0 BEGIN 
		DELETE FROM [#metrics] WHERE [type] = N'SELF';
	END;

	IF @IncludePhantomBlocking = 0 BEGIN 
		DELETE FROM [#metrics] WHERE [type] = N'PHANTOM';
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH leads AS (		
	
		SELECT report_id, blocking_id
		FROM [#metrics] 

		EXCEPT 

		SELECT report_id, blocked_id
		FROM [#metrics] 

	), 
	chain AS ( 
		SELECT 
			report_id, 
			0 AS [level],
			blocking_id, 
			CAST(blocking_id AS sysname) [blocking_chain]
		FROM 
			leads 

		UNION ALL 

		SELECT 
			base.report_id, 
			c.[level] + 1 [level],
			base.blocked_id, 
			CAST(c.[blocking_chain] + N' -> ' + CAST(base.blocked_id AS nvarchar(10)) AS sysname)
		FROM 
			[#metrics] base 
			INNER JOIN chain c ON base.report_id = c.report_id AND base.blocking_id = c.blocking_id 
	)

	SELECT 
		[report_id],
		[level],
		[blocking_id],
		[blocking_chain]
	INTO 
		#chain
	FROM 
		chain
	WHERE 
		[level] <> 0;

	SELECT 
		report_id, 
		MIN([timestamp]) [timestamp], 
		COUNT(*) [process_count]
	INTO 
		#aggregated
	FROM 
		[#metrics]
	GROUP BY 
		[report_id];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH normalized AS ( 
		SELECT 
			ISNULL([c].[level], -1) [level],
			[m].[blocking_id],
			[m].[blocked_id],
			LAG([m].[report_id], 1, 0) OVER (ORDER BY [m].[report_id], ISNULL([c].[level], -1)) [previous_report_id],

			[m].[report_id] [original_report_id],
			[m].[timestamp],
			[m].[type],
			[m].[database],
			[a].[process_count],

			ISNULL([c].[blocking_chain], N'    ' + CAST([m].[blocked_id] AS sysname) + N' -> (' + CAST([m].[blocked_id] AS sysname) + N')') [blocking_chain],
			
			dbo.[format_timespan]([m].[blocked_wait_time]) [time_blocked],
			
			CASE WHEN [m].[blocking_id] IS NULL THEN N'<blocking-self>' ELSE [m].[blocking_status] END [blocking_status],
			[m].[blocking_isolation_level],
			CASE WHEN [m].[blocking_id] IS NULL THEN N'(' + CAST([m].[blocked_xactid] AS sysname) + N')' ELSE CAST([m].[blocking_xactid] AS sysname) END [blocking_xactid],
			CASE WHEN [m].[blocking_tran_count] IS NULL THEN N'(' + CAST([m].[blocked_tran_count] AS sysname) + N')' ELSE CAST([m].[blocking_tran_count] AS sysname) END [blocking_tran_count],
			CASE WHEN [m].blocking_request LIKE N'%Object Id = [0-9]%' THEN [m].[blocking_request] + N' --> ' + ISNULL([m].[blocking_sproc_statement], N'#sproc_statement_extraction_error#') ELSE ISNULL([m].[blocking_request], N'') END [blocking_request],
			[m].[blocking_resource],

			-- blocked... 
			[m].[blocked_status], -- always suspended or background - but background can be important to know... 
			[m].[blocked_isolation_level],
			[m].[blocked_xactid],
			[m].[blocked_tran_count],
			[m].[blocked_log_used],
			
			CASE WHEN [m].[blocked_request] LIKE N'%Object Id = [0-9]%' THEN [m].[blocked_request] + N' --> ' + ISNULL([m].[blocked_sproc_statement], N'#sproc_statement_extraction_error#') ELSE ISNULL([m].[blocked_request], N'') END [blocked_request],
			[m].[blocked_resource],
			[m].[blocking_host_name],
			[m].[blocking_login_name],
			[m].[blocking_client_app],
			[m].[blocked_host_name],
			[m].[blocked_login_name],
			[m].[blocked_client_app],
			[m].[report]
		FROM 
			[#metrics] [m]
			LEFT OUTER JOIN [#aggregated] a ON [m].[report_id] = [a].[report_id]
			LEFT OUTER JOIN [#chain] c ON [m].[report_id] = [c].[report_id] AND [m].[blocked_id] = c.[blocking_id]
	)

	SELECT 
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE CONVERT(sysname, [timestamp], 121) END [utc_timestamp],
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE [type] END [blocking_type],
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE [database] END [database_name],
		
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE CAST([process_count] AS sysname) END [process_count],
		[blocking_chain],
		[time_blocked],
		[blocking_status],
		[blocking_isolation_level],
		[blocking_xactid],
		[blocking_tran_count],
		[blocking_request],
		[blocking_resource],
		[blocked_status],
		[blocked_isolation_level],
		[blocked_xactid],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_request],
		[blocked_resource],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report] 
	FROM 
		[normalized] 
	ORDER BY 
		[original_report_id], [level];