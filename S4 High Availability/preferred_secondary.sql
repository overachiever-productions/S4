/*
    

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.preferred_secondary', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[preferred_secondary];
GO

CREATE FUNCTION dbo.[preferred_secondary] (@Database sysname)
RETURNS sysname
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output sysname = NULL;
    	
    	DECLARE @groupID uniqueidentifier;
        SELECT @groupID = [h].[group_id] FROM sys.[databases] [d] INNER JOIN sys.[dm_hadr_availability_replica_states] [h] ON [d].[replica_id] = [h].[replica_id] WHERE [d].[name] = @Database;

        IF @groupID IS NOT NULL BEGIN
    	    SET @output = (SELECT TOP (1) [replica_server_name] FROM sys.[availability_replicas] WHERE [group_id] = @groupID AND [replica_server_name] <> @@SERVERNAME ORDER BY [backup_priority] DESC);
    	END;
    	
    	RETURN @output;
    
    END;
GO

