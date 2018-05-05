# TDE Recommendations and Setup

## Official Microsoft Documentation

Primary Documentation for Transparent Data Encryption (TDE) can be found here:

https://docs.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption?view=sql-server-2017

***NOTE:** TDE is an Enterprise Edition ONLY feature.*

## Key Considerations and Warnings

### - Encryption / Decryption and Data Safety
Decryption of encrypted databases is obviously IMPOSSIBLE without access to the proper encryption/decryption certificates (and associated keys). 

As such, setting up TDE should always, consist of the following, high-level, steps or considerations:
* Full Documentation of the STEPS and security details used during setup (i.e., creation of certificates and keys).
* A completed, documented, backup (and safe-keeping) of the certificates used for encryption. 
* An immediate test/validation that TDE encrypted backups can be SAFELY restored on an additional server (to validate disaster recovery needs). 

### - Size of Data Operations 
Encryption is a size of data operation. 

Once a database is flagged for encryption (or decryption - i.e., removal of TDE), all 'disk space' and storage used by the database will become encrypted/decrypted. 
This is handled by background threads that do a decent job of 'yielding' to other, concurrent operations on the server. 

To avoid potentially overloading your hardware when encrypting/decrypting:
* Try to encrypt/decrypt during off-peak hours if/when possible. 
* When possible, encrypt/decrypt databases one at a time (i.e., in serial fashion) to avoid the potential for stress on CPUs and the IO subsystem. 

You can monitor the encryption/decryption process's overall progress by monitoring the **[percent_completed]** column in the following query: 

```sql
SELECT * FROM sys.dm_database_encryption_keys;
```

### - tempdb Considerations
Because SQL Server databases can/will use the tempdb as a 'scratch' location where data can be 'spilled', once a SINGLE database on a server becomes encrypted (via TDE), the tempdb will AUTOMATICALLY become encrypted as well - so that any data 'spilled' to this database (and backed by disk) will be encrypted at rest. 

In MOST environments this will not be a problem. But, in situations where queries and/or other operations are commonly spilling/dumping LARGE amounts of data into the tempdb as a part of normal processing and/or on servers with high volume workloads.

### - 'Encryption at Rest' and 'Encryption in Flight'
If encryption at rest is needed as a safegaurd, it's highly likely that encryption in flight will also be needed - meaning that communications between your SQL Server and app servers should also be encrypted. 

To encrypt all communications to/from your SQL Server: 

#### 1. Update Patch SQL Server to the latest SP/CU - as TLS 1.2 support was 'back-added' to many 'earlier' versions of SQL Server. 

For a list of all versions/releases (SPs and CUs included) of SQL Server, see: 

http://sqlserverbuilds.blogspot.com/


For a 'matrix' of TLS 1.2 supported versions of SQL Server, see:

https://support.microsoft.com/en-us/help/3135244/tls-1-2-support-for-microsoft-sql-server


#### 2. Ensure that Client Applications can support TLS 1.2 connectivity. 
Client applications may need to be updated to support TLS 1.2. 

For a list of known/available drivers, libraries, and other updated patches to support TLS 1.2 communications to SQL Server, see: 

https://support.microsoft.com/en-us/help/3135244/tls-1-2-support-for-microsoft-sql-server

Note that even older versions of the CLR (.NET) will need updates as well: 

https://support.microsoft.com/en-us/help/3154520/support-for-tls-system-default-versions-included-in-the-net-framework

#### 3. Restrict the Host (Windows) Operating System to reject non-TLS 1.2 connections 
To ensure that non-secure encryption protocols can NOT be used in connecting to your SQL Server (i.e., TLS 1.0 and lower - along with older 'SSL' protocols), you need to instruct your server/OS to ONLY allow TLS 1.2 connections. Otherwise, part of the SQL Server login/authentication process WILL negotiate a connection over a LOWER (vulnerable) encryption protocol IF the client application attempting a connection does NOT support TLS 1.2. 

Making this change to a Windows OS is managed by means of registry changes - documented here: 

https://support.microsoft.com/en-us/help/245030/how-to-restrict-the-use-of-certain-cryptographic-algorithms-and-protoc

#### 4. Determine which type of Certificate to use for encrypted communications 
Server/Encryption Certificates are used for two primary purposes - a) encrypting communications and, b) authenticating the target endpoint (i.e., making sure the server that applications are connecting to is actually the server that it 'claims' to be - by means of a 'trust' chain defined as part of the certificate's signature). 

For environments that REQUIRE server-authentication a certificate will have to either be obtained internally via a Certificate Signing Authority - or through an external, third, party (i.e., COMMODO or some other x509 certificate 'vendor'). 

For environments that ONLY want/need encryption of data in flight (and don't need server validation/verification via a certificate chain), SQL Server can be instructed to create a self-signed certificate upon startup - which is then used to encrypt communications in/out of the server. (Though, unless you disable access to the host OS by anything less than, say, TLS 1.2 clients, client applications COULD negotiate a secured connection by means of, say, SSL 3 or some other outdated/vulnerabile protocol.)

If you opt to use a self-signed certificate, you're deciding that applications don't need to 'verify' that they're actually 'talking to' your SQL Server (instead of a 'rogue box' that some hacker/disgruntleed worker has managed to stand-up 'in place' of your target Servers IP/HostName). Likewise, some OLDER connectivity libraries and protocols MAY have problems connecting to a self-signed certificate unless/until you can (typically) find a way to tell the application/connection to allow/trust certificates regardless of their origin. 

If you use a signed certificate, the following documentation lists the requirements for the certificate you'll need to procure: 

https://support.microsoft.com/en-us/help/245030/how-to-restrict-the-use-of-certain-cryptographic-algorithms-and-protoc

Likewise, the following links provide insights into SOME of the common pitfalls and problems you can run into when 'installing' a server certificate for SQL Server: 

https://www.mssqltips.com/sqlservertip/3408/how-to-troubleshoot-ssl-encryption-issues-in-sql-server/

https://stackoverflow.com/questions/36817627/ssl-certificate-missing-from-dropdown-in-sql-server-configuration-manager

https://serverfault.com/questions/532167/associate-ssl-certificate-for-sql-server-which-does-not-use-the-fqdn


#### 5. Testing PRIOR to making Production Changes
Before attempting any of the changes listed above (or below) in production, you'll need to stand up a test/staging environment where you can duplicate your production system, make the changes indicated above (and below) and then verify that test/sample applications and clients can connect. 

Most applications have no problem connecting to TLS 1.2-only endpoints (once they've been updated) - but the ONLY way to know for sure is to thoroughly test. 

#### 6. Forcing SQL Server to Encrypt Communications 
Once you've determined which kind of certificate you're going to use (self-signed or 'trusted'), you'll need to instruct you SQL Server to FORCE encrypted communications - to ensure that all client applications connecting to your server are encrypted (instead of letting apps 'decide' if they want encryption or not). 

To do this, log into your host SQL Server, and open then SQL Server Configuration Manager, then navigate to the Properties pane of the Protocols for MSSQLSERVER node (or your instance's name) as shown in the screenshot below:

![](https://git.overachiever.net/content/images/s4_doc_images/tde_server_config_manager.gif)

Then, if you're using a non-self-signed certificate, you'll need to configure certificate information in the 'Certificate' tab of the Properties pane. Or, if you're using a self-signed certificate you can simply SKIP that step (entirely). 

Then, when you're ready to force encryption, simply switch 'Force Encryption' to 'Yes' and click OK. 

![](https://git.overachiever.net/content/images/s4_doc_images/tde_force_encryption.gif)

SQL Server will warn you that the change (to forcing encryption or REMOVING that enforcement) will NOT take effect until you restart the SQL Server Service.

When you're ready to force encryption, restart your SQL Server Service: 

![](https://git.overachiever.net/content/images/s4_doc_images/tde_restart_service.gif)

NOTES: 
* If you're on a CLUSTERED SQL Server, [the process looks like? ]
* On HEAVILY used systems (with lots of RAM allocated/used), it can take a while for the SQL Server service to 'dump' all RAM as part of the restart. (You can 'coax' your service to a quicker restart by dumping the Procedure Cache and dropping all (clean) buffers - but doing so should only be done during periods of non-peak (i.e., slow/minimal) load.)
* If you're using a Mirrored or AG'd (Availability Group'd) configuration, executing a FAILOVER is commonly going to be a better option than restarting your SQL Server service on a larger box/instance - as it'll commonly take less time. HOWEVER, just make sure to configure the 'secondary' server to FORCE ENCRYPTION before you FAILOVER (otherwise, you'll need to failover at least 2x to ensure all 'nodes' are restricted to encrypted commmunications only).

##### Reverting forced Encryption
If you find that key/critical applications cannot connect to your server once you've enabled encrypted communications only:
* if POSSIBLE, try to leave encryption enabled for a few minutes to get an idea/list of exactly which applications/hosts are having problems connecting. (Obviously skip this step if it doesn't make any sense with your workload.)
* Revert 'Force Encryption' changes (i.e., remove the setting) by 'reversing' the changes you just made (i.e., switch the Force Encryption setting back to 'No' and restart the SQL Server Service - or FAILOVER). 

#### 7. Verifying Encrypted Connectivity
Once you've 'enforced encryption' and applications/operations are proceding in production as expected (or in your dev/test environment as part of testing), you can CONFIRM that client connections to SQL Server are encrypted using the following query: 

```sql
SELECT session_id, client_net_address, auth_scheme, encrypt_option FROM sys.dm_exec_connections;
```

If encryption is working correctly and as expected, the **[encrypt_option]** column will be set to TRUE for all connected clients.

## TDE Setup Instructions 

### Primary Server 
The following instructions apply to the server (or servers - i.e., such as in a Mirroring or Availability Group topology) you'll be configuring to allow TDE against target databases. 

#### 1. Ensure that the Server has a MASTER KEY
This key will be signed by the underlying (DPAPI on Windows) OS then used to sign db-level keys and other certificates by on the SQL Server: 

```sql
USE [master];
GO


IF NOT EXISTS (SELECT NULL FROM master.sys.[certificates] WHERE [certificate_id] = 101) BEGIN 
	
	CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'make sure to add a secure pass-phrase with cryptographic ENTROPY here!';

  END; 
ELSE 
	PRINT 'Master Key Already Exists';	

GO
```

NOTE: In the code above, you'll want to make sure to change AND document the password you use. (Rather than using a 'password', use a longer pass-phrase.)

And, note that if you already have a MASTER KEY (which is common - though NOT having one is common also), the script above will NOT try to recreate a MASTER KEY. 


#### 2. Create a Backup of your Server's MASTER encryption key
Strictly speaking, you do not need to have this backup to be able to recover your TDE data in the case of an emergency. 

Instead, since it is ALWAYS a best practice to backup/save anything to do with encryption or server/configuration on your server, a better approach is to simply execute a backup of your MASTER key (taking the approach to 'always backup' - rather than trying to remember which certificates/keys/etc. can be safely 'skipped'). 

To execute a backup: 

```sql
-- TODO: make sure you change the PATH and the password:
BACKUP MASTER KEY TO FILE = N'D:\SQLBackups\ServerName_MasterKey.key'
	ENCRYPTION BY PASSWORD = 'Password to decrypt master key file details goes here.'; 
GO
```

When executing the code above, make sure to change the path/filename and set (and document) the password you're using to encrypt/decrypt your MASTER KEY.


#### 3. Create a new, Server-Level, Certificate
This is the 'master' certificate that you'll use to sign the encryption keys for your databases. 

**WARNING: If you LOSE this certificate, you will NOT be able to access your data** (on a different server/etc - or should the key SOMEHOW be dropped from your system).

```sql
CREATE CERTIFICATE DataEncryptionCertificate
WITH 
	SUBJECT = 'Data Encyrption (TDE) Certificate', 
	EXPIRY_DATE = '2030-12-31'
GO
```


***NOTE:** in MOST environments it makes the most sense to TDE all databases via the same (single) Certificate. However, there is nothing preventing you from potentially creating multiple different certificates and using those to sign database-level encryption keys SHOULD you want to want more extensive encryption options.* 


#### 4. Backup your 'Encryption' Certificate
Because this certificate is REQUIRED for disaster recovery purposes (and/or to let you move copies of production databases to other servers via migrations, upgrades, etc.), you'll NEED to execute a backup of the certificate. 

Backing up a certificate is achieved by creating a file-system representation of your certificate (i.e., a .cer or other file). But, since this certificate contains HIGHLY sensitive information, SQL Server will help you 'export' it in an encrypted fashion that REQUIRES a password/pass-key to be able to re-read and 'import' the certificate. 

Stated differently, the certificate backup file + encryption 'password' allow your TDE certificate become 'portable' - meaning that you can use it to copy/restore databases to another server or even restore TDE requirements on your PRIMARY server should it crash and need a full rebuild/etc. 
DataCn
WARNING: Without a SAFE/SECURE backup of this certificate (and the password) you will NOT be able to access your data in the case of an emergency. Period. Microsoft cannot/will-not provide support and there is no way to decrypt your data OTHER than by means of the certificate that was used to encrypt your data. 

WARNING: WITH access to this certificate, hackers and/or disgruntled employees can steal copies of your files and/or backups and decrypt them. 

In consequence of these two security concerns, best practices are to keep TDE 'Certificates' in a safe/protected, restricted, and audited location. 

To backup a certificate used for TDE: 

```sql
BACKUP CERTIFICATE DataEncryptionCertificate 
TO 
	FILE = 'D:\SQLBackups\DataEncryptionCertificate_TDE.cer'
WITH 
	PRIVATE KEY (
		FILE = 'D:\SQLBackups\DataEncryptionCertificate_TDE_PrivateKey.key', 
		ENCRYPTION BY PASSWORD = 'password here - with high ENtropY1!!!111one'
	);
GO
```

NOTE: Make sure to securely document the password you used as a decryption key for this backup operation. 

NOTE: Once you make a backup, MAKE SURE to copy it off-box and/or off-site and into a secured, audited, 'vault' or some other secure location where KEY people can access this information if/when needed (though, ideally, under some form of auditing).


#### 5. Encrypt Target Databases
Once you've created (and backed-up) a certificate for use in TDE, you'll need to execute the following steps per each database that you wish to encrypt. 

##### 5.a Create an Encryption Key
Per each database that you'll encrypt, you need to create an encryption key (which will be signed by your 'TDE' Certificate). This key will define encryption type and stength and, obviously, be used to encrypt/decrypt data to/from disk (transparently during SQL Server operations).

```sql
USE [DatabaseThatIWantToEncrypt];
GO

CREATE DATABASE ENCRYPTION KEY 
WITH 
	ALGORITHM = AES_256  -- AES_256 is recommended (lower/older algorithms are not enabled by DEFAULT on newer versions of SQL Server).
	ENCRYPTION BY SERVER CERTIFICATE DataEncryptionCertificate;
GO
```

See the following for additional information on the creation of database encryption keys: 

https://docs.microsoft.com/en-us/sql/t-sql/statements/create-database-encryption-key-transact-sql?view=sql-server-2017

##### 5.b Encrypt the Target Database 
You can instruct SQL Server to encrypt (or decrypt) a database via a 'simple' ALTER DATABASE statement - setting ENCRYPTION on or off as desired: 

```sql
ALTER DATABASE [DatabaseThatIWantToEncrypt]
SET 
	ENCRYPTION ON;
GO
```

While normal databases operations (queries and INSERTs/UPDATEs/DELETEs, most schema changes, and so on) will function without ANY issue while a database is being encrypted/decrypted some (very low lever) modifications to the database will NOT be allowed until encryption/decryption completes. Details on which operations are prohibited are found here: 

https://docs.microsoft.com/en-us/sql/relational-databases/security/encryption/transparent-data-encryption?view=sql-server-2017

(See the 'Restrictions' documentation - which outlines how while you are making 'big' changes to the server via encryption/decryption you can't drop the database, add/remove files, and other 'big' changes while encrytpion/decription is ongoing.)

Otherwise, background threads will begin the process of encrypting/decrypting the data as desired. 

##### 5.c Monitor Encryption (or Decryption) Progress
To monitor overall encryption (or decryption) progress, you can use the following query (focusing on the **[percent_completed]** column):

```sql
SELECT * FROM sys.dm_database_encryption_keys;
```

#### 5.d Kick off a FULL Backup When Possible
Ideally, once encryption (or decryption) is **COMPLETE**, kick off a FULL backup to a) ensure that backups are now encrypted (i.e., restart your backup chain), and b) decrease recovery time (i.e., to avoid the overhead of re-encrypting the data should you have to recover via T-LOG backups/etc.). Note too that since ALL data has been changed, DIFF backups don't make sense (as they can in other situations where you're 'restarting' the log chain).

##### 5.e Rinse and Repeat
To help avoid resoure exhaustion (CPU and IO-subsystem) from encrypting/decrypting 'too much' at once, try to encrypt/decrypt databases one at a time (i.e., in serial fashion) rather than 'toggling' encryption on/off against all databases at the same time. 

As such, once you've completed encrypting/decrypting a single database, and taken a backup, work through remaining/targetted databases as needed. 

### Ensuring Disaster Recovery Protection
Once you have encrypted your databases you will NEED to verify that they can be recovered in the case of a disaster. The ONLY way to CONFIDENTLY do this (and make sure you haven't somehow missed/skipped a step or somehow run afoul of some other, unforseen, problem) is to RESTORE your 'TDE' certificate to a new/additional server and VERIFY that you can then use that certificate to successfully restore a TDE/Encrypted database backup. 

To verify disaster recovery capabilities: 

#### 1. Copy Certificate and Key Backup Files to the Target Server
Copy the .cer and .key file representing your 'TDE' certificate to your test/target server.

#### 2. Ensure that the Target Server has a MASTER KEY. 
Create a new MASTER KEY using syntax similar to the following: 

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'This is a DIFFERENT password';
GO
```

NOTE: the MASTER KEY does NOT need to use the same encryption 'password' NOR does it even need to be the 'same' key (i.e., restored from before). 

#### 3. Create the DataEncryption Certificate from the .cer and .key Backups + password
Modify the paths for the .cer file and the .key file in the code below AND update the password, then execute. 


This should result in the creation of a new CERTIFICATE on the new/target server. However, since this certificate was 'signed' with the key/secure information used on your primary server, it'll have an identical thumbprint - meaning that it can be used to decrypt (and encryt) TDE databases.

```sql
CREATE CERTIFICATE DataEncryptionCertificate 
FROM 
	FILE = 'D:\SomePath\DataEncryptionCertificate_TDE.cer'
WITH 
	PRIVATE KEY (
		FILE = 'D:\some_path\DataEncryptionCertificate_TDE_PrivateKey.key',
		DECRYPTION BY PASSWORD = 'the SAME password here - that you used in the backup previously'
	);
GO
```

#### 4. Restore a Backup taken from your primary server. 
With a 'matching' (identical) certificate - which can be used for TDE - you can now restore databases created with TDE on your 'primary' server (i.e., the TEST server you're evaluating TDE on OR the production server(s) you've just configured for TDE). 

For information on restoring backups see the following:

http://www.sqlservervideos.com/video/restoring-databases-with-ssms/

As outlined above, you'll typically be better off by creating FULL backups of your databases AFTER they're completely encrypted. But this NOT required. 

Either way, you SHOULD be able to fully restore and recover a FULL (+ any DIFFs if you didn't execute a NEW full after TDE) + any t-logs without any problems issues. Otherwise, you've done something wrong and will need to either re-export/backup+restore your TDE 'certificate' and/or REMOVE TDE encryption, re-sign/re-create certificates and VERIFY that you can restore as needed. 

**Otherwise, you will be gauranteed to lose data during a disaster.** 