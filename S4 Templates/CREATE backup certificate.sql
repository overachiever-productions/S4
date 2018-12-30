

/*
	
	WARNINGS:
		- Once your backups are encrypted you CANNOT restore them to ANY other server WITHOUT a duplicate/copy of the Certificate
			used to encrypt your backups. Please read all instructions BEFORE execution/usage.

	DEPENDENCIES:
		- SQL Server 2014+
		- SQL Server Standard Edition or Enterprise Edition (encypted backups NOT supported on Web or Express).


	INSTRUCTIONS:
		- If your server doesn't already have a Master Key for the master DB, this script will create one AND back it up for you. 
			but, to do that, you'll need to specify the password that is used to encrypt all sensitive info on your server (i.e., create the master key)
			AND as part of the backup process, you'll need to specify a password that can be used to DECRYPT the encrypted backup that is... your private key. 

		- Otherwise, this script will create a Backups Certificate and then back it up to disk in the form of a Private Key file
			AND a password that protects the contents of that Private Key. You'll need both the Private Key file + password to be able to restore
				this certificate to your server (if there's a major crash) or to OTHER servers. 


		- In short, the order of operations here is to do the following: 
			1. Come up with a simple/short phrase to be used to 'start' encryption within your database - i.e., a master key. 
			2. Come up with a password/pass-phrase that will be used to encrypt the contents of your Private Key file. 
				(Anyone who has your private key file (if there were NOT a password) would be able to then create a cert that would let them restore your 
					backups, as such the password for the Private Key file is to PROTECT your backups and your Encryption Keys). 

			3. Come up with a path where you'll write out all backup keys/certs. 
			4. Replace all parameters below (CTRL+SHIFT+M or use the Query > Specify Values for Template Parameters menu option)
			5. Execute the script below. 
			6. Disaster Protection:
				- COPY/PASTE a copy of the final script in this file (i.e., the CREATE CERTIFICATE statement) and put it plus copies 
					of the .cer file(s) and .key files created into a safe location. 

				- Further, keep the password for your Master Key + for the Private Key with this info
					
				- And keep them all in a safe and secured location. 

				- You WILL need these details in the case of a disaster. And without them, all of your databases backed up by the certs 
					you create here will NOT be recoverable - at all. Period.		

*/





USE [master];
GO

--------------------------------------------------------------------------------------------------------------------
-- Create a Master Key if it does NOT exist:
IF NOT EXISTS (SELECT NULL FROM master.sys.symmetric_keys WHERE symmetric_key_id = 101) BEGIN;
	
	-- create the key:
	CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<masterKeyPassword, sysname, xxxxx>';

	-- Back up the master key (which needs to be done by means of using a password).
	BACKUP MASTER KEY TO FILE = N'<certBackupsPath, sysname, D:\SQLBackups>\master_database_master_key.cer'
		ENCRYPTION BY PASSWORD = N'<masterKeyBackupPassword, sysname, xxxxxxx>'; 

		-- NOTE that backing up the master key is not 100% required for native backup encryption - it's always just a good idea. 

END;

--------------------------------------------------------------------------------------------------------------------
-- Create a Backp Certificate:
CREATE CERTIFICATE [<backupCertName, sysname, EncryptedBackupsCertificate>]
	WITH SUBJECT = N'"<backupCertSubject, sysname, xxxxx>"', 
	EXPIRY_DATE = N'20401231';  -- December 31, 2040... 
GO

BACKUP CERTIFICATE [<backupCertName, sysname, EncryptedBackupsCertificate>]
	TO FILE = N'<certBackupsPath, sysname, D:\SQLBackups>\<backupCertName, sysname, EncryptedBackupsCertificate>.cer'
	WITH PRIVATE KEY (
		FILE = N'<certBackupsPath, sysname, D:\SQLBackups>\<backupCertName, sysname, EncryptedBackupsCertificate>_private.key', 
		ENCRYPTION BY PASSWORD = N'<backupCertEncryptionPassword, sysname, xxxxxx>'
	);
GO


SELECT N'COPY the .cer and .key files in [<certBackupsPath, sysname, D:\SQLBackups>] to a safe (off-box) location AND keep all associated certificate backup/decryption passwords SECURE (and, ideally, audited).' [!!!!WARNING!!!!];
GO

/*

	At this point, encrypted backups are now possible using admindb.dbo.backup_databases - or via the syntax below: 


			BACKUP DATABASE admindb TO DISK = N'D:\SQLBackups>\admindb\admindb_encryption_test.bak'
			WITH 
				COMPRESSION, 
				ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [<backupCertName, sysname, EncryptedBackupsCertificate>]), 
				STATS = 10;
			GO


	HOWEVER, encrypted backups can NOT be restored on any other (i.e., different) server UNLESS the certificate used for these backups
		has been restored (deployed) to the target server before hand. (i.e., you can restore to 'this' server no problem - but you can't 
		restore backups to a new/different server unless the same cert that exists on this server has been deployed THERE first).

		To address the task of restoring / deploying a certificate, see the accompanying "RESTORE backup certificate.sql" file... 

*/
