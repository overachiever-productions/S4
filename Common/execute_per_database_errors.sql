/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.execute_per_database_errors',N'IF') IS NOT NULL
	DROP FUNCTION dbo.[execute_per_database_errors];
GO

CREATE FUNCTION dbo.[execute_per_database_errors] (@errors xml)
RETURNS table
	AS RETURN
    
	-- {copyright}

    WITH core AS (
		SELECT 
			[data].[row].value(N'@id[1]', N'int') [error_id],
			[data].[row].value(N'(database_name)[1]', N'sysname') [database_name], 
			[data].[row].value(N'(error_message)[1]', N'nvarchar(max)') [error_message], 
			[data].[row].value(N'(statement)[1]', N'nvarchar(max)') [statement] 
		FROM 
			@errors.nodes(N'//error') [data]([row])
	) 

	SELECT 
		[core].[error_id],
		[core].[database_name],
		[core].[error_message],
		[core].[statement] 
	FROM 
		core;
GO