/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_synchronizing_databases','TF') IS NOT NULL
	DROP FUNCTION dbo.list_synchronizing_databases;
GO


CREATE FUNCTION dbo.list_synchronizing_databases(
	@IgnoredDatabases			nvarchar(MAX)		= NULL, 
	@ExcludeSecondaries			bit					= 0
)
RETURNS @synchronizingDatabases table ( 
	server_name sysname, 
	sync_type sysname,
	[database_name] sysname, 
	[role] sysname
) 
AS 
	-- {copyright}

	BEGIN;

		DECLARE @localServerName sysname = @@SERVERNAME;

		-- Mirrored DBs:
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		SELECT @localServerName [server_name], N'MIRRORED' sync_type, d.[name] [database_name], m.[mirroring_role_desc] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;
		
		IF @ExcludeSecondaries = 1 BEGIN 
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'AG' AND [role] = N'SECONDARY';
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'MIRRORED' AND [role] = N'MIRROR';
		END;

		IF NULLIF(@IgnoredDatabases, N'') IS NOT NULL BEGIN
			DELETE FROM @synchronizingDatabases WHERE [database_name] IN (SELECT [result] FROM dbo.[split_string](@IgnoredDatabases, N',', 1));
		END;

		RETURN;
	END;
GO

--##CONDITIONAL_VERSION(> 10.5) 

ALTER FUNCTION dbo.list_synchronizing_databases(
	@IgnoredDatabases			nvarchar(MAX)		= NULL, 
	@ExcludeSecondaries			bit					= 0
)
RETURNS @synchronizingDatabases table ( 
	server_name sysname, 
	sync_type sysname,
	[database_name] sysname, 
	[role] sysname
) 
AS
	-- {copyright}
	 
	BEGIN;

		DECLARE @localServerName sysname = @@SERVERNAME;

		-- Mirrored DBs:
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		SELECT @localServerName [server_name], N'MIRRORED' sync_type, d.[name] [database_name], m.[mirroring_role_desc] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;

		-- AG'd DBs (2012 + only):
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		SELECT @localServerName [server_name], N'AG' [sync_type], d.[name] [database_name], hars.role_desc FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id;

		IF @ExcludeSecondaries = 1 BEGIN 
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'AG' AND [role] = N'SECONDARY';
			DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'MIRRORED' AND [role] = N'MIRROR';
		END;

		IF NULLIF(@IgnoredDatabases, N'') IS NOT NULL BEGIN
			DELETE FROM @synchronizingDatabases WHERE [database_name] IN (SELECT [result] FROM dbo.[split_string](@IgnoredDatabases, N',', 1));
		END;

		RETURN;
	END;
GO