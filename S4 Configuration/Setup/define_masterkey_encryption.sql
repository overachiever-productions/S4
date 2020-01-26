/*

	vNEXT: Option to 'overwrite' (but with warnings about what it'll trash/force-to-repave).

	vNEXT: allow {DEFAULT} 
		for @BackupPath ... er... well... 
			that could work. 
				but i guess what I'd really, sigh, like is {DEFAULT}\certs ... which... meh... 


	-- DROP MASTER KEY; 
	--	make sure to run the above in the MASTER db.. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.define_masterkey_encryption','P') IS NOT NULL
	DROP PROC dbo.[define_masterkey_encryption];
GO

CREATE PROC dbo.[define_masterkey_encryption]
	@MasterEncryptionKeyPassword		sysname		= NULL, 
	@BackupPath							sysname		= NULL, 
	@BackupEncryptionPassword			sysname		= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@BackupPath, N'') IS NOT NULL BEGIN 
		IF NULLIF(@BackupEncryptionPassword, N'') IS NULL BEGIN 
			RAISERROR('Backup of Master Encryption Key can NOT be done without specifying a password (you''ll need this to recover the key IF necessary).', 16, 1);
			RETURN -2;
		END;

		DECLARE @error nvarchar(MAX);
		EXEC dbo.[establish_directory] 
			@TargetDirectory = @BackupPath, 
			@Error = @error OUTPUT;
		
		IF @error IS NOT NULL BEGIN
			RAISERROR(@error, 16, 1);
			RETURN - 5;
		END;
	END;

	IF NULLIF(@MasterEncryptionKeyPassword, N'') IS NULL 
		SET @MasterEncryptionKeyPassword = CAST(NEWID() AS sysname);
	
	DECLARE @command nvarchar(MAX);
	IF NOT EXISTS (SELECT NULL FROM master.sys.[symmetric_keys] WHERE [symmetric_key_id] = 101) BEGIN 
		SET @command = N'USE [master]; CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''' + @MasterEncryptionKeyPassword + N'''; ';

		EXEC sp_executesql @command;

		PRINT 'MASTER KEY defined with password of: ' + @MasterEncryptionKeyPassword
	  
		IF NULLIF(@BackupPath, N'') IS NOT NULL BEGIN 
			-- TODO: verify backup location. 
		
			DECLARE @hostName sysname; 
			SELECT @hostName = @@SERVERNAME;

			SET @command = N'USE [master]; BACKUP MASTER KEY TO FILE = N''' + @BackupPath + N'\' + @hostName + N'_Master_Encryption_Key.key''
				ENCRYPTION BY PASSWORD = ''' + @BackupEncryptionPassword + N'''; '; 

			EXEC sp_executesql @command;

			PRINT 'Master Key Backed up to ' + @BackupPath + N' with Password of: ' + @BackupEncryptionPassword;
		END;	  
	  
	  RETURN 0;

	END; 

	-- otherwise, if we're still here... 
	PRINT 'Master Key Already Exists';	

	RETURN 0;
GO