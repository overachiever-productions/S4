/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_advanced_capabilities','P') IS NOT NULL
	DROP PROC dbo.verify_advanced_capabilities;
GO

CREATE PROC dbo.verify_advanced_capabilities
AS
	SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @xpCmdShellInUse bit;
	DECLARE @advancedS4 bit;
	DECLARE @errorMessage nvarchar(1000);
	
	SELECT 
		@xpCmdShellInUse = CAST([value_in_use] AS bit) 
	FROM 
		sys.configurations 
	WHERE 
		[name] = 'xp_cmdshell';

	SELECT 
		@advancedS4 = CAST([setting_value] AS bit) 
	FROM 
		dbo.[settings] 
	WHERE 
		[setting_key] = N'advanced_s4_error_handling';

	IF @xpCmdShellInUse = 1 AND ISNULL(@advancedS4, 0) = 1
		RETURN 0;
	
	RAISERROR(N'Advanced S4 error handling capabilities are NOT enabled. Please consult S4 setup documentation and execute admindb.dbo.enable_advanced_capabilities;', 16, 1);
	RETURN -1;
GO