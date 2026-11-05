/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[leaked_connections]','P') IS NOT NULL
	DROP PROC dbo.[leaked_connections];
GO

CREATE PROC dbo.[leaked_connections]






	-- @seconds_something_something (i.e., for [s].[last_request_end_time] ... and ... yeah, use seconds vs minutes ... and ... default to 300 or whatever
	-- @mode = { summary | detail } ... detail will show ... (grouped) results by ... code / statement (i.e., run DBCC INPUTBUFFER against results and then group by statements in addition to 
	--			the other details we're grouping against. 
	-- @aggregations_thingies - i.e., my kill_leaked_connections has some fun options for grouping ON x, y, z or JUST x, or just z, or just z, x, etc. 
	--	leverage that here. 

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SELECT
		COUNT([s].[session_id]) [connections],
		DB_NAME([s].[database_id]) [database], 
		[s].[program_name],
		[s].[login_name], 
		[s].[host_name], 
		[c].[client_net_address]
	FROM
		[sys].[dm_exec_sessions] [s]
		INNER JOIN [sys].[dm_exec_connections] [c] ON [s].[session_id] = [c].[session_id]
	WHERE
		[s].[is_user_process] = 1 
		AND [s].[status] != N'running'
		AND [s].[last_request_end_time] < DATEADD(MINUTE, -5, GETDATE())
	GROUP BY
		DB_NAME([s].[database_id]), 
		[s].[program_name],
		[s].[login_name], 
		[s].[host_name], 
		[c].[client_net_address]
	HAVING
		COUNT([s].[session_id]) > 2
	ORDER BY
		COUNT([s].[session_id]) DESC;	
