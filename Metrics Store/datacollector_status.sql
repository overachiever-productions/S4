/*

		CONVENTIONS
			- CodeLibrary-FileKey as Token. 

		vNEXT: 
			- This was originally written against Get-DataCollectorStatus. 
				But, there's no reason I can't execute it against Get-DataCollectors IF @DataCollectorName = N'{ALL}'. 
				i.e., that way I can use this to check on individual data collector sets when/as needed. 
				AND can also use a single sproc call to get info on ALL running/executing Data Collector Sets. 
			- and, along the lines of the above, no reason i can't return OUTPUT info via XML - i.e., serialized results
				i.e., make this sproc adhere to PROJECT or RETURN. 

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
		@PrintOnly = 0,
		@StringOutput = @StringOutput OUTPUT,
		@ErrorMessage = @ErrorMessage OUTPUT; 

	SELECT @StringOutput [string], @ErrorMessage;

	
	

