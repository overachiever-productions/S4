/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_init_capture_large_sql]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_init_capture_large_sql];
GO

CREATE PROC dbo.[eventstore_init_capture_large_sql]
	@TargetSessionName						sysname = N'capture_large_sql', 
	@TargetEventStoreTable					sysname = N'admindb.dbo.eventstore_large_sql', 
	@TraceTarget							sysname = N'event_file',				
	@TraceFilePath							sysname = N'D:\Traces', 
	@MaxFiles								int = 10, 
	@FileSizeMB								int = 200,
	@MaxBufferEvents						int = 1024,
	@StartupState							bit = 1, 
	@StartSessionOnCreation					bit = 1,
	@DurationMillisecondsThreshold			int = 20000,
	@CPUMillisecondsThreshold				int = 15000,
	@RowCountThreshold						int = 20000,
	@ReplaceSessionIfExists					sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteTableIfExists					sysname = NULL,			-- { KEEP | REPLACE} 
	@PrintOnly								bit = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetSessionName = ISNULL(NULLIF(@TargetSessionName, N''), N'capture_large_sql');
	SET @TargetEventStoreTable = ISNULL(NULLIF(@TargetEventStoreTable, N''), N'admindb.dbo.xestore_large_sql');	

	SET @DurationMillisecondsThreshold = ISNULL(NULLIF(@DurationMillisecondsThreshold, 0), 20000);
	SET @CPUMillisecondsThreshold = ISNULL(NULLIF(@CPUMillisecondsThreshold, 0), 15000);
	SET @RowCountThreshold = ISNULL(NULLIF(@RowCountThreshold, 0), 20000);

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Table Definition:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @eventStoreTableDDL nvarchar(MAX) = N'CREATE TABLE [{schema}].[{table}] (
	[timestamp] [datetime] NULL,
	[database_name] [sysname] NULL,
	[user_name] [sysname] NULL,
	[host_name] [sysname] NULL,
	[application_name] [sysname] NULL,
	[module] [sysname] NULL,
	[statement] [nvarchar](max) NULL,
	[offset] [nvarchar](259) NULL,
	[cpu_ms] [bigint] NULL,
	[duration_ms] [bigint] NULL,
	[physical_reads] [bigint] NULL,
	[writes] [bigint] NULL,
	[row_count] [bigint] NULL,
	[report] [xml] NULL
) 
WITH (DATA_COMPRESSION = PAGE); ';

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Session Definition:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @eventStoreSessionDDL nvarchar(MAX) = N'CREATE EVENT SESSION [{session_name}] ON {server_or_database} 
	ADD EVENT sqlserver.sql_statement_completed (
		SET 
			collect_statement = 1 
		ACTION (
			[sqlserver].[database_name],
			[sqlserver].[client_app_name],
			[sqlserver].[client_hostname], 
			[sqlserver].[session_id], 
			[sqlserver].[username]
		)
		WHERE (
			[duration] > {durationMS}000 
			OR 
			[cpu_time] > {cpuMS}000 
			OR 
			[row_count] > {rowCount}
		)
	), 
	ADD EVENT sqlserver.rpc_completed (
		ACTION ( 
			[sqlserver].[database_name],
			[sqlserver].[client_app_name],
			[sqlserver].[client_hostname], 
			[sqlserver].[session_id], 
			[sqlserver].[username]
		)
		WHERE  (
			[duration] > {durationMS}000 
			OR 
			[cpu_time] > {cpuMS}000 
			OR 
			[row_count] > {rowCount}
		)
	)
	ADD TARGET {xe_target}
	WITH (
		MAX_MEMORY = 16MB,
		EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
		MAX_DISPATCH_LATENCY = 30 SECONDS,
		MAX_EVENT_SIZE = 0KB,
		MEMORY_PARTITION_MODE = PER_NODE,
		TRACK_CAUSALITY = OFF,
		STARTUP_STATE = {startup_state}
	);	';

	SET @eventStoreSessionDDL = REPLACE(@eventStoreSessionDDL, N'{durationMS}', @DurationMillisecondsThreshold);
	SET @eventStoreSessionDDL = REPLACE(@eventStoreSessionDDL, N'{cpuMS}', @CPUMillisecondsThreshold);
	SET @eventStoreSessionDDL = REPLACE(@eventStoreSessionDDL, N'{rowCount}', @RowCountThreshold);
	
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing (via core/base functionality):
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @returnValue int;
	EXEC @returnValue = dbo.[eventstore_initialize_session]
		@TargetSessionName = @TargetSessionName,
		@TargetEventStoreTable = @TargetEventStoreTable,
		@TraceTarget = @TraceTarget,
		@TraceFilePath = @TraceFilePath,
		@MaxFiles = @MaxFiles,
		@FileSizeMB = @FileSizeMB,
		@MaxBufferEvents = @MaxBufferEvents,
		@StartupState = @StartupState,
		@StartSessionOnCreation = @StartSessionOnCreation,
		@ReplaceSessionIfExists = @ReplaceSessionIfExists,
		@OverwriteTableIfExists = @OverwriteTableIfExists,
		@EventStoreTableDDL = @eventStoreTableDDL,
		@EventStoreSessionDDL = @eventStoreSessionDDL,
		@PrintOnly = @PrintOnly;

	RETURN @returnValue;
GO