/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_enable_capture_plan_costs]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_enable_capture_plan_costs];
GO

CREATE PROC dbo.[eventstore_enable_capture_plan_costs]
	@TargetSessionName						sysname = N'eventstore_plan_costs', 
	@TargetEventStoreTable					sysname = N'admindb.dbo.eventstore_plan_costs', 
	@EtlProcedureName						sysname = N'admindb.dbo.eventstore_etl_plan_costs',
	@TraceTarget							sysname = N'event_file', 
	@TraceFilePath							sysname = N'D:\Traces', 
	@MaxFiles								int = 10, 
	@FileSizeMB								int = 200,
	@MaxBufferEvents						int = 1024,
	@StartupState							bit = 1, 
	@StartSessionOnCreation					bit = 1,
	@CostThreshold							int = 200,
	@EventStoreDataRetentionDays			int = 60,
	@OverwriteSessionIfExists				sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteTableIfExists					sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteSettingsIfExist				sysname = NULL,			-- { KEEP | REPLACE} 
	@PrintOnly								bit = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

-- WARN: the stuff below is ... huge. 
-- TODO: SQL Server 2019 - Prior to CU18 throws GOBS of access errors if/when attempting to set up this XE. 
--	see: https://app.todoist.com/showTask?id=6434454019 

	DECLARE @eventStoreKey sysname = N'PLAN_COSTS';

	SET @TargetSessionName = ISNULL(NULLIF(@TargetSessionName, N''), N'eventstore_plan_costs');
	SET @TargetEventStoreTable = ISNULL(NULLIF(@TargetEventStoreTable, N''), N'admindb.dbo.eventstore_plan_costs');
	SET @EtlProcedureName = ISNULL(@EtlProcedureName, N'admindb.dbo.eventstore_etl_plan_costs');

	SET @CostThreshold = ISNULL(NULLIF(@CostThreshold, 0), 200);

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Table Definition:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @eventStoreTableDDL nvarchar(MAX) = N'CREATE TABLE [{schema}].[{table}](
	[timestamp] [datetime2](7) NULL,
	[database_name] [sysname] NULL,
	[user_name] [sysname] NULL,
	[host_name] [sysname] NULL,
	[app_name] [sysname] NULL,
	[cpu_time] [int] NULL,
	[duration] [int] NULL,
	[estimated_rows] [int] NULL,
	[estimated_cost] [int] NULL,
	[granted_memory_kb] [int] NULL,
	[dop] [int] NULL,
	[object_name] [sysname] NULL,
	[query_hash] [bigint] NULL,
	[statement] [varchar](max) NULL,
	[plan] [xml] NULL
) ON [PRIMARY]; -- TODO: IXes and page compression, etc.';

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Session Definition:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @eventStoreSessionDDL nvarchar(MAX) = N'CREATE EVENT SESSION [{session_name}] ON {server_or_database} 
	ADD EVENT sqlserver.query_post_execution_plan_profile (
		SET collect_database_name = 1
		ACTION (
			sqlserver.client_app_name,
			sqlserver.client_hostname,
			sqlserver.is_system,
			sqlserver.query_hash_signed,
			sqlserver.query_plan_hash_signed,
			sqlserver.sql_text,
			sqlserver.username
		)
		WHERE ([estimated_cost] > {cost_threshold})
	)
	ADD TARGET {xe_target}
	WITH (
		MAX_MEMORY = 32MB,
		EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
		MAX_DISPATCH_LATENCY = 30 SECONDS,
		MAX_EVENT_SIZE = 0KB,
		MEMORY_PARTITION_MODE = PER_NODE,
		TRACK_CAUSALITY = OFF,
		STARTUP_STATE = {startup_state}
	);	';

	SET @eventStoreSessionDDL = REPLACE(@eventStoreSessionDDL, N'{cost_threshold}', @CostThreshold);

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing (via core/base functionality):
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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
		@EtlFrequencyMinutes = 5,
		@EtlProcedureName = @EtlProcedureName,
		@DataRetentionDays = @EventStoreDataRetentionDays,		
		@OverwriteSessionIfExists = @OverwriteSessionIfExists,
		@OverwriteTableIfExists = @OverwriteTableIfExists,
		@OverwriteSettingsIfExist = @OverwriteSettingsIfExist,
		@EventStoreTableDDL = @eventStoreTableDDL,
		@EventStoreSessionDDL = @eventStoreSessionDDL,
		@PrintOnly = @PrintOnly;

	RETURN @returnValue;
GO