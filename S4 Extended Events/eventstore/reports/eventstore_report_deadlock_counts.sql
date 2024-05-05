/*



	.REMARKS
		#### Exclusions
		Filtering (or exclusion) of Specific SQL Statements works, but not exactly as might be expected - given the nature of how Deadlocks work. 
		Specifically, if you exclude (or filter-out) something like `@ExcludedStatements = N'%UPDATE%myTableNameHere%'`, then any statements (captured 
		either as part of the deadlock itself or via the Input Buffer) that run UPDATEs against `[myTableNameHere]` WILL be excluded from counts. 
		However, if a Deadlock occurs against `[myTableNameHere]` from/against another table (e.g., FK conflict), then a DEADLOCK will still be 
		included in counts/outputs of this report for the time-block in question. 
		Or, stated differently, to FULLY ignore/exclude an ENTIRE Deadlock (instead of just 'part' or 'parts' of the Deadlock), the `@ExcludedStatements` 
		value would need to effectively exclude ALL statements involved in the actual deadlock - e.g., the UPDATE against `[myTableNameHere]` AND whatever
		was being fired against `[fkConflictTableNameHere]` as the 'other side of the Deadlock` as well. (And, of course: Deadlocks can/will involve more
		than 'just' 2x operations in some cases.) 

		The above logic (i.e., limitations on exclusions) also applies to `@ExcludeSqlAgentJobs` - if all 'members' of a Deadlock are from SQL Server Agent
		Jobs, then the entire Deadlock will be excluded. If a Deadlock occurs between Agent Jobs and OTHER operations, the Deadlock will be counted in the 
		time blocks output by this report - and stats for deadlock_reports, total_processes, and total_transactions will be incremented to include ALL 
		aspects of the Deadlock in question. Only total_wait_ms will EXCLUDE the waits associated with the Job in question. 
		Whereas, if ALL members of the Deadlock were SQL Server Agent jobs, then deadlock_reports, total_processes, total_transactions, and total_wait_ms
		would NOT be incremented at all. 



	vNEXT:
		- I need to figure out how to have the docs/info above ... AND allow this vNEXT tag to live in the same bit of code. 
		- I also think I probably need to look at options for somehow excluding 'exclusions' from total_processes, and total_transactions (instead of ONLY 
		being excluded from total_wait_ms). I think I could do this by ... a) excluding the AND [x].statement is NULL clause from the @sql dynamic INSERT/SELECT into 
		#metrics, b) running some 'decrements' against matches - in some odd way. 
		I would still need some documentation for the above - i.e., a deadlock of 3x threads, where 2x of them are excluded still = 1x deadlock_report ... but
		then wouldn't count the processes/transactions/waits for those 2x - just ... the 1x. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_report_deadlock_counts]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_report_deadlock_counts];
GO

CREATE PROC dbo.[eventstore_report_deadlock_counts]
	@Granularity				sysname			= N'HOUR', 
	@Start						datetime		= NULL, 
	@End						datetime		= NULL, 
	@TimeZone					sysname			= NULL, 
	@ExcludeSqlAgentJobs		bit				= 1, 
	@ExcludedStatements			nvarchar(MAX)	= NULL				
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExcludeSqlAgentJobs = ISNULL(@ExcludeSqlAgentJobs, 1);
	SET @ExcludedStatements = NULLIF(@ExcludedStatements, N'');

	DECLARE @eventStoreKey sysname = N'DEADLOCKS';
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @eventStoreKey); 
	
	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @eventStoreTarget, 
		@ParameterNameForTarget = N'@eventStoreTarget', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	SET @outcome = 0;
	DECLARE @times xml;
	EXEC @outcome = dbo.[eventstore_timebounded_counts]
		@Granularity = @Granularity,
		@Start = @Start,
		@End = @End,
		@TimeZone = @TimeZone,
		@SerializedOutput = @times OUTPUT;

	IF @outcome <> 0 
		RETURN @outcome;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'(block_id)[1]', N'int') [block_id], 
			[data].[row].value(N'(start_time)[1]', N'datetime') [start_time],
			[data].[row].value(N'(end_time)[1]', N'datetime') [end_time], 
			[data].[row].value(N'(time_zone)[1]', N'sysname') [time_zone]
		FROM 
			@times.nodes(N'//time') [data]([row])
	) 

	SELECT 
		[block_id],
		[start_time],
		[end_time],
		[time_zone]
	INTO 
		#times
	FROM 
		shredded 
	ORDER BY 
		[block_id];
	
	IF @Start IS NULL BEGIN 
		SELECT 
			@Start = MIN([start_time]), 
			@End = MAX([end_time]) 
		FROM 
			[#times];
	END;

	CREATE TABLE #metrics ( 
		[deadlock_time] datetime2 NOT NULL,
		[deadlock_id] int NOT NULL, 
		[process_count] int NOT NULL, 
		[transaction_count] int NOT NULL, 
		[wait_time_ms] bigint NOT NULL
	);

	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @exclusions nvarchar(MAX) = N'';
	IF @ExcludeSqlAgentJobs = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [s].[application_name] NOT LIKE N''SQLAgent%''';
	END;

	DECLARE @excludedStatementsJoin nvarchar(MAX) = N'';
	IF @ExcludedStatements IS NOT NULL BEGIN 
		CREATE TABLE #excludedStatements (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[statement] nvarchar(MAX) NOT NULL
		);

		INSERT INTO [#excludedStatements] ([statement])
		SELECT [result] FROM [dbo].[split_string](@ExcludedStatements, N',', 1);
		
		SET @excludedStatementsJoin = @crlftab + N'LEFT OUTER JOIN #excludedStatements [x] ON ([s].[input_buffer] LIKE [x].[statement] OR [s].[statement] LIKE [x].[statement])';
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[statement] IS NULL';
	END;
	
	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[s].[timestamp] [deadlock_time], 
	[s].[deadlock_id], 
	[s].[process_count], 
	[s].[transaction_count], 
	[s].[wait_time_ms]
FROM 
	{SourceTable} [s]{excludedStatementsJoin}
WHERE 
	[s].[timestamp]>= @Start 
	AND [s].[timestamp] <= @End{exclusions};'; 

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{excludedStatementsJoin}', @excludedStatementsJoin);
	SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

	--EXEC [dbo].[print_long_string] @sql;
	
	INSERT INTO [#metrics] (
		[deadlock_time],
		[deadlock_id],
		[process_count],
		[transaction_count],
		[wait_time_ms]
	)
	EXEC sys.[sp_executesql]
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlate + Project
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH times AS ( 
		SELECT 
			[t].[block_id], 
			[t].[start_time], 
			[t].[end_time]
		FROM 
			[#times] [t]
	), 
	correlated AS ( 
		SELECT 
			[t].[block_id],
			[t].[start_time],
			[t].[end_time], 
			[m].[deadlock_time], 
			[m].[deadlock_id], 
			[m].[process_count], 
			[m].[transaction_count], 
			[m].[wait_time_ms]
		FROM 
			[times] [t]
			LEFT OUTER JOIN [#metrics] [m] ON [m].[deadlock_time] < [t].[end_time] AND [m].[deadlock_time] > [t].[start_time] -- anchors 'up' - i.e., for an event that STARTS at 12:59:59.33 and ENDs 2 seconds later, the entry will 'show up' in hour 13:00... 
	), 
	summed AS ( 
		SELECT 
			[block_id], 
			[deadlock_id], 
			MAX([process_count]) [processes_count], 
			MAX([transaction_count]) [transactions_count], 
			SUM([wait_time_ms]) [total_wait_ms]
		FROM 
			[correlated] 
		GROUP BY
			[block_id], [deadlock_id]
	),
	aggregated AS ( 
		SELECT 
			[block_id], 
			COUNT([deadlock_id]) [total_deadlocks],
			SUM([processes_count]) [total_processes], 
			SUM([transactions_count]) [total_transactions], 
			SUM([total_wait_ms]) [total_wait_ms]
		FROM 
			[summed] 
		GROUP BY
			[block_id]
	) 

	SELECT 
		[t].[end_time],
		ISNULL([a].[total_deadlocks], 0) [deadlock_reports],
		ISNULL([a].[total_processes], 0) [deadlocked_processes],
		ISNULL([a].[total_transactions], 0) [deadlocked_transactions],
		ISNULL([a].[total_wait_ms], 0) [total_wait_ms]
	FROM 
		[#times] [t]
		LEFT OUTER JOIN [aggregated] [a] ON [t].[block_id] = [a].[block_id] 
	ORDER BY 
		[t].[block_id];

	RETURN 0; 
GO