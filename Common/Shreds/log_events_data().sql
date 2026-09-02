/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.log_events_data', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[log_events_data];
GO

CREATE FUNCTION dbo.[log_events_data] (@events xml)
RETURNS table
	AS RETURN 

	-- {copyright}

	WITH core AS ( 
		SELECT
			[data].[row].value(N'@row_id[1]', N'int') [row_id], 
			[data].[row].value(N'@log[1]', N'int') [log_file_number], 
			[data].[row].value(N'@date[1]', N'datetime') [log_date], 
			[data].[row].value(N'@process[1]', N'sysname') [process_info], 
			[data].[row].value(N'(.)[1]', N'varchar(2048)') [text]
		FROM 
			@events.nodes(N'//event') [data]([row])
	) 

	SELECT 
		[row_id],
		[log_file_number],
		[log_date],
		[process_info],
		[text]		
	FROM 
		core; 
GO