/*

	REFACTOR: 
		- MAYBE call this REPORT_database_details or SHOW_database_details or ... something OTHER than ... LIST... (MAYBE).

	vNEXT:
		Need to report on whether QueryStore is enabled or not (and maybe the size-used vs allowed-size?)


	vNEXT:
		- Option to dump output as XML 
			So that XML blobs can be saved/stored in admindb.dbo.db_somethings or whatever. 
			AND so that there can be a sproc with options for comparisons - to list changes (so'z I can keep an eye on mods over time and so on). 
				See: https://www.notion.so/overachiever/Database-Baselines-for-admindb-fa9375b6d3f6471999f57833e3c4ca6e?pvs=4


			DECLARE @x xml;
			EXEC admindb.dbo.[list_database_details]
				@SerializedOutput = @x OUTPUT;
			SELECT @x;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[list_database_details]','P') IS NOT NULL
	DROP PROC dbo.[list_database_details];
GO

CREATE PROC dbo.[list_database_details]
    @TargetDatabases                nvarchar(MAX)   = N'{ALL}', 
    @ExcludedDatabases              nvarchar(MAX)   = NULL, 
    @Priorities                     nvarchar(MAX)   = NULL, 
	@SerializedOutput				xml				= N'<default/>'	    OUTPUT
AS 
    SET NOCOUNT ON; 

    -- {copyright}

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
	
	WITH core AS ( 
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
			CAST(([logsize].[log_size] / 1024.0) AS decimal(24,1)) [log_size_gb],
			CASE 
				WHEN [logsize].[log_size] = 0 THEN -1.0
				WHEN [logused].[log_used] = 0 THEN 0.0
				ELSE CAST((([logused].[log_used] / [logsize].[log_size]) * 100.0) AS decimal(5,1))
			END [%_log_used],

			-- TODO: 
			--		and in % of data-file used/free ... 
			--		here's how to calculate that: 
			--	
			--				SELECT
			--					DB_NAME() [database_name],
			--					[name] AS [file_name],
			--					CAST(([size] / 128.0) AS decimal(22,2)) AS [file_size_mb],
			--					CAST(([size] / 128.0 - CAST(FILEPROPERTY([name], 'SpaceUsed') AS int) / 128.0) AS decimal(22,2)) AS [free_space_mb]
			--				FROM
			--					[sys].[database_files];
			--
			--		and... between all of the different data-file, log-file, log-file-%-used, and data-file-%-used + log-file-as-data-file-% ... 
			--			it probably makes sense to break all of the above out into xml or something. 
			--			AND, if the log file > 75% of the data-file or larger (and the data-file > xMB in size) then... throw in a SMELL. 


			-- TODO: possibly add in VLF counts here as well? 
			--		ah, maybe make it an @IncludeVLFs bit ...  ? 

			[d].recovery_model_desc [recovery],
			
			CAST([c].[data_files_count] AS sysname) + N':' + CAST([c].[log_files_count] AS sysname) + N':' + CAST([c].[fs_files_count] AS sysname) + N':' + CAST([c].[fti_files_count] AS sysname) AS [file_counts (d:l:fs:fti)],
			[d].page_verify_option_desc [page_verify],
			[d].[is_trustworthy_on] [trustworthy],
			[d].[is_read_committed_snapshot_on] [rcsi], 
			CASE WHEN [d].[snapshot_isolation_state] = 1 THEN N'SNAPSHOT_ISOLATION; ' ELSE N'' END
				+ CASE WHEN [d].[is_broker_enabled] = 1 THEN N'BROKER; ' ELSE N'' END
				+ CASE WHEN [d].[is_cdc_enabled] = 1 THEN N'CDC' ELSE N'' END
				+ CASE WHEN [d].[target_recovery_time_in_seconds] <> 0 THEN N'TARGET_RECOVERY_SECs: ' + CAST([d].[target_recovery_time_in_seconds] AS sysname) ELSE N'' END
				+ CASE WHEN [d].[delayed_durability] <> 0 THEN N'DELAYED_DURABILITY: ' + CAST([d].[delayed_durability] AS sysname) ELSE N'' END
				+ CASE WHEN [d].[is_accelerated_database_recovery_on] = 1 THEN N'ACCELERATED_RECOVERY' ELSE N'' END
				+ CASE WHEN [d].[is_stale_page_detection_on] = 1 THEN N'STALE_PAGE_DETECTION' ELSE N'' END
				-- TODO: add in any other options here that make sense... 
			[advanced_options],
			CASE WHEN [d].[owner_sid] = 0x01 THEN 0 ELSE 1 END [non_sa_owner],
			CASE WHEN [d].[is_auto_close_on] = 1 THEN N'Auto-Close; ' ELSE N'' END
				+ CASE WHEN [d].[is_auto_shrink_on] = 1 THEN N'Auto-Shrink; ' ELSE N'' END
				+ CASE WHEN [d].[is_parameterization_forced] = 1 THEN N'Parameterization-Forced; ' ELSE N'' END
				+ CASE WHEN [d].[is_auto_update_stats_async_on] = 1 THEN 'Auto-Async-Stats; ' ELSE N'' END 
			[smells]
		FROM 
			sys.databases [d]
			LEFT OUTER JOIN [#fileCount] [c] ON [d].[database_id] = [c].[database_id]
			LEFT OUTER JOIN (
				SELECT	database_id, SUM(size) size, COUNT(database_id) [Files] FROM sys.master_files WHERE [type] = 0 GROUP BY database_id
			) [s] ON [d].database_id = [s].database_id
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / 1024.0) AS decimal(24,1)) [log_size] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Size %') [logsize] ON [d].[name] = [logsize].[db_name]
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / 1024.0) AS decimal(24,1)) [log_used] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Used %') [logused] ON [d].[name] = [logused].[db_name]
	)

	SELECT 
		[name],
		[level],
		[state],
		[collation],
		[db_size_gb],
		[log_size_gb],
		[%_log_used] [log_used_pct],
		[recovery],
		[file_counts (d:l:fs:fti)],
		[page_verify],
		[trustworthy],
		[rcsi],
		[advanced_options],
		[non_sa_owner],
		[smells] 
	INTO #intermediate
	FROM 
		core
	ORDER BY 
		[db_size_gb] DESC;


	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- RETURN instead of project.. 
		
		SET @SerializedOutput = (
			SELECT 
				[name],
				[level],
				[state],
				[collation],
				[db_size_gb],
				[log_size_gb],
				[log_used_pct],
				[recovery],
				[file_counts (d:l:fs:fti)] [file_counts_d_l_fs_fti],
				[page_verify],
				[trustworthy],
				[rcsi],
				[advanced_options],
				[non_sa_owner],
				[smells]
			FROM 
				[#intermediate]
			ORDER BY 
				[name]
			FOR XML PATH(N'database'), ROOT(N'databases'), ELEMENTS XSINIL
		)

		RETURN 0;
	END;

	SELECT 
		[name],
		[level],
		[state],
		[collation],
		[db_size_gb],
		[log_size_gb],
		[log_used_pct],
		[recovery],
		[file_counts (d:l:fs:fti)],
		[page_verify],
		[trustworthy],
		[rcsi],
		[advanced_options],
		[non_sa_owner],
		[smells] 
	FROM 
		[#intermediate] 
	ORDER BY 
		[db_size_gb] DESC;

	RETURN 0;
GO