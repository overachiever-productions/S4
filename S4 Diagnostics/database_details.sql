/*

	TODO: (low priority) 
		implement @Databases ... NOT 'honored' at all at this point. 
		AND... I THINK the logical place to do this is AFTER pulling results for ALL dbs. 
			i.e., everything in the current query/operation is FAST/FINE. 
				so... treat @Databases as a POST predicate vs pre-predicate (which'll just complicate logic like crazy if doing this 'pre').

	vNEXT: 
		I know I need to do some 'conditional' logic to address 'columns' (i.e., features/details) that are NOT available on EARLIER versions
			of SQL Server. However, do any of those get 'untriggered' by means of compat? (I don't think so. BUT, assume that we're talking about
			accelerated_database_recovery... ... which is a 150? feature. If the SERVER is 150, 160, 170 ... great. BUT what if the DB is COMPAT 100? or something odd? 
				does that 'hide'/remove the column in question? (Again, i don't think so. but I really need to test for this.)


	vNEXT:
		https://overachieverllc.atlassian.net/browse/S4-482


	vNEXT:
		- Option to dump output as XML 
			So that XML blobs can be saved/stored in admindb.dbo.db_somethings or whatever. 
			AND so that there can be a sproc with options for comparisons - to list changes (so'z I can keep an eye on mods over time and so on). 
				See: https://www.notion.so/overachiever/Database-Baselines-for-admindb-fa9375b6d3f6471999f57833e3c4ca6e?pvs=4


			DECLARE @x xml;
			EXEC admindb.dbo.[database_details]
				@SerializedOutput = @x OUTPUT;
			SELECT @x;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[database_details]','P') IS NOT NULL
	DROP PROC dbo.[database_details];
GO

CREATE PROC dbo.[database_details]
    @Databases						nvarchar(MAX)   = N'{ALL}', 
    @Priorities                     nvarchar(MAX)   = NULL,						
	@SerializedOutput				xml				= N'<default/>'	    OUTPUT
AS 
    SET NOCOUNT ON; 

    -- {copyright}

	SET @Databases = ISNULL(NULLIF(@Databases, N''), N'{ALL}');
	SET @Priorities = NULLIF(@Priorities, N'');

	CREATE TABLE #freeSpace (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[file_name] sysname NOT NULL, 
		[type] tinyint NOT NULL,
		[file_size_mb] decimal(24,2) NULL, 
		[free_space_mb] decimal(24,2) NULL 
	); 
	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}];
	INSERT INTO [#freeSpace] ([database_name], [file_name], [type], [file_size_mb], [free_space_mb])
	SELECT
		N''{CURRENT_DB}'' [database_name], 
		[name] AS [file_name],
		[type],
		CAST(([size] / 128.0) AS decimal(22,2)) AS [file_size_mb],
		CAST(([size] / 128.0 - CAST(FILEPROPERTY([name], ''SpaceUsed'') AS int) / 128.0) AS decimal(22,2)) AS [free_space_mb]
	FROM
		[sys].[database_files]; ';

	DECLARE @errors xml;
	EXEC dbo.[execute_per_database]
		@Databases = @Databases,
		@Priorities = @Priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT;

	IF @errors IS NOT NULL BEGIN 
		RAISERROR('Unexpected errors extracting free-space: ', 16, 1);
		-- TODO: I need to shred this vs just selecting it. 
		SELECT @errors;
		RETURN -22;
	END;

	DECLARE @vlfCounts xml; 
	DECLARE @outcome int = 0;
	EXEC @outcome = dbo.[vlf_counts]
		@Databases = @Databases,
		@Priorities = @Priorities,
		@SerializedOutput = @vlfCounts OUTPUT;

	IF @outcome <> 0 BEGIN
		RAISERROR(N'Exception during retrieval of VLF Counts.', 16, 1);
		RETURN -10;
	END;

	SELECT 
		database_id, 
		SUM(CASE WHEN [type] = 0 THEN 1 ELSE 0 END) [data_files_count], 
		SUM(CASE WHEN [type] = 1 THEN 1 ELSE 0 END) [log_files_count],
		SUM(CASE WHEN [type] = 2 THEN 1 ELSE 0 END) [fs_files_count],
		SUM(CASE WHEN [type] = 4 THEN 1 ELSE 0 END) [fti_files_count]
	INTO 
		#fileCount
	FROM 
		sys.master_files 
	GROUP BY 
		[database_id];
	
	WITH files_on_c AS ( 
		SELECT 
			[name],
			MAX(CASE WHEN [physical_name] LIKE N'C:\%' THEN 1 ELSE 0 END) [files_on_c]
		FROM 
			sys.[master_files]
		GROUP BY 
			[name]
	), 
	core AS ( 
		SELECT 
			[d].[name] [name],
			[d].[compatibility_level] [level], 
			CASE 
				WHEN [d].[state_desc] = N'ONLINE' AND [d].[user_access_desc] = N'MULTI_USER' THEN N'ONLINE'
				ELSE CASE 
					WHEN [d].[state_desc] = N'ONLINE' THEN d.[user_access_desc] 
					ELSE [d].[state_desc]
				END 
			END [state],

			-- TODO: add in MIRROR / REPLICA - based on whether the DB is mirrored or in an AG. 
			--		ideally, there's some way to communicate if we're primary, secondary, RO, distributed, etc. 

			[d].[collation_name] [collation],
			CAST((([s].[size] * 8.0 / 1024.0) / 1024.0) AS decimal(24,1)) [db_size_gb],
			(SELECT SUM([free_space_mb]) FROM [#freeSpace] WHERE [database_name] = [d].[name] AND [type] = 0) [free_space_mb],
			CAST(([logsize].[log_size] / 1024.0) AS decimal(24,1)) [log_size_gb],
			CASE 
				WHEN [logsize].[log_size] = 0 THEN -1.0
				WHEN [logused].[log_used] = 0 THEN 0.0
				ELSE CAST((([logused].[log_used] / [logsize].[log_size]) * 100.0) AS decimal(5,1))
			END [%_log_used],

			[d].recovery_model_desc [recovery],
			
			CAST([c].[data_files_count] AS sysname) + N':' + CAST([c].[log_files_count] AS sysname) + N':' + CAST([c].[fs_files_count] AS sysname) + N':' + CAST([c].[fti_files_count] AS sysname) AS [file_counts (d:l:fs:fti)],
			[d].page_verify_option_desc [page_verify],
			[d].[is_trustworthy_on] [trustworthy],
			[d].[is_read_committed_snapshot_on] [rcsi], 
			[d].[is_query_store_on] [query_store],
			CASE WHEN [d].[snapshot_isolation_state] = 1 THEN N' SNAPSHOT_ISOLATION; ' ELSE N'' END
				+ CASE WHEN [d].[is_broker_enabled] = 1 THEN N' BROKER; ' ELSE N'' END
				--+ CASE WHEN [d].[is_fulltext_enabled] = 1 THEN N' FTI; ' ELSE N'' END   -- this is true on any ... server with FTI installed. 
				+ CASE WHEN [d].[is_cdc_enabled] = 1 THEN N' CDC; ' ELSE N'' END
				+ CASE WHEN [d].[target_recovery_time_in_seconds] <> 0 THEN N' TARGET_RECOVERY_SECs: ' + CAST([d].[target_recovery_time_in_seconds] AS sysname) + N'; ' ELSE N'' END
				+ CASE WHEN [d].[delayed_durability] <> 0 THEN N' DELAYED_DURABILITY: ' + CAST([d].[delayed_durability] AS sysname) + N'; ' ELSE N'' END
				+ CASE WHEN [d].[containment_desc] <> N'NONE' THEN N' CONTAINMENT: ' + [d].[containment_desc] + N'; ' ELSE N'' END
				+ CASE WHEN [d].[is_encrypted] = 1 THEN N' ENCRYPTED; ' ELSE N'' END
				+ CASE WHEN [d].[is_accelerated_database_recovery_on] = 1 THEN N' ACCELERATED_RECOVERY; ' ELSE N'' END
				+ CASE WHEN [d].[is_stale_page_detection_on] = 1 THEN N' STALE_PAGE_DETECTION; ' ELSE N'' END
				+ CASE WHEN [d].[is_result_set_caching_on] = 1 THEN N' RESULT_SET_CACHING; ' ELSE N'' END
				+ CASE WHEN [d].[is_ledger_on] = 1 THEN N' LEDGER; ' ELSE N'' END
				-- TODO: add in any other options here that make sense... 
			[advanced_options],
			CASE WHEN [d].[owner_sid] = 0x01 THEN 0 ELSE 1 END [non_sa_owner],
			CASE WHEN [d].[is_auto_close_on] = 1 THEN N' Auto-Close; ' ELSE N'' END
				+ CASE WHEN [fc].[files_on_c] = 1 THEN N' Files on C:\; ' ELSE N'' END
				+ CASE WHEN [d].[is_trustworthy_on] = 1 THEN N' TRUSTHWORTHY; ' ELSE N'' END
				+ CASE WHEN [d].[is_auto_shrink_on] = 1 THEN N' Auto-Shrink; ' ELSE N'' END
				+ CASE WHEN [d].[is_parameterization_forced] = 1 THEN N' Parameterization-Forced; ' ELSE N'' END
				+ CASE WHEN [d].[is_auto_update_stats_async_on] = 1 THEN N' Auto-Async-Stats; ' ELSE N'' END 
				+ CASE WHEN [d].[is_mixed_page_allocation_on] = 1 THEN N' MIXED-PAGE-ALLOCATION; ' ELSE N'' END
			[smells]
		FROM 
			sys.databases [d]
			LEFT OUTER JOIN [files_on_c] [fc] ON [d].[name] = [fc].[name]
			LEFT OUTER JOIN [#fileCount] [c] ON [d].[database_id] = [c].[database_id]
			LEFT OUTER JOIN (
				SELECT	database_id, SUM(size) size, COUNT(database_id) [Files] FROM sys.master_files WHERE [type] = 0 GROUP BY database_id
			) [s] ON [d].database_id = [s].database_id
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / 1024.0) AS decimal(24,1)) [log_size] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Size %') [logsize] ON [d].[name] = [logsize].[db_name]
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / 1024.0) AS decimal(24,1)) [log_used] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Used %') [logused] ON [d].[name] = [logused].[db_name]
	), 
	vlfs AS ( 
		SELECT 
			[data].[row].value(N'(database_name)[1]', N'sysname') [database_name], 
			[data].[row].value(N'(vlf_count)[1]', N'int') [vlf_count]
		FROM 
			@vlfCounts.nodes(N'//database') [data]([row])		
	)


	SELECT 
		[c].[name],
		[c].[level],
		[c].[state],
		[c].[collation],
		[c].[db_size_gb],
		CASE WHEN [free_space_mb] IS NULL THEN NULL ELSE CAST([c].[free_space_mb] / 1024. AS decimal(24,2)) END [free_space_gb],
		[c].[log_size_gb],
		[c].[%_log_used] [log_used_pct],
		[c].[recovery],
		[v].[vlf_count],
		[c].[file_counts (d:l:fs:fti)],
		[c].[page_verify],
		[c].[trustworthy],
		[c].[rcsi],
		[c].[query_store],
		LTRIM(REPLACE([c].[advanced_options], N'  ', N' ')) [advanced_options],
		[c].[non_sa_owner],
		LTRIM(REPLACE([c].[smells], N'  ', N' ')) [smells]
	INTO #intermediate
	FROM 
		core [c]
		LEFT OUTER JOIN [vlfs] [v] ON [c].[name] = [v].[database_name]
	ORDER BY 
		[db_size_gb] DESC;

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- RETURN instead of project.. 
		
		SET @SerializedOutput = (
			SELECT 
				[name],
				[level],
				[state],
				[collation],
				[db_size_gb] [size_gb],
				[free_space_gb] [free_gb],
				[log_size_gb] [log_gb],
				[log_used_pct],
				[recovery],
				[vlf_count] [vlfs],
				[file_counts (d:l:fs:fti)] [file_counts_d_l_fs_fti],
				[page_verify],
				[trustworthy],
				[rcsi],
				[query_store] [qs],
				[advanced_options],
				[non_sa_owner],
				[smells]
			FROM 
				[#intermediate]
			ORDER BY 
				[name]
			FOR XML PATH(N'database'), ROOT(N'databases'), ELEMENTS XSINIL
		);

		RETURN 0;
	END;

	SELECT 
		[name],
		[level],
		[state],
		[collation],
		[db_size_gb] [size_gb],
		[free_space_gb] [free_gb],
		[log_size_gb] [log_gb],
		[log_used_pct],
		[recovery],
		[vlf_count] [vlfs],
		[file_counts (d:l:fs:fti)] [file_counts (d:l:fs:ft)],
		[page_verify],
		[trustworthy],
		[rcsi],
		[query_store] [qs],
		[advanced_options],
		[non_sa_owner],
		[smells] 
	FROM 
		[#intermediate] 
	ORDER BY 
		[db_size_gb] DESC;

	RETURN 0;
GO