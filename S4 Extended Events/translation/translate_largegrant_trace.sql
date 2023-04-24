/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_largegrant_trace','P') IS NOT NULL
	DROP PROC dbo.[translate_largegrant_trace];
GO

CREATE PROC dbo.[translate_largegrant_trace]
	@SourceXelFilesDirectory				sysname			= N'D:\Traces', 
	@TargetTable							sysname, 
	@OverwriteTarget						bit				= 0,
	@OptionalStartTime						datetime		= NULL, 
	@OptionalEndTime						datetime		= NULL, 
	@TimeZone								sysname			= N'{SERVER_LOCAL}'
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @SourceXelFilesDirectory = ISNULL(@SourceXelFilesDirectory, N'');
	SET @TargetTable = ISNULL(@TargetTable, N'');
	SET @TimeZone = NULLIF(@TimeZone, N'');

	IF @SourceXelFilesDirectory IS NULL BEGIN 
		RAISERROR(N'Please specify a valid directory name for where large_memory_grant*.xel files can be loaded from.', 16, 1);
		RETURN -1;
	END;

	SELECT @SourceXelFilesDirectory = dbo.[normalize_file_path](@SourceXelFilesDirectory);
	DECLARE @exists bit; 
	EXEC dbo.[check_paths] @Path = @SourceXelFilesDirectory, @Exists = @exists OUTPUT;
	IF @exists <> 1 BEGIN 
		RAISERROR(N'Invalid directory, %s,  specified for @SourceXelFilesDirectory. Target directory NOT found on current SQL Server instance.', 16, 1, @SourceXelFilesDirectory);
		RETURN -2
	END;

	IF @TargetTable IS NULL BEGIN 
		RAISERROR('Please specify a @TargetTable value - for storage of output from dbo.translate_largegrant_trace', 16, 1); 
		RETURN -2;
	END; 

	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
	SELECT 
		@targetDatabase = PARSENAME(@TargetTable, 3), 
		@targetSchema = ISNULL(PARSENAME(@TargetTable, 2), N'dbo'), 
		@targetObjectName = PARSENAME(@TargetTable, 1);
	
	IF @targetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		
		IF @targetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. Please use dbname.schemaname.objectname qualified names.', 16, 1, N'@TargetTable');
			RETURN -5;
		END;
	END;

	-- normalize:
	SELECT @TargetTable = N'[' + @targetDatabase + N'].[' + @targetSchema + N'].[' + @targetObjectName + N']';

	-- Determine if @TargetTable already exists:
	DECLARE @targetObjectID int;
	DECLARE @check nvarchar(MAX) = N'SELECT @targetObjectID = OBJECT_ID(''' + @TargetTable + N''');'

	EXEC [sys].[sp_executesql] 
		@check, 
		N'@targetObjectID int OUTPUT', 
		@targetObjectID = @targetObjectID OUTPUT; 

	IF @targetObjectID IS NOT NULL BEGIN 
		IF @OverwriteTarget = 1 BEGIN
			DECLARE @drop nvarchar(MAX) = N'USE [' + PARSENAME(@TargetTable, 3) + N']; DROP TABLE [' + PARSENAME(@TargetTable, 2) + N'].[' + PARSENAME(@TargetTable, 1) + N'];';
			
			EXEC sys.sp_executesql @drop;

		  END;
		ELSE BEGIN
			RAISERROR('@TargetTable %s already exists. Please either drop it manually, or set @OverwriteTarget to a value of 1 during execution of this sproc.', 16, 1);
			RETURN -5;
		END;
	END;	

	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- XEL Extraction: 
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @extractionPath nvarchar(200) =  @SourceXelFilesDirectory + '\large_memory_grants*.xel';

	CREATE TABLE #raw (
		row_id int IDENTITY(1,1) NOT NULL, 
		[object_name] nvarchar(256) NOT NULL, 
		event_data xml NOT NULL, 
		timestamp_utc datetime NOT NULL 
	);
	
	DECLARE @sql nvarchar(MAX) = N'	SELECT 
		[object_name],
		CAST([event_data] as xml) [event_data],
		CAST([timestamp_utc] as datetime) [datetime_utc]
	FROM 
		sys.[fn_xe_file_target_read_file](@extractionPath, NULL, NULL, NULL)
	WHERE 
		object_name = N''degree_of_parallelism'' {DateLimits};';

	DECLARE @dateLimits nvarchar(MAX) = N'';
	DECLARE @nextLine nchar(4) = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9);
	
	IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
		SET @TimeZone = dbo.[get_local_timezone]();

	DECLARE @offsetMinutes int = 0;
	IF @TimeZone IS NOT NULL
		SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);

	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @dateLimits = @nextLine + N'AND [timestamp_utc] >= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalStartTime), 121) +  N'''';
	END;

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF NULLIF(@dateLimits, N'') IS NOT NULL BEGIN
			SET @dateLimits = REPLACE(@dateLimits, N'AND ', N'AND (') + N')' + @nextLine + N'AND ([timestamp_utc] <= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime), 121) + N''')';
		  END;
		ELSE BEGIN 
			SET @dateLimits = @nextLine + N'AND [timestamp_utc] <= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime), 121) + N'''';
		END;
	END;

	SET @sql = REPLACE(@sql, N'{DateLimits}', @dateLimits);

	INSERT INTO [#raw] (
		[object_name],
		[event_data],
		[timestamp_utc]
	)
	EXEC sys.sp_executesql 
		@sql, 
		N'@extractionPath nvarchar(200)', 
		@extractionPath = @extractionPath;

	-- intermediate projection:
	WITH core AS ( 
		SELECT 
			ROW_NUMBER() OVER (ORDER BY [timestamp_utc]) [report_id], 
			DATEADD(HOUR, DATEDIFF(HOUR, GETUTCDATE(), CURRENT_TIMESTAMP), [event_data].value('(event/@timestamp)[1]', 'datetime')) AS [timestamp],
			[event_data]
		FROM 
			[#raw]
	), 
	extracted AS ( 
		SELECT 
			[c].[report_id], 
			[c].[timestamp], 
			[c].[event_data].value('(/event/action[@name=''database_name'']/value)[1]','sysname')																AS [database],
			[c].[event_data].value('(/event/data[@name=''dop'']/value)[1]', 'int')																				AS [dop],
			[c].[event_data].value('(/event/data[@name=''workspace_memory_grant_kb'']/value)[1]','bigint')														AS [memory_grant_kb],
			[c].[event_data].value('(/event/action[@name=''client_hostname'']/value)[1]','varchar(max)')														AS [host_name],
			[c].[event_data].value('(/event/action[@name=''client_app_name'']/value)[1]', 'varchar(max)')														AS [application_name],
			[c].[event_data].value('(/event/action[@name=''is_system'']/value)[1]', 'bit')																		AS [is_system],
			[c].[event_data].value('(/event/data[@name=''statement_type'']/text)[1]','varchar(max)')															AS [statement_type], 
			[c].[event_data].value('(/event/action[@name=''sql_text'']/value)[1]','varchar(max)')																AS [statement],
			[c].[event_data].value('(/event/action[@name=''query_hash_signed'']/value)[1]','varchar(max)')														AS [query_hash_signed],
			[c].[event_data].value('(/event/action[@name=''query_plan_hash_signed'']/value)[1]','varchar(max)')													AS [query_plan_hash_signed],
			CONVERT(varbinary(64), N'0x' + [c].[event_data].value('(/event/action[@name=''plan_handle'']/value)[1]', 'nvarchar(max)'), 1)						AS [plan_handle], 
			[c].event_data [raw_data]

		FROM 
			[core] c
	)
	
	SELECT 
		[e].[report_id],
		[e].[timestamp],
		[e].[database],
		[e].[dop],
		CAST(([e].[memory_grant_kb] / (1024.0 * 1024.0)) AS decimal(12,2)) [memory_grant_gb],
		[e].[host_name],
		[e].[application_name],
		[e].[is_system],
		[e].[statement_type],
		[e].[statement],
		[e].[query_hash_signed],
		[e].[query_plan_hash_signed],
		[e].[plan_handle],
		[e].[raw_data]
	INTO 
		#shredded
	FROM 
		extracted e
	ORDER BY 
		e.[report_id];


	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection/Storage:
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @command nvarchar(MAX) = N'USE [{targetDatabase}];

	SELECT 
		[report_id],
		[timestamp],
		[database],
		[dop],
		[memory_grant_gb],
		[host_name],
		[application_name],
		[is_system],
		[statement_type],
		[statement],
		[query_hash_signed],
		[query_plan_hash_signed],
		[plan_handle],
		[raw_data]
	INTO 
		{targetTableName}
	FROM 
		[#shredded]
	ORDER BY 
		[report_id]; ';

	SET @command = REPLACE(@command, N'{targetDatabase}', @targetDatabase);
	SET @command = REPLACE(@command, N'{targetTableName}', @TargetTable);

	EXEC sp_executesql @command;

	-- output a summary: 
	SET @command = N'SELECT COUNT(*) [rows], (SELECT MIN([timestamp]) FROM {targetTableName} WHERE NULLIF([timestamp], N'''') IS NOT NULL) [start], MAX([timestamp]) [end] FROM {targetTableName}; ';
	SET @command = REPLACE(@command, N'{targetTableName}', @TargetTable);

	EXEC sp_executesql @command; 

	RETURN 0;
GO