/*



	SAMPLE Execution: 

		EXEC [admindb].dbo.[eventstore_rpt_large_sql_chronology]
			@ExcludeSqlCmd = 0, 
			@ExcludeSqlAgentJobs = 0, 
			@ExcludedStatements = N'%eventstore_etl_processor%, %backup%',
			@MinDurationMilliseconds = 25;



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_rpt_large_sql_chronology]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_rpt_large_sql_chronology];
GO

CREATE PROC dbo.[eventstore_rpt_large_sql_chronology]
	@Start						datetime		= NULL, 
	@End						datetime		= NULL,
	@ExcludeSqlAgentJobs		bit				= 1, 
	@ExcludeSqlCmd				bit				= 1,			-- bit of a hack ... to exclude jobs ... that are executed by admindb... 
	@ExcludedStatements			 nvarchar(MAX)	= NULL,
	@MinCpuMilliseconds			int				= -1, 
	@MinDurationMilliseconds	int				= -1, 
	@MinRowsModifiedCount		int				= -1
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @ExcludeSqlAgentJobs = ISNULL(@ExcludeSqlAgentJobs, 1);
	SET @ExcludeSqlCmd = ISNULL(@ExcludeSqlCmd, 1);
	SET @ExcludedStatements = NULLIF(@ExcludedStatements, N'');
	
	DECLARE @eventStoreKey sysname = N'LARGE_SQL';
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @eventStoreKey); 	

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @eventStoreTarget, 
		@ParameterNameForTarget = N'@eventStoreTarget', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding Predicates and Translations:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	IF @Start IS NULL AND @End IS NULL BEGIN 
		SET @Start = DATEADD(HOUR, -2, GETDATE());
		SET @End = GETDATE();
	  END; 
	ELSE BEGIN 
		IF @Start IS NOT NULL BEGIN 
			SET @End = DATEADD(HOUR, 2, @Start);
		END;

		IF @End IS NULL AND @Start IS NOT NULL BEGIN 
			RAISERROR(N'A value for @End can ONLY be specified if a value for @Start has been provided.', 16, 1);
			RETURN -2;
		END;

		IF @End < @Start BEGIN 
			RAISERROR(N'Specified value for @End can NOT be less than (earlier than) value provided for @Start.', 16, 1);
			RETURN -3;
		END;
	END;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Extraction / Work-Table:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @exclusions nvarchar(MAX) = N'';

	IF @ExcludeSqlAgentJobs = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [application_name] NOT LIKE N''SQLAgent%''';
	END;

	IF @ExcludeSqlCmd = 1 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [application_name] <> N''SQLCMD''';
	END;

	IF @MinCpuMilliseconds > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [cpu_ms] > ' + CAST(@MinCpuMilliseconds AS sysname);
	END;

	IF @MinDurationMilliseconds > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [duration_ms] > ' + CAST(@MinDurationMilliseconds AS sysname);
	END; 

	IF @MinRowsModifiedCount > 0 BEGIN 
		SET @exclusions = @exclusions + @crlftab + N'AND [row_count] > ' + CAST(@MinRowsModifiedCount AS sysname);
	END;

	DECLARE @excludedStatementsJoin nvarchar(MAX) = N'';
	IF @ExcludedStatements IS NOT NULL BEGIN 
		CREATE TABLE #excludedStatements (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[statement] nvarchar(MAX) NOT NULL
		);

		INSERT INTO [#excludedStatements] ([statement])
		SELECT [result] FROM [dbo].[split_string](@ExcludedStatements, N',', 1);
		
		SET @excludedStatementsJoin = @crlftab + N'LEFT OUTER JOIN #excludedStatements [x] ON [s].[statement] LIKE [x].[statement]';
		SET @exclusions = @exclusions + @crlftab + N'AND [x].[statement] IS NULL';

	END;

	CREATE TABLE #metrics (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[timestamp] datetime NULL,
		[database_name] sysname NULL,
		[user_name] sysname NULL,
		[host_name] sysname NULL,
		[application_name] sysname NULL,
		[module] sysname NULL,
		[statement] nvarchar(max) NULL,
		[offset] nvarchar(259) NULL,
		[cpu_ms] bigint NULL,
		[duration_ms] bigint NULL,
		[physical_reads] bigint NULL,
		[writes] bigint NULL,
		[row_count] bigint NULL,
		[report] xml NULL
	);

	DECLARE @sql nvarchar(MAX) = N'SELECT 
	[s].[timestamp],
	[s].[database_name],
	[s].[user_name],
	[s].[host_name],
	[s].[application_name],
	[s].[module],
	[s].[statement],
	[s].[offset],
	[s].[cpu_ms],
	[s].[duration_ms],
	[s].[physical_reads],
	[s].[writes],
	[s].[row_count],
	[s].[report]
FROM 
	{SourceTable} [s]{excludedStatementsJoin}
WHERE
	[timestamp] >= @Start
	AND [timestamp] < @End{exclusions}
ORDER BY 
	[timestamp]; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{excludedStatementsJoin}', @excludedStatementsJoin);
	SET @sql = REPLACE(@sql, N'{exclusions}', @exclusions);

	INSERT INTO [#metrics] (
		[timestamp],
		[database_name],
		[user_name],
		[host_name],
		[application_name],
		[module],
		[statement],
		[offset],
		[cpu_ms],
		[duration_ms],
		[physical_reads],
		[writes],
		[row_count],
		[report]
	)
	EXEC sys.sp_executesql
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Translate SQL Server Agent Job Names: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @ExcludeSqlAgentJobs = 0 BEGIN 
		DECLARE @rowId int;
		DECLARE @currentAppName sysname; 
		DECLARE @jobName sysname;

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[row_id],
			[application_name]
		FROM 
			[#metrics] 
		WHERE 
			[application_name] LIKE N'SQLAgent - TSQL JobStep (Job 0%';
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @rowId, @currentAppName;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
			SET @jobName = NULL;  -- have to reset to NULL for project vs return semantics to work.

			EXEC dbo.[translate_program_name_to_agent_job] 
				@ProgramName = @currentAppName, 
				@IncludeJobStepInOutput = 1, 
				@JobName = @jobName OUTPUT;
			
			UPDATE [#metrics] 
			SET 
				[application_name] = N'SQL Agent Job: ' + @jobName 
			WHERE 
				[row_id] = @rowId;
		
			FETCH NEXT FROM [walker] INTO @rowId, @currentAppName;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

	END;

	SELECT 
		[timestamp],
		[database_name],
		[user_name],
		[host_name],
		[application_name],
		[module],
		[statement],
		[offset],
		[cpu_ms],
		dbo.[format_timespan]([duration_ms]) [duration],
		[physical_reads],
		[writes],
		[row_count],
		[report]
	FROM 
		[#metrics]
	ORDER BY 
		[timestamp];

	RETURN 0;
GO