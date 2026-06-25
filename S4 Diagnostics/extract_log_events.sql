/*
	
		TODO: look at changing the datatypes for @start and @end to 'vectors' or whatever I'm going to call them - maybe `timespans`. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[extract_log_events]','P') IS NOT NULL
	DROP PROC dbo.[extract_log_events];
GO

CREATE PROC dbo.[extract_log_events]
	@start							sysname			= N'2 weeks', 
	@end							sysname			= NULL, 
	--@options						sysname			= NULL,							-- FORCE_RELOAD
	@serialized_output				xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @start = ISNULL(NULLIF(@start, N''), N'2 weeks');
	SET @end = NULLIF(@end, N'');

	DECLARE @StartTime datetime, @EndTime datetime;
	SELECT @StartTime = TRY_PARSE(@start AS datetime), @EndTime = TRY_PARSE(ISNULL(@end, GETDATE()) AS datetime);

	IF @StartTime IS NULL BEGIN
		DECLARE @Error nvarchar(MAX);
		EXEC dbo.[translate_vector_datetime]
			@Vector = @start,
			@Operation = N'SUBTRACT',
			@Output = @StartTime OUTPUT,
			@Error = @Error OUTPUT;

		IF @Error IS NOT NULL BEGIN
			RAISERROR(@Error, 16, 1);
			RETURN -1;
		END;		
	END;

	IF @EndTime IS NULL BEGIN 
		SET @Error = NULL;
		EXEC dbo.[translate_vector_datetime]
			@Vector = @end,
			@Operation = N'SUBTRACT',
			@Output = @EndTime OUTPUT,
			@Error = @Error OUTPUT;

		IF @Error IS NOT NULL BEGIN
			RAISERROR(@Error, 16, 1);
			RETURN -1;
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Cached Results?
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	--IF UPPER(@options) LIKE N'%FORCE%' OR UPPER(@options) LIKE N'%RELOAD%'
	--	GOTO LOAD_LOG_DATA;

	-- Problems with Caching: 
	-- 1. Concurrency - if multiple consumers are trying to use the same cache, they might step on each other.
	-- 2. Timespans - if the cache is based on a specific time range, it might not be valid for subsequent calls with different time ranges.

	-- To Address the FIRST? maybe I end up with dbo.settings.log_extraction_active = 1 ... and then set it to 0. 
	--				once completed. 
	--	IF I end up going that route ... then I might as well have dbo.settings.log_extraction_cache 
	--				as a sysname with start:[startTime], end: [endTime], and generated: [generatedTime] 
	--			WHERE: 
	--				-> generatedTime = when I set dbo.settings.log_extraction_active to 0. i.e., when I completed. 
	--				-> endTime can ... be the equivalent of 'now' or GETDATE() ... something that indicates that the specified endTime
	--						for the cached data is/was within X minutes of the current time.
	--						OR ... hell. maybe just set ENDTime to ... GETDATE() or whatever when completed/etc. 
	--							i.e., or the actual value of @EndTime ... 
	-- 
	-- THEN... 
	--		CACHING WOULD WORK LIKE: 
	--		IF EXISTS (SELECT NULL FROM dbo.cached_error_log) ... 
	--				a. check to see the start/end of the cached data. 
	--					if they're within 1-2 minutes? of current start/end ... then fine? 
	--						unless there's some kind of directive. 
	--						and/or ... I could have a dbo.settings.error_logs_cache_window_seconds = e.g., 90 or whatever. 
	--					if ... start/end are within <threshold> then ... read from the CACHE instead. 
	--				b. if the cache is expired/old/no-good: 
	--					DELETE FROM dbo.cached_error_log;
	--				c. then ... check for log_extraction_active. 
	--						if it's active, then just read directly from the file and skip trying to ADD to the cache. 
	--						if NOT active. 
	--							set active and ... when done reading... 
	--							'top off the cache'. 
	--				d. either pull from the cache - if we had cached data or ... pull from ... #whatever.... depending upon logic. 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Enumerate Logs + Extract
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
LOAD_LOG_DATA:

	DECLARE @log_files table (
		[log_number] int NOT NULL, 
		[log_end] datetime NOT NULL, 
		[log_size] bigint NOT NULL, 
		[extract] bit NOT NULL DEFAULT(0)
	); 

	INSERT INTO @log_files ([log_number], [log_end], [log_size])
	EXEC sys.sp_enumerrorlogs; 

	-- Logical Correction:
	UPDATE @log_files SET [log_end] = GETDATE() WHERE [log_number] = 0;

	WITH [marked] AS (
		SELECT 
			[log_number],
			LEAD([log_end], 1, NULL) OVER (ORDER BY [log_number]) [log_start],
			[log_end]
		FROM 
			@log_files
	) 

	UPDATE [x] 
	SET 
		[extract] = 1
	FROM 
		@log_files [x]
		INNER JOIN [marked] [m] ON [x].[log_number] = [m].[log_number]
	WHERE 
		-- TODO: this logic is correct - it's "classic" interval-overlap logic. 
		-- ONLY: there might be a granularity problem here - i.e., sp_enumerrorlogs pulls back values ROUNDED to nearest(?) minute. my granularity is more specific. 
		[m].[log_start] <= @EndTime 
		AND [m].[log_end] >= @StartTime;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Extraction of 'marked' logs:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #event_log_entries (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[log_date] datetime NOT NULL,
		[process_info] sysname NOT NULL,
		[text] varchar(2048) NOT NULL, 
		[log_number] int NULL
	);	

	DECLARE @TargetLog int;
	DECLARE [loader] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[log_number]
	FROM 
		@log_files 
	WHERE 
		[extract] = 1 
	ORDER BY 
		[log_number];
	
	OPEN [loader];
	FETCH NEXT FROM [loader] INTO @TargetLog;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		INSERT INTO [#event_log_entries] ([log_date], [process_info], [text])
		EXEC sys.[xp_readerrorlog] @TargetLog, 1;

		-- NOT wild about this but ... it's milliseconds of CPU/duration - tops. 
		UPDATE [#event_log_entries] SET [log_number] = @TargetLog WHERE [log_number] IS NULL;
	
		FETCH NEXT FROM [loader] INTO @TargetLog;
	END;
	
	CLOSE [loader];
	DEALLOCATE [loader];

	DELETE FROM [#event_log_entries] WHERE [log_date] < @StartTime OR [log_date] > @EndTime;

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		
		SELECT @serialized_output = (
			SELECT 
				[log_number] [@log],
				[log_date] [@date],
				[process_info] [@process],
				RTRIM([text]) [*]	
			FROM 
				[#event_log_entries]
			ORDER BY 
				[row_number]
			FOR XML PATH(N'event'), ROOT(N'events'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[log_number] [log_file_number],
		[log_date],
		[process_info],
		RTRIM([text]) [text]		
	FROM 
		[#event_log_entries]
	ORDER BY 
		[row_number];

GO