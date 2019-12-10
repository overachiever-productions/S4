

/*

	OVERVIEW
		- See "CREATE backup certificate.sql" for reasons why this file/process exists. 

	REQUIREMENTS
		In order to restore a backup certificate (to a new machine or to the same/old machine after a disaster/repave/whatever), you will need:

			- The backup of the certificate file (i.e., a .cer file) with backup certificate details. 
			- The decryption key file (used to encrypt details of the .cer file while 'at rest'). 
			- The decryption key PASSWORD (the password used to decrypt the decyption key (which, in turn, decrypts the cert)). 

			- A Master Key on the server you're deploying/restoring this certificate to. (This script will help you create one if/as needed.)
				NOTE: You do NOT need the SAME master key cert on 'this' box as your 'source' box. Instead, you just need 'a' master key in place
					to handle certificate signing needs at the server level.

	NOTE:
		the _NAME_ of the certificate does NOT have to be an exact match. 
		Specifically,
			- you can create a cert called EncryptedBackupsCert on ServerXyz for production usage/etc. 
			- then back that cert up as EncryptedBackupsCert.cer + .key etc... (and, obviously, file names don't need to match cert names). 
			- then RESTORE the EncryptedBackupsCert as, say: [ServerXyzProd_EncryptedBackupsThingy] on a smoke and rubble/failover server and you'll be 'just fine' (in the sense that you'll be able to restore backups on this other/secondary server without issues). 
		ALL of that said, it's recommended to use the SAME name for this important piece of infrastructure across ALL machines in your topology/environment.

	INSTRUCTIONS
		1. copy the .cer and .key files associated with your certificate export/backup to a location (path) accessible to the target server. 
		2. CTRL+SHIFT+M to replace all parameters in the following script - including: 
			
				- the password for a NEW master key (if needed). (NOTE: you don't REALLY need to know or remember this password in _MOST_ environments.)
				- the path/location where your .key and .cer files are (by convention within this script, this path and the path to your SQL Server database backups will be the SAME). 
				- a password - used to create a NEW Master Key - if one is not already in place. 
				- the NAME of the certificate you're restoring/deploying (by CONVENTION, the .cer and .key files used for backup purposes will be <CERTNAME>.cer and <CERTNAME>_private.key - so change these details if/as needed). 
				- the decryption password for the .cer's .key file. 

		3. Once all parameters have been specified, double-check that all paths, file-names, and other details look as expected. 
		4. Run this script to create/restore your backup certificate. 
		
		OPTIONAL:
		5. If you wish to create a copy of your local Master Key:
			- un-comment the BACKUP MASTER KEY commands (i.e., 2 lines) in the section of this script that creates a master key IF needed... 
			- set/specify a password that will be used to DECRYPT your Master Key backup. 
			- run just the 2 lines associated with the backup process 
			- make sure to KEEP the password for this master key backup safe/secure (otherwise there's NO point in having a backup of the master key).



*/



USE [master];
GO

--------------------------------------------------------------------------------------------------------------------
-- Create a Master Key if it does NOT exist:
IF NOT EXISTS (SELECT NULL FROM master.sys.symmetric_keys WHERE symmetric_key_id = 101) BEGIN;
	
	-- create the key:
	CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<masterKeyPassword, sysname, xxxxx>';

	-- Back up the master key (which needs to be done by means of using a password).
	--BACKUP MASTER KEY TO FILE = N'<certBackupsPath, sysname, D:\SQLBackups>\master_database_master_key.cer'
	--	ENCRYPTION BY PASSWORD = 'decryption password goes here'; 
		

END;

--------------------------------------------------------------------------------------------------------------------
-- Restore the Backup Encryption Certificate: 
CREATE CERTIFICATE [<backupCertName, sysname, EncryptedBackupsCertificate>]
	FROM FILE = N'<certBackupsPath, sysname, D:\SQLBackups>\<certFileNamePattern, sysname, CertFileName>.cer'
	WITH PRIVATE KEY (
		FILE = N'<certBackupsPath, sysname, D:\SQLBackups>\<certFileNamePattern, sysname, CertFileName>_PrivateKey.key', 
		DECRYPTION BY PASSWORD = '<backupCertEncryptionPassword, sysname, xxxxxx>'
	);
GO