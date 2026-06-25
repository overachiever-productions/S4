/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.log_events_data','IF') IS NOT NULL
	DROP FUNCTION dbo.[log_events_data];
GO

CREATE FUNCTION dbo.[log_events_data] (@events xml)
RETURNS table
	AS RETURN 

	-- {copyright}

	WITH core AS ( 
		SELECT 
			[data].[row].value(N'@log[1]', N'int') [log_file_number], 
			[data].[row].value(N'@date[1]', N'datetime') [log_date], 
			[data].[row].value(N'@process[1]', N'sysname') [process_info], 
			[data].[row].value(N'(.)[1]', N'varchar(2048)') [text]
		FROM 
			@events.nodes(N'//event') [data]([row])
	) 

	SELECT 
		[log_file_number],
		[log_date],
		[process_info],
		[text]		
	FROM 
		core; 
GO