/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_largegrant_counts','P') IS NOT NULL
	DROP PROC dbo.[view_largegrant_counts];
GO

CREATE PROC dbo.[view_largegrant_counts]
	@TranslatedLargeGrantsTable				sysname, 
	@Granularity							sysname			= N'HOUR',		-- { DAY | HOUR | MINUTE } 
	@OptionalStartTime						datetime		= NULL, 
	@OptionalEndTime						datetime		= NULL, 
	@ConvertTimesFromUtc					bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TranslatedLargeGrantsTable = NULLIF(@TranslatedLargeGrantsTable, N'');
	SET @ConvertTimesFromUtc = ISNULL(@ConvertTimesFromUtc, 1);

	IF UPPER(@Granularity) LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @TranslatedLargeGrantsTable, 
		@ParameterNameForTarget = N'@TranslatedLargeGrantsTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	DECLARE @timeOffset int = 0;
	IF @ConvertTimesFromUtc = 1 BEGIN 
		SET @timeOffset = (SELECT DATEDIFF(MINUTE, GETDATE(), GETUTCDATE()));
	END;

	DECLARE @timePredicates nvarchar(MAX) = N'';

	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @timePredicates = N' AND [timestamp] >= ''' + CONVERT(sysname, @OptionalStartTime, 121) + N'''';
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		SET @timePredicates = @timePredicates + N' AND [timestamp] <= ''' + CONVERT(sysname, @OptionalEndTime, 121) + N'''';
	END;		

	CREATE TABLE #simplified (
		report_id int NOT NULL, 
		memory_grant_gb decimal(12,2) NOT NULL, 
		statement_type sysname NOT NULL, 
		query_hash_signed bigint NOT NULL, 
		[timestamp] datetime NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	report_id, 
	memory_grant_gb, 
	statement_type, 
	query_hash_signed, 
	[timestamp]
FROM 
	{SourceTable}{WHERE}; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	
	IF @timePredicates <> N'' BEGIN 
		SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + N'WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9)  + N'report_id IS NOT NULL' + @timePredicates);
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{WHERE}', N'');
	END;

	INSERT INTO [#simplified] (
		[report_id],
		[memory_grant_gb],
		[statement_type],
		[query_hash_signed],
		[timestamp]
	)
	EXEC sp_executesql 
		@sql;
	

	------------------------------------------------------------------------------------------------------
	-- Time-Blocking Logic: 
	DECLARE @traceStart datetime, @traceEnd datetime; 

	SET @sql = N'SELECT 
		@traceStart = MIN([timestamp]), 
		@traceEnd = MAX([timestamp])
	FROM 
		{SourceTable}; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);

	EXEC sys.[sp_executesql]
		@sql, 
		N'@traceStart datetime OUTPUT, @traceEnd datetime OUTPUT', 
		@traceStart = @traceStart OUTPUT, 
		@traceEnd = @traceEnd OUTPUT;
		
	DECLARE @minutes int = 0; 

	CREATE TABLE #times (
		row_id int IDENTITY(1,1) NOT NULL, 
		time_block datetime NOT NULL
	);

	IF UPPER(@Granularity) LIKE N'%INUTE%' BEGIN -- 5 minute blocks... 
		SET @minutes = 5;
	END; 

	IF UPPER(@Granularity) = N'HOUR' BEGIN 
		SET @minutes = 60;
	END;

	IF UPPER(@Granularity) = N'DAY' BEGIN 
		SET @minutes = 60 * 24;
	END;

	IF @minutes = 0 BEGIN 
		RAISERROR('Invalid @Granularity value specified. Allowed values are { DAY | HOUR | MINUTE } - where MINUTE = 5 minute increments.', 16, 1);
		return -20;
	END;

	IF @OptionalStartTime IS NOT NULL BEGIN 
		IF @OptionalStartTime > @traceStart 
			SET @traceStart = @OptionalStartTime;
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF @OptionalEndTime < @traceEnd
			SET @traceEnd = @OptionalEndTime
	END;

	DECLARE @timesStart datetime, @timesEnd datetime;
	SELECT 
		@timesStart = DATEADD(MINUTE, DATEDIFF(MINUTE, 0,@traceStart) / @minutes * @minutes, 0), 
		@timesEnd = DATEADD(MINUTE, @minutes, DATEADD(MINUTE, DATEDIFF(MINUTE, 0,@traceEnd) / @minutes * @minutes, 0));

	WITH times AS ( 
		SELECT @timesStart [time_block] 

		UNION ALL 

		SELECT DATEADD(MINUTE, @minutes, [time_block]) [time_block]
		FROM [times]
		WHERE [time_block] < @timesEnd
	) 

	INSERT INTO [#times] (
		[time_block]
	)
	SELECT [time_block] 
	FROM times
	OPTION (MAXRECURSION 0);

	WITH times AS ( 
		SELECT 
			row_id,
			t.[time_block] [end],
			LAG(t.[time_block], 1, DATEADD(MINUTE, (0 - @minutes), @timesStart)) OVER (ORDER BY row_id) [start]
		FROM 
			[#times] t
	), 
	coordinated AS ( 
		SELECT 
			t.[row_id], 
			t.[start] [time_period], 
			s.[report_id], 
			s.[memory_grant_gb], 
			s.[statement_type], 
			s.[query_hash_signed]
		FROM 
			times t 
			LEFT OUTER JOIN [#simplified] s ON s.[timestamp] < t.[end] AND s.[timestamp] > t.[start] 
		WHERE 
			s.[report_id] IS NOT NULL
	),
	aggregated AS ( 
		SELECT 
			[time_period],
			COUNT([report_id]) [total_events], 
			CAST(SUM([memory_grant_gb]) as decimal(18,2)) [total_gb_used], 
			CAST(AVG([memory_grant_gb]) as decimal(18,2)) [avg_gb_used], 
			CAST(MAX([memory_grant_gb]) as decimal(18,2)) [max_gb_used], 
			COUNT(DISTINCT [query_hash_signed]) [distinct_queries]
		FROM 
			[coordinated]
		GROUP BY 
			[time_period]
	)

	SELECT 
		[time_period],
		[total_events],
		[total_gb_used],
		[avg_gb_used],
		[max_gb_used],
		[distinct_queries] 
	FROM 
		[aggregated]
	ORDER BY 
		[time_period];

	RETURN 0;
GO