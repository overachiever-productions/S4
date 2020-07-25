/*
	vNEXT: check for existence of .cer and .key files in @BackupDirectory and @CopyToBackupDirectory
			this'll require that I 'build' those paths + names as @variables and check for their existence (nothing terrible). 
			Otherwise, until then, attempting to write to existing files throws an exception from within BACKUP CERTIFICATE statement - which is fine-ish. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.backup_server_certificate','P') IS NOT NULL
	DROP PROC dbo.[backup_server_certificate];
GO

CREATE PROC dbo.[backup_server_certificate]
	@CertificateName					sysname							= NULL,
	@BackupDirectory					nvarchar(2000)					= N'{DEFAULT}',					
	@CopyToBackupDirectory				nvarchar(2000)					= NULL,	
	@EncryptionKeyPassword				sysname, 
	@PrintOnly							bit								= 0 
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @CertificateName = NULLIF(@CertificateName, N'');
	SET @BackupDirectory = NULLIF(@BackupDirectory, N'');
	SET @CopyToBackupDirectory = NULLIF(@CopyToBackupDirectory, N'');
	SET @EncryptionKeyPassword = NULLIF(@EncryptionKeyPassword, N'');

	SET @PrintOnly = ISNULL(@PrintOnly, 0);

	IF @CertificateName IS NULL BEGIN 
		RAISERROR(N'@CertificateName is Required.', 16, 1);
		RETURN -1;
	END;

	-- verify that cert exists:
	IF NOT EXISTS (SELECT NULL FROM master.sys.[certificates] WHERE [name] = @CertificateName) BEGIN
		RAISERROR(N'@CertificateName of ''%s'' was not found in [master] database. Please check your input and try again.', 16, 1, @CertificateName);
		RETURN -2;
	END;

	-- Note: couldn't find calls to the internal logic that SQL Server uses to enforce/check password complexity - or it'd be 'fun' to run @EncryptionKeyPassword through that prior to attempting BACKUP... 
	IF @EncryptionKeyPassword IS NULL BEGIN 
		RAISERROR(N'@EncryptionKeyPassword is Required - and is used to secure/protect access to private-key details when persisted to disk as a .cer + .key file.', 16, 1);
		RETURN -5;
	END;

	IF UPPER(@BackupDirectory) = N'{DEFAULT}' BEGIN 
		SELECT @BackupDirectory = dbo.load_default_path('BACKUP');
	END;
	
	IF @BackupDirectory IS NULL BEGIN 
		RAISERROR(N'@BackupDirectory is Required.', 16, 1);
		RETURN -10;
	END;

	-- normalize paths: 
	IF(RIGHT(@BackupDirectory, 1) = N'\')
		SET @BackupDirectory = LEFT(@BackupDirectory, LEN(@BackupDirectory) - 1);

	IF(RIGHT(ISNULL(@CopyToBackupDirectory, N''), 1) = N'\')
		SET @CopyToBackupDirectory = LEFT(@CopyToBackupDirectory, LEN(@CopyToBackupDirectory) - 1);

	
    DECLARE @outcome nvarchar(MAX) = NULL;
	BEGIN TRY
        EXEC dbo.establish_directory
            @TargetDirectory = @BackupDirectory, 
            @PrintOnly = @PrintOnly,
            @Error = @outcome OUTPUT;

		IF @outcome IS NOT NULL BEGIN
			RAISERROR('Invalid Directory detected for @BackupDirectory. Error Message: %s', 16, 1, @outcome);
			RETURN -20;
		END;

		IF @CopyToBackupDirectory IS NOT NULL BEGIN
			SET @outcome = NULL;
			EXEC dbo.establish_directory
				@TargetDirectory = @CopyToBackupDirectory, 
				@PrintOnly = @PrintOnly,
				@Error = @outcome OUTPUT;

			IF @outcome IS NOT NULL BEGIN
				RAISERROR('Invalid Directory detected for @CopyToBackupDirectory. Error Message: %s', 16, 1, @outcome);
				RETURN -20;
			END;
		END;

	END TRY 
	BEGIN CATCH
		SELECT @outcome = ERROR_MESSAGE();
		RAISERROR(N'Unexpected Error verifying Backup Directory Target(s). Error: %s', 16, 1, @outcome);
		RETURN -30;
	END CATCH;
			
	-----------------------------------------------------------------------------
	-- Process Backup Operation: 
	DECLARE @template nvarchar(MAX) = N'USE [master];

BACKUP CERTIFICATE [' + @CertificateName + N']
TO FILE = N''{BackupPath}\' + @CertificateName + N'.cer''
WITH PRIVATE KEY (
	FILE = N''{BackupPath}\' + @CertificateName + N'_PrivateKey.key'', 
	ENCRYPTION BY PASSWORD = N''' + @EncryptionKeyPassword + N'''
);
';

	DECLARE @command nvarchar(MAX) = @template; 
	SET @command = REPLACE(@template, N'{BackupPath}', @BackupDirectory);

	BEGIN TRY 

		IF @PrintOnly = 1 
			PRINT @command; 
		ELSE 
			EXEC sp_executesql @command; 

	END TRY
	BEGIN CATCH 
		SELECT @outcome = ERROR_MESSAGE(); 
		RAISERROR('Unexpected error executing BACKUP CERTIFICATE against @BackupDirectory. Error Message: %s', 16, 1, @outcome);
		RETURN -40;
	END CATCH

	IF @CopyToBackupDirectory IS NOT NULL BEGIN 
		BEGIN TRY 
			SET @command = @template;
			SET @command = REPLACE(@template, N'{BackupPath}', @CopyToBackupDirectory);

			IF @PrintOnly = 1 
				PRINT @command; 
			ELSE 
				EXEC sp_executesql @command; 

		END TRY 
		BEGIN CATCH
			SELECT @outcome = ERROR_MESSAGE(); 
			RAISERROR('Unexpected error executing BACKUP CERTIFICATE against @CopyToBackupDirectory. Error Message: %s', 16, 1, @outcome);
			RETURN -41;
		END CATCH;
	END;

	RETURN 0;
GO