

/*
	NOTES: 
		- Some of the checks in this validation script are hard-coded to ENGLISH (1033).

	INSTRUCTIONS:
		- Just run this script on the Primary and Secondary - and review any INFO, WARNINGS, or ERRORs raised. 
		- Section (in the outcome - if there are any issues) refers to the scripts defined in Part IV of the accompanying documentation. 

*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#ERRORs') IS NOT NULL
	DROP TABLE #Errors;

CREATE TABLE #Errors (
	ErrorId int IDENTITY(1,1) NOT NULL, 
	SectionID int NOT NULL, 
	Severity varchar(20) NOT NULL, -- INFO, WARNING, ERROR
	ErrorText nvarchar(2000) NOT NULL
);

-------------------------------------------------------------------------------------
-- 0. Core Configuration Details/Needs:

-- Database Mail
IF (SELECT value_in_use FROM sys.configurations WHERE name = 'Database Mail XPs') != 1 BEGIN
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 0, N'ERROR', N'Database Mail has not been set up or configured.';
END

DECLARE @profileInfo TABLE (
	profile_id int NULL, 
	name sysname NULL, 
	[description] nvarchar(256) NULL
)
INSERT INTO	@profileInfo (profile_id, name, description)
EXEC msdb.dbo.sysmail_help_profile_sp;

IF NOT EXISTS (SELECT NULL FROM @profileInfo) BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 0, N'ERROR', N'A Database Mail Profile has not been created.';
END 

-- SQL Agent can talk to Database Mail and a profile has been configured: 
declare @DatabaseMailProfile nvarchar(255)
exec master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
 IF @DatabaseMailProfile IS NULL BEGIN 
 	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 0, N'ERROR', N'The SQL Server Agent has not been configured to Use Database Mail.';
 END 

-- Operators (at least one configured)
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators) BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 0, N'WARNING', N'No SQL Server Agent Operator was detected.';
END 

-------------------------------------------------------------------------------------
-- 1. 
-- PARTNER linked server definition.
DECLARE @linkedServers TABLE (
	SRV_NAME sysname NULL, 
	SRV_PROVIDERNAME nvarchar(128) NULL, 
	SRV_PRODUCT nvarchar(128) NULL,
	SRV_DATASOURCE nvarchar(4000) NULL, 
	SRV_PROVIDERSTRING nvarchar(4000) NULL,
	SRV_LOCATION nvarchar(4000) NULL, 
	SRV_CAT sysname NULL
)

INSERT INTO @linkedServers 
EXEC sp_linkedservers

IF NOT EXISTS (SELECT NULL FROM @linkedServers WHERE SRV_NAME = N'PARTNER') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 1, N'ERROR', N'Linked Server definition for PARTNER not found (synchronization checks won''t work).';
END

-------------------------------------------------------------------------------------
-- 2.Server and Job Synchronization Checks

-- check for missing code/objects:
DECLARE @ObjectNames TABLE (
	name sysname
)

INSERT INTO @ObjectNames (name)
VALUES 
(N'server_trace_flags'),
(N'is_primary_database'),
(N'server_synchronization_checks'),
(N'job_synchronization_checks');

INSERT INTO #Errors (SectionID, Severity, ErrorText)
SELECT 
	2, 
	N'ERROR',
	N'Object [' + x.name + N'] was not found in the [admindb] database.'
FROM 
	@ObjectNames x
	LEFT OUTER JOIN admindb..sysobjects o ON o.name = x.name
WHERE 
	o.name IS NULL;

-- warn if there aren't any job steps with dba_ServerSynchronizationChecks or dba_JobSynchronizationChecks referenced.
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%server_synchronization_checks%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [server_synchronization_checks] was not found.';
END 

IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%job_synchronization_checks%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [job_synchronization_checks] was not found.';
END 

-------------------------------------------------------------------------------------
-- 3. Mirroring Failover

-- Mirroring Failover Messages (WITH LOG):
IF NOT EXISTS (SELECT NULL FROM master.sys.messages WHERE language_id = 1033 AND message_id = 1440 AND is_event_logged = 1) BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 3, N'WARNING', N'Message ID 1440 is not set to use the WITH_LOG option.';
END

IF NOT EXISTS (SELECT NULL FROM master.sys.messages WHERE language_id = 1033 AND message_id = 1480 AND is_event_logged = 1) BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 3, N'ERROR', N'Message ID 1480 is not set to use the WITH_LOG option.';
END


-- objects/code:
DELETE FROM @ObjectNames;
INSERT INTO @ObjectNames (name)
VALUES 
(N'server_trace_flags'),
(N'respond_to_db_failover');

INSERT INTO #Errors (SectionID, Severity, ErrorText)
SELECT 
	3, 
	N'ERROR',
	N'Object [' + x.name + N'] was not found in the admindb database.'
FROM 
	@ObjectNames x
	LEFT OUTER JOIN admindb..sysobjects o ON o.name = x.name
WHERE 
	o.name IS NULL;

--DELETE FROM @ObjectNames;
--INSERT INTO @ObjectNames (name)
--VALUES 
--(N'sp_fix_orphaned_users');

--INSERT INTO #Errors (SectionID, Severity, ErrorText)
--SELECT 
--	3, 
--	N'ERROR', 
--	N'Object [' + x.name + N'] was not found in the master database.'
--FROM 
--	@ObjectNames x
--	LEFT OUTER JOIN admindb..sysobjects o ON o.name = x.name
--WHERE 
--	o.name IS NULL;


-- Alerts for 1440/1480
--IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE message_id = 1440) BEGIN 
--	INSERT INTO #Errors (SectionID, Severity, ErrorText)
--	SELECT 3, N'INFO', N'An Alert to Trap Failover with a Database as the Primary has not been configured.';
--END

IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE message_id = 1480) BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 3, N'ERROR', N'A SQL Server Agent Alert has not been set up to ''trap'' Message 1480 (database failover) has not been created.';
END

-- Warn if no job to respond to failover:
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%respond_to_db_failover%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 3, N'WARNING', N'A SQL Server Agent Job that calls [respond_to_db_failover] (to handle database failover) was not found.';
END 


-------------------------------------------------------------------------------------
-- 4. Monitoring. 

-- objects/code:
DELETE FROM @ObjectNames;
INSERT INTO @ObjectNames (name)
VALUES 
(N'dba_Mirroring_HealthCheck');

INSERT INTO #Errors (SectionID, Severity, ErrorText)
SELECT 
	4, 
	N'ERROR',
	N'Object [' + x.name + N'] was not found in the master database.'
FROM 
	@ObjectNames x
	LEFT OUTER JOIN master.dbo.sysobjects o ON o.name = x.name
WHERE 
	o.name IS NULL;


-- Make sure the 'stock' MS job "Database Mirroring Monitor Job" is present. 
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobs WHERE name = 'Database Mirroring Monitor Job') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 4, N'ERROR', N'The SQL Server Agent (initially provided by Microsoft) entitled ''Database Mirroring Monitor Job'' is not present. Please recreate.';
END 

-- Make sure there's a health-check job:
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%dba_Mirroring_HealthCheck%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 4, N'WARNING', N'A SQL Server Agent Job that calls [dba_Mirroring_HealthCheck] (to run health checks) was not found.';
END 


-------------------------------------------------------------------------------------
-- 5. Backups

-- objects/code:
DELETE FROM @ObjectNames;
INSERT INTO @ObjectNames (name)
VALUES 
(N'backup_databases');

INSERT INTO #Errors (SectionID, Severity, ErrorText)
SELECT 
	5, 
	N'ERROR',
	N'Object [' + x.name + N'] was not found in the admin database.'
FROM 
	@ObjectNames x
	LEFT OUTER JOIN admindb.dbo.sysobjects o ON o.name = x.name
WHERE 
	o.name IS NULL;

DECLARE @sproID int;
SELECT @sproID = object_id FROM master.sys.objects WHERE name = 'backup_databases';
IF @sproID IS NOT NULL BEGIN 
	
	IF EXISTS (SELECT NULL FROM master.sys.sql_modules WHERE OBJECT_ID = @sproID AND [definition] LIKE '%xp_cmdshell%') BEGIN 
		IF NOT EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 1) BEGIN 
			INSERT INTO #Errors (SectionID, Severity, ErrorText)
			SELECT 5, N'WARNING', N'Sproc admindb.dbo.[backup_databases] requires xp_cmdshell to copy files off-box, but xp_cmdshell is not enabled. Please enable via sp_configure.';			
		END
	END
END

-- warnings for backups:
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%backup_databases%FULL%SYSTEM%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 5, N'INFO', N'No SQL Server Agent Job to execute backups of System Databases was found.';	
END

IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%backup_databases%FULL%' AND command NOT LIKE '%backup_databases%FULL%system%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 5, N'INFO', N'No SQL Server Agent Job to execute FULL backups of User Databases was found.';	
END

IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%backup_databases%LOG%') BEGIN 
	INSERT INTO #Errors (SectionID, Severity, ErrorText)
	SELECT 5, N'INFO', N'No SQL Server Agent Job to execute Transaction Log backups of User Databases was found.';	
END

-------------------------------------------------------------------------------------
-- 6. Reporting 
IF EXISTS (SELECT NULL FROM #Errors)
	SELECT SectionID [Section], Severity, ErrorText [Detail] FROM #Errors ORDER BY ErrorId;
ELSE 
	SELECT 'All Checks Completed - No Issues Detected.' [Outcome];

