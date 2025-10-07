/*

		CONVENTIONS
			- CodeLibrary-FileKey as Token. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[datacollector_status]','P') IS NOT NULL
	DROP PROC dbo.[datacollector_status];
GO

CREATE PROC dbo.[datacollector_status]
	@DataCollectorName			sysname	
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @outcome int;
	EXEC @outcome = dbo.verify_datacollector_permissions;
	IF @outcome <> 0 BEGIN
		-- Raise has already been handled.
		RETURN @outcome;
	END;

	DECLARE @command nvarchar(MAX) = N'Get-DataCollectorStatus "{0}";';
	SET @command = REPLACE(@command, N'{0}', @DataCollectorName);

	DECLARE	@StringOutput nvarchar(MAX), @ErrorMessage nvarchar(MAX);
	EXEC dbo.[execute_powershell]
		@Command = @command,
		@DotIncludeFile = N'{ADMINDB_CORE_PS}',
		@ExecutionAttemptsCount = 1,
		@PrintOnly = 1,
		@StringOutput = @StringOutput OUTPUT,
		@ErrorMessage = @ErrorMessage OUTPUT; 

	SELECT @StringOutput [string], @ErrorMessage;

	
	

