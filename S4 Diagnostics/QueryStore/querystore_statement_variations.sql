/*

	TODO: 
		This'll be a TINY bit of a pain - because the actual change will need to be implemented 'down' in the querystore_variations_by_query_ids proc.
		BUT ... this sproc should return a [module_id] column (or [module_name] column) in the resultset.
		Because, without that detail, it's hard to tell if you've 'matched' the exact statement you're looking for.

	EXAMPLE: 
		EXEC [dbo].[querystore_statement_variations]
			@TargetDatabase = N'BILLING'	,
			@StatementPattern = N'%SELECT%FROM%client%',
			@Granularity = N'TOTAL'		

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[querystore_statement_variations]','P') IS NOT NULL
	DROP PROC dbo.[querystore_statement_variations];
GO

CREATE PROC dbo.[querystore_statement_variations]
	@TargetDatabase			sysname					= NULL,
	@StatementPattern		nvarchar(MAX),								-- Expects wildcards to already be in place. 
	@Granularity			sysname					= N'TOTAL',			-- { TOTAL | DAY | NATIVE }
	@ExtractParameters		bit						= 1,
	@StartTimeUtc			datetime				= NULL,				-- defaults to 2 weeks ago. 
	@EndTimeUtc				datetime				= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Granularity = UPPER(ISNULL(NULLIF(@Granularity, N''), N'TOTAL'));

	IF @Granularity NOT IN (N'TOTAL', N'DAY', N'NATIVE') BEGIN
		RAISERROR(N'Allowed values for @Granularity are: { TOTAL | DAY | NATIVE }.', 16, 1);
		RETURN -10;
	END;

	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;
		
		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for @TargetDatabase and/or S4 was unable to determine calling-db-context. Please specify a valid database name for @TargetDatabase and retry. ', 16, 1);
			RETURN -5;
		END;
	END;

	IF @StartTimeUtc IS NULL BEGIN 
		SET @StartTimeUtc = DATEADD(DAY, 0 - 14, GETUTCDATE());
	END;

	DECLARE @enum bigint_enumeration;

	DECLARE @sql nvarchar(MAX) = N'
	SELECT 
		[q].[query_id] 
	FROM 
		[{targetDB}].[sys].[query_store_query] [q] 
		INNER JOIN [{targetDB}].[sys].[query_store_query_text] [t] ON [q].[query_text_id] = [t].[query_text_id]
	WHERE 
		[t].[query_sql_text] LIKE @StatementPattern 
		AND [q].[last_execution_time] >= @StartTimeUtc AT TIME ZONE ''UTC''{endTime}
		AND [t].[query_sql_text] NOT LIKE N''%@StartTimeUtc AT TIME ZONE ''''UTC''''%''; ';

	SET @sql = REPLACE(@sql, N'{targetDB}', @TargetDatabase);

	IF @EndTimeUtc IS NULL 
		SET @sql = REPLACE(@sql, N'{endTime}', N'');
	ELSE 
		SET @sql = REPLACE(@sql, N'{endTime}', NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N'AND [q].[last_execution_time] < @EndTimeUtc AT TIME ZONE ''UTC''');

	INSERT INTO @enum ([value])
	EXEC sys.[sp_executesql] 
		@sql, 
		N'@StatementPattern nvarchar(MAX), @StartTimeUtc datetime, @EndTimeUtc datetime', 
		@StatementPattern = @StatementPattern, 
		@StartTimeUtc = @StartTimeUtc, 
		@EndTimeUtc = @EndTimeUtc;
	
	IF NOT EXISTS (SELECT NULL FROM @enum) BEGIN 
		RAISERROR(N'@StatementPattern and/or other specified parameters yielded NO results.', 16, 1);
		RETURN 0;
	END;

	DECLARE @startTime datetime2(7) = @StartTimeUtc AT TIME ZONE 'UTC';
	DECLARE @endTime datetime2(7) = ISNULL(@EndTimeUtc, GETUTCDATE()) AT TIME ZONE 'UTC';

	EXEC dbo.[querystore_variations_by_query_ids]
		@TargetDatabase = @TargetDatabase,
		@Granularity = @Granularity,
		@QueryIds = @enum,
		@ExtractParameters = @ExtractParameters,
		@StartTime = @startTime,
		@EndTime = @endTime;

	RETURN 0;
GO