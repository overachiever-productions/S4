


/*



	IMPORTANT:
		- MUST set the ON_FAILURE action to be what is needed/desired. 
				DEFAULT for this template is to FAIL_OPERATION. 



*/

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- A. DEFINITIONS
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

USE [master];
GO

------------------------------------------------------------------------------------------------------------------------------------
-- Server Audit: 
-- drop if exists:
IF EXISTS(SELECT NULL FROM sys.[server_audits] WHERE [name] = N'<audit_name, sysname, Server Audit>') BEGIN

	ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = OFF);
	DROP SERVER AUDIT [<audit_name, sysname, Server Audit>];

END;
	

-- create/define:
CREATE SERVER AUDIT [<audit_name, sysname, Server Audit>]
TO FILE (
	FILEPATH = N'<audit_path, sysname, D:\Audits\>',
	MAXSIZE = <maxFileSizeMB, int, 200>MB,
	MAX_ROLLOVER_FILES = <maxRolloverFilesCount, int, 4>, 
	RESERVE_DISK_SPACE = ON  -- pre-allocate disk size up to MAXSIZE... 
)
WITH (
	QUEUE_DELAY = 2000,
	ON_FAILURE = FAIL_OPERATION  -- options: SHUTDOWN | FAIL_OPERATION | CONTINUE. My recommendation: initially START with CONTINUE, then audit failures/fix - THEN switch to FAIL_OPERATION. 
)

-- WHERE ... (any specifics can be configured here). 
--		e.g., WHERE object_name = 'CreditCards'... etc. 


GO


-- enable: 
ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = ON);
GO


------------------------------------------------------------------------------------------------------------------------------------
-- Server Audit Specification: 

IF EXISTS (SELECT NULL FROM sys.[server_audit_specifications] WHERE [name] = N'<serverAuditSpecName, sysname, Server Audit Specification>') BEGIN
	ALTER SERVER AUDIT SPECIFICATION [<serverAuditSpecName, sysname, Server Audit Specification>] WITH (STATE = OFF);
	DROP SERVER AUDIT SPECIFICATION [<serverAuditSpecName, sysname, Server Audit Specification>];
END



-- NOTE: this is defined for 2012+ instances. (2008 instances have entirely different audit actions/groups.)
CREATE SERVER AUDIT SPECIFICATION [<serverAuditSpecName, sysname, Server Audit Specification>]
	FOR SERVER AUDIT [<audit_name, sysname, Server Audit>]
		ADD (APPLICATION_ROLE_CHANGE_PASSWORD_GROUP),
		ADD (AUDIT_CHANGE_GROUP),
		ADD (BACKUP_RESTORE_GROUP),
		ADD (DATABASE_CHANGE_GROUP ),
		--ADD (DATABASE_LOGOUT_GROUP ),
		--ADD (DATABASE_OBJECT_ACCESS_GROUP),
		ADD (DATABASE_OBJECT_CHANGE_GROUP),
		ADD (DATABASE_OBJECT_OWNERSHIP_CHANGE_GROUP),
		ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP ),
		ADD (DATABASE_OPERATION_GROUP),
		ADD (DATABASE_OWNERSHIP_CHANGE_GROUP ),
		ADD (DATABASE_PERMISSION_CHANGE_GROUP),
		ADD (DATABASE_PRINCIPAL_CHANGE_GROUP ),
		ADD (DATABASE_PRINCIPAL_IMPERSONATION_GROUP),
		ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP ),
		ADD (DBCC_GROUP),
		--ADD (FAILED_DATABASE_AUTHENTICATION_GROUP),  -- contained dbs only. 
		ADD (FAILED_LOGIN_GROUP),
		--ADD (FULLTEXT_GROUP),
		ADD (LOGIN_CHANGE_PASSWORD_GROUP ),
		--ADD (LOGOUT_GROUP),
		ADD (SCHEMA_OBJECT_ACCESS_GROUP),
		ADD (SCHEMA_OBJECT_CHANGE_GROUP),
		ADD (SCHEMA_OBJECT_OWNERSHIP_CHANGE_GROUP),
		ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP ),
		ADD (SERVER_OBJECT_CHANGE_GROUP),
		ADD (SERVER_OBJECT_OWNERSHIP_CHANGE_GROUP),
		ADD (SERVER_OBJECT_PERMISSION_CHANGE_GROUP ),
		ADD (SERVER_OPERATION_GROUP),  -- juicy server-level changes
		ADD (SERVER_PERMISSION_CHANGE_GROUP),
		ADD (SERVER_PRINCIPAL_CHANGE_GROUP ),
		ADD (SERVER_PRINCIPAL_IMPERSONATION_GROUP),
		ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP ),
		ADD (SERVER_STATE_CHANGE_GROUP ),
		--ADD (SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP),  -- contained only.
		--ADD (SUCCESSFUL_LOGIN_GROUP),  -- depends upon environment... 
		ADD (TRACE_CHANGE_GROUP),
		--ADD (USER_CHANGE_PASSWORD_GROUP),  -- contained only... 
		ADD (USER_DEFINED_AUDIT_GROUP) -- outputs any 'custom' details defined by sp_audit_write and friends. 
	WITH (STATE = ON);
GO

------------------------------------------------------------------------------------------------------------------------------------
-- DB Audit Specification for msdb (i.e., Jobs Monitoring):

USE [msdb];
GO

IF EXISTS(SELECT NULL FROM msdb.sys.[database_audit_specifications] WHERE [name] = N'<msdbJobsMonitoringSpecName, sysname, Jobs Monitoring (msdb)>') BEGIN 
	ALTER DATABASE AUDIT SPECIFICATION [<msdbJobsMonitoringSpecName, sysname, Jobs Monitoring (msdb)>] WITH (STATE = OFF);
	DROP DATABASE AUDIT SPECIFICATION [<msdbJobsMonitoringSpecName, sysname, Jobs Monitoring (msdb)>];
END;

CREATE DATABASE AUDIT SPECIFICATION [<msdbJobsMonitoringSpecName, sysname, Jobs Monitoring (msdb)>]
	FOR SERVER AUDIT [<audit_name, sysname, Server Audit>]
		ADD (EXECUTE ON OBJECT::[dbo].[sp_add_job] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_update_job] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_delete_job] BY [public]),

		ADD (EXECUTE ON OBJECT::[dbo].[sp_add_jobschedule] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_update_schedule] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_delete_schedule] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_attach_schedule] BY [public]),

		ADD (EXECUTE ON OBJECT::[dbo].[sp_add_jobstep] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_update_jobstep] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_delete_jobstep] BY [public]),

		ADD (EXECUTE ON OBJECT::[dbo].[sp_add_operator] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_update_operator] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_delete_operator] BY [public]),

		ADD (EXECUTE ON OBJECT::[dbo].[sp_add_alert] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_update_alert] BY [public]),
		ADD (EXECUTE ON OBJECT::[dbo].[sp_delete_alert] BY [public]),

		ADD (INSERT ON OBJECT::[dbo].[sysjobs] BY [public]),
		ADD (UPDATE ON OBJECT::[dbo].[sysjobs] BY [public]),
		ADD (DELETE ON OBJECT::[dbo].[sysjobs] BY [public]), 

		ADD (INSERT ON OBJECT::[dbo].[sysjobschedules] BY [public]),
		ADD (UPDATE ON OBJECT::[dbo].[sysjobschedules] BY [public]),
		ADD (DELETE ON OBJECT::[dbo].[sysjobschedules] BY [public]), 

		ADD (INSERT ON OBJECT::[dbo].[sysjobsteps] BY [public]),
		ADD (UPDATE ON OBJECT::[dbo].[sysjobsteps] BY [public]),
		ADD (DELETE ON OBJECT::[dbo].[sysjobsteps] BY [public]), 


		ADD (INSERT ON OBJECT::[dbo].[sysoperators] BY [public]),
		ADD (UPDATE ON OBJECT::[dbo].[sysoperators] BY [public]),
		ADD (DELETE ON OBJECT::[dbo].[sysoperators] BY [public]), 

		ADD (INSERT ON OBJECT::[dbo].[sysalerts] BY [public]),
		ADD (UPDATE ON OBJECT::[dbo].[sysalerts] BY [public]),
		ADD (DELETE ON OBJECT::[dbo].[sysalerts] BY [public]) 
	WITH (STATE = ON);
GO

------------------------------------------------------------------------------------------------------------------------------------
-- DB Audit Specifcation and Implemenation/Addition:

-- PER database to AUDIT: 

-- NOTE: 2012+ semantics: 

USE [<targetDBName, sysname, xxxx>];
GO

IF EXISTS(SELECT NULL FROM [<targetDBName, sysname, xxxx>].sys.[database_audit_specifications] WHERE [name] = N'<dbSpecName, sysname, Database Audit Specification>') BEGIN 
	ALTER DATABASE AUDIT SPECIFICATION [<dbSpecName, sysname, Database Audit Specification>] WITH (STATE = OFF);
	DROP DATABASE AUDIT SPECIFICATION [<dbSpecName, sysname, Database Audit Specification>];
END;

CREATE DATABASE AUDIT SPECIFICATION [<dbSpecName, sysname, Database Audit Specification>]
	FOR SERVER AUDIT [<audit_name, sysname, Server Audit>]

		--ADD (APPLICATION_ROLE_CHANGE_PASSWORD_GROUP), -- appliation role usage only... 
		ADD (AUDIT_CHANGE_GROUP)--,
		--ADD (BACKUP_RESTORE_GROUP),		-- duplicate of server spec (TODO: compare details of db-level vs server-level events/actions)
		--ADD (DATABASE_CHANGE_GROUP),		-- duplicate of server spec (TODO: compare details of db-level vs server-level events/actions)
		--ADD (DATABASE_LOGOUT_GROUP),
		--ADD (DATABASE_OBJECT_ACCESS_GROUP),
		--ADD (DATABASE_OBJECT_CHANGE_GROUP),
		--ADD (DATABASE_OBJECT_OWNERSHIP_CHANGE_GROUP),
		--ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
		--ADD (DATABASE_OPERATION_GROUP),
		--ADD (DATABASE_OWNERSHIP_CHANGE_GROUP),
		--ADD (DATABASE_PERMISSION_CHANGE_GROUP),
		--ADD (DATABASE_PRINCIPAL_CHANGE_GROUP),
		--ADD (DATABASE_PRINCIPAL_IMPERSONATION_GROUP),
		--ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
		--ADD (DBCC_GROUP),
		--ADD (FAILED_DATABASE_AUTHENTICATION_GROUP),
		--ADD (SCHEMA_OBJECT_ACCESS_GROUP),
		--ADD (SCHEMA_OBJECT_CHANGE_GROUP),
		--ADD (SCHEMA_OBJECT_OWNERSHIP_CHANGE_GROUP),
		--ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP),
		--ADD (SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP),
		--ADD (USER_CHANGE_PASSWORD_GROUP),
		--ADD (USER_DEFINED_AUDIT_GROUP)

	WITH (STATE = ON);
GO




------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- B. Analysis/Review:
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Sample 'review' query... 
SELECT action_id, succeeded, [event_time], server_principal_name, database_principal_name, additional_information, [statement] 
FROM fn_get_audit_file('<audit_path, sysname, D:\Audits\>*',default,default)
ORDER BY [event_time], [transaction_id], [sequence_number];