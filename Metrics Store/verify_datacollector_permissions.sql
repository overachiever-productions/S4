/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[verify_datacollector_permissions]','P') IS NOT NULL
	DROP PROC dbo.[verify_datacollector_permissions];
GO

CREATE PROC dbo.[verify_datacollector_permissions]

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF EXISTS (SELECT NULL FROM [dbo].[settings] WHERE [setting_key] = N'data_collector_perms_set' AND [setting_value] = N'1') BEGIN
		RETURN 0;
	END;

	DECLARE @currentServiceAccount sysname = (SELECT [service_account] FROM sys.dm_server_services WHERE [servicename] LIKE N'SQL Server (%');
	DECLARE @command nvarchar(MAX) = REPLACE(N'Test-PerformanceGroupMembership -Member ''{0}''; ', N'{0}', @currentServiceAccount);
	
	DECLARE @stringOutput nvarchar(MAX), @errorMessage nvarchar(MAX);
	EXEC dbo.[execute_powershell]
		@Command = @command,
		@DotIncludeFile = N'{ADMINDB_CORE_PS}',
		@ExecutionAttemptsCount = 1,
		@StringOutput = @stringOutput OUTPUT,
		@ErrorMessage = @ErrorMessage OUTPUT; 

	IF @errorMessage IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected Error Executing Test-CurrentuserHasPerformancePermissions: %s.', 16, 1, @errorMessage);
		RETURN -10;
	END;
	
	IF @stringOutput LIKE N'Both%' BEGIN
		IF EXISTS(SELECT NULL FROM [dbo].[settings] WHERE [setting_key] = N'data_collector_perms_set') BEGIN
			UPDATE [dbo].[settings] SET [setting_value] = N'1', [comments] = CONVERT(sysname, GETDATE(), 121) WHERE [setting_key] = N'data_collector_perms_set';
		  END;
		ELSE BEGIN
			INSERT INTO dbo.[settings] ([setting_type], [setting_key], [setting_value], [comments])
			VALUES (N'UNIQUE', N'data_collector_perms_set', N'1', CONVERT(sysname, GETDATE(), 121));
		END;

		RETURN 0;
	END;
	
	DECLARE @instructions nvarchar(MAX) = N'	--------------------------------------------------------------------------
	Granting SQL Server Service Membership in Performance Log Groups:
	--------------------------------------------------------------------------
		- SQL Server does not currently have membership in BOTH groups necessary for interaction (READ and WRITE) with Data Collector Sets. 
				- Current Membership is [{membership}]  (vs options of Read | Write | Both - with "Both" being required).
		- An Administrator MUST grant membership ... (SQL Server can NOT do this itself).
		
		- For more context and details: 
			https://totalsql.com/xxxx/granting-membership-blah

		- The EXACT code to grant membership in these groups is provided below for PowerShell and CMD.exe implementations.
		- If you want to continue, copy/paste the PowerShell or CMD syntax from below into an ELEVATED prompt and execute. 

		POWERSHELL CODE: 
			
			Add-LocalGroupMember -Group "Performance Log Users" -Member "{service_account}"; 
			Add-LocalGroupMember -Group "Performance Monitor Users" -Member "{service_account}";

		CMD.EXE CODE: 
			
			net localgroup "Performance Log Users" "{service_account}" /add 
			net localgroup "Performance Monitor Users" "{service_account}" /add 

	';

	SET @instructions = REPLACE(@instructions, N'{service_account}', @currentServiceAccount);
	SET @instructions = REPLACE(@instructions, N'{membership}', @stringOutput);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	RAISERROR('SQL Server does NOT have membership in BOTH of the Performance Log/Monitoring Groups required for interaction with Performance Logs.%sTo correct this problem, review the instructions below: ', 16, 1, @crlf);
	PRINT @instructions;

	RETURN -5;
GO
