/*

	.EXAMPLE
		
		```sql

		DECLARE @xml xml; 
		EXEC dbo.[io_freezes] 
			@serialized_output = @xml OUTPUT; 

		SELECT @xml;
		
		```
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[io_freezes]','P') IS NOT NULL
	DROP PROC dbo.[io_freezes];
GO

CREATE PROC dbo.[io_freezes]
	@event_data							xml			= NULL,
	@start								datetime	= NULL, 
	@end								datetime	= NULL, 
	@serialized_output					xml			= N'<default/>'	    OUTPUT		
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @start = ISNULL(@start, DATEADD(DAY, -14, GETDATE()));
	SET @end = ISNULL(@end, GETDATE());

	IF @start >= @end BEGIN
		RAISERROR(N'@start can not be greater than @end.', 16, 1);
		RETURN -1;
	END;
	
	CREATE TABLE [#event_log_entries] (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[log_date] datetime NOT NULL,
		[process_info] sysname NOT NULL,
		[text] varchar(2048) NOT NULL
	);

	IF @event_data IS NULL BEGIN
		EXEC dbo.[extract_log_events]
			@start = @start,
			@end = @end,
			@serialized_output = @event_data OUTPUT; 
	END;

	INSERT INTO [#event_log_entries] ([log_date], [process_info], [text])
	SELECT 
		 [log_date],
		 [process_info],
		 [text]
	FROM 
		dbo.[log_events_data](@event_data)
	ORDER BY 
		[row_id];
	
	WITH core AS ( 
		SELECT 
			[row_number], 
			[log_date] [timestamp],
			SUBSTRING([text], 0, CHARINDEX('.', [text])) [detail], 
			CASE WHEN [text] LIKE N'%frozen%' THEN N'freeze' ELSE N'thaw' END [operation]
		FROM 
			[#event_log_entries]
		WHERE 
			[text] LIKE N'I/O is frozen on database%' 
			OR [text] LIKE N'I/O was resumed on database%'
	) 
	SELECT 
		[row_number], 
		[timestamp],
		[detail], 
		RIGHT(core.[detail], LEN(core.[detail]) - PATINDEX('%database %', [detail]) - 8) [database], 
		[operation]
	INTO 
		[#intermediate_vss_metrics]
	FROM 
		core;

	-- TODO: these are JUST the raw metrics - i.e., need to probably a) aggregate by DB - i.e., avg, max, variation, and b) report on the 'worst' (i.e., order by MAX desc).
	WITH core AS ( 
		SELECT 
			[row_number], 
			[timestamp], 
			LAG([timestamp], 1, NULL) OVER(PARTITION BY [database] ORDER BY [timestamp] DESC) [freeze_end], 
			[database], 
			[operation], 
			[detail]
		FROM 
			[#intermediate_vss_metrics]
	) 

	SELECT 
		[database],
		[timestamp] [freeze_start],
		[freeze_end],
		DATEDIFF(MILLISECOND, [timestamp], [freeze_end]) [freeze_ms], 
		[detail]
	INTO 
		[#vss_metrics]
	FROM 
		[core]
	WHERE 
		[operation] = N'freeze'
	ORDER BY 
		[timestamp];

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				[database],
				[freeze_start],
				[freeze_end],
				[freeze_ms],
				[detail]
			FROM 
				[#vss_metrics] 
			FOR 
				XML PATH(N'freeze'), ROOT(N'freezes'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[database],
		[freeze_start],
		[freeze_end],
		[freeze_ms],
		[detail]
	FROM 
		[#vss_metrics]
	ORDER BY 
		[freeze_ms] DESC;

	RETURN 0;
GO