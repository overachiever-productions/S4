/*

	vNEXT: 
		look at potentially impossing optional @Thresholds into play for disks. 
			e.g., let's say that the output of the sample execution below shows that 
				drive D is hitting 12K IOPs and doing 898MB/sec... 
				it'd be NICE to put in something like: 
					@ThresholdsForD = N'500MB and 7000 IOPs'
						obviously... that's a LAME way of specifying those values ... FIGURING OUT HOW TO specify those inputs would, hands-down, be the hardest part here
							but... let's assume i use xml or something ... 

						Point is, it'd be nice to run this wil NO thresholds/limits and see 'real' perf
							then run with caps/limits specified - to see what those artificial limits would do in terms of how frequently (what percent) of the time we'd be in the 98+ range
										and... at that point in a 100%+ range as well
											that way... if we ran the numbers with the thresholds listed above and saw that we were running .2% of the time at 99%+ and .1% of the time at 100%+ 
												we'd know we could safely drop down to 500MB and 7K IOPs
													whereas... if those numbers were 8% of the time and 5% of the time... we'd know that this would cause major issues.... 




	SAMPLE EXECUTION: 
	
		EXEC [admindb].dbo.report_io_percent_of_percent_load 
			@MetricsSourceTable = N'FIS_IOPS_Metrics', 
			@TargetDisks = N'D,E,G';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_io_percent_of_percent_load','P') IS NOT NULL
	DROP PROC dbo.[report_io_percent_of_percent_load];
GO

CREATE PROC dbo.[report_io_percent_of_percent_load]
	@MetricsSourceTable			sysname, 
	@TargetDisks				sysname		= N'{ALL}'
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TargetDisks = ISNULL(NULLIF(@TargetDisks, N''), N'{ALL}');

	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @MetricsSourceTable, 
		@ParameterNameForTarget = N'@MetricsSourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 

	DECLARE @targetDBName sysname = PARSENAME(@normalizedName, 3);
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX);

	DECLARE @sampleRow nvarchar(200);

	SET @sql = N'SET @sampleRow = (SELECT TOP 1 [name] FROM [' + @targetDBName + N'].sys.[all_columns] WHERE [object_id] = OBJECT_ID(''' + @normalizedName + N''') AND [name] LIKE ''%Disk Read Bytes/sec''); ';
	EXEC sp_executesql 
		@sql, 
		N'@sampleRow nvarchar(200) OUTPUT',
		@sampleRow = @sampleRow OUTPUT;

	DECLARE @hostNamePrefix sysname; 
	DECLARE @instanceNamePrefix sysname;
	SET @hostNamePrefix = LEFT(@sampleRow, CHARINDEX(N'\PhysicalDisk', @sampleRow));

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

	DECLARE @drives table (
		row_id int IDENTITY(1,1) NOT NULL, 
		drive sysname NOT NULL, 
		simplified sysname NULL
	); 

	SET @sql = N'WITH core AS ( 
		SELECT 
			column_id,
			REPLACE(name, @hostNamePrefix, N'''') [name]
		FROM 
			[' + @targetDBName + N'].sys.[all_columns] 
		WHERE 
			[object_id] = OBJECT_ID(''' + @normalizedName + N''')
			AND [name] LIKE ''%Disk Read Bytes/sec''
	) 

	SELECT 
		REPLACE(REPLACE([name], ''PhysicalDisk('', ''''), N'')\Disk Read Bytes/sec'', N'''') [drive]
	FROM 
		core; ';

	INSERT INTO @drives ([drive])
	EXEC sp_executesql 
		@sql,
		N'@hostNamePrefix sysname', 
		@hostNamePrefix = @hostNamePrefix;


	UPDATE @drives
	SET 
		[simplified] = REPLACE(REPLACE(drive, LEFT(drive,  CHARINDEX(N' ', drive)), N''), N':', N'');

	-- Implement drive filtering: 
	IF UPPER(@TargetDisks) <> N'{ALL}' BEGIN 

		DELETE d 
		FROM 
			@drives d 
			LEFT OUTER JOIN ( 
				SELECT 
					[result]
				FROM 
					admindb.dbo.split_string(@TargetDisks, N',', 1)

				UNION 
					
				SELECT 
					N'_Total' [result]				
			) x ON d.[simplified] = x.[result] 
		WHERE 
			x.[result] IS NULL;

	END;

	DECLARE @statement nvarchar(MAX) = N'
	WITH translated AS (
		SELECT 
			TRY_CAST([{timeZone}] as datetime) [timestamp],
			TRY_CAST([\\{HostName}\Processor(_Total)\% Processor Time]  as decimal(10,2)) [% CPU],
			TRY_CAST([{InstanceName}Buffer Manager\Page life expectancy] as int) [PLE],
			TRY_CAST([{InstanceName}SQL Statistics\Batch Requests/sec] as decimal(22,2)) [batches/second],
        
			{ReadBytes}
			{WriteBytes}
			{MSPerRead}
			{MSPerWrite}
			{ReadsPerSecond}
			{WritesPerSecond}
		FROM 
			{TableName}
	), 
	aggregated AS (
		SELECT 
			[timestamp],
			[% CPU],
			[PLE],
			[batches/second],   

			{AggregatedThroughput}
			{AggregatedIOPS}
			{AggregatedLatency}

			, (SELECT MAX(latency) FROM (VALUES {PeakLatency}) AS x(latency)) [PeakLatency]
		FROM 
			translated 
	)

	SELECT 
		[timestamp],
		[% CPU],
		[PLE],
		[batches/second],

		{Throughput}
		{IOPS}
		{Latency},
		[PeakLatency]
	INTO 
		##translated_metrics
	FROM 
		[aggregated]; ';

	------------------------------------------------------------------------------------------------------------
	-- Raw Data / Extraction (from nvarchar(MAX) columns).
	------------------------------------------------------------------------------------------------------------
	--------------------------------
	-- ReadBytes
	DECLARE @ReadBytes nvarchar(MAX) = N'';
	SELECT 
		@ReadBytes = @ReadBytes + N'TRY_CAST([\\{HostName}\PhysicalDisk(' + drive + N')\Disk Read Bytes/sec] as decimal(22,2)) [ReadBytes.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{ReadBytes}', @ReadBytes);

	--------------------------------
	-- WriteBytes
	DECLARE @WriteBytes nvarchar(MAX) = N'';
	SELECT 
		@WriteBytes = @WriteBytes + N'TRY_CAST([\\{HostName}\PhysicalDisk(' + drive + N')\Disk Write Bytes/sec] as decimal(22,2)) [WriteBytes.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{WriteBytes}', @WriteBytes);

	--------------------------------
	-- MSPerRead
	DECLARE @MSPerRead nvarchar(MAX) = N'';
	SELECT 
		@MSPerRead = @MSPerRead + N'TRY_CAST([\\{HostName}\PhysicalDisk(' + drive + N')\Avg. Disk sec/Read] as decimal(22,2)) [MSPerRead.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives
	WHERE 
		[drive] <> '_Total';

	SET @statement = REPLACE(@statement, N'{MSPerRead}', @MSPerRead);

	--------------------------------
	-- MSPerWrite
	DECLARE @MSPerWrite nvarchar(MAX) = N'';
	SELECT 
		@MSPerWrite = @MSPerWrite + N'TRY_CAST([\\{HostName}\PhysicalDisk(' + drive + N')\Avg. Disk sec/Write] as decimal(22,2)) [MSPerWrite.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives
	WHERE 
		[drive] <> '_Total';

	SET @statement = REPLACE(@statement, N'{MSPerWrite}', @MSPerWrite);

	--------------------------------
	-- ReadsPerSecond
	DECLARE @ReadsPerSecond nvarchar(MAX) = N'';
	SELECT 
		@ReadsPerSecond = @ReadsPerSecond + N'TRY_CAST([\\{HostName}\PhysicalDisk(' + drive + N')\Disk Reads/sec] as decimal(22,2)) [ReadsPerSecond.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{ReadsPerSecond}', @ReadsPerSecond);

	--------------------------------
	-- WritesPerSecond
	DECLARE @WritesPerSecond nvarchar(MAX) = N'';
	SELECT 
		@WritesPerSecond = @WritesPerSecond + N'TRY_CAST([\\{HostName}\PhysicalDisk(' + drive + N')\Disk Writes/sec] as decimal(22,2)) [WritesPerSecond.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @WritesPerSecond = LEFT(@WritesPerSecond, LEN(@WritesPerSecond) - 5);  -- tabs/etc.... 
	SET @statement = REPLACE(@statement, N'{WritesPerSecond}', @WritesPerSecond);

	------------------------------------------------------------------------------------------------------------
	-- Aggregated Data
	------------------------------------------------------------------------------------------------------------
	--------------------------------
	-- AggregatedThroughput
	DECLARE @AggregatedThroughput nvarchar(MAX) = N'';
	SELECT 
		@AggregatedThroughput = @AggregatedThroughput + N'CAST(([ReadBytes.' + simplified + N'] + [WriteBytes.' + simplified + N']) /  (1024.0 * 1024.0) as decimal(20,2)) [Throughput.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{AggregatedThroughput}', @AggregatedThroughput);

	--------------------------------
	-- AggregatedIOPS
	DECLARE @AggregatedIOPS nvarchar(MAX) = N'';
	SELECT 
		@AggregatedIOPS = @AggregatedIOPS + N'[ReadsPerSecond.' + simplified + N'] + [WritesPerSecond.' + simplified + N'] [IOPs.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{AggregatedIOPS}', @AggregatedIOPS);

	--------------------------------
	-- AggregatedLatency
	DECLARE @AggregatedLatency nvarchar(MAX) = N'';
	SELECT 
		@AggregatedLatency = @AggregatedLatency + N'[MSPerRead.' + simplified + N'] + [MSPerWrite.' + simplified + N'] [Latency.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives
	WHERE 
		[drive] <> '_Total';

	SET @AggregatedLatency = LEFT(@AggregatedLatency, LEN(@AggregatedLatency) - 5);  -- tabs/etc.... 
	SET @statement = REPLACE(@statement, N'{AggregatedLatency}', @AggregatedLatency);


	DECLARE @PeakLatency nvarchar(MAX) = N'';

	SELECT 
		@PeakLatency = @PeakLatency + N'([MSPerRead.' + simplified + N'] + [MSPerWrite.' + simplified + N']), '
	FROM 
		@drives 
	WHERE 
		[drive] <> '_Total';

	SET @PeakLatency = LEFT(@PeakLatency, LEN(@PeakLatency) - 1);

	SET @statement = REPLACE(@statement, N'{PeakLatency}', @PeakLatency);
	
	------------------------------------------------------------------------------------------------------------
	-- Final Projection Details: 
	------------------------------------------------------------------------------------------------------------
	--------------------------------
	-- Throughput
	DECLARE @Throughput nvarchar(MAX) = N'';
	SELECT 
		@Throughput = @Throughput + N'[Throughput.' + simplified + N'] [MB Throughput.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{Throughput}', @Throughput);

	--------------------------------
	-- IOPs
	DECLARE @IOPs nvarchar(MAX) = N'';
	SELECT 
		@IOPs = @IOPs + N'[IOPs.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SET @statement = REPLACE(@statement, N'{IOPs}', @IOPs);

	--------------------------------
	-- Latency
	DECLARE @Latency nvarchar(MAX) = N'';
	SELECT 
		@Latency = @Latency + N'[Latency.' + simplified + N'],' + @crlf + @tab + @tab
	FROM 
		@drives
	WHERE 
		[drive] <> '_Total'; -- averages out latencies over ALL drives - vs taking the MAX... (so... we'll have to grab [peak/max).

	SET @Latency = LEFT(@Latency, LEN(@Latency) - 5);  -- tabs/etc.... 
	SET @statement = REPLACE(@statement, N'{Latency}', @Latency);

	--------------------------------
	-- TOP + ORDER BY + finalization... 

	SET @statement = REPLACE(@statement, N'{timeZone}', @timeZone);
	SET @statement = REPLACE(@statement, N'{HostName}', REPLACE(@hostNamePrefix, N'\', N''));
	SET @statement = REPLACE(@statement, N'{InstanceName}', @instanceNamePrefix);
	SET @statement = REPLACE(@statement, N'{TableName}', @normalizedName);

	--EXEC admindb.dbo.[print_long_string] @statement;
	
	-- vNEXT: rather than playing with ##global temp tables... I think the following approach would be a better option - it'll need some decent help though
	--		not JUST in terms of creating the T-SQL needed to create the #translated_metrics table... but... also in terms of the INSERT INTO (will, have, to, specify, column, names) angle of things
	--			OTEHRWISE, if I TRY to use 'shortcut syntax' I run the risk of things getting garbled on the way in... 
	--DECLARE @tempTableDefinition nvarchar(MAX); 
	--EXEC [admindb].dbo.project_query_to_table_definition
	--	@Command = @sql, 
	--	@Params = N'@hostNamePrefix sysname',
	--	@TableName = N'translated_metrics', 
	--	@Mode = N'TEMP',
	--	@Output = @tempTableDefinition OUTPUT;

	--PRINT @tempTableDefinition;


	IF OBJECT_ID('tempdb..##translated_metrics') IS NOT NULL BEGIN
		DROP TABLE ##translated_metrics;
	END;

	EXEC sp_executesql @statement;

	-------------------------------------------------------------------------------------------------------------------------
	-- convert ##translated_metrics to #translated_metrics: 
	IF OBJECT_ID('tempdb..##translated_metrics') IS NOT NULL BEGIN
		SELECT * INTO #translated_metrics FROM ##translated_metrics;

		DROP TABLE ##translated_metrics;
	END;

	-------------------------------------------------------------------------------------------------------------------------
	-- begin processing/assessing outputs: 

	DECLARE @maxIOPs decimal(24,2);
	DECLARE @maxThroughput decimal(24,2);
	DECLARE @totalRows decimal(24,2); 

	CREATE TABLE #results ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		server_name sysname NOT NULL, 
		metric_type sysname NOT NULL, 
		drive sysname NOT NULL,
		peak_value sysname NOT NULL, 
		[< 10% usage] decimal(24,2) NOT NULL,
		[10-20% usage] decimal(24,2) NOT NULL,
		[20-40% usage] decimal(24,2) NOT NULL,
		[40-60% usage] decimal(24,2) NOT NULL,
		[60-90% usage] decimal(24,2) NOT NULL,
		[90-98% usage] decimal(24,2) NOT NULL,
		[99+% usage] decimal(24,2) NOT NULL
	);

	DECLARE @maxTemplate nvarchar(MAX) = N'SELECT 
		@totalRows = COUNT(*), 
		@maxIOPs = MAX([IOPs.{driveName}]), 
		@maxThroughput = MAX([MB Throughput.{driveName}])
	FROM 
		[#translated_metrics]; ';

	DECLARE @aggregateIOPsTemplate nvarchar(MAX) = N'WITH partitioned AS ( 

		SELECT 
			CASE WHEN  [IOPs.{driveName}] < (@maxIOPs * .1) THEN 1 ELSE 0 END [< 10% usage],
			CASE WHEN ([IOPs.{driveName}] > (@maxIOPs * .1)) AND  ([IOPs.{driveName}] <= (@maxIOPs * .2)) THEN 1 ELSE 0 END [10-20% usage],
			CASE WHEN ([IOPs.{driveName}] > (@maxIOPs * .2)) AND  ([IOPs.{driveName}] <= (@maxIOPs * .4)) THEN 1 ELSE 0 END [20-40% usage], 
			CASE WHEN ([IOPs.{driveName}] > (@maxIOPs * .4)) AND  ([IOPs.{driveName}] <= (@maxIOPs * .6)) THEN 1 ELSE 0 END [40-60% usage], 
			CASE WHEN ([IOPs.{driveName}] > (@maxIOPs * .6)) AND  ([IOPs.{driveName}] <= (@maxIOPs * .9)) THEN 1 ELSE 0 END [60-90% usage],
			CASE WHEN ([IOPs.{driveName}] > (@maxIOPs * .91)) AND ([IOPs.{driveName}] <= (@maxIOps * .98)) THEN 1 ELSE 0 END [90-98% usage],
			CASE WHEN ([IOPs.{driveName}] > (@maxIOPs * .98)) THEN 1 ELSE 0 END [99+% usage]

		FROM 
			[#translated_metrics]

	),
	aggregated AS ( 

		SELECT 
			CAST(((SUM([< 10% usage]) / @totalRows) * 100.00) AS decimal(24,2))  [< 10% usage],
			CAST(((SUM([10-20% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [10-20% usage],
			CAST(((SUM([20-40% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [20-40% usage],
			CAST(((SUM([40-60% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [40-60% usage],
			CAST(((SUM([60-90% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [60-90% usage],
			CAST(((SUM([90-98% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [90-98% usage],
			CAST(((SUM([99+% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [99+% usage]
		FROM 
			[partitioned]
	) 

	SELECT
		@serverName [server], 
		N''IOPs'' [metric_type], 
		N''{driveName}'' [drive],
		CAST(@maxIOPs AS sysname) + N'' IOPs'' [peak_value],
		[aggregated].[< 10% usage],
		[aggregated].[10-20% usage],
		[aggregated].[20-40% usage],
		[aggregated].[40-60% usage],
		[aggregated].[60-90% usage],
		[aggregated].[90-98% usage],
		[aggregated].[99+% usage]
	FROM 
		[aggregated]; ';

	DECLARE @aggregateMBsTemplate nvarchar(MAX) = N'WITH partitioned AS ( 

		SELECT 
			CASE WHEN  [MB Throughput.{driveName}] < (@maxThroughput * .1) THEN 1 ELSE 0 END [< 10% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@maxThroughput * .1)) AND  ([MB Throughput.{driveName}] <= (@maxThroughput * .2)) THEN 1 ELSE 0 END [10-20% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@maxThroughput * .2)) AND  ([MB Throughput.{driveName}] <= (@maxThroughput * .4)) THEN 1 ELSE 0 END [20-40% usage], 
			CASE WHEN ([MB Throughput.{driveName}] > (@maxThroughput * .4)) AND  ([MB Throughput.{driveName}] <= (@maxThroughput * .6)) THEN 1 ELSE 0 END [40-60% usage], 
			CASE WHEN ([MB Throughput.{driveName}] > (@maxThroughput * .6)) AND  ([MB Throughput.{driveName}] <= (@maxThroughput * .9)) THEN 1 ELSE 0 END [60-90% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@maxThroughput * .91)) AND ([MB Throughput.{driveName}] <= (@maxThroughput * .98)) THEN 1 ELSE 0 END [90-98% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@maxThroughput * .98)) THEN 1 ELSE 0 END [99+% usage]

		FROM 
			[#translated_metrics]

	),
	aggregated AS ( 

		SELECT 
			CAST(((SUM([< 10% usage]) / @totalRows) * 100.00) AS decimal(24,2))  [< 10% usage],
			CAST(((SUM([10-20% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [10-20% usage],
			CAST(((SUM([20-40% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [20-40% usage],
			CAST(((SUM([40-60% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [40-60% usage],
			CAST(((SUM([60-90% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [60-90% usage],
			CAST(((SUM([90-98% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [90-98% usage],
			CAST(((SUM([99+% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [99+% usage]
		FROM 
			[partitioned]
	) 


	SELECT
		@serverName [server], 
		N''Throughput'' [metric_type], 
		N''{driveName}'' [drive],
		CAST(@maxThroughput AS sysname) + N'' MB/s'' [peak_value],
		[aggregated].[< 10% usage],
		[aggregated].[10-20% usage],
		[aggregated].[20-40% usage],
		[aggregated].[40-60% usage],
		[aggregated].[60-90% usage],
		[aggregated].[90-98% usage],
		[aggregated].[99+% usage]
	FROM 
		[aggregated]; ';

	DECLARE @driveName sysname;
	DECLARE @serverName sysname = REPLACE(@hostNamePrefix, N'\', N'');

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[simplified]
	FROM 
		@drives
	ORDER BY 
		[row_id];

	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @driveName;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @sql = REPLACE(@maxTemplate, N'{driveName}', @driveName); 

		EXEC sp_executesql 
			@sql, 
			N'@totalRows decimal(24,2) OUTPUT, @maxThroughput decimal(24,2) OUTPUT, @maxIOPs decimal(24,2) OUTPUT', 
			@totalRows = @totalRows OUTPUT, 
			@maxThroughput = @maxThroughput OUTPUT, 
			@maxIOPs = @maxIOPs OUTPUT; 

		SET @sql = REPLACE(@aggregateIOPsTemplate,  N'{driveName}', @driveName); 

		INSERT INTO [#results] (
			[server_name],
			[metric_type],
			[drive],
			[peak_value],
			[< 10% usage],
			[10-20% usage],
			[20-40% usage],
			[40-60% usage],
			[60-90% usage],
			[90-98% usage],
			[99+% usage]
		)
		EXEC sp_executesql 
			@sql, 
			N'@maxIOPs decimal(24,2), @totalRows decimal(24,2), @serverName sysname', 
			@maxIOPs = @maxIOPs, 
			@totalRows = @totalRows, 
			@serverName = @serverName;


		SET @sql = REPLACE(@aggregateMBsTemplate, N'{driveName}', @driveName); 

		INSERT INTO [#results] (
			[server_name],
			[metric_type],
			[drive],
			[peak_value],
			[< 10% usage],
			[10-20% usage],
			[20-40% usage],
			[40-60% usage],
			[60-90% usage],
			[90-98% usage],
			[99+% usage]
		)
		EXEC sp_executesql 
			@sql, 
			N'@maxThroughput decimal(24,2), @totalRows decimal(24,2), @serverName sysname', 
			@maxThroughput = @maxThroughput, 
			@totalRows = @totalRows, 
			@serverName = @serverName;

		FETCH NEXT FROM [walker] INTO @driveName;
	END;

	CLOSE [walker];
	DEALLOCATE [walker];

	SELECT 
		[server_name],
		[metric_type],
		[drive],
		[peak_value],
		N'' [ ],
		[< 10% usage],
		[10-20% usage],
		[20-40% usage],
		[40-60% usage],
		[60-90% usage],
		[90-98% usage],
		[99+% usage] 
	FROM 
		[#results]
	ORDER BY 
		[metric_type], 
		[row_id]; 

	RETURN 0;
GO