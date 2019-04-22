/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.disable_advanced_s4','P') IS NOT NULL
	DROP PROC dbo.disable_advanced_s4
GO

CREATE PROC dbo.disable_advanced_s4

AS 
	SET NOCOUNT ON;

	-- {copyright}

	DECLARE @xpCmdShellValue bit; 
	DECLARE @xpCmdShellInUse bit;
	DECLARE @advancedS4 bit = 0;
	DECLARE @errorMessage nvarchar(MAX);
		
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

	BEGIN TRY 
		IF @xpCmdShellValue = 1 OR @xpCmdShellInUse = 1 BEGIN
			EXEC sp_configure 'xp_cmdshell', 0; 
			RECONFIGURE;	
			
			SELECT @xpCmdShellValue = 0, @xpCmdShellInUse = 0;
		END;

		IF EXISTS (SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN
			IF @advancedS4 = 1 BEGIN 
				UPDATE dbo.[settings]
				SET 
					[setting_value] = N'0', 
					[comments] = N'Manually DISABLED on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.' 
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
					N'Manually DISABLED on ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'.' 
				);
			END;
			SET @advancedS4 = 0;
		END;

	END TRY
	BEGIN CATCH 
		SELECT @errorMessage = N'Unhandled Exception: ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END CATCH

	SELECT 
		@xpCmdShellValue [xp_cmdshell.value], 
		@xpCmdShellInUse [xp_cmdshell.value_in_use],
		@advancedS4 [advanced_s4_error_handling.value];

	RETURN 0;
GO