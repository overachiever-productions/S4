/*

	DECLARE @command varchar(2000) = 'bcp "SELECT [code] FROM admindb..[code_library] WHERE script_id = 2;" queryout C:\Perflogs\lib\sql.perfmoncfg -f C:\Perflogs\lib\code.fmt -T';
	EXEC xp_cmdshell @command;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[initialize_codelibrary]','P') IS NOT NULL
	DROP PROC dbo.[initialize_codelibrary];
GO

CREATE PROC dbo.[initialize_codelibrary]
	@ForceInitialization			bit = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @settingsKey sysname = N'code_library_enabled';
	IF EXISTS (SELECT NULL FROM dbo.[settings] WHERE [setting_key] = @settingsKey AND [setting_value] = N'1') BEGIN
		IF @ForceInitialization = 0 RETURN 0;
	END;

	DECLARE @crlfTab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	DECLARE @perfLogs sysname = N'C:\Perflogs';
	DECLARE @instructions nvarchar(MAX) = N'	--------------------------------------------------------------------------
	Granting SQL Server Permissions against [{directory}]:
	--------------------------------------------------------------------------
		- SQL Server does not currently have write-access against [{directory}]. 
		- An Administrator MUST grant permissions (SQL Server can NOT do this itself).  

		- For more context and details on potential security concerns, visit:
			https://totalsql.com/xxxxx/granting-sql-server-write-perms-vs-folders 

		- The EXACT code to grant these permissions is provided below for both PowerShell and CMD.exe implementations. 
		- If you want to continue, copy/paste the PowerShell or CMD syntax from below into an ELEVATED prompt and execute. 

		POWERSHELL CODE:

			$acl = Get-Acl -Path "{directory}\"; 
			$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("{service}", "FullControl", "ContainerInherit,ObjectInherit", "none", "Allow");
			$acl.SetAccessRule($rule);
			Set-Acl -Path "{directory}\" -AclObject $acl;

		CMD.EXE CODE:

			icacls "{directory}" /grant:r "{service}":(OI)(CI)F

	';

	-- TODO: I may, arguably, want to put all of this 'logic' + instructions into a UDF - that can be called from multiple places? 
	DECLARE @service sysname = N'NT SERVICE\MSSQLSERVER';
	IF @@SERVERNAME LIKE N'%\%' BEGIN
		SET @service = (SELECT [result] FROM dbo.[split_string](@@SERVERNAME, N'\', 1) WHERE [row_id] = 2);
		SET @service = N'NT SERVICE\MSSQL$' + @service;
	END;

	SET @instructions = REPLACE(@instructions, N'{service}', @service);
	SET @instructions = REPLACE(@instructions, N'{directory}', @perfLogs);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Verify C:\Perflogs, C:\PerfLogs\lib - and that SQL Server has access. 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @exists bit; 
	DECLARE @hasAccess bit; 
	EXEC dbo.[verify_directory_access]
		@TargetPath = @perfLogs,
		@Accessible = @hasAccess OUTPUT; 

	IF ISNULL(@hasAccess, 0) = 0 BEGIN
		RAISERROR(N'SQL Server does NOT have write permissions against [%s].%sTo correct this problem, review the instructions below: ', 16, 1, @perfLogs, @crlfTab);
		-- TODO: do I also need to grant PERMS here to the SQL Server Service? 
		--		and (sneaky, sneaky) if SQL Server has FULL perms here, can it GRANT perms for SQL Server Service? 
		PRINT @instructions;

		RETURN -5;
	END;

	DECLARE @codeLibDirectory sysname = N'C:\Perflogs\lib';
	DECLARE @error nvarchar(MAX);
	EXEC dbo.[establish_directory]
		@TargetDirectory = @codeLibDirectory,
		@Error = @error OUTPUT
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(N'ruh roh', 16, 1);
		RETURN -5;
	END;

	EXEC dbo.[check_paths] @Path = @codeLibDirectory, @Exists = @exists OUTPUT;
	IF ISNULL(@exists, 0) = 0 BEGIN 
		RAISERROR(N'TargetDirectory [%s] does NOT exist.', 16, 1, @codeLibDirectory);
		RETURN -20;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Get BCP Version:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	-- NOTE: if there's already a v.fmt in place, BCP will overwrite it without throwing errors or prompts/etc. i.e., this is idempotent:
	DECLARE @command varchar(2000) = 'bcp admindb.dbo.[code_view] format nul -f C:\Perflogs\lib\v.fmt -T -n';

	SET @error = NULL;
	EXEC dbo.[execute_command]
		@Command = @command,
		@ExecutionType = N'SHELL',
		@ExecutionAttemptsCount = 1,
		@PrintOnly = 0,
		@Outcome = NULL,
		@ErrorMessage = @error OUTPUT; 

	IF @error IS NOT NULL BEGIN 
		SELECT @error;
		RAISERROR('ruh roh. something wrong happened.', 16, 1);
		RETURN -10;
	END;

	SET @error = NULL;
	DECLARE @stringContent nvarchar(MAX);
	EXEC dbo.[execute_powershell]
		@Command = N'Get-Content -Path "C:\Perflogs\lib\v.fmt" -Raw;',
		@ExecutionAttemptsCount = 1,
		@StringOutput = @stringContent OUTPUT,
		@ErrorMessage = @error OUTPUT

	IF @error IS NOT NULL BEGIN 
		RAISERROR(N'ruh roh', 16, 1);
		RETURN -11;
	END; 

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @bcpVersion sysname = (SELECT [result] FROM [dbo].[split_string](@stringContent, @crlf, 1) WHERE [row_id] = 1);

	--TODO, arguably: remove v.fmt. 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Deploy BCP (CODE) FORMAT FILE:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @command = N'EXEC admindb.dbo.[create_code_formatfile] @BcpVersion = N''' + @bcpVersion + ''';'
	--DECLARE @sqlCommand varchar(2000) = '-Q "{1}" -o "{2}" -f o:{e}';
	DECLARE @sqlCommand varchar(2000) = '-Q "{1}" -o "{2}"';
	SET @sqlCommand = REPLACE(@sqlCommand, N'{1}', @command);
	SET @sqlCommand = REPLACE(@sqlCommand, N'{2}', N'C:\Perflogs\lib\code.fmt');
	--SET @sqlCommand = REPLACE(@sqlCommand, N'{e}', N'65001'); -- ANSI... 

	DECLARE @outcome xml;
	SET @error = NULL;
	EXEC dbo.[execute_command]
		@Command = @sqlCommand,
		@ExecutionType = N'SQLCMD',
		@ExecutionAttemptsCount = 1,
		@PrintOnly = 0,
		@Outcome = @outcome OUTPUT,
		@ErrorMessage = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(N'ruh roh', 16, 1);
		SELECT @error;
		RETURN -12;
	END;

	INSERT INTO dbo.[settings] ([setting_type], [setting_key], [setting_value], [comments])
	VALUES (N'UNIQUE', @settingsKey, N'1', CONVERT(sysname, GETDATE(), 121));

	RETURN 0;
GO