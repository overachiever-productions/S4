/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_nonaccessible_databases','TF') IS NOT NULL
	DROP FUNCTION dbo.[list_nonaccessible_databases];
GO

CREATE FUNCTION dbo.[list_nonaccessible_databases] ()
RETURNS @nonaccessibleDatabases table ( 
	database_id int NOT NULL, 
	[database_name] sysname NOT NULL, 
	[status] sysname NOT NULL, 
	[owner_spid] int NULL
)
AS
    
	-- {copyright}
    
    BEGIN; 
    	
		-- SINGLE_USER dbs (potential vNEXT option: look into excluding based on @@SPID vs currently owning spid?)
		INSERT INTO @nonaccessibleDatabases ([database_id],[database_name],[status], [owner_spid])
		SELECT d.database_id, d.[name], N'SINGLE_USER' [status], s.[spid]
		FROM sys.databases d 
		LEFT OUTER JOIN sys.[sysprocesses] s ON d.[database_id] = s.[dbid]
		WHERE d.user_access_desc = N'SINGLE_USER';

		-- restoring/recovering and non-ONLINE databases:
    	INSERT INTO @nonaccessibleDatabases ([database_id],[database_name],[status])
		SELECT database_id, [name], state_desc 
		FROM sys.databases WHERE [state_desc] <> N'ONLINE';

		-- AG/Mirroring secondaries:
		WITH synchronized AS ( 
			SELECT 
				[database_name],
				[sync_type] + N' - ' + [role] [status]
			FROM 
				admindb.dbo.list_synchronizing_databases(NULL, 0)
			WHERE 
				[role] = N'SECONDARY'
		)

		INSERT INTO @nonaccessibleDatabases ([database_id],[database_name],[status])
		SELECT 
			d.database_id,
			s.[database_name], 
			s.[status]
		FROM 
			synchronized s 
			INNER JOIN sys.databases d ON s.[database_name] = d.[name]
    	
    	RETURN;
    
    END;
GO

--##CONDITIONAL_VERSION(> 10.5) 

ALTER FUNCTION dbo.[list_nonaccessible_databases] ()
RETURNS @nonaccessibleDatabases table ( 
	database_id int NOT NULL, 
	[database_name] sysname NOT NULL, 
	[status] sysname NOT NULL, 
	[owner_spid] int NULL
)
AS
    
	-- {copyright}
    
    BEGIN; 
    	
		-- SINGLE_USER dbs (potential vNEXT option: look into excluding based on @@SPID vs currently owning spid?)
		INSERT INTO @nonaccessibleDatabases ([database_id],[database_name],[status], [owner_spid])
		SELECT d.database_id, d.[name], N'SINGLE_USER' [status], s.[session_id]
		FROM sys.databases d 
		LEFT OUTER JOIN sys.[dm_exec_sessions] s ON d.[database_id] = s.[database_id] 
		WHERE d.user_access_desc = N'SINGLE_USER';

		-- restoring/recovering and non-ONLINE databases:
    	INSERT INTO @nonaccessibleDatabases ([database_id],[database_name],[status])
		SELECT database_id, [name], state_desc 
		FROM sys.databases WHERE [state_desc] <> N'ONLINE';

		-- AG/Mirroring secondaries:
		WITH synchronized AS ( 
			SELECT 
				[database_name],
				[sync_type] + N' - ' + [role] [status]
			FROM 
				admindb.dbo.list_synchronizing_databases(NULL, 0)
			WHERE 
				[role] = N'SECONDARY'
		)

		INSERT INTO @nonaccessibleDatabases ([database_id],[database_name],[status])
		SELECT 
			d.database_id,
			s.[database_name], 
			s.[status]
		FROM 
			synchronized s 
			INNER JOIN sys.databases d ON s.[database_name] = d.[name]
    	
    	RETURN;
    
    END;
GO