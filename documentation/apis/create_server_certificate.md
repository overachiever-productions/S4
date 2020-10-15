![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > `dbo.create_server_certificate`

# dbo.create_server_certificate

## Table of Contents
- [Overview](#overview)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview
**APPLIES TO:** :heavy_check_mark: Windows :heavy_check_mark: SQL Server 2008 / 2008 R2 :grey_question: SQL Server 2012+ :o: Linux :grey_question: Azure :grey_question: SQL Server Express / Web

~~**S4 CONVENTIONS:** [ConventionX](/x/link-here), [ConventionY](etc), and [ConventionB](etc)~~

Simplifies creation of SQL Server server-level certificates (for use in backup encryption, TDE, etc.) while enabling best-practices implementation. Optionally, and - by recommendation - `dbo.create_server_certificate` will create a backup or backups of the `.cer` and `.key` files needed to recreate your certificate for disaster recovery and other purposes. 

## Syntax

```

    dbo.create_server_certificate 
        [@MasterKeyEncryptionPassword = N'strong password for [master] db key encryption' ],
        @CertificateName = N'Name of certificate to create', 			
        @CertificateSubject	= N'Description of certificate purpose', 		
        [@CertificateExpiryVector = N'<vector for certificate expiry>', ]			
        [@BackupDirectory = N'{DEFAULT} | D:\PathToBackups\ForCertBackups\', ]			
        [@CopyToBackupDirectory= N'\\Optional\Secondary\Backup\Location\', ]		
        [@EncryptionKeyPassword = N'strong password for backup of certificate', ]		
        [@PrintOnly = [ 0 | 1 ] ] 					


```

### Arguments
`[ @MasterKeyEncryptionPassword = N'strong password for key encryption of [master] db' ] `  
Before creating server-level certificates, an encryption key MUST be created in the `[master]` database - [via `CREATE MASTER KEY` syntax](https://docs.microsoft.com/en-us/sql/t-sql/statements/create-master-key-transact-sql?view=sql-server-ver15). `dbo.create_server_certificate` simplifies the creation of this master key by creating it IF needed and IF a value has been provided for `@MasterKeyEncryptionPassword` - otherwise, (if a master key has not YET been set) an error will be raised.  
*OPTIONAL*

`@CertificateName = N'Name of the certificate to create' `  
Represents the name of the certificate you wish to create - and must not match the name of any other certificates that already exist in the `[master]` database.  
*REQUIRED*

`@CertificateSubject = N'Description of certificate' `  
Represents a description or overview of the certificate to be created - e.g., `'Provides Backup Encryption for Server X'`.  
*REQUIRED*

`[ @CertificateExpiryVector = N'<vector for certificate expiry>' ] `  
Represents an [S4 vector](/documentation/conventions.md#vectors) that uses natural language to define how long the certificate is valid for - e.g., `N'18 weeks'` or `N'3 years'`.  
*OPTIONAL* - Defaults to `N'10 years'`.

`[ @BackupDirectory = N'{DEFAULT} | D:\PathToBackups\ForCertBackups\', ] `  
Corresponds directly to the `@BackupDirectory` parameter for [`dbo.backup_server_certificate`](/documentation/apis/backup_server_certificate.md).  
*OPTIONAL* 

`[ @CopyToBackupDirectory= N'\\Optional\Secondary\Backup\Location\', ] `  
Corresponds directly to the `@BackupDirectory` parameter for [`dbo.backup_server_certificate`](/documentation/apis/backup_server_certificate.md).  
*OPTIONAL*

` [ @EncryptionKeyPassword = N'strong password for backup of certificate', ] `  
Corresponds directly to the `@BackupDirectory` parameter for [`dbo.backup_server_certificate`](/documentation/apis/backup_server_certificate.md).  
*OPTIONAL* - though, 'Required' if `@BackupDirectory` is specified.

[**@PrintOnly** `= { 0 | 1}` ]  
[TODO link this doc-blurb into a standardized location - so I only have to write this CORE/CONVENTION'd stuff 1x.] 
 
[Return to Table of Contents](#table-of-contents)
 
### Return Code Values 
  0 (success) or non-0 (failure)  

[Return to Table of Contents](#table-of-contents)

## Remarks
Only works against certificates defined in the `[master]` database - i.e., server-level certificates only. 


[Return to Table of Contents](#table-of-contents)

## Permissions 
Requires the following permissions (depending upon how executed): 
- [`CREATE MASTER KEY`](https://docs.microsoft.com/en-us/sql/t-sql/statements/create-master-key-transact-sql?view=sql-server-ver15#permissions)
- [`CREATE CERTIFICATE`](https://docs.microsoft.com/en-us/sql/t-sql/statements/create-certificate-transact-sql?view=sql-server-ver15#permissions)
- [`BACKUP CERTIFICATE`](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-certificate-transact-sql?view=sql-server-ver15#permissions#permissions).

## Examples

### A. Doing such and such
Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
```sql

SELECT 'example stuff here';

```

### B. Doing blah blah

Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
```sql

SELECT 'example stuff here';

```
Lacus vel facilisis volutpat est. Molestie a iaculis at erat pellentesque adipiscing. Non quam lacus suspendisse faucibus.


[Return to Table of Contents](#table-of-contents)

## See Also
- [best practices for such and such]()
- [related code/functionality]()

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.create_server_certificate