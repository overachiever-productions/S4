/*


	BUG:
		looks like there's a potential logic-bug with @End ... i.e., if I specify @Start of like 2 weeks ago ... I can leave @End empty? 
			... i've tried adding in some logic that'll try to set @End to GETUTCDATE()... but I'm not sure that's the right approach? 
				i mean... i don't want someone specifying a start of 2 years ago... and no end date, right? 
					or, if they do... it should have to be explicit? 

	BUG / PROBLEM: 
		dbo.[eventstore_heatmap_frame] is focused on TIMES and 'ignores' (effectively) ...dates.
			which means that the datetimes that it throws out ... are 1900-01-01 <time> 
			which made me spend ~40 minutes trying to figure out WHY THE F I could clearly see that GETDATE() AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' 100% correctly
				showed -7:00 (2026-03-18) but my "heatmap_frame" calculations of t.[start_time] AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific....' were 100000% showing as -8:00 always. 
				cuz ... duh, 1900-01-01 is ... january and ... apparently governed by non-DST - i.e., -8 hours. 
				SIGH.


	EXAMPLE:
			EXEC [admindb].dbo.[eventstore_report_all_errors_heatmap]
				@Mode = 'DAY_OF_WEEK',
				--@Granularity = ?,
				@Start = '2024-07-01',
				@MinimumSeverity = 15,
				--@ErrorIds = ?,
				@Databases = N'-master';

*/


USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_all_errors_heatmap]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_all_errors_heatmap];
GO

CREATE PROC dbo.[eventstore_report_all_errors_heatmap]
	@Mode						sysname			= N'TIME_OF_DAY',		-- { TIME_OF_DAY | TIME_OF_WEEK } 
	@Granularity				sysname			= N'HOUR',				-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@ExcludeUTCHeader			bit				= 0,			-- TODO: make this a 'default'/preference... 
	@UseDefaults				bit				= 1, 
	@EventStoreTarget			sysname			= NULL,	
	@MinimumSeverity			int				= -1, 
	@ErrorIds					nvarchar(MAX)	= NULL, 
	@Databases					nvarchar(MAX)	= NULL,
	@Applications				nvarchar(MAX)	= NULL, 
	@Hosts						nvarchar(MAX)	= NULL, 
	@Principals					nvarchar(MAX)	= NULL,
	@Statements					nvarchar(MAX)	= NULL, 
	@ExcludeSystemErrors		bit				= 1			
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');
	SET @TimeZone = NULLIF(@TimeZone, N'');
	SET @ExcludeUTCHeader = ISNULL(@ExcludeUTCHeader, 0);
	SET @EventStoreTarget = NULLIF(@EventStoreTarget, N'');
	SET @UseDefaults = ISNULL(@UseDefaults, 1);

	SET @MinimumSeverity = ISNULL(NULLIF(@MinimumSeverity, 0), -1);
	SET @ErrorIds = NULLIF(@ErrorIds, N'');
	SET @ExcludeSystemErrors = ISNULL(@ExcludeSystemErrors, 1);

	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Statements = NULLIF(@Statements, N'');

	-- TODO: validate @Mode

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metadata + Preferences
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreKey sysname = N'ALL_ERRORS';
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

			IF @Mode IS NULL SELECT @Mode = CAST([value] AS sysname) FROM @predicates WHERE [key] = N'@Mode';
			IF @Granularity IS NULL SELECT @Granularity = CAST([value] AS sysname) FROM @predicates WHERE [key] = N'@Granularity';
			IF @MinimumSeverity IS NULL SELECT @MinimumSeverity = CAST([value] AS int) FROM @predicates WHERE [key] = N'@MinimumSeverity';
			IF @ErrorIds IS NULL SELECT @ErrorIds = [value] FROM @predicates WHERE [key] = N'@ErrorIds';

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
--	DECLARE @timeZoneTransformType sysname = N'NONE';
	IF @TimeZone IS NOT NULL BEGIN 
		IF (SELECT [dbo].[get_engine_version]()) < 13.00 BEGIN
			RAISERROR(N'@TimeZone is only supported on SQL Server 2016+.', 16, 1);
			RETURN -110;			
		END;

		IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
			SET @TimeZone = dbo.[get_local_timezone]();

		DECLARE @timeZoneOffsetMinutes int = (dbo.[get_timezone_offset_minutes](@TimeZone));

		--IF @TimeZone IS NULL
		--	SET @timeZoneTransformType = N'OUTPUT-ONLY';
		--ELSE 
		--	SET @timeZoneTransformType = N'ALL';
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Predicate Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @MinimumSeverity <> -1 BEGIN 
		IF @MinimumSeverity < 1 OR @MinimumSeverity > 25 BEGIN 
			RAISERROR(N'@MinimumSeverity may only be set to a value between 1 and 25.', 16, 1);
			RETURN -11;
		END;
	END;

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
		[error_timestamp] datetime NOT NULL,  
		[error_number] int NOT NULL
	);
	CREATE NONCLUSTERED INDEX #metrics_error_id ON [#metrics] ([error_number]);

	IF @MinimumSeverity <> -1 BEGIN 
		SET @filters = @filters + @crlftab + N'AND Severity >= ' + CAST(@MinimumSeverity AS sysname); 
	END;

	IF @ErrorIds IS NOT NULL BEGIN 
		DECLARE @rawErrorValues TABLE ( 
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[error_value] sysname NOT NULL 
		); 

		CREATE TABLE #expandedErrorIds (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[error_number] int, 
			[is_exclude] bit DEFAULT (0),
			PRIMARY KEY CLUSTERED ([is_exclude], [error_number]) 
		);

		INSERT INTO @rawErrorValues ([error_value])
		SELECT [result] FROM [dbo].[split_string](@ErrorIds, N',', 1);

		INSERT INTO [#expandedErrorIds] ([error_number], [is_exclude])
		SELECT 
			ABS(CAST([error_value] AS int)) [error_number],
			CASE WHEN [error_value] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			@rawErrorValues 
		WHERE 
			[error_value] NOT LIKE N'%{%';

		IF EXISTS (SELECT NULL FROM @rawErrorValues WHERE [error_value] LIKE N'%{%') BEGIN 
			DECLARE @rowId int; 
			DECLARE @errorValue sysname; 

			DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				[row_id], 
				[error_value]
			FROM 
				@rawErrorValues 
			WHERE 
				[error_value] LIKE N'%{%';

			OPEN [walker];
			FETCH NEXT FROM [walker] INTO @rowId, @errorValue;
			
			WHILE @@FETCH_STATUS = 0 BEGIN
			
				INSERT INTO [#expandedErrorIds] ([error_number], [is_exclude])
				SELECT 
					x.[error_id], 
					CASE WHEN @errorValue LIKE N'-%' THEN 1 ELSE 0 END
				FROM 
					dbo.[eventstore_translate_error_token](@errorValue) x
				WHERE 
					x.[error_id] NOT IN (SELECT [error_number] FROM [#expandedErrorIds]);
			
				FETCH NEXT FROM [walker] INTO @rowId, @errorValue;
			END;
			
			CLOSE [walker];
			DEALLOCATE [walker];
		END;

		IF EXISTS (SELECT NULL FROM [#expandedErrorIds] WHERE [is_exclude] = 0) BEGIN 
			SET @joins = @joins + @crlftab + N'INNER JOIN [#expandedErrorIds] [r] ON [r].[is_exclude] = 0 AND [e].[error_number] = [r].[error_number]';
		END;

		IF EXISTS (SELECT NULL FROM [#expandedErrorIds] WHERE [is_exclude] = 1) BEGIN 
			SET @joins = @joins + @crlftab + N'LEFT OUTER JOIN [#expandedErrorIds] [x] ON [x].[is_exclude] = 1 AND [e].[error_number] = [x].[error_number]';
			SET @filters = @filters + @crlftab + N'AND [x].[error_number] IS NULL';
		END;
	END;

	IF @ExcludeSystemErrors = 1 BEGIN 
		SET @filters = @filters + @crlftab + N'AND [e].[is_system] = 0';
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[e].[timestamp] [error_timestamp], 
	[e].[error_number]
FROM 
	{SourceTable} [e]{joins}
WHERE 
	[e].[timestamp] >= @Start 
	AND [e].[timestamp] <= @End{filters};'

	SET @sql = REPLACE(@sql, N'{SourceTable}', @fullyQualifiedTargetTable);
	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);
	--SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

-- TODO: 
--		don't think these time-range strings are correct. think i need to start with @Start/@End as UTC. '
--			then explain what they've been CONVERTED to ... via the conversion. 
-- TODO: 
--		need to warn/output IF we cross a DST boundary - e.g., assume @Start is October 28, and @End is Nov, XXX - that's a DST boundary crossing. 
--			AND ... I'll always use the @End as the REPORTING time 'zone/thingy'. e.g., if we cross a DST boundary in spring, we'll be on the new, spring-summer DST time, whereas if we cross in fall, we'll be on the non-DST fall/winter time.
--		AND... i guess I could put a column or notifier into the PROJECTION that specifies DT or ST... 
	DECLARE @timeRangeString nvarchar(MAX) = N'Time-Range is ' + CONVERT(sysname, @Start, 121) + N' - ' + CONVERT(sysname, @End, 121) + N' (' + ISNULL(@TimeZone, N'UTC') + N').';

	--IF (@timeZoneOffsetMinutes IS NOT NULL) AND (@timeZoneTransformType = N'ALL') BEGIN 
	--	SELECT 
	--		@Start = CAST((@Start AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime), 
	--		@End   = CAST((@End   AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime);

	--	SET @timeRangeString = @timeRangeString + N' Translated to ' + CONVERT(sysname, @Start, 121) + N' - ' + CONVERT(sysname, @End, 121) + N' (UTC).';
	--END;

	PRINT @timeRangeString;
	PRINT N'';

	INSERT INTO [#metrics] (
		[error_timestamp],
		[error_number]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project:
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
				[m].[error_number]	
			FROM 
				[#times] [t] 
				LEFT OUTER JOIN [#metrics] [m] ON CAST([m].[error_timestamp] AS time) <= CAST([t].[end_time] AS time) AND CAST([m].[error_timestamp] AS time) > CAST([t].[start_time] AS time)
		), 
		aggregated AS ( 
			SELECT 
				[block_id], 
				COUNT(*) [errors], 
				-- TODO: possibly look at adding MAX([severity])? 
				COUNT(DISTINCT [error_number]) [distinct_errors]
			FROM 
				[correlated] 
			WHERE 
				[error_number] IS NOT NULL 
			GROUP BY 
				[block_id]
		)
		
		SELECT 
			FORMAT([t].[start_time], N'hh\:mm') + N':00 - ' + FORMAT([t].[end_time], N'hh\:mm') + N':59' [utc_time],
			FORMAT([t].[zone_start], N'HH\:mm') + N':00 - ' + FORMAT([t].[zone_end], N'HH\:mm') + N':59' [zone_time],
			ISNULL([a].[errors], 0) [total_errors], 
			ISNULL([a].[distinct_errors], 0) [distinct_errors]
		INTO 
			#tod_projection  -- this 'extra' projection into yet-another-temp-table incurs a bit of a perf-hit. BUT, makes projection of final results (+ debugging) trivial.
		FROM 
			[#times] [t]
			LEFT OUTER JOIN [aggregated] [a] ON	[t].[block_id] = [a].[block_id]
		ORDER BY
			[t].[block_id]; 

		SET @sql = N'SELECT 
	{time_bounds}
	[total_errors],
	[distinct_errors] 
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
	PRINT N'KEY: total_errors (distinct_error_ids)';

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
		[m].[error_number]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [#metrics] [m] ON DATEPART(WEEKDAY, [m].[error_timestamp]) = @currentDayID
			AND (CAST([m].[error_timestamp] AS time) <= CAST([t].[end_time] as time) AND CAST([m].[error_timestamp] AS time) > CAST([t].[start_time] as time))
	WHERE 
		[m].[error_timestamp] IS NOT NULL
), 
currentDayMetrics AS (
	SELECT 
		[block_id],
		CAST(COUNT(*) as sysname) + N'' ('' + FORMAT(COUNT(DISTINCT [error_number]), ''N0'') + N'')'' [data]
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
			
		EXEC sys.sp_executesql 
			@sql, 
			N'@currentDayID int', 
			@currentDayID = @currentDayID;
	
		FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	SELECT 
		FORMAT([t].[start_time], N'hh\:mm') + N':00 - ' + FORMAT([t].[end_time], N'hh\:mm') + N':59' [utc_time],
		FORMAT([t].[zone_start], N'HH\:mm') + N':00 - ' + FORMAT([t].[zone_end], N'HH\:mm') + N':59' [zone_time],
		ISNULL([Sunday], N'-') [Sunday],  
		ISNULL([Monday], N'-') [Monday],
		ISNULL([Tuesday], N'-') [Tuesday],
		ISNULL([Wednesday], N'-') [Wednesday],
		ISNULL([Thursday], N'-') [Thursday],
		ISNULL([Friday], N'-') [Friday],
		ISNULL([Saturday], N'-') [Saturday]
	INTO 
		#tow_projection -- this 'extra' projection into yet-another-temp-table incurs a bit of a perf-hit. BUT, makes projection of final results (+ debugging) trivial.
	FROM 
		[#times] [t]
	ORDER BY 
		[block_id];

	SET @sql = N'SELECT 
	{time_bounds}
	N'' '' [ ],
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