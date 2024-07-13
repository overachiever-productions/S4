/*


	EXAMPLE:
			EXEC [admindb].dbo.[eventstore_report_blocked_processes_counts]
				--@Granularity = ?,
				@Start = N'2024-07-01',
				--@End = ?,
				@TimeZone = N'Eastern Standard Time',
				--@UseDefaults = ?,
				@IncludeSelfBlocking = 1,
				@IncludePhantomBlocking = 1,
				@Databases = N'-master, x3' --,
				--@Applications = ?,
				--@Hosts = ?,
				--@Principals = ?,
				--@Statements = N'-%SELECT%FROM%blah%';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_blocked_processes_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_blocked_processes_counts];
GO

CREATE PROC dbo.[eventstore_report_blocked_processes_counts]
	@Granularity				sysname			= N'HOUR', 
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@IncludeSelfBlocking		bit				= 1, 
	@IncludePhantomBlocking		bit				= 1,
	@UseDefaults				bit				= 1, 
	@Databases					nvarchar(MAX)	= NULL,
	@Applications				nvarchar(MAX)	= NULL, 
	@Hosts						nvarchar(MAX)	= NULL, 
	@Principals					nvarchar(MAX)	= NULL,
	@Statements					nvarchar(MAX)	= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');
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
	DECLARE @reportType sysname = N'COUNT';
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
			@Granularity = @Granularity,
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

		IF @Granularity IS NULL SELECT @Granularity = CAST([value] AS sysname) FROM @predicates WHERE [key] = N'@Granularity';
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
	SET @outcome = 0;
	DECLARE @times xml;
	EXEC @outcome = dbo.[eventstore_timebounded_counts]
		@Granularity = @Granularity,
		@Start = @Start,
		@End = @End,
		@SerializedOutput = @times OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(start_time)[1]', N'datetime') [start_time],
			[data].[row].value(N'(end_time)[1]', N'datetime') [end_time] 
		FROM 
			@times.nodes(N'//time') [data]([row])
	) 

	SELECT 
		[block_id],
		[start_time],
		[end_time]
	INTO 
		#times
	FROM 
		shredded 
	ORDER BY 
		[block_id];
	
	IF @Start IS NULL BEGIN 
		SELECT 
			@Start = MIN([start_time]), 
			@End = MAX([end_time]) 
		FROM 
			[#times];
	END;

	IF @End IS NULL SET @End = GETUTCDATE();

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metrics Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @filters nvarchar(MAX) = N'';
	DECLARE @joins nvarchar(MAX) = N'';

	CREATE TABLE #metrics ( 
		[event_time] datetime NOT NULL, 
		[signature] sysname NULL,  /* only used for cadence */
		[transaction_id] bigint NULL, 
		[blocked_id] int NOT NULL,
		[seconds_blocked] decimal(24,2) NOT NULL, 
		[type] sysname NOT NULL
	);

	CREATE NONCLUSTERED INDEX #metrics_by_event_time ON [#metrics] ([event_time]) INCLUDE ([transaction_id], [seconds_blocked], [type]);
	CREATE NONCLUSTERED INDEX #metrics_for_cadence_signatures ON [#metrics] ([signature]) INCLUDE ([seconds_blocked]);

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
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) END [principal],
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
	[e].[timestamp] [event_time], 
	CAST([e].[blocking_id] AS sysname) + N'':'' + CAST([e].[blocked_id] AS sysname) + N''=>'' + CAST([e].[blocking_xactid] AS sysname) + N''::'' + CAST([e].[blocked_xactid] AS sysname) [signature],
	ISNULL([e].[blocking_xactid], 0 - [e].[blocked_xactid]) [transaction_id], 
	[e].[blocked_id],
	[e].[seconds_blocked],
	CASE 
		WHEN [e].[blocked_xactid] IS NOT NULL AND [e].[blocking_xactid] IS NOT NULL THEN N''STANDARD''
		WHEN [e].[blocked_xactid] IS NOT NULL AND [e].[blocking_xactid] IS NULL THEN N''SELF''
		WHEN [e].[blocked_xactid] IS NULL AND [e].[blocking_xactid] IS NOT NULL THEN ''PHANTOM''
	END [type]
FROM 
	{SourceTable} [e]{joins}
WHERE 
	[e].[timestamp] >= @Start 
	AND [e].[timestamp] <= @End{filters};';	

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

	INSERT INTO [#metrics] ([event_time], [signature], [transaction_id], [blocked_id], [seconds_blocked], [type])
	EXEC sys.sp_executesql 
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/

	/* Define Blocked Processes Threshold Seconds (i.e., 'cadence' for how frequently reports are being generated. */
	DECLARE @blockedProcessThresholdCadenceSeconds int;
	WITH chained AS ( 
		SELECT TOP 5000
			[signature]
		FROM 
			[#metrics] 
		GROUP BY 
			[signature] 
		HAVING 
			COUNT(*) > 2
	),
	aligned AS ( 
		SELECT TOP 20000
			[m].[seconds_blocked], 
			LAG([m].[seconds_blocked], 1, NULL) OVER (PARTITION BY [m].[signature] ORDER BY [m].[seconds_blocked]) [previous]
		FROM 
			[#metrics] [m]
			INNER JOIN [chained] [x] ON [m].[signature] = [x].[signature]
	), 
	diffed AS ( 
		SELECT 
			CAST([seconds_blocked] - [previous] AS int) [seconds]
		FROM 
			[aligned] 
		WHERE 
			[previous] IS NOT NULL
	), 
	ranked AS (
		SELECT 
			[seconds], 
			COUNT(*) [hits],
			DENSE_RANK() OVER (ORDER BY COUNT(*) DESC) [rank]
		FROM 
			[diffed]
		GROUP BY 
			[seconds]
	)

	SELECT 
		@blockedProcessThresholdCadenceSeconds = ISNULL([seconds], 2)
	FROM 
		[ranked]
	WHERE 
		[rank] = 1;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Standard Blocking:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @ansiWarnings sysname = N'ON';
	IF @@OPTIONS & 8 < 8 BEGIN 
		SET @ansiWarnings = N'OFF';
		SET ANSI_WARNINGS OFF;
	END;

	WITH times AS ( 
		SELECT 
			[t].[block_id], 
			[t].[start_time], 
			[t].[end_time]
		FROM 
			[#times] [t]
	), 
	coordinated AS ( 
		SELECT 
			[t].[block_id],
			[t].[start_time],
			[t].[end_time], 
			[m].[transaction_id],
			[m].[blocked_id], 
			[m].[event_time], 
			[m].[seconds_blocked] [running_seconds], 
			CASE 
				WHEN [m].[seconds_blocked] IS NULL THEN 0 
				WHEN [m].[seconds_blocked] > ISNULL(@blockedProcessThresholdCadenceSeconds, 2) AND [m].[seconds_blocked] < (2 * ISNULL(@blockedProcessThresholdCadenceSeconds, 2)) THEN [m].[seconds_blocked] 
				ELSE ISNULL(@blockedProcessThresholdCadenceSeconds, 2) 
			END [accrued_seconds]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#metrics] [m] ON [m].[type] = N'STANDARD' AND [m].[event_time] < t.[end_time] AND [m].[event_time] > [t].[start_time] 
	), 
	maxed AS ( 
		SELECT 
			[block_id], 
			[transaction_id],   
			COUNT([transaction_id]) [total_events], 
			COUNT(DISTINCT [transaction_id]) [total_blocked_spids],
			MAX([running_seconds]) [running_seconds_blocked],
			SUM([accrued_seconds]) [accrued_seconds_blocked]
		FROM 
			[coordinated]
		GROUP BY 
			[block_id], [transaction_id]
	), 
	summed AS ( 
		SELECT 
			[block_id], 
			SUM([total_blocked_spids]) [total_blocked_spids], 
			SUM([total_events]) [total_events], 
			SUM([running_seconds_blocked]) [running_seconds_blocked], 
			SUM([accrued_seconds_blocked]) [accrued_seconds_blocked]
		FROM 
			maxed
		GROUP BY 
			[block_id]
	)

	SELECT 
		[t].[block_id],
		[total_blocked_spids],
		[total_events],
		ISNULL([running_seconds_blocked], 0) [running_seconds_blocked],
		ISNULL([accrued_seconds_blocked], 0) [accrued_seconds_blocked]
	INTO 
		#standardBlocking
	FROM 
		[times] [t]
		LEFT OUTER JOIN summed [s] ON [t].[block_id] = [s].[block_id]
	ORDER BY 
		[block_id];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- SELF Blocking:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @IncludeSelfBlocking = 1 BEGIN
		WITH times AS ( 
			SELECT 
				[t].[block_id], 
				[t].[start_time], 
				[t].[end_time]
			FROM 
				[#times] [t]
		), 
		coordinated AS ( 
			SELECT 
				[t].[block_id],
				[t].[start_time],
				[t].[end_time], 
				[m].[transaction_id],
				[m].[blocked_id], 
				[m].[event_time], 
				[m].[seconds_blocked] [running_seconds], 
				CASE 
					WHEN [m].[seconds_blocked] IS NULL THEN 0 
					WHEN [m].[seconds_blocked] > ISNULL(@blockedProcessThresholdCadenceSeconds, 2) AND [m].[seconds_blocked] < (2 * ISNULL(@blockedProcessThresholdCadenceSeconds, 2)) THEN [m].[seconds_blocked] 
					ELSE ISNULL(@blockedProcessThresholdCadenceSeconds, 2) 
				END [accrued_seconds]
			FROM 
				[times] [t]
				LEFT OUTER JOIN [#metrics] [m] ON [m].[type] = N'SELF' AND [m].[event_time] < t.[end_time] AND [m].[event_time] > [t].[start_time] 
		), 
		maxed AS ( 
			SELECT 
				[block_id], 
				[transaction_id], 
				COUNT([transaction_id]) [total_events], 
				COUNT(DISTINCT [transaction_id]) [total_blocked_spids],
				MAX([running_seconds]) [running_seconds_blocked],
				SUM([accrued_seconds]) [accrued_seconds_blocked]
			FROM 
				[coordinated]
			GROUP BY 
				[block_id], [transaction_id]
		), 
		summed AS ( 
			SELECT 
				[block_id], 
				SUM([total_blocked_spids]) [total_blocked_spids], 
				SUM([total_events]) [total_events], 
				SUM([running_seconds_blocked]) [running_seconds_blocked], 
				SUM([accrued_seconds_blocked]) [accrued_seconds_blocked]
			FROM 
				maxed
			GROUP BY 
				[block_id]
		)
	
		SELECT 
			[t].[block_id],
			[total_blocked_spids],
			[total_events],
			ISNULL([running_seconds_blocked], 0) [running_seconds_blocked],
			ISNULL([accrued_seconds_blocked], 0) [accrued_seconds_blocked]
		INTO 
			#selflocking
		FROM 
			[times] [t]
			LEFT OUTER JOIN summed [s] ON [t].[block_id] = [s].[block_id]
		ORDER BY 
			[block_id];
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Phantom Blocking:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @IncludePhantomBlocking = 1 BEGIN
		WITH times AS ( 
			SELECT 
				[t].[block_id], 
				[t].[start_time], 
				[t].[end_time]
			FROM 
				[#times] [t]
		), 
		coordinated AS ( 
			SELECT 
				[t].[block_id],
				[t].[start_time],
				[t].[end_time], 
				[m].[transaction_id],
				[m].[blocked_id], 
				[m].[event_time], 
				[m].[seconds_blocked] [running_seconds], 
				CASE 
					WHEN [m].[seconds_blocked] IS NULL THEN 0 
					WHEN [m].[seconds_blocked] > ISNULL(@blockedProcessThresholdCadenceSeconds, 2) AND [m].[seconds_blocked] < (2 * ISNULL(@blockedProcessThresholdCadenceSeconds, 2)) THEN [m].[seconds_blocked] 
					ELSE ISNULL(@blockedProcessThresholdCadenceSeconds, 2) 
				END [accrued_seconds]
			FROM 
				[times] [t]
				LEFT OUTER JOIN [#metrics] [m] ON [m].[type] = N'PHANTOM' AND [m].[event_time] < t.[end_time] AND [m].[event_time] > [t].[start_time] 
		), 
		maxed AS ( 
			SELECT 
				[block_id], 
				[transaction_id], 
				COUNT([transaction_id]) [total_events], 
				COUNT(DISTINCT [transaction_id]) [total_blocked_spids],
				MAX([running_seconds]) [running_seconds_blocked],
				SUM([accrued_seconds]) [accrued_seconds_blocked]
			FROM 
				[coordinated]
			GROUP BY 
				[block_id], [transaction_id]
		), 
		summed AS ( 
			SELECT 
				[block_id], 
				SUM([total_blocked_spids]) [total_blocked_spids], 
				SUM([total_events]) [total_events], 
				SUM([running_seconds_blocked]) [running_seconds_blocked], 
				SUM([accrued_seconds_blocked]) [accrued_seconds_blocked]
			FROM 
				maxed
			GROUP BY 
				[block_id]
		)
	
		SELECT 
			[t].[block_id],
			[total_blocked_spids],
			[total_events],
			ISNULL([running_seconds_blocked], 0) [running_seconds_blocked],
			ISNULL([accrued_seconds_blocked], 0) [accrued_seconds_blocked]
		INTO 
			#phantomBlocking
		FROM 
			[times] [t]
			LEFT OUTER JOIN summed [s] ON [t].[block_id] = [s].[block_id]
		ORDER BY 
			[block_id];
	END;

	IF @ansiWarnings = N'ON'
		SET ANSI_WARNINGS ON;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection (and supporting Logic):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @crlftabtab nchar(4) = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9);

	SET @sql = N'SELECT 
	[t].[end_time] [utc_end_time],{local_zone}
	[b].[total_events] [blocking_reports], 
	[b].[total_blocked_spids] [blocked_spids],
	ISNULL([b].[accrued_seconds_blocked], 0) [blocking_seconds], 
	ISNULL([b].[running_seconds_blocked], 0) [running_seconds]{spacer}{self_cols}{phantom_cols}
FROM 
	[#times] [t]
	LEFT OUTER JOIN [#standardBlocking] [b] ON [t].[block_id] = [b].[block_id]{self_join}{phantom_join}
ORDER BY 
	[t].[block_id];'; 

	IF UPPER(@timeZoneTransformType) <> N'NONE' BEGIN 
		SET @sql = REPLACE(@sql, N'{local_zone}', @crlftab + N'CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime) [' + REPLACE(REPLACE(LOWER(@TimeZone), N' ', N'_'), N'_time', N'') + N'_end_time],');
	  END;
	ELSE 
		SET @sql = REPLACE(@sql, N'{local_zone}', N'');

	IF @IncludePhantomBlocking = 1 OR @IncludeSelfBlocking = 1 BEGIN 
		SET @sql = REPLACE(@sql, N'{spacer}', N',' + @crlftab + N'N'' '' [ ],');

		IF @IncludeSelfBlocking = 1 BEGIN 
			DECLARE @selfCols nvarchar(MAX) = N'
	[s].[total_events] [self_blocking_reports], 
	[s].[total_blocked_spids] [self_blocked_spids],
	ISNULL([s].[accrued_seconds_blocked], 0) [self_blocking_seconds], 
	ISNULL([s].[running_seconds_blocked], 0) [self_running_seconds]';
			SET @sql = REPLACE(@sql, N'{self_cols}', @selfCols);
			SET @sql = REPLACE(@sql, N'{self_join}', @crlftab + N'LEFT OUTER JOIN [#selflocking] [s] ON [t].[block_id] = [s].[block_id] ');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{self_cols}', N'');
			SET @sql = REPLACE(@sql, N'{self_join}', N'');
		END;

		IF @IncludePhantomBlocking = 1 BEGIN 
			DECLARE @phantomCols nvarchar(MAX) = N'
	[p].[total_events] [phantom_blocking_reports], 
	[p].[total_blocked_spids] [phantom_blocked_spids],
	ISNULL([p].[accrued_seconds_blocked], 0) [phantom_blocking_seconds], 
	ISNULL([p].[running_seconds_blocked], 0) [phantom_running_seconds]';

			SET @sql = REPLACE(@sql, N'{phantom_cols}', CASE WHEN @IncludeSelfBlocking = 1 THEN N',' ELSE N'' END + @phantomCols);
			SET @sql = REPLACE(@sql, N'{phantom_join}', @crlftab + N'LEFT OUTER JOIN [#phantomBlocking] [p] ON [t].[block_id] = [p].[block_id]');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{phantom_cols}', N'');
			SET @sql = REPLACE(@sql, N'{phantom_join}', N'');
		END;
	  END;
	ELSE BEGIN
		SET @sql = REPLACE(@sql, N'{spacer}', N'');
		SET @sql = REPLACE(@sql, N'{self_cols}', N'');
		SET @sql = REPLACE(@sql, N'{self_join}', N'');
		SET @sql = REPLACE(@sql, N'{phantom_cols}', N'');
		SET @sql = REPLACE(@sql, N'{phantom_join}', N'');
	END;

	EXEC [dbo].[print_long_string] @sql;
	
	EXEC [sys].[sp_executesql]
		@sql;

	RETURN 0;
GO