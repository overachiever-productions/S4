/*

	vNEXT: 
		- option to shove numeric outputs into admindb.dbo.format_number().
				(option meaning... @FormatNumbers bit = 1 ... as default... but... can be set to 0 in case goal is to dump this stuff into excel or whatever).




			EXEC [admindb].dbo.[view_blockedprocess_heatmap]
				@TranslatedBlockedProcessesTable = N'blocking.dbo.all_blocking_feb15',
				@Mode = N'WEEK_TIME', 
				@Granularity = 'Minute';



	TIME ZONE EXAMPLES (utc vs specific):
			EXEC [admindb].dbo.[view_blockedprocess_heatmap]
				@TranslatedBlockedProcessesTable = N'blocking.dbo.all_blocking_feb15',
				@Mode = N'WEEK_TIME',
				--@Granularity = N'MINUTE',
				@ExcludeSelfBlocking = 1;


			EXEC [admindb].dbo.[view_blockedprocess_heatmap]
				@TranslatedBlockedProcessesTable = N'blocking.dbo.all_blocking_feb15',
				@Mode = N'WEEK_TIME',
				--@Granularity = N'MINUTE',
				@ExcludeSelfBlocking = 1,
				@TimeZone = N'Central Standard Time';



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_blockedprocess_heatmap','P') IS NOT NULL
	DROP PROC dbo.[view_blockedprocess_heatmap];
GO

CREATE PROC dbo.[view_blockedprocess_heatmap]
	@TranslatedBlockedProcessesTable			sysname, 
	@Mode										sysname			= N'TIME_OF_DAY',		-- { TIME_OF_DAY | WEEK_TIME } 
	@Granularity								sysname			= N'HOUR',			-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@ExcludeSelfBlocking						bit				= 0,
	@TimeZone									sysname			= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Mode = UPPER(ISNULL(NULLIF(@Mode, N''), N'TIME_OF_DAY'));
	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'HOUR'));

	SET @TranslatedBlockedProcessesTable = NULLIF(@TranslatedBlockedProcessesTable, N'');
	SET @TimeZone = NULLIF(@TimeZone, N'');

	IF @Mode LIKE N'%S' SET @Mode = LEFT(@Mode, LEN(@Mode) - 1);  -- normalize/remove S, e.g., week_times becomes week_time.

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

	DECLARE @minutes int = 60;
	IF @Granularity <> 'HOUR' SET @minutes = 20;

	CREATE TABLE #days ( 
		[day_id] int IDENTITY(1,1), 
		[day_name] sysname 
	); 

	/* Insanely enough ... NEED this in like 2-3 different spots. */
	INSERT INTO [#days] ([day_name])
	VALUES (N'Sunday'), (N'Monday'), (N'Tuesday'), (N'Wednesday'), (N'Thursday'), (N'Friday'), (N'Saturday');

	CREATE TABLE #times (
		[row_id] int IDENTITY(1, 1) NOT NULL, 
		[week_day] int NOT NULL, 
		[start] time NOT NULL, 
		[end] time NOT NULL
	);

	DECLARE @startTime datetime2 = '2017-01-01 00:00:00.000';
	DECLARE @endTime datetime2 = '2017-01-01 23:59:59.999';

	IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
		SET @TimeZone = dbo.[get_local_timezone]();

	DECLARE @offsetMinutes int = 0;
	IF @TimeZone IS NOT NULL AND UPPER(@TimeZone) <> N'UTC' BEGIN
		DECLARE @timeZoneName sysname = LOWER(REPLACE(@TimeZone, N' ', N'_'));
		SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);
	END;

	IF @Mode = N'WEEK_TIME' 
		SET @endTime = '2017-01-07 23:59:59.999';

	WITH times AS ( 
		SELECT @startTime [start], DATEADD(MICROSECOND, 0 - 1, (DATEADD(MINUTE, @minutes, @startTime))) [end]

		UNION ALL 
			
		SELECT 
			DATEADD(MINUTE, @minutes, [start]) [start] , 
			DATEADD(MICROSECOND, 0 - 1, (DATEADD(MINUTE, @minutes, [end]))) [end]
		FROM 
			[times]
		WHERE 
			[times].[start] < DATEADD(MINUTE, 0 - @minutes, @endTime)
	)

	INSERT INTO [#times] ([week_day], [start], [end])
	SELECT 
		DATEPART(WEEKDAY, [start]) [week_day],
		CAST([start] AS time) [start], 
		CAST([end] AS time) [end]
	FROM 
		[times]
	OPTION (MAXRECURSION 1000);

	DECLARE @sql nvarchar(MAX) = N'WITH coordinated AS ( 
	SELECT 
		[t].[week_day],
		[t].[start],
		[t].[end],
		ISNULL([b].[blocking_xactid], 0) [blocking_xactid],
		ISNULL([b].[seconds_blocked], 0) [seconds_blocked]				
	FROM 
		[#times] [t]
		LEFT OUTER JOIN {sourceTable} [b] ON (
			{dayJoin}(CAST([b].[timestamp] AS time) >= [t].[start] AND CAST([b].[timestamp] AS time) <= [t].[end])
		)
	WHERE 
		[b].[blocked_xactid] IS NOT NULL 
		AND [b].[blocking_xactid] IS NOT NULL
), 
aggregated AS (
	SELECT 
		[t].[week_day],
		[t].[start],
		[t].[end],
		COUNT([c].[blocking_xactid]) [blocked_processes],
		ISNULL(MAX([c].[seconds_blocked]), 0) [seconds_blocked]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [coordinated] [c] ON [t].[week_day] = [c].[week_day] AND [t].[start] = [c].[start]
	GROUP BY 
		[t].[week_day], [t].[start], [t].[end]
) 

SELECT 
	[a].[week_day],
	[a].[start], 
	[a].[blocked_processes],
	ISNULL([a].[seconds_blocked], 0) [seconds_blocked]
FROM 
	[aggregated] [a]
ORDER BY 
	[a].[week_day], [a].[start]; ';

	SET @sql = REPLACE(@sql, N'{sourceTable}', @normalizedName);

	IF UPPER(@Mode) = N'TIME_OF_DAY' BEGIN 
		SET @sql = REPLACE(@sql, N'{dayJoin}', N'');
	  END;
	ELSE BEGIN
		SET @sql = REPLACE(@sql, N'{dayJoin}', N'[t].[week_day] = DATEPART(WEEKDAY, [b].[timestamp]) AND ');
	END;

	CREATE TABLE #coordinated (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[day] int NOT NULL,
		[start] time, 
		[blocked_processes] int NOT NULL, 
		[seconds_blocked] decimal(24,2) NOT NULL, 
		[self_blocked] int NULL, 
		[self_seconds] decimal(24,2) NULL 
	);

	INSERT INTO [#coordinated] (
		[day],
		[start], 
		[blocked_processes],
		[seconds_blocked]
	)
	EXEC [sys].[sp_executesql] 
		@sql;

	IF @ExcludeSelfBlocking = 0 BEGIN 

		SET @sql = N'	WITH coordinated AS ( 
	SELECT 
		[t].[week_day],
		[t].[start],
		[t].[end],
		[b].[blocked_xactid],  -- blocked _NOT_ blocking... 
		[b].[seconds_blocked]				
	FROM 
		[#times] [t]
		LEFT OUTER JOIN {sourceTable} [b] ON (
			{dayJoin}(CAST([b].[timestamp] AS time) >= [t].[start] AND CAST([b].[timestamp] AS time) <= [t].[end])
		)
	WHERE 
		[b].[blocked_xactid] IS NOT NULL 
		AND [b].[blocking_xactid] IS NULL  -- self blockers don''t have a ''listed'' blocker... cuz... they''re ... self-blocking
), 
aggregated AS (
	SELECT 
		[t].[week_day],
		[t].[start],
		[t].[end],
		COUNT([c].[blocked_xactid]) [self_blocked_processes],
		ISNULL(MAX([c].[seconds_blocked]), 0) [self_seconds_blocked]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [coordinated] [c] ON [t].[week_day] = [c].[week_day] AND [t].[start] = [c].[start]
	GROUP BY 
		[t].[week_day], [t].[start], [t].[end]
), 
aligned AS (
	SELECT 
		[a].[week_day] [day],
		[a].[start], 
		[a].[self_blocked_processes],
		ISNULL([a].[self_seconds_blocked], 0) [self_seconds_blocked]
	FROM 
		[aggregated] [a] 
)

UPDATE [c]
SET 
	[c].[self_blocked] = [x].[self_blocked_processes],
	[c].[self_seconds] = [x].[self_seconds_blocked]
FROM 
	#coordinated [c]
	INNER JOIN aligned [x] ON [c].[day] = [x].[day] AND [c].[start] = [x].[start]; ';

		SET @sql = REPLACE(@sql, N'{sourceTable}', @normalizedName);

		IF @Mode = N'TIME_OF_DAY' BEGIN 
			SET @sql = REPLACE(@sql, N'{dayJoin}', N'');
		  END;
		ELSE BEGIN
			SET @sql = REPLACE(@sql, N'{dayJoin}', N'[t].[week_day] = DATEPART(WEEKDAY, [b].[timestamp]) AND ');
		END;
		
		EXEC sp_executesql @sql;
	END;

	IF UPPER(@Mode) = N'TIME_OF_DAY' BEGIN 

		SET @sql = N'	SELECT 
		{time}
		[blocked_processes],
		[seconds_blocked]{selfBlocking}
	FROM 
		[#coordinated] 
	ORDER BY 
		1; ';  -- bit ugly to sort by a column ordinal in production code... but ... it works. 
			
		IF @TimeZone IS NULL OR UPPER(@TimeZone) = N'UTC' BEGIN 
			SET @sql = REPLACE(@sql, N'{time}', N'LEFT(CONVERT(sysname, [start], 14), 8) + N''.000 - '' + LEFT(CONVERT(sysname, [start], 14), 2) + N'':59:59.999'' [utc],');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{time}', N'LEFT(CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, [start]), 14), 8) + N''.000 - '' + LEFT(CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, [start]), 14), 2) + N'':59:59.999'' [' + @timeZoneName + N'],');
		END;

		IF @ExcludeSelfBlocking = 1 
			SET @sql = REPLACE(@sql, N'{selfBlocking}', N'');
		ELSE 
			SET @sql = REPLACE(@sql, N'{selfBlocking}', N',
	'''' [ ],
	[self_blocked],
	[self_seconds] ');
	
		EXEC sp_executesql 
			@sql, 
			N'@offsetMinutes int', 
			@offsetMinutes = @offsetMinutes;
		
		RETURN 0;
	END;
	
	IF UPPER(@Mode) = N'WEEK_TIME' BEGIN 

		IF @offsetMinutes <> 0 BEGIN 
			ALTER TABLE [#coordinated] ADD [utc_day_time] datetime NULL;
			ALTER TABLE [#coordinated] ADD [local_day_time] datetime NULL;

			UPDATE [#coordinated] 
			SET 
				[utc_day_time] = CAST('2017-01-0' + CAST([day] AS sysname) + ' ' + CONVERT(sysname, [start], 8) AS datetime),
				[local_day_time] = DATEADD(MINUTE, @offsetMinutes, CAST('2017-01-0' + CAST([day] AS sysname) + ' ' + CONVERT(sysname, [start], 8) AS datetime))
			WHERE 
				[utc_day_time] IS NULL;

			/* Time (day)-Shift. Arguably, could do these in a single op - but they're fast and easier to debug/own via 2x operations. */
			UPDATE [#coordinated]
			SET 
				[local_day_time] = DATEADD(DAY, 7, [local_day_time])
			WHERE 
				[local_day_time] < @startTime;

			UPDATE [#coordinated]
			SET 
				[local_day_time] = DATEADD(DAY, 0 - 7, [local_day_time])
			WHERE 
				[local_day_time] > @endTime;

			/* Now, apply time-shift to original date + times ... */
			UPDATE [#coordinated] 
			SET 
				[day] = DATEPART(DAY, [local_day_time]), 
				[start] = CAST([local_day_time] AS time); 
		END;

		DECLARE @currentDayID int = 1; 
		DECLARE @currentDayName sysname = N'Sunday';
		DECLARE @select nvarchar(MAX) = N'SELECT 
	[start], 
	CASE WHEN [day] = @currentDayID THEN {contents} ELSE N'''' END [data] 
FROM 
	[#coordinated] 
WHERE 
	[day] = @currentDayID'; 
		
		IF @ExcludeSelfBlocking = 1 BEGIN 
			SET @select = REPLACE(@select, N'{contents}', N'CAST([blocked_processes] AS sysname) + N'' / '' + CAST([seconds_blocked] AS sysname)');
		  END; 
		ELSE BEGIN 
			SET @select = REPLACE(@select, N'{contents}', N'CAST([blocked_processes] AS sysname) + N'' / '' + CAST([seconds_blocked] AS sysname) + '' ('' + CAST([self_blocked] AS sysname) + N'' / '' + CAST([self_seconds] AS sysname) + N'')''');
		END;

		CREATE TABLE #weekView (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[start] time NULL,
			[Sunday] sysname NULL, 
			[Monday] sysname NULL, 
			[Tuesday] sysname NULL,
			[Wednesday] sysname NULL,
			[Thursday] sysname NULL,
			[Friday] sysname NULL,
			[Saturday] sysname NULL,
		);

		SET @sql = @select + N' ORDER BY [row_id]; ';

		INSERT INTO [#weekView] (
			[start],
			[Sunday]
		)
		EXEC sp_executesql 
			@sql, 
			N'@currentDayID int', 
			@currentDayID = @currentDayID;

		/* Yup ... ugly hack. But it's easy to maintain and PLENTY fast... */
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[day_id],
			[day_name]
		FROM 
			[#days]
		WHERE 
			[day_id] > 1
		ORDER BY 
			[day_id]
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			SET @sql = N'WITH currentDay AS ( 
		{select}
)

UPDATE [w] 
SET 
	[w].[{currentDayName}] = [c].[data]
FROM 
	#weekView [w] 
	INNER JOIN currentDay [c] ON [w].[start] = [c].[start]; ';

			SET @sql = REPLACE(@sql, N'{select}', @select);
			SET @sql = REPLACE(@sql, N'{currentDay}', @currentDayID);
			SET @sql = REPLACE(@sql, N'{currentDayName}', @currentDayName);

			EXEC sp_executesql 
				@sql, 
				N'@currentDayID int', 
				@currentDayID = @currentDayID;

			FETCH NEXT FROM [walker] INTO @currentDayID, @currentDayName;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		SET @sql = N'	SELECT
	LEFT(CONVERT(sysname, [start], 14), 8) + N''.000 - '' + LEFT(CONVERT(sysname, [start], 14), 2) + N'':59:59.999'' [{time_zone}],
	'' '' [ ],
	[Sunday],
	[Monday],
	[Tuesday],
	[Wednesday],
	[Thursday],
	[Friday],
	[Saturday]
FROM
	[#weekView]
ORDER BY 
	[row_id]; ';
		
		IF @TimeZone IS NULL OR UPPER(@TimeZone) = N'UTC' BEGIN 
			SET @sql = REPLACE(@sql, N'{time_zone}', N'utc');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{time_zone}', @timeZoneName);
		END;
		EXEC sp_executesql 
			@sql;
		
	END;
	
	RETURN 0;
GO