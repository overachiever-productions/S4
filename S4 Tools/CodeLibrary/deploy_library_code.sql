/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[deploy_library_code]', N'P') IS NOT NULL
	DROP PROC  dbo.[deploy_library_code];
GO

CREATE PROC	dbo.[deploy_library_code]
	@Key					sysname, 
	@PrintOnly				bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Key = UPPER(@Key);
	SET @PrintOnly = ISNULL(@PrintOnly, 0);

	IF NOT EXISTS (SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'code_library_enabled' AND [setting_value] = N'1') BEGIN
		RAISERROR(N'Code Library Functionality is not enabled. Execute dbo.initialize_codelibrary to enable.', 16, 1);
		RETURN -5;
	END;

	DECLARE @libraryId int, @hash sysname, @path nvarchar(2048), @encoding sysname;
	DECLARE @errorText nvarchar(MAX);

	SELECT 
		@libraryId = [library_id],
		@hash = [file_hash], 
		@path = [file_path] 
	FROM 
		dbo.[code_library]
	WHERE 
		[library_key] = @Key;

	IF @hash IS NULL BEGIN 
		RAISERROR(N'Invalid @Key value specified [%s].', 16, 1, @Key);
		RETURN -5; 
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Check if file exists + validate hash: 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @stringResult nvarchar(MAX), @errorMessage nvarchar(MAX);
	
	DECLARE @directory nvarchar(2048) = (SELECT dbo.[extract_directory_from_fullpath](@path));
	DECLARE @file nvarchar(2048) = (SELECT dbo.[extract_filename_from_fullpath](@path));
	
	DECLARE @powershellCommand nvarchar(MAX) = N'Test-Path -Path ''' + @path + N''';';
	EXEC dbo.[execute_powershell]
		@Command = @powershellCommand,
		@ExecutionAttemptsCount = 1,
		@StringOutput = @stringResult OUTPUT,
		@ErrorMessage = @errorMessage OUTPUT;
	
	IF @errorMessage IS NOT NULL BEGIN
		RAISERROR(N'Error verifying file exists. Path: [%s]. Error: [%s].', 16, 1, @path, @errorMessage);
		RETURN -10;
	END;

	SET @stringResult = REPLACE(@stringResult, @crlf, N'');

	IF LOWER(@stringResult) = N'true' BEGIN 

		SELECT @stringResult = NULL, @errorMessage = NULL; 
		SET @powershellCommand = N'(Get-FileHash -Path ''' + @path + ''').Hash;'

		EXEC dbo.[execute_powershell]
			@Command = @powershellCommand,
			@ExecutionAttemptsCount = 1,
			@StringOutput = @stringResult OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;

		IF @errorMessage IS NOT NULL BEGIN 
			RAISERROR(N'Error Verifying File-Hash. Path: [%s]. Error: [%s].', 16, 1, @path, @errorMessage);
			RETURN -12;
		END;

		SET @stringResult = REPLACE(@stringResult, @crlf, N'');

		IF @stringResult = @hash BEGIN 
			PRINT 'File [' + @file + N'] already deployed to [' + @directory + N'] with up-to-date hash: [' + @hash + N'].';
			RETURN 0;
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Write File to Disk (if not already written):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @command nvarchar(MAX) = N'bcp "EXEC admindb.dbo.[load_library_code] {id};" queryout "{path}" -f C:\Perflogs\lib\code.fmt -T';
	SET @command = REPLACE(@command, N'{id}', @libraryId);
	SET @command = REPLACE(@command, N'{path}', @path);

	IF @PrintOnly = 1 BEGIN 
		PRINT @command;
		RETURN 0;
	END; 

	DECLARE	@Outcome xml;
	SET @errorMessage = NULL;
	EXEC dbo.[execute_command]
		@Command = @command,
		@ExecutionType = N'SHELL',
		@ExecutionAttemptsCount = 1,
		@IgnoredResults = N'{BCP}',
		@PrintOnly = 0,
		@Outcome = @Outcome OUTPUT,
		@ErrorMessage = @errorMessage OUTPUT; 

	IF @errorMessage IS NOT NULL BEGIN 
		RAISERROR(N'Error writing library-file to disk. Path: [%s]. Command: [%s]. Error: [%s].', 16, 1, @path, @command, @errorMessage);
		RETURN -30;
	END;	

	RETURN 0;
GO