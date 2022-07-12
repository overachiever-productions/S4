/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.log_backup_history_detail','P') IS NOT NULL
	DROP PROC dbo.[log_backup_history_detail];
GO

CREATE PROC dbo.[log_backup_history_detail]
	@LogSuccessfulOutcomes			bit							= 1, 
	@ExecutionDetails				dbo.backup_history_entry	READONLY, 
	@BackupHistoryId				int							OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF (SELECT COUNT(*) FROM @ExecutionDetails) <> 1 BEGIN 
		RAISERROR(N'Invalid Configuration. @ExecutionDetails can only, ever, contain a single row at a time.', 16, 1);
	END;

	DECLARE @isError bit = 0; 
	IF EXISTS (SELECT NULL FROM @ExecutionDetails WHERE [error_details] IS NOT NULL) 
		SET @isError = 1;

	IF @isError = 0 AND @LogSuccessfulOutcomes = 0
		RETURN 0;

	IF @BackupHistoryId IS NULL BEGIN 
		INSERT INTO dbo.[backup_log] (
			[execution_id],
			[backup_date],
			[database],
			[backup_type],
			[backup_path],
			[copy_path],
			[offsite_path],
			[backup_start],
			[backup_end],
			[backup_succeeded],
			[verification_start],
			[verification_end],
			[verification_succeeded],
			[copy_succeeded],
			[copy_seconds],
			[failed_copy_attempts],
			[copy_details],
			[offsite_succeeded],
			[offsite_seconds],
			[failed_offsite_attempts],
			[offsite_details],
			[error_details]
		)
		SELECT 
			[execution_id],
			[backup_date],
			[database],
			[backup_type],
			[backup_path],
			[copy_path],
			[offsite_path],
			[backup_start],
			[backup_end],
			[backup_succeeded],
			[verification_start],
			[verification_end],
			[verification_succeeded],
			[copy_succeeded],
			[copy_seconds],
			[failed_copy_attempts],
			[copy_details],
			[offsite_succeeded],
			[offsite_seconds],
			[failed_offsite_attempts],
			[offsite_details],
			[error_details]
		FROM 
			@ExecutionDetails;

		SELECT @BackupHistoryId = SCOPE_IDENTITY();

		RETURN 0;
	END;

	UPDATE x 
	SET 
		x.[backup_date] = d.[backup_date],
		x.[database] = d.[database],
		x.[backup_type] = d.[backup_type],
		x.[backup_path] = d.[backup_path],
		x.[copy_path] = d.[copy_path],
		x.[offsite_path] = d.[offsite_path],
		x.[backup_start] = d.[backup_start],
		x.[backup_end] = d.[backup_end],
		x.[backup_succeeded] = d.[backup_succeeded],
		x.[verification_start] = d.[verification_start],
		x.[verification_end] = d.[verification_end],
		x.[verification_succeeded] = d.[verification_succeeded],
		x.[copy_succeeded] = d.[copy_succeeded],
		x.[copy_seconds] = d.[copy_seconds],
		x.[failed_copy_attempts] = d.[failed_copy_attempts],
		x.[copy_details] = d.[copy_details],
		x.[offsite_succeeded] = d.[offsite_succeeded],
		x.[offsite_seconds] = d.[offsite_seconds],
		x.[failed_offsite_attempts] = d.[failed_offsite_attempts],
		x.[offsite_details] = d.[offsite_details],
		x.[error_details] = d.[error_details]
	FROM
		dbo.backup_log x 
		INNER JOIN @ExecutionDetails d ON x.[backup_id] = @BackupHistoryId
	WHERE 
		x.backup_id = @BackupHistoryId; 

	RETURN 0;
GO		