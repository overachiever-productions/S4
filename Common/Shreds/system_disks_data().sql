/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.system_disks_data', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[system_disks_data];
GO

CREATE FUNCTION dbo.[system_disks_data] (@disks xml)
RETURNS table
    AS RETURN 
    
	-- {copyright}
  
	WITH core AS ( 
		SELECT 
			[data].[row].value(N'@drive[1]', N'sysname') [drive],
			[data].[row].value(N'@label[1]', N'sysname') [label],
			[data].[row].value(N'@file_system[1]', N'sysname') [file_system],
			[data].[row].value(N'@size_gb[1]', N'decimal(10,2)') [size_gb],
			[data].[row].value(N'@free_gb[1]', N'decimal(10,2)') [free_gb],
			[data].[row].value(N'@percent_used[1]', N'decimal(5,2)') [percent_used]
		FROM 
			@disks.nodes(N'//disk') [data]([row])
	) 

	SELECT 
		[drive],
		[label],
		[file_system],
		[size_gb],
		[free_gb],
		[percent_used] 
	FROM 
		core;
GO