/*

	vNEXT:
		- figure out how to deal with @Statements 'splitting' as ... commas (,) will be a pain... 
			See: https://overachieverllc.atlassian.net/browse/EVS-22?focusedCommentId=10753 

	.DOCUMENTATION
		.PARAMETERS
			.NAME: @Statements
			.TYPE: nvarchar(MAX) NULL 
			.DEFAULT: NULL
			.DESCRIPTION: 

			:::WARNING
			#### :zap: NOTE: 
			Multiple statement patterns (i.e., using % for LIKE operations) can be specified via the `@Statements` - which SPLITs statements via the `,` character. 
			Translation: if any of the LIKE statements you 'embed' in the `@Statements` parameter have 'natural' commas in them, replace them with the `_` (single-char) wild
			card character. 
		TODO: do a better job of documenting the above. See https://overachieverllc.atlassian.net/browse/EVS-22?focusedCommentId=10754 for more details.


			.NAME: @TimeZone 
			.TYPE: sysname NULL 
			.DEFAULT: NULL
			.DESCRIPTION: 
			When specified - either explicitly or as a preference (stored in eventstore_report_preference_settings) will do two things:  
			- Translates any explicitly specified @Start and/or @End values to the @TimeZone specified (vs being in UTC time). 
			- Injects an additional column into the output - which shows translated times in the @TimeZone specified - along-side the UTC dates.
			
			**NOTE:** If @Start and @End are both provided, but @TimeZone is explicitly set to NULL - then only a UTC date/time column will be provided in the output;


		.EXAMPLES 
			.EXAMPLE: Basic Interaction
			.DESCRIPTION: 
			This'll ... just use defaults if any are loaded and ... if none are specified, it'll use hard-coded defaults for time-ranges: 

			```sql

			EXEC [admindb].dbo.[eventstore_report_all_errors_counts];

			```
			More text down here. 

			.EXAMPLE: Explicitly Specifying `@Start` and `@End` ranges: 

			```sql

			EXEC [admindb].dbo.[eventstore_report_all_errors_counts]
				@Start = '2024-06-09 23:19:42.280',
				@End = '2024-06-11 23:19:42.280';

			```
			etc... 

			.EXAMPLE: Some other Example... 
			blah blah blah 

			```sql

			EXEC [admindb].dbo.[eventstore_report_all_errors_counts]
				@UseDefaults = 0,
				@TimeZone = N'{SERVER_LOCAL}',
				@Start = '2024-06-09 23:19:42.280',
				@End = '2024-06-11 23:19:42.280',
				@Applications = N'-%agent%';
			
			```

	vNEXT:
					

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_all_errors_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_all_errors_counts];
GO

CREATE PROC dbo.[eventstore_report_all_errors_counts]
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
	DECLARE @reportType sysname = N'COUNTS';
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

--EXEC dbo.[print_long_string] @sql;

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
			[m].[error_timestamp], 
			[m].[error_number] [error_id]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#metrics] [m] ON [m].[error_timestamp] < [t].[end_time] AND [m].[error_timestamp] > [t].[start_time] -- anchors ''up'' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will ''show up'' in hour 13:00... 
	), 
	aggregated AS ( 
		SELECT 
			[block_id], 
			COUNT(*) [errors], 
			COUNT(DISTINCT [error_id]) [distinct_errors]
		FROM 
			[correlated] 
		WHERE 
			[error_timestamp] IS NOT NULL 
		GROUP BY 
			[block_id]
	)

	SELECT 
		[t].[end_time] [utc_end_time],{local_zone}
		ISNULL([a].[errors], 0) [error_count],
		ISNULL([a].[distinct_errors], 0) [distinct_errors]
	FROM 
		[#times] [t] 
		LEFT OUTER JOIN [aggregated] [a] ON [t].[block_id] = [a].[block_id]
	ORDER BY 
		[t].[block_id];';

	IF UPPER(@timeZoneTransformType) <> N'NONE' BEGIN 
		SET @sql = REPLACE(@sql, N'{local_zone}', @crlftab + N'CAST(([t].[end_time] AT TIME ZONE ''UTC'' AT TIME ZONE ''' + @TimeZone + N''') as datetime) [' + REPLACE(REPLACE(LOWER(@TimeZone), N' ', N'_'), N'_time', N'') + N'_end_time],');
	  END;
	ELSE 
		SET @sql = REPLACE(@sql, N'{local_zone}', N'');

	EXEC sys.[sp_executesql] 
		@sql;

	RETURN 0;
GO