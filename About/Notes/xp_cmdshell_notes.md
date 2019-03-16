### Notes about xp_cmdshell

There's a lot of false information online about the use of xp_cmdshell. However, while enabling xp_cmdshell for anyone OUTSIDE of the SysAdmin fixed server-role WOULD be a bad idea, this both semi-difficult to do (i.e., it takes some explicit steps), and is NOT what is required for S4 backups to execute. Instead, S4 Backups simply need xp_cmdshell enabled for SysAdmins - which will give Admins (or SQL Server Agent jobs running with elevated permissions), the ability to, effectively, open up a command-shell on the host SQL Server and execute commands against that shell WITH the permissions granted to your SQL Server Engine/Service. Or, in other words, xp_cmdshell allows SysAdmins to run arbitrary Windows commands (in effect giving them a 'DOS prompt') with whatever permissions are afforded to the SQL Server Service itself. When configured securely and correctly, the number of permissions available to a SQL Server Service are VERY limited by default - and are typically restricted to folders explicitly defined during setup or initial configuration (i.e., SQL Server will obviously need permissions to access the Program Files\SQL Server\ directory, the folders for data and log files, and any folders you've defined for SQL Server to use as backups; further, if you're pushing backups off-box (which you should be doing), you'll need to be using a least-privilege Domain Account - which will need to be granted read/write permissions against your targeted network shares for SQL Server backups). 

In short, the worst that a SysAdmin can do with xp_cmdshell enabled is... the same they could do without it enabled (i.e., they could drop/destroy all of your databases and backups (if they are so inclined to do or if they're careless and their access to the server is somehow compromised) - but there is NO elevation of privilege that comes from having xp_cmdshell enabled - period. 

To check to see if xp_cmdshell is enabled, run the following against your server: 

```sql
-- 1 = enabled, 0 = not-enabled:
SELECT name, value_in_use FROM sys.configurations WHERE name = 'xp_cmdshell';
```

If it's not enabled, you'll then need to see if advanced configuration options are enabled or not (as 'flipping' xp_cmdshell on/off is an advanced configuration option). To do this, run the following against your server: 

```sql
-- 1 = enabled, 0 = not-enabled:
SELECT name, value_in_use FROM sys.configurations WHERE name = 'show advanced options';
```

If you need to enable advanced configuration options, run the following:

```sql
USE master;
GO

EXEC sp_configure 'show advanced options', 1;
GO
```

Once you execute the command above, SQL Server will notify you that the command succeeded, but that you need to run a RECONFIGURE command before the change will be applied. To force SQL Server to re-read configuration information, run the following command: 

```sql
RECONFIGURE;
```

**WARNING:** While the configuration options specified in these setup docs will NOT cause a dump of your plan cache, OTHER configuration changes can/will force a dump of your plan cache (which can cause MAJOR performance issues and problems on heavily used servers). As such:
- Be careful with the use of RECONFIGURE (i.e., don't ever treat it lightly). 
- If you're 100% confident that no OTHER changes to the server's configuration are PENDING a RECONFIGURE command, go ahead and run reconfigure as needed to complete setup. 
- If there's any doubt and you're on a busy system, wait until non-peak hours before running a RECONFIGURE command.

To check if there are any changes pending on your server, you can run the following (and if the only configuration setting listed is for xp_cmdshell, then you can run RECONFIGURE without any worries):

```sql
-- note that 'min server memory(MB)' will frequently show up in here
--		if so, you can ignore it... 
SELECT name, value, value_in_use 
FROM sys.configurations
WHERE value != value_in_use;
```

Otherwise, once advanced configuration options are enabled, if you need to enable xp_cmdshell, run the following against your server:

```sql
USE master;
GO

EXEC sp_configure 'xp_cmdshell', 1;
GO
```

Once you've run that, you will need to run a RECONFIGURE statement (as outlined above) BEFORE the change will 'take'. (See instructions above AND warnings - then execute when/as possible.)