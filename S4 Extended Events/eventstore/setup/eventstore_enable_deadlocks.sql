/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_enable_deadlocks]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_enable_deadlocks];
GO

CREATE PROC dbo.[eventstore_enable_deadlocks]
	@TargetSessionName						sysname = N'eventstore_deadlocks', 
	@TargetEventStoreTable					sysname = N'admindb.dbo.eventstore_deadlocks', 
	@EtlProcedureName						sysname = N'admindb.dbo.eventstore_etl_deadlocks',
	@TraceTarget							sysname = N'event_file', 
	@TraceFilePath							sysname = N'D:\Traces', 
	@MaxFiles								int = 4, 
	@FileSizeMB								int = 100, 
	@MaxBufferEvents						int = 1024,
	@StartupState							bit = 1, 
	@StartSessionOnCreation					bit = 1,
	@EventStoreDataRetentionDays			int = 60,
	@OverwriteSessionIfExists				sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteTableIfExists					sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteSettingsIfExist				sysname = NULL,			-- { KEEP | REPLACE} 
	@PrintOnly								bit = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @eventStoreKey sysname = N'DEADLOCKS';

	SET @TargetSessionName = ISNULL(NULLIF(@TargetSessionName, N''), N'eventstore_deadlocks');
	SET @TargetEventStoreTable = ISNULL(NULLIF(@TargetEventStoreTable, N''), N'admindb.dbo.eventstore_deadlocks');	
	SET @EtlProcedureName = ISNULL(@EtlProcedureName, N'admindb.dbo.eventstore_etl_deadlocks');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Table Definition:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreTableDDL nvarchar(MAX) = N'CREATE TABLE [{schema}].[{table}] (
	[timestamp] [datetime] NULL,
	[deadlock_id] [int] NOT NULL,
	[process_count] [int] NOT NULL,
	[session_id] [varchar](30) NOT NULL,
	--[process_id] [varchar](30) NOT NULL,
	[application_name] [sysname] NULL,
	[host_name] [sysname] NULL,
	[transaction_count] [int] NULL,
	[lock_mode] [varchar](20) NULL,
	[wait_time_ms] bigint NULL,
	[log_used] [bigint] NULL,
	[wait_resource_id] [varchar](200) NULL,
	[wait_resource] [varchar](2000) NULL,
	[proc] [nvarchar](MAX) NULL,
	[statement] [nvarchar](MAX) NULL,
	[input_buffer] [nvarchar](MAX) NULL,
	[deadlock_graph] [xml] NULL
);';

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Session Definition:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreSessionDDL nvarchar(MAX) = N'CREATE EVENT SESSION [{session_name}] ON {server_or_database} 
	ADD EVENT sqlserver.xml_deadlock_report ()
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

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing (via core/base functionality):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @enableETL bit = COALESCE(NULLIF(@StartupState, 0), NULLIF(@StartSessionOnCreation, 0), 0);

	DECLARE @returnValue int;
	EXEC @returnValue = dbo.[eventstore_setup_session]
		@EventStoreKey = @eventStoreKey,
		@TargetSessionName = @TargetSessionName,
		@TargetEventStoreTable = @TargetEventStoreTable,
		@TraceTarget = @TraceTarget,
		@TraceFilePath = @TraceFilePath,
		@MaxFiles = @MaxFiles,
		@FileSizeMB = @FileSizeMB,
		@MaxBufferEvents = @MaxBufferEvents,
		@StartupState = @StartupState,
		@StartSessionOnCreation = @StartSessionOnCreation,
		@EtlEnabled = @enableETL,
		@EtlFrequencyMinutes = 2,  -- some deadlocks can/will be against tempdb objects - so... more frequent extraction/transform = better insight.
		@EtlProcedureName = @EtlProcedureName,
		@DataRetentionDays = @EventStoreDataRetentionDays,
		@OverwriteSessionIfExists = @OverwriteSessionIfExists,
		@OverwriteTableIfExists = @OverwriteTableIfExists,
		@OverwriteSettingsIfExist = @OverwriteSettingsIfExist,
		@EventStoreTableDDL = @eventStoreTableDDL,
		@EventStoreSessionDDL =@eventStoreSessionDDL,
		@PrintOnly = @PrintOnly;

	RETURN @returnValue;
GO