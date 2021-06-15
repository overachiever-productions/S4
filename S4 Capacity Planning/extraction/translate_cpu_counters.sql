/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_cpu_counters','P') IS NOT NULL
	DROP PROC dbo.[translate_cpu_counters];
GO

CREATE PROC dbo.[translate_cpu_counters]
	@SourceTable			sysname, 
	@TargetTable			sysname, 
	@OverwriteTarget		bit				= 0, 
	@PrintOnly				bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @SourceTable, 
		@ParameterNameForTarget = N'@SourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 
	
	IF UPPER(@TargetTable) = UPPER(@SourceTable) BEGIN 
		RAISERROR('@SourceTable and @TargetTable can NOT be the same - please specify a new/different name for the @TargetTable parameter.', 16, 1);
		RETURN -1;
	END;

	IF @TargetTable IS NULL BEGIN 
		RAISERROR('Please specify a @TargetTable value - for the output of dbo.translate_cpu_perfcounters', 16, 1); 
		RETURN -2;
	END; 

	-- translate @TargetTable details: 
	SELECT @TargetTable = N'[' + ISNULL(PARSENAME(@TargetTable, 3), PARSENAME(@normalizedName, 3)) + N'].[' + ISNULL(PARSENAME(@TargetTable, 2), PARSENAME(@normalizedName, 2)) + N'].[' + PARSENAME(@TargetTable, 1) + N']';
	
	-- Determine if @TargetTable already exists:
	DECLARE @targetObjectID int;
	DECLARE @check nvarchar(MAX) = N'SELECT @targetObjectID = OBJECT_ID(''' + @TargetTable + N''');'

	EXEC [sys].[sp_executesql] 
		@check, 
		N'@targetObjectID int OUTPUT', 
		@targetObjectID = @targetObjectID OUTPUT; 

	IF @targetObjectID IS NOT NULL BEGIN 
		IF @OverwriteTarget = 1 AND @PrintOnly = 0 BEGIN
			DECLARE @drop nvarchar(MAX) = N'USE [' + PARSENAME(@TargetTable, 3) + N']; DROP TABLE [' + PARSENAME(@TargetTable, 2) + N'].[' + PARSENAME(@TargetTable, 1) + N'];';
			
			EXEC sys.sp_executesql @drop;

		  END;
		ELSE BEGIN
			RAISERROR('@TargetTable %s already exists. Please either drop it manually, or set @OverwriteTarget to a value of 1 during execution of this sproc.', 16, 1);
			RETURN -5;
		END;
	END;

	-------------------------------------------------------------------------------------------------------------------------

	DECLARE @targetDBName sysname = PARSENAME(@normalizedName, 3);
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX);

	DECLARE @sampleRow nvarchar(200);

	SET @sql = N'SET @sampleRow = (SELECT TOP 1 [name] FROM [' + @targetDBName + N'].sys.[all_columns] WHERE [object_id] = OBJECT_ID(''' + @normalizedName + N''') AND column_id > 1);';

	EXEC sp_executesql 
		@sql, 
		N'@sampleRow nvarchar(200) OUTPUT',
		@sampleRow = @sampleRow OUTPUT;

	DECLARE @serverName sysname; 
	DECLARE @instanceNamePrefix sysname;
	
	SET @serverName = SUBSTRING(@sampleRow, 3, LEN(@sampleRow));
	SET @serverName = SUBSTRING(@serverName, 0, CHARINDEX(N'\', @serverName));

	IF NULLIF(@serverName, N'') IS NULL BEGIN 
		RAISERROR(N'Unable to extract Server-Name from input .csv file. Processing cannot continue.', 16, 1);
		RETURN -9;
	END;

	SET @sql = N'SET @sampleRow = (SELECT TOP 1 [name] FROM [' + @targetDBName + N'].sys.[all_columns] WHERE [object_id] = OBJECT_ID(''' + @normalizedName + N''') AND [name] LIKE ''%Batch Requests/sec''); ';
	EXEC sp_executesql 
		@sql, 
		N'@sampleRow nvarchar(200) OUTPUT',
		@sampleRow = @sampleRow OUTPUT;	
		
	SET @instanceNamePrefix = LEFT(@sampleRow, CHARINDEX(N':SQL Statistics', @sampleRow));

	
	DECLARE @timeZone sysname; 
	SET @sql = N'SELECT 
		@timeZone = [name]
	FROM 
		[' + @targetDBName + N'].sys.[columns] 
	WHERE 
		[object_id] = OBJECT_ID(''' + @normalizedName + N''')
		AND [column_id] = 1; ';

	EXEC sp_executesql 
		@sql, 
		N'@timeZone sysname OUTPUT',
		@timeZone = @timeZone OUTPUT;	

	DECLARE @procCountColumnNameValue sysname; 
	DECLARE @totalCoreCount int;	

	SET @sql = N'SELECT @procCountColumnNameValue = [name] FROM [' + @targetDBName + N'].sys.[all_columns] WHERE [object_id] = OBJECT_ID(''' + @normalizedName + N''') AND [column_id] = (
	SELECT MAX(column_id) FROM (
		SELECT 
			[column_id]
		FROM 
			[' + @targetDBName + N'].sys.[all_columns]
		WHERE 
			[object_id] = OBJECT_ID(''' + @normalizedName + N''')
			AND 
				(
					[name] LIKE N''%Processor(%Processor Time'' 
					AND 
					[name] NOT LIKE N''%(_Total)\%''
				)
		) x
); '; 


	EXEC [sys].[sp_executesql] 
		@sql, 
		N'@procCountColumnNameValue sysname OUTPUT', 
		@procCountColumnNameValue = @procCountColumnNameValue OUTPUT;

	SET @procCountColumnNameValue = REPLACE(@procCountColumnNameValue, N')\% Processor Time', N'');
	SET @procCountColumnNameValue = REPLACE(@procCountColumnNameValue, N'\\' + @serverName + N'\Processor(', N'');
	SET @totalCoreCount = CAST(@procCountColumnNameValue AS int) + 1;

	IF NULLIF(@totalCoreCount, 0) IS NULL BEGIN
		RAISERROR('Invalid Metrics Data Detected. Target table %s does NOT provide CPU metrics data.', 16, 1, @normalizedName);
		RETURN -20;
	END;


	DECLARE @statement nvarchar(MAX) = N'WITH [translated] AS ( 
	SELECT
		TRY_CAST([{timeZone}] AS datetime) [timestamp],
{translatedCPUs}		ISNULL(TRY_CAST([\\{serverName}\Processor(_Total)\% Processor Time]  AS decimal(22,2)), 0) [total],
{sqlStats}
	FROM 
		{normalizedName}
),
[aggregated] AS ( 
	SELECT 
		N''{serverName}'' [server_name],
		[timestamp], 
		[total] [percentage_used], 
{aggregatedCPUs} 		(
		SELECT SUM(x.v) FROM (VALUES {cteConstructedAggregateCPUs}) x(v)
		) [total_cpu_used],
{sqlStatsAliases}
	FROM 
		[translated]
)

SELECT 
	* 
INTO 
	{TargetTable}
FROM 
	[aggregated]
ORDER BY 
	[total_cpu_used] DESC; ';


	-- Generate Projection data:
	DECLARE @translatedCPUs nvarchar(MAX) = N'';
	DECLARE @aggregatedCPUs nvarchar(MAX) = N'';
	DECLARE @cteConstructedAggregateCPUs nvarchar(MAX) = N'';
		
	SELECT 
		@translatedCPUs = @translatedCPUs + @tab + @tab + N'ISNULL(TRY_CAST([\\{serverName}\Processor(' + CAST(x.[id] - 1 AS sysname) + N')\% Processor Time] as decimal(22,2)), 0) [processor' + CAST(x.[id] - 1 AS sysname) + N'], ' + @crlf,
		@aggregatedCPUs = @aggregatedCPUs + @tab + @tab + N'[processor' + CAST(x.[id] - 1 AS sysname) + N'], ' + @crlf,
		@cteConstructedAggregateCPUs = @cteConstructedAggregateCPUs + '([processor' + CAST(x.[id] - 1 AS sysname) + N']),'
	FROM 
		(
			SELECT TOP(@totalCoreCount)
				ROW_NUMBER() OVER (ORDER BY [object_id]) [id]	
			FROM 
				sys.objects
		) x
	ORDER BY 
		x.[id];
	
	SET @cteConstructedAggregateCPUs = LEFT(@cteConstructedAggregateCPUs, LEN(@cteConstructedAggregateCPUs) - 1);

	-- Account for SQL Server metrics/translation: 
	DECLARE @sqlMetricsColumns table (
		[column_id] int IDENTITY(1,1) NOT NULL, 
		[raw_name] sysname NOT NULL, 
		[translation] sysname NULL,
		[aliased_name] sysname NOT NULL
	); 

	-- insert N rows for buffer nodes (i.e., PLE metrics per buffer node):
	SET @sql = N'SELECT 
		REPLACE([name], N''\\' +  @serverName + N''', N'''') [name], 
		N''ISNULL(CAST([{c}] as int), 0)'',
		N''ple_node_'' + REPLACE(REPLACE([name], (N''\\' + @serverName + N'\SQLServer:Buffer Node(''), N''''), N'')\Page life expectancy'', N'''')
	FROM 
		' + @targetDBName + N'.sys.columns 
	WHERE 
		[object_id] = OBJECT_ID(''' + @normalizedName + N''')
		AND [name] LIKE N''%Page life expectancy''
	ORDER BY 
		[column_id]; ';

	INSERT INTO @sqlMetricsColumns (
		[raw_name],
		[translation],
		[aliased_name]
	)
	EXEC sp_executesql @sql;

	-- static SQL counters:
	INSERT INTO @sqlMetricsColumns (
		[raw_name], 
		[translation],
		[aliased_name]
	)
	VALUES
	(N'\SQLServer:Buffer Manager\Lazy writes/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'lazy_writes/sec'),
	(N'\SQLServer:Buffer Manager\Page lookups/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'page_lookups/sec'),
	(N'\SQLServer:Buffer Manager\Page reads/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'page_reads/sec'),
	(N'\SQLServer:Buffer Manager\Page writes/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'pages_writes/sec'),
	(N'\SQLServer:Buffer Manager\Readahead pages/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'readahead_pages/sec'),
	(N'\SQLServer:Latches\Average Latch Wait Time (ms)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'avg_latch_time(ms)'),
	(N'\SQLServer:Latches\Latch Waits/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'latch_waits\sec'),
	(N'\SQLServer:Latches\Total Latch Wait Time (ms)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'total_latch_wait(ms)'),
	(N'\SQLServer:Locks(_Total)\Lock Requests/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'lock_requests\sec'),
--MKC: temporary removal... 	
	--(N'\SQLServer:Locks(_Total)\Lock Timeouts (timeout > 0)/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'lock_timeouts\sec'),
	(N'\SQLServer:Locks(_Total)\Lock Wait Time (ms)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'lock_wait(ms)'),
	(N'\SQLServer:Locks(_Total)\Lock Waits/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'lock_waits\sec'),
	(N'\SQLServer:Locks(_Total)\Number of Deadlocks/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'deadlocks\sec'),
	(N'\SQLServer:Memory Manager\Connection Memory (KB)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'connection_mem'),
	(N'\SQLServer:Memory Manager\Granted Workspace Memory (KB)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'granted_workspace'),
	(N'\SQLServer:Memory Manager\Memory Grants Outstanding', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'active_grants'),
	(N'\SQLServer:Memory Manager\Memory Grants Pending', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'pending_grants'),
	(N'\SQLServer:Memory Manager\Target Server Memory (KB)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'target_mem'),
	(N'\SQLServer:Memory Manager\Total Server Memory (KB)', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'total_mem'),
	(N'\SQLServer:SQL Statistics\Batch Requests/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'batch_requests\sec'),
	(N'\SQLServer:SQL Statistics\SQL Attention rate', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'attention_rate'),
	(N'\SQLServer:SQL Statistics\SQL Compilations/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'compilations\sec'),
	(N'\SQLServer:SQL Statistics\SQL Re-Compilations/sec', N'ISNULL(TRY_CAST([{c}] as decimal(24,3)), 0.0)', N'recompilations\sec');

	DECLARE @sqlMetrics nvarchar(MAX) = N''; 

	SELECT 
		@sqlMetrics = @sqlMetrics + @tab + @tab +
		CASE 
			WHEN [translation] IS NULL THEN N'[\\' + @serverName + [raw_name] + N'] [' + [aliased_name] + N'], ' 
			ELSE REPLACE([translation], N'{c}', (N'\\' + @serverName + [raw_name])) + N' [' + [aliased_name] + N'], ' 
		END + @crlf
	FROM 
		@sqlMetricsColumns
	ORDER BY 
		[column_id];

	SET @sqlMetrics = LEFT(@sqlMetrics, LEN(@sqlMetrics) - 4);

	DECLARE @sqlMetricAliases nvarchar(MAX) = N'';
	SELECT 
		@sqlMetricAliases = @sqlMetricAliases + @tab + @tab + QUOTENAME([aliased_name]) + N', ' + @crlf
	FROM 
		@sqlMetricsColumns 
	ORDER BY 
		[column_id];

	SET @sqlMetricAliases = LEFT(@sqlMetricAliases, LEN(@sqlMetricAliases) -4);	

	SET @statement = REPLACE(@statement, N'{normalizedName}', @normalizedName); 
	SET @statement = REPLACE(@statement, N'{timeZone}', @timeZone);
	SET @statement = REPLACE(@statement, N'{translatedCPUs}', @translatedCPUs);
	SET @statement = REPLACE(@statement, N'{aggregatedCPUs}', @aggregatedCPUs);
	SET @statement = REPLACE(@statement, N'{cteConstructedAggregateCPUs}', @cteConstructedAggregateCPUs);
	SET @statement = REPLACE(@statement, N'{sqlStats}', @sqlMetrics);
	SET @statement = REPLACE(@statement, N'{sqlStatsAliases}', @sqlMetricAliases);

	SET @statement = REPLACE(@statement, N'{serverName}', @serverName);
	SET @statement = REPLACE(@statement, N'{TargetTable}', @TargetTable);

	IF @PrintOnly = 1 BEGIN 
		EXEC dbo.[print_long_string] @statement; 
	  END; 
	ELSE BEGIN 
		EXEC sp_executesql @statement;

		SET @statement = N'SELECT COUNT(*) [total_rows_exported] FROM ' + @TargetTable + N'; ';
		EXEC [sys].[sp_executesql] @statement;

	END; 
		
	RETURN 0; 
GO