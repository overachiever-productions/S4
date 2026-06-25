/*
	
		TODO: look at changing the datatypes for @start and @end to 'vectors' or whatever I'm going to call them - maybe `timespans`. 


		.EXAMPLE: Projecting outputs: 
		Note that execution of the sproc returns all columns ... 

		```sql
		EXEC [admindb]..[extract_log_events]
			@start = N'2 months';

		```

		.EXAMPLE: Extraction of XML + Shredding via Inline Func:
		sdlkfjlasdfjldsfalk
		
		```sql

		DECLARE @xml xml;
		EXEC [admindb]..[extract_log_events]
			@start = N'2 months', 
			@serialized_output = @xml OUTPUT;

		-- allows explicit columns and FILTERING if/as needed:
		SELECT [log_date], [text] FROM [admindb]..[log_events_data](@xml)
		ORDER BY [row_id];

		```

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

	-- IMPLEMENTATION DETAILS: https://overachieverllc.atlassian.net/browse/S4-873

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
		-- https://overachieverllc.atlassian.net/browse/S4-874
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
				ROW_NUMBER() OVER (ORDER BY [row_number]) [@row_id],
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
		ROW_NUMBER() OVER (ORDER BY [row_number]) [row_id], 
		[log_number] [log_file_number],
		[log_date],
		[process_info],
		RTRIM([text]) [text]		
	FROM 
		[#event_log_entries]
	ORDER BY 
		[row_number];
GO