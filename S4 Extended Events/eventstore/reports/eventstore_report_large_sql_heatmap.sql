/*

	PICKUP/NEXT: 
		- Better formatting of start/end times (compare with what I'm doing in view_largegrant_heatmap). 
		- Weaponize for blocked-proceses, and deadlocks. (shouldn't be tooo hard). 
		-- BEFORE doing anything other than large_sql, deadlocks, blocked-proceses: 
			figure out how to tackle UTC offsets. 
			And, at a bare minimum: 
				throw an error until this is actually handled. 
				cuz, right now, it looks like this 'works' (it's ignored) - meaning
				... peoeple could call it and not know that offsets are a lie (same as if not specified). 
			otherwise, ... need to figrue out exactly how to handle those offsets.
				And, I THINK I handle them in the #metrics table. that'd make the most sense. I think. 
				but, i'm going to have to test out a simpllllle example to make sure I've got the logic right. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_large_sql_heatmap]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_large_sql_heatmap];
GO

CREATE PROC dbo.[eventstore_report_large_sql_heatmap]
	@Mode										sysname			= N'TIME_OF_DAY',		-- { TIME_OF_DAY | TIME_OF_WEEK } 
	@Granularity								sysname			= N'HOUR',			-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL,
	@ExcludeSqlAgentJobs		bit				= 1, 
	@ExcludeSqlCmd				bit				= 1,
	@ExcludedStatements			nvarchar(MAX)	= NULL,
	@MinCpuMilliseconds			int				= -1, 
	@MinDurationMilliseconds	int				= -1, 
	@MinRowsModifiedCount		int				= -1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Mode = UPPER(ISNULL(NULLIF(@Mode, N''), N'TIME_OF_DAY'));
	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'HOUR'));

	DECLARE @eventStoreKey sysname = N'LARGE_SQL';
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @eventStoreKey); 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time Bounding: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @Start IS NULL BEGIN 
		SET @Start = DATEADD(DAY, - 32, GETUTCDATE());
		SET @End = ISNULL(@End, GETUTCDATE());
	END;
	
	IF @End < @Start BEGIN 
		RAISERROR(N'@End may NOT be less-than (earlier than) @Start.', 16, 1);
		RETURN -2;
	END;

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @eventStoreTarget, 
		@ParameterNameForTarget = N'@eventStoreTarget', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	SET @outcome = 0;
	DECLARE @map xml;

	EXEC @outcome = dbo.[eventstore_heatmap_frame]
		@Granularity = @Granularity,
		@TimeZone = @TimeZone,
		@SerializedOutput = @map OUTPUT;
	
	IF @outcome <> 0 
		RETURN @outcome;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(utc_start)[1]', N'time') [utc_start],
			[data].[row].value(N'(utc_end)[1]', N'time') [utc_end]			
		FROM 
			@map.nodes(N'//time') [data]([row])
	) 

	SELECT 
		[block_id],
		[utc_start],
		[utc_end] 
	INTO 
		#times
	FROM 
		[shredded] 
	ORDER BY 
		[shredded].[block_id];
		

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Configure Exclusions/Filters:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @exclusions nvarchar(MAX) = N'';
	IF @ExcludeSqlAgentJobs = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [s].[application_name] NOT LIKE N''SQLAgent%''';
	END;

	IF @ExcludeSqlCmd = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [s].[application_name] <> N''SQLCMD''';
	END;

	IF @MinCpuMilliseconds > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [s].[cpu_ms] > ' + CAST(@MinCpuMilliseconds AS sysname);
	END;

	IF @MinDurationMilliseconds > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [s].[duration_ms] > ' + CAST(@MinDurationMilliseconds AS sysname);
	END; 

	IF @MinRowsModifiedCount > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [s].[row_count] > ' + CAST(@MinRowsModifiedCount AS sysname);
	END;

	DECLARE @excludedStatementsJoin nvarchar(MAX) = N'';
	IF @ExcludedStatements IS NOT NULL BEGIN 
		CREATE TABLE #excludedStatements (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[statement] nvarchar(MAX) NOT NULL
		);

		INSERT INTO [#excludedStatements] ([statement])
		SELECT [result] FROM [dbo].[split_string](@ExcludedStatements, N',', 1);
		
		SET @excludedStatementsJoin = @crlftab + N'LEFT OUTER JOIN #excludedStatements [x] ON [s].[statement] LIKE [x].[statement]';
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[statement] IS NULL';

	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate Data:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #metrics ( 
		[execution_end_time] datetime NOT NULL, 
		[cpu_milliseconds] bigint NOT NULL, 
		[duration_milliseconds] bigint NOT NULL 
	);  

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[s].[timestamp], 
	[s].[cpu_ms], 
	[s].[duration_ms]
FROM 
	{SourceTable} [s]{excludedStatementsJoin}
WHERE 
	[s].[timestamp]>= @Start 
	AND [s].[timestamp] <= @End{exclusions};'

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{excludedStatementsJoin}', @excludedStatementsJoin);
	SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

	INSERT INTO [#metrics] (
		[execution_end_time],
		-- IF perf for TIME_OF_WEEK ever becomes a problem then: a) add a day_of_week column here. b) populate + INDEX if/when (but only if/when) @mode=TIME_OF_WEEK
		[cpu_milliseconds],
		[duration_milliseconds]
	)
	EXEC sys.[sp_executesql]
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @Mode = N'TIME_OF_DAY' BEGIN 
		
		WITH correlated AS ( 
			SELECT 
				[t].[block_id], 
				[t].[utc_start], 
				[t].[utc_end],
				[m].[execution_end_time], 
				[m].[cpu_milliseconds], 
				[m].[duration_milliseconds]
			FROM 
				[#times] [t]
				LEFT OUTER JOIN [#metrics] [m] ON CAST([m].[execution_end_time] AS time) < [t].[utc_end] AND CAST([m].[execution_end_time] AS time) > [t].[utc_start]
		), 
		aggregated AS ( 
			SELECT 
				[block_id], 
				COUNT(*) [events], 
				SUM([cpu_milliseconds]) [total_cpu], 
				SUM([duration_milliseconds]) [total_duration]
			FROM 
				[correlated] 
			WHERE 
				[correlated].[execution_end_time] IS NOT NULL 
			GROUP BY 
				[block_id]
		)
		
		SELECT 
			[t].[utc_start],
			[t].[utc_end],
			ISNULL([a].[events], 0) [total_events],
			ISNULL([a].[total_cpu], 0) [total_cpu_ms],
			ISNULL([a].[total_duration], 0) [total_duration_ms]
		FROM 
			[#times] [t]
			LEFT OUTER JOIN [aggregated] [a] ON [t].[block_id] = [a].[block_id]
		ORDER BY 
			[t].[block_id];

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
		[m].[cpu_milliseconds], 
		[m].[duration_milliseconds]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [#metrics] [m] ON DATEPART(WEEKDAY, [m].[execution_end_time]) = @currentDayID
			AND (CAST([m].[execution_end_time] AS time) < [t].[utc_end] AND CAST([m].[execution_end_time] AS time) > [t].[utc_start])
	WHERE 
		[m].[execution_end_time] IS NOT NULL
), 
currentDayMetrics AS (
	SELECT 
		[block_id],
		CAST(COUNT(*) as sysname) + N'' ('' + FORMAT(SUM([cpu_milliseconds]), ''N0'') + N'' - '' + FORMAT(SUM([duration_milliseconds]), ''N0'') + N'')'' [data]
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
			
		EXEC dbo.[print_long_string] @sql;
		EXEC sys.sp_executesql 
			@sql, 
			N'@currentDayID int', 
			@currentDayID = @currentDayID;
	
		FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	PRINT 'Cell legend: [# (C - D)] - Where # is [total_events], C is [total_cpu_ms], and D is [total_duration_ms].';

	SELECT 
		[utc_start],
		[utc_end], 
		N' ' [ ],
		ISNULL([Sunday], N'-') [Sunday],  
		ISNULL([Monday], N'-') [Monday],
		ISNULL([Tuesday], N'-') [Tuesday],
		ISNULL([Wednesday], N'-') [Wednesday],
		ISNULL([Thursday], N'-') [Thursday],
		ISNULL([Friday], N'-') [Friday],
		ISNULL([Saturday], N'-') [Saturday]
	FROM 
		[#times]
	ORDER BY 
		[block_id];
	

