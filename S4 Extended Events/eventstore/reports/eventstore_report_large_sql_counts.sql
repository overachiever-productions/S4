/*



	SAMPLE EXECUTION (i.e., showing that we want to filter out some statements and ... rows < 300, cpu < 800ms )

				EXEC [admindb].dbo.[eventstore_rpt_large_sql_counts]
					@ExcludeSqlCmd = 0, 
					@ExcludeSqlAgentJobs = 0, 
					@ExcludedStatements = N'%eventstore_etl_processor%, %backup%',
					@MinRowsModifiedCount = 300, 
					@MinCpuMilliseconds = 800;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_large_sql_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_large_sql_counts];
GO

CREATE PROC dbo.[eventstore_report_large_sql_counts]
	@Granularity				sysname			= N'HOUR', 
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

	SET @ExcludeSqlAgentJobs = ISNULL(@ExcludeSqlAgentJobs, 1);
	SET @ExcludeSqlCmd = ISNULL(@ExcludeSqlCmd, 1);
	SET @ExcludedStatements = NULLIF(@ExcludedStatements, N'');

	DECLARE @eventStoreKey sysname = N'LARGE_SQL';
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @eventStoreKey); 

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
	DECLARE @times xml;
	EXEC @outcome = dbo.[eventstore_timebounded_counts]
		@Granularity = @Granularity,
		@Start = @Start,
		@End = @End,
		@TimeZone = @TimeZone,
		@SerializedOutput = @times OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(start_time)[1]', N'datetime') [start_time],
			[data].[row].value(N'(end_time)[1]', N'datetime') [end_time], 
			[data].[row].value(N'(time_zone)[1]', N'sysname') [time_zone]
		FROM 
			@times.nodes(N'//time') [data]([row])
	) 

	SELECT 
		[block_id],
		[start_time],
		[end_time],
		[time_zone]
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

	CREATE TABLE #metrics ( 
		[execution_end_time] datetime NOT NULL, 
		[cpu_milliseconds] bigint NOT NULL,
		[duration_milliseconds] bigint NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL, 
		[row_count] bigint NOT NULL
	); 

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

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[s].[timestamp] [execution_end_time], 
	[s].[cpu_ms] [cpu_milliseconds], 
	[s].[duration_ms] [duration_milliseconds], 
	[s].[physical_reads] [reads], 
	[s].[writes], 
	[s].[row_count]
FROM 
	{SourceTable} [s]{excludedStatementsJoin}
WHERE 
	[s].[timestamp]>= @Start 
	AND [s].[timestamp] <= @End{exclusions};'; 

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{excludedStatementsJoin}', @excludedStatementsJoin);
	SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

	--EXEC dbo.[print_long_string] @sql;	

	INSERT INTO [#metrics] (
		[execution_end_time],
		[cpu_milliseconds],
		[duration_milliseconds],
		[reads],
		[writes], 
		[row_count]
	)
	EXEC sys.[sp_executesql]
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH times AS ( 
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
			LEFT OUTER JOIN [#metrics] [m] ON [m].[execution_end_time] < [t].[end_time] AND [m].[execution_end_time] > [t].[start_time] -- anchors 'up' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will 'show up' in hour 13:00... 
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
			[execution_end_time] IS NOT NULL  -- without this, then 'empty' time slots (block_ids) end up with COUNT(*) = 1 ... 
		GROUP BY 
			[block_id]
	)

	SELECT 
		[t].[end_time],
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
		[t].[block_id];

	RETURN 0;
GO