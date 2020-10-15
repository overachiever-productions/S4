![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > `dbo.restore_server_certificate`

# dbo.restore_server_certificate

## Table of Contents
- [Overview](#overview)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview
**APPLIES TO:** :heavy_check_mark: Windows :heavy_check_mark: SQL Server 2008 / 2008 R2 :grey_question: SQL Server 2012+ :o: Linux :grey_question: Azure :grey_question: SQL Server Express / Web

~~**S4 CONVENTIONS:** [ConventionX](/x/link-here), [ConventionY](etc), and [ConventionB](etc)~~

Simplifies creation of server-level certificates from `.cer` and `.key` files - along with required encryption key used to protect `.key` file contents.

Provides two main ways to specify the paths/locations of `.cer` and `.key` files: 
- S4-Convention - files will be found at `<@CertificateAndKeyRootDirectory>\<@OriginalCertificateName>.cer` and `<@CertificateAndKeyRootDirectory>\<@OriginalCertificateName>_PrivateKey.key` - meaning that all that is needed for 'pathing' purposes is to provide the `@CertificateAndKeyRootDirectory` if the `.key` and `.cer` files were created (backed-up) using S4's `dbo.backup_server_certificate` or via `dbo.create_server_certificate`.
- By means of explicitly enumerated 'full-path' definitions for both `@FullCertificateFilePath` and `@FullKeyFilePath` - which is a bit more 'cumbersome' than S4-convention-based restore operations, but exists to enable restore operations against keys backed up without S4 conventions.

See examples for more information on these two different options.

## Syntax

```

    dbo.restore_server_certificate 
        [@OriginalCertificateName = N'Name of the original certifcate (pre-backup)', ]
        [@CertificateAndKeyRootDirectory = N'{DEFAULT} | D:\PathToCerAndKeyFiles\', ]
        @PrivateKeyEncryptionPassword = N'Strong Password used to encrypt .key file details', 	
        [@MasterKeyEncryptionPassword = N'Optional strong password for master key encryption', ]
        [@OptionalNewCertificateName = N'Optional NEW name for cert on this server', ]
        [@FullCertificateFilePath = N'X:\FullPath\And\ExactFileName.cer', ]
        [@FullKeyFilePath = N'X:\FullPath\And\ExactFileName.key', ]
        [@PrintOnly = [ 0 | 1 ] ] 


```

### Arguments
`[ @OriginalCertificateName = N'Original Certificate Name' ] `  
If using S4 File-Names conventions - i.e., if `@CertificateAndKeyRootDirectory` is specified, then `@OriginalCertificateName` is required and should point to the folder/path/directory containing both your `.cer` and `.key` files. T 
*OPTIONAL or REQUIRED - depending upon execution type*
 
`[ @CertificateAndKeyRootDirectory = N'{DEFAULT} | D:\PathToCerAndKeyFiles\', ] `  
If `@OriginalCertificateName` has been used to 'inform' the file-names of the `.cer` and `.key` files to restore-from, then `@CertificateAndKeyRootDirectory` is required and should point to the folder/path/directory containing both your `.cer` and `.key` files. The S4 token for the default SQL Server Backup directory (`N'{DEFAULT}'`) is allowed - but assumes that your `.cer` and `.key` files are stored in the root of your backups directory.   
*OPTIONAL or REQUIRED - depending upon execution type*
 
`@PrivateKeyEncryptionPassword = N'Strong Password used to encrypt .key file details', 	`  
Represents the strong-password used to encrypt the security details within you `.key` file.  
*REQUIRED*

`[ @MasterKeyEncryptionPassword = N'Optional strong password for master key encryption', ] `  
Corresponds directly to the `@MasterKeyEncryptionPassword` parameter for [`dbo.backup_create_certificate`](/documentation/apis/create_server_certificate.md).  
*OPTIONAL* 

`[ @OptionalNewCertificateName = N'Optional NEW name for cert on this server', ] `  
When specified, `@OptionalNewCertificateName` will 'overwrite' or 'replace' the name of the certificate to be restored - e.g., if your certificate was originally called (and backed-up as) `BackupEncryptionCert` and `@OptionalNewCertificateName` is set to the value `N'BackupCert'`, then the certificate will be created by execution of `dbo.restore_server_certificate` with the name `[BackupCert]` on the current server.  
*OPTIONAL*  

`[ @FullCertificateFilePath = N'X:\FullPath\And\ExactFileName.cer', ]`  
When specified, `@FullCertificateFilePath` points to the EXACT path, filename, and extension of the certificate file containing the certificate details you wish to restore.  
*OPTIONAL*

`[ @FullKeyFilePath = N'X:\FullPath\And\ExactFileName.key', ] `  
When specified, `@FullKeyFilePath` contains the EXACT path, filename, and extension of the private-key file corresponding to the certificate you wish to restore.  
*OPTIONAL - but required if/when `@FullCertificateFilePath` is specified or used.*

**@PrintOnly** `= { 0 | 1}` ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.] 

[Return to Table of Contents](#table-of-contents)
 
### Return Code Values 
  0 (success) or non-0 (failure)  

[Return to Table of Contents](#table-of-contents)

## Remarks
Only works against certificates that will be restored in/against the `[master]` database - i.e., server-level certificates only. 


[Return to Table of Contents](#table-of-contents)

## Permissions 
Required the permissions defined by [`CREATE MASTER KEY`](https://docs.microsoft.com/en-us/sql/t-sql/statements/create-master-key-transact-sql?view=sql-server-ver15#permissions). 

NOTE: Also requires knowledge of and/or access to the password used to protect the private key details for the certificate being restored. 

## Examples

### A. Executing a simple, S4-Convention-based, Restore
Assume that we have two servers - joined in an Availability Group - both of which will need access to a certificate used for Backups Encryption. 

Creation of this certificate can be handled as follows on, say, `SQL1` - via the following command: 

```sql 

EXEC [admindb].dbo.[create_server_certificate]
	@MasterKeyEncryptionPassword = NULL,
	@CertificateName = N'BackupsEncryptionCertificate',
	@CertificateSubject = N'Backup Encryption for AG Servers',
	@BackupDirectory = N'\\SharedDisks\SQLBackups\certs\',
	@EncryptionKeyPassword = N'JJZ7Ea@Y+t@sgMhF';
	
```

Note, too, that the use of `dbo.create_server_certificate` above executes a BACKUP of the `BackupsEncryptionCertificate` as part of execution - which means that creation of the certificate above will result in 3x objects being created: 
- A new, server-level, certificate within the `[master]` database on `SQL1` called `BackupEncryptionCertificate`. 
- A `.cer` backup file - created at `\\SharedDisks\SQLBackups\certs\BackupsEncryptionCertificate.cer`.
- A corresponding Private-Key file (protected by the @EncryptionKeyPassword specified) at `\\SharedDisks\SQLBackups\certs\BackupsEncryptionCertificate_PrivateKey.key`. 

Using these artifacts/outputs, we can now connect to `SQL2` and run the following call to `dbo.restore_server_certificate` to create the `BackupsEncryptionCertificate` on `SQL2` - so that it will be present on both hosts in the Availability Group: 

```sql

EXEC [admindb].dbo.[restore_server_certificate]
	@OriginalCertificateName = N'BackupsEncryptionCertificate',
	@PrivateKeyEncryptionPassword = N'JJZ7Ea@Y+t@sgMhF',
	@CertificateAndKeyRootDirectory = N'\\SharedDisks\SQLBackups\certs\';
	
```

Note that, in the execution above, `dbo.restore_server_certificate` will 'figure out' the location of the .cer and .key files by means of adhering to S4 file-naming conventions relative to certificates. 

### B. Explicitly Stating the Location of Cert and Key Files
Assume that you already have a certificate and private-key backup - and wish to restore a certificate from a previous server on to a new server (or as, say, part of disaster recovery). In this case, you'll need to specify the following: 
- the exact path to the certificate backup file. 
- the exact path to your private key file. 
- the password used for private-key encryption. 
- the name you'd like this certificate to have on your new server. 

Execution of `dbo.restore_server_certificate` would, as such, look similar to the following: 

```sql 

EXEC [admindb].dbo.[restore_server_certificate]
	@OriginalCertificateName = N'TDECertForImportantDB',
	@PrivateKeyEncryptionPassword = N'Strong Password Here',
	@FullCertificateFilePath = N'D:\SQLBackups\imports\certs\ServerXYZ_TDE_Cert.certificate',
	@FullKeyFilePath = N'D:\SQLBackups\imports\keys\TDE_PrivateKey.xxx';

``` 

And, note that in the example above, the directories for both the Certificate Backup and the Private Key can be different and there is no expectation (or limitation) of file-names OR extensions - i.e., any VALID set of certificate-backup and private-key files that will work via T-SQL's `CREATE CERTIFICATE` command will work here. 

### C. Creating and Renaming a Certificate
Assume you're a developer - and need to restore a Production or QA certificate in your dev environment to work against a particular bug in a specified database - but the database in question has backups protected by an encryption certificate. In this case, you want to 'restore' the cert AND give it a new name - something that makes it easier to identify (and drop/remove) when you're done. 

Further, assume that you haven't, yet, configured MASTER KEY ENCRYPTION in your `[master]` database. 

In this scenario, execution of `dbo.restore_server_certificate` will look similar to the following: 

```sql 

EXEC [admindb].dbo.[restore_server_certificate]
	@OriginalCertificateName = N'ProductionBackupsEncryption',
	@CertificateAndKeyRootDirectory = N'D:\MyProjects\FilesFromDBAForSprintXyz\',
	@PrivateKeyEncryptionPassword = N'#5AX%+3A4qN_eSUG', -- password for key file
	@MasterKeyEncryptionPassword = N'&C-bGca+Sv@C3w3!', -- new, random, password
	@OptionalNewCertificateName = N'Prod_BackupCert-RemoveMe';
	

```

Where execution of `dbo.restore_server_certificate` will 'import' the security thumbprint and certificate details for the `ProductionBackupsEncryption` certificate, but install it on your development server as `Prod_BackupCert-RemoveMe` as the new name - and will also enable master key encryption as part of execution as well. 

[Return to Table of Contents](#table-of-contents)

## See Also
- [best practices for such and such]()
- [related code/functionality]()

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.restore_server_certificate