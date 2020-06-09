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




	SAMPLE EXECUTIONS: 
	
			EXEC [admindb].dbo.report_io_percent_of_percent_load 
				@MetricsSourceTable = N'NA4_IOPS_Sizing3', 
				@TargetDisks = N'D,E,G';


			EXEC [admindb].dbo.report_io_percent_of_percent_load 
				@MetricsSourceTable = N'NA4_IOPS_Sizing3', 
				@TargetDisks = N'D,E,G',
				@TargetThresholds = N'D:3000:250, E:2400:250, G:3000:250';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_io_percent_of_percent_load','P') IS NOT NULL
	DROP PROC dbo.[report_io_percent_of_percent_load];
GO

CREATE PROC dbo.[report_io_percent_of_percent_load]
	@MetricsSourceTable				sysname, 
	@TargetDisks					sysname				= N'{ALL}', 
	@TargetThresholds				nvarchar(MAX)		= NULL,
	@ExcludePerfmonTotal			bit					= 1,						
	@IncludeContinuityHeader		bit					= 0
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

	-------------------------------------------------------------------------------------------------------------------------
	-- Translate Targetting Constraints (if present): 
	DECLARE @targetsPresent bit = 0;

	IF NULLIF(@TargetThresholds, N'') IS NOT NULL BEGIN 

		CREATE TABLE #targets (
			row_id int NOT NULL, 
			drive_letter sysname NOT NULL, 
			target_iops decimal(24,2) NOT NULL, 
			target_mbps decimal(24,2) NOT NULL
		);

		INSERT INTO [#targets] (
			[row_id],
			[drive_letter],
			[target_iops],
			[target_mbps]
		)
		EXEC admindb.dbo.[shred_string] 
			@Input = @TargetThresholds, 
			@RowDelimiter = N',', 
			@ColumnDelimiter = N':';
		
		IF EXISTS (SELECT NULL FROM [#targets]) BEGIN
			SET @targetsPresent = 1;

		END;

	END;

	-------------------------------------------------------------------------------------------------------------------------

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


		IF @ExcludePerfmonTotal = 1 BEGIN 
			DELETE FROM @drives WHERE [simplified] = N'_Total';
		END;

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
		##translated_io_metrics
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


	IF OBJECT_ID('tempdb..##translated_io_metrics') IS NOT NULL BEGIN
		DROP TABLE ##translated_io_metrics;
	END;

	EXEC sp_executesql @statement;

	-------------------------------------------------------------------------------------------------------------------------
	-- convert ##translated_io_metrics to #translated_metrics: 
	IF OBJECT_ID('tempdb..##translated_io_metrics') IS NOT NULL BEGIN
		SELECT * INTO #translated_metrics FROM ##translated_io_metrics;

		DROP TABLE ##translated_io_metrics;
	END;

	DECLARE @serverName sysname = REPLACE(@hostNamePrefix, N'\', N'');

	-------------------------------------------------------------------------------------------------------------------------
-- TODO: push into a sub-sproc that EXPECTS and uses #translated_metrics for re-use purposes... (assuming that #temp-table is visable in 'sub-sprocs'
	IF @IncludeContinuityHeader = 1 BEGIN 

		DECLARE @startTime datetime, @endTime datetime;
		DECLARE @largeGaps int;
		DECLARE @smallGapsSum int; 

		SELECT 
			@startTime = MIN([timestamp]), 
			@endTime = MAX([timestamp])
		FROM 
			#translated_metrics
		WHERE 
			[timestamp] IS NOT NULL;

		WITH core AS ( 
			SELECT 
				[timestamp], 
				ROW_NUMBER() OVER (ORDER BY [timestamp]) [row_number]
			FROM 
				#translated_metrics
		) 

		SELECT 
			ROW_NUMBER() OVER(ORDER BY c1.[timestamp]) [gap_id],
			c1.[timestamp] [gap_start], 
			c2.[timestamp] [gap_end], 
			DATEDIFF(MILLISECOND, c1.[timestamp], c2.[timestamp]) [gap_duration_ms]
		INTO 
			#gaps
		FROM 
			core c1 
			INNER JOIN core c2 ON c1.[row_number] + 1 = c2.[row_number] 
		WHERE 
			DATEDIFF(MILLISECOND, c1.[timestamp], c2.[timestamp]) > 1200
		ORDER BY 
			c1.[row_number];


		SELECT @largeGaps = SUM(gap_duration_ms) FROM [#gaps] WHERE [gap_duration_ms] > 30000;
		SELECT @smallGapsSum = SUM(gap_duration_ms) FROM [#gaps] WHERE [gap_duration_ms] < 30000;

		SELECT 
			@serverName [server_name],
			@startTime [start_time],
			@endTime [end_time], 
			DATEDIFF(SECOND, @startTime, @endTime) [total_seconds], 
			@largeGaps / 1000 [large_gap_seconds], 
			@smallGapsSum / 1000 [aggregate_small_gap_seconds], 
			(DATEDIFF(SECOND, @startTime, @endTime)) - (@largeGaps / 1000) - (@smallGapsSum / 1000) [exact_seconds]


		SELECT * FROM [#gaps] ORDER BY [gap_id];

	END;
	   
	-------------------------------------------------------------------------------------------------------------------------
	-- begin processing/assessing outputs: 

	DECLARE @maxIOPs decimal(24,2);
	DECLARE @maxThroughput decimal(24,2);
	DECLARE @totalRows decimal(24,2); 
	DECLARE @comparedIOPs decimal(24,2);
	DECLARE @comparedThroughput decimal(24,2);

	CREATE TABLE #results ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		server_name sysname NOT NULL, 
		metric_type sysname NOT NULL, 
		drive sysname NOT NULL,
		peak_value sysname NOT NULL, 
		target_value sysname NULL,
		[< 10% usage] decimal(24,2) NOT NULL,
		[10-20% usage] decimal(24,2) NOT NULL,
		[20-40% usage] decimal(24,2) NOT NULL,
		[40-60% usage] decimal(24,2) NOT NULL,
		[60-90% usage] decimal(24,2) NOT NULL,
		[90-98% usage] decimal(24,2) NOT NULL,
		[99-100% usage] decimal(24,2) NOT NULL,
		[101-110% usage] decimal(24,2) NULL,
		[111-120% usage] decimal(24,2) NULL,
		[121%+ usage] decimal(24,2) NULL
	);

	DECLARE @maxTemplate nvarchar(MAX) = N'SELECT 
		@totalRows = COUNT(*), 
		@maxIOPs = MAX([IOPs.{driveName}]), 
		@maxThroughput = MAX([MB Throughput.{driveName}])
	FROM 
		[#translated_metrics]; ';

	DECLARE @aggregateIOPsTemplate nvarchar(MAX) = N'WITH partitioned AS ( 

		SELECT 
			CASE WHEN ([IOPs.{driveName}] <= (@comparedIOPs * .1)) THEN 1 ELSE 0 END [< 10% usage],
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * .1)) AND  ([IOPs.{driveName}] <= (@comparedIOPs * .2)) THEN 1 ELSE 0 END [10-20% usage],
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * .2)) AND  ([IOPs.{driveName}] <= (@comparedIOPs * .4)) THEN 1 ELSE 0 END [20-40% usage], 
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * .4)) AND  ([IOPs.{driveName}] <= (@comparedIOPs * .6)) THEN 1 ELSE 0 END [40-60% usage], 
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * .6)) AND  ([IOPs.{driveName}] <= (@comparedIOPs * .9)) THEN 1 ELSE 0 END [60-90% usage],
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * .9)) AND ([IOPs.{driveName}] <= (@comparedIOps * .98)) THEN 1 ELSE 0 END [90-98% usage],
			
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * .98)){boundaryCondition}THEN 1 ELSE 0 END [99-100% usage],
						
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * 1)) AND ([IOPs.{driveName}] <= (@comparedIOps * 1.1)) THEN 1 ELSE 0 END [101-110% usage],
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * 1.1)) AND ([IOPs.{driveName}] <= (@comparedIOps * 1.2)) THEN 1 ELSE 0 END [111-120% usage],
			CASE WHEN ([IOPs.{driveName}] > (@comparedIOPs * 1.2)) THEN 1 ELSE 0 END [121%+ usage]

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
			CAST(((SUM([99-100% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [99-100% usage],
			
			CAST(((SUM([101-110% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [101-110% usage],
			CAST(((SUM([111-120% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [111-120% usage],
			CAST(((SUM([121%+ usage]) / @totalRows) * 100.00) AS decimal(24,2)) [121%+ usage]

		FROM 
			[partitioned]
	) 

	SELECT
		@serverName [server], 
		N''IOPs'' [metric_type], 
		N''{driveName}'' [drive],
		CAST(@maxIOPs AS sysname) + N'' IOPs'' [peak_value],
		CAST(@targetIOPs AS sysname) + N'' IOPs'' [target_value],
		[aggregated].[< 10% usage],
		[aggregated].[10-20% usage],
		[aggregated].[20-40% usage],
		[aggregated].[40-60% usage],
		[aggregated].[60-90% usage],
		[aggregated].[90-98% usage],
		[aggregated].[99-100% usage],

		[aggregated].[101-110% usage],
		[aggregated].[111-120% usage],
		[aggregated].[121%+ usage]
	FROM 
		[aggregated]; ';

	DECLARE @aggregateMBsTemplate nvarchar(MAX) = N'WITH partitioned AS ( 

		SELECT 
			CASE WHEN ([MB Throughput.{driveName}] <= (@comparedThroughput * .1)) THEN 1 ELSE 0 END [< 10% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * .1)) AND  ([MB Throughput.{driveName}] <= (@comparedThroughput * .2)) THEN 1 ELSE 0 END [10-20% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * .2)) AND  ([MB Throughput.{driveName}] <= (@comparedThroughput * .4)) THEN 1 ELSE 0 END [20-40% usage], 
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * .4)) AND  ([MB Throughput.{driveName}] <= (@comparedThroughput * .6)) THEN 1 ELSE 0 END [40-60% usage], 
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * .6)) AND  ([MB Throughput.{driveName}] <= (@comparedThroughput * .9)) THEN 1 ELSE 0 END [60-90% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * .91)) AND ([MB Throughput.{driveName}] <= (@comparedThroughput * .98)) THEN 1 ELSE 0 END [90-98% usage],
			
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * .98)){boundaryCondition}THEN 1 ELSE 0 END [99-100% usage],
			
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * 1.01)) AND ([MB Throughput.{driveName}] <= (@comparedThroughput * 1.1)) THEN 1 ELSE 0 END [101-110% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * 1.11)) AND ([MB Throughput.{driveName}] <= (@comparedThroughput * 1.2)) THEN 1 ELSE 0 END [111-120% usage],
			CASE WHEN ([MB Throughput.{driveName}] > (@comparedThroughput * 1.2)) THEN 1 ELSE 0 END [121%+ usage]

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
			CAST(((SUM([99-100% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [99-100% usage],
			
			CAST(((SUM([101-110% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [101-110% usage],
			CAST(((SUM([111-120% usage]) / @totalRows) * 100.00) AS decimal(24,2)) [111-120% usage],
			CAST(((SUM([121%+ usage]) / @totalRows) * 100.00) AS decimal(24,2)) [121%+ usage]

		FROM 
			[partitioned]
	) 


	SELECT
		@serverName [server], 
		N''Throughput'' [metric_type], 
		N''{driveName}'' [drive],
		CAST(@maxThroughput AS sysname) + N'' MB/s'' [peak_value],
		CAST(@targetThroughput AS sysname) + N'' MB/s'' [target_value],
		[aggregated].[< 10% usage],
		[aggregated].[10-20% usage],
		[aggregated].[20-40% usage],
		[aggregated].[40-60% usage],
		[aggregated].[60-90% usage],
		[aggregated].[90-98% usage],
		[aggregated].[99-100% usage],

		[aggregated].[101-110% usage],
		[aggregated].[111-120% usage],
		[aggregated].[121%+ usage]
	FROM 
		[aggregated]; ';

	DECLARE @driveName sysname;
	DECLARE @targetIOPs decimal(24,2) = 0;
	DECLARE @targetThroughput decimal(24,2) = 0; 
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

		-----------------------------------------------------------------------------------
		-- account for targeted metrics vs peak metrics:
		IF @targetsPresent = 1 BEGIN

			IF @driveName = N'_Total' BEGIN 
				SELECT 
					@targetIOPs = SUM([target_iops]), 
					@targetThroughput = SUM([target_mbps])
				FROM 
					[#targets]
			  END; 
			ELSE BEGIN
				SELECT 
					@targetIOPs = ISNULL([target_iops], @maxIOPs), 
					@targetThroughput = ISNULL([target_mbps], @maxThroughput)
				FROM 
					[#targets]
				WHERE 
					[drive_letter] = @driveName;
			END;

			SET @comparedIOPs = @targetIOPs;
			SET @comparedThroughput = @targetThroughput;

			SET @aggregateIOPsTemplate = REPLACE(@aggregateIOPsTemplate, N'{boundaryCondition}', N' AND ([IOPs.{driveName}] <= (@comparedIOps * 1)) ');
			SET @aggregateMBsTemplate = REPLACE(@aggregateMBsTemplate, N'{boundaryCondition}', N' AND ([IOPs.{driveName}] <= (@comparedThroughput * 1)) ');

		  END;
		ELSE BEGIN -- using peak metrics for % of % used... 
			SET @comparedIOPs = @maxIOPs;
			SET @comparedThroughput = @maxThroughput;

			SET @aggregateIOPsTemplate = REPLACE(@aggregateIOPsTemplate, N'{boundaryCondition}', N'');
			SET @aggregateMBsTemplate = REPLACE(@aggregateMBsTemplate, N'{boundaryCondition}', N'');

		END;


		-----------------------------------------------------------------------------------
		-- calculate IOPs:

		SET @sql = REPLACE(@aggregateIOPsTemplate,  N'{driveName}', @driveName); 

		INSERT INTO [#results] (
			[server_name],
			[metric_type],
			[drive],
			[peak_value],
			[target_value],
			[< 10% usage],
			[10-20% usage],
			[20-40% usage],
			[40-60% usage],
			[60-90% usage],
			[90-98% usage],
			[99-100% usage], 
			[101-110% usage], 
			[111-120% usage], 
			[121%+ usage]
		)
		EXEC sp_executesql 
			@sql, 
			N'@maxIOPs decimal(24,2), @targetIOPs decimal(24,2), @comparedIOPs decimal(24,2), @totalRows decimal(24,2), @serverName sysname', 
			@maxIOPs = @maxIOPs, 
			@targetIOPs = @targetIOPs, 
			@comparedIOPs = @comparedIOPs,
			@totalRows = @totalRows, 
			@serverName = @serverName;


		-----------------------------------------------------------------------------------
		-- calculate Throughput:

		SET @sql = REPLACE(@aggregateMBsTemplate, N'{driveName}', @driveName); 

		INSERT INTO [#results] (
			[server_name],
			[metric_type],
			[drive],
			[peak_value],
			[target_value],
			[< 10% usage],
			[10-20% usage],
			[20-40% usage],
			[40-60% usage],
			[60-90% usage],
			[90-98% usage],
			[99-100% usage], 
			[101-110% usage], 
			[111-120% usage], 
			[121%+ usage]
		)
		EXEC sp_executesql 
			@sql, 
			N'@maxThroughput decimal(24,2), @targetThroughput decimal(24,2), @comparedThroughput decimal(24,2), @totalRows decimal(24,2), @serverName sysname', 
			@maxThroughput = @maxThroughput, 
			@targetThroughput = @targetThroughput, 
			@comparedThroughput = @comparedThroughput,
			@totalRows = @totalRows, 
			@serverName = @serverName;

		FETCH NEXT FROM [walker] INTO @driveName;
	END;

	CLOSE [walker];
	DEALLOCATE [walker];

	DECLARE @projectionTemplate nvarchar(MAX) = N'SELECT 
		[server_name],
		[drive],
		[metric_type],
		[peak_value],
		{target_value}
		N'''' [ ],
		[< 10% usage],
		[10-20% usage],
		[20-40% usage],
		[40-60% usage],
		[60-90% usage],
		[90-98% usage],
		[99-100% usage] 
		{targetOverages}
	FROM 
		[#results]
	ORDER BY 
		[metric_type], 
		[row_id]; ';

	SET @sql = @projectionTemplate; 

	IF @targetsPresent = 1 BEGIN 
		
		SET @sql = REPLACE(@sql, N'{target_value}', N'[target_value],');
		SET @sql = REPLACE(@sql, N'{targetOverages}', N',[101-110% usage],
		[111-120% usage],
		[121%+ usage]');

	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{target_value}', N'');
		SET @sql = REPLACE(@sql, N'{targetOverages}', N'');
	END;

	EXEC sp_executesql @sql;

	RETURN 0;
GO