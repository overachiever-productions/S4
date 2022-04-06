/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.clear_stale_jobsactivity','P') IS NOT NULL
	DROP PROC dbo.[clear_stale_jobsactivity];
GO

CREATE PROC dbo.[clear_stale_jobsactivity]
	@ThresholdVectorForStaleJobActivities		nvarchar(MAX)		= N'1 month',
	@MinimumSessionsToKeep						int					= 5
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @ThresholdVectorForStaleJobActivities = ISNULL(NULLIF(@ThresholdVectorForStaleJobActivities, N''), N'1 month');
	
	DECLARE @retentionCutoff datetime;
	DECLARE @retentionError nvarchar(MAX);

	EXEC dbo.[translate_vector_datetime]
		@Vector = @ThresholdVectorForStaleJobActivities, 
		@Operation = N'SUBTRACT', 
		@ValidationParameterName = N'@ThresholdVectorForStaleJobActivities', 
		@ProhibitedIntervals = N'BACKUP', 
		@Output = @retentionCutoff OUTPUT, 
		@Error = @retentionError OUTPUT;

	IF @retentionError IS NOT NULL BEGIN 
		RAISERROR(@retentionError, 16, 1);
		RETURN -2;
	END;

	IF @MinimumSessionsToKeep > 0 BEGIN 
		
		DECLARE @minimumDate datetime; 
		
		WITH lastN AS ( 
			SELECT TOP (@MinimumSessionsToKeep) agent_start_date 
			FROM msdb.dbo.[syssessions] 
			ORDER BY [agent_start_date] DESC
		) 
		SELECT @minimumDate = (
			SELECT TOP (1) agent_start_date FROM [lastN] ORDER BY [lastN].[agent_start_date]
		);

		IF @minimumDate	< @retentionCutoff
			SET @retentionCutoff = @minimumDate;

	END;

	DECLARE @sessionId int; 
	SELECT @sessionId = MAX([session_id]) FROM [msdb].dbo.[syssessions] WHERE [agent_start_date] <= @retentionCutoff;

	DELETE FROM [msdb].dbo.[sysjobactivity] WHERE [session_id] < @sessionId;

	RETURN 0;
GO