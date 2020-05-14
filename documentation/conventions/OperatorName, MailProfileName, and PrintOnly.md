
[**@OperatorName** = N'{DEFAULT}' ]  
~~DEFAULTED. If 'Alerts' is not a valid Operator name specified/configured on the server, dbo.apply_logs will throw an error BEFORE attempting to apply logs. Otherwise, once this parameter is set to a valid Operator name, then if/when there are any problems during execution, this is the Operator that dbo.apply_logs will send an email alert to - with an overview of problem details.~~
DEFAULT = N'{DEFAULT}';

~~Defaults to 'Alerts'. If 'Alerts' is not a valid Operator name specified/configured on the server, dbo.restore_databases will throw an error BEFORE attempting to restore databases. Otherwise, once this parameter is set to a valid Operator name, then if/when there are any problems during execution, this is the Operator that dbo.restore_databases will send an email alert to - with an overview of problem details. ~~


[**@MailProfileName** = N'{DEFAULT}' ]   
[NOTE: need to document the convention of @PrintOnly = SKIP alerting validation, whereas ... prod-run = throw an error before even running... ]

~~If a valid SQL Server Database Mail Profile is not specified, dbo.backup_databases will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during backups.   
DEFAULT = N'{[DEFAULT]()}'.~~

~~Deafults to 'General'. If this is not a valid SQL Server Database Mail Profile, dba_RestoreBackups will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during restore + validation operations.~~

~~Deafults to 'General'. If this is not a valid SQL Server Database Mail Profile, dba_RestoreBackups will throw an error BEFORE attempting backups. Otherwise, this is the profile used to send alerts if/when there are problems or errors encountered during restore + validation operations. ~~


**[@EmailSubjectPrefix** = 'Email-Subject-Prefix-You-Would-Like-For-XXXXXXXS-Alert-Messages']  
~~Defaults to '[RESTORE TEST ] ', but can be modified as desired. Otherwise, whenever an error or problem occurs during execution an email will be sent with a Subject that starts with whatever is specified (i.e., if you switch this to '--DB2 RESTORE-TEST PROBLEMS!!-- ', you'll get an email with a subject similar to '--DB2 RESTORE-TEST PROBLEMS!!-- Failed To complete' - making it easier to set up any rules or specialized alerts you may wish for backup-testing-specific alerts sent by your SQL Server.~~

~~Defaults to '[Database Backups ] ', but can be modified as desired. Otherwise, whenever an error or problem occurs during execution an email will be sent with a Subject that starts with whatever is specified (i.e., if you switch this to '--DB2 BACKUPS PROBLEM!!-- ', you'll get an email with a subject similar to '--DB2 BACKUPS PROBLEM!!-- Failed To complete' - making it easier to set up any rules or specialized alerts you may wish for backup-specific alerts sent by your SQL Server.
DEFAULT = N'[Database Backups ] '.~~


[**@PrintOnly** = [ 0| 1] ]
DEFAULTED. 
~~When set to true, dbo.apply_logs will NOT execute any of the commands it would normally execute during processing. Instead, commands are printed to the console only. This optional parameter is useful when attempting 'what if' operations to see how processing might look/behave (without making any changes), and can be helpful in debugging or even some types of disaster recovery scenarios.~~   

~~When set to true, processing will complete as normal, HOWEVER, no backup operations or other commands will actually be EXECUTED; instead, all commands will be output to the query window (and SOME validation operations will be skipped). No logging to dbo.backup_log will occur when @PrintOnly = 1. Use of this parameter (i.e., set to true) is primarily intended for debugging operations AND to 'test' or 'see' what dbo.backup_databases would do when handed a set of inputs/parameters. ~~


DEFAULT = 0.