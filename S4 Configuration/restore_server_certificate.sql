/*
	vNEXT: 
		Enable @CreateOnPartner functionality - via CERTENCODED: https://docs.microsoft.com/en-us/sql/t-sql/functions/certencoded-transact-sql?view=sql-server-ver15



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.restore_server_certificate','P') IS NOT NULL
	DROP PROC dbo.[restore_server_certificate];
GO

CREATE PROC dbo.[restore_server_certificate]
	@OriginalCertificateName						sysname			= NULL, 
	@CertificateAndKeyRootDirectory					sysname			= NULL,			-- {DEFAULT} is supported - i.e., for .cer/.key files dropped into default backups root.
	@PrivateKeyEncryptionPassword					sysname			= NULL,	
	@MasterKeyEncryptionPassword					sysname			= NULL,
	@OptionalNewCertificateName						sysname			= NULL, 
	@FullCertificateFilePath						sysname			= NULL,			-- specific/direct paths if @CertificateAndKeyRootDirectory needs to be overridden.
	@FullKeyFilePath								sysname			= NULL,			-- ditto.
	--@RestoreOnPartner								bit				= 0, 
	@PrintOnly										bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @OriginalCertificateName = NULLIF(@OriginalCertificateName, N'');
	SET @CertificateAndKeyRootDirectory = NULLIF(@CertificateAndKeyRootDirectory, N'');
	SET @PrivateKeyEncryptionPassword = NULLIF(@PrivateKeyEncryptionPassword, N'');

	SET @MasterKeyEncryptionPassword = NULLIF(@MasterKeyEncryptionPassword, N'');
	SET @OptionalNewCertificateName = NULLIF(@OptionalNewCertificateName, N'');
	SET @FullCertificateFilePath = NULLIF(@FullCertificateFilePath, N'');
	SET @FullKeyFilePath = NULLIF(@FullKeyFilePath, N'');
	
	--SET @RestoreOnPartner = ISNULL(@RestoreOnPartner, 0);
	SET @PrintOnly = ISNULL(@PrintOnly, 0);

	DECLARE @certFileFullPath sysname;
	DECLARE @keyFileFullPath sysname;

	IF @FullCertificateFilePath IS NOT NULL AND @FullKeyFilePath IS NULL OR @FullKeyFilePath IS NOT NULL AND @FullCertificateFilePath IS NULL BEGIN 
		RAISERROR('When specifying explicit/full-path details for .cer and .key files both @FullCertificateFilePath and @FullKeyFilePath must BOTH be specified.', 16, 1);
		RETURN -1;
	END;

	-- there are 2x ways to 'find' the .cer and .key - full-blown file-paths or S4 convention of {backupPath}\{certname}.{extension}
	IF @FullCertificateFilePath IS NOT NULL AND @FullKeyFilePath IS NOT NULL BEGIN 
		
		SET @certFileFullPath = dbo.normalize_file_path(@FullCertificateFilePath);
		SET @keyFileFullPath = dbo.normalize_file_path(@FullKeyFilePath);

	  END;
	ELSE BEGIN 
		IF @OriginalCertificateName IS NULL BEGIN 
			RAISERROR(N'@OriginalCertificateName is required - and, by S4 convention, should match the name of the original/source certificate.', 16, 1);
			RETURN -2;
		END; 

		IF UPPER(@CertificateAndKeyRootDirectory) = N'{DEFAULT}' BEGIN 
			SELECT @CertificateAndKeyRootDirectory = dbo.load_default_path('BACKUP');
		END;

		IF @CertificateAndKeyRootDirectory IS NULL BEGIN 
			RAISERROR(N'@CertificateAndKeyRootDirectory and should point to the directory where your {@OriginalCertificateName}.cer and .key files are stored.', 16, 1);
			RETURN -3;
		END;

		SET @certFileFullPath = @CertificateAndKeyRootDirectory + N'\' + @OriginalCertificateName + N'.cer';
		SET @keyFileFullPath = @CertificateAndKeyRootDirectory + N'\' + @OriginalCertificateName + N'_PrivateKey.key'

	END;

	IF @PrivateKeyEncryptionPassword IS NULL BEGIN 
		RAISERROR(N'@PrivateKeyEncryptionPassword is required - and should be the password defined for protection of your certificate''s .key file.', 16, 1);
		RETURN -20;
	END;

	-- Verify that Cer and Key files exist:
	DECLARE @exists bit;

	EXEC dbo.[check_paths] 
		@Path = @certFileFullPath, 
		@Exists = @exists OUTPUT;
	
	IF @exists = 0 BEGIN 
		RAISERROR(N'The .cer file path specified (%s) is invalid or does not exist.', 16, 1, @certFileFullPath);
		RETURN -21;
	END;

	EXEC dbo.[check_paths] 
		@Path = @keyFileFullPath, 
		@Exists = @exists OUTPUT;

	IF @exists = 0 BEGIN 
		RAISERROR(N'The .key file path specified (%s) is invalid or does not exist.', 16, 1, @keyFileFullPath);
		RETURN -21;
	END;

	-- verify that target cert name does not already exist: 
	DECLARE @certName sysname = ISNULL(@OptionalNewCertificateName, @OriginalCertificateName);

	IF EXISTS (SELECT NULL FROM [master].sys.[certificates] WHERE [name] = @certName) BEGIN 
		RAISERROR(N'Target certificate name ''%s'' already exists on server.', 16, 1, @certName);
		RETURN 0;
	END;


	-----------------------------------------------------------------------------
	-- Verify Master Key Encryption:
	-- DRY_VIOLATION: the code below exists here and in dbo.create_server_certificate:
	IF NOT EXISTS (SELECT NULL FROM master.sys.[symmetric_keys] WHERE [symmetric_key_id] = 101) BEGIN 
		
		IF @MasterKeyEncryptionPassword IS NULL BEGIN 
			RAISERROR(N'Master Key Encryption has not yet been defined (in the [master] databases). Please supply a @MasterKeyEncryptionPassword.', 16, 1);
			RETURN -8;
		END;

		DECLARE @command nvarchar(MAX) = N'USE [master];

IF NOT EXISTS (SELECT NULL FROM master.sys.symmetric_keys WHERE symmetric_key_id = 101) BEGIN;
	CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''' + @MasterKeyEncryptionPassword + N''';
END;
';
		IF @PrintOnly = 1
			PRINT @command; 
		ELSE 
			EXEC sp_executesql @command;

	END;


	DECLARE @template nvarchar(MAX) = N'USE [master];

CREATE CERTIFICATE [{certName}] 
FROM 
	FILE = ''{certFile}''
WITH 
	PRIVATE KEY (
		FILE = ''{keyFile}'',
		DECRYPTION BY PASSWORD = ''{password}''
	);
';

	DECLARE @sql nvarchar(MAX) = @template;
	SET @sql = REPLACE(@sql, N'{certName}', @certName);
	SET @sql = REPLACE(@sql, N'{certFile}', @certFileFullPath);
	SET @sql = REPLACE(@sql, N'{keyFile}', @keyFileFullPath);
	SET @sql = REPLACE(@sql, N'{password}', @PrivateKeyEncryptionPassword);


	DECLARE @outcome nvarchar(MAX);
	BEGIN TRY 
		IF @PrintOnly = 1
			PRINT @sql;
		ELSE 
			EXEC sp_executesql @sql;

	END TRY
	BEGIN CATCH
		SELECT @outcome = ERROR_MESSAGE();
		RAISERROR(N'Unexpected Error executing CREATE CERTFICATE from FILE + PRIVATE KEY FILE. Error: %s', 16, 1, @outcome);
		RETURN -40;
	END CATCH;

	RETURN 0;
GO