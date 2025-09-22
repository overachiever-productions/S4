/*
	-- PICKUP / NEXT:
	-- CHECK for 'can RECONFIGURE' (or not) early-on in the process ... 
	--		and ... 'outsource' it to a sproc ... that does project/return ... 
	--		that way, if there's a problem where we can't do it... we fail early and say something like: "doh, can't RECONFIGURE cuz x, y, z. review these ... look at docs, correct or ... @PRintOnly = 1 but beware". 
	--	also, might be nice to see if there's a way to determine if I should add "WITH OVERRIDE" ... 
	-- and... bundle this logic into dbo.configure_instance as well. 


	TODO: 
		- Make this the CLIX:
			CREATE NONCLUSTERED INDEX [<Name of Missing Index, sysname,>]
			ON [dbo].[eventstore_blocked_processes] ([timestamp],[blocking_xactid],[blocked_xactid])
			INCLUDE ([seconds_blocked],[blocked_id])

		- Existing CLIX to become just the PK... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_enable_blocked_processes]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_enable_blocked_processes];
GO

CREATE PROC dbo.[eventstore_enable_blocked_processes]
	@TargetSessionName						sysname = N'eventstore_blocked_processes', 
	@TargetEventStoreTable					sysname = N'admindb.dbo.eventstore_blocked_processes', 
	@EtlProcedureName						sysname = N'admindb.dbo.eventstore_etl_blocked_processes',
	@TraceTarget							sysname = N'event_file', 
	@TraceFilePath							sysname = N'D:\Traces', 
	@MaxFiles								int = 10, 
	@FileSizeMB								int = 200, 
	@MaxBufferEvents						int = 1024,
	@StartupState							bit = 1, 
	@StartSessionOnCreation					bit = 1,
	@BlockedProcessThreshold				int = 2, 
	@EventStoreDataRetentionDays			int = 60,
	@OverwriteSessionIfExists				sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteTableIfExists					sysname = NULL,			-- { KEEP | REPLACE} 
	@OverwriteSettingsIfExist				sysname = NULL,			-- { KEEP | REPLACE} 
	@PrintOnly								bit = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @eventStoreKey sysname = N'BLOCKED_PROCESSES';

	SET @TargetSessionName = ISNULL(NULLIF(@TargetSessionName, N''), N'eventstore_blocked_processes');
	SET @TargetEventStoreTable = ISNULL(NULLIF(@TargetEventStoreTable, N''), N'admindb.dbo.eventstore_blocked_processes');
	SET @EtlProcedureName = ISNULL(@EtlProcedureName, N'admindb.dbo.eventstore_etl_blocked_processes');
	SET @BlockedProcessThreshold = ISNULL(NULLIF(@BlockedProcessThreshold, 0), 2);

	DECLARE @command nvarchar(MAX);
	DECLARE @errorMessage nvarchar(MAX);
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Blocked Processes Threshold:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @currentThreshold int = (SELECT CAST(value_in_use AS int) FROM sys.[configurations] WHERE [name] = N'blocked process threshold (s)');

	IF @currentThreshold <> @BlockedProcessThreshold BEGIN 

-- TODO: verify that we can execute a RECONFIGURE (i.e., no pending ugliness or potential problems);
/* Verify that we can RECONFIGURE */

-- TODO: I think i should probably 'wrap' sp_configure calls in a sproc - so that 'my' code doesn't echo things like "COnfiguration option 'x' changed from x to y. Run Reconfigure...
		SET @command = N'/*---------------------------------------------------------------------------------------------------------------------------------------------------
-- Set Blocked Process Threshold on Server:
---------------------------------------------------------------------------------------------------------------------------------------------------*/
EXEC sp_configure ''blocked process threshold'', ' + CAST(@BlockedProcessThreshold AS sysname) + N'; ';

		IF @PrintOnly = 1 BEGIN 
			PRINT @command;
			PRINT N'GO';
			PRINT N'';
			PRINT N'RECONFIGURE;';
			PRINT N'GO';
			PRINT N'';
		  END; 
		ELSE BEGIN 
			BEGIN TRY
				EXEC sys.[sp_executesql] 
					@command; 

				EXEC(N'RECONFIGURE');
			END TRY 
			BEGIN CATCH 
				SET @errorMessage = N'Failed to Set Blocked Process Threshold on Server. ERROR ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE() + N'.';
				PRINT 'would be handling errors here and ... not going through with rest of operation... ';
			END CATCH;
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Table Definition:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreTableDDL nvarchar(MAX) = N'CREATE TABLE [{schema}].[{table}](
	[row_id] [int] IDENTITY(1,1) NOT NULL,
	[timestamp] [datetime2](7) NOT NULL,
	[database] [nvarchar](128) NOT NULL,
	[seconds_blocked] [decimal](24, 2) NOT NULL,
	[report_id] [int] NOT NULL,
	[blocking_id] sysname NULL,  -- ''self blockers'' can/will be NULL
	[blocked_id] sysname NOT NULL,
	[blocking_xactid] [bigint] NULL,  -- ''self blockers'' can/will be NULL
	[blocking_request] [nvarchar](MAX) NULL,
	[blocking_sproc_statement] [nvarchar](MAX) NULL,
	[blocking_resource_id] [nvarchar](80) NULL,
	[blocking_resource] [varchar](2000) NULL,
	[blocking_wait_time] [int] NULL,
	[blocking_tran_count] [int] NULL,  -- ''self blockers'' can/will be NULL
	[blocking_isolation_level] [nvarchar](128) NULL,   -- ''self blockers'' can/will be NULL
	[blocking_status] sysname NULL,
	[blocking_start_offset] [int] NULL,
	[blocking_end_offset] [int] NULL,
	[blocking_host_name] sysname NULL,
	[blocking_login_name] sysname NULL,
	[blocking_client_app] sysname NULL,
	[blocked_xactid] [bigint] NULL,  -- can be NULL
	[blocked_request] [nvarchar](max) NULL,
	[blocked_sproc_statement] [nvarchar](max) NULL,
	[blocked_resource_id] [nvarchar](80) NULL,
	[blocked_resource] [varchar](2000) NULL,  -- can be NULL if/when there isn''t an existing translation
	[blocked_wait_time] [int] NOT NULL,
	[blocked_tran_count] [int] NOT NULL,
	[blocked_log_used] [int] NOT NULL,
	[blocked_lock_mode] sysname NULL, -- CAN be NULL
	[blocked_isolation_level] [nvarchar](128) NULL,
	[blocked_status] sysname NOT NULL,
	[blocked_start_offset] [int] NOT NULL,
	[blocked_end_offset] [int] NOT NULL,
	[blocked_host_name] sysname NULL,
	[blocked_login_name] sysname NULL,
	[blocked_client_app] sysname NULL,
	[report] [xml] NOT NULL
) ON [PRIMARY]; 

CREATE CLUSTERED INDEX [CLIX_{table}_ByRowID] ON [{table}] ([row_id]);
CREATE NONCLUSTERED INDEX [COVIX_{table}_details_ByTxIds] ON [{table}] ([blocking_xactid],[blocked_xactid]) INCLUDE ([timestamp],[seconds_blocked]); ';

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Session Definition:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @eventStoreSessionDDL nvarchar(MAX) = N'CREATE EVENT SESSION [{session_name}] ON {server_or_database} 
	ADD EVENT sqlserver.blocked_process_report()
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
		@EtlFrequencyMinutes = 10,
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