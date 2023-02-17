/*



			EXEC [admindb].dbo.[translate_memory_counters] 
				@SourceTable = N'FISSQL3_Consolidated', 
				@TargetTable = N'FISSQL3_Memory', 
				@OverwriteTarget = 1, 
				@PrintOnly = 0;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_memory_counters','P') IS NOT NULL
	DROP PROC dbo.[translate_memory_counters];
GO

CREATE PROC dbo.[translate_memory_counters]
	@SourceTable			sysname, 
	@TargetTable			sysname, 
	@OverwriteTarget		bit				= 0, 
	@PrintOnly				bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @SourceTable, 
		@ParameterNameForTarget = N'@SourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  /* error will have already been raised... */
	
	IF UPPER(@TargetTable) = UPPER(@SourceTable) BEGIN 
		RAISERROR('@SourceTable and @TargetTable can NOT be the same - please specify a new/different name for the @TargetTable parameter.', 16, 1);
		RETURN -1;
	END;

	IF @TargetTable IS NULL BEGIN 
		RAISERROR('Please specify a @TargetTable value - for the output of dbo.translate_cpu_perfcounters', 16, 1); 
		RETURN -2;
	END; 

	/* Translate @TargetTable details: */
	SELECT @TargetTable = N'[' + ISNULL(PARSENAME(@TargetTable, 3), PARSENAME(@normalizedName, 3)) + N'].[' + ISNULL(PARSENAME(@TargetTable, 2), PARSENAME(@normalizedName, 2)) + N'].[' + PARSENAME(@TargetTable, 1) + N']';
	
	/* Determine if @TargetTable already exists: */
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

	DECLARE @targetDBName sysname = PARSENAME(@normalizedName, 3);
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX);

	DECLARE @sampleRow nvarchar(200);

	SET @sql = N'SET @sampleRow = (SELECT TOP 1 [name] FROM [' + @targetDBName + N'].sys.[all_columns] WHERE [object_id] = OBJECT_ID(''' + @normalizedName + N''') AND column_id > 1);';

	EXEC sp_executesql 
		@sql, 
		N'@sampleRow nvarchar(200) OUTPUT',
		@sampleRow = @sampleRow OUTPUT;

	DECLARE @serverName sysname; 
	DECLARE @instanceNamePrefix sysname;
	
	SET @serverName = SUBSTRING(@sampleRow, 3, LEN(@sampleRow));
	SET @serverName = SUBSTRING(@serverName, 0, CHARINDEX(N'\', @serverName));

	IF NULLIF(@serverName, N'') IS NULL BEGIN 
		RAISERROR(N'Unable to extract Server-Name from input .csv file. Processing cannot continue.', 16, 1);
		RETURN -9;
	END;
	
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

	-------------------------------------------------------------------------------------------------------------------------	
	
	DECLARE @statement nvarchar(MAX) = N'WITH [translated] AS (
	SELECT 
		TRY_CAST([{timeZone}] AS datetime) [timestamp],
		N''' + @serverName + N''' [server_name],
		CAST(['+ @instanceNamePrefix + N'Buffer Manager\Page life expectancy] as int) [ple],
		CAST((['+ @instanceNamePrefix + N'Memory Manager\Granted Workspace Memory (KB)] / (1024.0 * 1024.0)) as decimal(22,2)) [granted_workspace_memory_GBs],
		CAST(['+ @instanceNamePrefix + N'Memory Manager\Memory Grants Outstanding] as int) [grants_outstanding],
		CAST(['+ @instanceNamePrefix + N'Memory Manager\Memory Grants Pending] as int) [grants_pending],
		['+ @instanceNamePrefix + N'SQL Statistics\Batch Requests/sec] [batch_requests/second]
	FROM 
		{normalizedName}
)

SELECT 
	[timestamp],
	[server_name],
	[ple],
	[granted_workspace_memory_GBs],
	[grants_outstanding],
	[grants_pending],
	[batch_requests/second]  
INTO 
	{TargetTable} 
FROM 
	[translated]
ORDER BY 
	[timestamp] ';

	SET @statement = REPLACE(@statement, N'{normalizedName}', @normalizedName); 
	SET @statement = REPLACE(@statement, N'{timeZone}', @timeZone);

	SET @statement = REPLACE(@statement, N'{serverName}', @serverName);
	SET @statement = REPLACE(@statement, N'{TargetTable}', @TargetTable);

	IF @PrintOnly = 1 BEGIN 
		EXEC dbo.[print_long_string] @statement; 
	  END; 
	ELSE BEGIN 
		EXEC sp_executesql @statement;

		SET @statement = N'SELECT COUNT(*) [total_rows_exported] FROM ' + @TargetTable + N'; ';
		EXEC [sys].[sp_executesql] @statement;

	END; 
		
	RETURN 0; 
GO