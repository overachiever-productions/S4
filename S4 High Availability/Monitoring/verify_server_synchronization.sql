/*
	BUG:
		@ignoredObjects have a hard time with ', x, y' syntax - i.e.,, works fine with ',x,y' but not with 'spaces'. 

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
		- If synchronized databases are NOT owned by the same user (ideally 'sa'), then make sure that dba_RespondToMirroredDatabaseRoleChange 
                switches ownership to the server-principal needed. 
		- Full execution of this sproc nets < 40ms of execution time on the primary.
		- Current implementation doesn't address synch-checks on Server-Level Triggers or Endpoints. (But this could be added if needed.)
		- Differences between logins are NOT addressed either. 
		- Current implementation doesn't offer exclusions (i.e., option to ignore) server-level settings - as they should have SYSTEM-WIDE 
                impact/scope and, therefore, should be identical between servers. 
		- SQL Server Login passwords are hashed on their respective servers - using different 'salts' - so the same password on different 
                servers will LOOK different always (meaning we can't check/verify if passwords are the same).

	SAMPLE EXECUTION:

		EXEC admindb.dbo.verify_server_synchronization 
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
	@IgnoreSynchronizedDatabaseOwnership	    bit		            = 0,					
	@IgnoredMasterDbObjects				        nvarchar(MAX)       = NULL,
	@IgnoredLogins						        nvarchar(MAX)       = NULL,
	@IgnoredAlerts						        nvarchar(MAX)       = NULL,
	@IgnoredLinkedServers				        nvarchar(MAX)       = NULL,
    @IgnorePrincipalNames                       bit                 = 1,                -- e.g., WinName1\Administrator and WinBox2Name\Administrator should both be treated as just 'Administrator'
	@MailProfileName					        sysname             = N'General',					
	@OperatorName						        sysname             = N'Alerts',					
	@PrintOnly							        bit		            = 0						
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

    CREATE TABLE #bus ( 
        [row_id] int IDENTITY(1,1) NOT NULL, 
        [channel] sysname NOT NULL DEFAULT (N'warning'),  -- ERROR | WARNING | INFO | CONTROL | GUIDANCE | OUTCOME (for control?)
        [timestamp] datetime NOT NULL DEFAULT (GETDATE()),
        [parent] int NULL,
        [grouping_key] sysname NULL, 
        [heading] nvarchar(1000) NULL, 
        [body] nvarchar(MAX) NULL, 
        [detail] nvarchar(MAX) NULL, 
        [command] nvarchar(MAX) NULL
    );

	EXEC @return = dbo.verify_partner 
		@Error = @returnMessage OUTPUT; 

	IF @return <> 0 BEGIN 
		INSERT INTO [#bus] (
			[channel],
			[heading],
			[body], 
			[detail]
		)
		VALUES	(
			N'ERROR', 
			N'PARTNER is down/inaccessible.', 
			N'Synchronization Checks against PARTNER server cannot be conducted as connection attempts against PARTNER from ' + @@SERVERNAME + N' failed.', 
			@returnMessage
		)
		
		GOTO REPORTING;
	END;

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END; 

	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;

	IF OBJECT_ID('admindb.dbo.server_trace_flags', 'U') IS NULL BEGIN 
		RAISERROR('Table dbo.server_trace_flags is not present in master. Synchronization check can not be processed.', 16, 1);
		RETURN -6;
	END

	-- Start by updating dbo.server_trace_flags on both servers:
	EXEC dbo.[populate_trace_flags];
	EXEC sp_executesql N'EXEC [PARTNER].[admindb].dbo.populate_trace_flags; ';

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

    ---------------------------------------
	-- Server Level Configuration/Settings: 
	DECLARE @remoteConfig table ( 
		configuration_id int NOT NULL, 
		value_in_use sql_variant NULL
	);	

	INSERT INTO @remoteConfig (configuration_id, value_in_use)
	EXEC master.sys.sp_executesql N'SELECT configuration_id, value_in_use FROM PARTNER.master.sys.configurations;';

    INSERT INTO [#bus] (
        [grouping_key],
        [heading], 
        [body]
    )
    SELECT 
        N'sys.configurations' [grouping_key], 
        N'Setting ' + QUOTENAME([source].[name]) + N' is different between servers.' [heading], 
        N'Value on ' + @localServerName + N' = ' + CAST([source].[value_in_use] AS sysname) + N'. Value on ' + @remoteServerName + N' = ' + CAST([target].[value_in_use] AS sysname) + N'.' [body]
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
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'trace flag' [grouping_key], 
        N'Trace Flag ' + CAST(trace_flag AS sysname) + N' exists only on ' + @localServerName + N'.' [heading] 
	FROM 
		admindb.dbo.server_trace_flags 
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM admindb.dbo.server_trace_flags);

	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'trace flag' [grouping_key],
        N'Trace Flag ' + CAST(trace_flag AS sysname) + N' exists only on ' + @remoteServerName + N'.' [heading]  
	FROM 
		admindb.dbo.server_trace_flags 
	WHERE 
		trace_flag NOT IN (SELECT trace_flag FROM @remoteFlags);

	-- different values: 
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'trace flag' [grouping_key],
        N'Trace Flag Enabled Value is Different Between Servers.' [heading]
	FROM 
		admindb.dbo.server_trace_flags [x]
		INNER JOIN @remoteFlags [y] ON x.trace_flag = y.trace_flag 
	WHERE 
		x.[status] <> y.[status]
		OR x.[global] <> y.[global]
		OR x.[session] <> y.[session];

	---------------------------------------
	-- Make sure sys.messages.message_id #1480 is set so that is_event_logged = 1 (for easier/simplified role change (failover) notifications). Likewise, make sure 1440 is still set to is_event_logged = 1 (the default). 
	DECLARE @remoteMessages table (
		language_id smallint NOT NULL, 
		message_id int NOT NULL, 
		is_event_logged bit NOT NULL
	);

	INSERT INTO @remoteMessages (language_id, message_id, is_event_logged)
	EXEC sp_executesql N'SELECT language_id, message_id, is_event_logged FROM PARTNER.master.sys.messages WHERE message_id IN (1440, 1480);';
    
    -- local:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'error messages' [grouping_key],
        N'The is_event_logged property for message_id ' + CAST(message_id AS sysname) + N' on ' + @localServerName + N' is not set to 1.' [heading]
	FROM 
		sys.messages 
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	-- remote:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading] 
    )    
    SELECT 
        N'error messages' [grouping_key],
        N'The is_event_logged property for message_id ' + CAST(message_id AS sysname) + N' on ' + @remoteServerName + N' is not set to 1.' [heading]
	FROM 
		sys.messages 
	WHERE 
		language_id = @@langid
		AND message_id IN (1440, 1480)
		AND is_event_logged = 0;

	---------------------------------------
	-- admindb checks: 
	DECLARE @localAdminDBVersion sysname;
	DECLARE @remoteAdminDBVersion sysname;

	SELECT @localAdminDBVersion = version_number FROM admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM admindb..version_history);
	EXEC sys.sp_executesql N'SELECT @remoteVersion = version_number FROM PARTNER.admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM PARTNER.admindb.dbo.version_history);', N'@remoteVersion sysname OUTPUT', @remoteVersion = @remoteAdminDBVersion OUTPUT;

	IF @localAdminDBVersion <> @remoteAdminDBVersion BEGIN
        INSERT INTO [#bus] (
            [grouping_key],
            [heading], 
            [body]
        )    
        SELECT 
            N'admindb (s4 versioning)' [grouping_key],
            N'S4 Database versions are different betweent servers.' [heading], 
            N'Version on ' + @localServerName + N' is ' + @localAdminDBVersion + '. Version on' + @remoteServerName + N' is ' + @remoteAdminDBVersion + N'.' [body];
	END;

    DECLARE @localAdvancedValue sysname; 
    DECLARE @remoteAdvancedValue sysname; 

    SELECT @localAdvancedValue = setting_value FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling';
    EXEC sys.sp_executesql N'SELECT @remoteAdvancedValue = setting_value FROM PARTNER.admindb.dbo.settings WHERE [setting_key] = N''advanced_s4_error_handling'';', N'@remoteAdvancedValue sysname OUTPUT', @remoteAdvancedValue = @remoteAdvancedValue OUTPUT;

    IF ISNULL(@localAdvancedValue, N'0') <> ISNULL(@remoteAdvancedValue, N'0') BEGIN 
        INSERT INTO [#bus] (
            [grouping_key],
            [heading], 
            [body]
        )
        SELECT 
            N'admindb (s4 versioning)' [grouping_key],
            N'S4 Advanced Error Handling configuration settings are different betweent servers.' [heading], 
            N'Value on ' + @localServerName + N' is ' + @localAdvancedValue + '. Value on' + @remoteServerName + N' is ' + @remoteAdvancedValue + N'.' [body];
    END; 

	---------------------------------------
	-- Mirrored database ownership:
	IF @IgnoreSynchronizedDatabaseOwnership = 0 BEGIN 
		DECLARE @localOwners table ( 
			[name] nvarchar(128) NOT NULL, 
			sync_type sysname NOT NULL, 
			owner_sid varbinary(85) NULL
		);

		-- mirrored (local) dbs: 
		INSERT INTO @localOwners ([name], sync_type, owner_sid)
		SELECT d.[name], N'Mirrored' [sync_type], d.owner_sid FROM master.sys.databases d INNER JOIN master.sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL; 

		-- AG'd (local) dbs: 
        IF (SELECT admindb.dbo.get_engine_version()) >= 11.0 BEGIN
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
		IF (SELECT admindb.dbo.get_engine_version()) >= 11.0 BEGIN
			INSERT INTO @remoteOwners ([name], sync_type, owner_sid)
			EXEC sp_executesql N'SELECT [name], N''Availability Group'' [sync_type], owner_sid FROM [PARTNER].[master].sys.databases WHERE replica_id IS NOT NULL;';			
		END

        INSERT INTO [#bus] (
            [grouping_key],
            [heading], 
            [body]
        )    
        SELECT 
            N'databases' [grouping_key], 
			[local].sync_type + N' database owners for database ' + QUOTENAME([local].[name]) + N' are different between servers.' [heading], 
            N'To correct: a) Execute a manual failover of database ' + QUOTENAME([local].[name]) + N', and then b) EXECUTE { ALTER AUTHORIZATION ON DATABASE::[' + [local].[name] + N'] TO [sa];  }. NOTE: All synchronized databases should be owned by SysAdmin.'
            -- TODO: instructions on how to fix and/or CONTROL directives TO fix... (only, can't 'fix' this issue with mirrored/AG'd databases).
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
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'linked servers' [grouping_key], 
        N'Linked Server definition for ' + QUOTENAME([local].[name]) + N' exists on ' + @localServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		sys.servers [local]
		LEFT OUTER JOIN @remoteLinkedServers [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].server_id > 0 
		AND [local].[name] <> 'PARTNER'
		AND [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [remote].[name] IS NULL;

	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'linked servers' [grouping_key], 
        N'Linked Server definition for ' + QUOTENAME([remote].[name]) + N' exists on ' + @remoteServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteLinkedServers [remote]
		LEFT OUTER JOIN master.sys.servers [local] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[remote].server_id > 0 
		AND [remote].[name] <> 'PARTNER'
		AND [remote].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND [local].[name] IS NULL;
	
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'linked servers' [grouping_key], 
		N'Linked Server Definition for ' + QUOTENAME([local].[name]) + N' exists on both servers but is different.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		sys.servers [local]
		INNER JOIN @remoteLinkedServers [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @IgnoredLinkedServerNames)
		AND ( 
			[local].product COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].product
			OR [local].[provider] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[provider]
			-- Sadly, PARTNER is a bit of a pain/problem - it has to exist on both servers - but with slightly different versions:
			OR (
				CASE 
					WHEN [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = 'PARTNER' AND [local].[data_source] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[data_source] THEN 0 -- non-true (i.e., non-'different' or non-problematic)
					ELSE 1  -- there's a problem (because data sources are different, but the name is NOT 'Partner'
				END 
				 = 1  
			)
			OR [local].[location] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[location]
			OR [local].provider_string COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].provider_string
			OR [local].[catalog] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[catalog]
			OR [local].is_remote_login_enabled <> [remote].is_remote_login_enabled
			OR [local].is_rpc_out_enabled <> [remote].is_rpc_out_enabled
			OR [local].is_collation_compatible <> [remote].is_collation_compatible
			OR [local].uses_remote_collation <> [remote].uses_remote_collation
			OR [local].collation_name COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].collation_name
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
        [simplified_name] sysname NULL,
		[sid] varbinary(85) NULL,
		[type] char(1) NOT NULL,
		[is_disabled] bit NULL, 
        [password_hash] varbinary(256) NULL
	);

	INSERT INTO @remotePrincipals ([principal_id], [name], [sid], [type], [is_disabled], [password_hash])
	EXEC master.sys.sp_executesql N'
    SELECT 
        p.[principal_id], 
        p.[name], 
        p.[sid], 
        p.[type], 
        p.[is_disabled], 
        l.[password_hash]
    FROM 
        [PARTNER].[master].sys.server_principals p
        LEFT OUTER JOIN [PARTNER].[master].sys.sql_logins l ON p.[principal_id] = l.[principal_id]
    WHERE 
        p.[principal_id] > 10 
        AND p.[name] NOT LIKE ''##%##'' AND p.[name] NOT LIKE ''NT %\%'';';

	DECLARE @localPrincipals table ( 
		[principal_id] int NOT NULL,
		[name] sysname NOT NULL,
        [simplified_name] sysname NULL,
		[sid] varbinary(85) NULL,
		[type] char(1) NOT NULL,
		[is_disabled] bit NULL, 
        [password_hash] varbinary(256) NULL
	);

	INSERT INTO @localPrincipals ([principal_id], [name], [sid], [type], [is_disabled], [password_hash])
    SELECT 
        p.[principal_id], 
        p.[name], 
        p.[sid], 
        p.[type], 
        p.[is_disabled], 
        l.[password_hash]
    FROM 
        [master].sys.server_principals p
        LEFT OUTER JOIN [master].sys.sql_logins l ON p.[principal_id] = l.[principal_id]
    WHERE 
        p.[principal_id] > 10 
        AND p.[name] NOT LIKE '##%##' AND p.[name] NOT LIKE 'NT %\%';

    IF @IgnorePrincipalNames = 1 BEGIN 
        UPDATE @localPrincipals
        SET 
            [simplified_name] = REPLACE([name], @localServerName + N'\', N''),
            [sid] = 0x0
        WHERE 
            [type] = 'U'
            AND [name] LIKE @localServerName + N'\%'; 
            
        UPDATE @remotePrincipals
        SET 
            [simplified_name] = REPLACE([name], @remoteServerName + N'\', N''), 
            [sid] = 0x0
        WHERE 
            [type] = 'U' -- Windows Only... 
            AND [name] LIKE @remoteServerName + N'\%';
    END;

    -- local only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'logins' [grouping_key], 
		N'Login ' + QUOTENAME([local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS) + N' exists on ' + QUOTENAME(@localServerName) + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@localPrincipals [local]
	WHERE 
		ISNULL([local].[simplified_name], [local].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT ISNULL([simplified_name], [name]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @remotePrincipals)
		AND [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM @ignoredLoginName);

	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'logins' [grouping_key], 
		N'Login ' + QUOTENAME([remote].[name] COLLATE SQL_Latin1_General_CP1_CI_AS) + N' exists on ' + QUOTENAME(@remoteServerName) + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remotePrincipals [remote]
	WHERE 
		ISNULL([remote].[simplified_name], [remote].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT ISNULL([simplified_name], [name]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @localPrincipals)
		AND [remote].[name] NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM @ignoredLoginName);

	-- differences
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'logins' [grouping_key], 
		N'Definition for Login ' + QUOTENAME([local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS) + N' is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
        @localPrincipals [local]
        INNER JOIN @remotePrincipals [remote] ON ISNULL([local].[simplified_name], [local].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS = ISNULL([remote].[simplified_name], [remote].[name]) COLLATE SQL_Latin1_General_CP1_CI_AS
	WHERE
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM @ignoredLoginName)
		AND (
			[local].[sid] <> [remote].[sid]
			OR [local].password_hash <> [remote].password_hash  
			OR [local].is_disabled <> [remote].is_disabled
		);

    -- (server) role memberships: 
    DECLARE @localMemberRoles table ( 
        [login_name] sysname NOT NULL, 
        [simplified_name] sysname NULL, 
        [role] sysname NOT NULL
    );

    DECLARE @remoteMemberRoles table ( 
        [login_name] sysname NOT NULL, 
        [simplified_name] sysname NULL, 
        [role] sysname NOT NULL
    );	
    
    -- note, explicitly including NT SERVICE\etc and other 'built in' service accounts as we want to check for any differences in role memberships:
    INSERT INTO @localMemberRoles (
        [login_name],
        [role]
    )
    SELECT 
	    p.[name] [login_name],
	    [roles].[name] [role_name]
    FROM 
	    sys.server_principals p 
	    INNER JOIN sys.server_role_members m ON p.principal_id = m.member_principal_id
	    INNER JOIN sys.server_principals [roles] ON m.role_principal_id = [roles].principal_id
    WHERE 
	    p.principal_id > 10 AND p.[name] NOT LIKE '##%##';

    INSERT INTO @remoteMemberRoles (
        [login_name],
        [role]
    )
    EXEC sys.[sp_executesql] N'
    SELECT 
	    p.[name] [login_name],
	    [roles].[name] [role_name]
    FROM 
	    [PARTNER].[master].sys.server_principals p 
	    INNER JOIN [PARTNER].[master].sys.server_role_members m ON p.principal_id = m.member_principal_id
	    INNER JOIN [PARTNER].[master].sys.server_principals [roles] ON m.role_principal_id = [roles].principal_id
    WHERE 
	    p.principal_id > 10 AND p.[name] NOT LIKE ''##%##''; ';
        
    IF @IgnorePrincipalNames = 1 BEGIN 
        UPDATE @localMemberRoles
        SET 
            [simplified_name] = REPLACE([login_name], @localServerName + N'\', N'')
        WHERE 
            [login_name] LIKE @localServerName + N'\%';

        UPDATE @remoteMemberRoles
        SET 
            [simplified_name] = REPLACE([login_name], @remoteServerName + N'\', N'')
        WHERE 
            [login_name] LIKE @remoteServerName + N'\%';        
    END;

    -- local not in remote:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )   
    SELECT 
        N'logins' [grouping_key], 
        N'Login ' + QUOTENAME([local].[login_name]) + N' is a member of server role ' + QUOTENAME([local].[role]) + N' on server ' + QUOTENAME(@localServerName) + N' only.' [heading]
    FROM 
        @localMemberRoles [local] 
    WHERE 
        (ISNULL([local].[simplified_name], [local].[login_name]) + N'.' + [local].[role]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
            SELECT (ISNULL([simplified_name], [login_name]) + N'.' + [role]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @remoteMemberRoles
        )
        AND [local].[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM @ignoredLoginName);

    -- remote not in local:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )   
    SELECT 
        N'logins' [grouping_key], 
        N'Login ' + QUOTENAME([remote].[login_name]) + N' is a member of server role ' + QUOTENAME([remote].[role]) + N' on server ' + QUOTENAME(@remoteServerName) + N' only.' [heading]
    FROM 
        @remoteMemberRoles [remote] 
    WHERE 
        (ISNULL([remote].[simplified_name], [remote].[login_name]) + N'.' + [remote].[role]) COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (
            SELECT (ISNULL([simplified_name], [login_name]) + N'.' + [role]) COLLATE SQL_Latin1_General_CP1_CI_AS FROM @localMemberRoles
        )
        AND [remote].[login_name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM @ignoredLoginName);

    
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

    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key], 
		N'Operator ' + QUOTENAME([local].[name]) + N' exists on ' + @localServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		msdb.dbo.sysoperators [local]
		LEFT OUTER JOIN @remoteOperators [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[remote].[name] IS NULL;

	-- remote only
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key], 	
        N'Operator ' + QUOTENAME([remote].[name]) + N' exists on ' + @remoteServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteOperators [remote]
		LEFT OUTER JOIN msdb.dbo.sysoperators [local] ON [remote].[name] = [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS
	WHERE 
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS IS NULL;

	-- differences (just checking email address in this particular config):
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key], 
		N'Defintion for Operator ' + QUOTENAME([local].[name]) + N' is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		msdb.dbo.sysoperators [local]
		INNER JOIN @remoteOperators [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].[enabled] <> [remote].[enabled]
		OR [local].[email_address] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[email_address];

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
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'alerts' [grouping_key], 
		N'Alert ' + QUOTENAME([local].[name]) + N' exists on ' + @localServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		msdb.dbo.sysalerts [local]
		LEFT OUTER JOIN @remoteAlerts [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE
		[remote].[name] IS NULL
		AND [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @ignoredAlertName);

    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'alerts' [grouping_key], 
		N'Alert ' + QUOTENAME([remote].[name]) + N' exists on ' + @remoteServerName + N' only.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@remoteAlerts [remote]
		LEFT OUTER JOIN msdb.dbo.sysalerts [local] ON [remote].[name] = [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS
	WHERE
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS IS NULL
		AND [remote].[name] NOT IN (SELECT [name] FROM @ignoredAlertName);

	-- differences:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'operators' [grouping_key],  
		N'Definition for Alert ' + QUOTENAME([local].[name]) + N' is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM	
		msdb.dbo.sysalerts [local]
		INNER JOIN @remoteAlerts [remote] ON [local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS = [remote].[name]
	WHERE 
		[local].[name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @ignoredAlertName)
		AND (
		[local].message_id <> [remote].message_id
		OR [local].severity <> [remote].severity
		OR [local].[enabled] <> [remote].[enabled]
		OR [local].delay_between_responses <> [remote].delay_between_responses
		OR [local].notification_message COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].notification_message
		OR [local].include_event_description <> [remote].include_event_description
		OR [local].[database_name] COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].[database_name]
		OR [local].event_description_keyword COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].event_description_keyword
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
		OR [local].performance_condition COLLATE SQL_Latin1_General_CP1_CI_AS <> [remote].performance_condition
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
	SELECT [name] COLLATE SQL_Latin1_General_CP1_CI_AS FROM master.sys.objects WHERE [type] IN ('U','V','P','FN','IF','TF') AND is_ms_shipped = 0 AND [name] COLLATE SQL_Latin1_General_CP1_CI_AS NOT IN (SELECT [name] FROM @ignoredMasterObjects);
	
	DECLARE @remoteMasterObjects TABLE (
		[object_name] sysname NOT NULL
	);

	INSERT INTO @remoteMasterObjects ([object_name])
	EXEC master.sys.sp_executesql N'SELECT [name] FROM PARTNER.master.sys.objects WHERE [type] IN (''U'',''V'',''P'',''FN'',''IF'',''TF'') AND is_ms_shipped = 0;';
	DELETE FROM @remoteMasterObjects WHERE [object_name] IN (SELECT [name] FROM @ignoredMasterObjects);

	-- local only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'master objects' [grouping_key], 
		N'Object ' + QUOTENAME([local].[object_name]) + N' exists in the master database on ' + @localServerName + N' only.'  [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		@localMasterObjects [local]
		LEFT OUTER JOIN @remoteMasterObjects [remote] ON [local].[object_name] = [remote].[object_name]
	WHERE
		[remote].[object_name] IS NULL;
	
	-- remote only:
    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'master objects' [grouping_key], 
		N'Object ' + QUOTENAME([remote].[object_name]) + N' exists in the master database on ' + @remoteServerName + N' only.'  [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
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
		INNER JOIN @localMasterObjects x ON o.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[object_name];

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

    INSERT INTO [#bus] (
        [grouping_key],
        [heading]
    )    
    SELECT 
        N'master objects' [grouping_key], 
		N'The Definition for object ' + QUOTENAME([local].[object_name]) + N' (in the master database) is different between servers.' [heading]
        -- TODO: instructions on how to fix and/or CONTROL directives TO fix... 
	FROM 
		(SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'local') [local]
		INNER JOIN (SELECT [object_name], [hash] FROM #Definitions WHERE [location] = 'remote') [remote] ON [local].object_name = [remote].object_name
	WHERE 
		[local].[hash] <> [remote].[hash];
	
	------------------------------------------------------------------------------
	-- Report on any discrepancies: 
REPORTING:
	IF(SELECT COUNT(*) FROM #bus) > 0 BEGIN 

		DECLARE @subject nvarchar(300) = N'SQL Server Synchronization Check Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = N'The following synchronization issues were detected: ' + @crlf + @crlf;

        SELECT 
            @message = @message + @tab +  UPPER([channel]) + N': ' + [heading] + CASE WHEN [body] IS NOT NULL THEN @crlf + @tab + @tab + ISNULL([body], N'') ELSE N'' END + @crlf + @crlf
        FROM 
            #bus
        ORDER BY 
            [row_id];


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

	RETURN 0;
GO