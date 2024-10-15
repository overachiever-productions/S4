/*
	NOTE: This does NOT adhere to PROJECT or RETURN... (it ONLY does RETURN)


	REFACTOR: 
		dbo.eventstore_frame_heatmap (where 'frame' is a verb). I could also use a ... verby-very like dbo.eventstore_build|generate|create_heatmap.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_heatmap_frame]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_heatmap_frame];
GO

CREATE PROC dbo.[eventstore_heatmap_frame]
	@Granularity				sysname			= N'HOUR',			-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@SerializedOutput			xml				= NULL				OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'HOUR'));
	IF @Granularity LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);


SELECT @Granularity;

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
	DECLARE @startTime datetime2 = '2017-01-01 00:00:00.000';
	DECLARE @endTime datetime2 = '2017-01-01 23:59:59.999';

	CREATE TABLE #times (
		[row_id] int IDENTITY(1, 1) NOT NULL, 
		[utc_start] time NOT NULL, 
		[utc_end] time NOT NULL
	);

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

	INSERT INTO [#times] ([utc_start], [utc_end])
	SELECT 
		CAST([start] AS time) [utc_start], 
		CAST([end] AS time) [utc_end]
	FROM 
		[times]
	OPTION (MAXRECURSION 200);

	SELECT @SerializedOutput = (
		SELECT 
			[row_id] [block_id],
			CAST([utc_start] AS time) [start_time],
			CAST([utc_end] AS time) [end_time]
		FROM 
			[#times]
		ORDER BY 
			[row_id]
		FOR XML PATH(N'time'), ROOT(N'times'), TYPE
	);

	RETURN 0;
GO