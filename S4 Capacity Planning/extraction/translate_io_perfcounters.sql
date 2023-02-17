/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_io_perfcounters','P') IS NOT NULL
	DROP PROC dbo.[translate_io_perfcounters];
GO

CREATE PROC dbo.[translate_io_perfcounters]
	@SourceTable			sysname, 
	@TargetTable			sysname, 
	@OverwriteTarget		bit				= 0, 
	@PrintOnly				bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @SourceTable = NULLIF(@SourceTable, N'');
	SET @TargetTable = NULLIF(@TargetTable, N'');

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
		RAISERROR('Please specify a @TargetTable value - for the output of dbo.translate_io_perfcounters', 16, 1); 
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
	-- Import/Translate:

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

	DECLARE @statement nvarchar(MAX) = N'
	WITH translated AS (
		SELECT 
			TRY_CAST([{timeZone}] as datetime) [timestamp],
			TRY_CAST([\\{HostName}\Processor(_Total)\% Processor Time]  as decimal(10,2)) [% CPU],
			--TRY_CAST([{InstanceName}Buffer Manager\Page life expectancy] as int) [PLE],
			--TRY_CAST([{InstanceName}SQL Statistics\Batch Requests/sec] as decimal(22,2)) [batches/second],
        
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
			--[PLE],
			--[batches/second],   

			{AggregatedThroughput}
			{AggregatedIOPS}
			{AggregatedLatency}

			, (SELECT MAX(latency) FROM (VALUES {PeakLatency}) AS x(latency)) [PeakLatency]
		FROM 
			translated 
	)

	SELECT 
		N''{HostName}'' [server_name],
		[timestamp],
		[% CPU],
		--[PLE],
		--[batches/second],

		{Throughput}
		{IOPS}
		{Latency},
		[PeakLatency]
	INTO 
		{TargetTable}
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
	SET @statement = REPLACE(@statement, N'{InstanceName}', ISNULL(@instanceNamePrefix, N''));
	SET @statement = REPLACE(@statement, N'{TableName}', @normalizedName);
	SET @statement = REPLACE(@statement, N'{TargetTable}', @TargetTable);

	IF @PrintOnly = 1 BEGIN 
		EXEC dbo.[print_long_string] @statement;
	  END; 
	ELSE BEGIN 
		EXEC [sys].[sp_executesql] @statement;

		SET @statement = N'SELECT COUNT(*) [total_rows_exported] FROM ' + @TargetTable + N'; ';
		EXEC [sys].[sp_executesql] @statement;

	END;

	RETURN 0;
GO