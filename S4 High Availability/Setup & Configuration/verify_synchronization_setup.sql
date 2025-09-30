/*
	TODO: 
		- Uh... this should check for mirroring/AG-ing endpoints and associated security, no?
		- Ideally, it'd also be great to try and query the windows firewall - see if it's on, and ... if so, do we have a rule for 5022?


	INSTRUCTIONS:
		- Just run this script on the Primary and Secondary - and review any INFO, WARNINGS, or ERRORs raised. 
                
		- Section (in the outcome - if there are any issues) refers to the scripts defined in Part IV of the accompanying documentation. 
                -- TODO: drop/ignore section stuff (or ... re-implement it - i.e., it's from pre-sprocified versions).


    NEEDED:
        - this SHOULD check/verify that the SQL Server Agent IS running. And SET to AUTO START.
        - https://overachieverllc.atlassian.net/browse/S4-570
        - https://overachieverllc.atlassian.net/browse/S4-676
        - I MAY want to check for whether we're using NT SERVICE\MSSQLSERVER / similar (local) accounts vs DOMAIN or NETWORK accounts for BOTH SQL Server AND SQL Server Agent.

    vNEXT:
        - possible @IgnoreSuchAndSuch parameters... 
        - Some of the checks in this validation script are hard-coded to ENGLISH (1033). (can change this to use current server's default language)... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_synchronization_setup','P') IS NOT NULL
	DROP PROC dbo.[verify_synchronization_setup];
GO

CREATE PROC dbo.[verify_synchronization_setup]

AS
    SET NOCOUNT ON; 

	-- {copyright}

    CREATE TABLE #Errors (
	    ErrorId int IDENTITY(1,1) NOT NULL, 
	    SectionID int NOT NULL, 
	    Severity varchar(20) NOT NULL, -- INFO, WARNING, ERROR
	    ErrorText nvarchar(2000) NOT NULL
    );

    -------------------------------------------------------------------------------------
    -- 0. Core Configuration Details/Needs:

	-- TODO: Verify that we've got a Mirroring Endpoint (and, ideally, that CONNECT/etc. has been granted to something on the partner/etc.). 


    -- TODO: integrate THIS logic with the original XE Session logic below: 
    -- also... I should have one of these XE session definitions and simply deploy it if it doesn't exist. 
    -- See https://overachieverllc.atlassian.net/browse/S4-671 for more info. 
	IF (SELECT [admindb].dbo.[get_engine_version]()) >= 11.0 BEGIN 
		
		DECLARE @startupState bit; 
		SELECT @startupState = startup_state FROM sys.[server_event_sessions] WHERE [name] = N'AlwaysOn_health';

		IF @startupState IS NOT NULL AND @startupState <> 1 BEGIN 
			DECLARE @sql nvarchar(MAX) = N'ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE = ON); ';
			EXEC sys.sp_executesql @sql;
		END

		IF NOT EXISTS (SELECT NULL FROM sys.[dm_xe_sessions] WHERE [name] = N'AlwaysOn_health') BEGIN
			SET @sql = N'ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START; ';

			EXEC sys.sp_executesql @sql;
		END;
	END;

    -- (old/existing XE Session Logic).
	-- Verify AG health XE session:
	IF (SELECT [admindb].dbo.[get_engine_version]()) >= 11.0 BEGIN 
		IF NOT EXISTS (SELECT NULL FROM sys.[server_event_sessions] WHERE [name] = N'AlwaysOn_health') BEGIN
			INSERT INTO #Errors (SectionID, Severity, ErrorText)
			SELECT 0, N'WARNING', N'AlwaysOn_health XE session not found on server.';			

		  END; 
		ELSE BEGIN -- we found it, make sure it's auto-started and running: 
			
			IF NOT EXISTS (SELECT NULL FROM sys.[server_event_sessions] WHERE [name] = N'AlwaysOn_health' AND [startup_state] = 1) BEGIN
				INSERT INTO #Errors (SectionID, Severity, ErrorText)
				SELECT 0, N'WARNING', N'AlwaysOn_health XE session is NOT set to auto-start with Server.';
			END;

			IF NOT EXISTS (SELECT NULL FROM sys.[dm_xe_sessions] WHERE [name] = N'AlwaysOn_health') BEGIN
				INSERT INTO #Errors (SectionID, Severity, ErrorText)
				SELECT 0, N'WARNING', N'AlwaysOn_health XE session is NOT currently running.';
			END;
		END;
	END;

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
    DECLARE @DatabaseMailProfile nvarchar(255)
    EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
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
	    [name] sysname
    );

    INSERT INTO @ObjectNames ([name])
    VALUES 
    (N'server_trace_flags'),
    (N'is_primary_database'),
    (N'verify_server_synchronization'),
    (N'verify_job_synchronization');

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

    -- warn if there aren't any job steps with verify_server_synchronization or verify_job_synchronization referenced.
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%verify_server_synchronization%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [dbo].[verify_server_synchronization] was not found.';
    END 

    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%verify_job_synchronization%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [dbo].[verify_job_synchronization] was not found.';
    END 

	-- ditto on data-synch checks: 
	IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%verify_data_synchronization%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 2, N'WARNING', N'A SQL Server Agent Job that calls [dbo].[verify_data_synchronization] was not found.';
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
    (N'process_synchronization_failover');

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
	    SELECT 3, N'ERROR', N'A SQL Server Agent Alert has not been set up to ''trap'' Message 1480 (database failover).';
    END

    -- Warn if no job to respond to failover:
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%process_synchronization_failover%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 3, N'WARNING', N'A SQL Server Agent Job that calls [process_synchronization_failover] (to handle database failover) was not found.';
    END 

    -------------------------------------------------------------------------------------
    -- 4. Monitoring. 

    -- objects/code:
    DELETE FROM @ObjectNames;
    INSERT INTO @ObjectNames (name)
    VALUES 
    (N'verify_data_synchronization');

    INSERT INTO #Errors (SectionID, Severity, ErrorText)
    SELECT 
	    4, 
	    N'ERROR',
	    N'Object [' + x.name + N'] was not found in the master database.'
    FROM 
	    @ObjectNames x
	    LEFT OUTER JOIN admindb.sys.sysobjects o ON o.name = x.name
    WHERE 
	    o.name IS NULL;

    IF EXISTS(SELECT * FROM sys.[database_mirroring] WHERE [mirroring_guid] IS NOT NULL) BEGIN
	    -- If Mirrored dbs are present:
	    -- Make sure the 'stock' MS job "Database Mirroring Monitor Job" is present. 
	    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobs WHERE name = 'Database Mirroring Monitor Job') BEGIN 
		    INSERT INTO #Errors (SectionID, Severity, ErrorText)
		    SELECT 4, N'ERROR', N'The SQL Server Agent (initially provided by Microsoft) entitled ''Database Mirroring Monitor Job'' is not present. Please recreate.';
	    END;
    END; 

    -- Make sure there's a health-check job:
    IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysjobsteps WHERE command LIKE '%data_synchronization_checks%') BEGIN 
	    INSERT INTO #Errors (SectionID, Severity, ErrorText)
	    SELECT 4, N'WARNING', N'A SQL Server Agent Job that calls [data_synchronization_checks] (to run health checks) was not found.';
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
	    N'Object [' + x.[name] + N'] was not found in the admin database.'
    FROM 
	    @ObjectNames x
	    LEFT OUTER JOIN admindb.dbo.sysobjects o ON o.name = x.name
    WHERE 
	    o.name IS NULL;

    DECLARE @settingValue sysname; 
    SELECT @settingValue = ISNULL([setting_value], N'0') FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling';

    IF @settingValue <> N'1' BEGIN
        INSERT INTO #Errors (SectionID, Severity, ErrorText)
        SELECT 5, N'WARNING', N'admindb.dbo.[backup_databases] requires advanced error handling capabilities enabled. Please execute admindb.dbo.enable_advanced_capabilities to enable advanced capabilities.';
    END;

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

    RETURN 0;
GO