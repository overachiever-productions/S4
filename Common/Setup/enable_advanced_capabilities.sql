/*

	NOTE: Only members of SysAdmin (or those with similar/suitable permissions) will be able to successfully run this stored procedure.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.enable_advanced_capabilities','P') IS NOT NULL
	DROP PROC dbo.enable_advanced_capabilities;
GO

CREATE PROC dbo.enable_advanced_capabilities

AS 
	SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @xpCmdShellValue bit; 
	DECLARE @xpCmdShellInUse bit;
	DECLARE @advancedS4 bit = 0;
	
	SELECT 
		@xpCmdShellValue = CAST([value] AS bit), 
		@xpCmdShellInUse = CAST([value_in_use] AS bit) 
	FROM 
		sys.configurations 
	WHERE 
		[name] = 'xp_cmdshell';

	IF EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN 
		SELECT 
			@advancedS4 = CAST([setting_value] AS bit) 
		FROM 
			dbo.[settings] 
		WHERE 
			[setting_key] = N'advanced_s4_error_handling';
	END;

	-- check to see if enabled first: 
	IF @advancedS4 = 1 AND @xpCmdShellInUse = 1 BEGIN
		PRINT 'Advanced S4 error handling (ability to use xp_cmdshell) already/previously enabled.';
		GOTO termination;
	END;

	IF @xpCmdShellValue = 1 AND @xpCmdShellInUse = 0 BEGIN 
		RECONFIGURE;
		SET @xpCmdShellInUse = 1;
	END;

	IF @xpCmdShellValue = 0 BEGIN

        IF EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'show advanced options' AND [value_in_use] = 0) BEGIN
            EXEC sp_configure 'show advanced options', 1; 
            RECONFIGURE;
        END;

		EXEC sp_configure 'xp_cmdshell', 1; 
		RECONFIGURE;

		SELECT @xpCmdShellValue = 1, @xpCmdShellInUse = 1;
	END;

	IF @advancedS4 = 0 BEGIN 
		IF EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN
			UPDATE dbo.[settings] 
			SET 
				[setting_value] = N'1', 
				[comments] = N'Manually enabled on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.'  
			WHERE 
				[setting_key] = N'advanced_s4_error_handling';
		  END;
		ELSE BEGIN 
			INSERT INTO dbo.[settings] (
				[setting_type],
				[setting_key],
				[setting_value],
				[comments]
			)
			VALUES (
				N'UNIQUE', 
				N'advanced_s4_error_handling', 
				N'1', 
				N'Manually enabled on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.' 
			);
		END;
		SET @advancedS4 = 1;
	END;

termination: 
	SELECT 
		@xpCmdShellValue [xp_cmdshell.value], 
		@xpCmdShellInUse [xp_cmdshell.value_in_use],
		@advancedS4 [advanced_s4_error_handling.value];

	RETURN 0;
GO