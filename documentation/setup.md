![](https://assets.overachiever.net/s4/images/s4_main_logo.png)
[S4 Docs Home](/readme.md) > Installing, Updating, and Removing S4

# Installing, Updating, and Removing S4

## Table of Contents
- [Requirements and Version Support](#requirements-and-version-support)
- [Step-by-Step Installation Instructions](#step-by-step-installation-instructions)
- [Enabling Advanced S4 Features](#enabling-advanced-s4-features) 
    - [Common Questions and Concerns about enabling xp_cmdshell](#common-questions-and-concerns-about-enabling-xp_cmdshell)
    - [Configuring SQL Server Database Mail](#configuring-sql-server-database-mail)
- [Keeping S4 Updated](#updating-s4)
- [Removing S4](#removing-s4)
- [Installation via PowerShell](#installation-via-powershell)

## Requirements And Version Support

### Requirements
- S4 is designed for SQL Server DBAs. 
    - SysAdmin permissions are needed for S4 deployment.
- Advanced Capabilities (low-level error handling and alerting/notifications) further depend upon [xp_cmdshell](#enabling-advanced-s4-features) and SQL Server's native [Database Mail](#Configuring-sql-server-database-mail) capabilities.

## Step-By-Step Installation Instructions
To deploy S4:
1. Grab the `admindb_latest.sql` deployment script from the S4 [latest release](https://github.com/overachiever-productions/s4/releases/latest) page.
2. Execute the contents of the `admindb_latest.sql` file against your target server. 
3. The script will do everything necessary to create a new database, the `admindb`, and populate it with all S4 entities and code needed.

> :zap: **Existing Deployments:** *If S4 has **already** been deployed to your target SQL Server Instance, the deployment script will detect this and simply UPDATE all code in the [admindb] to the latest version - adding a new entry into admindb.dbo.version_history.* 

4. Upon script completion, information about the current version(s) installed on your server instance will be displayed:

![](https://assets.overachiever.net/s4/images/install_install_completed.gif)

5. To take full advantage of all S4 [features and benefits](/readme.md#features-and-benefits), you'll need to enable advanced S4 features, and ensure that you have database mail configured - as defined in the sections below.

### Enabling Advanced S4 Features
Once S4 has been deployed (i.e., after the admindb has been created), to deploy advanced error-handling features (which ensures that xp_cmdshell is enabled), simply run the following: 

```sql

    EXEC admindb.dbo.enable_advanced_capabilities;
    GO
    
```

### Common Questions and Concerns about enabling xp_cmdshell 
Meh. There's a lot of [FUD](https://en.wikipedia.org/wiki/Fear,_uncertainty_and_doubt) out there about enabling xp_cmdshell on your SQL Server. *Security is NEVER something to take lightly, but xp_cmdshell isn't a security concern* - running a SQL Server with ELEVATED PERMISSIONS is a security concern. xp_cmdshell merely allows administrators to interact with the OS much EASIER than would otherwise be possible WITHOUT xp_cmdshell enabled. 

To checkup-on/view current S4 advanced functionality and configuration settings, run the following: 

```sql

    EXEC admindb.dbo.verifiy_advanced_capabilities;
    GO

```

**Note that S4 ships with Advanced Capabilities DISABLED by default.**

For more information on WHY xp_cmdshell makes lots of sense to use for 'advanced' capabilities AND to learn more about why xp_cmdshell is NOT the panic-attack many assume it to be, make sure to review [S4 notes on xp_cmdshell](/documentation/notes/xp_cmdshell.md).

### Configuring SQL Server Database Mail
In order to take advantage of advanced alerting and monitoring capabilities - including the ablity to execute backups and run restore-tests - you'll need to configure SQL Server's Database Mail capabilities AND instruct or define how S4 communicates with SQL Server Agent Operators in the case of problems.

[PENDING DOCS: S4 Setup - dbo.enable_database_mail... ]

[PENDING DOCS: S4 Setup - configuring EXISTING servers and DB Mail Setups to interact with S4 alerting conventions.]

[Return to Table of Contents](#table-of-contents)

## Updating S4
Keeping S4 up-to-date is simple - just grab and run the `admindb_latest.sql` file against your target server.

To Update S4: 
1. Grab the `admindb_latest.sql` deployment script from the S4 [latest release](https://github.com/overachiever-productions/s4/releases/latest) page.
2. Execute this script against your target server.
3. The `admindb_latest.sql` script will deploy and update/upgrade to all of the latest and greatest S4 goodness. 
4. Upon completion, the update/deployment script will output information about all versions installed on your target server instance:

![](https://assets.overachiever.net/s4/images/install_update_completed.gif)

[Return to Table of Contents](#table-of-contents)

## Removing S4
To remove S4:
1. If you have enabled advanced capabilities (and WANT/NEED xp_cmdshell to be disabled as part of the cleanup process), you'll need to run the following code to disable them (please do this BEFORE DROP'ing the `[admindb]` database):   
```  

    EXEC admindb.dbo.disable_advanced_capabilities;  
    GO  
    
```

2. Review and disable any SQL Server Agent jobs that may be using S4 functionality or capabilities (automated database restore-tests, disk space checks/alerts, HA failover, etc.). 
3. Drop the `[admindb]` database: 
```

    USE [master];  
    GO   

    DROP DATABASE [admindb];  
    GO
    
```

4. Done. 

(If you want to re-install, simply re-run the original setup instructions outlined above.)

## Installation via PowerShell
[**Documentation Pending.** But, basically, just grab [/s4/releases/latest/admindb_latest.sql](https://github.com/overachiever-productions/s4/releases/latest) via `Invoke-WebRequest`, then run `Invoke-SqlCmd` against the downloaded file, and then run `Invoke-SqlCmd -Query "EXEC admindb.dbo.enable_advanced_capabilities;"` ... done.]

<section style="visibility:hidden; display:none;">

```powershell
$creds = Get-Credentials "Please provide SysAdmin creds against your SQL Server...";
Download-Content "https://github.com/overachieverproductions/s4/releases/latest/admindb_latest.sql" > $admindbLatest;
Invoke-SqlCmd -QueryFile $admindbLatest -IgnoreVariables -Credentials $creds;
Invoke-SqlCmd -Query "EXEC admindb.dbo.enable_advanced_capabilities;" -Credentials $creds;
```
</section>


[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md)
