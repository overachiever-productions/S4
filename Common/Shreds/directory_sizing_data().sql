/*



*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.directory_sizing_data', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[directory_sizing_data];
GO

CREATE FUNCTION dbo.[directory_sizing_data] (@directories xml)
RETURNS table
    AS RETURN 
    
	-- {copyright}
  
	WITH core AS ( 
		SELECT 
			[data].[row].value(N'@name[1]', N'sysname') [directory],
			[data].[row].value(N'@file_count[1]', N'int') [file_count],
			[data].[row].value(N'@total_mb[1]', N'decimal(22,2)') [total_mb],
			[data].[row].value(N'@largest_mb[1]', N'decimal(22,2)') [largest_mb],
			[data].[row].value(N'@avg_mb[1]', N'decimal(22,2)') [avg_mb]
		FROM 
			@directories.nodes(N'//directory') [data]([row])

	) 

	SELECT 
		[core].[directory],
		[core].[file_count],
		[core].[total_mb],
		[core].[largest_mb],
		[core].[avg_mb]
	FROM 
		core;
GO