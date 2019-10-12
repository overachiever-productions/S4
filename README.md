# S4

<span style="font-size: 26px">**S**imple **S**QL **S**erver **S**cripts -> **S4**</span>

## TABLE OF CONTENTS
  
> ### <i class="fa fa-random"></i> Work in Progress  
> This documentation is a work in progress. Any content [surrounded by square brackets] represents a DRAFT version of documentation.

- [License](#license)
- [Requirements](#requirements)
- [Setup](#setup)
    - [Step By Step Installation Instructions](#step-by-step-installation)
    - [Enabling Advanced S4 Features](#enabling-advanced-s4-features)
    - [Updating S4](#updates)
    - [Removing S4](#removing)
- [S4 Features and Benefits](#features-and-benefits)
    - [S4 Utilities](#utilities)
    - [Performance Monitoring](#performance-monitoring)
    - [S4 Backups](#backups)
    - [Automated Restore Tests](#automated-restores)
- [Using S4 Conventions](#using-s4-conventions)
- [S4 Best Practices](#s4-best-practices)

## License

[MIT LICENSE](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=master&encodedPath=LICENSE)

## Requirements
**SQL Server Requirements:**

- SQL Server 2012+.
- MOST (but not all) S4 functionality works with SQL Server 2008 / SQL Server 2008 R2. 
- Some advanced functionality does not work on Express and/or Web Versions of SQL Server.
- Windows Server Only. (Not yet tested on Azure/Linux.)

**Setup Requirements:**
- To deploy, you'll need the ability to run T-SQL scripts against your server and create a database.
- Advanced error handling (for backups and other automation) requires xp_cmdshell to be enabled - as per the steps outlined in [Enabling Advanced S4 Features](#enabling-advanced-s4-features).
- SMTP (SQL Server Database Mail) for advanced S4 automation and alerts.


## SETUP 
Setup is trivial: run a [T-SQL script "e.g.7.0.3042.sql"](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) against your target server and S4 will create a new `[admindb]` database - as the new home for all S4 code and functionality.  

Advanced S4 automation and error handling requires a server-level change - which has to be explicitly enabled via the step outlined in [Enabling Advanced S4 Features](#enabling-advanced-s4-features). 

Once deployed, it's easy to [keep S4 updated](#updating-s4) - just grab new releases of the deployment file, and run them against your target server (where they'll see your exising deployment and update code as needed).

If (for whatever reason) you no longer want/need S4, you can 'Undo' advanced functionality via the instructions found in [Removing S4](#removing-s4) - and then DROP the `[admindb]` database.


### Steb By Step Installation
To deploy S4:
1. Grab the `latest-release.sql` S4 deployment script. By convention, the LATEST version of S4 will be available in the [\Deployment\ ](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) folder - and will be the only T-SQL file present (e.g., 5.5.2816.2.sql - as per the screenshot below).

![](https://assets.overachiever.net/s4/images/install_get_latest_file.gif)

2. Execute the contents of the `latest-version.sql` (e.g., "5.5.2816.2.sql") file against your target server. 
3. The script will do everything necessary to create a new database (the `[admindb]`) and populate it with all S4 entities and code needed.
4. At script completion, information about the current version(s) installed on your server instance will be displayed 

![](https://assets.overachiever.net/s4/images/install_install_completed.gif)

> #### <i class="fa fa-bolt"></i> Existing Deployments
> *If S4 has **already** been deployed to your target SQL Server Instance, the deployment script will detect this and simply UPDATE all code in the [admindb] to the latest version - adding a new entry into admindb.dbo.version_history.* 

### Enabling Advanced S4 Features
Once S4 has been deployed (i.e., after the admindb has been created), to deploy advanced error-handling features, simply run the following: 

```sql
EXEC [admindb].dbo.[enable_advanced_capabilities];
GO
```

#### Common Questions and Concerns about enabling xp_cmdshell 
Meh. There's a lot of [FUD](https://en.wikipedia.org/wiki/Fear,_uncertainty_and_doubt) out there about enabling xp_cmdshell on your SQL Server. *Security is NEVER something to take lightly, but xp_cmdshell isn't a security concern - having a SQL Server running with ELEVATED PERMISSIONS is a security concern.* xp_cmdshell merely allows the SQL Server Service account to interact with the OS much EASIER than would otherwise be possible without xp_cmdshell enabled. 

To checkup-on/view current S4 advanced functionality and configuration settings, run the following: 

```sql
EXEC dbo.verifiy_advanced_capabilities;
GO
```

**Note that S4 ships with Advanced Capabilities DISABLED by default.**

[For more information on WHY xp_cmdshell makes lots of sense to use for 'advanced' capabilities AND to learn more about why xp_cmdshell is NOT the panic-attack many assume it to be, make sure to check on [link to CONVENTIONS - where Advanced Functionality is covered].]

[Return to Table of Contents](#table-of-contents)

### UPDATES
Keeping S4 up-to-date is simple - just grab and run the latest-release.sql file against your target server.

To Update S4: 
1. Grab the `latest-release.sql` S4 deployment script. By convention, the LATEST version of S4 will be available in the [\Deployment\ ](/Repository/00aeb933-08e0-466e-a815-db20aa979639/master/Tree/Deployment) folder - and will be the only T-SQL file present (e.g., "5.6.2831.1.sql" - as per the screenshot below).

![](https://assets.overachiever.net/s4/images/install_update_latest_file.gif)

2. Execute this script (e.g., "5.6.2831.1.sql") against your target server.
3. The `latest-release.sql` script will deploy all of the latest and greatest S4 goodness. 
4. Upon completion, the update/deployment script will output information about all versions installed on your target server instance:

![](https://assets.overachiever.net/s4/images/install_update_completed.gif)

### Removing S4
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

4. Done. (If you want to re-install, simply re-run the original setup instructions.)

[Return to Table of Contents](#table-of-contents)

## FEATURES AND BENEFITS
The entire point of S4 is to provide SIMPLE SQL Server Scripts - or a toolbox full of easy-to-use scripts that can be used for a wide variety of purposes.

### S4 Utilities 
S4 was primarily built to facilitate the automation of backups, restores, and disaster recovery testing - but contains a number of utilities that can be used to make many typical administrative T-SQL Tasks easier. 

#### Counting Matches 
Count the number of times an @input contains @pattern - such as determining the number of spaces in this statement:
```sql
SELECT admindb.dbo.[count_matches](N'There are five spaces in here.', N' ');
----------
5
```

Or, you can use this for more complex pattern matching: 
```sql
SELECT 
	admindb.dbo.[count_matches]([definition], N'LEN(')
FROM 
	admindb.sys.[sql_modules]
WHERE 
	[object_id] = OBJECT_ID('dbo.count_matches');
----------
3
```

It's also great for branching and other logical evaluations: 
```sql
IF (SELECT admindb.dbo.count_matches(@someVariable, 'targetText') > 0) BEGIN 
    PRINT 'the string ''targetText'' _WAS_ found... '
END;
----------
the string 'targetText' _WAS_ found...
```

***NOTE:** dbo.count_matches does NOT support wildcards or regexes.*

#### Pring Long Strings
The T-SQL `PRINT` command truncates longer text at 4000 characters. S4's `dbo.print_long_string` uses simple logic to overcome this functionality making it easy to 'print' larger outputs - like really-long dynamic SQL Statements, 'blob' text, etc. 

```sql
EXEC admindb.dbo.print_long_string @nvarcharMaxVariableWithReallyLongTextInIt;
GO
```
> <i class="fa fa-terminal"></i>  
> The contents of @nvarcharMaxVariableWithReallyLongTextInIt would be displayed here
> over as many lines
> as needed to output the entire contents.

#### Split Strings


#### Format TimeSpans


#### Common DBA Tasks and Needs

#### Listing Databases





### Performance Monitoring

### Simplified and Robust Backups

### Simplified Restore Operations and Automated Restore-Testing

### HA Configuration, Monitoring, and Alerting

### Security Diagnostics 

### Config 'dumps' etc... 


[Return to Table of Contents](#table-of-contents)

## APIs
**NOTE:** *Not ALL S4 code has currently been documented. Specifically, 'internally used' and 'helper' code remains largely undocumented at this point.* 


[Return to Table of Contents](#table-of-contents)

## USING S4 Conventions
sdfsdf


<div class="stub" meta="this is content 'pulled' from setup - that now belongs in CONVENTIONS - because advanced error handling is a major convention">[LINK to CONVENTIONS about how S4 doesn't want to just 'try' things and throw up hands if/when there's an error. it strives for caller-inform. So that troubleshooting is easy and natural - as DBAs/admins will have immediate access to specific exceptions and errors - without having to spend tons of time debugging and so on... ]

#### TRY / CATCH Fails to Catch All Exceptions in SQL Server
[demonstrate this by means of an example - e.g., backup to a drive that doesn't exist... and try/catch... then show the output... of F5/execution.]

[To get around this, have to enable xp_cmdshell - to let us 'shell out' to the SQL Server's own shell and run sqlcmd with the command we want to run... so that we can capture all output/details as needed.] 

[example of dbo.execute_command (same backup statement as above - but passed in as a command) - and show the output - i.e., we TRAPPED the error (with full details).]

[NOTE about how all of this is ... yeah, a pain, but there's no other way. Then... xp_cmdshell is native SQL Server and just fine.]


For more detailed information, see [Notes about xp_cmdshell](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2Fxp_cmdshell_notes.md)</div>


[Return to Table of Contents](#table-of-contents)

## S4 BEST PRACTICES
sfdsdfsd

<div class="stub">[make sure that HA docs/links have a reference to these two sites/doc-sources: 

- [SQL Server Biz Continuity](https://docs.microsoft.com/en-us/sql/database-engine/sql-server-business-continuity-dr?view=sql-server-2017)

- [Windows Server Failover Clustering DOCS](https://docs.microsoft.com/en-us/windows-server/failover-clustering/failover-clustering-overview)

]</div>

[Return to Table of Contents](#table-of-contents)
<style>
    div.stub { display: none; }
</style>