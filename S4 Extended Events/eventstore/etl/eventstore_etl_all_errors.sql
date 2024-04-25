/*


	
	TODO: 
		1. Look at tweaking the XE Session so that it ignores WHERE (Severity < 11 AND and is_event_logged = 0). 
			as that'll remove a lot of noise/cruft. 
		2. then look at the following and see what else I can remove: 
						SELECT 
							* 
						FROM 
							sys.messages 
						WHERE 
							[language_id] = 1033 
							AND [severity] < 11 
							AND [is_event_logged] = 0
							AND ([message_id] < 12707 OR [message_id] > 13176)
							AND([message_id] < 13202 OR [message_id] > 13399)
							AND([message_id] < 14201 OR [message_id] > 14220)
							AND([message_id] < 14549 OR [message_id] > 14599)
							AND([message_id] < 20528 OR [message_id] > 20551)
							--AND([message_id] < OR [message_id] > )
							--AND([message_id] < OR [message_id] > )
	
							AND ([message_id] < 35401 OR [message_id] > 35532)
						ORDER BY 
							[message_id]

		3. Then... I'm going to also need an evenstore_all_errors_exclusions table ... 
			it's just going to HAVE to be something that HAS to be deployed and ... will exclude gobs of other crap that CAN go into the XE trace (cuz too expensive to filter out) but won't be 
				ETL'd into the all_errors eventstore table for reporting/analysis/etc. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_all_errors]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_all_errors];
GO

CREATE PROC dbo.[eventstore_etl_all_errors]
	@SessionName				sysname			= N'eventstore_all_errors', 
	@EventStoreTarget			sysname			= N'admindb.dbo.eventstore_all_errors',
	@InitializeDaysBack			int				= 5
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @SessionName = ISNULL(NULLIF(@SessionName, N''), N'eventstore_all_errors');
	SET @EventStoreTarget = ISNULL(NULLIF(@EventStoreTarget, N''), N'admindb.dbo.eventstore_all_errors');
	SET @InitializeDaysBack = ISNULL(@InitializeDaysBack, 5);	

	DECLARE @etlSQL nvarchar(MAX) = N'
	USE [{targetDatabase}];

	INSERT INTO [{targetSchema}].[{targetTable}] (
		[timestamp],
		[operation],
		[error_number],
		[severity],
		[state],
		[message],
		[database],
		[user_name],
		[host_name],
		[application_name],
		[is_system],
		[statement],
		[report]
	)
	SELECT 
		[nodes].[row].value(N''(@timestamp)[1]'', N''datetime'') [timestamp],
		[nodes].[row].value(N''(@name)[1]'', N''varchar(30)'') [operation],
		[nodes].[row].value(N''(data[@name="error_number"]/value)[1]'', N''int'') [error_number],
		[nodes].[row].value(N''(data[@name="severity"]/value)[1]'', N''int'') [severity],
		[nodes].[row].value(N''(data[@name="state"]/value)[1]'', N''int'') [state],
		[nodes].[row].value(N''(data[@name="message"]/value)[1]'', N''varchar(max)'') [message],
		[nodes].[row].value(N''(action[@name="database_name"]/value)[1]'', N''sysname'') [database],
		[nodes].[row].value(N''(action[@name="user_name"]/value)[1]'', N''sysname'')	[user_name],
		[nodes].[row].value(N''(action[@name="client_hostname"]/value)[1]'', N''varchar(max)'') [host_name],
		[nodes].[row].value(N''(action[@name="client_app_name"]/value)[1]'', N''varchar(max)'') [application_name],
		[nodes].[row].value(N''(action[@name="is_system"]/value)[1]'', N''sysname'') [is_system],
		[nodes].[row].value(N''(action[@name="sql_text"]/value)[1]'', N''varchar(max)'') [statement], 
		[nodes].[row].query(N''.'') [report]
	FROM 
		@EventData.nodes(N''//event'') [nodes]([row]);  ';

	DECLARE @return int;
	EXEC @return = dbo.[eventstore_etl_session] 
		@SessionName = @SessionName, 
		@EventStoreTarget = @EventStoreTarget, 
		@TranslationDML = @etlSQL, 
		@InitializeDaysBack = @InitializeDaysBack;
	
	RETURN @return;
GO