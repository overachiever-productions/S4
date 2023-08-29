/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.


	EXAMPLE (list all XE sessions):

		EXEC dbo.list_xe_sessions;


	EXAMPLE (via RETURN vs project):

			DECLARE @SerializedOutput xml;
			EXEC dbo.[list_xe_sessions] 
				@TargetSessionName = N'capture_all_errors', 
				@IncludeDiagnostics = 1,
				@SerializedOutput = @SerializedOutput OUTPUT;

			SELECT @SerializedOutput;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_xe_sessions','P') IS NOT NULL
	DROP PROC dbo.[list_xe_sessions];
GO

CREATE PROC dbo.[list_xe_sessions]
	@TargetSessionName				sysname			= NULL,
	@IncludeDiagnostics				bit				= 0,
	@SerializedOutput				xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetSessionName = NULLIF(@TargetSessionName, N'');
	SET @IncludeDiagnostics = NULLIF(@IncludeDiagnostics, 0);

	DECLARE @xeSource sysname = N'server';
	IF LOWER(@@VERSION) LIKE '%azure%' SET @xeSource = N'database';

	DECLARE @sql nvarchar(MAX) = N'SELECT 
		[s].[event_session_id],
		[s].[name],
		[s].[event_retention_mode_desc],
		[s].[max_dispatch_latency],
		[s].[max_memory],
		[s].[max_event_size],
		[s].[memory_partition_mode],
		[s].[memory_partition_mode_desc],
		[s].[track_causality],
		[s].[startup_state], 
		-- azure only: [has_long_running_target] 
		[t].[name] [storage_type]
	FROM 
		sys.[{0}_event_sessions] [s]
		INNER JOIN [sys].[{0}_event_session_targets] [t] ON [s].[event_session_id] = [t].[event_session_id]; ';

	SET @sql = REPLACE(@sql, N'{0}', @xeSource);

	CREATE TABLE #definitions ( 
		[event_session_id] int NOT NULL,
		[name] sysname NULL,
		[event_retention_mode_desc] nvarchar(60) NULL,
		[max_dispatch_latency] int NULL,
		[max_memory] int NULL,
		[max_event_size] int NULL,
		[memory_partition_mode] char(1) NULL,
		[memory_partition_mode_desc] nvarchar(60) NULL,
		[track_causality] bit NULL,
		[startup_state] bit NULL,
		[storage_type] sysname NOT NULL
	); 

	INSERT INTO [#definitions] (
		[event_session_id],
		[name],
		[event_retention_mode_desc],
		[max_dispatch_latency],
		[max_memory],
		[max_event_size],
		[memory_partition_mode],
		[memory_partition_mode_desc],
		[track_causality],
		[startup_state], 
		[storage_type]
	)
	EXEC sp_executesql
		@sql;

	SET @sql = N'SELECT 
	[s].[name],
	[s].[buffer_policy_desc],
	[s].[dropped_event_count],
	[s].[dropped_buffer_count],
	[s].[blocked_event_fire_time],
	[s].[create_time] /* Pretty much pointless as per: https://dba.stackexchange.com/q/255387/6100 */,{version_specific}
	[t].[target_data],
	[t].[bytes_written]	
FROM 
	sys.[dm_xe_{0}sessions] [s]
	INNER JOIN [sys].[dm_xe_{0}session_targets] [t] ON [s].[address] = [t].[event_session_address]; ';

	CREATE TABLE #states (
		[name] sysname NOT NULL, 
		[buffer_policy_des] sysname NOT NULL,
		[dropped_event_count] int NOT NULL, 
		[dropped_buffer_count] int NOT NULL, 
		[blocked_event_fire_time] int NOT NULL,
		[create_time] datetime NOT NULL
	);
	
	DECLARE @versionCols nvarchar(MAX) = N'';
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	IF (SELECT dbo.[get_engine_version]()) >= 14.00 BEGIN 
		ALTER TABLE [#states] ADD [buffer_processed_count] bigint NOT NULL;
		ALTER TABLE [#states] ADD [total_bytes_generated] bigint NOT NULL;

		SET @versionCols = @versionCols + @crlftab + N'[s].[buffer_processed_count], ' + @crlftab + N'[s].[buffer_processed_count],';
	END; 

	IF (SELECT dbo.[get_engine_version]()) >= 15.00 BEGIN 
		ALTER TABLE [#states] ADD [total_target_memory] bigint NOT NULL;

		SET @versionCols = @versionCols + @crlftab + N'[s].[total_target_memory],';
	END;
	
	ALTER TABLE [#states] ADD [target_data] nvarchar(MAX) NULL;
	ALTER TABLE [#states] ADD [bytes_written] bigint NOT NULL;

	SET @sql = REPLACE(@sql, N'{version_specific}', @versionCols);
	
	IF @xeSource = N'database'
		SET @sql = REPLACE(@sql, N'{0}', N'database_');
	ELSE 
		SET @sql = REPLACE(@sql, N'{0}', N'');

	INSERT INTO [#states] -- MKC: hmmm... being lazy and using shorthand syntax. usually comes to bite me later on. 
	EXEC sp_executesql 
		@sql

	SET @sql = N'SELECT 
	[event_session_id], 
	CAST([value] as sysname) [file_name] 
FROM 
	[sys].[{0}_event_session_fields] 
WHERE 
	LOWER([name]) = N''filename''; ';

	CREATE TABLE #files ( 
		[event_session_id] int NOT NULL, 
		[file_name] sysname NOT NULL 
	); 

	SET @sql = REPLACE(@sql, N'{0}', @xeSource);

	INSERT INTO [#files] ([event_session_id],[file_name])
	EXEC sp_executesql 
		@sql; 

	DECLARE @finalProjection nvarchar(MAX) = N'	SELECT 
		[d].[name] [session_name],
		CASE WHEN [s].[name] IS NULL THEN N''stopped'' ELSE N''RUNNING'' END [status],
		REPLACE(REPLACE([d].[event_retention_mode_desc], N''ALLOW_'', N''''), N''_EVENT_LOSS'', N'''') [loss_mode],
		[d].[max_dispatch_latency] / 1000 [latency],
		[d].[max_memory] / 1024 [buffer_mb],
		--[d].[max_event_size],
		REPLACE([d].[memory_partition_mode_desc], N''PER_'', N'''') [partition],
		[d].[track_causality] [causality],
		[d].[startup_state] [auto_start],
		[d].[storage_type],
		--[s].[buffer_policy_des],
		[f].[file_name]{diagnostics}
	FROM 
		[#definitions] [d]
		LEFT OUTER JOIN [#states] [s] ON [d].[name] = [s].[name]
		LEFT OUTER JOIN [#files] [f] ON [d].[event_session_id] = [f].[event_session_id]{WHERE} 
	ORDER BY 
		[d].[name]{FORXML} ;';

	DECLARE @diagnostics nvarchar(MAX) = N'		{padding}[s].[dropped_event_count] [dropped_events],
		[s].[dropped_buffer_count] [dropped_buffers],
		[s].[blocked_event_fire_time] [blocked_latency],
		[s].[create_time], 
		[s].[target_data],{version_specific} 
		[s].[bytes_written] ';

	IF @IncludeDiagnostics = 1 BEGIN 
	   	SET @finalProjection = REPLACE(@finalProjection, N'{diagnostics}', N',' + @crlftab + @diagnostics);
		SET @finalProjection = REPLACE(@finalProjection, N'{version_specific}', REPLACE(@versionCols, NCHAR(9), NCHAR(9) + NCHAR(9)));
	  END; 
	ELSE 
		SET @finalProjection = REPLACE(@finalProjection, N'{diagnostics}', N'');

	IF @TargetSessionName IS NOT NULL 
		SET @finalProjection = REPLACE(@finalProjection, N'{WHERE}', @crlftab + N'WHERE' + @crlftab + NCHAR(9) + N'LOWER([d].[name]) = LOWER(@TargetSessionName)'); 
	ELSE 
		SET @finalProjection = REPLACE(@finalProjection, N'{WHERE}', N''); 

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- RETURN instead of project.. 
		SET @finalProjection = REPLACE(@finalProjection, N'{padding}', N'');	

		SET @finalProjection = REPLACE(@finalProjection, N'{FORXML}', @crlftab + N'FOR XML PATH(''session''), ROOT(''sessions'')');
		SET @finalProjection = REPLACE(@finalProjection, N'SELECT', N'SELECT @output = (SELECT');
		SET @finalProjection = REPLACE(@finalProjection, N';', N');');

		DECLARE @output xml;
		EXEC [sys].[sp_executesql]
			@finalProjection, 
			N'@TargetSessionName sysname, @output xml OUTPUT', 
			@TargetSessionName = @TargetSessionName,
			@output = @output OUTPUT

		SET @SerializedOutput = @output;

		RETURN 0;
	END;

	-- If we're still here: PROJECT:
	SET @finalProjection = REPLACE(@finalProjection, N'{FORXML}', N'');
	SET @finalProjection = REPLACE(@finalProjection, N'{padding}', N''''' [ ],');
	
	EXEC sys.[sp_executesql]
		@finalProjection, 
		N'@TargetSessionName sysname', 
		@TargetSessionName = @TargetSessionName;

	RETURN 0;
GO	