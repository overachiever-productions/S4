/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_cpu_and_sql_threshold_exceptions','P') IS NOT NULL
	DROP PROC dbo.[report_cpu_and_sql_threshold_exceptions];
GO

CREATE PROC dbo.[report_cpu_and_sql_threshold_exceptions]
	@SourceTable							sysname, 
	@IncludeAllCpus							bit					= 0,   -- if 0, only outputs percentage_used vs details on EACH core + aggregates/etc.
	@CpuOverPercentageThreshold				decimal(5,2)		= NULL,
	@PleUnderThreshold						int					= NULL, 
	@BatchCountOverThreshold				int					= NULL, 
	@PrintOnly								bit = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @CpuOverPercentageThreshold = NULLIF(@CpuOverPercentageThreshold, 0);
	SET @PleUnderThreshold = NULLIF(@PleUnderThreshold, 0);
	SET @BatchCountOverThreshold = NULLIF(@BatchCountOverThreshold, 0);

	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;
	
	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @SourceTable, 
		@ParameterNameForTarget = N'@SourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 

	IF (ISNULL(@CpuOverPercentageThreshold, 0) + ISNULL(@PleUnderThreshold, 0) + ISNULL(@BatchCountOverThreshold, 0)) = 0 BEGIN 
		RAISERROR(N'At least 1 @xxxThreshold value must be specified - otherwise, simply run { SELECT * FROM %s }.', 16, 1, @normalizedName);
		RETURN -20;
	END;
	
	DECLARE @targetDB sysname = PARSENAME(@normalizedName, 3);

	DECLARE @template nvarchar(MAX) = N'SELECT 
	{Projection}	
FROM 
	{normalizedTable} 
WHERE 
	{CPU}
	{PLE}
	{BatchCount}
ORDER BY 
	[timestamp]'

	DECLARE @countOfThresholds int = 0;
	DECLARE @cpu nvarchar(MAX) = N'';
	DECLARE @ple nvarchar(MAX) = N'';
	DECLARE @batchCount nvarchar(MAX) = N'';

	DECLARE @sql nvarchar(MAX);

	DECLARE @clrf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);
	
	IF @CpuOverPercentageThreshold IS NOT NULL BEGIN 
		SET @cpu = N'percentage_used >= ' + CAST(@CpuOverPercentageThreshold AS sysname) + N' ';
		
		SET @countOfThresholds = @countOfThresholds + 1;
	END;

	IF @PleUnderThreshold IS NOT NULL BEGIN 

		SET @sql = N'SELECT 
			@ple = @ple + [name] + N'' <= '' + CAST(@PleUnderThreshold as sysname) + N'' OR ''
		FROM 
			[' + @targetDB + N'].sys.columns 
		WHERE 
			[object_id] = OBJECT_ID(''' + @normalizedName + N''')
			AND [name] LIKE N''ple_node_%''; ';


		EXEC sys.[sp_executesql]
			@sql, 
			N'@ple nvarchar(MAX) OUTPUT, @PleUnderThreshold int', 
			@ple = @ple OUTPUT, 
			@PleUnderThreshold = @PleUnderThreshold;

		SET @ple = N'( ' + LEFT(@ple, LEN(@ple) - 3) + N' ) ';
		IF @countOfThresholds > 0 SET @ple = N'AND ' + @ple;

		SET @countOfThresholds = @countOfThresholds + 1;
	END;

	IF @BatchCountOverThreshold IS NOT NULL BEGIN 

		SET @batchCount = N'[batch_requests\sec] >= ' + CAST((CAST(@BatchCountOverThreshold AS decimal(23,2))) AS sysname) + N' ';
		IF @countOfThresholds > 0 SET @batchCount = N'AND ' + @batchCount;

		SET @countOfThresholds = @countOfThresholds + 1;
	END;

	DECLARE @columns nvarchar(MAX) = N'
	[server_name],
	[timestamp],
	[percentage_used] [cpu_percent_used],
	[ple_node_001],
	[ple_node_000],
	[lazy_writes/sec],
	[page_lookups/sec],
	[page_reads/sec],
	[pages_writes/sec],
	[readahead_pages/sec],
	[avg_latch_time(ms)],
	[latch_waits\sec],
	[total_latch_wait(ms)],
	[lock_requests\sec],
	[lock_timeouts\sec],
	[lock_wait(ms)],
	[lock_waits\sec],
	[deadlocks\sec],
	[connection_mem],
	[granted_workspace],
	[active_grants],
	[pending_grants],
	[target_mem],
	[total_mem],
	[batch_requests\sec],
	[attention_rate],
	[compilations\sec],
	[recompilations\sec] ';

	IF @IncludeAllCpus = 1 BEGIN 
		SET @columns = N'*'  -- bit of a hack, but easier than determining how many CPU/processor# columns to include... 
	END;

	SET @sql = REPLACE(@template, N'{normalizedTable}', @normalizedName); 
	SET @sql = REPLACE(@sql, N'{Projection}', @columns);
	SET @sql = REPLACE(@sql, N'{CPU}', @cpu);
	SET @sql = REPLACE(@sql, N'{PLE}', @ple);
	SET @sql = REPLACE(@sql, N'{BatchCount}', @batchCount);

	IF @PrintOnly = 1 BEGIN 
		EXEC dbo.[print_long_string] @sql;
	  END; 
	ELSE BEGIN 
		EXEC sys.[sp_executesql] @sql;
	END;
		
	RETURN 0;

GO