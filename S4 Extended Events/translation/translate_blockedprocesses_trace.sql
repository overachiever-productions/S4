/*

		vNEXT:
			- dbo.extract_statement needs the ability to use/define @OptionalDbTranslationMappings 
					otherwise, if this sproc is run in another environment, we end up grabbing the wrong statements (which is silly/bad/wrong).

			- Change @OverwriteTarget to 
				@BehaviorOnTargetTableExists sysname	= { OVERWRITE | ADD } 

					where OVERWRITE is the same as current/now behavior.	
					and ADD = a) find the start/stop of the data in the current @TargetTable... b) grab anything from the new @Source... that isn't in the range defined/calculated from step a
								and, c) shove the 'union' of said data into the table 
									this way we can add new/additional data ('before' or 'after' whatever is there) to help look for other patterns/behaviors and the likes.
				
				ALSO: MIGHT not need to do the above by means of @startTime and @endTime - i.e., there might be other markers or details I can use to help differentiate data
					that has already been imported/translated vs what's 'targetted'. 
						easy example would be the report_id - assuming that doesn't get reset if/when the trace is stopped/resttarted (which it DOES). 
							but... reportID and, say... txid or some combination of something to exclude duplicates is really all i need. 

							further, might make more sense to just shove data into a staging table (which I do)
								then... UNION it into the @TargetTable as the last step - i.e., not sure how much benefit there is to trying to isolate 'new data ONLY'
									during the intial process. (unless, of course, tons of the data we're processing has already been processed...)


	
		Execution Examples/Tests: 

				EXEC [admindb].dbo.[translate_blockedprocesses_trace]
					@SourceXelFilesDirectory = N'D:\Traces\ts',
					@TargetTable = N'Meddling.dbo.xxx_blocked',
					@OverwriteTarget = 1,
					@OptionalUTCStartTime = '2020-08-18 03:41:04.500', 
					@OptionalUTCEndTime = '2020-08-18 03:44:05.069',
					@OptionalDbTranslationMappings = N'';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_blockedprocesses_trace','P') IS NOT NULL
	DROP PROC dbo.[translate_blockedprocesses_trace];
GO

CREATE PROC dbo.[translate_blockedprocesses_trace]
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
		RAISERROR('Please specify a @TargetTable value - for storage of output from dbo.translate_blockedprocesses_trace', 16, 1); 
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
		object_name = N''blocked_process_report''
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

	--PRINT @sql;

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
	SELECT 
		IDENTITY(int, 1, 1) row_id,
		meta.[timestamp], 
		meta.[database_name], 
		CAST((meta.duration/1000000.0) as decimal(24,2)) [seconds_blocked], 
		[report].report_id,
		
		[report].blocking_spid, 
		[report].blocking_ecid, 
		CAST([report].blocking_spid as nvarchar(max)) + CASE WHEN [report].blocking_ecid = 0 THEN N' ' ELSE N' ' + QUOTENAME([report].blocking_ecid, N'()') END [blocking_id], 
		CAST([report].blocked_spid as nvarchar(max)) + CASE WHEN [report].blocked_ecid = 0 THEN N' ' ELSE N' ' + QUOTENAME([report].blocked_ecid, N'()') END [blocked_id],
		[report].blocking_xactid,
		[report].[blocking_request],
		CAST('' AS nvarchar(MAX)) [normalized_blocking_request],
		CAST('' AS nvarchar(MAX)) [blocking_sproc_statement],
		CAST('' AS sysname) [blocking_weight],
		[report].[blocking_resource] [blocking_resource_id], 
		CAST('' AS varchar(2000)) [blocking_resource],
		[report].blocking_wait_time,  
		[report].blocking_tran_count,
		[report].blocking_isolation_level,
		[report].blocking_status,
		ISNULL([report].[blocking_start_offset], 0) [blocking_start_offset],
		ISNULL([report].[blocking_end_offset], 0) [blocking_end_offset],
		[report].blocking_host_name,
		[report].blocking_login_name,
		[report].[blocking_client_app],

		[report].blocked_spid, 
		[report].blocked_ecid, 
		[report].blocked_xactid, 
		[report].[blocked_request], 
		CAST('' AS nvarchar(MAX)) [normalized_blocked_request],
		CAST('' AS nvarchar(MAX)) [blocked_sproc_statement],
		CAST('' AS sysname) [blocked_weight],
		[report].blocked_resource [blocked_resource_id],
		CAST('' AS varchar(2000)) [blocked_resource],
		[report].blocked_wait_time, 
		[report].blocked_tran_count, 
		[report].[blocked_log_used],
		[report].blocked_lock_mode,
		[report].blocked_isolation_level, 
		[report].blocked_status, 
		ISNULL([blocked_start_offset], 0) [blocked_start_offset],
		ISNULL([blocked_end_offset], 0) [blocked_end_offset],
		[report].blocked_host_name, 
		[report].blocked_login_name, 
		[report].[blocked_client_app],
		[meta].[report]
	INTO 
		#shredded
	FROM  
		[#raw] trace 
		CROSS APPLY ( 
			SELECT 
				trace.[event_data].value('(event/@timestamp)[1]','datetime') [timestamp], 
				trace.[event_data].value('(event/data[@name="database_name"]/value)[1]','nvarchar(128)') [database_name],
				trace.[event_data].value('(event/data[@name="duration"]/value)[1]','bigint') [duration], 
				trace.[event_data].query('event/data/value/blocked-process-report') [report]
		) meta
		CROSS APPLY (
			SELECT
				[report].value('(/blocked-process-report/@monitorLoop)[1]','int') [report_id],
				[report].value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int') [blocking_spid],
				[report].value('(/blocked-process-report/blocking-process/process/@ecid)[1]', 'int') [blocking_ecid],	-- execution context id... 				
				[report].value('(/blocked-process-report/blocking-process/process/@xactid)[1]', 'bigint') [blocking_xactid],
				[report].value('(/blocked-process-report/blocking-process/process/inputbuf)[1]','nvarchar(max)') [blocking_request],
				[report].value('(/blocked-process-report/blocking-process/process/@waitresource)[1]','nvarchar(80)') [blocking_resource],
				[report].value('(/blocked-process-report/blocking-process/process/@waittime)[1]','int') [blocking_wait_time],
				[report].value('(/blocked-process-report/blocking-process/process/@trancount)[1]','int') [blocking_tran_count],
				[report].value('(/blocked-process-report/blocking-process/process/@clientapp)[1]','nvarchar(128)') [blocking_client_app],
				[report].value('(/blocked-process-report/blocking-process/process/@hostname)[1]','nvarchar(128)') [blocking_host_name],
				[report].value('(/blocked-process-report/blocking-process/process/@loginname)[1]','nvarchar(128)') [blocking_login_name],
				[report].value('(/blocked-process-report/blocking-process/process/@isolationlevel)[1]','nvarchar(128)') [blocking_isolation_level],
				[report].value('(/blocked-process-report/blocking-process/process/executionStack/frame/@stmtstart)[1]','int') [blocking_start_offset],
				[report].value('(/blocked-process-report/blocking-process/process/executionStack/frame/@stmtend)[1]','int') [blocking_end_offset],
				[report].value('(/blocked-process-report/blocking-process/process/@status)[1]','nvarchar(128)') [blocking_status],

				[report].value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'int') [blocked_spid],
				[report].value('(/blocked-process-report/blocked-process/process/@ecid)[1]', 'int') [blocked_ecid],
				[report].value('(/blocked-process-report/blocked-process/process/@xactid)[1]', 'bigint') [blocked_xactid],
				[report].value('(/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)') [blocked_request],
				[report].value('(/blocked-process-report/blocked-process/process/@waitresource)[1]','nvarchar(80)') [blocked_resource],
				[report].value('(/blocked-process-report/blocked-process/process/@waittime)[1]','int') [blocked_wait_time],
				[report].value('(/blocked-process-report/blocked-process/process/@trancount)[1]','int') [blocked_tran_count],
				[report].value('(/blocked-process-report/blocked-process/process/@logused)[1]','int') [blocked_log_used],
				[report].value('(/blocked-process-report/blocked-process/process/@clientapp)[1]','nvarchar(128)') [blocked_client_app],
				[report].value('(/blocked-process-report/blocked-process/process/@hostname)[1]','nvarchar(128)') [blocked_host_name],
				[report].value('(/blocked-process-report/blocked-process/process/@loginname)[1]','nvarchar(128)') [blocked_login_name],
				[report].value('(/blocked-process-report/blocked-process/process/@isolationlevel)[1]','nvarchar(128)') [blocked_isolation_level],
				[report].value('(/blocked-process-report/blocked-process/process/@lockMode)[1]','nvarchar(128)') [blocked_lock_mode],
				[report].value('(/blocked-process-report/blocked-process/process/@status)[1]','nvarchar(128)') [blocked_status], 

				-- NOTE: this EXPLICITLY pulls only the FIRST frame's details (there can be MULTIPLE per 'batch').
				ISNULL([report].value('(/blocked-process-report/blocked-process/process/executionStack/frame/@stmtstart)[1]','int'), 0) [blocked_start_offset],
				ISNULL([report].value('(/blocked-process-report/blocked-process/process/executionStack/frame/@stmtend)[1]','int'), 0) [blocked_end_offset]
		) report
	ORDER BY 
		[meta].[timestamp], [report].[report_id];


	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Statement Normalization: 
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		blocking_request, 
		COUNT(*) [instance_count],  
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#normalized_blocking
	FROM 
		[#shredded] 
	GROUP BY 
		[blocking_request];

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		blocked_request, 
		COUNT(*) [instance_count], 
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#normalized_blocked
	FROM 
		[#shredded] 
	GROUP BY 
		[blocked_request];

	DECLARE @rowID int;
	DECLARE @statement nvarchar(MAX); 
	DECLARE @normalized nvarchar(MAX);
	DECLARE @params nvarchar(MAX);
	DECLARE @error nvarchar(MAX);

	DECLARE normalizing CURSOR LOCAL FAST_FORWARD FOR
	SELECT row_id, blocking_request [request] FROM [#normalized_blocking];

	OPEN normalizing;
	FETCH NEXT FROM	normalizing INTO @rowID, @statement;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @normalized = NULL; 

		EXEC dbo.[normalize_text]
			@statement, 
			@normalized OUTPUT, 
			@params OUTPUT, 
			@error OUTPUT;

		UPDATE [#normalized_blocking]
		SET 
			[definition] = @normalized
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM	normalizing INTO @rowID, @statement;
	END;

	CLOSE normalizing;
	DEALLOCATE normalizing;

	DECLARE normalized CURSOR LOCAL FAST_FORWARD FOR
	SELECT row_id, blocked_request [request] FROM [#normalized_blocked];

	OPEN normalized;
	FETCH NEXT FROM	normalized INTO @rowID, @statement;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @normalized = NULL; 

		EXEC dbo.[normalize_text]
			@statement, 
			@normalized OUTPUT, 
			@params OUTPUT, 
			@error OUTPUT;

		UPDATE [#normalized_blocked]
		SET 
			[definition] = @normalized
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM	normalized INTO @rowID, @statement;
	END;

	CLOSE normalized;
	DEALLOCATE normalized;	

	UPDATE s 
	SET
		s.[normalized_blocking_request] = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#normalized_blocking] x ON s.[blocking_request] = x.[blocking_request]
	WHERE 
		s.[blocking_request] IS NOT NULL;

	UPDATE s 
	SET
		s.[normalized_blocked_request] = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#normalized_blocked] x ON s.[blocked_request] = x.[blocked_request]
	WHERE 
		s.[blocked_request] IS NOT NULL;

	UPDATE [#shredded]
	SET 
		blocking_request = COALESCE([normalized_blocking_request], blocking_request, N''), 
		blocked_request = COALESCE([normalized_blocked_request], [blocked_request], N'');


	-- Statement Extraction (from Sprocs): 
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[database_name],
		blocking_request [request], 
		blocking_start_offset, 
		blocking_end_offset, 
		CAST('' AS nvarchar(MAX)) [definition] 
	INTO 
		#statement_blocking
	FROM 
		[#shredded] 
	WHERE 
		[blocking_request] LIKE N'%Object Id = [0-9]%'
	GROUP BY 
		[database_name], [blocking_request], [blocking_start_offset], [blocking_end_offset];

	--------------------------------------------------------------------------------------------------------------------------------------------
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[database_name],
		blocked_request [request], 
		blocked_start_offset, 
		blocked_end_offset, 
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#statement_blocked
	FROM 
		[#shredded] 
	WHERE 
		[blocked_request] LIKE N'%Object Id = [0-9]%'
	GROUP BY 
		[database_name], [blocked_request], [blocked_start_offset], [blocked_end_offset];

	--------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @sproc sysname;
	DECLARE @sourceDatabase sysname;
	DECLARE @objectId int;
	DECLARE @start int;
	DECLARE @end int;

	DECLARE extracting CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, [database_name], request, blocking_start_offset, blocking_end_offset FROM [#statement_blocking];

	OPEN [extracting];
	FETCH NEXT FROM [extracting] INTO @rowID, @sourceDatabase, @sproc, @start, @end;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @objectId = CAST(REPLACE(RIGHT(@sproc, CHARINDEX(' = ', REVERSE(@sproc))), ']', '') AS int);
		SET @statement = NULL; 

		EXEC dbo.[extract_statement]
			@TargetDatabase = @sourceDatabase,
			@ObjectID = @objectId, 
			@OffsetStart = @start, 
			@OffsetEnd = @end, -- int
			@Statement = @statement OUTPUT;

		UPDATE [#statement_blocking]
		SET 
			[definition] = @statement 
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [extracting] INTO @rowID, @sourceDatabase, @sproc, @start, @end;
	END;

	CLOSE [extracting];
	DEALLOCATE [extracting];

	--------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE extracted CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, [database_name], request, blocked_start_offset, blocked_end_offset FROM [#statement_blocked];

	OPEN [extracted];
	FETCH NEXT FROM [extracted] INTO @rowID, @sourceDatabase, @sproc, @start, @end;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @objectId = CAST(REPLACE(RIGHT(@sproc, CHARINDEX(' = ', REVERSE(@sproc))), ']', '') AS int);
		SET @statement = NULL; 

		EXEC dbo.[extract_statement]
			@TargetDatabase = @sourceDatabase, -- sysname
			@ObjectID = @objectId, -- int
			@OffsetStart = @start, -- int
			@OffsetEnd = @end, -- int
			@Statement = @statement OUTPUT;

		UPDATE [#statement_blocked]
		SET 
			[definition] = @statement 
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [extracted] INTO @rowID, @sourceDatabase, @sproc, @start, @end;
	END;

	CLOSE [extracted];
	DEALLOCATE [extracted];


	UPDATE s 
	SET 
		s.[blocking_sproc_statement] = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#statement_blocking] x ON ISNULL(s.[normalized_blocking_request], s.[blocking_request]) = x.[request]
			AND s.[blocking_start_offset] = x.[blocking_start_offset] AND s.[blocking_end_offset] = x.[blocking_end_offset];

	UPDATE s 
	SET 
		s.[blocked_sproc_statement] = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#statement_blocked] x ON ISNULL(s.[normalized_blocked_request], s.[blocked_request]) = x.[request]
			AND s.[blocked_start_offset] = x.[blocked_start_offset] AND s.[blocked_end_offset] = x.[blocked_end_offset];


	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Statement Weighting:
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	WITH signaturing AS ( 
		SELECT 
			CASE WHEN [blocking_request] LIKE N'%Object Id = [0-9]%' THEN [blocking_request] + N'.' + CAST([blocking_start_offset] AS sysname) + N'.' + CAST([blocking_end_offset] AS sysname) ELSE [blocking_request] END [statement]
		FROM
			#shredded
	) 
	SELECT 
		[statement], 
		COUNT(*) [instance_count]
	INTO 
		#weighting
	FROM 
		[signaturing] 
	GROUP BY 
		[statement]

	DECLARE @sum int;
	SELECT @sum = SUM(instance_count) FROM [#weighting];	-- should be the count of rows... in #shredded... 

	UPDATE s
	SET 
		s.[blocking_weight] = CAST(x.[instance_count] AS sysname) + N' / ' + CAST(@sum AS sysname)
	FROM 
		[#shredded] s
		INNER JOIN [#weighting] x ON (CASE
			WHEN s.[blocking_request] LIKE N'%Object Id = [0-9]%' THEN s.[blocking_request] + N'.' + CAST(s.[blocking_start_offset] AS sysname) + N'.' + CAST(s.[blocking_end_offset] AS sysname) 
			ELSE s.[blocking_request] 
		END) = x.[statement];
		
	--------------------------------------------------------------------------------------------------------------------------------------------
	WITH signatured AS ( 
		SELECT 
			CASE WHEN [blocked_request] LIKE N'%Object Id = [0-9]%' THEN [blocked_request] + N'.' + CAST([blocked_start_offset] AS sysname) + N'.' + CAST([blocked_end_offset] AS sysname) ELSE [blocked_request] END [statement]
		FROM
			#shredded
	) 
	SELECT 
		[statement], 
		COUNT(*) [instance_count]
	INTO 
		#weighted
	FROM 
		[signatured] 
	GROUP BY 
		[statement]

	SELECT @sum = SUM(instance_count) FROM [#weighted];	-- should be the count of rows... in #shredded... 

	UPDATE s
	SET 
		s.[blocked_weight] = CAST(x.[instance_count] AS sysname) + N' / ' + CAST(@sum AS sysname)
	FROM 
		[#shredded] s
		INNER JOIN [#weighted] x ON (CASE
			WHEN s.[blocked_request] LIKE N'%Object Id = [0-9]%' THEN s.[blocked_request] + N'.' + CAST(s.[blocked_start_offset] AS sysname) + N'.' + CAST(s.[blocked_end_offset] AS sysname) 
			ELSE s.[blocked_request] 
		END) = x.[statement];

	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Wait Resource Extraction:
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		blocking_resource_id, 
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#resourcing
	FROM 
		[#shredded] 
	GROUP BY 
		blocking_resource_id; 
		
	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		blocked_resource_id, 
		CAST('' AS nvarchar(MAX)) [definition]
	INTO 
		#resourced
	FROM 
		[#shredded] 
	GROUP BY 
		blocked_resource_id; 
		
	DECLARE @resourceID nvarchar(80);
	DECLARE @resource nvarchar(2000);
	
	DECLARE resourcing CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, blocking_resource_id FROM [#resourcing];

	OPEN [resourcing];
	FETCH NEXT FROM [resourcing] INTO @rowID, @resourceID;

	WHILE @@FETCH_STATUS = 0 BEGIN

		EXEC dbo.[extract_waitresource]
			@WaitResource = @resourceID,
			@DatabaseMappings = @OptionalDbTranslationMappings,
			@Output = @resource OUTPUT;

		UPDATE [#resourcing] 
		SET 
			[definition] = @resource
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [resourcing] INTO @rowID, @resourceID;
	END;

	CLOSE [resourcing];
	DEALLOCATE [resourcing];

	--------------------------------------------------------------------------------------------------------------------------------------------
	
	DECLARE resourced CURSOR LOCAL FAST_FORWARD FOR 
	SELECT row_id, blocked_resource_id FROM [#resourced];

	OPEN [resourced];
	FETCH NEXT FROM [resourced] INTO @rowID, @resourceID;

	WHILE @@FETCH_STATUS = 0 BEGIN

		EXEC dbo.[extract_waitresource]
			@WaitResource = @resourceID,
			@DatabaseMappings = @OptionalDbTranslationMappings,
			@Output = @resource OUTPUT;

		UPDATE [#resourced] 
		SET 
			[definition] = @resource
		WHERE 
			[row_id] = @rowID;

		FETCH NEXT FROM [resourced] INTO @rowID, @resourceID;
	END;

	CLOSE [resourced];
	DEALLOCATE [resourced];

	UPDATE s 
	SET 
		s.blocking_resource = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#resourcing] x ON s.[blocking_resource_id] = x.[blocking_resource_id];

	UPDATE s 
	SET 
		s.blocked_resource = x.[definition]
	FROM 
		[#shredded] s 
		INNER JOIN [#resourced] x ON s.[blocked_resource_id] = x.[blocked_resource_id];


	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projection/Storage:
	-----------------------------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @command nvarchar(MAX) = N'USE [{targetDatabase}];
	
	SELECT 
		[row_id], 
		[timestamp],
		[database_name],
		[seconds_blocked],
		[report_id],
		[blocking_spid],
		[blocking_ecid],
		[blocking_id],
		[blocked_id],
		[blocking_xactid],
		[blocking_request],
		--[normalized_blocking_request],
		[blocking_sproc_statement],
		[blocking_weight],
		[blocking_resource_id],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_tran_count],
		[blocking_isolation_level],
		[blocking_status],
		[blocking_start_offset],
		[blocking_end_offset],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_spid],
		[blocked_ecid],
		[blocked_xactid],
		[blocked_request],
		--[normalized_blocked_request],
		[blocked_sproc_statement],
		[blocked_weight],
		[blocked_resource_id],
		[blocked_resource],
		[blocked_wait_time],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_lock_mode],
		[blocked_isolation_level],
		[blocked_status],
		[blocked_start_offset],
		[blocked_end_offset],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report]
	INTO 
		{targetTableName}
	FROM 
		#shredded
	ORDER BY 
		row_id; ';

	SET @command = REPLACE(@command, N'{targetDatabase}', @targetDatabase);
	SET @command = REPLACE(@command, N'{targetTableName}', @TargetTable);

	EXEC sp_executesql @command;

	SET @command = N'	SELECT COUNT(*) [rows], MIN(timestamp) [start], MAX(timestamp) [end] FROM {targetTableName}; ';
	SET @command = REPLACE(@command, N'{targetTableName}', @TargetTable);

	EXEC sp_executesql @command; 

	RETURN 0; 
GO