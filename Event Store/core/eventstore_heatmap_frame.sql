/*
	NOTE: This does NOT adhere to PROJECT or RETURN... (it ONLY does RETURN)

	REFACTOR:
		remove "eventstore" from the name. 


	SAMPLE / SIGNATURE: 

			DECLARE @SerializedOutput xml;
			EXEC [dbo].[eventstore_heatmap_frame]
				@Granularity = N'MINUTE',
				@SerializedOutput = @SerializedOutput OUTPUT; 

			SELECT @SerializedOutput;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_heatmap_frame]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_heatmap_frame];
GO

CREATE PROC dbo.[eventstore_heatmap_frame]
	@Granularity				sysname			= N'HOUR',			-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@TimeZone					sysname			= N'UTC',
	@Start						datetime2(7)	= NULL,			
	@End						datetime2(7)	= NULL,
	@SerializedOutput			xml				= NULL				OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'HOUR'));
	IF @Granularity LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

	SET @TimeZone = ISNULL(NULLIF(@TimeZone, N''), N'UTC');
	SET @Start = ISNULL(@Start, DATEADD(DAY, -7, GETDATE()));
	SET @End = ISNULL(@End, GETDATE());

	IF UPPER(@Granularity) NOT IN (N'HOUR', N'MINUTE') BEGIN 
		RAISERROR(N'Allowed values for @Granularity are HOUR(S) or MINUTE(S).', 16, 1);
		RETURN -8;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time Bounding (Blocks) - and Start/End Defaults.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @minutes int = 0;
	IF UPPER(@Granularity) LIKE N'%INUTE%' BEGIN -- 20 minute blocks... 
		SET @minutes = 20;
	END; 

	IF UPPER(@Granularity) = N'HOUR' BEGIN 
		SET @minutes = 60;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- HeatMap Creation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @startTime datetime2(4) = CAST(FORMAT(@End, N'yyyy-MM-dd') + N' 00:00:00.0000' AS datetime2(7));
	DECLARE @endTime datetime2(4) = CAST(FORMAT(@End, N'yyyy-MM-dd') + N' 23:59:59.9999' AS datetime2(7));

	CREATE TABLE #times (
		[row_id] int IDENTITY(1, 1) NOT NULL, 
		[utc_start] time NOT NULL, 
		[utc_end] time NOT NULL,
		[local_start] datetime2(4) NOT NULL,
		[local_end] datetime2(4) NOT NULL
	);

	WITH times AS ( 
		SELECT 
			@startTime [start], 
			DATEADD(MILLISECOND, 0 - 1, (DATEADD(MINUTE, @minutes, @startTime))) [end]

		UNION ALL 
			
		SELECT 
			DATEADD(MINUTE, @minutes, [start]) [start], 
			DATEADD(MILLISECOND, 0 - 1, (DATEADD(MINUTE, @minutes, [end]))) [end]
		FROM 
			[times]
		WHERE 
			[times].[start] < DATEADD(MINUTE, 0 - @minutes, @endTime)
	)

	INSERT INTO [#times] ([utc_start], [utc_end], [local_start], [local_end])
	SELECT 
		CAST([start] AS time) [utc_start], 
		CAST([end] AS time) [utc_end], 
		[start] AT TIME ZONE 'UTC' AT TIME ZONE @TimeZone [local_start], 
		
	-- FML:
		[end] AT TIME ZONE 'UTC' AT TIME ZONE @TimeZone [local_end]
	FROM 
		[times]
	OPTION (MAXRECURSION 200);

	SELECT @SerializedOutput = (
		SELECT 
			[row_id] [block_id],
			/* 
				NAH REALLY. WTF Microsoft? hh is what's required for 24-hour time for times, HH is what's REQUIRED for 24-hour time with datetimes. 
				TODO: use CONVERT here instead of FORMAT, as FORMAT completely, utterly, sucks. (TERRIBLE, TERRIBLE, factors.)
			*/
			CAST(FORMAT([utc_start], N'hh\:mm\:ss') + N'.0000000' AS time) [start_time],
			CAST(FORMAT([utc_end], N'hh\:mm\:ss') + N'.9999999' AS time) [end_time], 
			CAST(FORMAT([local_start], N'yyyy-MM-dd HH\:mm\:ss') + N'.0000' AS datetime2(4)) [local_start],
			CAST(FORMAT([local_end], N'yyyy-MM-dd HH\:mm\:ss') + N'.9999' AS datetime2(4)) [local_end]
		FROM 
			[#times]
		ORDER BY 
			[row_id]
		FOR XML PATH(N'time'), ROOT(N'times'), TYPE
	);

	RETURN 0;
GO