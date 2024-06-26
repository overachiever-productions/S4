
/*
	
	refactor. 
		dbo.report_recovery_metrics








------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
AVG/MAX durations and file-counts for restore + consistency checks: 

					WITH core AS ( 
						SELECT 
							[database],
							DATEDIFF(MILLISECOND, [restore_start], [restore_end]) [restore_duration],
							DATEDIFF(MILLISECOND, [consistency_start], [consistency_end]) [consistency_duration], 
							ISNULL(restored_files.value('count(/files/file)', 'int'), 0) [restored_file_count]
						FROM 
							dbo.[restore_log] 
						WHERE 
							[operation_date] > DATEADD(DAY, 0 - 30, GETDATE())
							AND [error_details] IS NULL
					) 

					SELECT 
						[database], 
						dbo.[format_timespan](AVG(restore_duration)) [avg_restore_duration], 
						dbo.[format_timespan](MAX(restore_duration)) [max_restore_duration], 
	
						dbo.[format_timespan](AVG([consistency_duration])) [avg_consistency_duration], 
						dbo.[format_timespan](MAX([consistency_duration])) [max_consistency_duration], 
	
						AVG([restored_file_count]) [avg_file_count], 
						MAX([restored_file_count]) [max_file_count]
					FROM 
						core
					GROUP BY 
						[database]
					ORDER BY 
						[avg_restore_duration] DESC;
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------



	-- permutations... 
	--		SUMMARY - Formatted summary of the last @Scope. 
	--		SLAs = AGGREGATE of restore times (avgs, max, min), error counts, and RPOs, RTOs over the @scope specified. 
	--		RPO = Detailed version of just RPO details over @Scope. 
	--		RTO = Detailed version of just RTO details over @Scope.  
	--		ERROR = Any/all errors in a 'dashboard' - effectively 'summary' but just focused on errors. 
	--		DEVIATION = standard deviations in timing ... as a 'dashboard'/report (i.e., avg for x, deviation by y)... etc. 

	-- vNEXT
		- Look at adding N'{GUID}' as an @Scope value - along with N'{GUID}, {GUID}, {GUID}'... 
			- that'll require some additional validation/filtering and other logic. 
			- BUT... this'll also mean i can tweak restore_databases to pull back 'error' details by means of executing this sproc? 


		- Also, need to account for 'multi-day' restores in a cleaner fashion. 
			e.g., assume we start restoring, say, 10x different databases at 10:45PM nightly. And that this takes 3.25 hours total. 
					some of thos operations will  be from 'today', some from 'yesterday' if/when viewing this info/report once everything is done. 

---------------------------------------------------------------------------------------------------
---- sample RPO checks: 


								--DECLARE @LatestBatch uniqueidentifier;
								--SELECT @LatestBatch = (SELECT TOP 1 [execution_id] FROM dbo.[restore_log] ORDER BY [restore_test_id] DESC);

								--SET @LatestBatch = '2A7A3D02-350E-47AC-A74E-65680ABF38C5';


								--SELECT 
								--	[database] + N' -> ' + [restored_as] [operation], 
								--	[restore_succeeded],
								--	[test_date], 
								--	restore_end, 
								--	ISNULL(restored_files.value('count(/files/file)', 'int'), 0) [restored_file_count],
								--	ISNULL(restored_files.exist('/files/file/name[contains(., "DIFF_")]'), 0) [diff_restored],
								--	--0 [diff_included],			-- derive from restored_files
								--	restored_files.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime') [latest_backup]

								--FROM 
								--	dbo.[restore_log]
								--WHERE 
								--	[execution_id] = @LatestBatch
								--ORDER BY 
								--	[restore_test_id];


								--GO

--;
--WITH core AS ( 

--	SELECT TOP 100
--		restore_test_id,
--		[database] + N' -> ' + [restored_as] [operation], 
--		[restore_succeeded],
--		[test_date], 
--		[restore_start],
--		restore_end, 
--		ISNULL(restored_files.value('count(/files/file)', 'int'), 0) [restored_file_count],
--		ISNULL(restored_files.exist('/files/file/name[contains(., "DIFF_")]'), 0) [diff_restored],
--		--0 [diff_included],			-- derive from restored_files
--		restored_files.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime') [latest_backup]

--	FROM 
--		dbo.[restore_log]

--	ORDER BY 
--		[restore_test_id] DESC
--)

--SELECT 
--	[restore_test_id],
--    [operation],
--    [restore_succeeded],
--    [test_date],
--	[restore_start],
--    [restore_end],
--    [restored_file_count],
--    [diff_restored],
--    [latest_backup], 
--	dbo.format_timespan(DATEDIFF(MILLISECOND, [core].[latest_backup], [core].[restore_end])) [recovery_point_vector]
--FROM 
--	core;




---------------------------------------------------------------------------------------------------
---- RTO checks: 

---- TODO: currently outputs as hh:mm:ss ... probably need to enable a dd hh:mm:ss option too... cuz of long-running restores and such... (i.e., i don't have any clients (currently) that need this ... but ... it could happen... 
----		well... or... if 49:12:12 pretty clear..... guess it is. (so, just make sure that'll work as expected).

--DECLARE @LatestBatch uniqueidentifier;
--SELECT @LatestBatch = (SELECT TOP 1 [execution_id] FROM dbo.[restore_log] ORDER BY [restore_test_id] DESC);

--DECLARE @Errors bit = 0;

--IF EXISTS (SELECT NULL FROM dbo.[restore_log] WHERE [execution_id] = @LatestBatch AND [restore_succeeded] = 0 OR [consistency_succeeded] = 0)
--	SET @Errors = 1;

--IF @Errors = 1 
--	SELECT 'Errors Were Detected - Check for Details' [outcome];
--ELSE BEGIN 
--	DECLARE @totalSeconds int;

--	SELECT @totalSeconds = SUM(DATEDIFF(SECOND, restore_start, restore_end)) FROM dbo.[restore_log] WHERE [execution_id] = @LatestBatch;

--	SELECT N'Total Restore Time -> '	
--			+ RIGHT('0' + CAST(@totalSeconds / 3600 AS sysname),2) + ':' +
--			+ RIGHT('0' + CAST((@totalSeconds / 60) % 60 AS sysname),2) + ':' +
--			+ RIGHT('0' + CAST(@totalSeconds % 60 AS sysname),2)
--END;

--GO



-------------------------------------------------------------------
---- F. RTO checks over x days (well.. last 10):

--WITH core AS ( 
--	SELECT 
--		rl.[execution_id],
--		(SELECT MIN([test_date]) FROM dbo.[restore_log] x WHERE x.[execution_id] = rl.[execution_id]) [test_date],
--		CASE
--			WHEN rl.[restore_succeeded] = 1 THEN DATEDIFF(SECOND, rl.[restore_start], rl.[restore_end])
--			ELSE 0
--		END [restore_seconds]
--	FROM 
--		dbo.[restore_log] rl
--), 
--grouped AS (
--	SELECT 
--		[core].[execution_id], 
--		[core].[test_date],
--		SUM([core].[restore_seconds]) [total_seconds]
--	FROM 
--		core 
--	WHERE 
--		[core].[test_date] > DATEADD(DAY, -10, GETDATE())
--	GROUP BY 
--		[core].[execution_id], [core].[test_date]
--)
	
--SELECT 
--	[grouped].[test_date], 
--	RIGHT('0' + CAST([total_seconds] / 3600 AS sysname),2) + ':' +
--		+ RIGHT('0' + CAST(([total_seconds] / 60) % 60 AS sysname),2) + ':' +
--		+ RIGHT('0' + CAST([total_seconds] % 60 AS sysname),2) [total_rto_time]
--FROM 
--	grouped 
--ORDER BY 
--	[grouped].[test_date];

--GO	



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_recovery_metrics','P') IS NOT NULL
	DROP PROC dbo.list_recovery_metrics;
GO

CREATE PROC dbo.list_recovery_metrics 
	@TargetDatabases				nvarchar(MAX)		= N'{ALL}', 
	@ExcludedDatabases				nvarchar(MAX)		= NULL,				-- e.g., 'demo, test, %_fake, etc.'
	@Priorities						nvarchar(MAX)		= NULL,
	@Mode							sysname				= N'SUMMARY',		-- SUMMARY | SLA | RPO | RTO | ERROR | DEVIATION
	@Scope							sysname				= N'WEEK'			-- LATEST | DAY | WEEK | MONTH | QUARTER
AS 
	SET NOCOUNT ON;

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Validate Inputs: 
	-- TODO: validate inputs.... 

	-----------------------------------------------------------------------------
	-- Establish target databases and execution instances:
	CREATE TABLE #targetDatabases (
		[database_name] sysname NOT NULL
	);

	CREATE TABLE #executionIDs (
		execution_id uniqueidentifier NOT NULL
	);

	INSERT INTO [#targetDatabases] ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@Priorities = @Priorities;

	IF UPPER(@Scope) = N'LATEST'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT TOP(1) [execution_id] FROM dbo.[restore_log] ORDER BY [restore_id] DESC;

	IF UPPER(@Scope) = N'DAY'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(GETDATE() AS [date]) GROUP BY [execution_id];
	
	IF UPPER(@Scope) = N'WEEK'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(WEEK, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	

	IF UPPER(@Scope) = N'MONTH'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(MONTH, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	

	IF UPPER(@Scope) = N'QUARTER'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(QUARTER, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	
	

	-----------------------------------------------------------------------------
	-- Extract core/key details into a temp table (to prevent excessive CPU iteration later on via sub-queries/operations/presentation-types). 
	SELECT 
		l.[restore_id], 
		l.[execution_id], 
		ROW_NUMBER() OVER (ORDER BY l.[restore_id]) [row_number],
		l.[operation_date],
		l.[database], 
		l.[restored_as], 
		l.[restore_succeeded], 
		l.[restore_start], 
		l.[restore_end],
		CASE 
			WHEN l.[restore_succeeded] = 1 THEN DATEDIFF(MILLISECOND, l.[restore_start], l.[restore_end])
			ELSE 0
		END [restore_duration], 
		l.[consistency_succeeded], 
		CASE
			WHEN ISNULL(l.[consistency_succeeded], 0) = 1 THEN DATEDIFF(MILLISECOND, l.[consistency_start], l.[consistency_end])
			ELSE 0
		END [consistency_check_duration], 				
		l.[restored_files], 
		ISNULL(restored_files.value('count(/files/file)', 'int'), 0) [restored_file_count],
		ISNULL(restored_files.exist('/files/file/name[contains(., "DIFF_")]'), 0) [diff_restored],
		restored_files.value('(/files/file[@id = max(/files/file/@id)]/created)[1]', 'datetime') [latest_backup],
		l.[error_details]
	INTO 
		#facts 
	FROM 
		dbo.[restore_log] l 
		INNER JOIN [#targetDatabases] d ON l.[database] = d.[database_name]
		INNER JOIN [#executionIDs] e ON l.[execution_id] = e.[execution_id];

				-- vNEXT: 
				--		so. if there's just one db being restored per 'test' (i.e., execution) then ... only show that db's name... 
				--			but, if there are > 1 ... show all dbs in an 'xml list'... 
				--			likewise, if there's just a single db... report on rpo... total. 
				--			but, if there are > 1 dbs... show rpo_total, rpo_min, rpo_max, rpo_avg... AND... then ... repos by db.... i.e., 4 columns for total, min, max, avg and then a 5th/additional column for rpos by db as xml... 
				--			to pull this off... just need a dynamic query/projection that has {db_list} and {rpo} tokens for columns... that then get replaced as needed. 
				--				though, the trick, of course, will be to tie into the #tempTables and so on... 

	-- generate aggregate details as well: 
	SELECT 
		x.execution_id, 
		CAST((SELECT  
		CASE 
			-- note: using slightly diff xpath directives in each of these cases/options:
			WHEN [x].[database] = x.[restored_as] THEN CAST((SELECT f2.[restored_as] [restored_db] FROM [#facts] f2 WHERE x.execution_id = f2.[execution_id] ORDER BY f2.[database] FOR XML PATH(''), ROOT('dbs')) AS XML)
			ELSE CAST((SELECT f2.[database] [@source_db], f2.[restored_as] [*] FROM [#facts] f2 WHERE x.execution_id = f2.[execution_id] ORDER BY f2.[database] FOR XML PATH('restored_db'), ROOT('dbs')) AS XML)
		END [databases]
		) AS xml) [databases],
-- TODO: when I query/project this info (down below in various modes) use xpath or even a NASTY REPLACE( where I look for '<error source="[$db_name]" />') ... to remove 'empty' nodes (databases) and, ideally, just have <errors/> if/when there were NO errors.
		CAST((SELECT [database] [@source], error_details [*] FROM [#facts] f3 WHERE x.execution_id = f3.[execution_id] AND f3.[error_details] IS NOT NULL ORDER BY f3.[database] FOR XML PATH('error'), ROOT('errors')) AS xml) [errors]

-- TODO: need a 'details' column somewhat like: 
		--	<detail database="restored_db_name_here" restored_file_count="N" rpo_milliseconds="nnnn" /> ... or something similar... 
	INTO 
		#aggregates
	FROM 
		#facts x;


	IF UPPER(@Mode) IN (N'SLA', N'RPO', N'RTO') BEGIN 

		SELECT 
			[restore_id], 
			[execution_id],
			COUNT(restore_id) OVER (PARTITION BY [execution_id]) [tested_count],
			[database], 
			[restored_as],
			--DATEDIFF(DAY, [latest_backup], [restore_end]) [rpo_gap_days], 
			--DATEDIFF(DAY, [restore_start], [restore_end]) [rto_gap_days],
			DATEDIFF(MILLISECOND, [latest_backup], [restore_end]) [rpo_gap], 
			DATEDIFF(MILLISECOND, [restore_start], [restore_end]) [rto_gap]
		INTO 
			#metrics
		FROM 
			#facts;
	END; 

	-----------------------------------------------------------------------------
	-- SUMMARY: 
	IF UPPER(@Mode) = N'SUMMARY' BEGIN
	
		DECLARE @compatibilityCommand nvarchar(MAX) = N'
		SELECT 
			f.[operation_date], 
			f.[database] + N'' -> '' + f.[restored_as] [operation],
			f.[restore_succeeded], 
			--f.[consistency_succeeded] [check_succeeded],
			f.[restored_file_count],
			f.[diff_restored], 
			dbo.format_timespan(f.[restore_duration]) [restore_duration],
			
			
			-- MKC: this is ... busted.
			--dbo.format_timespan(SUM(f.[restore_duration]) OVER (PARTITION BY f.[execution_id] ORDER BY f.[restore_id])) [cummulative_restore],
			
			-- MKC: these ... don''t make ANY sense in a RECOVERY METRICS report:
			--dbo.format_timespan(f.[consistency_check_duration]) [check_duration], 
			--dbo.format_timespan(SUM(f.[consistency_check_duration]) OVER (PARTITION BY f.[execution_id] ORDER BY f.[restore_id])) [cummulative_check], 
			CASE 
				WHEN DATEDIFF(DAY, f.[latest_backup], f.[restore_end]) > 20 THEN CAST(DATEDIFF(DAY, f.[latest_backup], f.[restore_end]) AS nvarchar(20)) + N'' days'' 
				ELSE dbo.format_timespan(DATEDIFF(MILLISECOND, f.[latest_backup], f.[restore_end])) 
			END [rpo_gap], 
			ISNULL(f.[error_details], N'''') [error_details]
		FROM 
			#facts f
		ORDER BY 
			f.[row_number] DESC; ';

		IF (SELECT dbo.[get_engine_version]()) <= 10.5 BEGIN 
			-- TODO: the fix here won't be too hard. i.e., I just need to do the following: 
			--		a) figure out how to 'order' the rows in #facts as needed... i.e., either by a ROW_NUMBER() ... windowing function (assuming that's supported) or by means of some other option... 
			--		b) instead of using SUM() OVER ()... 
			--				just 1) create an INNER JOIN against #facts f2 ON f1.previousRowIDs <= f2.currentRowID - as per this approach: https://stackoverflow.com/a/2120639/11191
			--				then 2) just SUM against f2 instead... and that should work just fine. 
			
			-- as in... i'd create/define a DIFFERENT @compatibilityCommand 'body'... then let that be RUN below via sp_executesql... 


			RAISERROR('The SUMMARY mode is currently NOT supported in SQL Server 2008 and 2008R2.', 16, 1); 
			RETURN -100;
		END; 

		EXEC sys.[sp_executesql] @compatibilityCommand;
	END; 

	-----------------------------------------------------------------------------
	-- SLA: 
	IF UPPER(@Mode) = N'SLA' BEGIN
		DECLARE @dbTestCount int; 
		SELECT @dbTestCount = MAX([tested_count]) FROM [#metrics];

		IF @dbTestCount < 2 BEGIN
			WITH core AS ( 
				SELECT 
					f.execution_id, 
					MAX(f.[row_number]) [rank_id],
					MIN(f.[operation_date]) [test_date],
					COUNT(f.[database]) [tested_db_count],
					SUM(CAST(f.[restore_succeeded] AS int)) [restore_succeeded_count],
					SUM(CAST(f.[consistency_succeeded] AS int)) [check_succeeded_count], 
					SUM(CASE WHEN NULLIF(f.[error_details], N'') IS NULL THEN 0 ELSE 1 END) [error_count], 
					SUM(f.[restore_duration]) restore_duration, 
					SUM(f.[consistency_check_duration]) [consistency_duration], 

					-- NOTE: these really only work when there's a single db per execution_id being processed... 
					MAX(f.[restore_end]) [most_recent_restore],
					MAX(f.[latest_backup]) [most_recent_backup]
				FROM 
					#facts f
				GROUP BY 
					f.[execution_id]
			) 

			SELECT 
				x.[test_date],
				a.[databases],
				x.[tested_db_count],
				x.[restore_succeeded_count],
				x.[check_succeeded_count],
				x.[error_count],
				CASE 
					WHEN x.[error_count] = 0 THEN CAST('<errors />' AS xml)
					ELSE a.[errors]   -- TODO: strip blanks and such...   i.e., if there are 50 dbs tested, and 2x had errors, don't want to show 48x <error /> and 2x <error>blakkljdfljjlfsdfj</error>. Instead, just want to show... the 2x <error> blalsdfjldflk</errro> rows... (inside of an <errors> node... 
				END [errors],
				dbo.format_timespan(x.[restore_duration]) [recovery_time_gap],
				dbo.format_timespan(DATEDIFF(MILLISECOND, x.[most_recent_backup], x.[most_recent_restore])) [recovery_point_gap]
			FROM 
				core x
				INNER JOIN [#aggregates] a ON x.[execution_id] = a.[execution_id]
			ORDER BY 
				x.[test_date], x.[rank_id];
		  END;
		ELSE BEGIN 

			WITH core AS ( 
				SELECT 
					f.execution_id, 
					MAX(f.[row_number]) [rank_id],
					MIN(f.[operation_date]) [test_date],
					COUNT(f.[database]) [tested_db_count],
					SUM(CAST(f.[restore_succeeded] AS int)) [restore_succeeded_count],
					SUM(CAST(f.[consistency_succeeded] AS int)) [check_succeeded_count], 
					SUM(CASE WHEN NULLIF(f.[error_details], N'') IS NULL THEN 0 ELSE 1 END) [error_count], 
					SUM(f.[restore_duration]) restore_duration, 
					SUM(f.[consistency_check_duration]) [consistency_duration]
				FROM 
					#facts f
				GROUP BY 
					f.[execution_id]
			), 
			metrics AS ( 
				SELECT 
					[execution_id],
					MAX([rpo_gap]) [max_rpo_gap], 
					AVG([rpo_gap]) [avg_rpo_gap],
					MIN([rpo_gap]) [min_rpo_gap], 
					MAX([rto_gap]) [max_rto_gap], 
					AVG([rto_gap]) [avg_rto_gap],
					MIN([rto_gap]) [min_rto_gap]
				FROM
					#metrics  
				GROUP BY 
					[execution_id]
			) 

			SELECT 
				x.[test_date],
				x.[execution_id],

-- TODO: this top(1) is a hack. Need to figure out a cleaner way to run AGGREGATES in #aggregates when > 1 db is being restored ... 
				(SELECT TOP (1) a.[databases] FROM #aggregates a WHERE a.[execution_id] = x.[execution_id]) [databases],
				x.[tested_db_count],
				x.[restore_succeeded_count],
				x.[check_succeeded_count],
				x.[error_count],
				CASE 
					WHEN x.[error_count] = 0 THEN CAST('<errors />' AS xml)
-- TODO: also a hack... 
					ELSE (SELECT TOP(1) a.[errors] FROM [#aggregates] a WHERE a.[execution_id] = x.execution_id)   
					--ELSE (SELECT y.value('(/errors/error/@source_db)[1]','sysname') [@source_db], y.value('.', 'nvarchar(max)') [*] FROM ((SELECT TOP(1) a.[errors] FROM [#aggregates] a WHERE a.[execution_id] = x.[execution_id])).nodes() AS x(y) WHERE y.value('.','nvarchar(max)') <> N'' FOR XML PATH('error'), ROOT('errors'))
				END [errors],
				
				dbo.format_timespan(m.[max_rto_gap]) [max_rto_gap],
				dbo.format_timespan(m.[avg_rto_gap]) [avg_rto_gap],
				dbo.format_timespan(m.[min_rto_gap]) [min_rto_gap],
				'blah as xml' recovery_time_details,  --'xclklsdlfs' [---rpo_metrics--]  -- i need... avg rpo, min_rpo, max_rpo... IF there's > 1 db being restored... otherwise, just the rpo, etc. 

				dbo.format_timespan(m.[max_rpo_gap]) [max_rpo_gap],
				dbo.format_timespan(m.[avg_rpo_gap]) [avg_rpo_gap],
				dbo.format_timespan(m.[min_rpo_gap]) [min_rpo_gap],
				'blah as xml' recovery_point_details  -- <detail database="restored_db_name_here" restored_file_count="N" rpo_milliseconds="nnnn" /> ... or something similar... 
			FROM 
				core x
				INNER JOIN metrics m ON x.[execution_id] = m.[execution_id]
			ORDER BY 
				x.[test_date], x.[rank_id];

		END;
		

	END; 

	-----------------------------------------------------------------------------
	-- RPO: 
	IF UPPER(@Mode) = N'RPO' BEGIN

		PRINT 'RPO';

	END; 

	-----------------------------------------------------------------------------
	-- RTO: 
	IF UPPER(@Mode) = N'RTO' BEGIN

		PRINT 'RTO';
		
	END; 

	-----------------------------------------------------------------------------
	-- ERROR: 
	IF UPPER(@Mode) = N'ERROR' BEGIN

		PRINT 'ERROR';

	END; 

	-----------------------------------------------------------------------------
	-- DEVIATION: 
	IF UPPER(@Mode) = N'DEVIATION' BEGIN

		PRINT 'DEVIATION';

	END; 

	RETURN 0;
GO