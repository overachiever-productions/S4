/*
	vNEXT: (this was, originally, in the non-eventstore version of the sproc):
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
	Yeah... nah. 
		I mean, i think there's a place for the logic above - but not in this report. 

	TODO: 
		- time-zone 'stuff' doesn't work before SQL Server 2016... so... just build a new version... 
		- figure out how to handle time-bounding. 
			Specifically: 
				- If I don't specify a time-boundary, then if I'm at 'HOUR' granularity, I get 2 hours when only 1 hour (in the history at the time) had blocked-process reports. 
					i.e., the problem is i'm geting 2 hours where there was only 1 hour with blocking. 
					likewise, if I switch to 'MINUTE' as granularity, there was a 5 minute period where there was blocking... but I get 7x 5-minute periods reported. 
				- What should this do if/when someone specifies a time-range where there was no locking/blocking? 
					pretty sure it'll just spit out 'blanks' for that time period - which is fine/perfect. 
						MOSTLY. 
							If I just specify a START it doesn't run until 'now' (which sort of makes sense... 
							If I specify a start AND end, it covers the time between those. 

				- WHAT should this do if someone doesn't specify a start/end-period? 
					i can't just show every bit of locking/blocking that's ever happened. 
						I should, i guess, default to some 'time spans' based on granularity. 
							e.g., if someone just runs this with 'HOUR', then show the last 24 or 48 hours? 
							if someone runs this with 'DAY', show the last 14 days? 
							and if someone runs this with 'MINUTE' show the last 120 minutes? 
					In other words, "OptionalStart/End" become a little less 'optional' when this thing is going to be running all the time, right? 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_rpt_blocked_processes_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_rpt_blocked_processes_counts];
GO

CREATE PROC dbo.[eventstore_rpt_blocked_processes_counts]
	@Granularity				sysname			= N'HOUR', 
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');

-- TODO: pull this from eventstore meta-data ... and throw if there isn't a match... 
	DECLARE @eventStoreTarget sysname = N'admindb.dbo.eventstore_blocked_processes';

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

	IF UPPER(@Granularity) LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding Predicates and Translations:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
		SET @TimeZone = dbo.[get_local_timezone]();

	DECLARE @offsetMinutes int = 0;
	IF @TimeZone IS NOT NULL
		SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time Bounding (Blocks) - and Start/End Defaults.
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @minutes int = 0;
	IF UPPER(@Granularity) LIKE N'%INUTE%' BEGIN -- 5 minute blocks... 
		SET @minutes = 5;
		SET @Start = ISNULL(@Start, DATEADD(HOUR, -2, GETDATE()));
		SET @End = ISNULL(@End, GETDATE());
	END; 

	IF UPPER(@Granularity) = N'HOUR' BEGIN 
		SET @minutes = 60;
		SET @Start = ISNULL(@Start, DATEADD(HOUR, -24, GETDATE()));
		SET @End = ISNULL(@End, GETDATE());
	END;

	IF UPPER(@Granularity) = N'DAY' BEGIN 
		SET @minutes = 60 * 24;
		SET @Start = ISNULL(@Start, DATEADD(DAY, -8, GETDATE()));
		SET @End = ISNULL(@End, GETDATE());
	END;	
	
	DECLARE @boundingTimes xml; 
	EXEC dbo.[generate_bounding_times] 
		@Start = @Start, 
		@End = @End	, 
		@Minutes = @minutes, 
		@SerializedOutput = @boundingTimes OUTPUT;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(time_block)[1]', N'datetime') [time_block]
		FROM 
			@boundingTimes.nodes(N'//time') [data]([row])
	) 

	SELECT 
		[block_id],
		[time_block] 
	INTO 
		#times
	FROM 
		shredded 
	ORDER BY 
		[block_id];

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Normal Blocking:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	CREATE TABLE #blockers (
		[transaction_id] bigint NOT NULL, 
		[blocked_id] int NOT NULL,
		[event_time] datetime NOT NULL, 
		[seconds_blocked] decimal(24,2) NOT NULL 
	);

	DECLARE @sql nvarchar(MAX) = N'	WITH core AS ( 
		SELECT 
			blocking_xactid [transaction_id], 
			[blocked_id],
			[blocked_wait_time],
			[timestamp] [event_time], 
			[seconds_blocked]

		FROM 
			{SourceTable} 
		WHERE 
			[blocked_xactid] IS NOT NULL  -- don''t include ''phantom'' blocking
			AND [blocking_xactid] IS NOT NULL 
			AND [timestamp] >= @Start
			AND [timestamp] <= @End	
	)

	SELECT 
		[transaction_id], 
		[blocked_id],
		[event_time], 
		[seconds_blocked]
	FROM 
		core; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);

	INSERT INTO [#blockers] (
		[transaction_id],
		[blocked_id],
		[event_time],
		[seconds_blocked]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Blocking Report Granularity:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- TODO: there's a happy-path logic bug here. Assume that blocked process threhold IS at 2 seconds. 
	--		if we get a COUPLE of operations that block for say, 6+ seconds each time there's a problem, fine - we'll get a MODE of 2 seconds between each blocking process and be FINE. 
	--		but. say that something blocks for 2.2 seconds ... every 90 seconds. At that point, the MODE will be ... 90 seconds (cuz there'll be, say, 4x of those back to back, with a cadence of 90 seconds between each problem)... 
	--		
	--		I can think of 2x ways to work around this: 
	--		a) as part of either eventstore_init_blockedprocesses - or the sproc that etl's blocked_processes every N seconds (by means of SQL Server Agent Job)
	--				capture blocked_processes_threshold and dump it into a tracking table IF the value has changed since the last time it was captured i.e., it'd be a 2 if it never changes, but might go from 2 to 4 or whatever in a case where an org changes this periodically.. 
	--				then, just look for what the value was for the @Start/@End in question and ... be done with it. 
	--		b) use .. blocked_seconds - previous.blocked_seconds for the cadence instead of event_time - previous.event_time. 
	--			and... yeah... this'd be a better option than mere event_time.
	DECLARE @blockedProcessThresholdCadenceSeconds int;

	WITH differenced AS (
		SELECT 
			[event_time], 
			DATEDIFF(SECOND, LAG(event_time, 1, NULL) OVER (ORDER BY [event_time]), [event_time]) [interval_seconds]
		FROM 
			[#blockers]
	), 
	ranked AS ( 
		SELECT 
			[interval_seconds], 
			DENSE_RANK() OVER (ORDER BY COUNT(*) DESC) [rank]
		FROM 
			[differenced]
		WHERE 
			[interval_seconds] IS NOT NULL 
			AND [interval_seconds] <> 0
		GROUP BY 
			[interval_seconds]
	) 

	SELECT 
		@blockedProcessThresholdCadenceSeconds = [interval_seconds]
	FROM 
		[ranked]
	WHERE 
		[rank] = 1;

	--SELECT @blockedProcessThresholdCadenceSeconds;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Self-Blocking:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	CREATE TABLE #self_blockers (
		[transaction_id] bigint NULL, 
		[blocked_id] int NOT NULL,
		[event_time] datetime NOT NULL, 
		[seconds_blocked] decimal(24,2) NOT NULL 
	);

	SET @sql = N'	WITH core AS ( 
		SELECT 
			blocking_xactid [transaction_id], 
			[blocked_id],
			[blocked_wait_time],
			[timestamp] [event_time], 
			[seconds_blocked]

		FROM 
			{SourceTable} 
		WHERE 
			[blocked_xactid] IS NOT NULL -- ignore ''phantom'' blocking 
			AND [blocking_xactid] IS NULL 
			AND [timestamp] >= @Start
			AND [timestamp] <= @End	
	)

	SELECT 
		[transaction_id], 
		[blocked_id],
		[event_time], 
		[seconds_blocked]
	FROM 
		core; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);

	INSERT INTO [#self_blockers] (
		[transaction_id],
		[blocked_id],
		[event_time],
		[seconds_blocked]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Phantom Blocking:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- TODO: add these in ... 
	-- they'd be ... same as blocking/self-blocking - but WHERE [blocked_xactid] IS NULL ... 
	

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate Self-Blocking by Time-Block:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	WITH times AS ( 
		SELECT 
			[t].[block_id], 
			LAG([t].[time_block], 1, DATEADD(MINUTE, (0 - @minutes), DATEADD(MINUTE, @offsetMinutes, @Start))) OVER (ORDER BY [t].[block_id]) [start_time],
			[t].[time_block] [event_time]
		FROM 
			[#times] [t]

	),
	coordinated AS (
		SELECT 
			[t].[block_id], 
			[t].[event_time] [t_end_time], 
			[b].[transaction_id], 
			[b].[blocked_id],
			[b].[event_time], 
			[b].[seconds_blocked] [running_seconds], 
			CASE 
				WHEN [b].[seconds_blocked] IS NULL THEN 0 
				WHEN [b].[seconds_blocked] > @blockedProcessThresholdCadenceSeconds AND [b].[seconds_blocked] < (2 * @blockedProcessThresholdCadenceSeconds) THEN [b].[seconds_blocked] 
				ELSE @blockedProcessThresholdCadenceSeconds 
			END [accrued_seconds]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#self_blockers] [b] ON [b].[event_time] < [t].[event_time] AND b.[event_time] > [t].[start_time] -- anchors 'up' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will 'show up' in hour 13:00... 
	), 
	maxed AS ( 
		SELECT 
			[block_id], 
			[transaction_id], 
			COUNT([blocked_id]) [total_events],  
			COUNT(DISTINCT [blocked_id]) [total_blocked_spids],
			MAX([running_seconds]) [running_seconds_blocked], 
			SUM([accrued_seconds]) [accrued_seconds_blocked]
		FROM 
			[coordinated]
		GROUP BY 
			[block_id], [transaction_id]
	), 
	summed AS ( 
		SELECT 
			[block_id], 
			SUM([maxed].[total_blocked_spids]) [total_blocked_spids],
			SUM([total_events]) [total_events], 
			SUM([running_seconds_blocked]) [running_seconds_blocked],
			SUM([accrued_seconds_blocked]) [accrued_seconds_blocked]
		FROM 
			maxed 
		GROUP BY 
			[block_id]
	)

	SELECT 
		[t].[block_id],
		[t].[time_block] [end_time], 
		[s].[total_events] [blocking_events],
		[s].[total_blocked_spids] [blocked_spids],
		ISNULL([s].[accrued_seconds_blocked], 0) [blocking_seconds],
		ISNULL([s].[running_seconds_blocked], 0) [running_seconds] 
	INTO 
		#summedSelfBlockers
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [summed] [s] ON [t].[block_id] = [s].[block_id]
	ORDER BY 
		[t].[block_id];

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate by Time-Block + Project:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	WITH times AS ( 
		SELECT 
			[t].[block_id], 
			LAG([t].[time_block], 1, DATEADD(MINUTE, (0 - @minutes), DATEADD(MINUTE, @offsetMinutes, @Start))) OVER (ORDER BY [t].[block_id]) [start_time],
			[t].[time_block] [event_time]
		FROM 
			[#times] [t]

	),
	coordinated AS (
		SELECT 
			[t].[block_id], 
			[t].[event_time] [t_end_time], 
			[b].[transaction_id], 
			[b].[blocked_id],
			[b].[event_time], 
			[b].[seconds_blocked] [running_seconds], 
			CASE 
				WHEN [b].[seconds_blocked] IS NULL THEN 0 
				WHEN [b].[seconds_blocked] > @blockedProcessThresholdCadenceSeconds AND [b].[seconds_blocked] < (2 * @blockedProcessThresholdCadenceSeconds) THEN [b].[seconds_blocked] 
				ELSE @blockedProcessThresholdCadenceSeconds 
			END [accrued_seconds]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#blockers] [b] ON [b].[event_time] < [t].[event_time] AND b.[event_time] > [t].[start_time] -- anchors 'up' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will 'show up' in hour 13:00... 
	), 
	maxed AS ( 
		SELECT 
			[block_id], 
			[transaction_id], 
			COUNT([blocked_id]) [total_events],
			COUNT(DISTINCT [blocked_id]) [total_blocked_spids],
			MAX([running_seconds]) [running_seconds_blocked], 
			SUM([accrued_seconds]) [accrued_seconds_blocked]
		FROM 
			[coordinated]
		GROUP BY 
			[block_id], [transaction_id]
	), 
	summed AS ( 
		SELECT 
			[block_id], 
			SUM([maxed].[total_blocked_spids]) [total_blocked_spids],
			SUM([total_events]) [total_events], 
			SUM([running_seconds_blocked]) [running_seconds_blocked],
			SUM([accrued_seconds_blocked]) [accrued_seconds_blocked]
		FROM 
			maxed 
		GROUP BY 
			[block_id]
	)

	SELECT 
		--[t].[block_id], 
		--DATEADD(MILLISECOND, 3, DATEADD(MINUTE, 0 - @minutes, [t].[time_block])) [start_time],
		[t].[time_block] [event_time_end], 
		[s].[total_events] [blocking_events],
		[s].[total_blocked_spids] [blocked_spids],
		ISNULL([s].[accrued_seconds_blocked], 0) [blocking_seconds],
		ISNULL([s].[running_seconds_blocked], 0) [running_seconds], 
		N'' [ ], 
		sb.[blocking_events] [self_events], 
		sb.[blocked_spids] [self_spids],
		sb.[blocking_seconds] [self_seconds], 
		sb.[running_seconds] [self_running_seconds]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [summed] [s] ON [t].[block_id] = [s].[block_id]
		LEFT OUTER JOIN [#summedSelfBlockers] [sb] ON [s].[block_id] = [sb].[block_id]
	ORDER BY 
		[t].[block_id];

	RETURN 0;
GO