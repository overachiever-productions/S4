/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_enable_all_errors]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_enable_all_errors];
GO

CREATE PROC dbo.[eventstore_enable_all_errors]
	@TargetSessionName						sysname = N'eventstore_all_errors', 
	@TargetEventStoreTable					sysname = N'admindb.dbo.eventstore_all_errors', 
	@EtlProcedureName						sysname = N'admindb.dbo.eventstore_etl_all_errors',
	@TraceTarget							sysname = N'event_file',				
	@TraceFilePath							sysname = N'D:\Traces', 
	@MaxFiles								int = 8, 
	@FileSizeMB								int = 200,
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
	
	DECLARE @eventStoreKey sysname = N'ALL_ERRORS';

	SET @TargetSessionName = ISNULL(NULLIF(@TargetSessionName, N''), N'eventstore_all_errors');
	SET @TargetEventStoreTable = ISNULL(NULLIF(@TargetEventStoreTable, N''), N'admindb.dbo.eventstore_all_errors');	
	SET @EtlProcedureName = ISNULL(@EtlProcedureName, N'admindb.dbo.eventstore_etl_all_errors');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Table Definition:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreTableDDL nvarchar(MAX) = N'CREATE TABLE [{schema}].[{table}] (
	[timestamp] [datetime] NULL,
	[operation] [varchar](30) NULL,
	[error_number] [int] NULL,
	[severity] [int] NULL,
	[state] [int] NULL,
	[message] [varchar](max) NULL,
	[database] [sysname] NULL,
	[user_name] [sysname] NULL,
	[host_name] [varchar](max) NULL,
	[application_name] [varchar](max) NULL,
	[is_system] [bit] NULL,
	[statement] [varchar](max) NULL, 
	[report] [xml] NULL
) 
WITH (DATA_COMPRESSION = PAGE); ';

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Session Definition:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreSessionDDL nvarchar(MAX) = N'CREATE EVENT SESSION [{session_name}] ON {server_or_database} 
	ADD EVENT sqlserver.error_reported (  
		ACTION (
			[sqlserver].[client_app_name],
			[sqlserver].[client_hostname],
			[sqlserver].[database_name],
			[sqlserver].[is_system],
			[sqlserver].[nt_username],
			[sqlserver].[sql_text],
			[sqlserver].[tsql_frame],
			[sqlserver].[tsql_stack],
			[sqlserver].[server_principal_name]		
		)
		WHERE (
			[error_number] > 0		AND			-- number of ''noise errors'' with 0 and -1 error_numbers... 
			[error_number] <> 2528	AND			-- dbcc completed.
			[error_number] <> 3014	AND			-- tlog backup success
			[error_number] <> 3197	AND			-- I/O is frozen on database %ls. No user action is required. However, if I/O is not resumed promptly, you could cancel the backup.
			[error_number] <> 3198	AND			-- I/O was resumed on database %ls. No user action is required.
			[error_number] <> 3262	AND			-- backup file is valid
			[error_number] <> 4035	AND			-- backup pages (count) processed
			[error_number] <> 5701	AND			-- db changed
			[error_number] <> 5703	AND			-- language changed
			[error_number] <> 8153	AND			-- Null value eliminated in aggregate
			[error_number] <> 14205 AND			-- (Unknown) (literally)
			[error_number] <> 14553 AND			-- Replication Distribution Subsystem (NOT an error).... 
			[error_number] <> 14570 AND			-- (Job Outcome) 
			[error_number] <> 15650 AND			-- Updating [object] stats... 
			[error_number] <> 15651 AND			-- # indexes/stats ... have been updated, # did not require update... 
			[error_number] <> 15652 AND			-- [object] has been updated (stats)
			[error_number] <> 15653 AND			-- Status update NOT necessary... 
			[error_number] <> 17550 AND			-- DBCC TRACEON 3604...
			[error_number] <> 17551 AND			-- DBCC TRACEOFF 3604...
			[error_number] <> 22121 AND			-- repl cleanup message... 
			[error_number] <> 22803 AND			-- CDC has scanned the log from LSN ..... 	

			[message] NOT LIKE ''Command: UPDATE STATISTICS%'' -- commonly finding BAZILLIONS of these on most servers (obviously) - which muddies the waters... 
		)
	)
	ADD TARGET {xe_target}
    WITH (
		MAX_MEMORY = 16 MB,
		EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
		MAX_DISPATCH_LATENCY = 30 SECONDS,
		MAX_EVENT_SIZE = 0 KB,
		MEMORY_PARTITION_MODE = PER_NODE,  
		TRACK_CAUSALITY = OFF, 
		STARTUP_STATE = {startup_state}
    ); ';

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