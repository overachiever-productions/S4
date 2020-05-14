/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.update_server_name','P') IS NOT NULL
	DROP PROC dbo.[update_server_name];
GO

CREATE PROC dbo.[update_server_name]
	@PrintOnly			bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @currentHostNameInWindows sysname;
	DECLARE @serverNameFromSysServers sysname; 

	SELECT
		@currentHostNameInWindows = CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS sysname),
		@serverNameFromSysServers = @@SERVERNAME;

	IF UPPER(@currentHostNameInWindows) <> UPPER(@serverNameFromSysServers) BEGIN
		DECLARE @oldServerName sysname = @serverNameFromSysServers;
		DECLARE @newServerName sysname = @currentHostNameInWindows;

		PRINT N'BIOS/Windows HostName: ' + @newServerName + N' does not match name defined within SQL Server: ' + @oldServerName + N'.';
		

		IF @PrintOnly = 0 BEGIN 

			PRINT N'Initiating update to SQL Server definitions.';
			
			EXEC sp_dropserver @oldServerName;
			EXEC sp_addserver @newServerName, local;

			PRINT N'SQL Server Server-Name set to ' + @newServerName + N'.';

			PRINT 'Please RESTART SQL Server to ensure that this change has FULLY taken effect.';

		END;
	END;

	RETURN 0;
GO