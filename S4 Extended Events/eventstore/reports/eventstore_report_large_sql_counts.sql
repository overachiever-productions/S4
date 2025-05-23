/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_large_sql_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_large_sql_counts];
GO

CREATE PROC dbo.[eventstore_report_large_sql_counts]
	@Granularity				sysname			= N'HOUR', 
	@StartUTC					datetime		= NULL, 
	@EndUTC						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@UseDefaults				bit				= 1, 
	@EventStoreTarget			sysname			= NULL,	
	@ExcludeSqlAgentJobs		bit				= 1, 
	@ExcludeSqlCmd				bit				= 1,
	@MinCpuMilliseconds			int				= -1, 
	@MinDurationMilliseconds	int				= -1, 
	@MinRowsModifiedCount		int				= -1,
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
	SET @EventStoreTarget = NULLIF(@EventStoreTarget, N'');
	SET @UseDefaults = ISNULL(@UseDefaults, 1);

	SET @ExcludeSqlAgentJobs = ISNULL(@ExcludeSqlAgentJobs, 1);
	SET @ExcludeSqlCmd = ISNULL(@ExcludeSqlCmd, 1);
	SET @MinCpuMilliseconds = ISNULL(@MinCpuMilliseconds, -1);
	SET @MinDurationMilliseconds = ISNULL(@MinDurationMilliseconds, -1);
	SET @MinRowsModifiedCount = ISNULL(@MinRowsModifiedCount, -1);

	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Statements = NULLIF(@Statements, N'');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metadata + Preferences
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreKey sysname = N'LARGE_SQL';
	DECLARE @reportType sysname = N'COUNT';
	DECLARE @fullyQualifiedTargetTable sysname, @outcome int = 0, @outputID int;

	IF @EventStoreTarget IS NULL BEGIN
		EXEC @outcome = dbo.[eventstore_get_target_by_key]
			@EventStoreKey = @eventStoreKey,
			@TargetTable = @fullyQualifiedTargetTable OUTPUT;

		IF @outcome <> 0 
			RETURN @outcome;
	  END; 
	ELSE BEGIN 
		EXEC @outcome = dbo.[load_id_for_normalized_name]
			@TargetName = @EventStoreTarget,
			@ParameterNameForTarget = N'@EventStoreTarget',
			@NormalizedName = @fullyQualifiedTargetTable OUTPUT, 
			@ObjectID = @outputID OUTPUT;

		IF @outcome <> 0 
			RETURN @outcome;
	END;
	
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
		IF @StartUTC IS NULL BEGIN 
			SET @StartUTC = ISNULL(@defaultStartTime, DATEADD(HOUR, -24, GETUTCDATE())); 
			SET @EndUTC = GETUTCDATE();
		END;

		IF NULLIF(@defaultPredicates, N'') IS NOT NULL BEGIN 
			DECLARE @predicates table ([key] sysname NOT NULL, [value] sysname NOT NULL);
			INSERT INTO @predicates ([key], [value]) 
			SELECT 
				LEFT([result], CHARINDEX(N':', [result]) - 1) [key], 
				SUBSTRING([result], CHARINDEX(N':', [result]) + 1, LEN([result])) [value]
			FROM  
				dbo.[split_string](@defaultPredicates, N';', 1);
 	
			IF @ExcludeSqlAgentJobs IS NULL SELECT @ExcludeSqlAgentJobs = CAST([value] AS bit) FROM @predicates WHERE [key] = N'@ExcludeSqlAgentJobs';
			IF @ExcludeSqlCmd IS NULL SELECT @ExcludeSqlCmd = CAST([value] AS bit) FROM @predicates WHERE [key] = N'@ExcludeSqlCmd';
			IF @MinCpuMilliseconds IS NULL SELECT @MinCpuMilliseconds = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinCpuMilliseconds';
			IF @MinDurationMilliseconds IS NULL SELECT @MinDurationMilliseconds = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinDurationMilliseconds';
			IF @MinRowsModifiedCount IS NULL SELECT @MinRowsModifiedCount = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinRowsModifiedCount';

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


	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @outcome = 0;
	DECLARE @times xml;
	EXEC @outcome = dbo.[eventstore_timebounded_counts]
		@Granularity = @Granularity,
		@Start = @StartUTC,
		@End = @EndUTC,
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
	
	IF @StartUTC IS NULL BEGIN 
		SELECT 
			@StartUTC = MIN([start_time]), 
			@EndUTC = MAX([end_time]) 
		FROM 
			[#times];
	END;
	
	IF @EndUTC IS NULL SET @EndUTC = GETUTCDATE();

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predicate Mapping and Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @filters nvarchar(MAX) = N'';
	DECLARE @joins nvarchar(MAX) = N'';

	IF @Databases IS NOT NULL BEGIN
		CREATE TABLE #expandedDatabases (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[database] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [database])
		);
	END; 

	IF @Applications IS NOT NULL BEGIN
		CREATE TABLE #applications (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[application_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [application_name]) 
		);
	END;

	IF @Hosts IS NOT NULL BEGIN 
		CREATE TABLE #hosts (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[host_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [host_name])
		); 
	END;

	IF @Principals IS NOT NULL BEGIN
		CREATE TABLE #principals (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[principal] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [principal])
		); 
	END;

	IF @Statements IS NOT NULL BEGIN 
		CREATE TABLE #statements (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[statement] nvarchar(MAX) NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude]) 
		);
	END;

	EXEC [admindb].dbo.[eventstore_report_predicates]
		@Databases = @Databases,
		@Applications = @Applications,
		@Hosts = @Hosts,
		@Principals = @Principals,
		@Statements = @Statements,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metrics Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);

	CREATE TABLE #metrics ( 
		[execution_end_time] datetime NOT NULL, 
		[cpu_milliseconds] bigint NOT NULL,
		[duration_milliseconds] bigint NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL, 
		[row_count] bigint NOT NULL, 
		[database] sysname NOT NULL, 
		[application_name] sysname NOT NULL, 
		[host_name] sysname NOT NULL, 
		[principal] sysname NOT NULL, 
		[statement] nvarchar(MAX) NOT NULL
	); 
	
	DECLARE @exclusions nvarchar(MAX) = N'';
	IF @ExcludeSqlAgentJobs = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[application_name] NOT LIKE N''SQLAgent%''';
	END;

	IF @ExcludeSqlCmd = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[application_name] <> N''SQLCMD''';
	END;

	IF @MinCpuMilliseconds > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[cpu_ms] > ' + CAST(@MinCpuMilliseconds AS sysname);
	END;

	IF @MinDurationMilliseconds > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[duration_ms] > ' + CAST(@MinDurationMilliseconds AS sysname);
	END; 

	IF @MinRowsModifiedCount > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[row_count] > ' + CAST(@MinRowsModifiedCount AS sysname);
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[x].[timestamp] [execution_end_time], 
	[x].[cpu_ms] [cpu_milliseconds], 
	[x].[duration_ms] [duration_milliseconds], 
	[x].[physical_reads] [reads], 
	[x].[writes], 
	[x].[row_count], 
	[x].[database], 
	[x].[application_name], 
	[x].[host_name], 
	[x].[user_name] [principal], 
	[x].[statement]

FROM 
	{SourceTable} [x]{joins}
WHERE 
	[x].[timestamp]>= @StartUTC 
	AND [x].[timestamp] <= @EndUTC{filters}{exclusions};'; 

	SET @sql = REPLACE(@sql, N'{SourceTable}', @fullyQualifiedTargetTable);
	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);
	SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

	DECLARE @timeRangeString nvarchar(MAX) = N'Time-Range is ' + CONVERT(sysname, @StartUTC, 121) + N' - ' + CONVERT(sysname, @EndUTC, 121) + N' (' + ISNULL(@TimeZone, N'UTC') + N').';

	IF (@timeZoneOffsetMinutes IS NOT NULL) AND (@timeZoneTransformType = N'ALL') BEGIN 
		SELECT 
			@StartUTC = CAST((@StartUTC AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime), 
			@EndUTC   = CAST((@EndUTC   AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime);

		SET @timeRangeString = @timeRangeString + N' Translated to ' + CONVERT(sysname, @StartUTC, 121) + N' - ' + CONVERT(sysname, @EndUTC, 121) + N' (UTC).';
	END;

	PRINT @timeRangeString;
	PRINT N'';

	INSERT INTO [#metrics] (
		[execution_end_time],
		[cpu_milliseconds],
		[duration_milliseconds],
		[reads],
		[writes], 
		[row_count],
		[database], 
		[application_name],
		[host_name],
		[principal],
		[statement]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@StartUTC datetime, @EndUTC datetime', 
		@StartUTC = @StartUTC, 
		@EndUTC = @EndUTC;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @sql = N'WITH times AS ( 
		SELECT 
			[t].[block_id], 
			[t].[start_time], 
			[t].[end_time]
		FROM 
			[#times] [t]
	), 
	correlated AS ( 
		SELECT 
			[t].[block_id],
			[t].[start_time],
			[t].[end_time],
			[m].[execution_end_time],
			[m].[cpu_milliseconds],
			[m].[duration_milliseconds],
			[m].[reads],
			[m].[writes], 
			[m].[row_count]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#metrics] [m] ON [m].[execution_end_time] < [t].[end_time] AND [m].[execution_end_time] > [t].[start_time] -- anchors ''up'' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will ''show up'' in hour 13:00... 
	), 
	aggregated AS ( 
		SELECT 
			[block_id], 
			COUNT(*) [events],
			SUM([cpu_milliseconds]) [total_cpu],
			SUM([duration_milliseconds]) [total_duration], 
			SUM(CAST(([reads] * 8.0 / 1024.0) AS decimal(24,2))) [total_reads], 
			SUM(CAST(([writes] * 8.0 / 1024.0) AS decimal(24,2))) [total_writes], 
			SUM([row_count]) [total_rows]
		FROM 
			[correlated]
		WHERE 
			[execution_end_time] IS NOT NULL  -- without this, then ''empty'' time slots (block_ids) end up with COUNT(*) = 1 ... 
		GROUP BY 
			[block_id]
	)

	SELECT 
		[t].[end_time] [utc_end_time],{local_zone}
		ISNULL([a].[events], 0) [events],
		ISNULL([a].[total_cpu], 0) [total_cpu_ms],
		dbo.[format_timespan](ISNULL([a].[total_duration], 0)) [total_duration],
		ISNULL([a].[total_reads], 0) [total_reads_MB],
		ISNULL([a].[total_writes], 0) [total_writes_MB], 
		ISNULL([a].[total_rows], 0) [total_rows]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [aggregated] [a] ON [t].[block_id] = [a].[block_id]
	ORDER BY 
		[t].[block_id]; ';

	IF UPPER(@timeZoneTransformType) <> N'NONE' BEGIN 
		SET @sql = REPLACE(@sql, N'{local_zone}', @crlftab + NCHAR(9) + N'CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime) [' + REPLACE(REPLACE(LOWER(@TimeZone), N' ', N'_'), N'_time', N'') + N'_end_time],');
	  END;
	ELSE 
		SET @sql = REPLACE(@sql, N'{local_zone}', N'');

	EXEC sys.[sp_executesql] 
		@sql;

	RETURN 0;
GO
	
	