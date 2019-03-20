/*
	TODO: 
		- verify that @MailProfileName and @OperatorName are VALID entries (not just that they're present).
		- switch all queries/SELECTs against PARTNER to be run as sp_executesql queries - so that they 'compile' at run-time instead of when this sproc/script is created
			(to prevent this script from throwing errors on systems where there isn't a PARTNER configured when running (installing/updating) scripts).
		
	BUG:
		@ignoredObjects have a hard time with ', x, y' syntax - i.e.,, works fine with ',x,y' but not with 'spaces'. 

	DEPENDENCIES:
		- PARTNER (linked server to Mirroring 'partner')
		- admindb.dbo.server_trace_flags (table)	
		- admindb.dbo.is_primary_database()

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple


	vNEXT:
		- check on SQL Server Agent properties like : history retention, alert system (general, failsafe, etc.) and... on log retention. 
		- check on SQL Server Error Log Retention details... 


	NOTES:
		- When code/objects in the master database are different the best way to address this is: 
			a) figure out which server has the CORRECT version of code, 
			b) script that version (on that server) as an ALTER script, 
			c) RUN the ALTER script BACK on the source server, and then 
			d) run the same ALTER script on the 'secondary' server. Otherwise, you'll frequently NOT get the scripts/code to achieve 100%
			identical checksums from one server to the next (i.e., with just a single ALTER against one server). 
		- If synchronized databases are NOT owned by the same user (ideally 'sa'), then make sure that dba_RespondToMirroredDatabaseRoleChange switches ownership to the server-principal needed. 
		- Full execution of this sproc nets < 40ms of execution time on the primary.
		- Current implementation doesn't address synch-checks on Server-Level Triggers or Endpoints. (But this could be added if needed.)
		- Differences between logins are NOT addressed either. 
		- Current implementation doesn't offer exclusions (i.e., option to ignore) server-level settings - as they should have SYSTEM-WIDE impact/scope and, therefore, should be identical between servers. 
		- SQL Server Login passwords are hashed on their respective servers - using different 'salts' - so the same password on different servers will LOOK different always (meaning we can't check/verify if passwords are the same).

	SAMPLE EXECUTION:

		EXEC admindb.dbo.server_synchronization_checks 
			@IgnoredMasterDbObjects = N'dba_TableTest', 
			@IgnoredAlerts = N'', 
			@IgnoredLogins = N'test,Bilbo,distributor_admin,GoLive',
			@IgnoredLinkedServers = N'PROD,STAGE,repl_distributor', 
			@PrintOnly = 1;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_server_synchronization','P') IS NOT NULL
	DROP PROC dbo.verify_server_synchronization;
GO

CREATE PROC dbo.verify_server_synchronization 
	@IgnoreMirroredDatabaseOwnership	bit		= 0,					-- check by default. 
	@IgnoredMasterDbObjects				nvarchar(4000) = NULL,
	@IgnoredLogins						nvarchar(4000) = NULL,
	@IgnoredAlerts						nvarchar(4000) = NULL,
	@IgnoredLinkedServers				nvarchar(4000) = NULL,
	@MailProfileName					sysname = N'General',					
	@OperatorName						sysname = N'Alerts',					
	@PrintOnly							bit		= 0						-- output only to console if @PrintOnly = 1
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-- if we're not manually running this, make sure the server is the primary:
	IF @PrintOnly = 0 BEGIN -- if we're not running a 'manual' execution - make sure we have all parameters:
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile <> @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END 

	IF OBJECT_ID('admindb.dbo.server_trace_flags', 'U') IS NULL BEGIN 
		RAISERROR('Table dbo.server_trace_flags is not present in master. Synchronization check can not be processed.', 16, 1);
		RETURN -6;
	END

	-- Start by updating dbo.server_trace_flags on both servers:
	TRUNCATE TABLE dbo.server_trace_flags; -- truncating and replacing nets < 1 page of data and typically around 0ms of CPU. 

	INSERT INTO dbo.server_trace_flags(trace_flag, [status], [global], [session])
	EXECUTE ('DBCC TRACESTATUS() WITH NO_INFOMSGS');

	-- Figure out which server this should be running on (and then, from this point forward, only run on the Primary);
	DECLARE @firstMirroredDB sysname; 
	SET @firstMirroredDB = (SELECT TOP 1 d.[name] FROM sys.databases d INNER JOIN sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL ORDER BY d.[name]); 

	-- if there are NO mirrored dbs, then this job will run on BOTH servers at the same time (which seems weird, but if someone sets this up without mirrored dbs, no sense NOT letting this run). 
	IF @firstMirroredDB IS NOT NULL BEGIN 
		-- Check to see if we're on the primary or not. 
		IF (SELECT dbo.is_primary_database(@firstMirroredDB)) = 0 BEGIN 
			PRINT 'Server is Not Primary.'
			RETURN 0; -- tests/checks are now done on the secondary
		END
	END 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	-- Just to make sure that this job (running on both servers) has had enough time to update server_trace_flags, go ahead and give everything 200ms of 'lag'.
	--	 Lame, yes. But helps avoid false-positives and also means we don't have to set up RPC perms against linked servers. 
	WAITFOR DELAY '00:00:00.200';

	CREATE TABLE #Divergence (
		rowid int IDENTITY(1,1) NOT NULL, 
		name nvarchar(100) NOT NULL, 
		[description] nvarchar(500) NOT NULL
	);

	---------------------------------------
	-- Server Level Configuration/Settings: 
	DECLARE @remoteConfig table ( 
		configuration_id int NOT NULL, 
		value_in_use sql_variant NULL
	);	

	INSERT INTO @remoteConfig (configuration_id, value_in_use)
	EXEC master.sys.sp_executesql N'SELECT configuration_id, value_in_use FROM PARTNER.master.sys.configurations;';

	INSERT INTO #Divergence ([name], [description])
	SELECT 
		N'ConfigOption: ' + [source].[name], 
		N'Server Configuration Option is different between ' + @localServerName + N' and ' + @remoteServerName + N'. (Run ''EXEC sp_configure;'' on both servers and/or run ''SELECT * FROM master.sys.configurations;'' on both servers.)'
	FROM 
		master.sys.configurations [source]
		INNER JOIN @remoteConfig [target] ON [source].[configuration_id] = [target].[configuration_id]
	WHERE 
		[source].value_in_use <> [target].value_in_use;

	---------------------------------------
	-- Trace Flags: 
	DECLARE @remoteFlags TABLE (
		trace_flag int NOT NULL, 
		[status] bit NOT NULL, 
		[global] bit NOT NULL, 
		[session] bit NOT NULL
	);
	
	INSERT INTO @remoteFlags ([trace_flag], [status], [global], [session])
	EXEC sp_executesql N'SELECT [trace_flag], [status], [global], [session] FROM PARTNER.admindb.dbo.server_trace_flags;';
	
	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(trace_flag AS nvarchar(5)), 
		N'TRACE FLAG is enabled on ' + @localServerName + N' only.'
	FROM 
		admindb.dbo.server_trace_flags 
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM @remoteFlags);

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(trace_flag AS nvarchar(5)), 
		N'TRACE FLAG is enabled on ' + @remoteServerName + N' only.'
	FROM 
		@remoteFlags
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM admindb.dbo.server_trace_flags);

	-- different values: 
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'TRACE FLAG: ' + CAST(x.trace_flag AS nvarchar(5)), 
		N'TRACE FLAG Enabled Value is different between both servers.'
	FROM 
		admindb.dbo.server_trace_flags [x]
		INNER JOIN @remoteFlags [y] ON x.trace_flag = y.trace_flag 
	WHERE 
		x.[status] <> y.[status]
		OR x.[global] <> y.[global]
		OR x.[session] <> y.[session];


	---------------------------------------
	-- Make sure sys.messages.message_id #1480 is set so that is_event_logged = 1 (for easier/simplified role change (failover) notifications). Likewise, make sure 1440 is still set to is_event_logged = 1 (the default). 
	-- local:
	INSERT INTO #Divergence (name, [description])
	SELECT
		N'ErrorMessage: ' + CAST(message_id AS nvarchar(20)), 
		N'The is_event_logged property for this message_id on ' + @localServerName + N' is NOT set to 1. Please run Mirroring Failover setup scripts.'
	FROM 
		sys.messages 
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	-- remote:
	DECLARE @remoteMessages table (
		language_id smallint NOT NULL, 
		message_id int NOT NULL, 
		is_event_logged bit NOT NULL
	);

	INSERT INTO @remoteMessages (language_id, message_id, is_event_logged)
	EXEC sp_executesql N'SELECT language_id, message_id, is_event_logged FROM PARTNER.master.sys.messages WHERE message_id IN (1440, 1480);';

	INSERT INTO #Divergence (name, [description])
	SELECT
		N'ErrorMessage: ' + CAST(message_id AS nvarchar(20)), 
		N'The is_event_logged property for this message_id on ' + @remoteServerName + N' is NOT set to 1. Please run Mirroring Failover setup scripts.'
	FROM 
		@remoteMessages
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	---------------------------------------
	-- admindb versions: 
	DECLARE @localAdminDBVersion sysname;
	DECLARE @remoteAdminDBVersion sysname;

	SELECT @localAdminDBVersion = version_number FROM admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM admindb..version_history);
	EXEC sys.sp_executesql N'SELECT @remoteVersion = version_number FROM PARTNER.admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM PARTNER.admindb.dbo.version_history);', N'@remoteVersion sysname OUTPUT', @remoteVersion = @remoteAdminDBVersion OUTPUT;

	IF @localAdminDBVersion <> @remoteAdminDBVersion BEGIN
		INSERT INTO #Divergence (name, [description])
		SELECT 
			N'admindb versions are NOT synchronized',
			N'Admin db on ' + @localServerName + ' is ' + @localAdminDBVersion + ' while the version on ' + @remoteServerName + ' is ' + @remoteAdminDBVersion + '.';
	END;

	---------------------------------------
	-- Mirrored database ownership:
	IF @IgnoreMirroredDatabaseOwnership = 0 BEGIN 
		DECLARE @localOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL, 
			owner_sid varbinary(85) NULL
		);

		-- mirrored (local) dbs: 
		INSERT INTO @localOwners ([name], sync_type, owner_sid)
		SELECT d.[name], N'Mirrored' [sync_type], d.owner_sid FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL; 

		-- AG'd (local) dbs: 
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @localOwners ([name], sync_type, owner_sid)
			EXEC master.sys.sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM sys.databases WHERE replica_id IS NOT NULL;';  -- has to be dynamic sql - otherwise replica_id will throw an error during sproc creation... 
		END

		DECLARE @remoteOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL,
			owner_sid varbinary(85) NULL
		);

		-- Mirrored (remote) dbs:
		INSERT INTO @remoteOwners ([name], sync_type, owner_sid) 
		EXEC sp_executesql N'SELECT d.[name], ''Mirrored'' [sync_type], d.owner_sid FROM PARTNER.master.sys.databases d INNER JOIN PARTNER.master.sys.database_mirroring m ON m.database_id = d.database_id WHERE m.mirroring_guid IS NOT NULL;';

		-- AG'd (local) dbs: 
		IF (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) >= 11 BEGIN
			INSERT INTO @localOwners ([name], sync_type, owner_sid)
			EXEC sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM sys.databases WHERE replica_id IS NOT NULL;';			
		END

		INSERT INTO #Divergence (name, [description])
		SELECT 
			N'Database: ' + [local].[name], 
			[local].sync_type + N' database owners are different between servers.'
		FROM 
			@localOwners [local]
			INNER JOIN @remoteOwners [remote] ON [local].[name] = [remote].[name]
		WHERE
			[local].owner_sid <> [remote].owner_sid;
	END

	---------------------------------------
	-- Linked Servers:
	DECLARE @IgnoredLinkedServerNames TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @IgnoredLinkedServerNames([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredLinkedServers, N',', 1);

	DECLARE @remoteLinkedServers table ( 
		[server_id] int NOT NULL,
		[name] sysname NOT NULL,
		[location] nvarchar(4000) NULL,
		[provider_string] nvarchar(4000) NULL,
		[catalog] sysname NULL,
		[product] sysname NOT NULL,
		[data_source] nvarchar(4000) NULL,
		[provider] sysname NOT NULL,
		[is_remote_login_enabled] bit NOT NULL,
		[is_rpc_out_enabled] bit NOT NULL,
		[is_collation_compatible] bit NOT NULL,
		[uses_remote_collation] bit NOT NULL,
		[collation_name] sysname NULL,
		[connect_timeout] int NULL,
		[query_timeout] int NULL,
		[is_remote_proc_transaction_promotion_enabled] bit NULL,
		[is_system] bit NOT NULL,
		[lazy_schema_validation] bit NOT NULL
	);

	INSERT INTO @remoteLinkedServers ([server_id], [name], [location], provider_string, [catalog], product, [data_source], [provider], is_remote_login_enabled, is_rpc_out_enabled, is_collation_compatible, uses_remote_collation,
		 collation_name, connect_timeout, query_timeout, is_remote_proc_transaction_promotion_enabled, is_system, lazy_schema_validation)
	EXEC master.sys.sp_executesql N'SELECT [server_id], [name], [location], provider_string, [catalog], product, [data_source], [provider], is_remote_login_enabled, is_rpc_out_enabled, is_collation_compatible, uses_remote_collation, collation_name, connect_timeout, query_timeout, is_remote_proc_transaction_promotion_enabled, is_system, lazy_schema_validation FROM PARTNER.master.sys.servers;';

	-- local only:
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		N'Linked Server: ' + [local].[name],
		N'Linked Server exists on ' + @localServerName + N' only.'
	FROM 
		sys.servers [local]
		LEFT OUTER JOIN @remoteLinkedServers [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].server_id > 0 
		AND [local].[name] <> 'PARTNER'
		AND [local].[name] NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [remote].[name] IS NULL;

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [remote].[name],
		N'Linked Server exists on ' + @remoteServerName + N' only.'
	FROM 
		@remoteLinkedServers [remote]
		LEFT OUTER JOIN master.sys.servers [local] ON [local].[name] = [remote].[name]
	WHERE 
		[remote].server_id > 0 
		AND [remote].[name] <> 'PARTNER'
		AND [remote].[name] NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [local].[name] IS NULL;

	
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Linked Server: ' + [local].[name], 
		N'Linkded server definitions are different between servers.'
	FROM 
		sys.servers [local]
		INNER JOIN @remoteLinkedServers [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].[name] NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND ( 
			[local].product <> [remote].product
			OR [local].[provider] <> [remote].[provider]
			-- Sadly, PARTNER is a bit of a pain/problem - it has to exist on both servers - but with slightly different versions:
			OR (
				CASE 
					WHEN [local].[name] = 'PARTNER' AND [local].[data_source] <> [remote].[data_source] THEN 0 -- non-true (i.e., non-'different' or non-problematic)
					ELSE 1  -- there's a problem (because data sources are different, but the name is NOT 'Partner'
				END 
				 = 1  
			)
			OR [local].[location] <> [remote].[location]
			OR [local].provider_string <> [remote].provider_string
			OR [local].[catalog] <> [remote].[catalog]
			OR [local].is_remote_login_enabled <> [remote].is_remote_login_enabled
			OR [local].is_rpc_out_enabled <> [remote].is_rpc_out_enabled
			OR [local].is_collation_compatible <> [remote].is_collation_compatible
			OR [local].uses_remote_collation <> [remote].uses_remote_collation
			OR [local].collation_name <> [remote].collation_name
			OR [local].connect_timeout <> [remote].connect_timeout
			OR [local].query_timeout <> [remote].query_timeout
			OR [local].is_remote_proc_transaction_promotion_enabled <> [remote].is_remote_proc_transaction_promotion_enabled
			OR [local].is_system <> [remote].is_system
			OR [local].lazy_schema_validation <> [remote].lazy_schema_validation
		);
		

	---------------------------------------
	-- Logins:
	DECLARE @ignoredLoginName TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredLoginName([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredLogins, N',', 1);

	DECLARE @remotePrincipals table ( 
		[principal_id] int NOT NULL,
		[name] sysname NOT NULL,
		[sid] varbinary(85) NULL,
		[type] char(1) NOT NULL,
		[is_disabled] bit NULL
	);

	INSERT INTO @remotePrincipals (principal_id, [name], [sid], [type], is_disabled)
	EXEC master.sys.sp_executesql N'SELECT principal_id, [name], [sid], [type], is_disabled FROM PARTNER.master.sys.server_principals;';

	DECLARE @remoteLogins table (
		[name] sysname NOT NULL,
		[password_hash] varbinary(256) NULL
	);
	INSERT INTO @remoteLogins ([name], password_hash)
	EXEC master.sys.sp_executesql N'SELECT [name], password_hash FROM PARTNER.master.sys.sql_logins;';

	-- local only:
	INSERT INTO #Divergence ([name], [description])
	SELECT 
		N'Login: ' + [local].[name], 
		N'Login exists on ' + @localServerName + N' only.'
	FROM 
		sys.server_principals [local]
	WHERE 
		principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S'
		AND [local].[name] NOT IN (SELECT [name] FROM @remotePrincipals WHERE principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S')
		AND [local].[name] NOT IN (SELECT [name] FROM @ignoredLoginName);

	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Login: ' + [remote].[name], 
		N'Login exists on ' + @remoteServerName + N' only.'
	FROM 
		@remotePrincipals [remote]
	WHERE 
		principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S'
		AND [remote].[name] NOT IN (SELECT [name] FROM sys.server_principals WHERE principal_id > 10 AND principal_id NOT IN (257, 265) AND [type] = 'S')
		AND [remote].[name] NOT IN (SELECT [name] FROM @ignoredLoginName);

	-- differences
	INSERT INTO #Divergence ([name], [description])
	SELECT
		N'Login: ' + [local].[name], 
		N'Login is different between servers. (Check SID, disabled, or password_hash (for SQL Logins).)'
	FROM 
		(SELECT p.[name], p.[sid], p.is_disabled, l.password_hash FROM sys.server_principals p LEFT OUTER JOIN sys.sql_logins l ON p.[name] = l.[name]) [local]
		INNER JOIN (SELECT p.[name], p.[sid], p.is_disabled, l.password_hash FROM @remotePrincipals p LEFT OUTER JOIN @remoteLogins l ON p.[name] = l.[name]) [remote] ON [local].[name] = [remote].[name]
	WHERE
		[local].[name] NOT IN (SELECT [name] FROM @ignoredLoginName)
		AND [local].[name] NOT LIKE '##MS%' -- skip all of the MS cert signers/etc. 
		AND (
			[local].[sid] <> [remote].[sid]
			--OR [local].password_hash <> [remote].password_hash  -- sadly, these are ALWAYS going to be different because of master keys/encryption details. So we can't use it for comparison purposes.
			OR [local].is_disabled <> [remote].is_disabled
		);

	---------------------------------------
	-- Endpoints? 
	--		[add if needed/desired.]

	---------------------------------------
	-- Server Level Triggers?
	--		[add if needed/desired.]

	---------------------------------------
	-- Other potential things to check/review:
	--		Audit Specs
	--		XEs 
	--		credentials/proxies
	--		service accounts (i.e., SQL Server and SQL Server Agent)
	--		perform volume maint-tasks, lock pages in memory... 
	--		etc...

	---------------------------------------
	-- Operators:
	-- local only

	DECLARE @remoteOperators table (
		[name] sysname NOT NULL,
		[enabled] tinyint NOT NULL,
		[email_address] nvarchar(100) NULL
	);

	INSERT INTO @remoteOperators ([name], [enabled], email_address)
	EXEC master.sys.sp_executesql N'SELECT [name], [enabled], email_address FROM PARTNER.msdb.dbo.sysoperators;';

	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [local].[name], 
		N'Operator exists on ' + @localServerName + N' only.'
	FROM 
		msdb.dbo.sysoperators [local]
		LEFT OUTER JOIN @remoteOperators [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[remote].[name] IS NULL;

	-- remote only
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [remote].[name], 
		N'Operator exists on ' + @remoteServerName + N' only.'
	FROM 
		@remoteOperators [remote]
		LEFT OUTER JOIN msdb.dbo.sysoperators [local] ON [remote].[name] = [local].[name]
	WHERE 
		[local].[name] IS NULL;

	-- differences (just checking email address in this particular config):
	INSERT INTO #Divergence (name, [description])
	SELECT	
		N'Operator: ' + [local].[name], 
		N'Operator definition is different between servers. (Check email address(es) and enabled.)'
	FROM 
		msdb.dbo.sysoperators [local]
		INNER JOIN @remoteOperators [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].[enabled] <> [remote].[enabled]
		OR [local].[email_address] <> [remote].[email_address];

	---------------------------------------
	-- Alerts:
	DECLARE @ignoredAlertName TABLE (
		entry_id int IDENTITY(1,1) NOT NULL,
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredAlertName([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredAlerts, N',', 1);

	DECLARE @remoteAlerts table (
		[name] sysname NOT NULL,
		[message_id] int NOT NULL,
		[severity] int NOT NULL,
		[enabled] tinyint NOT NULL,
		[delay_between_responses] int NOT NULL,
		[notification_message] nvarchar(512) NULL,
		[include_event_description] tinyint NOT NULL,
		[database_name] nvarchar(512) NULL,
		[event_description_keyword] nvarchar(100) NULL,
		[job_id] uniqueidentifier NOT NULL,
		[has_notification] int NOT NULL,
		[performance_condition] nvarchar(512) NULL,
		[category_id] int NOT NULL
	);

	INSERT INTO @remoteAlerts ([name], message_id, severity, [enabled], delay_between_responses, notification_message, include_event_description, [database_name], event_description_keyword,
			job_id, has_notification, performance_condition, category_id)
	EXEC master.sys.sp_executesql N'SELECT [name], message_id, severity, [enabled], delay_between_responses, notification_message, include_event_description, [database_name], event_description_keyword, job_id, has_notification, performance_condition, category_id FROM PARTNER.msdb.dbo.sysalerts;';

	-- local only
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [local].[name], 
		N'Alert exists on ' + @localServerName + N' only.'
	FROM 
		msdb.dbo.sysalerts [local]
		LEFT OUTER JOIN @remoteAlerts [remote] ON [local].[name] = [remote].[name]
	WHERE
		[remote].[name] IS NULL
		AND [local].[name] NOT IN (SELECT [name] FROM @ignoredAlertName);

	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [remote].[name], 
		N'Alert exists on ' + @remoteServerName + N' only.'
	FROM 
		@remoteAlerts [remote]
		LEFT OUTER JOIN msdb.dbo.sysalerts [local] ON [remote].[name] = [local].[name]
	WHERE
		[local].[name] IS NULL
		AND [remote].[name] NOT IN (SELECT [name] FROM @ignoredAlertName);

	-- differences:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'Alert: ' + [local].[name], 
		N'Alert definition is different between servers.'
	FROM	
		msdb.dbo.sysalerts [local]
		INNER JOIN @remoteAlerts [remote] ON [local].[name] = [remote].[name]
	WHERE 
		[local].[name] NOT IN (SELECT [name] FROM @ignoredAlertName)
		AND (
		[local].message_id <> [remote].message_id
		OR [local].severity <> [remote].severity
		OR [local].[enabled] <> [remote].[enabled]
		OR [local].delay_between_responses <> [remote].delay_between_responses
		OR [local].notification_message <> [remote].notification_message
		OR [local].include_event_description <> [remote].include_event_description
		OR [local].[database_name] <> [remote].[database_name]
		OR [local].event_description_keyword <> [remote].event_description_keyword
		-- JobID is problematic. If we have a job set to respond, it'll undoubtedly have a diff ID from one server to the other. So... we just need to make sure ID <> 'empty' on one server, while not on the other, etc. 
		OR (
			CASE 
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 0 -- no problem
				WHEN [local].job_id = N'00000000-0000-0000-0000-000000000000' AND [remote].job_id <> N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem - one alert is 'empty' and the other is not. 
				WHEN [local].job_id <> N'00000000-0000-0000-0000-000000000000' AND [remote].job_id = N'00000000-0000-0000-0000-000000000000' THEN 1 -- problem (inverse of above). 
				WHEN ([local].job_id <> N'00000000-0000-0000-0000-000000000000' AND [remote].job_id <> N'00000000-0000-0000-0000-000000000000') AND ([local].job_id <> [remote].job_id) THEN 0 -- they're both 'non-empty' so... we assume it's good
			END 
			= 1
		)
		OR [local].has_notification <> [remote].has_notification
		OR [local].performance_condition <> [remote].performance_condition
		OR [local].category_id <> [remote].category_id
		);

	---------------------------------------
	-- Objects in Master Database:  
	DECLARE @localMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	DECLARE @ignoredMasterObjects TABLE (
		entry_id int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	INSERT INTO @ignoredMasterObjects([name])
	SELECT [result] [name] FROM dbo.split_string(@IgnoredMasterDbObjects, N',', 1);

	INSERT INTO @localMasterObjects ([object_name])
	SELECT [name] FROM master.sys.objects WHERE [type] IN ('U','V','P','FN','IF','TF') AND is_ms_shipped = 0 AND [name] NOT IN (SELECT [name] FROM @ignoredMasterObjects);
	
	DECLARE @remoteMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	INSERT INTO @remoteMasterObjects ([object_name])
	EXEC master.sys.sp_executesql N'SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;';
	DELETE FROM @remoteMasterObjects WHERE [object_name] IN (SELECT [name] FROM @ignoredMasterObjects);

	-- local only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'object: ' + [local].[object_name], 
		N'Object exists only in master database on ' + @localServerName + '.'
	FROM 
		@localMasterObjects [local]
		LEFT OUTER JOIN @remoteMasterObjects [remote] ON [local].[object_name] = [remote].[object_name]
	WHERE
		[remote].[object_name] IS NULL;
	
	-- remote only:
	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'object: ' + [remote].[object_name], 
		N'Object exists only in master database on ' + @remoteServerName + '.'
	FROM 
		@remoteMasterObjects [remote]
		LEFT OUTER JOIN @localMasterObjects [local] ON [remote].[object_name] = [local].[object_name]
	WHERE
		[local].[object_name] IS NULL;


	CREATE TABLE #Definitions (
		row_id int IDENTITY(1,1) NOT NULL, 
		[location] sysname NOT NULL, 
		[object_name] sysname NOT NULL, 
		[type] char(2) NOT NULL,
		[hash] varbinary(MAX) NULL
	);

	INSERT INTO #Definitions ([location], [object_name], [type], [hash])
	SELECT 
		'local', 
		[name], 
		[type], 
		CASE 
			WHEN [type] IN ('V','P','FN','IF','TF') THEN 
				CASE
					-- HASHBYTES barfs on > 8000 chars. So, using this: http://www.sqlnotes.info/2012/01/16/generate-md5-value-from-big-data/
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
					ELSE HASHBYTES('SHA1', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		master.sys.objects o
		LEFT OUTER JOIN master.sys.sql_modules sm ON o.[object_id] = sm.[object_id]
		INNER JOIN @localMasterObjects x ON o.[name] = x.[object_name];

	DECLARE localtabler CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'local';

	DECLARE @currentObjectName sysname;
	DECLARE @checksum bigint = 0;

	OPEN localtabler;
	FETCH NEXT FROM localtabler INTO @currentObjectName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0;

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		SELECT @checksum = @checksum + [local].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.[name], c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM master.sys.columns c INNER JOIN master.sys.objects o ON o.object_id = c.object_id WHERE o.[name] = @currentObjectName
		) [local];

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'local';

		FETCH NEXT FROM localtabler INTO @currentObjectName;
	END 

	CLOSE localtabler;
	DEALLOCATE localtabler;

	INSERT INTO #Definitions ([location], [object_name], [type], [hash])
	EXEC master.sys.sp_executesql N'SELECT 
		''remote'', 
		o.[name], 
		[type], 
		CASE 
			WHEN [type] IN (''V'',''P'',''FN'',''IF'',''TF'') THEN 
				CASE
					WHEN DATALENGTH(sm.[definition]) > 8000 THEN (SELECT sys.fn_repl_hash_binary(CAST(sm.[definition] AS varbinary(MAX))))
					ELSE HASHBYTES(''SHA1'', sm.[definition])
				END
			ELSE NULL
		END [hash]
	FROM 
		PARTNER.master.sys.objects o
		LEFT OUTER JOIN PARTNER.master.sys.sql_modules sm ON o.object_id = sm.object_id
		INNER JOIN (SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0) x ON o.[name] = x.[name];';

	DECLARE remotetabler CURSOR LOCAL FAST_FORWARD FOR
	SELECT [object_name] FROM #Definitions WHERE [type] = 'U' AND [location] = 'remote';

	OPEN remotetabler;
	FETCH NEXT FROM remotetabler INTO @currentObjectName; 

	WHILE @@FETCH_STATUS = 0 BEGIN 
		SET @checksum = 0; -- otherwise, it'll get passed into sp_executesql with the PREVIOUS value.... 

		-- This whole 'nested' or 'derived' query approach is to get around a WEIRD bug/problem with CHECKSUM and 'running' aggregates. 
		EXEC master.sys.sp_executesql N'SELECT @checksum = ISNULL(@checksum,0) + [remote].[hash] FROM ( 
			SELECT CHECKSUM(c.column_id, c.[name], c.system_type_id, c.max_length, c.[precision]) [hash]
			FROM PARTNER.master.sys.columns c INNER JOIN PARTNER.master.sys.objects o ON o.object_id = c.object_id WHERE o.[name] = @currentObjectName
		) [remote];', N'@checksum bigint OUTPUT, @currentObjectName sysname', @checksum = @checksum OUTPUT, @currentObjectName = @currentObjectName;

		UPDATE #Definitions SET [hash] = @checksum WHERE [object_name] = @currentObjectName AND [location] = 'remote';

		FETCH NEXT FROM remotetabler INTO @currentObjectName; 
	END 

	CLOSE remotetabler;
	DEALLOCATE remotetabler;

	INSERT INTO #Divergence (name, [description])
	SELECT 
		N'object: ' + [local].[object_name], 
		N'Object definitions between servers are different.'
	FROM 
		(SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'local') [local]
		INNER JOIN (SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'remote') [remote] ON [local].object_name = [remote].object_name
	WHERE 
		[local].[hash] <> [remote].[hash];
	
	------------------------------------------------------------------------------
	-- Report on any discrepancies: 
	IF(SELECT COUNT(*) FROM #Divergence) > 0 BEGIN 

		DECLARE @subject nvarchar(300) = N'SQL Server Synchronization Check Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = N'The following synchronization issues were detected: ' + @crlf;

		SELECT 
			@message = @message + @tab + [name] + N' -> ' + [description] + @crlf
		FROM 
			#Divergence
		ORDER BY 
			rowid;
		
		IF @PrintOnly = 1 BEGIN 
			-- just Print out details:
			PRINT 'SUBJECT: ' + @subject;
			PRINT 'BODY: ' + @crlf + @message;

		  END
		ELSE BEGIN
			-- send a message:
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @subject,
				@body = @message;
		END;

	END 

	DROP TABLE #Divergence;
	DROP TABLE #Definitions;

	RETURN 0;
GO