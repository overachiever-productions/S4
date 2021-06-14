/*
	
	CONVENTIONS 
		
		- GYR
			Green, Yellow, Red. 
			3-tiered threshold markers/boundaries for setting low/med/high or safe(green), warning (yellow), problem (red) thresholds. 

			For PERCENTAGES, only need 2x bounds to establish full spectrum. 
				e.g., CPU
					Assume 0 - 65% is safe/green, 65- 90% is yellow, and 90%+ is red. 
					Only need: 
						@GreenYellowBoundary int = 65
						@YellowRedBoundary int 95

					From which we can derive: 
						0 - (@GreenYellow - 1) = Green. 
						@GreenYellow - (@YellowRed - 1) = Yellow
						@YellowRed - 100 = Red. 

			For other, non-percentages, need 3x bounds. 
				e.g., PLEs 
					Assume 6000+ is green, 200 - 6000 is yellow, and 1200 or less is red. 

					We'll need: 
						@GreenPle	int = 6000
						@YellowPle	int = 2000
						@RedPle		int = 1200

					Which CAN be combined into @Ple_GYR_Thresholds sysname = '6000, 2000, 1200'... 



	TODO: 
		-- note how I'm calculating GrantSizeGBs into red, yellow, green - the LOGIC there REALLY only needs Red and Green thresholds cuzz... of course it does. ANYTHING > or < than one or the either is, of course, YELLOW. 
			SEEE if I can't implement that across the board - and simplify the 'signature' of this thing... 


		-- MIGHT want to look at adding a new set of measures for WITHIN_10%_of_MAX... 
			e.g., I crunched some numbers for NA2SQL2 ... 
				- PLEs were great
				- grant GBs were set to 0-2,2-8, 8+
				- spent only 1.47% of overall time (24 hours) at 8GB+ 
				- BUT... 
					MAX PLE was ... 68GB... 
					which... is insane... 
						and... makes me wonder... how LONG were we anywhere within that range? 
							as in ... how long were we at 68GB - (68GB - 6.8GB => ~61GB) range (i.e., max through max-10%-of-max)??? 




	EXEC [admindb].dbo.[report_memory_percent_of_percent_load]
		@SourceTable = N'NA2SQL2_memory';



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_memory_percent_of_percent_load','P') IS NOT NULL
	DROP PROC dbo.[report_memory_percent_of_percent_load];
GO

CREATE PROC dbo.[report_memory_percent_of_percent_load]
	@SourceTable							sysname, 
	@Ple_GYR_Thresholds						sysname		= N'6000, 2000, 1200', 
	@GransSizeGB_GYR_Thresholds				sysname     = N'2, 4, 8',
	@ConcurrentGrants_GYR_Thresholds		sysname		= N'4, 8, 24'
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Ple_GYR_Thresholds = ISNULL(NULLIF(@Ple_GYR_Thresholds, N''), N'6000, 2000, 1200');
	SET @GransSizeGB_GYR_Thresholds = ISNULL(NULLIF(@GransSizeGB_GYR_Thresholds, N''), N'2, 4, 8');
	SET @ConcurrentGrants_GYR_Thresholds = ISNULL(NULLIF(@ConcurrentGrants_GYR_Thresholds, N''),  N'4, 8, 16');
	
	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @SourceTable, 
		@ParameterNameForTarget = N'@SourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  /* error will have already been raised... */


	-------------------------------------------------------------------------------------------------------------------------
	/* Translate Green, Yellow, Red Thresholds: */

	DECLARE @pleGreen int, @pleYellow int, @pleRed int; 
	DECLARE @grantSizeGreen decimal(22,2), @grantSizeYellow decimal(22,2), @grantSizeRed decimal(22,2);
	DECLARE @grantsGreen int, @grantsYellow int, @grantsRed int; 

	/* This sorta works - i mean, it's fine, it's fast, but it FEELS a bit ugly. ... */
	WITH shredded AS ( 
		SELECT 
			[row_id], 
			[result]
		FROM 
			dbo.[split_string](@Ple_GYR_Thresholds, N',', 1)
	)

	SELECT
		@pleGreen = (SELECT [result] FROM [shredded] s2 WHERE [s2].[row_id] = 1),
		@pleYellow = (SELECT [result] FROM [shredded] s2 WHERE [s2].[row_id] = 2),
		@pleRed = (SELECT [result] FROM [shredded] s2 WHERE [s2].[row_id] = 3);

	WITH shredded AS ( 
		SELECT 
			[row_id], 
			[result]
		FROM 
			dbo.[split_string](@GransSizeGB_GYR_Thresholds, N',', 1)
	)

	SELECT
		@grantSizeGreen = (SELECT CAST([result] AS decimal(22,2)) FROM [shredded] s2 WHERE [s2].[row_id] = 1),
		@grantSizeYellow = (SELECT CAST([result] AS decimal(22,2)) FROM [shredded] s2 WHERE [s2].[row_id] = 2),
		@grantSizeRed = (SELECT CAST([result] AS decimal(22,2)) FROM [shredded] s2 WHERE [s2].[row_id] = 3);

	WITH shredded AS ( 
		SELECT 
			[row_id], 
			[result]
		FROM 
			dbo.[split_string](@ConcurrentGrants_GYR_Thresholds, N',', 1)
	)

	SELECT
		@grantsGreen = (SELECT [result] FROM [shredded] s2 WHERE [s2].[row_id] = 1),
		@grantsYellow = (SELECT [result] FROM [shredded] s2 WHERE [s2].[row_id] = 2),
		@grantsRed = (SELECT [result] FROM [shredded] s2 WHERE [s2].[row_id] = 3);

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

	-------------------------------------------------------------------------------------------------------------------------

	DECLARE @maxPles int, @minPles int;
	DECLARE @maxGrantGB decimal(22,2), @minGrantGB decimal(22,2);
	DECLARE @maxGrantCount int, @minGrantCount int;
	DECLARE @maxPending int;
	DECLARE @totalRows decimal(24,2);

	DECLARE @aggs nvarchar(MAX) = N'
	SELECT 
		@maxPles = MAX([ple]), 
		@minPles = MIN([ple]), 
		@maxGrantGB = MAX([granted_workspace_memory_GBs]), 
		@minGrantGB = MIN([granted_workspace_memory_GBs]),
		@maxGrantCount = MAX([grants_outstanding]), 
		@minGrantCount = MIN([grants_outstanding]), 
		@maxPending = MAX([grants_pending]), 
		@totalRows = COUNT(*)
	FROM 
		' + @normalizedName + N'; '; 


	EXEC sp_executesql 
		@aggs, 
		N'@maxPles int OUTPUT, @minPles int OUTPUT, @maxGrantGB decimal(22,2) OUTPUT, @minGrantGB decimal(22,2) OUTPUT, @maxGrantCount int OUTPUT, @minGrantCount int OUTPUT, @maxPending int OUTPUT, @totalRows decimal(24,2) OUTPUT', 
		@maxPles = @maxPles OUTPUT, 
		@minPles = @minPles OUTPUT, 
		@maxGrantGB = @maxGrantGB OUTPUT, 
		@minGrantGB = @minGrantGB OUTPUT, 
		@maxGrantCount = @maxGrantCount OUTPUT, 
		@minGrantCount = @minGrantCount OUTPUT, 
		@maxPending = @maxPending OUTPUT, 
		@totalRows = @totalRows OUTPUT;

	CREATE TABLE #results ( 
		[row_id] int IDENTITY(1, 1) NOT NULL, 
		[server_name] sysname NOT NULL, 
		[metric] sysname NOT NULL, 
		[min] sysname NOT NULL, 
		[max] sysname NOT NULL, 
		[green_range] sysname NOT NULL, 
		[yellow_range] sysname NOT NULL, 
		[red_range] sysname NOT NULL, 
		[%_green] decimal(22,2) NOT NULL, 
		[%_yellow] decimal(22,2) NOT NULL, 
		[%_red] decimal(22,2) NOT NULL 
	);

	-------------------------------------------------------------------------------------------------------------------------
	DECLARE @extraction nvarchar(MAX) = N'
	WITH partitioned AS ( 
		SELECT 
			[server_name], 
			CASE WHEN [ple] >= @pleGreen THEN 1 ELSE 0 END [ple_green],
			CASE WHEN [ple] <= (@pleGreen - 1) AND [ple] > @pleRed THEN 1 ELSE 0 END [ple_yellow],
			CASE WHEN [ple] < @pleRed THEN 1 ELSE 0 END [ple_red],

			CASE WHEN [granted_workspace_memory_GBs] <= @grantSizeGreen THEN 1 ELSE 0 END [size_green],
			CASE WHEN [granted_workspace_memory_GBs] >= @grantSizeGreen AND [granted_workspace_memory_GBs] <= (@grantSizeRed - 1) THEN 1 ELSE 0 END [size_yellow],
			CASE WHEN [granted_workspace_memory_GBs] >= @grantSizeRed THEN 1 ELSE 0 END [size_red],

			CASE WHEN [grants_outstanding] <= @grantsGreen THEN 1 ELSE 0 END [grants_green],
			CASE WHEN [grants_outstanding] >= @grantsGreen + 1 AND [grants_outstanding] <= (@grantsRed - 1) THEN 1 ELSE 0 END [grants_yellow],
			CASE WHEN [grants_outstanding] >= @grantsRed THEN 1 ELSE 0 END [grants_red],

			CASE WHEN [grants_pending] > 0 THEN 1 ELSE 0 END [grants_pending_red]
		FROM 
			{normalizedName}
	), 
	aggregated AS ( 
		SELECT 
			CAST(((SUM([ple_green]) / @totalRows) * 100.0) AS decimal(6,2))				[ple_green],
			CAST(((SUM([ple_yellow]) / @totalRows) * 100.0) AS decimal(6,2))			[ple_yellow],
			CAST(((SUM([ple_red]) / @totalRows) * 100.0) AS decimal(6,2))				[ple_red],
			
			CAST(((SUM([size_green]) / @totalRows) * 100.0) AS decimal(6,2))			[size_green],
			CAST(((SUM([size_yellow]) / @totalRows) * 100.0) AS decimal(6,2))			[size_yellow],
			CAST(((SUM([size_red]) / @totalRows) * 100.0) AS decimal(6,2))				[size_red],

			CAST(((SUM([grants_green]) / @totalRows) * 100.0) AS decimal(6,2))			[grants_green],
			CAST(((SUM([grants_yellow]) / @totalRows) * 100.0) AS decimal(6,2))			[grants_yellow],
			CAST(((SUM([grants_red]) / @totalRows) * 100.0) AS decimal(6,2))			[grants_red],

			CAST(((SUM([grants_pending_red]) / @totalRows) * 100.0) AS decimal(6,2))	[grants_pending_red]
		FROM 
			[partitioned]
	), 
	ples AS ( 
		SELECT 
			@serverName [server_name],
			N''PLEs'' [metric], 
			CAST(@minPles as sysname) [min],
			CAST(@maxPles as sysname) [max],

			N''> '' + CAST(@pleGreen AS sysname) [green_range],
			CAST((@pleGreen -1) AS sysname) + N'' - '' + CAST((@pleRed + 1) AS sysname) [yellow_range],
			CAST(@pleRed AS sysname) + N'' - 0'' [red_range],

			[ple_green] [%_green],
			[ple_yellow] [%_yellow],
			[ple_red] [%_red]
		FROM 
			[aggregated]

	), 
	grant_sizes AS (
		SELECT 
			@serverName [server_name],
			N''WORKSPACE_GB'' [metric], 
			CAST(@minGrantGB as sysname) + N'' GB'' [min], 
			CAST(@maxGrantGB as sysname) + N'' GB'' [max],

			N''0 - '' + CAST((@grantSizeGreen - 0.01) AS sysname) + N'' GB'' [green_range],
			CAST(@grantSizeGreen AS sysname) + N'' - '' + CAST((@grantSizeRed - 0.01) AS sysname) + N'' GB'' [yellow_range],
			N''> '' + CAST(@grantSizeRed AS sysname) + N'' GB'' [red_range],

			[size_green] [%_green],
			[size_yellow] [%_yellow],
			[size_red] [%_red]

		FROM 
			[aggregated]

	), 
	grants AS (
		SELECT 
			@serverName [server_name],
			N''ACTIVE_GRANTS'' [metric], 
			CAST(@minGrantCount AS sysname) [min], 
			CAST(@maxGrantCount AS sysname) [max], 

			N''0 - '' + CAST(@grantsGreen AS sysname) [green_range], 
			CAST((@grantsGreen + 1) AS sysname) + N'' - '' + CAST((@grantsRed - 1) AS sysname) [yellow_range], 
			N''> '' + CAST(@grantsRed AS sysname) [red_range], 

			[grants_green] [%_green],
			[grants_yellow] [%_yellow],
			[grants_red] [%_red]
		FROM 
			[aggregated]
	), 
	pending AS (
		SELECT 
			@serverName [server_name],
			N''PENDING_GRANTS'' [metric], 
			N''0'' [min], 
			CAST(@maxPending AS sysname) [max], 

			N''< 1'' [green_range], 
			N''N/A'' [yellow_range], 
			N''> 1'' [red_range],

			100.0 - [grants_pending_red] [%_green], 
			0.0 [%_yellow],
			[grants_pending_red] [%_red]
		FROM 
			[aggregated]
	)

	SELECT * FROM ples UNION 
	SELECT * FROM grant_sizes UNION 
	SELECT * FROM grants UNION
	SELECT * FROM pending; ';

	SET @extraction = REPLACE(@extraction, N'{normalizedName}', @normalizedName);

	INSERT INTO [#results] (
		[server_name],
		[metric],
		[min],
		[max],
		[green_range],
		[yellow_range],
		[red_range],
		[%_green],
		[%_yellow],
		[%_red]
	)
	EXEC sp_executesql 
		@extraction, 
		N'@serverName sysname, @pleGreen int, @pleRed int, @grantSizeGreen decimal(22,2), @grantSizeRed decimal(22,2), @grantsGreen int, @grantsRed int, @maxPles int, @minPles int, @maxGrantGB decimal(22,2), @minGrantGB decimal(22,2), @maxGrantCount int, @minGrantCount int, @maxPending int, @totalRows decimal(24,2)', 
		@serverName = @serverName, 
		@pleGreen = @pleGreen, 
		@pleRed = @pleRed, 
		@grantSizeGreen = @grantSizeGreen, 
		@grantSizeRed = @grantSizeRed, 
		@grantsGreen = @grantsGreen, 
		@grantsRed = @grantsRed,
		@maxPles = @maxPles, 
		@minPles = @minPles, 
		@maxGrantGB = @maxGrantGB, 
		@minGrantGB = @minGrantGB, 
		@maxGrantCount = @maxGrantCount, 
		@minGrantCount = @minGrantCount, 
		@maxPending = @maxPending, 
		@totalRows = @totalRows;




	-------------------------------------------------------------------------------------------------------------------------
	/* Final Projection: */
	SELECT 
		[server_name],
		[metric],
		[min],
		[max],
		' ' [ ],
		[green_range],
		[yellow_range],
		[red_range],
		' ' [_],
		[%_green],
		[%_yellow],
		[%_red]
	FROM 
		[#results]
	ORDER BY 
		[row_id]; 


	RETURN 0; 
GO