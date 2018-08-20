


/*

	FODDER:
		semi-practical example of a 'filter'. (semi-practical in that this shows VERY well why you'd want to and how you'd go about it, only... the example is kind of fishy as Aaron says.)
		https://dba.stackexchange.com/questions/63760/sql-server-audit-specification-filter-dml-by-all-but-one-user

	IMPORTANT:
		- MUST set the ON_FAILURE action to be what is needed/desired. 
				DEFAULT for this template is to FAIL_OPERATION. 

	CONSIDERATIONS:
		- In highly sensitive environments the following 2x concerns might make sense:
			a) create an additional audit and/or (just) an additional Server Specification that includes AUDIT_CHANGE_GROUP - so that the 'main' audit tracks overall activity and such, and the 'secondary' audit (spec) is a 'watchdog that watches the wathdog'. 
				it might even make sense to create the first audit with a target of FILE, and the secondary audit with a TARGET of the security log. 

			b) could/would make sense to create a simple job that ensures that a specific audit (or whatever) is running - otherwise, send an alert to Alerts or a specific person, and so on. 


	TODO / vNEXT: 
		- MIGHT want to consider setting up a filter (i.e., at audit level) to squelch a particularly messy ... ALTER (AL) - update statistics... 
			looks like it'll be a bit hard to specify/trap... and, there's some benefit to having it in place (obviously) but... damn. 

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

ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = ON);
GO

---------------------------------------------------------------------
-- OPTIONAL: remove SQLTELEMETRY operations from the audit. 

USE [master];
GO

ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = OFF);
GO

ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WHERE server_principal_name <> 'NT SERVICE\SQLTELEMETRY';
GO

ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = ON);
GO



------------------------------------------------------------------------------------------------------------------------------------
-- Server Audit Specification: 

IF EXISTS (SELECT NULL FROM sys.[server_audit_specifications] WHERE [name] = N'<serverAuditSpecName, sysname, Server Audit Specification>') BEGIN
	ALTER SERVER AUDIT SPECIFICATION [<serverAuditSpecName, sysname, Server Audit Specification>] WITH (STATE = OFF);
	DROP SERVER AUDIT SPECIFICATION [<serverAuditSpecName, sysname, Server Audit Specification>];
END

-- https://docs.microsoft.com/en-us/sql/relational-databases/security/auditing/sql-server-audit-action-groups-and-actions

-- NOTE: this is defined for 2012+ instances. (2008 instances have entirely different audit actions/groups.)
CREATE SERVER AUDIT SPECIFICATION [<serverAuditSpecName, sysname, Server Audit Specification>]
	FOR SERVER AUDIT [<audit_name, sysname, Server Audit>]
		ADD (APPLICATION_ROLE_CHANGE_PASSWORD_GROUP), -- if not being used, no real overhead... 
		ADD (AUDIT_CHANGE_GROUP),
		ADD (BACKUP_RESTORE_GROUP),
		ADD (BROKER_LOGIN_GROUP), -- if broker isn't being used, we won't log any data (so no real overhead). 
		ADD (DATABASE_MIRRORING_LOGIN_GROUP), -- only reports on TLS issues with mirroring... (and, presumably? AGs?)
		ADD (DATABASE_CHANGE_GROUP),
		ADD (DATABASE_LOGOUT_GROUP),	-- contained users only... 
		--ADD (DATABASE_OBJECT_ACCESS_GROUP),  -- can lead to a LOT of overhead, and is primararily for service broker monitoring (see docs).
		ADD (DATABASE_OBJECT_CHANGE_GROUP),
		ADD (DATABASE_OBJECT_OWNERSHIP_CHANGE_GROUP),
		ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
		ADD (DATABASE_OPERATION_GROUP),
		ADD (DATABASE_OWNERSHIP_CHANGE_GROUP),
		ADD (DATABASE_PERMISSION_CHANGE_GROUP),
		ADD (DATABASE_PRINCIPAL_CHANGE_GROUP),
		ADD (DATABASE_PRINCIPAL_IMPERSONATION_GROUP),
		ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
		ADD (DBCC_GROUP),
		ADD (FAILED_DATABASE_AUTHENTICATION_GROUP),  -- contained dbs only. but, worth monitoring for failed login attempts. 
		ADD (FAILED_LOGIN_GROUP),
		--ADD (FULLTEXT_GROUP), -- no real 'security' info here.  
		ADD (LOGIN_CHANGE_PASSWORD_GROUP),
	--ADD (LOGOUT_GROUP),  -- can be enabled... connection pooling makes this a bit less vile than might originally think... 
		--ADD (SCHEMA_OBJECT_ACCESS_GROUP), -- this includes SELECTs ... and can literally crater busier servers.
		ADD (SCHEMA_OBJECT_CHANGE_GROUP),
		ADD (SCHEMA_OBJECT_OWNERSHIP_CHANGE_GROUP),
		ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP),
		ADD (SERVER_OBJECT_CHANGE_GROUP),
		ADD (SERVER_OBJECT_OWNERSHIP_CHANGE_GROUP),
		ADD (SERVER_OBJECT_PERMISSION_CHANGE_GROUP),
		ADD (SERVER_OPERATION_GROUP),  -- juicy server-level changes
		ADD (SERVER_PERMISSION_CHANGE_GROUP),
		ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
		ADD (SERVER_PRINCIPAL_IMPERSONATION_GROUP),
		ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
		ADD (SERVER_STATE_CHANGE_GROUP),
		ADD (SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP),  -- contained only.
	--ADD (SUCCESSFUL_LOGIN_GROUP),  -- depends upon environment/scenario. Again, pooled connections mitigate problems. 
		ADD (TRACE_CHANGE_GROUP),
	--ADD (TRANSACTION_GROUP) -- includes IMPLICIT transactions - which can/will dump a TON of modifications into a db. BUT, usefull when monitoring ALL modifications. 
		ADD (USER_CHANGE_PASSWORD_GROUP),  -- contained only... 
		ADD (USER_DEFINED_AUDIT_GROUP) -- outputs any 'custom' details defined by sp_audit_write and friends. 
	WITH (STATE = ON);
GO

------------------------------------------------------------------------------------------------------------------------------------
-- DB Audit Specification for msdb (i.e., Jobs Monitoring):

-- NOTE: Use of [public] oviously means we want these activities trapped for any/ALL users (since every login is a part of [public]).

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

-- Note: there's no real need for these - other than for what I've done above with msdb - i.e., ACTION_GROUPS are better handled at the server-specification level - because they'll 
--		be applied to ALL databases (including newly spun-up, restored, and other types of databases). 
--			AND, if you don't want a specific db monitored, then just (stop first and) modify the FILTERS (where clause) for the Audit itself. 
--				e.g., 

-- Example: 
--ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = OFF);

--ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WHERE [database_name] <> 'Billing' AND [database_name] <> 'IdentityDB';
---- at this point, double-check the audit definition (i.e., filters) to make sure they 'took'.

--ALTER SERVER AUDIT [<audit_name, sysname, Server Audit>] WITH (STATE = ON);


-- NOTE:
--		IF you create a db-level audit spec that captures 'more' than what you've scoped via the Server-Level spec (where 'more' means - either different actions/groups or things 'outside' of your filter)... you'll get those results 'merged' into the overall whole. 
--			in other words, audits take the 'widest' amount of inputs specified (ORs instead of NOT ANDs). 
--		FURTHER, some actions/groups that are 'global' or 'server' in scope (like DBCC commands, and the likes) will end up 'firing' even if executed in an 'excluded' database - simply because those kinds of commands don't really 'care' which DB they're run from, as they're 'server-level' in scope ANYHOW. 



------------------------------------------------------------------------------------------------------------------------------------
-- Audit Management and Oversight:

-- Fine-tuning of config - i.e., see what actions are being tracked and at what rates and if there are any LEGIT filters that could be put in place that would decrease noise and NOT decrease efficacy of the audit. 
SELECT 
	action_id, 
	COUNT(*) instances
FROM 
	fn_get_audit_file('<audit_path, sysname, D:\Audits\>*',default,default)
GROUP BY 
	action_id 
ORDER BY 
	2 DESC;

-- then, look up the action_ids in question for additional details on their scope/origin/etc. 
SELECT * FROM sys.[dm_audit_actions] WHERE [action_id] = 'SL'; -- for example, this is a 'select'....  (if you don't need SELECT across ALL databases and/or only need it for one or two tables, or one or two databases, then set up db-level specifications as 'narrowly' as possible/logical. (when in doubt, record more data).

-- docs on this DMV are here: https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-audit-actions-transact-sql

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- B. Analysis/Review:
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Sample 'review' query... 
SELECT action_id, succeeded, [event_time], server_principal_name, database_principal_name, CAST(additional_information AS xml) [additional_information], [statement] 
FROM fn_get_audit_file('<audit_path, sysname, D:\Audits\>*',default,default)
ORDER BY [event_time] DESC, [transaction_id] DESC, [sequence_number] DESC;
