/*


	PICKUP/NEXT:
		I ... thought I had figured out a solid/clean way to address time-zone conversion in the OUTPUTS. 
		And... yeah, I'm sure I did. But it was PROBABLY for non-heatmap reports. 
			So... I need to 'marry' that logic IN TO my heatmap projections. 
		WITH the 'rub' being  that ... time-boundaries then ... cross DAYS... ugh. 


	EXAMPLE: 

			EXEC [admindb]..[eventstore_report_large_sql_heatmap]
				@Mode = N'TIME_OF_WEEK',
				@Granularity = N'HOUR',
				@Start = '2026-01-16',
				@End = '2026-03-02',
				@TimeZone = N'Central Standard Time',
				@UseDefaults = 1,
				@EventStoreTarget = N'admindb_DT.dbo.eventstore_large_sql',
				@ExcludeSqlAgentJobs = 1,
				@ExcludeSqlCmd = 1,
				--@MinCpuMilliseconds = -1,
				--@MinDurationMilliseconds = -1,
				--@MinRowsModifiedCount = -1,
				--@Databases = N'-Anal%',
				--@Applications = N'python',
				@Hosts = NULL,
				@Principals = NULL,
				@Statements = NULL;		



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_large_sql_heatmap]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_large_sql_heatmap];
GO

CREATE PROC dbo.[eventstore_report_large_sql_heatmap]
	@Mode						sysname			= N'TIME_OF_DAY',		-- { TIME_OF_DAY | TIME_OF_WEEK } 
	@Granularity				sysname			= N'HOUR',				-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= N'UTC', 
	@ExcludeUTCHeader			bit				= 0,					-- TODO: make this a 'default'/preference... 
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
	SET @TimeZone = ISNULL(NULLIF(@TimeZone, N''), N'UTC');
	SET @ExcludeUTCHeader = ISNULL(@ExcludeUTCHeader, 0);
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

	-- TODO: validate @Mode
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metadata + Preferences
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreKey sysname = N'LARGE_SQL';
	DECLARE @reportType sysname = N'HEATMAP';
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
			IF @ExcludeSqlAgentJobs IS NULL SELECT @ExcludeSqlAgentJobs = CAST([value] AS bit) FROM @predicates WHERE [key] = N'@ExcludeSqlAgentJobs';
			IF @ExcludeSqlCmd IS NULL SELECT @ExcludeSqlCmd = CAST([value] AS bit) FROM @predicates WHERE [key] = N'@ExcludeSqlCmd';
			IF @MinCpuMilliseconds IS NULL SELECT @MinCpuMilliseconds = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinCpuMilliseconds';
			IF @MinDurationMilliseconds IS NULL SELECT @MinDurationMilliseconds = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinDurationMilliseconds';
			IF @MinRowsModifiedCount IS NULL SELECT @MinRowsModifiedCount = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinRowsModifiedCount';

			IF @Databases IS NULL SELECT @Databases = [value] FROM @predicates WHERE [key] = N'@Databases';
 			IF @Applications IS NULL SELECT @Applications = [value] FROM @predicates WHERE [key] = N'@Applications';
			IF @Hosts IS NULL SELECT @Hosts = [value] FROM @predicates WHERE [key] = N'@Hosts';
			IF @Principals IS NULL SELECT @Principals = [value] FROM @predicates WHERE [key] = N'@Principals';
			IF @Statements IS NULL SELECT @Statements = [value] FROM @predicates WHERE [key] = N'@Statements';
		END;
	END;

	-- TODO: @ExcludeUTCHeader can only be 1 IF there's a VALID @TimeZone specified 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Zone Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @TimeZone IS NOT NULL BEGIN 
		IF (SELECT [dbo].[get_engine_version]()) < 13.00 BEGIN
			RAISERROR(N'@TimeZone is only supported on SQL Server 2016+.', 16, 1);
			RETURN -110;			
		END;

		IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
			SET @TimeZone = dbo.[get_local_timezone]();
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predicate Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @outcome = 0;
	DECLARE @map xml;
	
	EXEC @outcome = dbo.[eventstore_heatmap_frame]
		@Granularity = @Granularity,
        @TimeZone = @TimeZone,
		@Start = @Start, 
		@End = @End,
		@SerializedOutput = @map OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(start_time)[1]', N'time') [start_time],
			[data].[row].value(N'(end_time)[1]', N'time') [end_time], 
			[data].[row].value(N'(local_start)[1]', N'datetime2(4)') [zone_start], 
			[data].[row].value(N'(local_end)[1]', N'datetime2(4)') [zone_end]
		FROM 
			@map.nodes(N'//time') [data]([row])
	) 

	SELECT 
		[block_id],
		[start_time],
		[end_time],
		[zone_start], 
		[zone_end]
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
		[row_count] bigint NOT NULL
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
	[x].[row_count]
FROM 
	{SourceTable} [x]{joins}
WHERE 
	[x].[timestamp]>= @Start 
	AND [x].[timestamp] <= @End{filters}{exclusions};'; 

	SET @sql = REPLACE(@sql, N'{SourceTable}', @fullyQualifiedTargetTable);
	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);
	SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

	INSERT INTO [#metrics] (
		[execution_end_time],
		[cpu_milliseconds],
		[duration_milliseconds],
		[reads],
		[writes], 
		[row_count]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @timeBounds nvarchar(MAX) = N'';
	DECLARE @orderBy nvarchar(MAX) = N'[utc_time]';
	DECLARE @renamed nvarchar(MAX) = N'zone_time';	

	IF @TimeZone = N'UTC' BEGIN
		SET @timeBounds = N'[utc_time],'
		END;
	ELSE BEGIN 
		SET @renamed = REPLACE(LOWER(@TimeZone), N' ', N'_');

		IF @ExcludeUTCHeader = 1 BEGIN 
			SET @timeBounds = N'[zone_time] [{renamed}],';
			SET @orderBy = N'[zone_time]';
			END;
		ELSE BEGIN
			SET @timeBounds = N'[utc_time],' + @crlftab + N'[zone_time] [{renamed}], ';
		END;
	END;

	IF @Mode = N'TIME_OF_DAY' BEGIN 
		
		WITH correlated AS ( 
			SELECT 
				[t].[block_id], 
				[m].[execution_end_time], 
				[m].[cpu_milliseconds], 
				[m].[duration_milliseconds], 
				[m].[reads], 
				[m].[writes], 
				[m].[row_count]
			FROM 
				#times [t]
				LEFT OUTER JOIN [#metrics] [m] ON CAST([m].[execution_end_time] AS time) <= CAST([t].[end_time] AS time) AND CAST([m].[execution_end_time] AS time) > CAST([t].[start_time] AS time)
		),
		aggregated AS (
			SELECT 
				[block_id],
				COUNT(*) [events],
				SUM([cpu_milliseconds]) [total_cpu],
				SUM([duration_milliseconds]) [total_duration],
				SUM([reads]) [total_reads],
				SUM([writes]) [total_writes],
				SUM([row_count]) [total_rows]
			FROM 
				correlated 
			WHERE 
				[execution_end_time] IS NOT NULL
			GROUP BY
				[block_id]
		) 

		SELECT 
			FORMAT([t].[start_time], N'hh\:mm') + N':00 - ' + FORMAT([t].[end_time], N'hh\:mm') + N':59' [utc_time],
			FORMAT([t].[zone_start], N'HH\:mm') + N':00 - ' + FORMAT([t].[zone_end], N'HH\:mm') + N':59' [zone_time],
			ISNULL([a].[events], 0) [events],
			ISNULL(FORMAT([a].[total_cpu], N'N0'), N'-') [total_cpu],
			ISNULL(FORMAT([a].[total_duration], N'N0'), N'-') [total_duration],
			ISNULL(FORMAT([a].[total_reads], N'N0'), N'-') [total_reads],
			ISNULL(FORMAT([a].[total_writes], N'N0'), N'-') [total_writes],
			ISNULL(FORMAT([a].[total_rows], N'N0'), N'-') [total_rows]
		INTO 
			#tod_projection  -- this 'extra' projection into yet-another-temp-table incurs a bit of a perf-hit. BUT, makes projection of final results (+ debugging) trivial.
		FROM 
			[#times] [t]
			LEFT OUTER JOIN [aggregated] [a] ON [t].[block_id] = [a].[block_id];

		SET @sql = N'SELECT 
	{time_bounds}
	[events],
	[total_cpu],
	[total_duration],
	[total_reads],
	[total_writes],
	[total_rows] 
FROM 
	[#tod_projection] 
ORDER BY 
	{order_by}; ';

		SET @sql = REPLACE(@sql, N'{time_bounds}', @timeBounds);
		SET @sql = REPLACE(@sql, N'{order_by}', @orderBy);
		SET @sql = REPLACE(@sql, N'{renamed}', @renamed);

		EXEC sys.[sp_executesql] 
			@sql;

		RETURN 0;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- TIME_OF_WEEK
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	ALTER TABLE [#times] ADD [Sunday] sysname NULL;
	ALTER TABLE [#times] ADD [Monday] sysname NULL;
	ALTER TABLE [#times] ADD [Tuesday] sysname NULL;
	ALTER TABLE [#times] ADD [Wednesday] sysname NULL;
	ALTER TABLE [#times] ADD [Thursday] sysname NULL;
	ALTER TABLE [#times] ADD [Friday] sysname NULL;
	ALTER TABLE [#times] ADD [Saturday] sysname NULL;

	CREATE TABLE #days ( 
		[day_id] int IDENTITY(1,1), 
		[day_name] sysname 
	); 

	INSERT INTO [#days] ([day_name])
	VALUES (N'Sunday'), (N'Monday'), (N'Tuesday'), (N'Wednesday'), (N'Thursday'), (N'Friday'), (N'Saturday');

	DECLARE @currentDayID int;
	DECLARE @currentDayName sysname;

	DECLARE @select nvarchar(MAX) = N'WITH correlated AS ( 
	SELECT 
		[t].[block_id], 
		[m].[execution_end_time], 
		[m].[cpu_milliseconds] / 1000. / 1000. [cpu_ksecs], 
		[m].[duration_milliseconds] / 1000. / 1000. [duration_ksecs]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [#metrics] [m] ON DATEPART(WEEKDAY, [m].[execution_end_time]) = @currentDayID
			AND (CAST([m].[execution_end_time] AS time) <= CAST([t].[end_time] as time) AND CAST([m].[execution_end_time] AS time) > CAST([t].[start_time] as time))
	WHERE 
		[m].[execution_end_time] IS NOT NULL
), 
currentDayMetrics AS (
	SELECT 
		[block_id],
		RIGHT(REPLICATE(NCHAR(160), 4) + CAST(COUNT(*) as sysname), 4) + NCHAR(160) + NCHAR(160) + N''|'' + RIGHT(REPLICATE(NCHAR(160), 6) + FORMAT(SUM([cpu_ksecs]), ''N1''), 6) + NCHAR(160) + NCHAR(160) + N''| '' + RIGHT(REPLICATE(NCHAR(160), 6) + FORMAT(SUM([duration_ksecs]), ''N1''), 4) [data]
	FROM 
		[correlated]
	GROUP BY 
		[block_id]
)';

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[day_id], 
		[day_name]
	FROM 
		[#days]
	ORDER BY 
		[day_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @sql = N'{select}

UPDATE [t]
SET 
	[t].[{currentDayName}] = [m].[data]
FROM 
	[#times] [t]
	INNER JOIN [currentDayMetrics] [m] ON [t].[block_id] = [m].[block_id];';
	
		SET @sql = REPLACE(@sql, N'{select}', @select);
		SET @sql = REPLACE(@sql, N'{currentDayName}', @currentDayName);	
			
		--EXEC dbo.[print_long_string] @sql;
		EXEC sys.sp_executesql 
			@sql, 
			N'@currentDayID int', 
			@currentDayID = @currentDayID;
	
		FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	PRINT 'CELL LEGEND: [E (C - D)] - Where E is [total_events], C is [total_cpu_ms], and D is [total_duration_ms].';

	SELECT 
		FORMAT([t].[start_time], N'hh\:mm') + N':00 - ' + FORMAT([t].[end_time], N'hh\:mm') + N':59' [utc_time],
		FORMAT([t].[zone_start], N'HH\:mm') + N':00 - ' + FORMAT([t].[zone_end], N'HH\:mm') + N':59' [zone_time],
		ISNULL([t].[Sunday], N'-') [Sunday],  
		ISNULL([t].[Monday], N'-') [Monday],
		ISNULL([t].[Tuesday], N'-') [Tuesday],
		ISNULL([t].[Wednesday], N'-') [Wednesday],
		ISNULL([t].[Thursday], N'-') [Thursday],
		ISNULL([t].[Friday], N'-') [Friday],
		ISNULL([t].[Saturday], N'-') [Saturday]
	INTO 
		#tow_projection -- this 'extra' projection into yet-another-temp-table incurs a bit of a perf-hit. BUT, makes projection of final results (+ debugging) trivial.
	FROM 
		[#times] [t]
	ORDER BY 
		[block_id];

	SET @sql = N'SELECT 
	{time_bounds}
	[Sunday],
	[Monday],
	[Tuesday],
	[Wednesday],
	[Thursday],
	[Friday],
	[Saturday] 
FROM 
	[#tow_projection]
ORDER BY 
	{order_by}; ';

	SET @sql = REPLACE(@sql, N'{time_bounds}', @timeBounds);
	SET @sql = REPLACE(@sql, N'{order_by}', @orderBy);
	SET @sql = REPLACE(@sql, N'{renamed}', @renamed);

	EXEC sys.[sp_executesql] 
		@sql;

	RETURN 0;
GO