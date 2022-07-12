/*

						Setup/Prep:
							EXEC [admindb].dbo.[translate_largegrant_trace]
								@SourceXelFilesDirectory = N'D:\traces\ts',
								@TargetTable = N'Traces.dbo.NA1_large_grants',
								@OverwriteTarget = 1;

							EXEC [admindb].dbo.[view_largegrant_counts]
								@TranslatedLargeGrantsTable = N'Traces.dbo.NA1_large_grants',
								@Granularity = N'MINUTE';



		EXEC admindb.dbo.[view_largegrant_problems]
			@TranslatedLargeGrantsTable = N'Traces.dbo.NA1_large_grants',
			@OptionalStartTime = '2021-05-17 07:50:00.000',
			@OptionalEndTime = '2021-05-17 08:00:00.000';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_largegrant_problems','P') IS NOT NULL
	DROP PROC dbo.[view_largegrant_problems];
GO

CREATE PROC dbo.[view_largegrant_problems]
	@TranslatedLargeGrantsTable				sysname, 
	@TopN									int				= 20,
	@IncludeHeader							bit				= 0,
	@OptionalStartTime						datetime		= NULL, 
	@OptionalEndTime						datetime		= NULL, 
	@ConvertTimesFromUtc					bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TranslatedLargeGrantsTable = NULLIF(@TranslatedLargeGrantsTable, N'');
	SET @ConvertTimesFromUtc = ISNULL(@ConvertTimesFromUtc, 1);
	SET @IncludeHeader = ISNULL(@IncludeHeader, 0);

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @TranslatedLargeGrantsTable, 
		@ParameterNameForTarget = N'@TranslatedLargeGrantsTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	DECLARE @timeOffset int = 0;
	IF @ConvertTimesFromUtc = 1 BEGIN 
		SET @timeOffset = (SELECT DATEDIFF(MINUTE, GETDATE(), GETUTCDATE()));
	END;

	DECLARE @timePredicates nvarchar(MAX) = N'';


	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @timePredicates = N' AND [timestamp] >= ''' + CONVERT(sysname, @OptionalStartTime, 121) + N'''';
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		SET @timePredicates = @timePredicates + N' AND [timestamp] <= ''' + CONVERT(sysname, @OptionalEndTime, 121) + N'''';
	END;	

	CREATE TABLE #work_table (
		[report_id] bigint NULL,
		[timestamp] datetime NULL,
		[database] sysname NULL,
		[dop] int NULL,
		[memory_grant_gb] decimal(12,2) NULL,
		[host_name] varchar(max) NULL,
		[application_name] varchar(max) NULL,
		[is_system] bit NULL,
		[statement_type] varchar(max) NULL,
		[statement] varchar(max) NULL,
		[query_hash_signed] varchar(max) NULL,
		[query_plan_hash_signed] varchar(max) NULL,
		[plan_handle] varbinary(64) NULL,
		[raw_data] xml NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'SELECT 
		[report_id],
		[timestamp],
		[database],
		[dop],
		[memory_grant_gb],
		[host_name],
		[application_name],
		[is_system],
		[statement_type],
		[statement],
		[query_hash_signed],
		[query_plan_hash_signed],
		[plan_handle],
		[raw_data] 		
	FROM 
		{SourceTable}{WHERE}; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	
	IF @timePredicates <> N'' BEGIN 
		SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + N'WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9)  + N'report_id IS NOT NULL' + @timePredicates);
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{WHERE}', N'');
	END;
	
	INSERT INTO [#work_table] (
		[report_id],
		[timestamp],
		[database],
		[dop],
		[memory_grant_gb],
		[host_name],
		[application_name],
		[is_system],
		[statement_type],
		[statement],
		[query_hash_signed],
		[query_plan_hash_signed],
		[plan_handle],
		[raw_data]
	)
	EXEC sp_executesql 
		@sql;

	IF @IncludeHeader = 1 BEGIN
		DECLARE @header nvarchar(MAX) = N'';
		SET @header = N'SELECT ISNULL(@OptionalStartTime, (SELECT MIN([timestamp]) FROM #work_table)) [start], ISNULL(@OptionalEndTime, (SELECT MAX([timestamp]) FROM #work_table)) [end], DATEDIFF(MINUTE, ISNULL(@OptionalStartTime, (SELECT MIN([timestamp]) FROM #work_table)), ISNULL(@OptionalEndTime, (SELECT MAX([timestamp]) FROM #work_table))) [minutes];';

		EXEC sp_executesql 
			@header, 
			N'@OptionalStartTime datetime, @OptionalEndTime datetime', 
			@OptionalStartTime = @OptionalStartTime, 
			@OptionalEndTime = @OptionalEndTime;
	END;

	WITH aggregates AS ( 
		SELECT 
			MAX([memory_grant_gb]) [query_grant_gb], 
			SUM([memory_grant_gb]) [total_grant_gb], 
			COUNT(*) [execution_count],
			[query_hash_signed]
		FROM 
			[#work_table] 
		GROUP BY 
			[query_hash_signed] 
	)

	SELECT 
		[a].[query_grant_gb],
		[a].[total_grant_gb],
		[a].[execution_count],
		(SELECT TOP 1 x.[statement] FROM [#work_table] x WHERE x.[query_hash_signed] = [a].[query_hash_signed] ORDER BY [x].[memory_grant_gb] DESC) [statement], 
		(SELECT TOP 1 x.[application_name] FROM [#work_table] x WHERE x.[query_hash_signed] = [a].[query_hash_signed] ORDER BY [x].[memory_grant_gb] DESC) [application_name], 
		(SELECT TOP 1 x.[statement_type] FROM [#work_table] x WHERE x.[query_hash_signed] = [a].[query_hash_signed] ORDER BY [x].[memory_grant_gb] DESC) [statement_type], 
		(SELECT TOP 1 x.[raw_data] FROM [#work_table] x WHERE x.[query_hash_signed] = [a].[query_hash_signed] ORDER BY [x].[memory_grant_gb] DESC) [event_data]
	FROM 
		[aggregates] [a]
	ORDER BY 
		[a].[query_grant_gb] DESC;


	RETURN 0;
GO