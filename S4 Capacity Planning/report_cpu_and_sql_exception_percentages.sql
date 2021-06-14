/*

		Yeah. the name of this sucks... 

		Better naming idea might be: 
			dbo.report_cpu_violation_percentages or ... just dbo.report_cpu_violations


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_cpu_and_sql_exception_percentages','P') IS NOT NULL
	DROP PROC dbo.[report_cpu_and_sql_exception_percentages];
GO

CREATE PROC dbo.[report_cpu_and_sql_exception_percentages]
	@SourceTable							sysname, 
	@CpuOverPercentageThreshold				decimal(5,2)		= NULL,
	@PleUnderThreshold						int					= NULL, 
	@BatchCountOverThreshold				int					= NULL
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
	
	DECLARE @sql nvarchar(MAX); 
	DECLARE @targetDB sysname = PARSENAME(@normalizedName, 3);	
	DECLARE @totalRows int; 

	SET @sql = N'SELECT @totalRows = (SELECT COUNT(*) FROM ' + @normalizedName + N'); ';

	EXEC sys.[sp_executesql]
		@sql, 
		N'@totalRows int OUTPUT', 
		@totalRows = @totalRows OUTPUT;


	DECLARE @serverName sysname;
	SET @sql = N'SELECT @serverName = (SELECT TOP 1 [server_name] FROM ' + @normalizedName + N'); ';
	EXEC sys.[sp_executesql]
		@sql, 
		N'@serverName sysname OUTPUT', 
		@serverName = @serverName OUTPUT;


	DECLARE @startTime datetime, @endTime datetime; 
	SET @sql = N'SELECT @startTime = MIN([timestamp]), @endTime = MAX([timestamp]) FROM '  + @normalizedName + N'; ';
	EXEC sys.[sp_executesql]
		@sql, 
		N'@startTime datetime OUTPUT, @endTime datetime OUTPUT', 
		@startTime = @startTime OUTPUT, 
		@endTime = @endTime OUTPUT;

	DECLARE @cpu nvarchar(MAX) = N'';
	DECLARE @ple nvarchar(MAX) = N'';
	DECLARE @batchCount nvarchar(MAX) = N'';

	IF @CpuOverPercentageThreshold IS NOT NULL BEGIN
		DECLARE @cpuCount int; 

		SET @sql = N'SELECT @cpuCount = (SELECT COUNT(*) FROM ' + @normalizedName + N' WHERE percentage_used >= ' + CAST(@CpuOverPercentageThreshold AS sysname) + N'); ';

		EXEC sys.[sp_executesql]
			@sql, 
			N'@cpuCount int OUTPUT', 
			@cpuCount = @cpuCount OUTPUT;

		SET @cpu = N', ' + CAST(@CpuOverPercentageThreshold AS sysname) + N' [%_cpu_threshold], ' + CAST(@cpuCount AS sysname) + N' [cpu_violations], CAST(((CAST((' + CAST(@cpuCount AS sysname) + N') as decimal(23,2)) / CAST((' + CAST(@totalRows AS sysname) + N') as decimal(23,2))) * 100.0) as decimal(5,2)) [cpu_violations_%]'
	END;


	IF @PleUnderThreshold IS NOT NULL BEGIN
		DECLARE @pleCount int; 
		DECLARE @pleColumns nvarchar(MAX) = N'';

		SET @sql = N'SELECT 
			@pleColumns = @pleColumns + [name] + N'' <= '' + CAST(@PleUnderThreshold as sysname) + N'' OR ''
		FROM 
			[' + @targetDB + N'].sys.columns 
		WHERE 
			[object_id] = OBJECT_ID(''' + @normalizedName + N''')
			AND [name] LIKE N''ple_node_%''; ';

		EXEC sys.[sp_executesql] 
			@sql, 
			N'@PleUnderThreshold int, @pleColumns nvarchar(MAX) OUTPUT', 
			@PleUnderThreshold = @PleUnderThreshold,
			@pleColumns = @pleColumns OUTPUT;

		SET @pleColumns = LEFT(@pleColumns, LEN(@pleColumns) - 3);
		
		SET @sql = N'SELECT @pleCount = (SELECT COUNT(*) FROM ' + @normalizedName + N' WHERE (' + @pleColumns + N')); ';

		EXEC sys.[sp_executesql]
			@sql, 
			N'@pleCount int OUTPUT', 
			@pleCount = @pleCount OUTPUT;


		SET @ple = N', ' + CAST(@PleUnderThreshold AS sysname) + N' [ple_under_threshold], ' + CAST(@pleCount AS sysname) + ' [ple_violations], CAST(((CAST((' + CAST(@pleCount AS sysname) + N') as decimal(23,2)) / CAST((' + CAST(@totalRows AS sysname) + N') as decimal(23,2))) * 100.0) as decimal(5,2)) [ple_violations_%] ';
	END;

	IF @BatchCountOverThreshold IS NOT NULL BEGIN
		DECLARE @batchViolationsCount int;

		SET @sql = N'SELECT @batchViolationsCount = (SELECT COUNT(*) FROM ' + @normalizedName + N' WHERE [batch_requests\sec] >= ' + CAST((CAST(@BatchCountOverThreshold AS decimal(23,2))) AS sysname) + N'); ';

		EXEC sys.[sp_executesql] 
			@sql, 
			N'@batchViolationsCount int OUTPUT', 
			@batchViolationsCount = @batchViolationsCount OUTPUT;

		SET @batchCount = N', ' + CAST(@BatchCountOverThreshold AS sysname) + N' [batches/sec_threshold], ' + CAST(@batchViolationsCount AS sysname) + N' [batches/sec_violations], CAST(((CAST((' + CAST(@batchViolationsCount AS sysname) + N') as decimal(23,2)) / CAST((' + CAST(@totalRows AS sysname) + N') as decimal(23,2))) * 100.0) as decimal(5,2)) [batches/sec_violation_%] ';
	END;

	SET @sql = N'SELECT @serverName [server_name], dbo.format_timespan(DATEDIFF(MILLISECOND, @startTime, @endTime)) [total_duration], @totalRows [total_rows], N'''' [ ]{cpu}{ple}{BatchCount}; ';
	SET @sql = REPLACE(@sql, N'{cpu}', @cpu);
	SET @sql = REPLACE(@sql, N'{ple}', @ple);
	SET @sql = REPLACE(@sql, N'{BatchCount}', @batchCount);

	EXEC sys.[sp_executesql]
		@sql, 
		N'@serverName sysname, @startTime datetime, @endTime datetime, @totalRows int', 
		@serverName = @serverName, 
		@startTime = @startTime, 
		@endTime = @endTime, 
		@totalRows = @totalRows;

	RETURN 0;
GO