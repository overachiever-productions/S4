/*


-- check to see if there's anything here that I'm missing: https://www.sqlfingers.com/2025/12/the-queries-eating-your-tempdb-alive.html



--------------------------------------------------------------------------------------------
FROM 'original' tempdb_consumers:
        Implement weaponized version of this:
            D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Diagnostics\tempdb space consumers.sql

        or this: 
            (bottom part):
            D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Diagnostics\tempdb diagnostics.sql

--------------------------------------------------------------------------------------------


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[tempdb_consumers]', N'P') IS NOT NULL
	DROP PROC dbo.[tempdb_consumers];
GO

CREATE PROC dbo.[tempdb_consumers]
	@IncludeDetails				bit				= 0
AS
    SET NOCOUNT ON; 

	SET @IncludeDetails = ISNULL(@IncludeDetails, 0);

	-- {copyright}
	
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Note: DB Sizing Code stolen from SSMS' Database Size Report (and made dynamic/etc.)
	-----------------------------------------------------------------------------------------------------------------------------------------------------	
	DECLARE @tempdbSize int; 
	DECLARE @tempLogSize int;

	DECLARE @sql nvarchar(MAX) = N'USE [tempdb];
		DECLARE @dbsize bigint;
		DECLARE @logsize bigint;
		DECLARE @database_size_mb float;
		DECLARE @unallocated_space_mb float;
		DECLARE @reserved_mb float;
		DECLARE @data_mb float;
		DECLARE @log_size_mb float;
		DECLARE @reservedpages bigint;
		DECLARE @pages bigint;

		SELECT
			@dbsize = SUM(CONVERT(bigint, CASE WHEN [status] & 64 = 0 THEN [size] ELSE 0 END)),
			@logsize = SUM(CONVERT(bigint, CASE WHEN [status] & 64 != 0 THEN [size] ELSE 0 END))
		FROM
			[dbo].[sysfiles];

		SELECT
			@reservedpages = SUM([a].[total_pages]),
			@pages = SUM(
				CASE
					WHEN [it].[internal_type] IN (202, 204) THEN 0
					WHEN [a].[type] != 1 THEN [a].[used_pages]
					WHEN [p].[index_id] < 2 THEN [a].[data_pages]
					ELSE 0
				END)
		FROM
			[tempdb].[sys].[partitions] [p]
			JOIN [tempdb].[sys].[allocation_units] [a] ON [p].[partition_id] = [a].[container_id]
			LEFT JOIN [tempdb].[sys].[internal_tables] [it] ON [p].[object_id] = [it].[object_id];

		SELECT @database_size_mb = (CONVERT(dec(19, 2), @dbsize) + CONVERT(dec(19, 2), @logsize)) * 8192 / 1048576.0;

		SELECT @unallocated_space_mb = (CASE WHEN @dbsize >= @reservedpages THEN (CONVERT(dec(19, 2), @dbsize) - CONVERT(dec(19, 2), @reservedpages)) * 8192 / 1048576.0 ELSE 0 END);

		SELECT @reserved_mb = @reservedpages * 8192 / 1048576.0;
		SELECT @data_mb = @pages * 8192 / 1048576.0;
		SELECT @log_size_mb = CONVERT(dec(19, 2), @logsize) * 8192 / 1048576.0; 
			
		--SELECT
		--(@reserved_mb + @unallocated_space_mb) [data_size],
		--@log_size_mb AS [transaction_log_size]; 
		
		SELECT
			@tempdbSize = (@reserved_mb + @unallocated_space_mb),
			@tempLogSize = @log_size_mb; ';


	EXEC sys.sp_executesql 
		@sql, 
		N'@tempdbSize int OUTPUT, @tempLogSize int OUTPUT', 
		@tempdbSize = @tempdbSize OUTPUT, 
		@tempLogSize = @tempLogSize OUTPUT; 

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- tempdb file count:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @fileCount int; 
	SELECT @fileCount = COUNT(*) FROM sys.[master_files] WHERE [database_id] = 2 AND [type] = 0;


	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- TempTables and Spills Usage:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @tempTablesAllocated decimal(24,2);
	DECLARE @tempTablesDeallocated decimal(24,2);
	DECLARE @spillsAllocated decimal(24,2);
	DECLARE @spillsDeallocated decimal(24,2);
	
	DECLARE @tempTablesGB decimal(24,2);
	DECLARE @spillsGB decimal(24,2);
	
	WITH core AS ( 
		SELECT 
			CAST(SUM(user_objects_alloc_page_count) / 128.0 / 1024.0 AS decimal(24,2)) [temp_tables], 
			CAST(SUM(user_objects_dealloc_page_count) / 128.0 / 1024.0 AS decimal(24,2)) [x_temp_tables], 
			CAST(SUM(internal_objects_alloc_page_count) / 128.0 / 1024.0 AS decimal(24,2)) [spills],
			CAST(SUM(internal_objects_dealloc_page_count) / 128.0 / 1024.0 AS decimal(24,2)) [x_spills]
		FROM 
			tempdb.sys.[dm_db_session_space_usage]
	)

	SELECT 
		@tempTablesAllocated = [temp_tables],
		@tempTablesDeallocated = [x_temp_tables],
		@tempTablesGB = [temp_tables] - [x_temp_tables],
		@spillsAllocated = [spills],
		@spillsDeallocated = [x_spills], 
		@spillsGB = [spills] - [x_spills]
	FROM 
		core; 

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Version Store, Free Space, and internals:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @internalsSize decimal(24,2);
	DECLARE @tempdbFreeSpace decimal(24,2);
	DECLARE @versionStoreSize decimal(24,2); 

	SELECT
		@internalsSize = CAST((SUM(internal_object_reserved_page_count) / 128.0 / 1024.0) AS decimal(24,2)), 
		@tempdbFreeSpace = CAST((SUM(unallocated_extent_page_count) / 128.0 / 1024.0) AS decimal(24,2)), 
		@versionStoreSize = CAST((SUM(version_store_reserved_page_count) / 128 / 1024.0) AS decimal(24,2)) 
	FROM 
		tempdb.sys.dm_db_file_space_usage;

	WITH core AS ( 
		SELECT 
			CAST(@tempdbSize / 1024.0 AS decimal(24,2)) [tempdb_size_gb], 
			CAST(@tempLogSize / 1024.0 AS decimal(24,2)) [tempdb_log], 
			@fileCount [tempdb_file_count], 
			CASE WHEN @tempTablesGB > 0 THEN @tempTablesGB ELSE 0.0 END [temp_tables_gb], 
			CASE WHEN @spillsGB > 0 THEN @spillsGB ELSE 0.0 END [spills_gb], 
			@versionStoreSize [version_store_gb],
			@internalsSize [internals_gb],
			@tempdbFreeSpace [free_gb]
			
	)

	SELECT
		[core].[tempdb_file_count],
		[core].[tempdb_size_gb],
		[core].[tempdb_log],
		N' ' [ ],
		[core].[temp_tables_gb],
		[core].[spills_gb],
		[core].[version_store_gb],
		[core].[internals_gb],
		[core].[free_gb] 
	FROM 
		core;

	IF @IncludeDetails = 1 BEGIN 
		SELECT 
			@tempTablesAllocated [allocated_temp_tables_gb], 
			@tempTablesDeallocated [deallocated_temp_tables_gb], 
			@spillsAllocated [allocated_spills_gb], 
			@spillsDeallocated [deallocated_spills_gb], 
			N' ' [ ], 
			CAST(@tempdbSize / 1024.0 AS decimal(24,2)) - (@tempTablesGB + @spillsGB + @versionStoreSize + @internalsSize + @tempdbFreeSpace) [churn_gb]
	END;

	RETURN 0; 
GO	