/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.job_histories', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[job_histories];
GO

CREATE FUNCTION dbo.job_histories()
RETURNS TABLE AS 
RETURN 
	WITH history AS (
		SELECT 
			[j].[name] [job_name], 
			[h].[step_id], 
			[h].[step_name], 
			msdb.dbo.[agent_datetime]([h].[run_date], [h].[run_time]) [run_time], 			
			DATEDIFF(SECOND, 0, STUFF(STUFF(RIGHT('000000' + CONVERT(VARCHAR(6), [h].[run_duration]), 6), 5, 0, ':') ,3 , 0, ':')) [run_seconds],
			[h].[run_status],
			[h].[sql_message_id],
			[h].[sql_severity],
			[h].[message]
		FROM 
			msdb.dbo.sysjobs [j] 
			INNER JOIN msdb.dbo.[sysjobhistory] [h] ON [j].[job_id] = [h].[job_id]
	), 
	facts AS ( 
		SELECT 
			[h].[job_name],
			[h].[step_id],
			[h].[step_name],
			[h].[run_time], 
			DATENAME(WEEKDAY, [h].[run_time]) [weekday],
			[h].[run_seconds], 
			[h].[run_status],
			[h].[sql_message_id],
			[h].[sql_severity],
			[h].[message]
		FROM 
			[history] h
	)

	SELECT 
		[job_name],
		[step_id],
		[step_name],
		[run_time],
		[weekday],
		[run_seconds],
		[run_status],
		[sql_message_id],
		[sql_severity],
		[message] 
	FROM 
		[facts];
GO