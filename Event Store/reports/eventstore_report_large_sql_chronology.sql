/*
	PICKUP / NEXT: 
		- validate the target for @ProjectionTarget
		- can't be a # 
		- can be a ## 
		- otherwise, target DB is implied as current or has to exist. 
		- THROW if target TABLE already exists. 
			NOT going to bother with 'force' or other problems. 
			Just let the user/caller know that they flubbed it and THEY can fix it. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_large_sql_chronology]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_large_sql_chronology];
GO

CREATE PROC dbo.[eventstore_report_large_sql_chronology]
	@Granularity				sysname			= N'HOUR', 
	@StartUTC					datetime		= NULL, 
	@EndUTC						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@UseDefaults				bit				= 1, 
	@EventStoreTarget			sysname			= NULL,	
	@ProjectionTarget			sysname			= NULL,
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
	DECLARE @reportType sysname = N'CHRONOLOGY';
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
	-- HACK: https://overachieverllc.atlassian.net/browse/EVS-38 
	IF @StartUTC IS NULL 
		SET @StartUTC = DATEADD(YEAR, -10, GETDATE());

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
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
		[row_id] int IDENTITY(1,1) NOT NULL,
		[timestamp] datetime NULL,
		[database] sysname NULL,
		[user_name] sysname NULL,
		[host_name] sysname NULL,
		[application_name] sysname NULL,
		[module] sysname NULL,
		[statement] nvarchar(max) NULL,
		[offset] nvarchar(259) NULL,
		[cpu_ms] bigint NULL,
		[duration_ms] bigint NULL,
		[physical_reads] bigint NULL,
		[writes] bigint NULL,
		[row_count] bigint NULL,
		[report] xml NULL, 
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
	[x].[timestamp],
	[x].[database],
	[x].[user_name],
	[x].[host_name],
	[x].[application_name],
	[x].[module],
	[x].[statement],
	[x].[offset],
	[x].[cpu_ms],
	[x].[duration_ms],
	[x].[physical_reads],
	[x].[writes],
	[x].[row_count],
	[x].[report]
FROM 
	{SourceTable} [x]{joins}
WHERE 
	[x].[timestamp] >= @StartUTC 
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
		[timestamp],
		[database],
		[user_name],
		[host_name],
		[application_name],
		[module],
		[statement],
		[offset],
		[cpu_ms],
		[duration_ms],
		[physical_reads],
		[writes],
		[row_count],
		[report]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@StartUTC datetime, @EndUTC datetime', 
		@StartUTC = @StartUTC, 
		@EndUTC = @EndUTC;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @ExcludeSqlAgentJobs = 0 BEGIN 
		DECLARE @rowId int;
		DECLARE @currentAppName sysname; 
		DECLARE @jobName sysname;

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[row_id],
			[application_name]
		FROM 
			[#metrics] 
		WHERE 
			[application_name] LIKE N'SQLAgent - TSQL JobStep (Job 0%';
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @rowId, @currentAppName;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
			SET @jobName = NULL;  -- have to reset to NULL for project vs return semantics to work.

			EXEC dbo.[translate_program_name_to_agent_job] 
				@ProgramName = @currentAppName, 
				@IncludeJobStepInOutput = 1, 
				@JobName = @jobName OUTPUT;
			
			UPDATE [#metrics] 
			SET 
				[application_name] = N'SQL Agent Job: ' + @jobName 
			WHERE 
				[row_id] = @rowId;
		
			FETCH NEXT FROM [walker] INTO @rowId, @currentAppName;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];
	END;

	SET @sql = N'SELECT 
		[timestamp] [utc_end_time],{local_zone}
		[database],
		[user_name],
		[host_name],
		[application_name],
		[module],
		[statement],
		[offset],
		[cpu_ms] / 1000 [cpu_ms],
		dbo.[format_timespan]([duration_ms] / 1000) [duration],
		[physical_reads],
		[writes],
		[row_count],
		[report]{into}
	FROM 
		[#metrics]
	ORDER BY 
		[timestamp]; ';

	IF @ProjectionTarget IS NOT NULL BEGIN 
		SET @sql = REPLACE(@sql, N'{into}', @crlftab + NCHAR(9) + N'INTO ' + @ProjectionTarget);
		PRINT 'Dumped to ... ' + @ProjectionTarget;
	  END; 
	ELSE 
		SET @sql = REPLACE(@sql, N'{into}', N'');

	IF UPPER(@timeZoneTransformType) <> N'NONE' BEGIN 
		SET @sql = REPLACE(@sql, N'{local_zone}', @crlftab + N'[timestamp] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''' [' + REPLACE(REPLACE(LOWER(@TimeZone), N' ', N'_'), N'_standard_time', N'') + N'_timestamp],' );
	  END;
	ELSE 
		SET @sql = REPLACE(@sql, N'{local_zone}', N'');

	EXEC sys.[sp_executesql] 
		@sql;

	RETURN 0;
GO