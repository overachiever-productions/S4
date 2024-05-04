/*
	NOTE: This does NOT adhere to PROJECT or RETURN... (it ONLY does RETURN)

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_heatmap_frame]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_heatmap_frame];
GO

CREATE PROC dbo.[eventstore_heatmap_frame]
--	@Mode						sysname			= N'TIME_OF_DAY',		-- { TIME_OF_DAY | TIME_OF_WEEK } 
	@Granularity				sysname			= N'HOUR',				-- { HOUR | [20]MINUTE } (minute = 20 minute blocks)
	@TimeZone					sysname			= NULL,			-- Defaults to UTC (as that's what ALL XE sessions record in/against). Can be changed to a TimeZone on NEWER versions of SQL Server - including {SERVER_LOCAL}. 
	@SerializedOutput			xml				= NULL			OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	--SET @Mode = UPPER(ISNULL(NULLIF(@Mode, N''), N'TIME_OF_DAY'));
	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'HOUR'));
	IF @Granularity LIKE N'%S' SET @Granularity = LEFT(@Granularity, LEN(@Granularity) - 1);

	SET @TimeZone = NULLIF(@TimeZone, N'');	

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding Predicates and Translations:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
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

	--IF @Mode = N'TIME_OF_DAY' BEGIN
		SELECT @SerializedOutput = (
			SELECT 
				[row_id] [block_id],
				CAST([utc_start] AS time) [utc_start],
				CAST([utc_end] AS time) [utc_end]
			FROM 
				[#times]
			ORDER BY 
				[row_id]
			FOR XML PATH(N'time'), ROOT(N'times'), TYPE
		);

		RETURN 0;
	--END;

	RETURN 0;
GO
--	/*---------------------------------------------------------------------------------------------------------------------------------------------------
--	-- TIME_OF_WEEK Logic Only (already short-circuited / returned if we were processing TIME_OF_DAY)
--	---------------------------------------------------------------------------------------------------------------------------------------------------*/
----	SET @endTime = '2017-01-07 23:59:59.999';

--	DECLARE @sql nvarchar(MAX);
--	CREATE TABLE #weekView (
--		[row_id] int IDENTITY(1,1) NOT NULL, 
--		[utc_start] time NOT NULL,
--		[utc_end] time NOT NULL,
--		[Sunday] sysname NULL, 
--		[Monday] sysname NULL, 
--		[Tuesday] sysname NULL,
--		[Wednesday] sysname NULL,
--		[Thursday] sysname NULL,
--		[Friday] sysname NULL,
--		[Saturday] sysname NULL,
--	);

--	INSERT INTO [#weekView] (
--		[utc_start],
--		[utc_end]
--	)
--	SELECT 
--		[utc_start], 
--		[utc_end]
--	FROM 
--		[#times]
--	ORDER BY 
--		[row_id];

--	SELECT @SerializedOutput = (
--		SELECT 
--			[row_id],
--			[utc_start],
--			[utc_end],
--			[Sunday],
--			[Monday],
--			[Tuesday],
--			[Wednesday],
--			[Thursday],
--			[Friday],
--			[Saturday]	
--		FROM 
--			[#weekView]
--		ORDER BY 
--			[row_id] 
--		FOR XML PATH(N'time'), ROOT(N'times'), TYPE, ELEMENTS XSINIL
--	);

--	RETURN 0;
--GO