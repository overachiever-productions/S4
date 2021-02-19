/*

	BLUEPRINT: 
		This script: 
			- does NOT create/template batched operations (admindb.dbo.idiom_for_batched_operations does that). 
			- INSTEAD, it creates SPROCs that wrap batched-operations in a one-off, optimal, wrapper.
					where, the wrapper can/does also 'call out' (optionally) to a config table.


			EXEC [admindb]..[blueprint_for_batched_operation]
				@TargetDatabase = N'Meddling', 
				@GeneratedSprocName = N'TEST_DELETE_SPROC',
				@DefaultNumberOfDaysToKeep = 90,
				@DefaultBatchSize = 20000, 
				@ConfigurationKey = N'Actions.Something', 
				@ConfigurationTableName = N'dbo.DeleteConfigurations';
				--@ConfigurationKey = NULL,
				--@ConfigurationTableName = NULL,
				--@AllowDynamicSizing = 1,
				--@AllowMaxErrors = 1,
				--@AllowDeadlocksAsErrors = 1,
				--@AllowMaxExecutionSeconds = 1,
				--@AllowStopOnTempTableExists = 1



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.blueprint_for_batched_operation','P') IS NOT NULL
	DROP PROC dbo.[blueprint_for_batched_operation];
GO

CREATE PROC dbo.[blueprint_for_batched_operation]
	@DefaultNumberOfDaysToKeep						int, 
	@DefaultBatchSize								int, 
	@DefaultWaitDuration							sysname		= N'00:00:01.55',

	@TargetDatabase									sysname		= N'<db_name_here>',
	@GeneratedSprocName								sysname		= N'<sproc_name_here>', 
	@ConfigurationKey								sysname		= NULL,				-- if present, then config is possible.
	@ConfigurationTableName							sysname		= NULL, 

	@ProcessingHistoryTableName						sysname		= NULL,

	@AllowDynamicBatchSizing						bit			= 1, 
	@AllowMaxErrors									bit			= 1, 
	@AllowDeadlocksAsErrors							bit			= 1, 
	@AllowMaxExecutionSeconds						bit			= 1, 
	@AllowStopOnTempTableExists						bit			= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	------------------------------------------------------------------------------------------------------------------------------
	-- Validate Inputs:
	-- i.e., input params for THIS blueprint sproc... 

	SET @TargetDatabase = ISNULL(NULLIF(@TargetDatabase, N''), N'<db_name_here>');
	SET @GeneratedSprocName = ISNULL(NULLIF(@GeneratedSprocName, N''), N'<sproc_name_here>');
	SET @DefaultWaitDuration = ISNULL(NULLIF(@DefaultWaitDuration, N''), N'00:00:01.500');
	
	SET @ConfigurationKey = NULLIF(@ConfigurationKey, N'');
	SET @ConfigurationTableName = NULLIF(@ConfigurationTableName, N'');
	SET @ProcessingHistoryTableName = NULLIF(@ProcessingHistoryTableName, N'');

	IF (@DefaultBatchSize IS NULL OR @DefaultBatchSize < 0) OR (@DefaultNumberOfDaysToKeep IS NULL OR @DefaultNumberOfDaysToKeep < 0) BEGIN 
		RAISERROR('@DefaultBatchSize and @DefaultNumberOfDaysToKeep must both be set to non-NULL values > 0 - even when @UseConfig = 1.', 16, 1);
		RETURN -6;
	END;

	DECLARE @useConfiguration bit = 0;
	IF (@ConfigurationKey IS NOT NULL) OR (@ConfigurationTableName IS NOT NULL) BEGIN 
		IF (@ConfigurationKey IS NULL) OR (@ConfigurationTableName IS NULL) BEGIN 
			RAISERROR(N'@ConfigurationKey and @ConfigurationTableName must BOTH be specified in order to allow use of configuration-table overrides.', 16, 1);
			RETURN -10;
		END;

		SET @useConfiguration = 1;
	END;

	------------------------------------------------------------------------------------------------------------------------------
	-- Header/Signature:
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @loggingTableName sysname = N'#batched_operation_' + LEFT(CAST(NEWID() AS sysname), 8);

	---------------------------------------------------------------------------------------------------
	-- Sproc Signature and Configuration Settings:
	---------------------------------------------------------------------------------------------------

	DECLARE @signature nvarchar(MAX) = N'USE [{target_database}];
GO

IF OBJECT_ID(''dbo.{sproc_name}'',''P'') IS NOT NULL
	DROP PROC dbo.[{sproc_name}];
GO

CREATE PROC dbo.[{sproc_name}]
{parameters}
AS
    SET NOCOUNT ON; 

	-- NOTE: this code was generated from admindb.dbo.blueprint_for_batched_operation.
	
	-- Parameter Scrubbing/Cleanup:
	{cleanup}

	{configuration}
	';

	DECLARE @parameters nvarchar(MAX) = N'	@DaysWorthOfDataToKeep					int			= {default_retention},
	@KeepAllDataNewerThan					datetime	= NULL, 
	@BatchSize								int			= {default_batch_size},
	@WaitForDelay							sysname		= N''{default_wait_for}'',{configuration}{allow_batch_tuning}{total_cleanup_seconds}{default_max_errors}{deadlocks_as_errors}{safe_stop_name}
	@PersistHistory							bit			= {default_save_history}';

	DECLARE @cleanup nvarchar(MAX) = N'SET @WaitForDelay = NULLIF(@WaitForDelay, N'''');{configKeys}{tempTableName}';
	DECLARE @configuration nvarchar(MAX) = N'---------------------------------------------------------------------------------------------------------------
	-- Optional Retrieval of Settings via Configuration Table:
	---------------------------------------------------------------------------------------------------------------
	IF @ConfigurationKey IS NOT NULL BEGIN 

		BEGIN TRY 
			-- Reset/Load Input Values from Config Table INSTEAD of via parameters passed in to sproc: 
			DECLARE @configError nvarchar(MAX) = N'''';
			DECLARE @configSQL nvarchar(MAX) = N''SELECT 
				@BatchSize = [batch_size],
				@WaitForDelay = [wait_for_delay],
				@MaxExecutionSeconds = [max_execution_seconds],
				@TreatDeadlocksAsErrors = [treat_deadlocks_as_errors],
				@MaxAllowedErrors = [max_allowed_errors],
				@AllowDynamicBatchSizing = [enable_dynamic_batch_sizing],
				@MaxAllowedBatchSizeMultiplier = [max_batch_size_multiplier],
				@TargetBatchMilliseconds = [target_batch_milliseconds],
				@StopIfTempTableExists = [stop_if_tempdb_table_exists],
				@PersistHistory = [persist_history]		
			FROM 
				{configuration_table_name}
			WHERE	
				[configuration_key] = @ConfigurationKey; '';

			EXEC sp_executesql 
				@configSQL, 
				N''@BatchSize int OUTPUT,
				@WaitForDelay sysname OUTPUT,
				@AllowDynamicBatchSizing bit OUTPUT,
				@MaxAllowedBatchSizeMultiplier int OUTPUT, 
				@TargetBatchMilliseconds int OUTPUT,
				@MaxExecutionSeconds int OUTPUT,
				@MaxAllowedErrors int OUTPUT,
				@TreatDeadlocksAsErrors bit OUTPUT,
				@StopIfTempTableExists sysname OUTPUT,
				@PersistHistory bit OUTPUT, 
				@ConfigurationKey sysname'', 
				@BatchSize = @BatchSize OUTPUT,
				@WaitForDelay = @WaitForDelay OUTPUT,
				@AllowDynamicBatchSizing = @AllowDynamicBatchSizing OUTPUT,
				@MaxAllowedBatchSizeMultiplier = @MaxAllowedBatchSizeMultiplier OUTPUT,
				@TargetBatchMilliseconds = @TargetBatchMilliseconds OUTPUT,
				@MaxExecutionSeconds = @MaxExecutionSeconds OUTPUT,
				@MaxAllowedErrors = @MaxAllowedErrors OUTPUT,
				@TreatDeadlocksAsErrors = @TreatDeadlocksAsErrors OUTPUT,
				@StopIfTempTableExists = @StopIfTempTableExists OUTPUT,
				@PersistHistory = @PersistHistory OUTPUT,
				@ConfigurationKey = @ConfigurationKey;

			IF @BatchSize IS NULL BEGIN
				RAISERROR(''Invalid Configuration Key Specified. Key: %s did NOT match any keys in table: {configuration_table_name}. Unable to continue. Terminating.'', 16, 1, @ConfigurationKey);
			END;

		END TRY 
		BEGIN CATCH 
			SELECT @configError = N''ERROR NUMBER: '' + CAST(ERROR_NUMBER() as sysname) + N''. ERROR MESSAGE: '' + ERROR_MESSAGE();
			RAISERROR(@configError, 16, 1);
			RAISERROR(''Unexecpted Error Attempting retrieval of Configuration Values from Configuration Table {configuration_table_name}. Unable to continue. Terminating.'', 16, 1);
			RETURN -100;
		END CATCH
	END; ';
	DECLARE @declarations nvarchar(MAX) = N'';

	SET @parameters = REPLACE(@parameters, N'{default_retention}', @DefaultNumberOfDaysToKeep);
	SET @parameters = REPLACE(@parameters, N'{default_batch_size}', @DefaultBatchSize);
	SET @parameters = REPLACE(@parameters, N'{default_wait_for}', @DefaultWaitDuration);
	SET @parameters = REPLACE(@parameters, N'{default_save_history}', 0);	

	IF @useConfiguration = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{configuration}', @crlf + @tab + N'@ConfigurationKey						sysname		= NULL,' + @crlf + @tab + '@ConfigurationTable						sysname		= NULL, ');	
		SET @cleanup = REPLACE(@cleanup, N'{configKeys}', @crlf + @tab + N'SET @ConfigurationKey = NULLIF(@ConfigurationKey, N'''');' + @crlf + @tab + N'SET @ConfigurationTable = NULLIF(@ConfigurationTable, N'''');');
	  END;
	ELSE BEGIN
		SET @parameters = REPLACE(@parameters, N'{configuration}', N'');	
		SET @cleanup = REPLACE(@cleanup, N'{configKeys}', N'');
	END;

	IF @AllowDynamicBatchSizing = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{allow_batch_tuning}', @crlf + @tab + N'@AllowDynamicBatchSizing				bit			= 0,' + @crlf + @tab + '@MaxAllowedBatchSizeMultiplier			int			= 5, ' + @crlf + @tab + N'@TargetBatchMilliseconds				int			= 4200,');	
	  END;
	ELSE BEGIN 
		SET @parameters = REPLACE(@parameters, N'{allow_batch_tuning}', N'');	
	END;

	IF @AllowMaxExecutionSeconds = 1  
		SET @parameters = REPLACE(@parameters, N'{total_cleanup_seconds}', @crlf + @tab + N'@MaxExecutionSeconds					int			= NULL,');
	ELSE 
		SET @parameters = REPLACE(@parameters, N'{total_cleanup_seconds}', N'');	

	IF @AllowMaxErrors = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{default_max_errors}', @crlf + @tab + N'@MaxAllowedErrors						int			= 1,');
	  END;
	ELSE BEGIN 
		SET @parameters = REPLACE(@parameters, N'{default_max_errors}', N'');
	END;

	IF @AllowDeadlocksAsErrors = 1 
		SET @parameters = REPLACE(@parameters, N'{deadlocks_as_errors}',  @crlf + @tab + N'@TreatDeadlocksAsErrors					bit			= 0,');
	ELSE 
		SET @parameters = REPLACE(@parameters, N'{deadlocks_as_errors}', N'');

	IF @AllowStopOnTempTableExists  = 1 BEGIN 
		SET @parameters = REPLACE(@parameters, N'{safe_stop_name}', @crlf + @tab + N'@StopIfTempTableExists					sysname		= NULL,');
		SET @cleanup = REPLACE(@cleanup, N'{tempTableName}', @crlf + @tab + N'SET @StopIfTempTableExists = ISNULL(@StopIfTempTableExists, N'''');');
	  END;
	ELSE BEGIN
		SET @parameters = REPLACE(@parameters, N'{safe_stop_name}', N'');
		SET @cleanup = REPLACE(@cleanup, N'{tempTableName}', N'');
	END;
	
	SET @configuration = REPLACE(@configuration, N'{configuration_table_name}', @ConfigurationTableName);

	SET @signature = REPLACE(@signature, N'{target_database}', @TargetDatabase);
	SET @signature = REPLACE(@signature, N'{sproc_name}', @GeneratedSprocName);
	SET @signature = REPLACE(@signature, N'{parameters}', @parameters);
	SET @signature = REPLACE(@signature, N'{cleanup}', @cleanup);
	SET @signature = REPLACE(@signature, N'{configuration}', @configuration);


	---------------------------------------------------------------------------------------------------
	-- Initialization:
	---------------------------------------------------------------------------------------------------
DECLARE @initialization nvarchar(MAX) = N'	---------------------------------------------------------------------------------------------------------------
	-- Initialization:
	---------------------------------------------------------------------------------------------------------------
	SET NOCOUNT ON; 

	-- DROP TABLE IF EXISTS [{logging_table_name}];
	CREATE TABLE [{logging_table_name}] (
		[detail_id] int IDENTITY(1,1) NOT NULL, 
		[timestamp] datetime NOT NULL DEFAULT GETDATE(), 
		[is_error] bit NOT NULL DEFAULT (0), 
		[detail] nvarchar(MAX) NOT NULL
	); 

	-- Processing (variables/etc.)
	DECLARE @currentRowsProcessed int = @BatchSize; 
	DECLARE @totalRowsProcessed int = 0;
	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @errorsOccured bit = 0;
	DECLARE @currentErrorCount int = 0;{deadlock_declaration}
	DECLARE @startTime datetime = GETDATE();
	DECLARE @batchStart datetime;{dynamic_batching_declarations}
';

	SET @initialization = REPLACE(@initialization, N'{logging_table_name}', @loggingTableName);

	DECLARE @dynamicBatches nvarchar(MAX) = N'DECLARE @milliseconds int;
	DECLARE @initialBatchSize int = @BatchSize;
	';

	IF @AllowDeadlocksAsErrors = 1 BEGIN 
		SET @initialization = REPLACE(@initialization, N'{deadlock_declaration}', @crlf + @tab + N'DECLARE @deadlockOccurred bit = 0;');
	  END; 
	ELSE BEGIN 
		SET @initialization = REPLACE(@initialization, N'{deadlock_declaration}', N'');
	END;

	IF @AllowDynamicBatchSizing = 1 BEGIN 
		SET @initialization = REPLACE(@initialization, N'{dynamic_batching_declarations}', @crlf + @tab + @dynamicBatches);
	  END; 
	ELSE BEGIN 
		SET @initialization = REPLACE(@initialization, N'{dynamic_batching_declarations}', N'{}');
	END;

	---------------------------------------------------------------------------------------------------
	-- Body/Processing:
	---------------------------------------------------------------------------------------------------
	DECLARE @body nvarchar(MAX) = N'	---------------------------------------------------------------------------------------------------------------
	-- Processing:
	---------------------------------------------------------------------------------------------------------------
	WHILE @currentRowsProcessed = @BatchSize BEGIN 
	
		SET @batchStart = GETDATE();
	
		BEGIN TRY
			BEGIN TRAN; 
				
				-------------------------------------------------------------------------------------------------
				-- batched operation code:
				-------------------------------------------------------------------------------------------------
!!!!!!!!-- Specify YOUR code here, i.e., this is just a TEMPLATE:
				{Batch_Statement} 
!!!!!!!! - end YOUR code... 

				-------------------------------------------

				SELECT 
					@currentRowsProcessed = @@ROWCOUNT, 
					@totalRowsProcessed = @totalRowsProcessed + @@ROWCOUNT;

			COMMIT; 

			INSERT INTO [{logging_table_name}] (
				[timestamp],
				[detail]
			)
			SELECT 
				GETDATE() [timestamp], 
				(
					SELECT 
						@BatchSize [settings.batch_size], 
						@WaitForDelay [settings.wait_for], 
						@currentRowsProcessed [progress.current_batch_count], 
						@totalRowsProcessed [progress.total_rows_processed],
						DATEDIFF(MILLISECOND, @batchStart, GETDATE()) [progress.batch_milliseconds], 
						DATEDIFF(MILLISECOND, @startTime, GETDATE())[progress.total_milliseconds]
					FOR JSON PATH, ROOT(''detail'')
				) [detail];{MaxSeconds}{TerminateIfTempObject}{DynamicTuning}
		
			WAITFOR DELAY @WaitForDelay;
		END TRY
		BEGIN CATCH 
			
			{TreatDeadlocksAsErrors}SELECT @errorDetails = N''Error Number: '' + CAST(ERROR_NUMBER() AS sysname) + N''. Message: '' + ERROR_MESSAGE();

			IF @@TRANCOUNT > 0
				ROLLBACK; 

			INSERT INTO [{logging_table_name}] (
				[timestamp],
				[is_error],
				[detail]
			)
			SELECT
				GETDATE() [timestamp], 
				1 [is_error], 
				( 
					SELECT 
						@currentRowsProcessed [progress.current_batch_count], 
						@totalRowsProcessed [progress.total_rows_processed],
						N''Unexpected Error Occurred: '' + @errorDetails [errors.error]
					FOR JSON PATH, ROOT(''detail'')
				) [detail];
					   
			SET @errorsOccured = 1;
		
			{MaxErrors}
		END CATCH;
	END;

	';

	DECLARE @maxSeconds nvarchar(MAX) = N'	IF DATEDIFF(SECOND, @startTime, GETDATE()) >= @MaxExecutionSeconds BEGIN 
				INSERT INTO [{logging_table_name}] (
					[timestamp],
					[is_error],
					[detail]
				)
				SELECT
					GETDATE() [timestamp], 
					1 [is_error], 
					( 
						SELECT 
							@currentRowsProcessed [progress.current_batch_count], 
							@totalRowsProcessed [progress.total_rows_processed],
							DATEDIFF(MILLISECOND, @batchStart, GETDATE()) [progress.batch_milliseconds], 
							DATEDIFF(MILLISECOND, @startTime, GETDATE())[progress.total_milliseconds],
							CONCAT(N''Maximum execution seconds allowed for execution met/exceeded. Max Allowed Seconds: '', @MaxExecutionSeconds, N''.'') [errors.error]
						FOR JSON PATH, ROOT(''detail'')
					) [detail];
			
				SET @errorsOccured = 1;

				GOTO Finalize;		
			END;';
	DECLARE @tempdbTerminate nvarchar(MAX) = N'	IF OBJECT_ID(N''tempdb..'' + @StopIfTempTableExists) IS NOT NULL BEGIN 
				INSERT INTO [{logging_table_name}] (
					[timestamp],
					[is_error],
					[detail]
				)
				SELECT
					GETDATE() [timestamp], 
					1 [is_error], 
					( 
						SELECT 
							@currentRowsProcessed [progress.current_batch_count], 
							@totalRowsProcessed [progress.total_rows_processed],
							DATEDIFF(MILLISECOND, @batchStart, GETDATE()) [progress.batch_milliseconds], 
							DATEDIFF(MILLISECOND, @startTime, GETDATE())[progress.total_milliseconds],
							N''Graceful execution shutdown/bypass directive detected - object ['' + @StopIfTempTableExists + N''] found in tempdb. Terminating Execution.'' [errors.error]
						FOR JSON PATH, ROOT(''detail'')
					) [detail];
			
				SET @errorsOccured = 1;

				GOTO Finalize;
			END;';
	DECLARE @dynamicTuning nvarchar(MAX) = N'	-- Dynamic Tuning:
			SET @milliseconds = DATEDIFF(MILLISECOND, @batchStart, GETDATE());
			IF @milliseconds <= @TargetBatchMilliseconds BEGIN 
				IF @BatchSize < (@initialBatchSize * @MaxAllowedBatchSizeMultiplier) BEGIN

					SET @BatchSize = FLOOR((@BatchSize + (@BatchSize * .2)) / 100) * 100; 
					IF @BatchSize > (@initialBatchSize * @MaxAllowedBatchSizeMultiplier) 
						SET @BatchSize = (@initialBatchSize * @MaxAllowedBatchSizeMultiplier);
				END;
			  END;
			ELSE BEGIN 
				IF @BatchSize > (@initialBatchSize / @MaxAllowedBatchSizeMultiplier) BEGIN

					SET @BatchSize = FLOOR((@BatchSize - (@BatchSize * .2)) / 100) * 100;
					IF @BatchSize < (@initialBatchSize / @MaxAllowedBatchSizeMultiplier)
						SET @BatchSize = (@initialBatchSize / @MaxAllowedBatchSizeMultiplier);
				END;
			END; 
			IF @BatchSize <> @currentRowsProcessed SET @currentRowsProcessed = @BatchSize; -- preserve looping capabilities (i.e., AFTER we''ve logged details). ';
	DECLARE @deadlocksAsErrors nvarchar(MAX) = N'IF ERROR_NUMBER() = 1205 BEGIN
		
				INSERT INTO [{logging_table_name}] (
					[timestamp],
					[is_error],
					[detail]
				)
				SELECT
					GETDATE() [timestamp], 
					1 [is_error], 
					( 
						SELECT 
							@currentRowsProcessed [progress.current_batch_count], 
							@totalRowsProcessed [progress.total_rows_processed],
							N''Deadlock Detected. Logging to history table - but not counting deadlock as normal error for purposes of error handling/termination.'' [errors.error]
						FOR JSON PATH, ROOT(''detail'')
					) [detail];
					   
				SET @deadlockOccurred = 1;		
			END; ';
	DECLARE @maxErrors nvarchar(MAX) = N'SET @currentErrorCount = @currentErrorCount + 1; 
			IF @currentErrorCount >= @MaxAllowedErrors BEGIN 
				INSERT INTO [{logging_table_name}] (
					[timestamp],
					[is_error],
					[detail]
				)
				SELECT
					GETDATE() [timestamp], 
					1 [is_error], 
					( 
						SELECT 
							@currentRowsProcessed [progress.current_batch_count], 
							@totalRowsProcessed [progress.total_rows_processed],
							CONCAT(N''Max allowed errors count reached/exceeded: '', @MaxAllowedErrors, N''. Terminating Execution.'') [errors.error]
						FOR JSON PATH, ROOT(''detail'')
					) [detail];

				GOTO Finalize;
			END;';


	IF @AllowMaxErrors = 1 BEGIN 
		SET @body = REPLACE(@body, N'{MaxErrors}', @maxErrors);
	  END; 
	ELSE BEGIN 
		SET @body = REPLACE(@body, N'{MaxErrors}', N'GOTO Finalize;');
	END;

	IF @AllowMaxExecutionSeconds = 1 BEGIN 
		SET @body = REPLACE(@body, N'{MaxSeconds}', @crlf + @crlf + @tab + @tab + @maxSeconds);
	  END; 
	ELSE BEGIN 
		SET @body = REPLACE(@body, N'{MaxSeconds}', N'');
	END;
	
	IF @AllowStopOnTempTableExists = 1 BEGIN 
		SET @body = REPLACE(@body, N'{TerminateIfTempObject}',@crlf + @crlf + @tab + @tab + @tempdbTerminate);
	  END;
	ELSE BEGIN 
		SET @body = REPLACE(@body, N'{TerminateIfTempObject}', N'');
	END;

	IF @AllowDynamicBatchSizing = 1 BEGIN 
		SET @body = REPLACE(@body, N'{DynamicTuning}', @crlf + @crlf + @tab + @tab + @dynamicTuning);
	  END;
	ELSE BEGIN
		SET @body = REPLACE(@body, N'{DynamicTuning}', N'');
	END;

	IF @AllowDeadlocksAsErrors = 1 BEGIN 
		SET @body = REPLACE(@body, N'{TreatDeadlocksAsErrors}', @deadlocksAsErrors + @crlf + @crlf + @tab + @tab + @tab);
	  END;
	ELSE BEGIN
		SET @body = REPLACE(@body, N'{TreatDeadlocksAsErrors}', N'');
	END;

	--SET @body = REPLACE(@body, N'{Batch_Statement}', @tab + @tab + @tab + @BatchStatement);
	SET @body = REPLACE(@body, N'{logging_table_name}', @LoggingTableName);


	---------------------------------------------------------------------------------------------------
	-- Finalization:
	---------------------------------------------------------------------------------------------------
	DECLARE @finalize nvarchar(MAX) = N'	---------------------------------------------------------------------------------------------------------------
	-- Finalization/Reporting:
	---------------------------------------------------------------------------------------------------------------

	Finalize:

	{deadlock_report}IF @errorsOccured = 1 BEGIN 
		SET @PersistHistory = 1;
	END;

	IF @PersistHistory = 1 BEGIN 
		DECLARE @executionID uniqueidentifier = NEWID();

		IF EXISTS (SELECT NULL FROM sys.tables WHERE [name] = N''{History_Table_Name}'') BEGIN
			
			INSERT INTO [{History_Table_Name}] (
				[execution_id],
				[detail_id],
				[timestamp],
				[is_error],
				[detail]
			)
			SELECT 
				@executionID [execution_id],
				[detail_id],
				[timestamp],
				[is_error],
				[detail]
			FROM 
				[{logging_table_name}] 
			ORDER BY 
				[detail_id];

		  END;
		ELSE BEGIN 
			SELECT * FROM [{logging_table_name}] ORDER BY [detail_id];

			RAISERROR(N''Unable to persist processing history data into long-term storage. Storage Table not found/specified.'', 16, 1);
		END;

	END;

	RETURN 0;
GO';

	DECLARE @deadlockBlock nvarchar(MAX) = N'IF @deadlockOccurred = 1 BEGIN 
		PRINT N''NOTE: One or more deadlocks occurred.''; 
		SET @PersistHistory = 1;
	END;'

	IF @AllowDeadlocksAsErrors = 1 BEGIN 
		SET @finalize = REPLACE(@finalize, N'{deadlock_report}', @deadlockBlock + @crlf + @crlf + @tab);
	  END; 
	ELSE BEGIN 
		SET @finalize = REPLACE(@finalize, N'{deadlock_report}', N'');
	END;

	SET @finalize = REPLACE(@finalize, N'{logging_table_name}', @LoggingTableName);
	SET @finalize = REPLACE(@finalize, N'{History_Table_Name}', ISNULL(@ProcessingHistoryTableName, N''));

	---------------------------------------------------------------------------------------------------
	-- Projection/Print-Out:
	---------------------------------------------------------------------------------------------------

	EXEC admindb.dbo.[print_long_string] @signature;
	EXEC admindb.dbo.[print_long_string] @initialization;
	EXEC [admindb].dbo.[print_long_string] @body;
	EXEC [admindb].dbo.[print_long_string] @finalize;
	
	RETURN 0;

GO