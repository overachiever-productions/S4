/*

		vNEXT:
			- dbo.extract_statement needs the ability to use/define @OptionalDbTranslationMappings 
					otherwise, if this sproc is run in another environment, we end up grabbing the wrong statements (which is silly/bad/wrong).


		Execution Sample/Tests:

				EXEC [admindb].dbo.[translate_deadlock_trace]
					@SourceXelFilesDirectory = N'D:\Traces\ts',
					@TargetTable = N'Meddling.dbo.xxx_deadlocks',
					@OverwriteTarget = 1,
					@OptionalUTCEndTime = '2020-08-18 03:44:05.069',
					@OptionalDbTranslationMappings = N'';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_deadlock_trace','P') IS NOT NULL
	DROP PROC dbo.[translate_deadlock_trace];
GO

CREATE PROC dbo.[translate_deadlock_trace]
	@SourceXelFilesDirectory				sysname			= N'D:\Traces', 
	@TargetTable							sysname, 
	@OverwriteTarget						bit				= 0,
	@OptionalUTCStartTime					datetime		= NULL, 
	@OptionalUTCEndTime						datetime		= NULL, 
	@OptionalDbTranslationMappings			nvarchar(MAX)	= NULL

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @SourceXelFilesDirectory = ISNULL(@SourceXelFilesDirectory, N'');
	SET @TargetTable = ISNULL(@TargetTable, N'');

	IF @SourceXelFilesDirectory IS NULL BEGIN 
		RAISERROR(N'Please specify a valid directory name for where blocked_process_reports*.xel files can be loaded from.', 16, 1);
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
		RAISERROR('Please specify a @TargetTable value - for storage of output from dbo.translate_deadlock_trace', 16, 1); 
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
	DECLARE @extractionPath nvarchar(200) =  @SourceXelFilesDirectory + '\blocked_process_reports*.xel';

	CREATE TABLE #raw (
		row_id int IDENTITY(1,1) NOT NULL, 
		[object_name] nvarchar(256) NOT NULL, 
		event_data xml NOT NULL, 
		timestamp_utc datetime NOT NULL 
	);
	
	DECLARE @sql nvarchar(MAX) = N'SELECT 
		[object_name],
		CAST([event_data] as xml) [event_data],
		CAST([timestamp_utc] as datetime) [datetime_utc]
	FROM 
		sys.[fn_xe_file_target_read_file](@extractionPath, NULL, NULL, NULL)
	WHERE 
		object_name = N''xml_deadlock_report''
		{DateLimits};';

	DECLARE @dateLimits nvarchar(MAX) = N'';
	IF @OptionalUTCStartTime IS NOT NULL BEGIN 
		SET @dateLimits = N'AND CAST([timestamp_utc] as datetime) >= ''' + CONVERT(sysname, @OptionalUTCStartTime, 121) + N'''';
	END;

	IF @OptionalUTCEndTime IS NOT NULL BEGIN 
		IF NULLIF(@dateLimits, N'') IS NOT NULL BEGIN
			SET @dateLimits = REPLACE(@dateLimits, N'AND ', N'AND (') + N' AND CAST([timestamp_utc] as datetime) <= ''' + CONVERT(sysname, @OptionalUTCEndTime, 121) + N''')'
		  END;
		ELSE BEGIN 
			SET @dateLimits = N'AND CAST([timestamp_utc] as datetime) <= ''' + CONVERT(sysname, @OptionalUTCEndTime, 121) + N'''';
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
			ROW_NUMBER() OVER (ORDER BY [timestamp_utc]) [deadlock_id], 
			DATEADD(HOUR, DATEDIFF(HOUR, GETUTCDATE(), CURRENT_TIMESTAMP), [event_data].value('(event/@timestamp)[1]', 'datetime')) AS [timestamp],
			[event_data] [data]
		FROM 
			[#raw]
	), 
	processes AS ( 
		SELECT 
			c.deadlock_id, 
			c.[timestamp],
			c.[data] [deadlock_graph], 
			p.[rows].value('@id', N'varchar(50)') [process_id], 
			p.[rows].value('@lockMode', N'varchar(10)') lock_mode, 
			p.[rows].value('@spid', N'int') session_id, 
			p.[rows].value('@ecid', N'int') ecid, 
			p.[rows].value('@clientapp', N'varchar(100)') client_application, 
			p.[rows].value('@hostname', N'varchar(100)') [host_name], 
			p.[rows].value('@trancount', N'int') transaction_count, 
			p.[rows].value('@waitresource', N'varchar(200)') wait_resource, 
			p.[rows].value('@waittime', N'int') wait_time, 
			p.[rows].value('@logused', N'bigint') log_used, 
			p.[rows].value('(inputbuf)[1]', 'nvarchar(max)') [input_buffer],
			p.[rows].value('(executionStack/frame/@procname)[1]', 'nvarchar(max)') [proc],
			p.[rows].value('(executionStack/frame)[1]', 'nvarchar(max)') [statement],
			COUNT(*) OVER (PARTITION BY c.[deadlock_id]) [process_count] 
		FROM 
			core c 
			CROSS APPLY c.[data].nodes('//deadlock/process-list/process') p ([rows])
	), 
	victims AS ( 
		SELECT
			c.[deadlock_id],
			v.[values].value('@id', 'varchar(50)') victim_id 
		FROM 
			core c
			CROSS APPLY c.[data].nodes('//deadlock/victim-list/victimProcess') v ([values])
	), 
	aggregated AS ( 
		SELECT 
			[c].[deadlock_id],
			p.process_id,
			ROW_NUMBER() OVER (PARTITION BY [c].[deadlock_id] ORDER BY CASE WHEN v.[victim_id] IS NULL THEN 0 ELSE 1 END) [line_id],
			CASE WHEN [p].[process_id] = v.[victim_id] THEN N'    ' + CAST([p].[session_id] AS sysname)  ELSE CAST([p].[session_id] AS sysname) END [session_id],
			CASE WHEN [p].[process_id] = v.[victim_id] THEN N'    ' + [p].[client_application] ELSE [p].[client_application] END [client_application],
			CASE WHEN [p].[process_id] = v.[victim_id] THEN N'    ' + p.[host_name] ELSE p.[host_name] END [host_name], 
			CASE WHEN [p].[process_id] = v.[victim_id] THEN N'    ' + [p].[input_buffer] ELSE [p].[input_buffer] END [input_buffer] 
		FROM 
			core c
			INNER JOIN [processes] p ON c.[deadlock_id] = p.[deadlock_id]
			LEFT OUTER JOIN [victims] v ON v.[deadlock_id] = c.[deadlock_id] AND p.[process_id] = v.[victim_id]		
	)

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		CASE WHEN [a].[line_id] = 1 THEN CAST(a.[deadlock_id] AS sysname) ELSE N'    ' END [deadlock_id],  
		CASE WHEN [a].[line_id] = 1 THEN CONVERT(sysname, p.[timestamp], 121) ELSE N'' END [timestamp],
		CASE WHEN [a].[line_id] = 1 THEN CAST([p].[process_count] AS sysname) ELSE N'' END [process_count],
		CASE WHEN p.[ecid] = 0 THEN CAST(a.[session_id] AS sysname) ELSE CAST(a.[session_id] AS sysname) + N' (' + CAST([p].[ecid] AS sysname) + N')' END [session_id],
		[a].[client_application],
		[a].[host_name],
		[p].[transaction_count],
		[p].[lock_mode],
		admindb.dbo.[format_timespan]([p].[wait_time]) [wait_time],  -- TODO: is this off or correct? 
		[p].[log_used],
		[p].[wait_resource] [wait_resource_id],
		CAST('' AS varchar(2000)) [wait_resource],
		[p].[proc],
		[p].[statement],
		CAST(N'' AS nvarchar(MAX)) [normalized_statement],
		[a].[input_buffer],
		CASE WHEN [a].[line_id] = 1 THEN [p].[deadlock_graph] ELSE N'' END [deadlock_graph]
	INTO 
		#shredded
	FROM 
		[aggregated] a 
		INNER JOIN [processes] p ON [a].[deadlock_id] = [p].[deadlock_id] AND [a].[process_id] = [p].[process_id]
	ORDER BY 
		a.[deadlock_id], a.[line_id];


	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Statement Normalization: 
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[statement], 
		COUNT(*) [instance_count],  
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#normalized
	FROM 
		[#shredded] 
	GROUP BY 
		[statement];

	DECLARE @rowID int;
	DECLARE @statement nvarchar(MAX); 
	DECLARE @normalized nvarchar(MAX);
	DECLARE @params nvarchar(MAX);
	DECLARE @error nvarchar(MAX);

	DECLARE normalizer CURSOR LOCAL FAST_FORWARD FOR
	SELECT row_id, [statement] FROM #normalized;

	OPEN normalizer;
	FETCH NEXT FROM	normalizer INTO @rowID, @statement;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @normalized = NULL; 

		EXEC dbo.[normalize_text]
			@statement, 
			@normalized OUTPUT, 
			@params OUTPUT, 
			@error OUTPUT;

		UPDATE #normalized
		SET 
			[definition] = @normalized
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM	normalizer INTO @rowID, @statement;
	END;

	CLOSE normalizer;
	DEALLOCATE normalizer;

	UPDATE s 
	SET
		s.[normalized_statement] = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#normalized] x ON s.[statement] = x.[statement]
	WHERE 
		s.[statement] IS NOT NULL;

	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Wait Resource Extraction:
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[wait_resource_id], 
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#waits
	FROM 
		[#shredded] 
	GROUP BY 
		[wait_resource_id]; 
		
	DECLARE @resourceID nvarchar(80);
	DECLARE @resource nvarchar(2000);
	
	DECLARE waiter CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, [wait_resource_id] FROM [#waits];

	OPEN [waiter];
	FETCH NEXT FROM [waiter] INTO @rowID, @resourceID;

	WHILE @@FETCH_STATUS = 0 BEGIN

		EXEC dbo.[extract_waitresource]
			@WaitResource = @resourceID,
			@DatabaseMappings = @OptionalDbTranslationMappings,
			@Output = @resource OUTPUT;

		UPDATE #waits 
		SET 
			[definition] = @resource
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [waiter] INTO @rowID, @resourceID;
	END;

	CLOSE [waiter];
	DEALLOCATE [waiter];

	UPDATE s 
	SET 
		s.wait_resource = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#waits] x ON s.[wait_resource_id] = x.[wait_resource_id];

	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection/Storage:
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @command nvarchar(MAX) = N'USE [{targetDatabase}];

	SELECT 
		[row_id],
		[deadlock_id],
		[timestamp],
		[process_count],
		[session_id],
		[client_application],
		[host_name],
		[transaction_count],
		[lock_mode],
		[wait_time],
		[log_used],
		[wait_resource_id],
		[wait_resource],
		[proc],
		[statement],
		[normalized_statement],
		[input_buffer],
		[deadlock_graph] 
	INTO 
		{targetTableName}
	FROM 
		[#shredded]
	ORDER BY 
		[row_id]; ';

	SET @command = REPLACE(@command, N'{targetDatabase}', @targetDatabase);
	SET @command = REPLACE(@command, N'{targetTableName}', @TargetTable);

	EXEC sp_executesql @command;

	SET @command = N'SELECT COUNT(*) [rows], (SELECT MIN([timestamp]) FROM {targetTableName} WHERE NULLIF([timestamp], N'''') IS NOT NULL) [start], MAX([timestamp]) [end] FROM {targetTableName}; ';
	SET @command = REPLACE(@command, N'{targetTableName}', @TargetTable);

	EXEC sp_executesql @command; 

	RETURN 0;
GO