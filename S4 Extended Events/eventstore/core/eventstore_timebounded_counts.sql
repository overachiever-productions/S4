/*
	NOTE: This does NOT adhere to PROJECT or RETURN... 

	vNEXT: 
		Note that I COULD look into options to allow TimeZone offsets via an OVERLOAD of @TimeZone (for Pre-SQL Server 2016 instances). 
			i.e., I COULD allow things like N'+ 270 minutes' or ... N'- 240 minutes' INSTEAD of named time-zones. 
			This'd totally work ... and ... frankly, no reason to restric this to just versions earlier than 2016. 
				I'd just need a way to parse and handle this. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_timebounded_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_timebounded_counts];
GO

CREATE PROC dbo.[eventstore_timebounded_counts]
	@Granularity				sysname			= N'HOUR', 
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL,			-- Defaults to UTC (as that's what ALL XE sessions record in/against). Can be changed to a TimeZone on NEWER versions of SQL Server - including {SERVER_LOCAL}. 
	@SerializedOutput			xml				= NULL			OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');
	IF UPPER(@Granularity) LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

	SET @TimeZone = NULLIF(@TimeZone, N'');

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding Predicates and Translations:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	IF @TimeZone IS NOT NULL BEGIN 

		IF [dbo].[get_engine_version]() < 130 BEGIN 
			RAISERROR(N'@TimeZone is only supported on SQL Server 2016+.', 16, 1);
			RETURN -110;
		END;
	
		IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
			SET @TimeZone = dbo.[get_local_timezone]();

		DECLARE @offsetMinutes int = 0;
		IF @TimeZone IS NOT NULL
			SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);
	END;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time Bounding (Blocks) - and Start/End Defaults.
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @minutes int = 0;
	IF UPPER(@Granularity) LIKE N'%INUTE%' BEGIN -- 5 minute blocks... 
		SET @minutes = 5;
		SET @Start = ISNULL(@Start, DATEADD(HOUR, -2, GETUTCDATE()));
		SET @End = ISNULL(@End, GETUTCDATE());
	END; 

	IF UPPER(@Granularity) = N'HOUR' BEGIN 
		SET @minutes = 60;
		SET @Start = ISNULL(@Start, DATEADD(HOUR, -24, GETUTCDATE()));
		SET @End = ISNULL(@End, GETUTCDATE());
	END;

	IF UPPER(@Granularity) = N'DAY' BEGIN 
		SET @minutes = 60 * 24;
		SET @Start = ISNULL(@Start, DATEADD(DAY, -8, GETUTCDATE()));
		SET @End = ISNULL(@End, GETUTCDATE());
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

	DECLARE @startTime datetime = (SELECT DATEADD(MINUTE, 0 - @minutes, MIN(time_block)) FROM [#times]);

	WITH times AS ( 
		SELECT 
			[t].[block_id], 
			LAG([t].[time_block], 1, @startTime) OVER (ORDER BY [t].[block_id]) [start_time],
			[t].[time_block] [end_time],
			@TimeZone [time_zone]
		FROM 
			[#times] [t]
	)

	SELECT @SerializedOutput = (
		SELECT 
			[block_id],
			[start_time],
			[end_time],
			[time_zone] 
		FROM 
			times
		FOR XML PATH(N'time'), ROOT(N'times'), TYPE
	); 

	RETURN 0;
GO