/*

			


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[signal_waits]', N'P') IS NOT NULL
	DROP PROC dbo.[signal_waits];
GO

CREATE PROC dbo.[signal_waits]
	@vector_tag							sysname			= NULL,
	@serialized_output					xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @vector_tag = NULLIF(@vector_tag, N'');
	
	DECLARE @current xml = (
		SELECT 
			SUM([wait_time_ms]) [@total_time],
			SUM([wait_time_ms] - [signal_wait_time_ms]) [@resource_time],
			SUM([signal_wait_time_ms]) [@signal_time]
		FROM 
			sys.[dm_os_wait_stats]
		FOR XML PATH(N'waits'), TYPE
	);

	IF @vector_tag IS NOT NULL BEGIN
		DECLARE @cached_date datetime, @cached_xml xml;

		EXEC dbo.[inserlect_cache]
			@vector_type = @@PROCID,
			@vector_key = @vector_tag,
			@current_xml = @current,
			@cached_date = @cached_date OUTPUT,
			@cached_xml = @cached_xml OUTPUT;
	
		IF @cached_date IS NOT NULL BEGIN 
			
			WITH [old] AS ( 
				SELECT 
					CAST(1 AS int) [row_id],
					@cached_xml.value(N'(//waits/@total_time)[1]', N'bigint') [total_time],
					@cached_xml.value(N'(//waits/@resource_time)[1]', N'bigint') [resource_time],
					@cached_xml.value(N'(//waits/@signal_time)[1]', N'bigint') [signal_time]
			), 
			[current] AS (
				SELECT 
					CAST(1 AS int) [row_id],
					@current.value(N'(//waits/@total_time)[1]', N'bigint') [total_time],
					@current.value(N'(//waits/@resource_time)[1]', N'bigint') [resource_time],
					@current.value(N'(//waits/@signal_time)[1]', N'bigint') [signal_time]
			), 
			[vectored] AS (
				SELECT 
					[c].[total_time] - [o].[total_time] [total_time],
					[c].[resource_time] - [o].[resource_time] [resource_time],
					[c].[signal_time] - [o].[signal_time] [signal_time]
				FROM 
					[old] [o]
					INNER JOIN [current] [c] ON [o].[row_id] = [c].[row_id]
			) 
			
			SELECT @current = (
				SELECT 
					[total_time] [@total_time], 
					[resource_time] [@resource_time],
					[signal_time] [@signal_time]
				FROM 
					[vectored]
				FOR XML PATH(N'waits'), TYPE
			);

		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Extract 'Current' Values.
	--		For signal waits, we ONLY need scalars. 
	--		For other diagnostics, we'll want entire 'tables' i.e., #xxx or whatever. 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @totalTime decimal(22,2), @resourceTime decimal(22,2), @signalTime decimal(22,2);
	SELECT 
		@totalTime		= @current.value(N'(//waits/@total_time)[1]', N'decimal(22,2)'),
		@resourceTime	= @current.value(N'(//waits/@resource_time)[1]', N'decimal(22,2)'),
		@signalTime		= @current.value(N'(//waits/@signal_time)[1]', N'decimal(22,2)');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Return or Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

		SELECT @serialized_output = (
			SELECT 
				CAST(@signalTime * 100. / @totalTime AS decimal(5,2)) [@signal_percent],
				CAST(@resourceTime * 100. / @totalTime AS decimal(5,2)) [@resource_percent], 
				@cached_date [@cached]		/* Only emitted if/when NOT NULL - which works out great... */
			FOR 
				XML PATH(N'signal_waits'), TYPE
		);	

		RETURN 0;
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	CAST(@signalTime * 100. / @totalTime AS decimal(5,2)) [signal_pct],
	CAST(@resourceTime * 100. / @totalTime AS decimal(5,2)) [resource_pct]{cached}; ';

	DECLARE @cachedString nvarchar(MAX) = N'';

	IF @cached_date IS NOT NULL BEGIN
		SET @cachedString = N',' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'@cached_date [cached]';
	END 

	SET @sql = REPLACE(@sql, N'{cached}', @cachedString);

	EXEC sys.[sp_executesql]
		@sql, 
		N'@totalTime decimal(22,2), @resourceTime decimal(22,2), @signalTime decimal(22,2), @cached_date datetime = NULL', 
		@totalTime = @totalTime, 
		@signalTime = @signalTime, 
		@resourceTime = @resourceTime, 
		@cached_date = @cached_date;
		
	RETURN 0;
GO