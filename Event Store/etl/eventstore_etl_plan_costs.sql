/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_captured_plan_costs]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_captured_plan_costs];
GO

CREATE PROC dbo.[eventstore_etl_captured_plan_costs]
	@SessionName				sysname			= N'capture_plan_costs', 
	@EventStoreTarget			sysname			= N'admindb.dbo.eventstore_plan_costs',
	@InitializeDaysBack			int				= 10
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @SessionName = ISNULL(NULLIF(@SessionName, N''), N'capture_plan_costs');
	SET @EventStoreTarget = ISNULL(NULLIF(@EventStoreTarget, N''), N'admindb.dbo.eventstore_plan_costs');
	SET @InitializeDaysBack = ISNULL(@InitializeDaysBack, 10);

	DECLARE @etlSQL nvarchar(MAX) = N'
	USE [{targetDatabase}];

	WITH XMLNAMESPACES (
		N''http://schemas.microsoft.com/sqlserver/2004/07/showplan'' AS SP
	)
	INSERT INTO [{targetSchema}].[{targetTable}] (
		[timestamp],
		[database_name],
		[user_name],
		[host_name],
		[app_name],
		[cpu_time],
		[duration],
		[estimated_rows],
		[estimated_cost],
		[granted_memory_kb],
		[dop],
		[object_name],
		[query_hash],
		[statement],
		[plan]
	)
	SELECT 
		--[nodes].[row].query(N''(.)[1]'') [xml],
		[nodes].[row].value(N''(@timestamp)[1]'', N''datetime2'')												AS [timestamp],
		[nodes].[row].value(N''(data[@name=''''database_name'''']/value)[1]'', N''sysname'')					AS [database_name],
		[nodes].[row].value(N''(action[@name=''''username'''']/value)[1]'', N''sysname'')						AS [user_name],
		[nodes].[row].value(N''(action[@name=''''client_hostname'''']/value)[1]'', N''sysname'')				AS [host_name],
		[nodes].[row].value(N''(action[@name=''''client_app_name'''']/value)[1]'', N''sysname'')				AS [app_name],
		[nodes].[row].value(N''(data[@name=''''cpu_time'''']/value)[1]'',	N''int'')							AS [cpu_time],
		[nodes].[row].value(N''(data[@name=''''duration'''']/value)[1]'',	N''int'')							AS [duration],
		[nodes].[row].value(N''(data[@name=''''estimated_rows'''']/value)[1]'', N''int'')						AS [estimated_rows],
		[nodes].[row].value(N''(data[@name=''''estimated_cost'''']/value)[1]'', N''int'')						AS [estimated_cost],  
		[nodes].[row].value(N''(data[@name=''''granted_memory_kb'''']/value)[1]'', N''int'')					AS [granted_memory_kb],
		[nodes].[row].value(N''(data[@name=''''dop'''']/value)[1]'', N''int'')									AS [dop],
		[nodes].[row].value(N''(data[@name=''''object_name'''']/value)[1]'', N''sysname'')						AS [object_name],
		[nodes].[row].value(N''(action[@name=''''query_hash_signed'''']/value)[1]'', N''bigint'')				AS [query_hash],
		[nodes].[row].value(N''(action[@name=''''sql_text'''']/value)[1]'', N''varchar(max)'')					AS [statement], 
		[nodes].[row].query(N''data[@name=''''showplan_xml'''']/value/SP:ShowPlanXML'')							AS [plan]
	FROM 
		@EventData.nodes(N''//event'') [nodes]([row]); ';

	DECLARE @return int;
	EXEC @return = dbo.[eventstore_etl_session] 
		@SessionName = @SessionName, 
		@EventStoreTarget = @EventStoreTarget, 
		@TranslationDML = @etlSQL, 
		@InitializeDaysBack = @InitializeDaysBack;
	
	RETURN @return; 
GO







--	/* Verify that the XE Session (SessionName) exists: */
--	DECLARE @SerializedOutput xml;
--	EXEC dbo.[list_xe_sessions] 
--		@TargetSessionName = @SessionName, 
--		@IncludeDiagnostics = 1,
--		@SerializedOutput = @SerializedOutput OUTPUT;

--	IF dbo.[is_xml_empty](@SerializedOutput) = 1 BEGIN 
--		RAISERROR(N'Target @SessionName: [%s] not found. Please verify @SessionName input.', 16, 1, @SessionName); 
--		RETURN -10;
--	END;

--	/* Verify that the target table (XEStoreTarget) exists: */ 
--	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
--	SELECT 
--		@targetDatabase = PARSENAME(@XEStoreTarget, 3), 
--		@targetSchema = ISNULL(PARSENAME(@XEStoreTarget, 2), N'dbo'), 
--		@targetObjectName = PARSENAME(@XEStoreTarget, 1);
	
--	IF @targetDatabase IS NULL BEGIN 
--		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		
--		IF @targetDatabase IS NULL BEGIN 
--			RAISERROR('Invalid Database-Name specified for %s and/or S4 was unable to determine calling-db-context. Please use [db_name].[schema_name].[object_name] qualified names.', 16, 1, N'@XEStoreTarget');
--			RETURN -5;
--		END;
--	END;

--	DECLARE @targetTable sysname;
--	SELECT @targetTable = N'[' + @targetDatabase + N'].[' + @targetSchema + N'].[' + @targetObjectName + N']';

--	DECLARE @targetObjectID int;
--	DECLARE @check nvarchar(MAX) = N'SELECT @targetObjectID = OBJECT_ID(''' + @targetTable + N''');'

--	EXEC [sys].[sp_executesql] 
--		@check, 
--		N'@targetObjectID int OUTPUT', 
--		@targetObjectID = @targetObjectID OUTPUT; 

--	IF @targetObjectID IS NULL BEGIN 
--		RAISERROR('The target table-name specified by @XEStoreTarget: [%s] could not be located. Please create it using admindb.dbo.xestore_init_%s or create a new table following admindb documentation.', 16, 1, @XEStoreTarget, @SessionName);
--		RETURN -5;
--	END;

--	/* Otherwise, init extraction, grab rows, and ... if all passes, finalize extraction (i.e., LSET/CET management). */
--	DECLARE @Output xml, @extractionID int,	@extractionAttributes nvarchar(300);
--	EXEC dbo.[xestore_extract_session_xml]
--		@SessionName = @SessionName,
--		@Output = @Output OUTPUT,
--		@ExtractionID = @extractionID OUTPUT,
--		@ExtractionAttributes = @extractionAttributes OUTPUT, 
--		@InitializationDaysBack = @InitializeDaysBack;

--	DECLARE @errorID int, @errorMessage nvarchar(MAX), @errorLine int;
--	BEGIN TRY 
--		BEGIN TRAN;

--		DECLARE @sql nvarchar(MAX) = N'
--		USE [{targetDatabase}];

--		WITH XMLNAMESPACES (
--			N''http://schemas.microsoft.com/sqlserver/2004/07/showplan'' AS SP
--		)
--		INSERT INTO [{targetSchema}].[{targetTable}] (
--			[timestamp],
--			[database_name],
--			[user_name],
--			[host_name],
--			[app_name],
--			[cpu_time],
--			[duration],
--			[estimated_rows],
--			[estimated_cost],
--			[granted_memory_kb],
--			[dop],
--			[object_name],
--			[query_hash],
--			[statement],
--			[plan]
--		)
--		SELECT 
--			--[nodes].[row].query(N''(.)[1]'') [xml],
--			[nodes].[row].value(N''(@timestamp)[1]'', N''datetime2'')												AS [timestamp],
--			[nodes].[row].value(N''(data[@name=''''database_name'''']/value)[1]'', N''sysname'')					AS [database_name],
--			[nodes].[row].value(N''(action[@name=''''username'''']/value)[1]'', N''sysname'')						AS [user_name],
--			[nodes].[row].value(N''(action[@name=''''client_hostname'''']/value)[1]'', N''sysname'')				AS [host_name],
--			[nodes].[row].value(N''(action[@name=''''client_app_name'''']/value)[1]'', N''sysname'')				AS [app_name],
--			[nodes].[row].value(N''(data[@name=''''cpu_time'''']/value)[1]'',	N''int'')							AS [cpu_time],
--			[nodes].[row].value(N''(data[@name=''''duration'''']/value)[1]'',	N''int'')							AS [duration],
--			[nodes].[row].value(N''(data[@name=''''estimated_rows'''']/value)[1]'', N''int'')						AS [estimated_rows],
--			[nodes].[row].value(N''(data[@name=''''estimated_cost'''']/value)[1]'', N''int'')						AS [estimated_cost],  
--			[nodes].[row].value(N''(data[@name=''''granted_memory_kb'''']/value)[1]'', N''int'')					AS [granted_memory_kb],
--			[nodes].[row].value(N''(data[@name=''''dop'''']/value)[1]'', N''int'')									AS [dop],
--			[nodes].[row].value(N''(data[@name=''''object_name'''']/value)[1]'', N''sysname'')						AS [object_name],
--			[nodes].[row].value(N''(action[@name=''''query_hash_signed'''']/value)[1]'', N''bigint'')				AS [query_hash],
--			[nodes].[row].value(N''(action[@name=''''sql_text'''']/value)[1]'', N''varchar(max)'')					AS [statement], 
--			[nodes].[row].query(N''data[@name=''''showplan_xml'''']/value/SP:ShowPlanXML'')							AS [plan]
--		FROM 
--			@EventData.nodes(N''//event'') [nodes]([row]); ';

--		SET @sql = REPLACE(@sql, N'{targetDatabase}', @targetDatabase);
--		SET @sql = REPLACE(@sql, N'{targetSchema}', @targetSchema);
--		SET @sql = REPLACE(@sql, N'{targetTable}', @targetObjectName);
		
--		--PRINT @sql;

--		EXEC sys.sp_executesql 
--			@sql, 
--			N'@Output xml', 
--			@Output = @Output;

--		EXEC dbo.[xestore_finalize_extraction] 
--			@SessionName = @SessionName, 
--			@ExtractionId = @extractionID, 
--			@Attributes = @extractionAttributes;
		
--		COMMIT;
--	END TRY
--	BEGIN CATCH 
--		SELECT @errorID = ERROR_NUMBER(), @errorLine = ERROR_LINE(), @errorMessage = ERROR_MESSAGE();
--		RAISERROR(N'Exception processing ETL. Error Number %i, Line %i: %s', 16, 1, @errorID, @errorLine, @errorMessage);

--		IF @@TRANCOUNT > 0 
--			ROLLBACK;

--		RETURN -100;
--	END CATCH;

--	RETURN 0;
--GO