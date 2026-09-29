/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[restore_encoded_certificate]','P') IS NOT NULL
	DROP PROC dbo.[restore_encoded_certificate];
GO

CREATE PROC dbo.[restore_encoded_certificate]
	@private_key_password					sysname,
	@certificate_name						sysname,
	@execute_backup_and_cleanup				bit				= 1, 
	@encoded_certificate					nvarchar(MAX), 
	@encoded_private_key					nvarchar(MAX), 
	@print_only								bit				= 0			-- think i'll have it scrub/remove the @private_key_pwd
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @private_key_password = NULLIF(@private_key_password, N'');

	IF @private_key_password IS NULL BEGIN 
		RAISERROR(N'Parameter @private_key_password can not be NULL or empty.', 16, 1);
		RETURN -10;
	END;

	IF EXISTS (SELECT NULL FROM [master].sys.[certificates] WHERE [name] = @certificate_name) BEGIN
		RAISERROR(N'A certificate with the name [%s] already exists in [master].[sys].[certificates].', 16, 1, @certificate_name);
		RETURN -12;
	END;

	DECLARE @encodedCert varbinary(MAX) = DECOMPRESS(CONVERT(varbinary(MAX), REPLACE(dbo.[remove_whitespace](@encoded_certificate), N';', N''), 1));
	DECLARE @encodedKey varbinary(MAX) = DECOMPRESS(CONVERT(varbinary(MAX), REPLACE(dbo.[remove_whitespace](@encoded_private_key), N';', N''), 1));

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Master Encryption Key (if/as needed): 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	-- DRY_VIOLATION: the code below exists here and in dbo.create_server_certificate and dbo.restore_server_certificate:
	IF NOT EXISTS (SELECT NULL FROM master.sys.[symmetric_keys] WHERE [symmetric_key_id] = 101) BEGIN 
		
		DECLARE @masterKeyEncryptionPassword sysname = LOWER(LEFT(CAST(NEWID() AS sysname), 18));

		DECLARE @command nvarchar(MAX) = N'USE [master];

IF NOT EXISTS (SELECT NULL FROM master.sys.symmetric_keys WHERE symmetric_key_id = 101) BEGIN;
	CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''' + @masterKeyEncryptionPassword + N''';
END;
';
		IF @print_only = 1 BEGIN
			PRINT @command; 
			PRINT N'GO';
			PRINT N'';
		  END;
		ELSE 
			EXEC sys.sp_executesql 
				@command;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Rehydate Certificate:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @errorMessage nvarchar(MAX), @errorLine int, @errorNumber int;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @template nvarchar(MAX) = N'USE [master];
	
CREATE CERTIFICATE [{name}]
	FROM BINARY = {cert}
	WITH PRIVATE KEY (
		BINARY = {key}, 
		DECRYPTION BY PASSWORD = ''{password}''
);';

	SET @template = REPLACE(@template, N'{name}', @certificate_name);
	SET @template = REPLACE(@template, N'{cert}', CONVERT(nvarchar(MAX), @encodedCert, 1));
	SET @template = REPLACE(@template, N'{key}', CONVERT(nvarchar(MAX), @encodedKey, 1));
	
	IF @print_only = 1 
		SET @template = REPLACE(@template, N'{password}', N'<!!!!ENTER PASSWORD HERE!!!!>');
	ELSE 
		SET @template = REPLACE(@template, N'{password}', @private_key_password);

	IF @print_only = 1 BEGIN
		EXEC dbo.[print_string] @template;
		PRINT N'GO';
		PRINT N'';
	  END; 
	ELSE BEGIN
		BEGIN TRY
			EXEC sys.sp_executesql 
				@template;
		END TRY 
		BEGIN CATCH 
			SELECT @errorNumber = ERROR_NUMBER();

			IF @errorNumber = 15232 BEGIN 
				-- SQL Server Bug: Error Message for 15232 is WRONG ... (it says NAME - thumbprint is the issue).  
				RAISERROR(N'A certificate with a MATCHING THUMBPRINT already exists or this certificate already has been added to the master database.', 16, 1);
				RETURN -100;
			END;

			SELECT 
				@errorLine = ERROR_LINE(), 
				@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(@errorNumber AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
			IF @@TRANCOUNT > 0 
				ROLLBACK;

			RAISERROR(@errorMessage, 16, 1);
			EXEC admindb.dbo.[extract_dynamic_code_lines] @template, @errorLine, 6;
			RETURN -100;
		END CATCH;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Backup + Cleanup:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @execute_backup_and_cleanup = 1 BEGIN
		DECLARE @cleanup nvarchar(MAX) = N'USE [master];
		
BACKUP CERTIFICATE [{certName}] TO FILE = ''{path}.cer'' WITH PRIVATE KEY ( FILE = ''{path}.key'', ENCRYPTION BY PASSWORD = ''{password}''); 

WAITFOR DELAY ''00:00:02.000'';
DECLARE @quiet_please table (output sysname NULL);
INSERT INTO @quiet_please ([output])
EXEC xp_cmdshell ''del "{path}.*" /q;''; ';

		DECLARE @uniqueifier sysname = LEFT(NEWID(), 8);
		DECLARE @fileName sysname = dbo.load_default_path('BACKUP') + N'\' + @certificate_name + N'_' + @uniqueifier;

		SET @cleanup = REPLACE(@cleanup, N'{certName}', @certificate_name);
		SET @cleanup = REPLACE(@cleanup, N'{path}', @fileName);
		SET @cleanup = REPLACE(@cleanup, N'{password}', CAST(NEWID() AS sysname));

		IF @print_only = 1 BEGIN
			PRINT @cleanup;
			PRINT N'GO';
			PRINT N'';
		  END;
		ELSE BEGIN
			BEGIN TRY

				EXEC sys.sp_executesql 
					@cleanup;
			END TRY
			BEGIN CATCH
				SELECT @errorNumber = ERROR_NUMBER();

				SELECT 
					@errorLine = ERROR_LINE(), 
					@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(@errorNumber AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
				IF @@TRANCOUNT > 0 
					ROLLBACK;

				RAISERROR(@errorMessage, 16, 1);
				EXEC admindb.dbo.[extract_dynamic_code_lines] @template, @errorLine, 6;
				
				RAISERROR(N'WARNING: Backup and/or cleanup of CERT (backup) did NOT complete correctly. ', 16, 1);
				RETURN -200;	
			END CATCH;
		END;
	END;

	RETURN 0;
GO