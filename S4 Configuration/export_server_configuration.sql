/*

	


	EXEC admindb.dbo.[export_server_configuration]
		--@OutputPath = N'[DEFAULT]', 
		@CopyToPath = N'D:\Dropbox\Server\SQLBackups';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.export_server_configuration','P') IS NOT NULL
	DROP PROC dbo.export_server_configuration;
GO

CREATE PROC dbo.export_server_configuration 
	@OutputPath								nvarchar(2000)			= N'{DEFAULT}',
	@CopyToPath								nvarchar(2000)			= NULL, 
	@AddServerNameToFileName				bit						= 1, 
	@OperatorName							sysname					= N'Alerts',
	@MailProfileName						sysname					= N'General',
	@EmailSubjectPrefix						nvarchar(50)			= N'[Server Configuration Export] ',	 
	@PrintOnly								bit						= 0	

AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
    EXEC dbo.verify_advanced_capabilities;

	-----------------------------------------------------------------------------
	-- Input Validation:

	DECLARE @edition sysname;
	SELECT @edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @edition = N'STANDARD' OR @edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @edition = 'WEB';
	END;
	
	IF @edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF (@PrintOnly = 0) AND (@edition <> 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @databaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @databaseMailProfile OUT, @no_output = N'no_output';
 
		IF @databaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@OutputPath) = N'{DEFAULT}' BEGIN
		SELECT @OutputPath = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@OutputPath, N'') IS NULL BEGIN
		RAISERROR('@OutputPath cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF @PrintOnly = 1 BEGIN 
		
		-- just execute the sproc that prints info to the screen: 
		EXEC dbo.script_configuration;

		RETURN 0;
	END; 


	-- if we're still here, we need to dynamically output/execute dbo.script_server_configuration so that output is directed to a file (and copied if needed)
	--		while catching and alerting on any errors or problems. 
	DECLARE @errorDetails nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	-- normalize paths: 
	IF(RIGHT(@OutputPath, 1) = '\')
		SET @OutputPath = LEFT(@OutputPath, LEN(@OutputPath) - 1);

	IF(RIGHT(ISNULL(@CopyToPath, N''), 1) = '\')
		SET @CopyToPath = LEFT(@CopyToPath, LEN(@CopyToPath) - 1);

	DECLARE @outputFileName varchar(2000);
	SET @outputFileName = @OutputPath + '\' + CASE WHEN @AddServerNameToFileName = 1 THEN @@SERVERNAME + '_' ELSE '' END + N'Server_Configuration.txt';

	DECLARE @errors table ( 
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) 
	);

	DECLARE @xpCmdShellOutput table (
		result_id int IDENTITY(1,1) NOT NULL, 
		result nvarchar(MAX) NULL
	);

	-- Set up a 'translation' of the sproc call (for execution via xp_cmdshell): 
	DECLARE @sqlCommand varchar(MAX); 
	SET @sqlCommand = N'EXEC admindb.dbo.script_server_configuration;';

	DECLARE @command varchar(8000) = 'sqlcmd {0} -Q "{1}" -o "{2}"';

	-- replace parameters: 
	SET @command = REPLACE(@command, '{0}', CASE WHEN UPPER(@@SERVICENAME) = 'MSSQLSERVER' THEN '' ELSE ' -S .\' + UPPER(@@SERVICENAME) END);
	SET @command = REPLACE(@command, '{1}', @sqlCommand);
	SET @command = REPLACE(@command, '{2}', @outputFileName);

	BEGIN TRY

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL; 

		IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 
			SET @errorDetails = N'';
			SELECT 
				@errorDetails = @errorDetails + [result] + @crlf + @tab
			FROM 
				@xpCmdShellOutput 
			ORDER BY 
				[result_id];

			SET @errorDetails = N'Unexpected problem while attempting to write configuration details to disk: ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

			INSERT INTO @errors (error) VALUES (@errorDetails);
		END
		
		-- Verify that the file was written as expected: 
		SET @command = 'for %a in ("' + @outputFileName + '") do @echo %~ta';
		DELETE FROM @xpCmdShellOutput; 

		INSERT INTO @xpCmdShellOutput ([result])
		EXEC master.sys.[xp_cmdshell] @command;

		DECLARE @timeStamp datetime; 
		SELECT @timeStamp = MAX(CAST([result] AS datetime)) FROM @xpCmdShellOutput WHERE [result] IS NOT NULL;

		IF DATEDIFF(MINUTE, @timeStamp, GETDATE()) > 2 BEGIN 
			SET @errorDetails = N'TimeStamp for [' + @outputFileName + N'] reads ' + CONVERT(nvarchar(30), @timeStamp, 120) + N'. Current Execution Time is: ' + CONVERT(nvarchar(30), GETDATE(), 120) + N'. File writing operations did NOT throw an error, but time-stamp difference shows ' + @outputFileName + N' file was NOT written as expected.' ;
			
			INSERT INTO @errors (error) VALUES (@errorDetails);
		END;

		-- copy the file if/as needed:
		IF @CopyToPath IS NOT NULL BEGIN

			DELETE FROM @xpCmdShellOutput;
			SET @command = 'COPY "{0}" "{1}\"';

			SET @command = REPLACE(@command, '{0}', @outputFileName);
			SET @command = REPLACE(@command, '{1}', @CopyToPath);

			INSERT INTO @xpCmdShellOutput ([result])
			EXEC master.sys.[xp_cmdshell] @command;

			DELETE FROM @xpCmdShellOutput WHERE [result] IS NULL OR [result] LIKE '%1 file(s) copied.%'; 

			IF EXISTS (SELECT NULL FROM @xpCmdShellOutput) BEGIN 

				SET @errorDetails = N'';
				SELECT 
					@errorDetails = @errorDetails + [result] + @crlf + @tab
				FROM 
					@xpCmdShellOutput 
				ORDER BY 
					[result_id];

				SET @errorDetails = N'Unexpected problem while copying file from @OutputPath to @CopyFilePath : ' + @crlf + @crlf + @tab + @errorDetails + @crlf + @crlf + N'COMMAND: [' + @command + N']';

				INSERT INTO @errors (error) VALUES (@errorDetails);
			END 
		END;

	END TRY 
	BEGIN CATCH
		SET @errorDetails = N'Unexpected Exception while executing command: [' + ISNULL(@command, N'#ERROR#') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

		INSERT INTO @errors (error) VALUES (@errorDetails);
	END CATCH

REPORTING: 
	IF EXISTS (SELECT NULL FROM @errors) BEGIN
		DECLARE @emailErrorMessage nvarchar(MAX) = N'The following errors were encountered: ' + @crlf + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + N'- ' + [error] + @crlf
		FROM 
			@errors
		ORDER BY 
			error_id;

		DECLARE @emailSubject nvarchar(2000);
		SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';
	
		IF @edition <> 'EXPRESS' BEGIN;
			EXEC msdb.dbo.sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;
		END;		

	END;

	RETURN 0;
GO