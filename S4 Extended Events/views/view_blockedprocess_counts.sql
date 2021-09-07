/*

	vNEXT: 
		- Look at creating ~2x new columns in the final projection: 
			[blocking_transaction_ids]
			[blocking_report_ids] 
				both of which will be serialized XML as follows: 
					[blocking_transaction_ids]
						list of transact_ids...with total_blocking_time and self-blockeer or not. e.g., 
							<transaction_ids start-time="start-time-block" end-time="end-time-block"> 
								<blocker id="#######" total-spids-blocked="3" total_seconds_blocked="####" />
								<self-blocker id="####" total-seconds_blocked="####" />
							</transaction_ids>
					[blocking_report_ids] 
						will be similar, but contain just blocking tx ids... 
							<blocking-reports start-time="x" end-time="y" />
								<report id="###" process-count="xxxx" total_seconds="x" start-time="x" end-time="x" etc."" />
								<self-blocking-report or whatever />
							</blocking-reports>

				point is, i can put a bit of meta-data into these pigs to make it easier to spot what's up... 
					and, more importantly, identify which particular events I need to zero-in on for further review. 



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_blockedprocess_counts','P') IS NOT NULL
	DROP PROC dbo.[view_blockedprocess_counts];
GO

CREATE PROC dbo.[view_blockedprocess_counts]
	@TranslatedBlockedProcessesTable			sysname, 
	@Granularity								sysname			= N'HOUR',   -- { DAY | HOUR | MINUTE } WHERE MINUTE ends up being tackled in 5 minute increments (not 1 minute).
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL, 
	@ConvertTimesFromUtc						bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TranslatedBlockedProcessesTable = NULLIF(@TranslatedBlockedProcessesTable, N'');
	SET @ConvertTimesFromUtc = ISNULL(@ConvertTimesFromUtc, 1);

	IF UPPER(@Granularity) LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @TranslatedBlockedProcessesTable, 
		@ParameterNameForTarget = N'@TranslatedBlockedProcessesTable', 
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
	
	CREATE TABLE #blocked ( 
		blocking_id int IDENTITY(1,1) NOT NULL, 
		[type] sysname NOT NULL, 
		[start_time] datetime NOT NULL, 
		[end_time] datetime NOT NULL, 
		[blocked_processes_count] int NOT NULL, 
		[total_seconds_blocked] int NOT NULL, 
		[transaction_id] bigint NOT NULL 
	); 

	DECLARE @sql nvarchar(MAX) = N'	WITH blocking AS ( 
		SELECT 
			blocking_xactid [transaction_id], 
			COUNT(*) [blocked_processes_count],
			MIN([timestamp]) [start_time], 
			MAX([timestamp]) [end_time],
			MAX([seconds_blocked]) [seconds_blocked]
		FROM 
			{SourceTable} 
		WHERE 
			[blocked_xactid] IS NOT NULL AND -- temporary work-around until I figure these out... 
			[blocking_xactid] IS NOT NULL{TimePredicates} 
		GROUP BY 
			[blocking_xactid]
	) 

	SELECT 
		N''blocking-process'' [type],
		[start_time],
		[end_time],	
		[blocked_processes_count],
		[seconds_blocked], 
		transaction_id
	FROM 
		blocking 
	ORDER BY 
		[start_time]; ';
	
	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{TimePredicates}', @timePredicates);

	INSERT INTO [#blocked] (
		[type],
		[start_time],
		[end_time],
		[blocked_processes_count],
		[total_seconds_blocked],
		[transaction_id]
	)
	EXEC sys.sp_executesql 
		@sql;

	-- Account for self-blocking spids:
	SET @sql = N'WITH self_blockers AS ( 
		SELECT 
			blocked_xactid [transaction_id], 
			COUNT(*) [blocked_processes_count], 
			MIN([timestamp]) [start_time],
			MAX([timestamp]) [end_time],
			MAX([seconds_blocked]) [seconds_blocked]
		FROM 
			{SourceTable}  
		WHERE 
			[blocked_xactid] IS NOT NULL AND  -- ditto - temp work-around... 
			[blocking_xactid] IS NULL{TimePredicates} 
		GROUP BY 
			blocked_xactid
	) 
	
	SELECT 
		N''self-blocker'' [type],
		[start_time],
		[end_time],
		[blocked_processes_count],
		[seconds_blocked], 
		[transaction_id]
	FROM 
		[self_blockers]
	ORDER BY 
		[start_time]; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{TimePredicates}', @timePredicates);

	INSERT INTO [#blocked] (
		[type],
		[start_time],
		[end_time],
		[blocked_processes_count],
		[total_seconds_blocked],
		[transaction_id]
	)
	EXEC sys.sp_executesql 
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

	--IF @Granularity = 'DAY' BEGIN 
	--	ALTER TABLE [#times] ALTER COLUMN [time_block] date NOT NULL;
	--END;

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
			t.row_id,
			--t.[start] [time_period], 
			DATEADD(MINUTE, 0 - @timeOffset, t.[start]) [time_period], 
			--b.[start_time],
			--b.[end_time], 
			b.[transaction_id], 
			b.[type], 
			b.[blocked_processes_count], 
			b.[total_seconds_blocked]
		FROM 
			[times] t
			LEFT OUTER JOIN [#blocked] b ON b.[end_time] < t.[end] AND b.[end_time] > t.[start]
	), 
	aggregated AS ( 
		SELECT 
			[time_period], 
			COUNT([transaction_id]) [total_events], 
			ISNULL(SUM([total_seconds_blocked]), 0) [blocking_seconds],
			SUM(CASE WHEN [type] = N'blocking-process' THEN 1 ELSE 0 END) [blocking_events_count],
			SUM(CASE WHEN [type] = N'blocking-process' THEN [blocked_processes_count] ELSE 0 END) [blocked_spids],
			SUM(CASE WHEN [type] = N'blocking-process' THEN [total_seconds_blocked] ELSE 0 END) [blocked_seconds],

			SUM(CASE WHEN [type] = N'self-blocker' THEN 1 ELSE 0 END) [self_blocking_events_count], 
			SUM(CASE WHEN [type] = N'self-blocker' THEN [blocked_processes_count] ELSE 0 END) [self_blocked_spids],
			SUM(CASE WHEN [type] = N'self-blocker' THEN [total_seconds_blocked] ELSE 0 END) [self_blocked_seconds]

		FROM 
			[coordinated] 
		GROUP BY 
			[time_period]
	)

	SELECT 
		CASE WHEN UPPER(@Granularity) = N'DAY' THEN CAST([time_period] AS date) ELSE [time_period] END [time_period],
		[total_events],
		[blocking_seconds] [total_seconds],
		N'' [ ],
		[blocking_events_count],
		[blocked_spids],
		[blocked_seconds],
		N'' [ -],
		[self_blocking_events_count],
		[self_blocked_spids],
		[self_blocked_seconds]
	FROM  
		[aggregated] 
	ORDER BY 
		[time_period];

	RETURN 0;
GO