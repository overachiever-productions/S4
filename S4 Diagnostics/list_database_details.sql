/*

	-- Barely even a stub at this point... 

	Here's what I want this to show (i.e., a list of columns): 
		- database_name
		- state_desc
		- mirrored or AG'd or read-only or any other non-standard-ish something... 
		- file_count
		- files (xml with a list of files in it - i.e., each file's id, type, logical-name, physical-name, size, used%/free%). 
		- db_size
		- db_space_free
		- db_size_%_used
		- log size
		- log_%_used
		- log_as_%_of_db_size (better name needed, obviously)
		- total_vlfs_count
		- '' (spacer)
		- recovery_model
		- page_verify
		- compat_level
		- snapshot_isolation
		- rcsi (0 or 1)
		- problems (comma-delimited list of issues like, auto_close, auto_shrink, parameterization_forced, async_stats_off, etc. 
		

HERE's how to get space used (free) for DATA FILES (it's really the ONLY way I've got - unless I want to do sp_space_used/etc.)
	FODDER: 

						SELECT
							DB_NAME() [database_name],
							[name] AS [file_name],
							CAST(([size] / 128.0) AS decimal(22,2)) AS [file_size_mb],
							CAST(([size] / 128.0 - CAST(FILEPROPERTY([name], 'SpaceUsed') AS int) / 128.0) AS decimal(22,2)) AS [free_space_mb]
						FROM
							[sys].[database_files];


						--SELECT * FROM sys.[database_files];

	 Basically, just create a dynamic query that iterates through each DB, and drops the results of the ABOVE into #space-used table... so'z I can do JOINs against it later on... 




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_database_details','P') IS NOT NULL
	DROP PROC dbo.list_database_details;
GO

CREATE PROC dbo.list_database_details
    @TargetDatabases                nvarchar(MAX)   = N'{ALL}', 
    @ExcludedDatabases              nvarchar(MAX)   = NULL, 
    @Priorities                     nvarchar(MAX)   = NULL
AS 
    SET NOCOUNT ON; 

    -- {copyright}

    -- basically run the following - but :
    --      a) more extended (i.e., drop options and such via XML details)
    --      b) faster/more-performant
    --      c) filters and such to exclude some things... 
    --      d) version-enabled (i.e, 2008R2 - 2019 etc... )
    --      e) include VLF counts as well, etc. (min t-log size and everything - but as an @Include blah)


	-------------------------------------------------------------------------------
	-- Database basics/File Placement/etc
	SELECT DB_NAME([database_id])AS [Database Name], 
		   [file_id], name, physical_name, type_desc, state_desc, 
		   CONVERT( bigint, size/128.0) AS [Total Size in MB]
	FROM sys.master_files
	WHERE [database_id] > 4 
	AND [database_id] <> 32767
	OR [database_id] = 2
	ORDER BY [Total Size in MB] DESC;

	----------------------------------------------------------------
	-- overview of databases:

	SELECT
		db.[name] [db_name], 
		CONVERT(decimal(20,2), sizes.size * 8.0 / 1024) [db_size_MB],
		logsize.log_size [log_size_MB],
		CASE 
			WHEN logsize.log_size = 0 THEN -1.0
			WHEN logused.log_used = 0 THEN 0.0
			ELSE CAST(((logused.log_used / logsize.log_size) * 100.0) AS decimal(5,2))
		END [%_log_used],
		db.recovery_model_desc [RecoveryModel],
		db.page_verify_option_desc [Page Verify],
		sizes.Files [NumberOfNonLogFiles],
		-- TODO: addin max-size/Growth (but that's hard cuz of > 1 FILE option)
		-- TODO: add % of data files used. 
		(SELECT COUNT(database_id) FROM master.sys.master_files WHERE [type] IN (0,2) AND database_id = db.database_id) [FSorFTIFiles],
		db.[compatibility_level]
	FROM 
		sys.databases db
		LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / 1024.0) AS decimal(20,2)) [log_size] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Size %') logsize ON db.[name] = logsize.[db_name]
		LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / 1024.0) AS decimal(20,2)) [log_used] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Used %') logused ON db.[name] = logused.[db_name]
		LEFT OUTER JOIN (
			SELECT	database_id, SUM(size) size, COUNT(database_id) [Files] FROM sys.master_files WHERE [type] = 0 GROUP BY database_id
		) sizes ON db.database_id = sizes.database_id
	ORDER BY 
		sizes.size DESC;


	-- include this as a 'feature' above... 

	-- Bad/Potentially-Problematic databases:
	SELECT 
		name,
		is_read_only,
		is_auto_close_on,
		is_auto_shrink_on,
		is_parameterization_forced, 
		is_auto_create_stats_on, 
		is_auto_update_stats_async_on,
		snapshot_isolation_state_desc,
		is_read_committed_snapshot_on
	FROM master.sys.databases 
	WHERE 
		is_read_only = 1 OR
		is_auto_shrink_on = 1 OR
		is_auto_close_on = 1 OR
		is_parameterization_forced = 1 OR
		is_auto_create_stats_on = 0 OR
		is_auto_update_stats_async_on = 1 OR
		(snapshot_isolation_state_desc = 'ON' AND name NOT IN ('master','msdb')) OR
		is_read_committed_snapshot_on = 1;  
