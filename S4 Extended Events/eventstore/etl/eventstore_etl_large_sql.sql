/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_large_sql]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_large_sql];
GO

CREATE PROC dbo.[eventstore_etl_large_sql]
	@SessionName				sysname			= N'capture_large_sql', 
	@EventStoreTarget			sysname			= N'admindb.dbo.eventstore_large_sql',
	@InitializeDaysBack			int				= 10
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @SessionName = ISNULL(NULLIF(@SessionName, N''), N'capture_large_sql');
	SET @EventStoreTarget = ISNULL(NULLIF(@EventStoreTarget, N''), N'admindb.dbo.eventstore_large_sql');
	SET @InitializeDaysBack = ISNULL(@InitializeDaysBack, 10);

	DECLARE @etlSQL nvarchar(MAX) = N'
	USE [{targetDatabase}];

	INSERT INTO [{targetSchema}].[{targetTable}] (
		[timestamp],
		[database],
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
	SELECT 
		[nodes].[row].value(N''(@timestamp)[1]'', N''datetime'') [timestamp],
		[nodes].[row].value(N''(action[@name="database_name"]/value)[1]'', N''sysname'') [database],
		[nodes].[row].value(N''(action[@name="username"]/value)[1]'', N''sysname'') [user_name],
		[nodes].[row].value(N''(action[@name="client_hostname"]/value)[1]'', N''sysname'') [host_name],
		[nodes].[row].value(N''(action[@name="client_app_name"]/value)[1]'', N''sysname'') [application_name],
		[nodes].[row].value(N''(data[@name="object_name"]/value)[1]'', N''sysname'') [module],
		[nodes].[row].value(N''(data[@name="statement"]/value)[1]'', N''nvarchar(MAX)'') [statement],
		[nodes].[row].value(N''(data[@name="offset"]/value)[1]'', N''sysname'') + N'' - '' + [nodes].[row].value(N''(data[@name="offset_end"]/value)[1]'', N''sysname'')  [offset],
		[nodes].[row].value(N''(data[@name="cpu_time"]/value)[1]'', N''bigint'') / 1000 [cpu_ms],
		[nodes].[row].value(N''(data[@name="duration"]/value)[1]'', N''bigint'') / 1000 [duration_ms],
		[nodes].[row].value(N''(data[@name="physical_reads"]/value)[1]'', N''bigint'') [physical_reads],
		[nodes].[row].value(N''(data[@name="writes"]/value)[1]'', N''bigint'') [writes],
		[nodes].[row].value(N''(data[@name="row_count"]/value)[1]'', N''bigint'') [row_count], 
		[nodes].[row].query(N''.'') [report]
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