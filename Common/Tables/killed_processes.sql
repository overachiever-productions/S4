/*
	
*/

USE [admindb];
GO 

-- {copyright}

IF OBJECT_ID(N'[dbo].[killed_processes]', N'U') IS NULL BEGIN 
	CREATE TABLE [dbo].[killed_processes] (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[timestamp] datetime NOT NULL, 
		[type] sysname NOT NULL,	-- blocked_process, orphaned_connection, connection_pool_leak, etc. 
		[print_only] bit NOT NULL,
		[row_count] int NOT NULL, 
		[kill_count] int NOT NULL, 
		[executed_by] sysname NOT NULL, 
		[app_name] sysname NOT NULL, 
		[parameters] xml NOT NULL,
		[snapshot] xml NOT NULL,
		CONSTRAINT PK_killed_processes PRIMARY KEY NONCLUSTERED ([row_id])
	)
	WITH (DATA_COMPRESSION = PAGE);
	
	CREATE CLUSTERED INDEX CLIX_killed_processes_ByTypeAndTimeStamp ON [dbo].[killed_processes] ([type], [timestamp]);
END;
GO