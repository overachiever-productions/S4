/*

	AH... this is what I was looking for - or CLOSE to it: 

					SELECT	page_count,
						record_count,
						record_count / page_count	AS	avg_rows_per_page,
						avg_page_space_used_in_percent
					FROM	sys.dm_db_index_physical_stats
						(
						DB_ID(),
						OBJECT_ID(N'dbo.Customers', N'U'),
						NULL,
						NULL,
						N'DETAILED'
						)
					WHERE	index_level = 0;
					GO
		SOURCE: https://www.red-gate.com/simple-talk/databases/sql-server/t-sql-programming-sql-server/heaps-in-sql-server-part-4-pfs-contention/


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[captive_pages]','P') IS NOT NULL
	DROP PROC dbo.[captive_pages];
GO

CREATE PROC dbo.[captive_pages]
	@databases					nvarchar(MAX)			= N'{USER}',
	--@heaps					nmx						= ... {ALL}							-- TODO: option to TARGET or EXCLUDE specific heaps. ... and I COULD call this @tables ... but I want to be able to specify heaps that are not necessarily tables.
	@sample_size				sysname					= N'1200 rows',						-- { xxx % | xxx rows }
	@serialized_output         xml						= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @databases = ISNULL(NULLIF(@databases, N''), N'{USER}');
	SET @sample_size = ISNULL(NULLIF(@sample_size, N''), N'1200 rows');
	
	DECLARE @intRowCount int; 
	IF @sample_size LIKE '%row%'
		SET @intRowCount = (SELECT CAST([output] AS int) FROM dbo.[extract_numbers](@sample_size));
	ELSE BEGIN
		SET @intRowCount = 0 - (SELECT CAST([output] AS int) FROM dbo.[extract_numbers](@sample_size));
		IF ABS(@intRowCount) < 1 OR ABS(@intRowCount) > 100 BEGIN
			RAISERROR(N'Allowed percentage values for @sample_size must be between 1 - 100.', 16, 1);
			RETURN -1;
		END;
	END;

	CREATE TABLE #heaps ( 
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database] sysname NOT NULL, 
		[heap_name] sysname NOT NULL, 
		[row_count] bigint NOT NULL,
		[reserved_gb] decimal(10,1) NOT NULL,
		[estimated_row_size] int NULL, 
		[sampled_row_size] int NULL
	);

	DECLARE @template nvarchar(MAX) = N'USE [{CURRENT_DB}];
	WITH [metrics] AS ( 
		SELECT
			[ps].[object_id],
			SUM(CASE WHEN ([ps].[index_id] < 2) THEN [row_count] ELSE 0	END) AS [row_count],
			SUM([ps].[reserved_page_count]) AS [reserved]
		FROM
			[sys].[dm_db_partition_stats] [ps]
		GROUP BY
			[ps].[object_id]	
	) 

	INSERT INTO [#heaps] ([database], [heap_name], [row_count], [reserved_gb])
	SELECT
		N''[{CURRENT_DB}]'' [database],
		--[m].[object_id],
		[s].[name] + N''.'' + [t].[name] [heap_name],
		[m].[row_count] [row_count],
		([m].[reserved] * 8) / 1048576.00 [reserved_gb]
	FROM 
		[metrics] [m]
		INNER JOIN sys.[tables] [t] ON [m].[object_id] = [t].[object_id]
		INNER JOIN sys.[schemas] [s] ON [t].[schema_id] = [s].[schema_id];
	'; 



	DECLARE @Errors xml;
	DECLARE @errorContext nvarchar(MAX);
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Statement = @template,
		@Errors = @Errors OUTPUT; 

	IF @Errors IS NOT NULL BEGIN 
		SET @errorContext = N'Unexpected error while extracting table details (per database): ';
		GOTO ErrorDetails;
	END;

	-- foreachdb... get all heaps + sizes and ... estimates? 
	--		maybe, also? get variable columns? 


	-- once i've got all ... 
	--	cursor. yeah. 
	--		rbar ... but per each sample-able heap. 


	-- then ... once all metrics are collected ... 
	-- calculate / check. 


	-- then final projection. 
		
	RETURN 0;
ErrorDetails:
	DECLARE @errorDetails nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	SELECT 
		@errorDetails = @errorDetails + N'DATABASE: ' + QUOTENAME([database_name]) 
		+ @crlftab + N'ERROR_MESSAGE: ' + REPLACE([error_message], @crlf, @crlftab)
		+ @crlftab + [statement] 
		+ @crlf
	FROM 
		dbo.[execute_per_database_errors](@Errors)
	ORDER BY 
		[error_id];

	RAISERROR(@errorContext, 16, 1);
	EXEC dbo.[print_long_string] @errorDetails;	
	RETURN -100;	




