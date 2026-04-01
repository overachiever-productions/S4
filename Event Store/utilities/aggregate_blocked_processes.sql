/*
	NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.aggregate_blocked_processes','P') IS NOT NULL
	DROP PROC dbo.[aggregate_blocked_processes];
GO

CREATE PROC dbo.[aggregate_blocked_processes]
	@TranslatedBlockedProcessesTable			sysname, 
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL, 
	@ExcludeSelfBlocking						bit				= 0,
	@Output										xml				= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TranslatedBlockedProcessesTable = NULLIF(@TranslatedBlockedProcessesTable, N'');

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

	CREATE TABLE [#entireTrace] ( 
		[blocking_id] int IDENTITY(1,1) NOT NULL, 
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
			[blocking_xactid] IS NOT NULL
		GROUP BY 
			[blocking_xactid]
	) 

	SELECT 
		N''blocking-process'' [type],
		[start_time],
		[end_time],	
		[blocked_processes_count],
		[seconds_blocked], 
		[transaction_id]
	FROM 
		[blocking]
	ORDER BY 
		[start_time]; ';
	
	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);

	INSERT INTO [#entireTrace] (
		[type],
		[start_time],
		[end_time],
		[blocked_processes_count],
		[total_seconds_blocked],
		[transaction_id]
	)
	EXEC sys.sp_executesql 
		@sql;

	IF @ExcludeSelfBlocking = 0 BEGIN
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
				[blocking_xactid] IS NULL 
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

		INSERT INTO [#entireTrace] (
			[type],
			[start_time],
			[end_time],
			[blocked_processes_count],
			[total_seconds_blocked],
			[transaction_id]
		)
		EXEC sys.sp_executesql 
			@sql;	
	END;

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

	IF @OptionalStartTime IS NOT NULL OR @OptionalEndTime IS NOT NULL BEGIN 
		/*
			Excluding Blocking Operations before/after start/end times is a BIT tricky - e.g., something MIGHT start blocking 20 minutes before @start... 
				in which case, we don't want to exclude it from our list of blocked processes. 

			So, the approach is: 
				a. find processes actively blocking during @start/@end times specified
				b. DELETE where tx_id NOT IN (tx_ids that were blocking during the times specified). 
		*/
		SET @OptionalStartTime = ISNULL(@OptionalStartTime, @traceStart);
		SET @OptionalEndTime = ISNULL(@OptionalEndTime, @traceEnd);

		SELECT 
			[transaction_id]
		INTO 
			[#active]
		FROM 
			[#entireTrace] 
		WHERE 
			/* entirely within window (or exact match for entire window) */
			([start_time] >= @OptionalStartTime AND [end_time] <= @OptionalEndTime)

			/* start before window start and end after window end (i.e., running during window) */
			OR ([start_time] <= @OptionalStartTime AND [end_time] >= @OptionalEndTime)

			/* start during window */
			OR ([end_time] >= @OptionalEndTime AND [start_time] >= @OptionalStartTime AND [start_time] <= @OptionalEndTime)

			/* start before window, but end IN window */
			OR ([start_time] <= @OptionalStartTime AND [end_time] <= @OptionalEndTime AND [end_time] >= @OptionalStartTime);

		DELETE FROM [#entireTrace] 
		WHERE [transaction_id] NOT IN (SELECT [transaction_id] FROM [#active]);
	END;

	IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN -- Explicitly provided as param - i.e., output as XML
		SELECT @Output = (
			SELECT 
				@traceStart [@trace_start], 
				@traceEnd [@trace_end],
				(
					SELECT 
						[transaction_id],
						[type],
						[start_time],
						[end_time],
						dbo.[format_timespan](DATEDIFF(MILLISECOND, [start_time], [end_time])) [duration],
						[blocked_processes_count],
						[total_seconds_blocked]
					FROM 
						[#entireTrace]
					FOR XML PATH('instance'), TYPE
				)
			FOR XML PATH('instances')
		);

		RETURN 0;
	END;

	SELECT 
		[transaction_id],
		[type],
		[start_time],
		[end_time],
		dbo.[format_timespan](DATEDIFF(MILLISECOND, [start_time], [end_time])) [duration],
		[blocked_processes_count],
		[total_seconds_blocked]
	FROM 
		[#entireTrace]
	ORDER BY 
		[start_time];

	RETURN 0;
GO