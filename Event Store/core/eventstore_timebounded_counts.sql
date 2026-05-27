/*

	REFACTOR: 
		dbo.eventstore_verby-verb_count(thingy)
			see eventstore_heatmap_frame for more 'info'.

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
	@SerializedOutput			xml				= NULL			OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Granularity = ISNULL(NULLIF(@Granularity, N''), N'HOUR');
	IF UPPER(@Granularity) LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

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
			[t].[time_block] [end_time]
		FROM 
			[#times] [t]
	)

	SELECT @SerializedOutput = (
		SELECT 
			[block_id],
			[start_time],
			[end_time]
		FROM 
			times
		FOR XML PATH(N'time'), ROOT(N'times'), TYPE
	); 

	RETURN 0;
GO