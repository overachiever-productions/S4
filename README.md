<style>
    div.stub { display: none; }
</style>
# S4
**S**imple **S**QL **S**erver **S**cripts -> **S<sup>4</sup>**


<i class="fas fa-camera"></i>


[MIT LICENSE](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=master&encodedPath=LICENSE)

## <a name="toc"></a> TABLE OF CONTENTS
- [Installation](#installation)
    - [Requirements](#requirements)
    - [Step By Step Installation Instructions](#step-by-step-installation)
    - [Enabling Advanced S4 Features](#enabling-advanced-s4-features)
- [Updating S4](#updates)
- [FEATURES AND BENEFITS](#features-and-benefits)
- [Using S4 Conventions](#using-s4-conventions)
- [S4 Best Practices](#s4-best-practices)

## <a name="installation"></a> INSTALLATION 

### <a name="requirements"></a> Requirements
- SQL Server 2008+. NOT everything in S4 works with SQL Server 2008/R2 - but all S4 functionality IS intended to work with SQL Sever 2012+.
- Ability to run T-SQL against SQL Server and create a database ([admindb]).
- Advanced Error Handling (required for backups + automated restore tests and many other 'advanced' S4 features) require xp_cmdshell to be enabled - as outlined [below](#enabling-advanced-s4-features).
- SMTP (Database Mail) for notifications and alerts when using advanced/automated S4 features.

### <a name="step-by-step-installation"></a> Steb By Step Installation
To deploy S4 to a target SQL Server Instance:
1. Locate the latest version of S4 in the [Deployment](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Deployment) folder. By convention, only the latest and most-up-to-date version of S4 will be in the Deployment folder (and will use a min.max.signature.build.sql file format - e.g.., "5.5.2816.2.sql"). 

![](https://assets.overachiever.net/s4/images/install_get_latest_file.gif)

2. Run/Execute the contents of the latest-version.sql (e.g., "5.5.2816.2.sql") file against your target server. 
3. The script will do everything necessary to create a new database (the [admindb]) and populate it with all S4 entities and code needed. 
4. As script execution completes, information about the current version(s) installed on your server instance will be displayed. 

![](https://assets.overachiever.net/s4/images/install_install_completed.gif)

**NOTE:** *If S4 has already been deployed to your target SQL Server Instance, the deployment script will detect this and simply UPDATE all code in the [admindb] to the latest version - adding a new entry into admindb.dbo.version_history.* 

<i class="fa fa-refresh fa-spin fa-lg"></i>

### <a name="enabling-advanced-s4-features"></a> Enabling Advanced S4 Features
Once S4 has been deployed (i.e., after the admindb has been created), to deploy advanced error-handling features, simply run the following: 

```sql
EXEC [admindb].dbo.[enable_advanced_capabilities];
GO
```

<i class="fa fa-refresh fa-spin fa-lg"></i>



<div class="stub">[And to undo, execute dbo.disable_advanced_capabilities. Likewise to view/verify whether capabilities are on or not: EXEC dbo.verifiy_advanced_capabilities.]

*[-- TODO: document this fully as part of the v6.0 release (as that's where enabling xp _cmdshell will be removed from normal installation/deployment and become an OPTIONAL feature that can be enabled within the admindb itself (well, via the admindb - cuz it'll enable xp _cmdshell across the server if/as needed.)
v6.0 is where xp_cmdshell enabling will be 'split' out from the main deployment process into a sproc that'll report on the current setting, provide some info/docs/"don't panic details", and enable sp _ configure functionality.]*


[LINK to CONVENTIONS about how S4 doesn't want to just 'try' things and throw up hands if/when there's an error. it strives for caller-inform. So that troubleshooting is easy and natural - as DBAs/admins will have immediate access to specific exceptions and errors - without having to spend tons of time debugging and so on... ]

#### TRY / CATCH Fails to Catch All Exceptions in SQL Server
[demonstrate this by means of an example - e.g., backup to a drive that doesn't exist... and try/catch... then show the output... of F5/execution.]

[To get around this, have to enable xp_cmdshell - to let us 'shell out' to the SQL Server's own shell and run sqlcmd with the command we want to run... so that we can capture all output/details as needed.] 

[example of dbo.execute_command (same backup statement as above - but passed in as a command) - and show the output - i.e., we TRAPPED the error (with full details).]

[NOTE about how all of this is ... yeah, a pain, but there's no other way. Then... xp_cmdshell is native SQL Server and just fine.]</div>


#### Common Questions and Concerns about enabling xp_cmdshell 
Meh. There's a lot of [FUD](https://en.wikipedia.org/wiki/Fear,_uncertainty_and_doubt) out there about enabling xp_cmdshell on your SQL Server. Security is NEVER something to take lightly, but xp_cmdshell isn't a security concern - having a SQL Server running with ELEVATED PERMISSIONS is a security concern. xp_cmdshell merely allows the SQL Server Service account to interact with the OS much EASIER than would otherwise be possible without xp_cmdshell enabled. 

For more detailed information, see [Notes about xp_cmdshell](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2Fxp_cmdshell_notes.md)

[Return to Table of Contents](#toc)

## <a name="updates"></a> UPDATES
Once S4 has been deployed, keeping it updated is simple: 
1. As with a new installation/deployment, simply locate the latest.version.sql file (e.g., "5.6.2820.1.sql") in the [Deployment](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Deployment) folder,

![](https://assets.overachiever.net/s4/images/install_update_latest_file.gif)

2. Execute it against your target SQL Server Instance. 
3. The script will do everything necessary to update all code, tables, and other stuctures/entities needed to push your code to the latest version of S4 goodness. 
4. Upon completion, the update/deployment script will output information about all versions installed on your target server instance:

![](https://assets.overachiever.net/s4/images/install_update_completed.gif)

[Return to Table of Contents](#toc)

## <a name="features-and-benefits"></a> FEATURES AND BENEFITS
examples go here... 

[Return to Table of Contents](#toc)

## <a name="apis"></a> APIs
**NOTE:** *Not ALL S4 code has currently been documented. Specifically, 'internally used' and 'helper' code remains largely undocumented at this point.* 


[Return to Table of Contents](#toc)

## <a name="using-s4-conventions"></a> USING S4 Conventions
sdfsdf

[Return to Table of Contents](#toc)

## <a name="s4-best-practices"></a> S4 BEST PRACTICES
sfdsdfsd

[Return to Table of Contents](#toc)


