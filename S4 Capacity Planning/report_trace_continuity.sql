/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_trace_continuity','P') IS NOT NULL
	DROP PROC dbo.[report_trace_continuity];
GO

CREATE PROC dbo.[report_trace_continuity]
	@SourceTable			sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @SourceTable = NULLIF(@SourceTable, N'');

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

	DECLARE @serverName sysname;
	DECLARE @startTime datetime, @endTime datetime;

	DECLARE @sql nvarchar(MAX) = N'SELECT @serverName = (SELECT TOP 1 server_name FROM ' + @normalizedName + N'); ';

	EXEC sys.[sp_executesql]
		@sql, 
		N'@serverName sysname OUTPUT', 
		@serverName = @serverName OUTPUT;

	SET @sql = N'SELECT 
	@startTime = MIN([timestamp]), 
	@endTime = MAX([timestamp])
FROM 
	' + @normalizedName + N'
WHERE 
	[timestamp] IS NOT NULL; ';


	EXEC sp_executesql 
		@sql, 
		N'@startTime datetime OUTPUT, @endTime datetime OUTPUT', 
		@startTime = @startTime OUTPUT, 
		@endTime = @endTime OUTPUT;


	CREATE TABLE #gaps (
		gap_id int NOT NULL, 
		gap_start datetime NOT NULL, 
		gap_end datetime NOT NULL, 
		gap_duration_ms int NOT NULL
	);

	SET @sql = N'WITH core AS ( 
		SELECT 
			[timestamp], 
			ROW_NUMBER() OVER (ORDER BY [timestamp]) [row_number]
		FROM 
			' + @normalizedName + N'
	) 

	SELECT 
		ROW_NUMBER() OVER(ORDER BY c1.[timestamp]) [gap_id],
		c1.[timestamp] [gap_start], 
		c2.[timestamp] [gap_end], 
		DATEDIFF(MILLISECOND, c1.[timestamp], c2.[timestamp]) [gap_duration_ms]
	FROM 
		core c1 
		INNER JOIN core c2 ON c1.[row_number] + 1 = c2.[row_number] 
	WHERE 
		DATEDIFF(MILLISECOND, c1.[timestamp], c2.[timestamp]) > 1200
	ORDER BY 
		c1.[row_number]; ';

	INSERT INTO [#gaps] (
		[gap_id],
		[gap_start],
		[gap_end],
		[gap_duration_ms]
	)
	EXEC sys.sp_executesql @sql;

	DECLARE @largeGaps int;
	DECLARE @smallGapsSum int; 

	SELECT @largeGaps = SUM(gap_duration_ms) FROM [#gaps] WHERE [gap_duration_ms] > 30000;
	SELECT @smallGapsSum = SUM(gap_duration_ms) FROM [#gaps] WHERE [gap_duration_ms] < 30000;

	SELECT 
		@serverName [server_name],
		@startTime [start_time],
		@endTime [end_time], 
		DATEDIFF(SECOND, @startTime, @endTime) [total_seconds], 
		ISNULL(@largeGaps, 0) / 1000 [large_gap_seconds], 
		ISNULL(@smallGapsSum, 0) / 1000 [aggregate_small_gap_seconds], 
		(DATEDIFF(SECOND, @startTime, @endTime)) - (ISNULL(@largeGaps, 0) / 1000) - (ISNULL(@smallGapsSum, 0) / 1000) [exact_seconds]

	SELECT * FROM [#gaps] ORDER BY gap_id;

	RETURN 0; 
GO