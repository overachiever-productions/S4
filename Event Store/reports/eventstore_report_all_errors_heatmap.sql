/*


	BUG:
		looks like there's a potential logic-bug with @End ... i.e., if I specify @Start of like 2 weeks ago ... I can leave @End empty? 
			... i've tried adding in some logic that'll try to set @End to GETUTCDATE()... but I'm not sure that's the right approach? 
				i mean... i don't want someone specifying a start of 2 years ago... and no end date, right? 
					or, if they do... it should have to be explicit? 


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
	@Mode						sysname			= N'TIME_OF_DAY',
	@Granularity				sysname			= N'HOUR', 
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@UseDefaults				bit				= 1, 
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

	SET @Mode = UPPER(ISNULL(NULLIF(@Mode, N''), N'TIME_OF_DAY'));
	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');
	SET @TimeZone = NULLIF(@TimeZone, N'');

	SET @MinimumSeverity = ISNULL(NULLIF(@MinimumSeverity, 0), -1);
	SET @ErrorIds = NULLIF(@ErrorIds, N'');
	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Statements = NULLIF(@Statements, N'');
	SET @ExcludeSystemErrors = ISNULL(@ExcludeSystemErrors, 1);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metadata + Preferences
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreKey sysname = N'ALL_ERRORS';
	DECLARE @reportType sysname = N'HEATMAP';
	DECLARE @fullyQualifiedTargetTable sysname, @outcome int = 0;

	EXEC @outcome = dbo.[eventstore_get_target_by_key]
		@EventStoreKey = @eventStoreKey,
		@TargetTable = @fullyQualifiedTargetTable OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;
	
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
		--@TimeZone = @TimeZone,
		@SerializedOutput = @map OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(start_time)[1]', N'datetime') [start_time],
			[data].[row].value(N'(end_time)[1]', N'datetime') [end_time] 
		FROM 
			@map.nodes(N'//time') [data]([row])
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

	DECLARE @timeRangeString nvarchar(MAX) = N'Time-Range is ' + CONVERT(sysname, @Start, 121) + N' - ' + CONVERT(sysname, @End, 121) + N' (' + ISNULL(@TimeZone, N'UTC') + N').';

	IF (@timeZoneOffsetMinutes IS NOT NULL) AND (@timeZoneTransformType = N'ALL') BEGIN 
		SELECT 
			@Start = CAST((@Start AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime), 
			@End   = CAST((@End   AT TIME ZONE @TimeZone AT TIME ZONE 'UTC') AS datetime);

		SET @timeRangeString = @timeRangeString + N' Translated to ' + CONVERT(sysname, @Start, 121) + N' - ' + CONVERT(sysname, @End, 121) + N' (UTC).';
	END;

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
	IF @Mode = N'TIME_OF_DAY' BEGIN
	
		SET @sql = N'WITH correlated AS ( 
			SELECT 
				[t].[block_id], 
				[m].[error_number]				
			FROM 
				[#times] [t] 
				LEFT OUTER JOIN [#metrics] [m] ON CAST([m].[error_timestamp] AS time) < CAST([t].[end_time] AS time) AND CAST([m].[error_timestamp] AS time) > CAST([t].[start_time] AS time)
		), 
		aggregated AS ( 
			SELECT 
				[block_id], 
				COUNT(*) [errors], 
				COUNT(DISTINCT [error_number]) [distinct_errors]
			FROM 
				[correlated] 
			WHERE 
				[error_number] IS NOT NULL 
			GROUP BY 
				[block_id]
		)
		
		SELECT 
			FORMAT([t].[start_time], N''HH:mm'') + N'':00 - '' + FORMAT(DATEADD(MINUTE, -1, [t].[end_time]), N''HH:mm'') + N'':59''  [utc_time_of_day],{local_zone}
			ISNULL([a].[errors], 0) [total_errors], 
			ISNULL([a].[distinct_errors], 0) [distinct_errors]
		FROM 
			[#times] [t]
			LEFT OUTER JOIN [aggregated] [a] ON	[t].[block_id] = [a].[block_id]
		ORDER BY
			[t].[block_id]; ';

		IF UPPER(@timeZoneTransformType) <> N'NONE' BEGIN
			SET @sql = REPLACE(@sql, N'{local_zone}', @crlftab + N'FORMAT(CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime), N''HH:mm'') + N'':00 - '' + FORMAT(CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime), N''HH:mm'') + N'':59'' [' + REPLACE(REPLACE(LOWER(@TimeZone), N' ', N'_'), N'_standard_time', N'') + N'_time_of_day],');
		  END; 
		ELSE 
			SET @sql = REPLACE(@sql, N'{local_zone}', N'');

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
			AND (CAST([m].[error_timestamp] AS time) < CAST([t].[end_time] as time) AND CAST([m].[error_timestamp] AS time) > CAST([t].[start_time] as time))
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
			
		--EXEC dbo.[print_long_string] @sql;
		EXEC sys.sp_executesql 
			@sql, 
			N'@currentDayID int', 
			@currentDayID = @currentDayID;
	
		FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	SET @sql = N'SELECT 
	FORMAT([t].[start_time], N''HH:mm'') + N'':00 - '' + FORMAT(DATEADD(MINUTE, -1, [t].[end_time]), N''HH:mm'') + N'':59''  [utc_time_of_day],{local_zone}
	N'' '' [ ],
	ISNULL([Sunday], N''-'') [Sunday],  
	ISNULL([Monday], N''-'') [Monday],
	ISNULL([Tuesday], N''-'') [Tuesday],
	ISNULL([Wednesday], N''-'') [Wednesday],
	ISNULL([Thursday], N''-'') [Thursday],
	ISNULL([Friday], N''-'') [Friday],
	ISNULL([Saturday], N''-'') [Saturday]
FROM 
	[#times] [t]
ORDER BY 
	[block_id];';

	IF UPPER(@timeZoneTransformType) <> N'NONE' BEGIN
		SET @sql = REPLACE(@sql, N'{local_zone}', @crlftab + N'FORMAT(CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime), N''HH:mm'') + N'':00 - '' + FORMAT(CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime), N''HH:mm'') + N'':59'' [' + REPLACE(REPLACE(LOWER(@TimeZone), N' ', N'_'), N'_standard_time', N'') + N'_time_of_day],');
	  END; 
	ELSE 
		SET @sql = REPLACE(@sql, N'{local_zone}', N'');

	EXEC sys.[sp_executesql] 
		@sql;	

	RETURN 0;
GO