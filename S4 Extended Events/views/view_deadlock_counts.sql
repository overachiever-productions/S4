/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_deadlock_counts','P') IS NOT NULL
	DROP PROC dbo.[view_deadlock_counts];
GO

CREATE PROC dbo.[view_deadlock_counts]
	@TranslatedBlockedProcessesTable			sysname, 
	@Granularity								sysname			= N'HOUR',   -- { DAY | HOUR | MINUTE } WHERE MINUTE ends up being tackled in 5 minute increments (not 1 minute).
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL, 
	@TimeZone									sysname			= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TranslatedBlockedProcessesTable = NULLIF(@TranslatedBlockedProcessesTable, N'');
	SET @TimeZone = NULLIF(@TimeZone, N'');

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

	IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
		SET @TimeZone = dbo.[get_local_timezone]();

	DECLARE @offsetMinutes int = 0;
	IF @TimeZone IS NOT NULL
		SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);

	DECLARE @timePredicates nvarchar(MAX) = N'';

	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @timePredicates = N' AND [timestamp] >= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalStartTime), 121) + N'''';
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		SET @timePredicates = @timePredicates + N' AND [timestamp] <= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime), 121) + N'''';
	END;	
	
	CREATE TABLE #deadlocks (
		[deadlock_id] int NOT NULL, 
		[start_time] datetime NOT NULL, 
		[processes_count] int NOT NULL
	); 

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[deadlock_id], 
	MIN([timestamp]) [start_time], 
	MAX([process_count]) [processes_count]
FROM 
	{SourceTable}
WHERE 
	[deadlock_id] <> N''''{WHERE}
GROUP BY 
	[deadlock_id]
ORDER BY 
	[deadlock_id]; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	IF NULLIF(@timePredicates, N'') IS NULL BEGIN 
		SET @sql = REPLACE(@sql, N'{WHERE}', N'');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + NCHAR(9) + @timePredicates);
	END;
	
	INSERT INTO [#deadlocks] (
		[deadlock_id],
		[start_time],
		[processes_count]
	)
	EXEC sp_executesql 
		@sql;

	------------------------------------------------------------------------------------------------------
	-- Time-Bounding Logic: 
	DECLARE @traceStart datetime, @traceEnd datetime; 

	SET @sql = N'SELECT 
		@traceStart = MIN([timestamp]), 
		@traceEnd = MAX([timestamp])
	FROM 
		{SourceTable} 
	WHERE 
		[deadlock_id] <> ''''; ';

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
		RETURN -20;
	END;

	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @traceStart = DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalStartTime);
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		SET @traceEnd = DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime);
	END;

	DECLARE @timesStart datetime, @timesEnd datetime;
	SELECT 
		@timesStart = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @traceStart) / @minutes * @minutes, 0), 
		@timesEnd = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @traceEnd) / @minutes * @minutes, 0);

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
	SELECT DATEADD(MINUTE, @offsetMinutes, [time_block]) [time_block] 
	FROM times
	OPTION (MAXRECURSION 0);

	WITH times AS ( 
		SELECT 
			row_id,
			t.[time_block] [end],
			LAG(t.[time_block], 1, DATEADD(MINUTE, (0 - @minutes), DATEADD(MINUTE, @offsetMinutes, @timesStart))) OVER (ORDER BY row_id) [start]
		FROM 
			[#times] t
	), 
	coordinated AS ( 
		SELECT 
			t.[row_id], 
			t.[start] [time_period], 
			[d].[deadlock_id], 
			[d].[processes_count]
		FROM 
			[times] t 
			LEFT OUTER JOIN [#deadlocks] d ON DATEADD(MINUTE, @offsetMinutes, d.[start_time]) < t.[end] AND DATEADD(MINUTE, @offsetMinutes, d.[start_time]) >= t.[start]
		WHERE 
			d.[deadlock_id] <> ''
	), 
	aggregated AS ( 
		SELECT 
			DATEADD(MINUTE, 0 - @offsetMinutes, [t].[time_block]) [time_period], 
			COUNT([c].[deadlock_id]) [total_deadlocks], 
			ISNULL(SUM([c].[processes_count]), 0) [total_processes]
		FROM 
			[#times] [t]
			LEFT OUTER JOIN [coordinated] [c] ON [t].[time_block] = [c].[time_period]
		GROUP BY 
			[t].[time_block]
	) 

	SELECT 
		DATEADD(MINUTE, @offsetMinutes, [time_period]) [time_period],
		[total_deadlocks],
		[total_processes] 
	FROM 
		aggregated
	ORDER BY 
		[time_period];

	RETURN 0;
GO