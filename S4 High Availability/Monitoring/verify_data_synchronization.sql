/*
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



	TODO:
		[NOTE: the info below now correlates to this parameter: @ExcludeAnomolousSyncDeviations]
			
		document/address problem or issue with Ghosted Records. 
			specifically, we're determining 'lag' and RPOs by means of the vector between primary_last_log_commit and secondary_last_log_commit
				as, normally, they should be within a few milliseconds of each other. 

			Only, imagine a scenario like the following: 
				- very little traffic and/or very few modifications. 
					specifically, a few INSERTs every 10-180 seconds and a FEW DELETEs every 1-2.5 minutes... 

					at this point the last-log-commit time on BOTH servers is going to be, say, 10, 40, or even 120 seconds+ OLD. 
						it'll be the SAME on both - cuz the last change was 'a long time ago' - but it happened synchronously on both servers at/around the exact same time
							so... the VECTOR between those two metrics isn't large - but the duration between NOW and when that happened is ... large-ish. 

				- Ghosted Record Cleanup. 
					this is a process that doesn't have to be synchronously committed - it happens on the primary and (apparently?) gets thrown over the fence to the secondary
						(I actually need to double-check and see if i can spot whether this stuff is happening or not... 
							i.e., all of these 'details' are a very SOLID working THEORY... they're the only thing that really explains what's going on here - and I can see 
								that ghosted record cleanup IS happening on the primary and it IS happening at/around the time of the main problem - i.e., it's the catalyst - or so it appears). 

					meaning that ... 
						we now have 'async' changes ... that are 120+ seconds or whatever apart. 

						I've started to tackle this by means of averages - i.e., instead of taking the RPO 'right now' ... I 'poll' over N seconds and X times. 

						BUT, that's still not enough... i.e., 4x RPOs of 0 and 1x RPO of 147 still weigh in at an average of, say, 45seconds - well over the 15s threshold i normally want. 

						SO, 
							I need to do the following: 
								- 1. set up different options for polling - maybe EVEN by DATABASE... 
									this'll SUCK to put into @Params for this sproc so... instead, I'm going to: 
										a) default the @pollCount and @waitDuration to whatever makes sense (i.e., whatever's already in the sproc below). 
										b) set up options to LOOK FOR 'overwrites' for those defaults ... in the dbo.settings table. 
											and then... POSSIBLY, if i can think of a clean/easy way to tackle it ... look at doing this if/when certain dbs are found or whatever... 
												(probably NOT going to be feasible). 


								- 2. Look at using STDEV - to ignore/'remove'/'flatten' hiccups caused by this problem - as per the 'dogs' stuff here: 
									
										https://www.mathsisfun.com/data/standard-deviation.html

											and further detailed here: 
												https://www.mathsisfun.com/data/standard-deviation-formulas.html

						NOTE: 
							Final implementation is as follows: 
								1. If @ExcludeAnomolousSyncDeviations is enabled... then. 
								2. Calculate the MEAN (AVG) per each DB. 
								3. Also calculate SAMPLE STDEV (i.e., STDEV vs STDEVP) per database. 
								4. Add STDEV to MEAN. 
								5. Substract STDEV from MEAN. 
								6. _IF_ MEAN - STDEV is < 0, then 
									ADD 
										MEAN + STDEV + (ABS(MEAN - STDEV))
									instead of just using STDEV + MEAN (i.e., 'overwrite 'rule' #4'... 

								7. ALLOW removal/exclusion of 1x (i.e., largest) rpo or other target value IF 
									the value of output #6 is > output of #4 AND... the RPO in question is > #6... 


								e.g., 
									RPOs are 
										0
										147 
										0 
										3
										0

									AVG/MEAN = 30 seconds (i.e., 150 / 5) 
									SAMPLED MEAN = 66. 
									30 + 66 = 96 as upper bound (#4)
									30 - 66 = -36 as lower bound. (#5)
									36 + 96 = 132 (#6 - i.e., outcome of #5 was < 0 - so ABS value is added to result of #4). 

									147 IS > 132
										so it's excluded/ignored - meaning we get an average of .75  (i.e., 3 seconds / 4 iterations).
											whereas if @ExcludeAnomolousSyncDeviations had been set to 0, we'd be back at the AVG of 30 seconds. 



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_data_synchronization','P') IS NOT NULL
	DROP PROC dbo.verify_data_synchronization;
GO

CREATE PROC dbo.verify_data_synchronization 
	@IgnoredDatabases						nvarchar(MAX)		= NULL,
	@RPOThreshold							sysname				= N'10 seconds',
	@RTOThreshold							sysname				= N'40 seconds',
	
	@AGSyncCheckIterationCount				int					= 8, 
	@AGSyncCheckDelayBetweenChecks			sysname				= N'1800 milliseconds',
	@ExcludeAnomolousSyncDeviations			bit					= 0,    -- Primarily for Ghosted Records Cleanup... 
	
	@EmailSubjectPrefix						nvarchar(50)		= N'[Data Synchronization Problems] ',
	@MailProfileName						sysname				= N'General',	
	@OperatorName							sysname				= N'Alerts',	
	@PrintOnly								bit					= 0
AS
	SET NOCOUNT ON;

	-- {copyright}

	---------------------------------------------
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

	IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = 'PARTNER') BEGIN 
		RAISERROR('Linked Server ''PARTNER'' not detected. Comparisons between this server and its peer can not be processed.', 16, 1);
		RETURN -5;
	END;

	EXEC @return = dbo.verify_partner 
		@Error = @returnMessage OUTPUT; 

	IF @return <> 0 BEGIN 
		-- S4-229: this (current) response is a hack - i.e., sending email/message DIRECTLY from this code-block violates DRY
		--			and is only in place until dbo.verify_job_synchronization is rewritten to use a process bus.
		IF @PrintOnly = 1 BEGIN 
			PRINT 'PARTNER is disconnected/non-accessible. Terminating early. Connection Details/Error:';
			PRINT '     ' + @returnMessage;
		  END;
		ELSE BEGIN 
			DECLARE @hackSubject nvarchar(200), @hackMessage nvarchar(MAX);
			SELECT 
				@hackSubject = N'PARTNER server is down/non-accessible.', 
				@hackMessage = N'Job Synchronization Checks can not continue as PARTNER server is down/non-accessible. Connection Error Details: ' + NCHAR(13) + NCHAR(10) + @returnMessage; 

			EXEC msdb..sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @hackSubject,
				@body = @hackMessage;
		END;

		RETURN 0;
	END;

	----------------------------------------------
	-- Determine which server to run checks on. 
	IF (SELECT dbo.[is_primary_server]()) = 0 BEGIN
		PRINT 'Server is Not Primary.';
		RETURN 0;
	END;
        
    ----------------------------------------------
	-- Determine the last time this job ran: 
    DECLARE @lastCheckupExecutionTime datetime;
    EXEC [dbo].[get_last_job_completion_by_session_id] 
        @SessionID = @@SPID, 
        @ExcludeFailures = 1, 
        @LastTime = @lastCheckupExecutionTime OUTPUT; 

    SET @lastCheckupExecutionTime = ISNULL(@lastCheckupExecutionTime, DATEADD(HOUR, -2, GETDATE()));

    IF DATEDIFF(DAY, @lastCheckupExecutionTime, GETDATE()) > 2
        SET @lastCheckupExecutionTime = DATEADD(HOUR, -2, GETDATE())

    DECLARE @syncCheckSpanMinutes int = DATEDIFF(MINUTE, @lastCheckupExecutionTime, GETDATE());

    IF @syncCheckSpanMinutes <= 1 
        RETURN 0; -- no sense checking on history if it's just been a minute... 
    
	-- convert vectors to seconds: 
	DECLARE @rpoSeconds decimal(20, 2);
	DECLARE @rtoSeconds decimal(20, 2);

	DECLARE @vectorOutput bigint, @vectorError nvarchar(max); 
    EXEC dbo.translate_vector 
        @Vector = @RPOThreshold, 
        @Output = @vectorOutput OUTPUT, -- milliseconds
		@ProhibitedIntervals = N'DAY, WEEK, MONTH, QUARTER, YEAR',
        @Error = @vectorError OUTPUT; 

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -1;
	END;

	SET @rpoSeconds = @vectorOutput / 1000;
	
    EXEC dbo.translate_vector 
        @Vector = @RTOThreshold, 
        @Output = @vectorOutput OUTPUT, -- milliseconds
		@ProhibitedIntervals = N'DAY, WEEK, MONTH, QUARTER, YEAR',
        @Error = @vectorError OUTPUT; 

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -1;
	END;

	SET @rtoSeconds = @vectorOutput / 1000;

	IF @rtoSeconds > 2764800 OR @rpoSeconds > 2764800 BEGIN 
		RAISERROR(N'@RPOThreshold and @RTOThreshold values can not be set to > 1 month.', 16, 1);
		RETURN -10;
	END;

	IF @rtoSeconds < 2 OR @rpoSeconds < 2 BEGIN 
		RAISERROR(N'@RPOThreshold and @RTOThreshold values can not be set to less than 2 seconds.', 16, 1);
		RETURN -10;
	END;

	-- translate @AGSyncCheckDelayBetweenChecks into waitfor value. 
	DECLARE @waitFor sysname;
	SET @vectorError = NULL;

	EXEC dbo.[translate_vector_delay] 
		@Vector = @AGSyncCheckDelayBetweenChecks, 
		@ParameterName = N'@AGSyncCheckDelayBetweenChecks', 
		@Output = @waitFor OUTPUT, 
		@Error = @vectorError OUTPUT;

	IF @vectorError IS NOT NULL BEGIN 
		RAISERROR(@vectorError, 16, 1);
		RETURN -20;
	END;

    ----------------------------------------------
    -- Begin Processing: 
	DECLARE @localServerName sysname = @@SERVERNAME;
	DECLARE @remoteServerName sysname; 
	EXEC master.sys.sp_executesql N'SELECT @remoteName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE server_id = 0);', N'@remoteName sysname OUTPUT', @remoteName = @remoteServerName OUTPUT;

	-- start by loading a 'list' of all dbs that might be Mirrored or AG'd:
	DECLARE @synchronizingDatabases table ( 
		[server_name] sysname, 
		[sync_type] sysname,
		[database_name] sysname, 
		[role] sysname
	);

	-- grab a list of SYNCHRONIZING (primary) databases (excluding any we're instructed to NOT watch/care about):
	INSERT INTO @synchronizingDatabases (
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	)
	SELECT 
	    [server_name],
	    [sync_type],
	    [database_name], 
		[role]
	FROM 
		dbo.list_synchronizing_databases(@IgnoredDatabases, 1);

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
		WHERE time_recorded >= @lastCheckupExecutionTime;

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
		WHERE time_recorded >= @lastCheckupExecutionTime;
		IF @transdelay > @rpoSeconds BEGIN 
			SET @errorMessage = N'Mirroring Alert - Delays Applying Data to Secondary'
				+ @crlf + @tab + @tab + N'Max Trans Delay of ' + CAST(@transdelay AS nvarchar(30)) + N' in last ' + CAST(@syncCheckSpanMinutes as sysname) + N' minutes is greater than allowed threshold of ' + CAST(@rpoSeconds as sysname) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

			INSERT INTO @errors (errorMessage)
			VALUES (@errorMessage);
		END 

		-- check for problems with transaction delays on the primary:
		SELECT @averagedelay = MAX(ISNULL(average_delay,0)) FROM @output
		WHERE time_recorded >= @lastCheckupExecutionTime;
		IF @averagedelay > @rtoSeconds BEGIN 

			SET @errorMessage = N'Mirroring Alert - Transactions Delayed on Primary'
				+ @crlf + @tab + @tab + N'Max(Avg) Trans Delay of ' + CAST(@averagedelay AS nvarchar(30)) + N' in last ' + CAST(@syncCheckSpanMinutes as sysname) + N' minutes is greater than allowed threshold of ' + CAST(@rtoSeconds as sysname) + N'ms for database: ' + @currentMirroredDB + N' on Server: ' + @localServerName + N'.';

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
		EXEC sys.sp_executesql N'SELECT @currentAGName = ag.[name], @currentAGId = ag.group_id FROM sys.availability_groups ag INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id INNER JOIN sys.databases d ON ar.replica_id = d.replica_id WHERE d.[name] = @currentAGdDatabase;', 
			N'@currentAGdDatabase sysname, @currentAGName sysname OUTPUT, @currentAGId uniqueidentifier OUTPUT', 
			@currentAGdDatabase = @currentAGdDatabase, 
			@currentAGName = @currentAGName OUTPUT, 
			@currentAGId = @currentAGId OUTPUT;

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

		FETCH NEXT FROM ag_checker INTO @currentAGdDatabase;
	END;

	CLOSE ag_checker;
	DEALLOCATE ag_checker;

	CREATE TABLE [#metrics] (
		[row_id] int IDENTITY(1, 1) NOT NULL,
		[database_name] sysname NOT NULL,
		[iteration] int NOT NULL,
		[timestamp] datetime NOT NULL,
		[synchronization_delay (RPO)] decimal(20, 2) NOT NULL,
		[recovery_time (RTO)] decimal(20, 2) NOT NULL,
		-- raw data: 
		[redo_queue_size] decimal(20, 2) NULL,
		[redo_rate] decimal(20, 2) NULL,
		[primary_last_commit] datetime NULL,
		[secondary_last_commit] datetime NULL, 
		[ignore_rpo_as_anomalous] bit NOT NULL CONSTRAINT DF_metrics_anomalous DEFAULT (0)
	);


	DECLARE @iterations int = 1; 
	WHILE @iterations < @AGSyncCheckIterationCount BEGIN

		WITH [metrics] AS (
			SELECT
				[adc].[database_name],
				[drs].[last_commit_time],
				CAST([drs].[redo_queue_size] AS decimal(20,2)) [redo_queue_size],   -- KB of log data not yet 'checkpointed' on the secondary... 
				CAST([drs].[redo_rate] AS decimal(20,2)) [redo_rate],		-- avg rate (in KB) at which redo (i.e., inverted checkpoints) are being applied on the secondary... 
				[drs].[is_primary_replica] [is_primary]
			FROM
				[sys].[dm_hadr_database_replica_states] AS [drs]
				INNER JOIN [sys].[availability_databases_cluster] AS [adc] ON [drs].[group_id] = [adc].[group_id] AND [drs].[group_database_id] = [adc].[group_database_id]
		), 
		[primary] AS ( 
			SELECT
				[database_name],
				[last_commit_time] [primary_last_commit]
			FROM
				[metrics]
			WHERE
				[is_primary] = 1

		), 
		[secondary] AS ( 
			SELECT
				[database_name],
				[last_commit_time] [secondary_last_commit], 
				[redo_rate], 
				[redo_queue_size]
			FROM
				[metrics]
			WHERE
				[is_primary] = 0
		) 

		INSERT INTO [#metrics] (
			[database_name],
			[iteration],
			[timestamp],
			[synchronization_delay (RPO)],
			[recovery_time (RTO)],
			[redo_queue_size],
			[redo_rate],
			[primary_last_commit],
			[secondary_last_commit]
		)
		SELECT 
			p.[database_name], 
			@iterations [iteration], 
			GETDATE() [timestamp],
			DATEDIFF(SECOND, ISNULL(s.[secondary_last_commit], GETDATE()), ISNULL(p.[primary_last_commit], DATEADD(MINUTE, -10, GETDATE()))) [synchronization_delay (RPO)],
			CAST((CASE 
				WHEN s.[redo_queue_size] = 0 THEN 0 
				ELSE ISNULL(s.[redo_queue_size], 0) / s.[redo_rate]
			END) AS decimal(20, 2)) [recovery_time (RTO)],
			s.[redo_queue_size], 
			s.[redo_rate], 
			p.[primary_last_commit], 
			s.[secondary_last_commit]
		FROM 
			[primary] p 
			INNER JOIN [secondary] s ON p.[database_name] = s.[database_name];

		WAITFOR DELAY @waitFor;

		SET @iterations += 1;
	END;

	IF @ExcludeAnomolousSyncDeviations = 1 BEGIN 

		WITH derived AS ( 

			SELECT 
				[database_name],
				CAST(MAX([synchronization_delay (RPO)]) AS decimal(20, 2)) [max],
				CAST(AVG([synchronization_delay (RPO)]) AS decimal(20, 2)) [mean], 
				CAST(STDEV([synchronization_delay (RPO)]) AS decimal(20, 2)) [deviation]
			FROM 
				[#metrics] 
			GROUP BY 
				[database_name]

		), 
		db_iterations AS ( 
	
			SELECT 
				(
					SELECT TOP 1 x.row_id 
					FROM [#metrics] x 
					WHERE x.[synchronization_delay (RPO)] = d.[max] AND [x].[database_name] = d.[database_name] 
					ORDER BY x.[synchronization_delay (RPO)] DESC
				) [row_id]
			FROM 
				[derived] d
			WHERE 
				d.mean - d.[deviation] < 0 -- biz-rule - only if/when deviation 'knocks everything' negative... 
				AND d.[max] > ([d].[mean] + d.[deviation] + ABS([d].[mean] - d.[deviation]))
		)

		UPDATE m 
		SET 
			m.[ignore_rpo_as_anomalous] = 1 
		FROM 
			[#metrics] m 
			INNER JOIN [db_iterations] x ON m.[row_id] = x.[row_id];
	END;

	WITH violations AS ( 
		SELECT 
			[database_name],
			CAST(AVG([synchronization_delay (RPO)]) AS decimal(20, 2)) [rpo (seconds)],
			CAST(AVG([recovery_time (RTO)]) AS decimal(20,2 )) [rto (seconds)], 
			CAST((
				SELECT 
					[x].[iteration] [@iteration], 
					[x].[timestamp] [@timestamp],
					[x].[ignore_rpo_as_anomalous],
					[x].[synchronization_delay (RPO)] [rpo], 
					[x].[recovery_time (RTO)] [rto],
					[x].[redo_queue_size], 
					[x].[redo_rate], 
					[x].[primary_last_commit], 
					[x].[secondary_last_commit]
				FROM 
					[#metrics] x 
				WHERE 
					x.[database_name] = m.[database_name]
				ORDER BY 
					[x].[row_id] 
				FOR XML PATH('detail'), ROOT('details')
			) AS xml) [raw_data]
		FROM 
			[#metrics] m
		WHERE 
			m.[ignore_rpo_as_anomalous] = 0  -- note: these don't count towards rpo values - but they ARE included in serialized xml output (for review/analysis purposes). 
		GROUP BY
			[database_name]
	) 

	INSERT INTO @errors (
		[errorMessage]
	)
	SELECT 
		N'AG Alert - SLA Warning(s) for ' + QUOTENAME([database_name]) + @crlf + @tab + @tab + N'RPO and RTO values are currently set at [' + @RPOThreshold + N'] and [' + @RTOThreshold + N'] - but are currently polling at an AVERAGE of [' + CAST([rpo (seconds)] AS sysname) + N' seconds] AND [' + CAST([rto (seconds)] AS sysname) + N' seconds] for database ' + QUOTENAME([database_name])  + N'. Raw XML Data: ' + CAST([raw_data] AS nvarchar(MAX))
	FROM 
		[violations]
	WHERE 
		[violations].[rpo (seconds)] > @rpoSeconds OR [violations].[rto (seconds)] > @rtoSeconds
	ORDER BY 
		[database_name];

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
				@subject = @subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO