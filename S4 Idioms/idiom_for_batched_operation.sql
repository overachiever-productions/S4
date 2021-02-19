/*

EXEC admindb.dbo.[idiom_for_batched_operation]
	@BatchSize = 2000,
	--@WaitFor = NULL,
	@MaxExecutionSeconds = 800,
	@AllowDynamicBatchSizing = 1,
	--@TargetBatchMilliseconds = 0,
	--@MaxAllowedErrors = 0,
	--@TreatDeadlocksAsErrors = NULL,
	--@PersistLoggingDetails = NULL,
	@StopIfTempTableExists = N'##stop_word';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.idiom_for_batched_operation','P') IS NOT NULL
	DROP PROC dbo.[idiom_for_batched_operation];
GO
 
CREATE PROC dbo.[idiom_for_batched_operation]
	@BatchSize							int, 
	@WaitFor							sysname				= N'00:00:01.500',
	@BatchStatement						nvarchar(MAX)		= NULL,
	@BatchModeStatementType				sysname				= N'DELETE',   -- { DELETE | MOVE | NONE } 
	@LoggingTableName					sysname				= N'{DEFAULT}',
	@MaxExecutionSeconds				int					= NULL, 
	@AllowDynamicBatchSizing			bit					= 1, 
	@MaxAllowedBatchSizeMultiplier		int					= 5,			-- i.e., if @BatchSize = 2000, and @AllowDynamicBatchSizing = 1, this means we can/could get to a batch-size (max) of 5 * 2K or 10K.
	@TargetBatchMilliseconds			int					= 4000, 
	@MaxAllowedErrors					int					= 1, 
	@TreatDeadlocksAsErrors				bit					= 0,
	@StopIfTempTableExists				sysname				= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @WaitFor = NULLIF(@WaitFor, N'');
	SET @StopIfTempTableExists = NULLIF(@StopIfTempTableExists, N'');
	SET @BatchStatement = NULLIF(@BatchStatement, N'');
	SET @LoggingTableName = NULLIF(@LoggingTableName, N'');
	SET @BatchModeStatementType = NULLIF(@BatchModeStatementType, N'');
	
	SET @LoggingTableName = ISNULL(@LoggingTableName, N'{DEFAULT}');
	SET @BatchModeStatementType = ISNULL(@BatchModeStatementType, N'DELETE');
	SET @AllowDynamicBatchSizing = ISNULL(@AllowDynamicBatchSizing, 1);
	SET @TargetBatchMilliseconds = ISNULL(@TargetBatchMilliseconds, 4000);
	SET @MaxAllowedBatchSizeMultiplier = ISNULL(@MaxAllowedBatchSizeMultiplier, 5);
	SET @MaxAllowedErrors = ISNULL(@MaxAllowedErrors, 1);
	SET @TreatDeadlocksAsErrors = ISNULL(@TreatDeadlocksAsErrors, 0);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	---------------------------------------------------------------------------------------------------
	-- Input processing/logic:
	---------------------------------------------------------------------------------------------------
	IF UPPER(@LoggingTableName) = N'{DEFAULT}' SET @LoggingTableName = N'#batched_operation_' + LEFT(CAST(NEWID() AS sysname), 8);

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
					[<id_column, sysname, NameOfPrimaryKeyOrClixID>]  -- this is the ID of the row to be deleted, e.g., TicketID, ActivityID, UserId, Cart_Session_ID, etc. 
				FROM 
					dbo.[<target_table, sysname, TableToDeleteFrom>] WITH(NOLOCK)  -- For NON-DIRTY reads, MOST systems/scenarios can use WITH(READCOMMITTED, ROWLOCK, READPAST) which SKIPS locked rows (idea is it gets them later).
				WHERE 
					[<timestamp_column, sysname, NameOfTimeStampColumn>] < DATEADD(DAY, 0 - @DaysWorthOfDataToKeep, GETUTCDATE()) -- name of the datetime column to use for deletes, e.g., timestamp, create_time, entry_time, last_updated, etc. Should have a solid IX defined.
				) x ON t.[<id_column, sysname, NameOfPrimaryKeyOrClixID>]= x.[<id_column, sysname, NameOfPrimaryKeyOrClixID>];';

		END;
	END;

	---------------------------------------------------------------------------------------------------
	-- Initialization:
	---------------------------------------------------------------------------------------------------
	DECLARE @initialization nvarchar(MAX) = N'---------------------------------------------------------------------------------------------------------------
-- Setup:
---------------------------------------------------------------------------------------------------------------
SET NOCOUNT ON; 

-- DROP TABLE IF EXISTS [{logging_table_name}];
CREATE TABLE [{logging_table_name}] (
	[detail_id] int IDENTITY(1,1) NOT NULL, 
	[timestamp] datetime NOT NULL DEFAULT GETDATE(), 
	[is_error] bit NOT NULL DEFAULT (0), 
	[detail] nvarchar(MAX) NOT NULL
); 

DECLARE @WaitForDelay sysname = N''{wait_for}''; 
DECLARE @BatchSize int = {batch_size};{Max_Allowed_Errors}{Dynamic_Batching_Params}

-- Processing (variables/etc.)
DECLARE @currentRowsProcessed int = @BatchSize; 
DECLARE @totalRowsProcessed int = 0;
DECLARE @errorDetails nvarchar(MAX);
DECLARE @errorsOccured bit = 0;
DECLARE @currentErrorCount int = 0;{deadlock_declaration}
DECLARE @startTime datetime = GETDATE();
DECLARE @batchStart datetime;{dynamic_batching_declarations}

';
	
	SET @initialization = REPLACE(@initialization, N'{logging_table_name}', @LoggingTableName);
	SET @initialization = REPLACE(@initialization, N'{wait_for}', @WaitFor);
	SET @initialization = REPLACE(@initialization, N'{batch_size}', @BatchSize);
	SET @initialization = REPLACE(@initialization, N'{Batch_Statement}', @BatchStatement);

	DECLARE @dynamicBatches nvarchar(MAX) = N'DECLARE @milliseconds int;
DECLARE @initialBatchSize int = @BatchSize;
	';

	IF @MaxAllowedErrors > 1 BEGIN 
		SET @initialization = REPLACE(@initialization, N'{Max_Allowed_Errors}', @crlf + N'DECLARE @MaxAllowedErrors int = ' + CAST(@MaxAllowedErrors AS sysname) + N';');
	  END;
	ELSE BEGIN
		SET @initialization = REPLACE(@initialization, N'{Max_Allowed_Errors}', N'');
	END;

	IF @TreatDeadlocksAsErrors = 1 BEGIN 
		SET @initialization = REPLACE(@initialization, N'{deadlock_declaration}', @crlf + N'DECLARE @deadlockOccurred bit = 0;');
	  END; 
	ELSE BEGIN 
		SET @initialization = REPLACE(@initialization, N'{deadlock_declaration}', N'');
	END;

	IF @AllowDynamicBatchSizing = 1 BEGIN 
		SET @initialization = REPLACE(@initialization, N'{Dynamic_Batching_Params}', @crlf + N'DECLARE @MaxAllowedBatchSizeMultiplier int = ' + CAST(@MaxAllowedBatchSizeMultiplier AS sysname) + N';' + @crlf + N'DECLARE @TargetBatchMilliseconds int = ' + CAST(@TargetBatchMilliseconds AS sysname) + N';');
		SET @initialization = REPLACE(@initialization, N'{dynamic_batching_declarations}', @crlf + @dynamicBatches);
	  END; 
	ELSE BEGIN 
		SET @initialization = REPLACE(@initialization, N'{Dynamic_Batching_Params}', N'');
		SET @initialization = REPLACE(@initialization, N'{dynamic_batching_declarations}', N'{}');
	END;

	---------------------------------------------------------------------------------------------------
	-- Body:
	---------------------------------------------------------------------------------------------------
	DECLARE @body nvarchar(MAX) = N'---------------------------------------------------------------------------------------------------------------
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

!!!!!!!! - NOTE: you may want to pay attention to ROWLOCKs on INSERTs/UPDATEs/DELETEs. You may ALSO want to BYPASS triggers via CONTEXT_INFO(), etc. for the operations listed above.
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
	
	DECLARE @maxSeconds nvarchar(MAX) = N'IF DATEDIFF(SECOND, @startTime, GETDATE()) >= {Max_Allowed_Execution_Seconds} BEGIN 
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
						CONCAT(N''Maximum execution seconds allowed for execution met/exceeded. Max Allowed Seconds: '', {Max_Allowed_Execution_Seconds}, N''.'') [errors.error]
					FOR JSON PATH, ROOT(''detail'')
				) [detail];
			
			SET @errorsOccured = 1;

			GOTO Finalize;		
		END;';
	DECLARE @tempdbTerminate nvarchar(MAX) = N'IF OBJECT_ID(N''tempdb..{tempdb_safe_stop_name}'') IS NOT NULL BEGIN 
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
						N''Graceful execution shutdown/bypass directive detected - object [{tempdb_safe_stop_name}] found in tempdb. Terminating Execution.'' [errors.error]
					FOR JSON PATH, ROOT(''detail'')
				) [detail];
			
			SET @errorsOccured = 1;

			GOTO Finalize;
		END;';
	DECLARE @dynamicTuning nvarchar(MAX) = N'-- Dynamic Tuning:
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

	IF @MaxAllowedErrors > 1 BEGIN 
		SET @body = REPLACE(@body, N'{MaxErrors}', @maxErrors);
	  END; 
	ELSE BEGIN 
		SET @body = REPLACE(@body, N'{MaxErrors}', N'GOTO Finalize;');
	END;

	IF @MaxExecutionSeconds > 0 BEGIN 
		SET @maxSeconds = REPLACE(@maxSeconds, N'{Max_Allowed_Execution_Seconds}', @MaxExecutionSeconds);
		SET @body = REPLACE(@body, N'{MaxSeconds}', @crlf + @crlf + @tab + @tab + @maxSeconds);

	  END; 
	ELSE BEGIN 
		SET @body = REPLACE(@body, N'{MaxSeconds}', N'');
	END;
	
	IF @StopIfTempTableExists IS NOT NULL BEGIN 
		SET @tempdbTerminate = REPLACE(@tempdbTerminate, N'{tempdb_safe_stop_name}', @StopIfTempTableExists);
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

	IF @TreatDeadlocksAsErrors = 1 BEGIN 
		SET @body = REPLACE(@body, N'{TreatDeadlocksAsErrors}', @deadlocksAsErrors + @crlf + @crlf + @tab + @tab);
	  END;
	ELSE BEGIN
		SET @body = REPLACE(@body, N'{TreatDeadlocksAsErrors}', N'');
	END;

	SET @body = REPLACE(@body, N'{Batch_Statement}', @tab + @tab + @tab + @BatchStatement);
	SET @body = REPLACE(@body, N'{logging_table_name}', @LoggingTableName);

	---------------------------------------------------------------------------------------------------
	-- Cleanup
	---------------------------------------------------------------------------------------------------
	DECLARE @cleanup nvarchar(MAX) = N'---------------------------------------------------------------------------------------------------------------
-- Cleanup/Reporting:
---------------------------------------------------------------------------------------------------------------

Finalize:

{deadlock_report}IF @errorsOccured = 1 BEGIN 
	SELECT * FROM [{logging_table_name}] WHERE [is_error] = 1;
END;

PRINT N''-- NOTE: To view Output from logging history, run: { SELECT * FROM [{logging_table_name}] ORDER BY [timestamp]; } '';
';

	DECLARE @deadlockBlock nvarchar(MAX) = N'IF @deadlockOccurred = 1 BEGIN 
	PRINT N''NOTE: One or more deadlocks occurred - and were logged to [{logging_table_name}] ''; 
END;'

	IF @TreatDeadlocksAsErrors = 1 BEGIN 
		SET @cleanup = REPLACE(@cleanup, N'{deadlock_report}', @deadlockBlock + @crlf + @crlf);
	  END; 
	ELSE BEGIN 
		SET @cleanup = REPLACE(@cleanup, N'{deadlock_report}', N'');
	END;

	SET @cleanup = REPLACE(@cleanup, N'{logging_table_name}', @LoggingTableName);

	---------------------------------------------------------------------------------------------------
	-- Output/Projection:
	---------------------------------------------------------------------------------------------------

	EXEC [admindb].dbo.[print_long_string] @initialization;
	EXEC [admindb].dbo.[print_long_string] @body;
	EXEC [admindb].dbo.[print_long_string] @cleanup;

	RETURN 0
GO