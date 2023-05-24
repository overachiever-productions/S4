/*


		EXEC [admindb].dbo.[view_blockedprocesses_problems]
			@TranslatedBlockedProcessesTable = N'blocking.dbo.all_blocking_feb15',
			--@Mode = NULL,
			@OptionalStartTime = '2023-01-11 22:10:10.910',
			@OptionalEndTime = '2023-01-11 22:15:27.793',
			@ExcludeSelfBlocking = 0,
			@ConvertTimesFromUtc = 1;

		EXEC [admindb].dbo.[view_blockedprocesses_problems]
			@TranslatedBlockedProcessesTable = N'blocking.dbo.all_blocking_feb15',
			@Mode = N'BLOCKING_DURATION',
			--@OptionalStartTime = '2023-02-01 10:00:00', 
			--@OptionalEndTime = '2023-02-03 19:36:00',
			@TopRows = 10,
			@ConvertTimesFromUtc = 1;



		vNEXT:
			xml-aggregate #, {thing} for blocked-resources, blocked-statements 
				e.g., <blocked_resources><resource count=12>[RPT].[OBJECT_ID: 1874864592] - OBJECT_LOCK</resource> ... etc... 

			and then provide options to SORT/ORDER-BY these values 
				i.e., will want to roll these INTO some sort of additional option for sorting. 
				as in, WITH ranker ... won't work. i'll need a new @finalProjection for @MODE = BLOCKED_RESOURCE | BLOCKED_STATEMENT 
					where I 'shred' these values ... and then rank by them. 

				Or, more specifically: 
					a). add 2x new columns for ALL filters/projections where I XML-correlated-include (with counts) blocked statements/resources. 
					b). create a new set of optional filters to filter by these 2x columns.



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_blockedprocesses_problems','P') IS NOT NULL
	DROP PROC dbo.[view_blockedprocesses_problems];
GO

CREATE PROC dbo.[view_blockedprocesses_problems]
	@TranslatedBlockedProcessesTable			sysname, 
	@Mode										sysname			= N'BLOCKING_DURATION',   -- { BLOCKING_STATEMENT | BLOCKING_APPLICATION | BLOCKING_RESOURCE | BLOCKING_COUNT | BLOCKING_SECONDS | BLOCKING_DURATION } 
	@OptionalStartTime							datetime		= NULL, 
	@OptionalEndTime							datetime		= NULL, 
	@ExcludeSelfBlocking						bit				= 0,
	@TopRows									int				= 50,
	@ExcludeNullsForOrdering					bit				= 1,
	@TimeZone									sysname			= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Mode = ISNULL(NULLIF(@Mode, N''), N'BLOCKING_DURATION');
	SET @Mode = UPPER(@Mode);
	
	SET @TranslatedBlockedProcessesTable = NULLIF(@TranslatedBlockedProcessesTable, N'');
	SET @TimeZone = NULLIF(@TimeZone, N'');

	IF @Mode LIKE N'%S' SET @Mode = LEFT(@Mode, LEN(@Mode) - 1);  -- normalize/remove S, e.g., week_times becomes week_time.

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @TranslatedBlockedProcessesTable, 
		@ParameterNameForTarget = N'@TranslatedBlockedProcessesTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;	

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
		SET @TimeZone = dbo.[get_local_timezone]();

	DECLARE @offsetMinutes int = 0;
	IF @TimeZone IS NOT NULL
		SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);

	SET @OptionalStartTime = DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalStartTime);
	SET @OptionalEndTime = DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime);

	DECLARE @traceSummary xml; 
	EXEC dbo.[aggregate_blocked_processes]
		@TranslatedBlockedProcessesTable = @TranslatedBlockedProcessesTable,
		@OptionalStartTime = @OptionalStartTime,
		@OptionalEndTime = @OptionalEndTime,
		@ExcludeSelfBlocking = @ExcludeSelfBlocking,
		@Output = @traceSummary OUTPUT;
	
	WITH shredded AS ( 
		SELECT 
			[instance].[row].value(N'(transaction_id)[1]', N'bigint') [transaction_id],
			[instance].[row].value(N'(type)[1]', N'sysname') [type],
			[instance].[row].value(N'(start_time)[1]', N'datetime') [start_time],
			[instance].[row].value(N'(end_time)[1]', N'datetime') [end_time],
			[instance].[row].value(N'(duration)[1]', N'sysname') [duration],
			[instance].[row].value(N'(blocked_processes_count)[1]', N'bigint') [blocked_processes_count],
			[instance].[row].value(N'(total_seconds_blocked)[1]', N'bigint') [total_seconds_blocked]
		FROM 
			@traceSummary.nodes(N'//instance') [instance]([row])
	)

	SELECT 
		[shredded].[transaction_id],
		[shredded].[type],
		[shredded].[start_time],
		[shredded].[end_time],
		[shredded].[duration],
		[shredded].[blocked_processes_count],
		[shredded].[total_seconds_blocked] 
	INTO 
		#blockedProcesses
	FROM 
		[shredded];

	CREATE TABLE #expanded (
		[transaction_id] bigint NOT NULL,
		[type] sysname NOT NULL,
		[start_time] datetime NOT NULL,
		[end_time] datetime NOT NULL,
		[duration] sysname NOT NULL,
		[blocked_processes] bigint NOT NULL,
		[blocking_seconds] bigint NOT NULL,
		[database_name] sysname NULL,
		[blocking_request] nvarchar(MAX) NULL,
		[offset] sysname NULL,
		[blocking_resource] varchar(2000) NULL,
		[blocking_wait_time] int NULL,
		[blocking_isolation_level] sysname NULL,
		[blocking_tran_count] int NOT NULL,
		[blocking_status] sysname NULL,
		[blocker] xml NOT NULL,
		[blocking_client_app] sysname NOT NULL,
		[report] xml NOT NULL
	) 

	DECLARE @sql nvarchar(MAX) = N'WITH roots AS ( 
		SELECT 
			[blocking_xactid] [transaction_id],
			MIN([row_id]) [row_id]
		FROM 
			{SourceTable} 
		WHERE 
			[blocking_xactid] IN (SELECT [blocking_xactid] FROM [#blockedProcesses])
		GROUP BY 
			[blocking_xactid]
	), 
	expanded AS ( 
		SELECT 
			[p].[transaction_id],
			[p].[type],
			DATEADD(MINUTE, @offsetMinutes, [p].[start_time]) [start_time],
			DATEADD(MINUTE, @offsetMinutes, [p].[end_time]) [end_time],
			[p].[duration],
			[p].[blocked_processes_count] [blocked_processes],
			[p].[total_seconds_blocked] [blocking_seconds], 
			[b].[database_name],
			ISNULL(NULLIF([b].[blocking_sproc_statement], N''''), [b].[blocking_request]) [blocking_request],
			CASE WHEN [b].[blocking_start_offset] + [b].[blocking_end_offset] < 0 THEN N'''' ELSE CAST(ISNULL(NULLIF([b].[blocking_start_offset], -1), 0) AS sysname) + N'' - '' + CAST([b].[blocking_end_offset] AS sysname) END [offset],
			ISNULL(NULLIF([b].[blocking_resource], N''''), [b].[blocking_resource_id]) [blocking_resource],
			[b].[blocking_wait_time],
			[b].[blocking_isolation_level],
			[b].[blocking_tran_count],
			[b].[blocking_status],
			(
				SELECT 
					[y].[blocking_client_app] [app_name],
					[y].[blocking_host_name] [host_name],
					[y].[blocking_login_name] [login_name]
				FROM 
					{SourceTable}  [y]
				WHERE 
					[y].[row_id] = [x].[row_id]
				FOR XML PATH(''root_blocker''), TYPE
			) [blocker],
			[b].[blocking_client_app], 
			[b].[report]

		FROM 
			[#blockedProcesses] [p]
			INNER JOIN [roots] [x] ON [p].[transaction_id] = [x].[transaction_id] 
			INNER JOIN {SourceTable} [b] ON [x].[row_id] = [b].[row_id]
	)

	SELECT * FROM [expanded]; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	
	INSERT INTO [#expanded] (
		[transaction_id],
		[type],
		[start_time],
		[end_time],
		[duration],
		[blocked_processes],
		[blocking_seconds],
		[database_name],
		[blocking_request],
		[offset],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_isolation_level],
		[blocking_tran_count],
		[blocking_status],
		[blocker],
		[blocking_client_app],
		[report]
	)
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@offsetMinutes int', 
		@offsetMinutes = @offsetMinutes;

	DECLARE @finalProjection nvarchar(MAX) = N'SELECT TOP (@TopRows) 
		--[transaction_id],
		[type],
		[start_time],
		[end_time],
		[duration],
		[blocked_processes],
		[blocking_seconds],
		[database_name],
		[blocking_request],
		[offset],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_isolation_level],
		[blocking_tran_count],
		[blocking_status],
		[blocker],
		[blocking_client_app],
		[report] 
	FROM 
		[#expanded] 
	ORDER BY 
		[{columnName}] DESC; ';


	IF @Mode IN (N'BLOCKING_COUNT', N'BLOCKING_SECONDS', N'BLOCKING_DURATION') BEGIN 
		SET @finalProjection = REPLACE(@finalProjection, N'{columnName}', 
			CASE @Mode 
				WHEN N'BLOCKING_COUNT' THEN N'blocked_processes'
				WHEN N'BLOCKING_SECONDS' THEN N'blocking_seconds'
				WHEN N'BLOCKING_DURATION' THEN N'duration'
			END);

		EXEC [sys].[sp_executesql]
			@finalProjection, 
			N'@TopRows int', 
			@TopRows = @TopRows;

		RETURN 0;
	END;

	SET @finalProjection = N'WITH ranker AS (
		SELECT 
			[{orderByCol}], 
			COUNT(*) [hits]
		FROM 
			[#expanded]
		WHERE 
			1 = 1{filter}
		GROUP BY 
			[{orderByCol}] 
	)
		
	SELECT TOP (@TopRows)
		--[x].[transaction_id],
		[x].[type],
		[start_time],
		[end_time],
		[x].[duration],
		[x].[blocked_processes],
		[x].[blocking_seconds],
		[x].[database_name],
		[x].[blocking_request],
		[x].[offset],
		[x].[blocking_resource],
		[x].[blocking_wait_time],
		[x].[blocking_isolation_level],
		[x].[blocking_tran_count],
		[x].[blocking_status],
		[x].[blocker],
		[x].[report]
	FROM 
		[#expanded] x 
		INNER JOIN [ranker] r ON ISNULL([x].[{orderByCol}], N'''') = ISNULL([r].[{orderByCol}], '''')
	ORDER BY 
		r.[hits] DESC; ';

	--BLOCKING_STATEMENT | BLOCKING_APPLICATION | BLOCKING_RESOURCE
	DECLARE @spacing nchar(5) = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + NCHAR(9);
	IF @Mode = N'BLOCKING_STATEMENT' BEGIN 
		SET @finalProjection = REPLACE(@finalProjection, N'{orderByCol}', N'blocking_request');
		SET @finalProjection = REPLACE(@finalProjection, N'{filter}', N'');
	END;
	
	IF @Mode = N'BLOCKING_APPLICATION' BEGIN 
		SET @finalProjection = REPLACE(@finalProjection, N'{orderByCol}', N'blocking_client_app');
		SET @finalProjection = REPLACE(@finalProjection, N'{filter}', N'');
	END;

	IF @Mode = N'BLOCKING_RESOURCE' BEGIN 
		SET @finalProjection = REPLACE(@finalProjection, N'{orderByCol}', N'blocking_resource');

		IF @ExcludeNullsForOrdering = 1
			SET @finalProjection = REPLACE(@finalProjection, N'{filter}', @spacing + N'AND [blocking_resource] IS NOT NULL');
		ELSE 
			SET @finalProjection = REPLACE(@finalProjection, N'{filter}', N'');
	END;

--PRINT @finalProjection;

	EXEC sp_executesql 
		@finalProjection,
		N'@TopRows int', 
		@TopRows = @TopRows;

	RETURN 0;
GO