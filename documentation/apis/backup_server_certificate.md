![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > `dbo.backup_server_certificate`

# dbo.backup_server_certificate

## Table of Contents
- [Overview](#overview)
- [Syntax](#syntax)
- [Remarks](#remarks) 
- [Examples](#examples)
- [See Also](#see-also)

## Overview
**APPLIES TO:** :heavy_check_mark: Windows :heavy_check_mark: SQL Server 2008 / 2008 R2 :grey_question: SQL Server 2012+ :o: Linux :grey_question: Azure :grey_question: SQL Server Express / Web

~~**S4 CONVENTIONS:** [ConventionX](/x/link-here), [ConventionY](etc), and [ConventionB](etc)~~

Enables simplified execution of process to backup server-level certificates (used for backup encryption, TDE, etc.) via best-practices code implementation. 

## Syntax

```

    dbo.backup_server_certificate 
        @CertificateName = N'Name of Certificate to Backup',
        @BackupDirectory = N'{DEFAULT} | X:\RootPathToWhere\_cer_and_key_files_will_be_dumped',
        [@CopyToBackupDirectory = N'Optional share\directory for COPIES of cer+key files'],
        @EncryptionKeyPassword = N'strong-password-for-protection-of-key-file-contents',
        [@PrintOnly = [ 0 | 1 ] ] 

```

### Arguments
`@CertificateName = N'Name of Certificate to Create'`  
 Name of the certificate you want to backup - must be the name of an existing certificate in the `[master]` database.    
*REQUIRED.* 
  
`@BackupDirectory = N'D:\PathToBackupsFolder\etc\'`  
 Path or directory (do not include file-names or extensions) where certificate `.cer` and `.key` files will be saved/dumped.  
 *REQUIRED*
 
> ### :label: **NOTE:** 
> By S4 Convention, certificate files will be exported with `<CertificateName>.cer` and `<CertificateName>_PrivateKey.key` file-names. (And, by convention, these file names are what `dbo.restore_server_certificate` will 'look' for by default - though you CAN override these conventions within `dbo.restore_server_certificate`.)

`[ @CopyToBackupDirectory = '\\SecondaryPathName\etc\' ]`  
If supplied, `dbo.backup_server_certificate` will push/dump copies of your `.cer` and `.key` files to this path as well. As with `@BackupDirectory` do NOT specify file-names and/or extensions and note that S4 naming conventions are used for the file-names of files exported to the `@CopyToBackupDirectory` as well.  
*OPTIONAL*
 
 `@EncryptionKeyPassword = N'Strong Password for Key File Encryption'`  
 Is the password used to encrypt the `.key` file used to protect your certificate.  
 *REQUIRED*
 
> ### :zap: **WARNING:** 
> Make sure to safely and securely store your Encryption Key Password - without it you will NOT be able to recover your certificate (which, if used for TDE or Backup Encryption - means that YOU WILL LOSE DATA). Likewise, WITH access to this password and your `.cer` + `.key` files, anyone can recreate your certificates (gaining access to secured data).
 
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
Reqiures permissions defined by [`BACKUP CERTIFICATE`](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-certificate-transact-sql?view=sql-server-ver15#permissions#permissions).

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

[S4 Docs Home](/readme.md) > [S4 APIs](/documentation/apis.md) > dbo.backup_server_certificate