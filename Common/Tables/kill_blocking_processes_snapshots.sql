/*

*/

USE [admindb];
GO 

	-- {copyright}

IF OBJECT_ID(N'dbo.kill_blocking_process_snapshots', N'U') IS NULL BEGIN 
	CREATE TABLE dbo.kill_blocking_process_snapshots (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[timestamp] datetime NOT NULL, 
		[print_only] bit NOT NULL,
		[blocked_processes] int NOT NULL, 
		[lead_blockers] int NOT NULL, 
		[blockers_to_kill] int NOT NULL, 
		[snapshot] XML NOT NULL, 
		CONSTRAINT PK_kill_blocking_process_snapshots PRIMARY KEY CLUSTERED ([row_id])
	); 

END;
GO