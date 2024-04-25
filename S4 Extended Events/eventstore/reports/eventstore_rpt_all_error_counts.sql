/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_rpt_all_error_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_rpt_all_error_counts];
GO

CREATE PROC dbo.[eventstore_rpt_all_error_counts]
	@Granularity				sysname			= N'HOUR', 
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@MinimumSeverity			int				= -1, 
	@ExcludedErrorIds			nvarchar(MAX)	= NULL, 
	@RequiredErrorIds			nvarchar(MAX)	= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @ExcludedErrorIds = NULLIF(@ExcludedErrorIds, N'');
	SET @RequiredErrorIds = NULLIF(@RequiredErrorIds, N'');
	SET @MinimumSeverity = ISNULL(@MinimumSeverity, -1);
	SET @MinimumSeverity = ISNULL(NULLIF(@MinimumSeverity, 0), -1);
	
	DECLARE @eventStoreKey sysname = N'ALL_ERRORS';
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @eventStoreKey); 	

	IF @RequiredErrorIds IS NOT NULL AND @ExcludedErrorIds IS NOT NULL BEGIN 
		RAISERROR(N'@ExcludedErrorIds and @RequiredErrorIds are mutually Exclusive - use one or the other (not both).', 16, 1);
		RETURN -10;
	END;

	IF @MinimumSeverity <> -1 BEGIN 
		IF @MinimumSeverity < 1 OR @MinimumSeverity > 25 BEGIN 
			RAISERROR(N'@MinimumSeverity may only be set to a value between 1 and 25.', 16, 1);
			RETURN -11;
		END;
	END;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
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

-- HACK: 
--		Need to figure this out - in terms of HOW it interacts with an explicitly specified @TimeZone... 
--	BUT, for now, I'm hacking this to keep basic functionality working/proceding - and will come back and re-evaluate this. 
--		where 'this' is: 
--			for WHATEVER reason, [timestamp] values for this XE session are all, 100%, in UTC time - not local-server-time. 
--			I REALLY don't get that. 

--SELECT @Start, @End;
	DECLARE @diff int = DATEDIFF(HOUR, GETDATE(), GETUTCDATE());
	SET @Start = DATEADD(HOUR, @diff, @Start);
	SET @End = DATEADD(HOUR, @diff, @End);

	--SELECT @Start, @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Metrics Extraction:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #metrics ( 
		[error_timestamp] datetime NOT NULL,  
		[error_id] int NOT NULL
	);
	CREATE NONCLUSTERED INDEX #metrics_error_id ON [#metrics] ([error_id]);
	
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @filters nvarchar(MAX) = N'';
	DECLARE @joins nvarchar(MAX) = N'';

	IF @MinimumSeverity <> -1 BEGIN 
		SET @filters = @filters + @crlftab + N'AND Severity >= ' + CAST(@MinimumSeverity AS sysname); 
	END;

	IF @RequiredErrorIds IS NOT NULL BEGIN 
		CREATE TABLE #requiredIDs (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[error_id] int NOT NULL 
		);

		INSERT INTO [#requiredIDs] ([error_id])
		SELECT [result] FROM [dbo].[split_string](@RequiredErrorIds, N',', 1);

		SET @joins = @crlftab + N'INNER JOIN [#requiredIDs] [x] ON [e].[error_number] = [x].[error_id]';
	END;

	IF @ExcludedErrorIds IS NOT NULL BEGIN 
		CREATE TABLE #excludedIDs (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[error_id] int NOT NULL 
		);

		INSERT INTO [#excludedIDs] ([error_id])
		SELECT [result] FROM [dbo].[split_string](@ExcludedErrorIds, N',', 1);

		SET @joins = @crlftab + N'LEFT OUTER JOIN [#excludedIDs] [x] ON [e].[error_number] = [x].[error_id]';
		SET @filters = @filters + @crlftab + N'AND [x].[error_id] IS NOT NULL';
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[e].[timestamp] [error_timestamp], 
	[e].[error_number] [error_id]
FROM 
	{SourceTable} [e]{joins}
WHERE 
	[e].[timestamp]>= @Start 
	AND [e].[timestamp] <= @End{filters};'

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);

	INSERT INTO [#metrics] (
		[error_timestamp],
		[error_id]
	)
	EXEC sys.sp_executesql 
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
			[m].[error_timestamp], 
			[m].[error_id]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#metrics] [m] ON [m].[error_timestamp] < [t].[end_time] AND [m].[error_timestamp] > [t].[start_time] -- anchors 'up' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will 'show up' in hour 13:00... 
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
		[t].[end_time],
		ISNULL([a].[errors], 0) [error_count],
		ISNULL([a].[distinct_errors], 0) [distinct_errors]
	FROM 
		[#times] [t] 
		LEFT OUTER JOIN [aggregated] [a] ON [t].[block_id] = [a].[block_id]
	ORDER BY 
		[t].[block_id];

	RETURN 0;
GO