/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[file_stalls]', N'P') IS NOT NULL
	DROP PROC dbo.[file_stalls];
GO

CREATE PROC dbo.[file_stalls]
	@databases							nvarchar(MAX)		= N'{ALL}', 
	@vector_tag							sysname				= NULL,
	@serialized_output					xml					= N'<default/>'	    OUTPUT

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @databases = UPPER(ISNULL(NULLIF(@databases, N''), N'{ALL}'));
	SET @vector_tag = NULLIF(@vector_tag, N'');	

	SELECT
		DB_NAME([database_id]) [database],
		[file_id],
		[num_of_reads],
		[num_of_bytes_read],
		[io_stall_read_ms],
		[num_of_writes],
		[num_of_bytes_written],
		[io_stall_write_ms],
		[io_stall]
	INTO 
		#current
	FROM
		[sys].dm_io_virtual_file_stats(NULL, NULL);

	IF @vector_tag IS NOT NULL BEGIN 
		DECLARE @cached_date datetime, @cached_xml xml;

		DECLARE @current xml = (
			SELECT
				DB_NAME([database_id]) [@database],
				[file_id] [@file_id],
				[num_of_reads] [@num_reads],
				[num_of_bytes_read] [@num_read_bytes],
				[io_stall_read_ms] [@read_stalls],
				[num_of_writes] [@num_writes],
				[num_of_bytes_written] [@num_write_bytes],
				[io_stall_write_ms] [@write_stalls],
				[io_stall] [@total_stalls]
			FROM
				[sys].dm_io_virtual_file_stats(NULL, NULL)
			FOR XML PATH(N'stall'), ROOT('stalls'), TYPE
		);

		EXEC dbo.[inserlect_cache]
			@vector_type = @@PROCID,
			@vector_key = @vector_tag,
			@current_xml = @current,
			@cached_date = @cached_date OUTPUT,
			@cached_xml = @cached_xml OUTPUT;
		
		IF @cached_date IS NOT NULL BEGIN
			TRUNCATE TABLE [#current];

			WITH [old] AS ( 
				SELECT 
					[s].[stall].value(N'(@database)[1]', N'sysname') [database],
					[s].[stall].value(N'(@file_id)[1]', N'smallint') [file_id],
					[s].[stall].value(N'(@num_reads)[1]', N'bigint') [num_reads],
					[s].[stall].value(N'(@num_read_bytes)[1]', N'bigint') [num_read_bytes],
					[s].[stall].value(N'(@read_stalls)[1]', N'bigint') [read_stalls],
					[s].[stall].value(N'(@num_writes)[1]', N'bigint') [num_writes],
					[s].[stall].value(N'(@num_write_bytes)[1]', N'bigint') [num_write_bytes],
					[s].[stall].value(N'(@write_stalls)[1]', N'bigint') [write_stalls],
					[s].[stall].value(N'(@total_stalls)[1]', N'bigint') [total_stalls]
				FROM 
					@cached_xml.nodes(N'//stalls/stall') [s]([stall])
			), 
			[current] AS (
				SELECT 
					[s].[stall].value(N'(@database)[1]', N'sysname') [database],
					[s].[stall].value(N'(@file_id)[1]', N'smallint') [file_id],
					[s].[stall].value(N'(@num_reads)[1]', N'bigint') [num_reads],
					[s].[stall].value(N'(@num_read_bytes)[1]', N'bigint') [num_read_bytes],
					[s].[stall].value(N'(@read_stalls)[1]', N'bigint') [read_stalls],
					[s].[stall].value(N'(@num_writes)[1]', N'bigint') [num_writes],
					[s].[stall].value(N'(@num_write_bytes)[1]', N'bigint') [num_write_bytes],
					[s].[stall].value(N'(@write_stalls)[1]', N'bigint') [write_stalls],
					[s].[stall].value(N'(@total_stalls)[1]', N'bigint') [total_stalls]
				FROM 
					@current.nodes(N'//stalls/stall') [s]([stall])
			), 
			[vectored] AS (
				SELECT 
					[old].[database],
					[old].[file_id],
					[current].[num_reads] - [old].[num_reads] [num_reads],
					[current].[num_read_bytes] - [old].[num_read_bytes] [num_read_bytes],
					[current].[read_stalls] - [old].[read_stalls] [read_stalls],
					[current].[num_writes] - [old].[num_writes] [num_writes],
					[current].[num_write_bytes] - [old].[num_write_bytes] [num_write_bytes],
					[current].[write_stalls] - [old].[write_stalls] [write_stalls],
					[current].[total_stalls] - [old].[total_stalls] [total_stalls]
				FROM 
					[old]
					LEFT OUTER JOIN [current] ON [old].[database] = [current].[database] AND [old].[file_id] = [current].[file_id]

			)

			INSERT INTO [#current] (
				[database],
				[file_id],
				[num_of_reads],
				[num_of_bytes_read],
				[io_stall_read_ms],
				[num_of_writes],
				[num_of_bytes_written],
				[io_stall_write_ms],
				[io_stall]
			)
			SELECT 
				[database],
				[file_id],
				[num_reads],
				[num_read_bytes],
				[read_stalls],
				[num_writes],
				[num_write_bytes],
				[write_stalls],
				[total_stalls]
			FROM 
				[vectored];
		END;

	END; 

	CREATE TABLE #filtered (
		[database] sysname NOT NULL,
		[file_id] smallint NOT NULL,
		[num_of_reads] bigint NOT NULL,
		[num_of_bytes_read] bigint NOT NULL,
		[io_stall_read_ms] bigint NOT NULL,
		[num_of_writes] bigint NOT NULL,
		[num_of_bytes_written] bigint NOT NULL,
		[io_stall_write_ms] bigint NOT NULL,
		[io_stall] bigint NOT NULL
	);

	IF @databases IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_databases ([row_id] int IDENTITY(1,1) NOT NULL, [database] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [database]));
	END;

	DECLARE @sql nvarchar(MAX) = N'SELECT
	[x].[database],
	[x].[file_id],
	[x].[num_of_reads],
	[x].[num_of_bytes_read],
	[x].[io_stall_read_ms],
	[x].[num_of_writes],
	[x].[num_of_bytes_written],
	[x].[io_stall_write_ms],
	[x].[io_stall] 
FROM 
	[#current] [x]{JOINs}{WHERE}; ';

	IF @databases <> N'{ALL}' BEGIN

		DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
		EXEC dbo.[core_predicates]
			@Databases = @databases,
			@JoinPredicates = @joins OUTPUT,
			@FilterPredicates = @filters OUTPUT;

		SET @sql = REPLACE(@sql, N'{JOINs}', @joins);

		IF NULLIF(@filters, N'') IS NULL 
			SET @sql = REPLACE(@sql, N'{WHERE}', N'');
		ELSE 
			SET @sql = REPLACE(@sql, N'{WHERE}', NCHAR(13) + NCHAR(10) + N'WHERE ' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'1 = 1' + @filters); 
	  END;
	ELSE BEGIN
		SET @sql = REPLACE(@sql, N'{JOINs}', N'');
		SET @sql = REPLACE(@sql, N'{WHERE}', N'');
	END;

	INSERT INTO [#filtered] (
		[database],
		[file_id],
		[num_of_reads],
		[num_of_bytes_read],
		[io_stall_read_ms],
		[num_of_writes],
		[num_of_bytes_written],
		[io_stall_write_ms],
		[io_stall]
	)
	EXEC sys.[sp_executesql]
		@sql;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Return or Project:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				[x].[database] [@database],
				[x].[file_id] [@file_id],
				[m].[physical_name] [@file_name],
				ISNULL([x].[io_stall_read_ms] / NULLIF([x].[num_of_reads], 0), 0) [@avg_read_ms],
				ISNULL([x].[io_stall_write_ms] / NULLIF([x].num_of_writes, 0), 0) [@avg_write_ms],
				ISNULL([x].[io_stall] / NULLIF([x].[num_of_reads] + [x].[num_of_writes], 0), 0) [@avg_total_ms], 
				CAST(ISNULL([x].[num_of_bytes_read] / NULLIF([x].[num_of_writes], 0), 0) / 1024. AS decimal(22,2)) [@avg_read_kb],
				CAST(ISNULL([x].[num_of_bytes_written] / NULLIF([x].[num_of_writes], 0), 0) / 1024. AS decimal(22,2)) [@avg_write_kb]
			FROM 
				[#filtered] [x]
				INNER JOIN sys.[master_files] [m] ON DB_ID([x].[database]) = [m].[database_id] AND [x].[file_id] = [m].[file_id]
			FOR XML PATH(N'stall'), ROOT(N'stalls'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[x].[database],
		[x].[file_id],
		[m].[physical_name] [file_name],
		ISNULL([x].[io_stall_read_ms] / NULLIF([x].[num_of_reads], 0), 0) [avg_read_ms],
		ISNULL([x].[io_stall_write_ms] / NULLIF([x].num_of_writes, 0), 0) [avg_write_ms],
		ISNULL([x].[io_stall] / NULLIF([x].[num_of_reads] + [x].[num_of_writes], 0), 0) [avg_total_ms], 
		CAST(ISNULL([x].[num_of_bytes_read] / NULLIF([x].[num_of_writes], 0), 0) / 1024. AS decimal(22,2)) [avg_read_kb],
		CAST(ISNULL([x].[num_of_bytes_written] / NULLIF([x].[num_of_writes], 0), 0) / 1024. AS decimal(22,2)) [avg_write_kb]
	FROM 
		[#filtered] [x]
		INNER JOIN sys.[master_files] [m] ON DB_ID([x].[database]) = [m].[database_id] AND [x].[file_id] = [m].[file_id];

	RETURN 0;
GO