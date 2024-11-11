/*

	vNEXT: 
		Enable @CreateOnPartner functionality - via CERTENCODED: https://docs.microsoft.com/en-us/sql/t-sql/functions/certencoded-transact-sql?view=sql-server-ver15


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[create_server_certificate]', N'P') IS NOT NULL
	DROP PROC dbo.[create_server_certificate];
GO

CREATE PROC dbo.[create_server_certificate]
	@MasterKeyEncryptionPassword		sysname					= NULL,
	@CertificateName					sysname					= NULL,
	@CertificateSubject					sysname					= NULL,
	@CertificateExpiryVector			sysname					= N'10 years',
	--@CreateOnPartner					bit						= 0,
	@BackupDirectory					nvarchar(2000)			= NULL, -- if this and @EncKey are non-null, we'll execute a backup... 
	@CopyToBackupDirectory				nvarchar(2000)			= NULL,	
	@EncryptionKeyPassword				sysname					= NULL, 
	@PrintOnly							bit						= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @MasterKeyEncryptionPassword = NULLIF(@MasterKeyEncryptionPassword, N'');
	SET @CertificateName = NULLIF(@CertificateName, N'');
	SET @BackupDirectory = NULLIF(@BackupDirectory, N'');
	SET @CopyToBackupDirectory = NULLIF(@CopyToBackupDirectory, N'');
	SET @EncryptionKeyPassword = NULLIF(@EncryptionKeyPassword, N'');
	SET @CertificateSubject = NULLIF(@CertificateSubject, N'');

	SET @BackupDirectory = ISNULL(@BackupDirectory, N'{DEFAULT}');
	SET @CertificateExpiryVector = ISNULL(@CertificateExpiryVector, N'10 years');
	SET @PrintOnly = ISNULL(@PrintOnly, 0);
	--SET @CreateOnPartner = ISNULL(@CreateOnPartner, 0);
	
	IF @CertificateName IS NULL BEGIN 
		RAISERROR('@CertificateName is Required.', 16, 1);
		RETURN -1;
	END; 

	IF @CertificateSubject IS NULL BEGIN 
		RAISERROR('@CertificateSubject is required. Please provide a simple description of this certificate''s purpose.', 16, 1);
		RETURN -2;
	END;

	-- verify that cert does not exist:
	IF EXISTS (SELECT NULL FROM master.sys.[certificates] WHERE [name] = @CertificateName) BEGIN
		RAISERROR(N'@CertificateName of ''%s'' already exists in the [master] database.', 16, 1, @CertificateName);
		RETURN -5;
	END;

	-- translate expiry: 
	DECLARE @certExpiry datetime;
	DECLARE @vectorError nvarchar(MAX);
	EXEC dbo.[translate_vector_datetime]
		@Vector = @CertificateExpiryVector, 
		@Operation = N'ADD', 
		@ValidationParameterName = N'@CertificateExpiryVector', 
		@ProhibitedIntervals = N'BACKUP, SECOND', 
		@Output = @certExpiry OUTPUT, 
		@Error = @vectorError OUTPUT;

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -26;
	END;

	DECLARE @command nvarchar(MAX);

	-----------------------------------------------------------------------------
	-- Verify Master Key Encryption:
	IF NOT EXISTS (SELECT NULL FROM master.sys.[symmetric_keys] WHERE [symmetric_key_id] = 101) BEGIN 
		
		IF @MasterKeyEncryptionPassword IS NULL BEGIN 
			RAISERROR(N'Master Key Encryption has not yet been defined (in the [master] databases). Please supply a @MasterKeyEncryptionPassword.', 16, 1);
			RETURN -8;
		END;

		SET @command = N'USE [master];

IF NOT EXISTS (SELECT NULL FROM master.sys.symmetric_keys WHERE symmetric_key_id = 101) BEGIN;
	CREATE MASTER KEY ENCRYPTION BY PASSWORD = N''' + @MasterKeyEncryptionPassword + N''';
END;
';
		IF @PrintOnly = 1
			PRINT @command; 
		ELSE 
			EXEC sp_executesql @command;
	END;

	DECLARE @outcome nvarchar(MAX);

	SET @command = N'USE [master];
CREATE CERTIFICATE [' + @CertificateName + N']
WITH 
	SUBJECT = N''"' + @CertificateSubject + N'"'', 
	EXPIRY_DATE = ''' + CONVERT(sysname, @certExpiry, 23) + N''';
';

	BEGIN TRY 
		IF @PrintOnly = 1 
			PRINT @command; 
		ELSE 
			EXEC sp_executesql @command;

	END TRY
	BEGIN CATCH
		SELECT @outcome = ERROR_MESSAGE();
		RAISERROR(N'Unexpected Error executing CREATE CERTFICATE. Error: %s', 16, 1, @outcome);
		RETURN - 10;
	END CATCH;

	IF @BackupDirectory IS NOT NULL AND @EncryptionKeyPassword IS NOT NULL BEGIN 
		IF @PrintOnly = 1 BEGIN 
			
			PRINT N'';
			PRINT N'------------------------------------------------------------------------------------------------';
			PRINT N'-- Skipping Certificate Backup (because @PrintOnly = 1). However, command WOULD look similar to: ';

			DECLARE @backup nvarchar(MAX) = N'EXEC dbo.[backup_server_certificate]
	@CertificateName = N''' + @CertificateName + N''',
	@BackupDirectory = N''' + @BackupDirectory + ''',
	--@CopyToBackupDirectory = @CopyToBackupDirectory,
	@EncryptionKeyPassword = N''' + @EncryptionKeyPassword + N''',
	@PrintOnly = 1; ';

			EXEC dbo.[print_long_string] @backup;

			PRINT N'------------------------------------------------------------------------------------------------';

		  END; 
		ELSE BEGIN
			EXEC dbo.[backup_server_certificate]
				@CertificateName = @CertificateName,
				@BackupDirectory = @BackupDirectory,
				@CopyToBackupDirectory = @CopyToBackupDirectory,
				@EncryptionKeyPassword = @EncryptionKeyPassword,
				@PrintOnly = @PrintOnly;
		END;
	  END;
	ELSE BEGIN 
		RAISERROR('WARNING: Please use admindb.dbo.backup_server_certificate to create a backup of %s - to protect against disasters.', 6, 1, @CertificateName)
	END;

	-- vNEXT: if @CreateOnPartner.... 

	RETURN 0; 
GO