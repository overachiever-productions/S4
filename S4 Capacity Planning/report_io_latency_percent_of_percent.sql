/*

	NOTE: 
		- Requires execution of dbo.translate_io_perfcounters against RAW/.csv data before IO latency can be calculated. 


	SAMPLE EXECUTION: 
			EXEC [admindb].dbo.[translate_io_perfcounters] 
				@SourceTable = N'XYZA_Sept5_Raw', 
				@TargetTable = N'XYZA_Sept5_IO';

			EXEC [admindb].dbo.report_io_latency_percent_of_percent
				@SourceTable = N'XYZA_Sept5_IO', 
				@TargetDisks = N'D, F, G, H, T';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_io_latency_percent_of_percent','P') IS NOT NULL
	DROP PROC dbo.[report_io_latency_percent_of_percent];
GO

CREATE PROC dbo.[report_io_latency_percent_of_percent]
	@SourceTable					sysname, 
	@TargetDisks					sysname				= N'{ALL}'

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDisks = ISNULL(NULLIF(@TargetDisks, N''), N'{ALL}');

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

	-------------------------------------------------------------------------------------------------------------------------

	DECLARE @targetDBName sysname = PARSENAME(@normalizedName, 3);
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX);

	SET @sql = N'SELECT @serverName = (SELECT TOP 1 [server_name] FROM ' + @normalizedName + N'); ';
	DECLARE @serverName sysname; 
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@serverName sysname OUTPUT', 
		@serverName = @serverName OUTPUT;

	CREATE TABLE #drives (
		row_id int IDENTITY(1,1) NOT NULL, 
		[drive] sysname NOT NULL
	); 

	SET @sql = N'WITH core AS ( 
		SELECT 
			column_id,
			[name]
		FROM 
			[' + @targetDBName + N'].sys.[all_columns] 
		WHERE 
			[object_id] = OBJECT_ID(''' + @normalizedName + N''')
			AND [name] LIKE ''Latency.%''
	) 

	SELECT 
		REPLACE([name], N''Latency.'', '''') [drive]
	FROM 
		core; ';

	INSERT INTO #drives ([drive])
	EXEC sp_executesql 
		@sql;

	-- Implement drive filtering: 
	IF UPPER(@TargetDisks) <> N'{ALL}' BEGIN 

		DELETE d 
		FROM 
			#drives d 
			LEFT OUTER JOIN ( 
				SELECT 
					[result]
				FROM 
					dbo.split_string(@TargetDisks, N',', 1)

				UNION 
					
				SELECT 
					N'_Total' [result]				
			) x ON d.[drive] = x.[result] 
		WHERE 
			x.[result] IS NULL;
	END;

	-------------------------------------------------------------------------------------------------------------------------
	-- begin processing/assessing outputs: 
	CREATE TABLE #results ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[server_name] sysname NOT NULL, 
		[drive] sysname NOT NULL,
		[peak] decimal(24,2) NOT NULL, 
		[average] decimal(24,2) NOT NULL,
		[%_green] decimal(24,2) NOT NULL, 
		[%_yellow] decimal(24,2) NOT NULL, 
		[%_red] decimal(24,2) NOT NULL, 
		[%_swamped] decimal(24,2) NOT NULL
	);

	DECLARE @totalRows int, @maxLatency decimal(24,2), @avgLatency decimal(24,2); 
	DECLARE @aggregateTemplate nvarchar(MAX) = N'SELECT 
		@totalRows = COUNT(*), 
		@maxLatency = MAX([Latency.{driveName}]), 
		@avgLatency = AVG([Latency.{driveName}])
	FROM 
		' + @normalizedName + N'; ';

	DECLARE @driveLatencyTemplate nvarchar(MAX) = N'WITH partitioned AS (
		SELECT 
			CASE WHEN (ISNULL([Latency.{driveName}], .00) <= .08) THEN 1 ELSE 0 END [latency_green],
			CASE WHEN ([Latency.{driveName}] > .08 AND [Latency.{driveName}] <= .2) THEN 1 ELSE 0 END [latency_yellow],
			CASE WHEN ([Latency.{driveName}] > .21 AND [Latency.{driveName}] <= .59) THEN 1 ELSE 0 END [latency_red],
			CASE WHEN ([Latency.{driveName}] > .6) THEN 1 ELSE 0 END [latency_swamped]
		FROM 
			' + @normalizedName + N'
	), 
	aggregated AS ( 
		SELECT 
			CAST(((SUM([latency_green]) / @totalRows) * 100.0) AS decimal(24,2))  [latency_green],
			CAST(((SUM([latency_yellow]) / @totalRows) * 100.0) AS decimal(24,2))  [latency_yellow],
			CAST(((SUM([latency_red]) / @totalRows) * 100.0) AS decimal(24,2))  [latency_red],
			CAST(((SUM([latency_swamped]) / @totalRows) * 100.0) AS decimal(24,2))  [latency_swamped]
		FROM 
			[partitioned]
	) 
		
	SELECT 
		@serverName [server], 
		N''{driveName}'' [drive],
		@maxLatency [peak_latency],
		@avgLatency [avg_latency],
		
		[latency_green],
		[latency_yellow],
		[latency_red],
		[latency_swamped]
	FROM 
		[aggregated]; ';

	DECLARE @driveName sysname;
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[drive]
	FROM 
		#drives
	ORDER BY 
		[row_id];

	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @driveName;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @sql = REPLACE(@aggregateTemplate, N'{driveName}', @driveName); 

		EXEC sys.[sp_executesql] 
			@sql, 
			N'@totalRows int OUTPUT, @maxLatency decimal(24,2) OUTPUT, @avgLatency decimal(24,2) OUTPUT', 
			@totalRows = @totalRows OUTPUT, 
			@maxLatency = @maxLatency OUTPUT, 
			@avgLatency = @avgLatency OUTPUT; 

		SET @sql = REPLACE(@driveLatencyTemplate,  N'{driveName}', @driveName); 

		INSERT INTO [#results] (
			[server_name],
			[drive],
			[peak],
			[average],
			[%_green],
			[%_yellow],
			[%_red],
			[%_swamped]
		)
		EXEC sys.sp_executesql 
			@sql, 
			-- NOTE: _HAVE_ to cast/switch @totalRows to be a decimal... otherwise, /@totalRows(as int) won't give us %.
			N'@serverName sysname, @totalRows decimal(24,2), @maxLatency decimal(24,2), @avgLatency decimal(24,2)', 
			@serverName = @serverName,
			@totalRows = @totalRows, 
			@maxLatency = @maxLatency, 
			@avgLatency = @avgLatency;

		FETCH NEXT FROM [walker] INTO @driveName;
	END;

	CLOSE [walker];
	DEALLOCATE [walker];

	-- Final Projection: 
	SELECT 
		[server_name],
		[drive],
		[peak],
		[average],
		N' ' [ ], 
		N'0-8ms' [green], 
		N'9-20ms' [yellow],
		N'21- 59ms' [red], 
		N'60ms+' [swamped],
		N' ' [_], 
		[%_green],
		[%_yellow],
		[%_red],
		[%_swamped] 
	FROM 
		[#results] 
	ORDER BY 
		[row_id]; 

	RETURN 0; 
GO