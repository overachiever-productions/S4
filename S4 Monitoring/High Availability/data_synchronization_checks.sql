
/*

	NOTE: this is actively querying tables that don't existin in SQL SErver 2008/2008R2 (i.e., the hadr tables). 


	
	otherwise... the rub here is that the tests I'm doing for Mirrored DBs are a lot different than for AG'd dbs... 

	Here are the signatures of each sproc, for example: 

			CREATE PROC dbo.dba_Mirroring_HealthCheck 
				@OperatorName			sysname, 
				@MailProfileName		sysname,
				@MinutesBack			int				= 10,
				@TransDelayThreshold	int				= 8600,
				@AvgDelayThreshold		int				= 2800,
				@WitnessEnabled			bit, 		
				@PrintOnly				bit				= 0	


		vs

		CREATE PROC dbo.dba_AvailabilityGroups_HealthCheck 
			@MailProfileName		sysname,
			@OperatorName			sysname, 
			@ConsoleOnly			bit				= 0		



		the signature for the AG'd checks is nicer... but... i need to monitor more things via the mirroring checks. 

		either way, the global/big picture for this sproc/approach is that i'll:
			a) make sure this is the primary of the first 'synced' database - or exit execution. 
			b) run any/all alerts for any mirrored dbs. 
			c) run any/all alerts for any AG'd dbs. 
			d) report on any findings/issues. 

			that way, yeah, i'll STILL have 'duplicate' logic for mirrored and AG'd databases - but it won't be in 2x different sprocs. it'll be in one, single, location. (sucks. but sucks LESS.) 



		otherwise, some high-level plans/ideas on 'fixing' the discrepencies in the current signatures:
			1. Mirroring.@WitnessEnabled is something I SHOULD BE able to programatically determine via code - and then just checkon the witness if/when there is one (per each db) - instead of assuming that all dbs will have one or not as that 'switch' implies... 
			2. make sure to look at health of all 2x/3x servers involved - whether mirrored or AG'd. (harder with mirrored, obviously). 
			3. are there DATA /synchronization checks i can run against an AG'd database? If so... streamline/synthesize the 'check' switches/ @params so they'll work for both scenarios. 
				
				otherwise, it MIGHT make more sense to look at something like these:
					https://skreebydba.com/2016/10/31/monitoring-and-alerting-for-availability-groups/

					i.e., data-flow alerts and other alerts... 

					still, the ability to set a threshold from within code and analyze 'rate of stall/redo' and other stuff is pretty nice to have. 
						GUESSING i get some queue and resend/redo and other 'queue' lenght thingies via PerfMon for AGs (assuming I can't find DMVs/DMFs like I'm using with mirroring).





		Other potential fodder: 
			perf counters:
				https://docs.microsoft.com/en-us/sql/relational-databases/performance-monitor/sql-server-database-mirroring-object
				(i should be able to grab those on 'named instances' by simply grabbing the instance name and so on... 
					problem is, those docs kind of suck. 
						e.g.., what is transaction delay? hours, minutes, days? ms? 
							
							I would ASSUME ms... 
								and... this place documents those as being the case:
									https://logicalread.com/sql-server-perf-counters-database-mirroring-tl01/#.WrU4k-jwbAQ
										(still, not sure why MS can't do that). 
												
			possible fodder:
				https://docs.microsoft.com/en-us/sql/database-engine/database-mirroring/use-warning-thresholds-and-alerts-on-mirroring-performance-metrics-sql-server
				
				might also be good: 
					https://technet.microsoft.com/en-us/library/cc917681.aspx?f=255&MSPPError=-2147217396



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.data_synchronization_checks','P') IS NOT NULL
	DROP PROC dbo.data_synchronization_checks;
GO

CREATE PROC dbo.data_synchronization_checks 
	@IgnoredDatabases						nvarchar(MAX)		= NULL,
	@SyncCheckSpanMinutes					int					= 10,  --MKC: might rename this @ExecutionFrequencyMinutes or... soemthing... 
	@TransactionDelayThresholdMS			int					= 8600,
	@AvgerageSyncDelayThresholdMS			int					= 2800,
	@EmailSubjectPrefix						nvarchar(50)		= N'[Data Synchronization Problems] ',
	@MailProfileName						sysname				= N'General',	
	@OperatorName							sysname				= N'Alerts',	
	@PrintOnly								bit						= 0
AS
	SET NOCOUNT ON;

	---------------------------------------------
	-- Validation Checks: 
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

	----------------------------------------------
	-- Determine which server to run checks on. 

	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		server_name sysname, 
		sync_type sysname,
		[database_name] sysname, 
		[role] sysname
	);

	-- Mirrored DBs:
	INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
	SELECT @localServerName [server_name], N'MIRRORED' sync_type, d.[name] [database_name], m.[mirroring_role_desc] FROM sys.databases d INNER JOIN sys.database_mirroring m ON d.database_id = m.database_id WHERE m.mirroring_guid IS NOT NULL;

	-- AG'd DBs (2012 + only):
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE CAST(x.ProductMajorVersion AS int) >= '11') BEGIN
		INSERT INTO @synchronizingDatabases (server_name, sync_type, [database_name], [role])
		EXEC master.sys.[sp_executesql] N'SELECT @localServerName [server_name], N''AG'' [sync_type], d.[name] [database_name], hars.role_desc FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id;', N'@localServerName sysname', @localServerName = @localServerName;
	END;

	-- We're only interested in databases _on this server_ that are in a 'primary' state:
	DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'AG' AND [role] = N'SECONDARY';
	DELETE FROM @synchronizingDatabases WHERE [sync_type] = N'MIRRORED' AND [role] = N'MIRROR';

	-- We're also not interested in any dbs we've been explicitly instructed to ignore: 
	DELETE FROM @synchronizingDatabases WHERE [database_name] IN (SELECT [result] FROM admindb.dbo.[split_string](@IgnoredDatabases, N','));

	IF NOT EXISTS (SELECT NULL FROM @synchronizingDatabases) BEGIN 
		PRINT 'Server is not currently the Primary for any (monitored) synchronizing databases. Execution terminating (but will continue on primary).';
		RETURN 0; -- successful execution (on the secondary) completed.
	END;

	----------------------------------------------
	DECLARE @errors TABLE (
		error_id int IDENTITY(1,1) NOT NULL,
		errorMessage nvarchar(MAX) NOT NULL
	);

	-- http://msdn.microsoft.com/en-us/library/ms366320(SQL.105).aspx
	DECLARE @output TABLE ( 
		[database_name] sysname,
		[role] int, 
		mirroring_state int, 
		witness_status int, 
		log_generation_rate int, 
		unsent_log int, 
		send_rate int, 
		unrestored_log int, 
		recovery_rate int,
		transaction_delay int,
		transactions_per_sec int, 
		average_delay int, 
		time_recorded datetime,
		time_behind datetime,
		local_time datetime
	);

	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @transdelay int;
	DECLARE @averagedelay int;

	----------------------------------------------
	-- Process Mirrored Databases: 
	DECLARE m_checker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@synchronizingDatabases
	WHERE 
		[sync_type] = N'MIRRORED'
	ORDER BY 
		[database_name];

	DECLARE @currentMirroredDB sysname;

	OPEN m_checker;
	FETCH NEXT FROM m_checker INTO @currentMirroredDB;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		DELETE FROM @output;
		SET @errorMessage = N'';

		-- Force an explicit update of the mirroring stats - so that we get the MOST recent details:
		EXEC msdb.sys.sp_dbmmonitorupdate @database_name = @currentMirroredDB;

		INSERT INTO @output
		EXEC msdb.sys.sp_dbmmonitorresults 
			@database_name = @currentMirroredDB,
			@mode = 0, -- just give us the last row - to check current status
			@update_table = 0;  -- This SHOULD be set to 1 - but can/will cause issues with 'nested' INSERT EXEC calls (i.e., a bit of a 'bug'). So... the previous call updates... and we just read the recently updated results. 
		
		IF (SELECT COUNT(*) FROM @output) < 1 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Monitoring not working correctly.'
				+ @crlf + @tab + @tab + N'Database Mirroring Monitoring Failure for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';
				
			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END; 

		IF (SELECT TOP(1) mirroring_state FROM @output) <> 4 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Mirroring Disabled'
				+ @crlf + @tab + @tab + N'Synchronization Failure for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END

		-- check on the witness if needed:
		IF EXISTS (SELECT mirroring_witness_state_desc FROM sys.database_mirroring WHERE database_id = DB_ID(@currentMirroredDB) AND NULLIF(mirroring_witness_state_desc, N'UNKNOWN') IS NOT NULL) BEGIN 
			IF (SELECT TOP(1) witness_status FROM @output) <> 1 BEGIN
				SET @errorMessage = N'Mirroring Failure - Witness Down'
					+ @crlf + @tab + @tab + N'Witness Failure. Witness is currently not enabled or monitoring for database ' + @currentMirroredDB + N' on Server ' + @localServerName + N'.';

				INSERT INTO @errors (errorMessage)
				VALUES (@errorMessage);
			END;
		END;

		-- now that we have the info, start working through various checks/validations and raise any alerts if needed: 

		-- make sure that metrics are even working - if we get any NULLs in transaction_delay/average_delay, 
		--		then it's NOT working correctly (i.e. it's somehow not seeing everything it needs to in order
		--		to report - and we need to throw an error):
		SELECT @transdelay = MIN(ISNULL(transaction_delay,-1)) FROM	@output 
		WHERE time_recorded >= DATEADD(n, 0 - @SyncCheckSpanMinutes, GETUTCDATE());

		DELETE FROM @output; 
		INSERT INTO @output
		EXEC msdb.sys.sp_dbmmonitorresults 
			@database_name = @currentMirroredDB,
			@mode = 1,  -- give us rows from the last 2 hours:
			@update_table = 0;

		IF @transdelay < 0 BEGIN 
			SET @errorMessage = N'Mirroring Failure - Synchronization Metrics Unavailable'
				+ @crlf + @tab + @tab + N'Metrics for transaction_delay and average_delay unavailable for monitoring (i.e., SQL Server Mirroring Monitor is ''busted'') for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END;

		-- check for problems with transaction delay:
		SELECT @transdelay = MAX(ISNULL(transaction_delay,0)) FROM @output
		WHERE time_recorded >= DATEADD(n, 0 - @SyncCheckSpanMinutes, GETUTCDATE());
		IF @transdelay > @TransactionDelayThresholdMS BEGIN 
			SET @errorMessage = N'Mirroring Alert - Delays Applying Snapshot to Secondary'
				+ @crlf + @tab + @tab + N'Max Trans Delay of ' + CAST(@transdelay AS nvarchar(30)) + N' in last ' + CAST(@SyncCheckSpanMinutes as nvarchar(20)) + N' minutes is greater than allowed threshold of ' + CAST(@TransactionDelayThresholdMS as nvarchar(30)) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 

		-- check for problems with transaction delays on the primary:
		SELECT @averagedelay = MAX(ISNULL(average_delay,0)) FROM @output
		WHERE time_recorded >= DATEADD(n, 0 - @SyncCheckSpanMinutes, GETUTCDATE());
		IF @averagedelay > @AvgerageSyncDelayThresholdMS BEGIN 

			SET @errorMessage = N'Mirroring Alert - Transactions Delayed on Primary'
				+ @crlf + @tab + @tab + N'Max(Avg) Trans Delay of ' + CAST(@averagedelay AS nvarchar(30)) + N' in last ' + CAST(@SyncCheckSpanMinutes as nvarchar(20)) + N' minutes is greater than allowed threshold of ' + CAST(@AvgerageSyncDelayThresholdMS as nvarchar(30)) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 		

		FETCH NEXT FROM m_checker INTO @currentMirroredDB;
	END;

	CLOSE m_checker; 
	DEALLOCATE m_checker;

	
	----------------------------------------------
	-- Process AG'd Databases: 
	IF EXISTS (SELECT NULL FROM (SELECT SERVERPROPERTY('ProductMajorVersion') AS [ProductMajorVersion]) x WHERE CAST(x.ProductMajorVersion AS int) <= '10')
		GOTO REPORTING;

	DECLARE @downNodes nvarchar(MAX);
	DECLARE @currentAGName sysname;
	DECLARE @currentAGId uniqueidentifier;
	DECLARE @syncHealth tinyint;

	DECLARE @processedAgs table ( 
		agname sysname NOT NULL
	);

	DECLARE ag_checker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@synchronizingDatabases
	WHERE 
		[sync_type] = N'AG'
	ORDER BY 
		[database_name];

	DECLARE @currentAGdDatabase sysname; 

	OPEN ag_checker;
	FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN 
	
		SET @currentAGName = N'';
		SET @currentAGId = NULL;
		EXEC master.sys.sp_executesql N'SELECT @currentAGName = ag.[name], @currentAGId = ag.group_id FROM sys.availability_groups ag INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id INNER JOIN sys.databases d ON ar.replica_id = d.replica_id WHERE d.[name] = @currentAGdDatabase;', N'@currentAGdDatabase sysname, @currentAGName sysname OUTPUT, @currentAGId uniqueidentifier OUTPUT', @currentAGdDatabase = @currentAGdDatabase, @currentAGName = @currentAGName OUTPUT, @currentAGId = @currentAGId OUTPUT;

		IF NOT EXISTS (SELECT NULL FROM @processedAgs WHERE agname = @currentAGName) BEGIN
		
			-- Make sure there's an active primary:
-- TODO: in this new, streamlined, code... this check (at this point) is pointless. 
--		need to check this well before we get to the CURSOR for processing AGs, AG'd dbs... 
--			also, there might be a quicker/better way to get a 'list' of all dbs in a 'bad' (non-primary'd) state right out of the gate. 
--			AND, either way I slice it, i'll have to tackle this via sp_executesql - to account for lower-level servers. 
			--SELECT @primaryReplica = agstates.primary_replica
			--FROM sys.availability_groups ag 
			--LEFT OUTER JOIN sys.dm_hadr_availability_group_states agstates ON ag.group_id = agstates.group_id
			--WHERE 
			--	ag.[name] = @currentAGdDatabase;
			
			--IF ISNULL(@primaryReplica,'') = '' BEGIN 
			--	SET @errorMessage = N'MAJOR PROBLEM: No Replica is currently defined as the PRIMARY for Availability Group [' + @currentAG + N'].';

			--	INSERT INTO @errors (errorMessage)
			--	VALUES(@errorMessage);
			--END 
			

			-- Check on Status of all members:
			SET @downNodes = N'';
			EXEC master.sys.sp_executesql N'SELECT @downNodes = @downNodes +  member_name + N'','' FROM sys.dm_hadr_cluster_members WHERE member_state <> 1;', N'@downNodes nvarchar(MAX) OUTPUT', @downNodes = @downNodes OUTPUT; 
			IF LEN(@downNodes) > LEN(N'') BEGIN 
				SET @downNodes = LEFT(@downNodes, LEN(@downNodes) - 1); 
			
				SET @errorMessage = N'WARNING: The following WSFC Cluster Member Nodes are currently being reported as offline: ' + @downNodes + N'.';	

				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END

			-- Check on AG Health Status: 
			SET @syncHealth = 0;
			EXEC master.sys.sp_executesql N'SELECT @syncHealth = synchronization_health FROM sys.dm_hadr_availability_replica_states WHERE group_id = @currentAGId;', N'@currentAGId uniqueidentifier, @syncHealth tinyint OUTPUT', @currentAGId = @currentAGId, @syncHealth = @syncHealth OUTPUT;
			IF @syncHealth <> 2 BEGIN
				SELECT @errorMessage = N'WARNING: Current Health Status of Availability Group [' + @currentAGName + N'] Is Showing NON-HEALTHY.'
			
				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END; 

			-- Check on Synchronization Status of each db:
			SET @syncHealth = 0;
			EXEC master.sys.sp_executesql N'SELECT @syncHealth = synchronization_health FROM sys.dm_hadr_availability_replica_states WHERE group_id = @currentAGId;', N'@currentAGId uniqueidentifier, @syncHealth tinyint OUTPUT', @currentAGId = @currentAGId, @syncHealth = @syncHealth OUTPUT;
			IF @syncHealth <> 2 BEGIN
				SELECT @errorMessage = N'WARNING: The Synchronization Status for one or more Members of the Availability Group [' + @currentAGName + N'] Is Showing NON-HEALTHY.'
			
				INSERT INTO @errors (errorMessage)
				VALUES(@errorMessage);
			END;


			-- mark the current AG as processed (so that we don't bother processing multiple dbs (and getting multiple errors/messages) if/when they're all in the same AG(s)). 
			INSERT INTO @processedAgs ([agname])
			VALUES(@currentAGName);
		END;
		-- otherwise, we've already run checks on the availability group itself. 

		-- TODO: implement synchronization (i.e., lag/timing/threshold/etc.) logic per each synchronized database... (i.e., here).
		-- or... maybe this needs to be done per AG? not sure of what makes the most sense. 
		--		here's a link though: https://www.sqlshack.com/measuring-availability-group-synchronization-lag/
		--			NOTE: in terms of implementing 'monitors' for the above... the queries that Derik provides are all awesome. 
		--				Only... AGs don't work the same way as... mirroring. with mirroring, i can 'query' a set of stats captured over the last x minutes. and see if there have been any problems DURING that window... 
		--				with these queries... if there's not a problem this exact second... then... everything looks healthy. 
		--				so, there's a very real chance i might want to: 
		--					a) wrap up Derik's queries into a sproc that can/will dump metrics into a table within admindb... (and only keep them for a max of, say, 2 months?)
		--							err... actually, the sproc will have @HistoryRetention = '2h' or '2m' or whatever... (obviously not '2b')... 
		--					b) spin up a job that collects those stats (i.e., runs the job) every ... 30 seconds or someting tame but viable? 
		--					c) have this query ... query that info over the last n minutes... similar to what I'm doing to detect mirroring 'lag' problems.

		FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;
	END;


	CLOSE ag_checker;
	DEALLOCATE ag_checker;


REPORTING:
	-- 
	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';

		SET @errorMessage = N'The following errors were detected: ' + @crlf;

		SELECT @errorMessage = @errorMessage + @tab + N'- ' + errorMessage + @crlf
		FROM @errors
		ORDER BY error_id;

		IF @PrintOnly = 1 BEGIN
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @errorMessage;
		  END
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @Subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO

