/*

	vNEXT:
		- There's an ugly overload in this code currently - if @DefaultWaitDuration = N'N/A'
			then 2 things (yup, there's the overload) will happen: 
				a. we won't, obvious, execute a WAIT FOR DELAY (that's logical). 
				b. BAD: we'll also / instead: SET @continue = 0; 
						That was a bit of a hack... 
						but, ultimately, i need to define 'looping' as an OPTION or not... and then have that be a distinct directive - out/apart from wait for delay.


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
				@AllowConfigTableOverride = 1, 
				@ConfigurationTableName = N'dbo.DeleteConfigurations',
				@AllowDynamicBatchSizing = 1,
				@AllowMaxErrors = 1,
				@AllowDeadlocksAsErrors = 1,
				@AllowMaxExecutionSeconds = 1,
				@AllowStopOnTempTableExists = 1, 
				@LoggingHistoryTableName = N'cleanup_history';




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.blueprint_for_batched_operation','P') IS NOT NULL
	DROP PROC dbo.[blueprint_for_batched_operation];
GO

CREATE PROC dbo.[blueprint_for_batched_operation]
	@DefaultNumberOfDaysToKeep						int, 
	@DefaultBatchSize								int, 
	@DefaultWaitDuration							sysname			= N'00:00:01.55',

	@TargetDatabase									sysname			= N'<db_name_here>',
	@GeneratedSprocSchema							sysname			= N'dbo',
	@GeneratedSprocName								sysname			= N'<sproc_name_here>', 

	@PreProcessingStatement							nvarchar(MAX)	= NULL,
	@BatchStatement									nvarchar(MAX)	= NULL,		
	@BatchModeStatementType							sysname			= N'DELETE',   -- { DELETE | MOVE | NONE } 

	@AllowConfigTableOverride						bit				= 1,				-- if present, then config is possible.
	@ConfigurationTableName							sysname			= NULL, 

	@AllowDynamicBatchSizing						bit				= 1, 
	@AllowMaxErrors									bit				= 1, 
	@AllowDeadlocksAsErrors							bit				= 1, 
	@AllowMaxExecutionSeconds						bit				= 1, 
	@AllowStopOnTempTableExists						bit				= 1, 
	@LoggingHistoryTableName						sysname, 
	@DefaultHistoryLoggingLevel						sysname			= N'SIMPLE'		-- { SIMPLE | DETAIL }  -- errors are always included... 
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	------------------------------------------------------------------------------------------------------------------------------
	-- Validate Inputs:
	-- i.e., input params for THIS blueprint sproc... 

	SET @TargetDatabase = ISNULL(NULLIF(@TargetDatabase, N''), N'<db_name_here>');
	SET @GeneratedSprocName = ISNULL(NULLIF(@GeneratedSprocName, N''), N'<sproc_name_here>');
	SET @DefaultWaitDuration = ISNULL(NULLIF(@DefaultWaitDuration, N''), N'00:00:01.500');
	SET @BatchModeStatementType = ISNULL(NULLIF(@BatchModeStatementType, N''), N'DELETE');
	SET @DefaultHistoryLoggingLevel = ISNULL(NULLIF(@DefaultHistoryLoggingLevel, N''), N'SIMPLE');

	SET @ConfigurationTableName = NULLIF(@ConfigurationTableName, N'');
	SET @LoggingHistoryTableName = NULLIF(@LoggingHistoryTableName, N'');
	SET @BatchStatement = NULLIF(@BatchStatement, N'');
	SET @PreProcessingStatement = NULLIF(@PreProcessingStatement, N'');
	   
	--IF (@DefaultBatchSize IS NULL OR @DefaultBatchSize < 0) OR (@DefaultNumberOfDaysToKeep IS NULL OR @DefaultNumberOfDaysToKeep < 0) BEGIN 
	--	RAISERROR('@DefaultBatchSize and @DefaultNumberOfDaysToKeep must both be set to non-NULL values > 0 - even when @UseConfig = 1.', 16, 1);
	--	RETURN -6;
	--END;

	IF @AllowConfigTableOverride = 1 BEGIN 
		IF @ConfigurationTableName IS NULL BEGIN
			RAISERROR(N'A configuration table must be supplied via the @ConfigurationTableName parameter when @AllowConfigTableOverride is set to 1.', 16, 1);
			RETURN -10;
		END;
	END;

	------------------------------------------------------------------------------------------------------------------------------
	-- Header/Signature:
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @loggingTableName sysname = N'#batched_operation_' + LEFT(CAST(NEWID() AS sysname), 8);

	---------------------------------------------------------------------------------------------------
	-- Batch Statement Defaults/Templates:
	---------------------------------------------------------------------------------------------------
	IF @BatchStatement IS NULL BEGIN 
		IF UPPER(@BatchModeStatementType) = N'NONE' BEGIN

			SET @BatchStatement = N'Specify your batched T-SQL operation here. Note, you''ll want to try to use PKs/CLIXes and avoid NON-SARGable operations as much as possible.';
		END;

		IF UPPER(@BatchModeStatementType) = N'MOVE' BEGIN 
			SET @BatchStatement = N'			-- NOTE: you''ll have to create this table up BEFORE the WHILE @currentRowsProcessed = @BatchSize BEGIN loop starts... 
			--  it holds details on the rows REMOVED from the old table and to be SHOVED into the new table ... 
			--CREATE TABLE #MigrationTable (
			--	migration_row_id int IDENTITY(1,1) NOT NULL, 
				
			--	-- now, ''duplicate'' the schema of the table/rows you''ll be moving - i.e., column-names, data-types, and NULL/NON-NULL (you can ignore constraints).

			--	[column_1_to_copy] datatype_here [NOT NULL, 
			--	[column_2_to_copy] datatype_here NOT NULL, 
			--	-- etc.
			--	[column_N_to_copy] datatype_here NOT NULL
			--);


			TRUNCATE TABLE #MigrationTable;
			UPDATE [x] WITH(ROWLOCK)
			SET
				[x].[CopiedToNewTable] = 1  -- i.e., some sort of column to ''mark'' rows as transactionally moved. ALTER <myTable> ADD CopiedToNewTable bit NULL; -- if you make this NON-NULL, it''ll be a size of data operation.
			OUTPUT
				[Deleted].[column_1_to_copy],
				[Deleted].[column_2_to_copy],
				[Deleted].[column_3_to_copy],
				[Deleted].[column_4_to_copy],
				-- etc... 
				[Deleted].[column_N_to_copy]
			INTO #MigrationTable
			FROM 
				( 
					SELECT TOP (@BatchSize) * FROM [<table_to_move_rows_from, sysname, MySourceTable>] WHERE ([CopiedToNewTable] IS NULL OR [CopiedToNewTable] = 0) ORDER BY [<optional_orderby_column, sysname, CanBeRemoved>]
				) [x];

			--SELECT * FROM #MigrationTable

			INSERT INTO [<table_to_move_rows_TO, sysname, MyTargetTable>] WITH(ROWLOCK) (
				[column_1_to_copy],
				[column_2_to_copy],
				[column_3_to_copy],
				[column_4_to_copy],
				-- etc
				[column_N_to_copy]
			)
			SELECT
				[column_1_to_copy],
				[column_2_to_copy],
				[column_3_to_copy],
				[column_4_to_copy], 
				-- etc
				[column_N_to_copy]
			FROM
				 #MigrationTable;

				 -- USUALLY makes sense to let the engine figure out the best way to sort/order-by
			-- Later - i.e., once all rows are moved or ... whenever you want, you can DELETE FROM <your_source_table> WHERE [CopiedToNewTable] = 1'
		END;

		IF UPPER(@BatchModeStatementType) = N'DELETE' BEGIN 
			SET @BatchStatement = N'			
				DELETE [t]
				FROM dbo.[<target_table, sysname, TableToDeleteFrom>] t WITH(ROWLOCK)
				INNER JOIN (
					SELECT TOP (@BatchSize) 
						[<id_column, sysname, NameOfPrimaryKeyOrClixID>]  
					FROM 
						dbo.[<target_table, sysname, TableToDeleteFrom>] WITH(NOLOCK)  
					WHERE 
						[<timestamp_column, sysname, NameOfTimeStampColumn>] < DATEADD(DAY, 0 - @DaysWorthOfDataToKeep, @startTime) 
					) x ON t.[<id_column, sysname, NameOfPrimaryKeyOrClixID>]= x.[<id_column, sysname, NameOfPrimaryKeyOrClixID>];';
		END;

		SET @BatchStatement = N'!!!!!!!!-- Specify YOUR code here, i.e., this is just a TEMPLATE:
				' + @BatchStatement + N' 
!!!!!!!! / YOUR code... ';

	END;

	---------------------------------------------------------------------------------------------------
	-- Sproc Signature and Configuration Settings:
	---------------------------------------------------------------------------------------------------

	DECLARE @signature nvarchar(MAX) = N'USE [{target_database}];
GO

IF OBJECT_ID(''[{schema}].[{sproc_name}]'',''P'') IS NOT NULL
	DROP PROC [{schema}].[{sproc_name}];
GO

CREATE PROC [{schema}].[{sproc_name}]
{parameters}
AS
    SET NOCOUNT ON; 

	-- NOTE: this code was generated from admindb.dbo.blueprint_for_batched_operation.
	
	-- Parameter Scrubbing/Cleanup:
	{cleanup}{configuration}
	';

	DECLARE @parameters nvarchar(MAX) = N'	@DaysWorthOfDataToKeep					int			= {default_retention},
	@BatchSize								int			= {default_batch_size},
	@WaitForDelay							sysname		= N''{default_wait_for}'',{configuration}{allow_batch_tuning}{total_cleanup_seconds}{default_max_errors}{deadlocks_as_errors}{safe_stop_name}
	@HistoryLoggingLevel					sysname		= N''{default_save_history}''   -- { SIMPLE | DETAIL }  -- errors are always logged...  ';

	DECLARE @cleanup nvarchar(MAX) = N'SET @WaitForDelay = NULLIF(@WaitForDelay, N'''');{tempTableName}';
	DECLARE @configuration nvarchar(MAX) = @crlf + @crlf + @tab + N'---------------------------------------------------------------------------------------------------------------
	-- Optional Retrieval of Settings via Configuration Table:
	---------------------------------------------------------------------------------------------------------------
	IF @OverrideWithConfigParameters = 1 BEGIN 
		
		DECLARE @enabled bit;
		DECLARE @configurationKey sysname = OBJECT_NAME(@@PROCID);--{dynamic_batching_params2}{max_errors2}

		BEGIN TRY 
			-- Reset/Load Input Values from Config Table INSTEAD of via parameters passed in to sproc: 
			DECLARE @configError nvarchar(MAX) = N'''';
			DECLARE @configSQL nvarchar(MAX) = N''SELECT 
				@enabled = [enabled],
				@DaysWorthOfDataToKeep = [retention_days],
				@BatchSize = [batch_size],
				@WaitForDelay = [wait_for_delay],{max_exections_select}{deadlocks_select}{max_errors_select}{dynamic_batching_select}{temp_select}
				@HistoryLoggingLevel = [logging_level]		
			FROM 
				{configuration_table_name}
			WHERE	
				[procedure_name] = @configurationKey; '';

			EXEC sp_executesql 
				@configSQL, 
				N''@enabled bit OUTPUT, 
				@DaysWorthOfDataToKeep int OUTPUT, 
				@BatchSize int OUTPUT,
				@WaitForDelay sysname OUTPUT,{dynamic_batching_def}{max_exections_def}{deadlocks_def}{max_errors_def}{temp_def}
				@HistoryLoggingLevel sysname OUTPUT, 
				@configurationKey sysname'',
				@enabled = @enabled OUTPUT,
				@DaysWorthOfDataToKeep = @DaysWorthOfDataToKeep OUTPUT,
				@BatchSize = @BatchSize OUTPUT,
				@WaitForDelay = @WaitForDelay OUTPUT,{dynamic_batching_assignment}{max_exections_assignment}{deadlocks_assignment}{max_errors_assignment}{temp_assignment}
				@HistoryLoggingLevel = @HistoryLoggingLevel OUTPUT,
				@configurationKey = @configurationKey;

			IF @BatchSize IS NULL BEGIN
				RAISERROR(''Invalid Configuration Definiition Specified. Key: %s did NOT match any configured [procedure_name] in table: {configuration_table_name}. Unable to continue. Terminating.'', 16, 1, @configurationKey);
			END;

			IF @enabled <> 1 BEGIN 
				PRINT N''Procedure '' + @configurationKey + N'' has been marked as DISABLED in table {configuration_table_name}. Execution is terminating gracefully.;'';
				RETURN 0;
			END;

		END TRY 
		BEGIN CATCH 
			SELECT @configError = N''ERROR NUMBER: '' + CAST(ERROR_NUMBER() as sysname) + N''. ERROR MESSAGE: '' + ERROR_MESSAGE();
			RAISERROR(@configError, 16, 1);
			RAISERROR(''Unexecpted Error Attempting retrieval of Configuration Values from Configuration Table {configuration_table_name}. Unable to continue. Terminating.'', 16, 1);
			RETURN -100;
		END CATCH

	END; ';

	SET @parameters = REPLACE(@parameters, N'{default_retention}', @DefaultNumberOfDaysToKeep);
	SET @parameters = REPLACE(@parameters, N'{default_batch_size}', @DefaultBatchSize);
	SET @parameters = REPLACE(@parameters, N'{default_wait_for}', @DefaultWaitDuration);
	SET @parameters = REPLACE(@parameters, N'{default_save_history}', @DefaultHistoryLoggingLevel);	

	IF @AllowConfigTableOverride = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{configuration}', @crlf + @tab + N'@OverrideWithConfigParameters			bit			= 0, ');	

		SET @configuration = REPLACE(@configuration, N'{configuration_table_name}', @ConfigurationTableName);

		IF @AllowDynamicBatchSizing = 1 BEGIN
			SET @configuration = REPLACE(@configuration, N'{dynamic_batching_params}', @crlf + @tab + @tab + N'DECLARE @AllowDynamicBatchSizing bit;
		DECLARE @MaxAllowedBatchSizeMultiplier int;
		DECLARE @TargetBatchMilliseconds int;');
		  END; 
		ELSE BEGIN 
			SET @configuration = REPLACE(@configuration, N'{dynamic_batching_params}', N'');
		END;
	  END;
	ELSE BEGIN
		SET @parameters = REPLACE(@parameters, N'{configuration}', N'');	
		SET @cleanup = REPLACE(@cleanup, N'{configKeys}', N'');
		SET @configuration = N'';
	END;

	IF @AllowDynamicBatchSizing = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{allow_batch_tuning}', @crlf + @tab + N'@AllowDynamicBatchSizing				bit			= 0,' + @crlf + @tab + '@MaxAllowedBatchSizeMultiplier			int			= 5, ' + @crlf + @tab + N'@TargetBatchMilliseconds				int			= 2800,');	
		SET @configuration = REPLACE(@configuration, N'{dynamic_batching_select}', @crlf + @tab + @tab + @tab + @tab + N'@AllowDynamicBatchSizing = [enable_dynamic_batch_sizing],
				@MaxAllowedBatchSizeMultiplier = [max_batch_size_multiplier],
				@TargetBatchMilliseconds = [target_batch_milliseconds],');
		SET @configuration = REPLACE(@configuration, N'{dynamic_batching_def}', @crlf + @tab + @tab + @tab + @tab + N'@AllowDynamicBatchSizing bit OUTPUT,
				@MaxAllowedBatchSizeMultiplier int OUTPUT, 
				@TargetBatchMilliseconds int OUTPUT,');

		SET @configuration = REPLACE(@configuration, N'{dynamic_batching_assignment}', @crlf + @tab + @tab + @tab + @tab + N'@AllowDynamicBatchSizing = @AllowDynamicBatchSizing OUTPUT,
				@MaxAllowedBatchSizeMultiplier = @MaxAllowedBatchSizeMultiplier OUTPUT,
				@TargetBatchMilliseconds = @TargetBatchMilliseconds OUTPUT,');
	  END;
	ELSE BEGIN 
		SET @parameters = REPLACE(@parameters, N'{allow_batch_tuning}', N'');	
		SET @configuration = REPLACE(@configuration, N'{dynamic_batching_select}', N'');
		SET @configuration = REPLACE(@configuration, N'{dynamic_batching_def}', N'');
		SET @configuration = REPLACE(@configuration, N'{dynamic_batching_assignment}', N'');
	END;

	IF @AllowMaxExecutionSeconds = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{total_cleanup_seconds}', @crlf + @tab + N'@MaxExecutionSeconds					int			= NULL,');
		SET @configuration = REPLACE(@configuration, N'{max_exections_select}', @crlf + N'				@MaxExecutionSeconds = [max_execution_seconds],');
		SET @configuration = REPLACE(@configuration, N'{max_exections_def}', @crlf + N'				@MaxExecutionSeconds int OUTPUT,');
		SET @configuration = REPLACE(@configuration, N'{max_exections_assignment}', @crlf + N'				@MaxExecutionSeconds = @MaxExecutionSeconds OUTPUT,');
	  END;
	ELSE BEGIN
		SET @parameters = REPLACE(@parameters, N'{total_cleanup_seconds}', N'');	
		SET @configuration = REPLACE(@configuration, N'{max_exections_select}', N'');
		SET @configuration = REPLACE(@configuration, N'{max_exections_def}', N'');
		SET @configuration = REPLACE(@configuration, N'{max_exections_assignment}', N'');
	END;

	IF @AllowMaxErrors = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{default_max_errors}', @crlf + @tab + N'@MaxAllowedErrors						int			= 1,');
		SET @configuration = REPLACE(@configuration, N'{max_errors}', @crlf + @tab + @tab + N'DECLARE @MaxAllowedErrors int;');
		SET @configuration = REPLACE(@configuration, N'{max_errors_select}', @crlf + N'				@MaxAllowedErrors = [max_allowed_errors],');
		SET @configuration = REPLACE(@configuration, N'{max_errors_def}', @crlf + N'				@MaxAllowedErrors int OUTPUT,');
		SET @configuration = REPLACE(@configuration, N'{max_errors_assignment}', @crlf + N'				@MaxAllowedErrors = @MaxAllowedErrors OUTPUT,');
	  END;
	ELSE BEGIN 
		SET @parameters = REPLACE(@parameters, N'{default_max_errors}', N'');
		SET @configuration = REPLACE(@configuration, N'{max_errors}', N'');
		SET @configuration = REPLACE(@configuration, N'{max_errors_select}', N'');
		SET @configuration = REPLACE(@configuration, N'{max_errors_def}', N'');
		SET @configuration = REPLACE(@configuration, N'{max_errors_assignment}', N'');
	END;

	IF @AllowDeadlocksAsErrors = 1 BEGIN
		SET @parameters = REPLACE(@parameters, N'{deadlocks_as_errors}',  @crlf + @tab + N'@TreatDeadlocksAsErrors					bit			= 0,');
		SET @configuration = REPLACE(@configuration, N'{deadlocks_select}', @crlf + N'				@TreatDeadlocksAsErrors = [treat_deadlocks_as_errors],');
		SET @configuration = REPLACE(@configuration, N'{deadlocks_def}', @crlf + N'				@TreatDeadlocksAsErrors bit OUTPUT,');
		SET @configuration = REPLACE(@configuration, N'{deadlocks_assignment}', @crlf + N'				@TreatDeadlocksAsErrors = @TreatDeadlocksAsErrors OUTPUT,');
	  END;
	ELSE BEGIN
		SET @parameters = REPLACE(@parameters, N'{deadlocks_as_errors}', N'');
		SET @configuration = REPLACE(@configuration, N'{deadlocks_select}', N'');
		SET @configuration = REPLACE(@configuration, N'{deadlocks_def}', N'');
		SET @configuration = REPLACE(@configuration, N'{deadlocks_assignment}', N'');
	END;

	IF @AllowStopOnTempTableExists  = 1 BEGIN 
		SET @parameters = REPLACE(@parameters, N'{safe_stop_name}', @crlf + @tab + N'@StopIfTempTableExists					sysname		= NULL,');
		SET @cleanup = REPLACE(@cleanup, N'{tempTableName}', @crlf + @tab + N'SET @StopIfTempTableExists = ISNULL(@StopIfTempTableExists, N'''');');
		SET @configuration = REPLACE(@configuration, N'{temp_select}', @crlf + N'				@StopIfTempTableExists = [stop_if_tempdb_table_exists],');
		SET @configuration = REPLACE(@configuration, N'{temp_def}', @crlf + N'				@StopIfTempTableExists sysname OUTPUT,');
		SET @configuration = REPLACE(@configuration, N'{temp_assignment}', @crlf + N'				@StopIfTempTableExists = @StopIfTempTableExists OUTPUT,');
	  END;
	ELSE BEGIN
		SET @parameters = REPLACE(@parameters, N'{safe_stop_name}', N'');
		SET @cleanup = REPLACE(@cleanup, N'{tempTableName}', N'');

		SET @configuration = REPLACE(@configuration, N'{temp_select}', N'');
		SET @configuration = REPLACE(@configuration, N'{temp_def}', N'');
		SET @configuration = REPLACE(@configuration, N'{temp_assignment}', N'');
	END;
	
	SET @signature = REPLACE(@signature, N'{target_database}', @TargetDatabase);
	SET @signature = REPLACE(@signature, N'{schema}', @GeneratedSprocSchema);
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

	-- Processing Declarations:
	DECLARE @continue bit = 1;
	DECLARE @currentRowsProcessed int = @BatchSize; 
	DECLARE @totalRowsProcessed int = 0;
	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @currentErrorCount int = 0;{deadlock_declaration}
	DECLARE @startTime datetime = GETDATE();
	DECLARE @batchStart datetime;{dynamic_batching_declarations}{preProcessingDirectives}
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
		SET @initialization = REPLACE(@initialization, N'{dynamic_batching_declarations}', N'');
	END;

	IF @PreProcessingStatement IS NOT NULL BEGIN 
		SET @initialization = REPLACE(@initialization, N'{preProcessingDirectives}', @crlf + @tab + @PreProcessingStatement + @crlf);
	  END;
	ELSE BEGIN 
		SET @initialization = REPLACE(@initialization, N'{preProcessingDirectives}', N'');
	END;

	---------------------------------------------------------------------------------------------------
	-- Body/Processing:
	---------------------------------------------------------------------------------------------------
	DECLARE @body nvarchar(MAX) = N'	---------------------------------------------------------------------------------------------------------------
	-- Processing:
	---------------------------------------------------------------------------------------------------------------
	WHILE @continue = 1 BEGIN 
	
		SET @batchStart = GETDATE();
	
		BEGIN TRY
			BEGIN TRAN; 
				
				-------------------------------------------------------------------------------------------------
				-- batched operation code:
				-------------------------------------------------------------------------------------------------
				{Batch_Statement} 

				-------------------------------------------
				SELECT 
					@currentRowsProcessed = @@ROWCOUNT, 
					@totalRowsProcessed = @totalRowsProcessed + @@ROWCOUNT;

			COMMIT; 

			IF @currentRowsProcessed <> @BatchSize SET @continue = 0;

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
			
			{delay}
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
					   
			{MaxErrors}
		END CATCH;
	END;

	';

	DECLARE @maxSeconds nvarchar(MAX) = N'	IF @MaxExecutionSeconds > 0 AND (DATEDIFF(SECOND, @startTime, GETDATE()) >= @MaxExecutionSeconds) BEGIN 
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
			END; ';
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

	IF @DefaultWaitDuration = N'N/A' BEGIN
		SET @body = REPLACE(@body, N'{delay}', N'SET @continue = 0; -- no waiting/looping...');
	  END;
	ELSE BEGIN 
		SET @body = REPLACE(@body, N'{delay}', N'WAITFOR DELAY @WaitForDelay;');
	END;


	SET @body = REPLACE(@body, N'{Batch_Statement}', @BatchStatement);
	SET @body = REPLACE(@body, N'{logging_table_name}', @LoggingTableName);
	

	---------------------------------------------------------------------------------------------------
	-- Finalization:
	---------------------------------------------------------------------------------------------------
	DECLARE @finalize nvarchar(MAX) = N'	---------------------------------------------------------------------------------------------------------------
	-- Finalization/Reporting:
	---------------------------------------------------------------------------------------------------------------

	Finalize:{deadlock_report}

	DECLARE @executionID uniqueidentifier = NEWID();

	IF EXISTS (SELECT NULL FROM sys.tables WHERE [object_id] = OBJECT_ID(N''{History_Table_Name}'')) BEGIN
			
		IF @HistoryLoggingLevel = N''SIMPLE'' BEGIN 
			DELETE FROM {logging_table_name} WHERE is_error = 0 AND [detail_id] <> (SELECT MAX([detail_id]) FROM {logging_table_name});
		END;

		INSERT INTO {History_Table_Name} (
			[execution_id],
			[procedure_name],
			[detail_id],
			[timestamp],
			[is_error],
			[detail]
		)
		SELECT 
			@executionID [execution_id],
			OBJECT_NAME(@@PROCID) [procedure_name],
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

	RETURN 0;
GO';

	DECLARE @deadlockBlock nvarchar(MAX) = N'IF @deadlockOccurred = 1 BEGIN 
		PRINT N''NOTE: One or more deadlocks occurred.''; 
	END;'

	IF @AllowDeadlocksAsErrors = 1 BEGIN 
		SET @finalize = REPLACE(@finalize, N'{deadlock_report}', @crlf + @crlf + @tab + @deadlockBlock);
	  END; 
	ELSE BEGIN 
		SET @finalize = REPLACE(@finalize, N'{deadlock_report}', N'');
	END;

	IF PARSENAME(@LoggingHistoryTableName, 2) IS NULL SET @LoggingHistoryTableName = N'dbo.' + @LoggingHistoryTableName;
	
	SET @finalize = REPLACE(@finalize, N'{logging_table_name}', @LoggingTableName);
	SET @finalize = REPLACE(@finalize, N'{History_Table_Name}', ISNULL(QUOTENAME(PARSENAME(@LoggingHistoryTableName, 2)) + N'.' + QUOTENAME(PARSENAME(@LoggingHistoryTableName, 1)), N''));

	---------------------------------------------------------------------------------------------------
	-- Projection/Print-Out:
	---------------------------------------------------------------------------------------------------

	EXEC admindb.dbo.[print_long_string] @signature;
	EXEC admindb.dbo.[print_long_string] @initialization;
	EXEC [admindb].dbo.[print_long_string] @body;
	EXEC [admindb].dbo.[print_long_string] @finalize;
	
	RETURN 0;

GO