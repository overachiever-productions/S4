/*

	DEPENDENCIES 
		- While the CODE in this sproc has no dependencies on other code, the sproc itself is called when an Alert is fired, which calls a job, which tells this sproc to fire.
		- As such, this sproc won't be called (automatically) unless: 
			a) message_id 1480 has been setup with the WITH_LOG option enabled, 
			b) there's an alert to respond to Error 1480 errors.

	NOTES:
		- While this sproc CAN be executed directly, it is designed to be called by a Failover Alert (which triggers a job, and where the job (in turn) calls this sproc). 

		- This sproc ONLY addresses:
				a) Job States as follows:
					- Batch Jobs for a DB that's now the SECONDARY are disabled. 
					- Batch Jobs for a DB that's now the PRIMARY are set to Enabled. 
					(Batch Jobs = any job where the Job.CategoryName = NameOfASynchronizedDatabase)
				b) attempts to repair orphaned users on DB that has just become the PRIMARY.

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple
	
	
	vNEXT:
		- Look into whether it would make sense to try and 'fire off' a request to process this 'stuff' via service broker - that'd allow for some buffering/padding of operations/etc. 
					'Padding' via 'response' management for the Alert would likely be a MUCH simpler prospect... 
		- Look at adding more info/insight into the failover output messages based on additional details surface by AGs (compared to the limited info we get from mirrored dbs). 
		- Streamline 'jobs' logic in this sproc with that in dbo.verify_job_states. it's dumb to have 2x implementations of that logic. 
		-		instead, dbo.verify_job_states should be able to handle all of this - and have an option to 'spit out info' (instead of 'just' print or email)... 
		-				and then, this sproc can/will call that sproc... to enable DRY.

	SAMPLE EXECUTION:
		
		EXEC admindb.dbo.respond_to_db_failover
			@PrintOnly = 1; -- for testing 



*/


USE [admindb];
GO

IF OBJECT_ID('dbo.respond_to_db_failover','P') IS NOT NULL
	DROP PROC dbo.respond_to_db_failover;
GO

CREATE PROC dbo.respond_to_db_failover 
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname = N'Alerts', 
	@PrintOnly					bit		= 0					-- for testing (i.e., to validate things work as expected)
AS
	SET NOCOUNT ON;

	IF @PrintOnly = 0
		WAITFOR DELAY '00:00:03.00'; -- No, really, give things about 3 seconds (just to let db states 'settle in' to synchronizing/synchronized).

	DECLARE @serverName sysname = @@SERVERNAME;
	DECLARE @username sysname;
	DECLARE @report nvarchar(200);

	DECLARE @orphans table (
		UserName sysname,
		UserSID varbinary(85)
	);

	-- Start by querying current/event-ing server for list of databases and states:
	DECLARE @databases table (
		[db_name] sysname NOT NULL, 
		[sync_type] sysname NOT NULL, -- 'Mirrored' or 'AvailabilityGroup'
		[ag_name] sysname NULL, 
		[primary_server] sysname NULL, 
		[role] sysname NOT NULL, 
		[state] sysname NOT NULL, 
		[is_suspended] bit NULL,
		[is_ag_member] bit NULL,
		[owner] sysname NULL,   -- interestingly enough, this CAN be NULL in some strange cases... 
		[jobs_status] nvarchar(max) NULL,  -- whether we were able to turn jobs off or not and what they're set to (enabled/disabled)
		[users_status] nvarchar(max) NULL, 
		[other_status] nvarchar(max) NULL
	);

	-- account for Mirrored databases:
	INSERT INTO @databases ([db_name], [sync_type], [role], [state], [owner])
	SELECT 
		d.[name] [db_name],
		N'MIRRORED' [sync_type],
		dm.mirroring_role_desc [role], 
		dm.mirroring_state_desc [state], 
		sp.[name] [owner]
	FROM sys.database_mirroring dm
	INNER JOIN sys.databases d ON dm.database_id = d.database_id
	LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
	WHERE 
		dm.mirroring_guid IS NOT NULL
	ORDER BY 
		d.[name];

	-- account for AG databases:
	INSERT INTO @databases ([db_name], [sync_type], [ag_name], [primary_server], [role], [state], [is_suspended], [is_ag_member], [owner])
	SELECT
		dbcs.[database_name] [db_name],
		N'AVAILABILITY_GROUP' [sync_type],
		ag.[name] [ag_name],
		ISNULL(agstates.primary_replica, '') [primary_server],
		ISNULL(arstates.role_desc,'UNKNOWN') [role],
		ISNULL(dbrs.synchronization_state_desc, 'UNKNOWN') [state],
		ISNULL(dbrs.is_suspended, 0) [is_suspended],
		ISNULL(dbcs.is_database_joined, 0) [is_ag_member], 
		x.[owner]
	FROM
		master.sys.availability_groups AS ag
		LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states AS agstates ON ag.group_id = agstates.group_id
		INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
		INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON AR.replica_id = arstates.replica_id AND arstates.is_local = 1
		INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		LEFT OUTER JOIN master.sys.dm_hadr_database_replica_states AS dbrs ON dbcs.replica_id = dbrs.replica_id AND dbcs.group_database_id = dbrs.group_database_id
		LEFT OUTER JOIN (SELECT d.name, sp.name [owner] FROM master.sys.databases d INNER JOIN master.sys.server_principals sp ON d.owner_sid = sp.sid) x ON x.name = dbcs.database_name
	ORDER BY
		AG.name ASC,
		dbcs.database_name;

	-- process:
	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[db_name], 
		[role],
		[state]
	FROM 
		@databases
	ORDER BY 
		[db_name];

	DECLARE @currentDatabase sysname, @currentRole sysname, @currentState sysname; 
	DECLARE @enabledOrDisabled bit; 
	DECLARE @jobsStatus nvarchar(max);
	DECLARE @usersStatus nvarchar(max);
	DECLARE @otherStatus nvarchar(max);

	DECLARE @ownerChangeCommand nvarchar(max);

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		IF @currentState IN ('SYNCHRONIZED','SYNCHRONIZING') BEGIN 
			IF @currentRole IN (N'PRIMARY', N'PRINCIPAL') BEGIN 
				-----------------------------------------------------------------------------------------------
				-- specify jobs status:
				SET @enabledOrDisabled = 1;

				-----------------------------------------------------------------------------------------------
				-- set database owner to 'sa' if it's not owned currently by 'sa':
				IF NOT EXISTS (SELECT NULL FROM master.sys.databases WHERE name = @currentDatabase AND owner_sid = 0x01) BEGIN 
					SET @ownerChangeCommand = N'ALTER AUTHORIZATION ON DATABASE::[' + @currentDatabase + N'] TO sa;';

					IF @PrintOnly = 1
						PRINT @ownerChangeCommand;
					ELSE 
						EXEC sp_executesql @ownerChangeCommand;
				END

				-----------------------------------------------------------------------------------------------
				-- attempt to fix any orphaned users: 
				DELETE FROM @orphans;
				SET @report = N'[' + @currentDatabase + N'].dbo.sp_change_users_login ''Report''';

				INSERT INTO @orphans
				EXEC(@report);

				DECLARE fixer CURSOR LOCAL FAST_FORWARD FOR
				SELECT UserName FROM @orphans;

				OPEN fixer;
				FETCH NEXT FROM fixer INTO @username;

				WHILE @@FETCH_STATUS = 0 BEGIN

					BEGIN TRY 
						IF @PrintOnly = 1 
							PRINT 'Processing Orphans for Principal Database ' + @currentDatabase
						ELSE
							EXEC sp_change_users_login @Action = 'Update_One', @UserNamePattern = @username, @LoginName = @username;  -- note: this only attempts to repair bindings in situations where the Login name is identical to the User name
					END TRY 
					BEGIN CATCH 
						-- swallow... 
					END CATCH

					FETCH NEXT FROM fixer INTO @username;
				END

				CLOSE fixer;
				DEALLOCATE fixer;

				----------------------------------
				-- Report on any logins that couldn't be corrected:
				DELETE FROM @orphans;

				INSERT INTO @orphans
				EXEC(@report);

				IF (SELECT COUNT(*) FROM @orphans) > 0 BEGIN 
					SET @usersStatus = N'Orphaned Users Detected (attempted repair did NOT correct) : ';
					SELECT @usersStatus = @usersStatus + UserName + ', ' FROM @orphans;

					SET @usersStatus = LEFT(@usersStatus, LEN(@usersStatus) - 1); -- trim trailing , 
					END
				ELSE 
					SET @usersStatus = N'No Orphaned Users Detected';					

			  END 
			ELSE BEGIN -- we're NOT the PRINCIPAL instance:
				SELECT 
					@enabledOrDisabled = 0,  -- make sure all jobs are disabled
					@usersStatus = N'', -- nothing will show up...  
					@otherStatus = N''; -- ditto
			  END

		  END
		ELSE BEGIN -- db isn't in SYNCHRONIZED/SYNCHRONIZING state... 
			-- can't do anything because of current db state. So, disable all jobs for db in question, and 'report' on outcome. 
			SELECT 
				@enabledOrDisabled = 0, -- preemptively disable
				@usersStatus = N'Unable to process - due to database state',
				@otherStatus = N'Database in non synchronized/synchronizing state';
		END

		-----------------------------------------------------------------------------------------------
		-- Process Jobs (i.e. toggle them on or off based on whatever value was set above):
		BEGIN TRY 
			DECLARE toggler CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				sj.job_id, sj.name
			FROM 
				msdb.dbo.sysjobs sj
				INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
			WHERE 
				LOWER(sc.name) = LOWER(@currentDatabase);

			DECLARE @jobid uniqueidentifier; 
			DECLARE @jobname sysname;

			OPEN toggler; 
			FETCH NEXT FROM toggler INTO @jobid, @jobname;

			WHILE @@FETCH_STATUS = 0 BEGIN 
		
				IF @PrintOnly = 1 BEGIN 
					PRINT 'EXEC msdb.dbo.sp_updatejob @job_name = ''' + @jobname + ''', @enabled = ' + CAST(@enabledOrDisabled AS varchar(1)) + ';'
				  END
				ELSE BEGIN
					EXEC msdb.dbo.sp_update_job
						@job_id = @jobid, 
						@enabled = @enabledOrDisabled;
				END

				FETCH NEXT FROM toggler INTO @jobid, @jobname;
			END 

			CLOSE toggler;
			DEALLOCATE toggler;

			IF @enabledOrDisabled = 1
				SET @jobsStatus = N'Jobs set to ENABLED';
			ELSE 
				SET @jobsStatus = N'Jobs set to DISABLED';

		END TRY 
		BEGIN CATCH 

			SELECT @jobsStatus = N'ERROR while attempting to set Jobs to ' + CASE WHEN @enabledOrDisabled = 1 THEN ' ENABLED ' ELSE ' DISABLED ' END + '. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(20)) + N' -> ' + ERROR_MESSAGE();
		END CATCH

		-----------------------------------------------------------------------------------------------
		-- Update the status for this job. 
		UPDATE @databases 
		SET 
			[jobs_status] = @jobsStatus,
			[users_status] = @usersStatus,
			[other_status] = @otherStatus
		WHERE 
			[db_name] = @currentDatabase;

		FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;
	END

	CLOSE processor;
	DEALLOCATE processor;
	
	-----------------------------------------------------------------------------------------------
	-- final report/summary. 
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);
	DECLARE @message nvarchar(MAX) = N'';
	DECLARE @subject nvarchar(400) = N'';
	DECLARE @dbs nvarchar(4000) = N'';
	
	SELECT @dbs = @dbs + N'  DATABASE: ' + [db_name] + @crlf 
		+ CASE WHEN [sync_type] = N'AVAILABILITY_GROUP' THEN @tab + N'AG_MEMBERSHIP = ' + (CASE WHEN [is_ag_member] = 1 THEN [ag_name] ELSE 'DISCONNECTED !!' END) ELSE '' END + @crlf
		+ @tab + N'CURRENT_ROLE = ' + [role] + @crlf 
		+ @tab + N'CURRENT_STATE = ' + CASE WHEN is_suspended = 1 THEN N'SUSPENDED !!' ELSE [state] END + @crlf
		+ @tab + N'OWNER = ' + ISNULL([owner], N'NULL') + @crlf 
		+ @tab + N'JOBS_STATUS = ' + jobs_status + @crlf 
		+ @tab + CASE WHEN NULLIF(users_status, '') IS NULL THEN N'' ELSE N'USERS_STATUS = ' + users_status END
		+ CASE WHEN NULLIF(other_status,'') IS NULL THEN N'' ELSE @crlf + @tab + N'OTHER_STATUS = ' + other_status END + @crlf 
		+ @crlf
	FROM @databases
	ORDER BY [db_name];

	SET @subject = N'Database Failover Detected on ' + @serverName;
	SET @message = N'Post failover-response details are as follows: ';
	SET @message = @message + @crlf + @crlf + N'SERVER NAME: ' + @serverName + @crlf;
	SET @message = @message + @crlf + @dbs;

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

	RETURN 0;
GO