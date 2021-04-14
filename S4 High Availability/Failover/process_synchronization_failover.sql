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

IF OBJECT_ID('dbo.process_synchronization_failover','P') IS NOT NULL
	DROP PROC dbo.process_synchronization_failover;
GO

CREATE PROC dbo.process_synchronization_failover 
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname = N'Alerts', 
	@PrintOnly					bit		= 0					-- for testing (i.e., to validate things work as expected)
AS
	SET NOCOUNT ON;

	IF @PrintOnly = 0
		WAITFOR DELAY '00:00:05.00'; -- No, really, give things about 5 seconds (just to let db states 'settle in' to synchronizing/synchronized).


	DECLARE @printedCommands xml; 
	DECLARE @syncSummary xml;

	EXEC [dbo].[process_synchronization_status]
		@PrintOnly = @PrintOnly,
		@PrintedCommands = @printedCommands OUTPUT,
		@SynchronizationSummary = @syncSummary OUTPUT
	
	
	IF @PrintOnly = 1 BEGIN
		DECLARE @commands table (
			command_id int NOT NULL, 
			command nvarchar(MAX) NOT NULL 
		);

		WITH shredded AS ( 
			SELECT 
				[data].[row].value(N'@command_id[1]', N'int') [command_id], 
				[data].[row].value(N'.[1]', N'nvarchar(MAX)') [command]
			FROM 
				@printedCommands.nodes(N'//command') [data]([row])
		)

		INSERT INTO @commands (
			[command_id],
			[command]
		)
		SELECT 
			[command_id],
			[command]
		FROM 
			[shredded] 
		ORDER BY 
			[command_id];
		
		DECLARE @commandText nvarchar(MAX); 

		DECLARE [command_walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			command 
		FROM 
			@commands 
		ORDER BY 
			[command_id];
		
		OPEN [command_walker];
		FETCH NEXT FROM [command_walker] INTO @commandText;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			PRINT @commandText; 
		
			FETCH NEXT FROM [command_walker] INTO @commandText;
		END;
		
		CLOSE [command_walker];
		DEALLOCATE [command_walker];

		PRINT N'';

	END;

	DECLARE @databases table (
		[row_id] int NOT NULL, 
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

	WITH shredded AS ( 
		SELECT 
			[data].[row].value(N'row_id[1]', N'int') [row_id],
			[data].[row].value(N'db_name[1]', N'sysname') [db_name],
			[data].[row].value(N'sync_type[1]', N'sysname') [sync_type],
			[data].[row].value(N'ag_name[1]', N'sysname') [ag_name],
			[data].[row].value(N'primary_server[1]', N'sysname') [primary_server],
			[data].[row].value(N'role[1]', N'sysname') [role],
			[data].[row].value(N'state[1]', N'sysname') [state],
			[data].[row].value(N'is_suspended[1]', N'sysname') [is_suspended],
			[data].[row].value(N'is_ag_member[1]', N'sysname') [is_ag_member],
			[data].[row].value(N'owner[1]', N'sysname') [owner],
			[data].[row].value(N'jobs_status[1]', N'nvarchar(MAX)') [jobs_status],
			[data].[row].value(N'users_status[1]', N'nvarchar(MAX)') [users_status],
			[data].[row].value(N'other_status[1]', N'nvarchar(MAX)') [other_status]
		FROM 
			@syncSummary.nodes(N'//database') [data]([row])

	)
	
	INSERT INTO @databases (
		[row_id],
		[db_name],
		[sync_type],
		[ag_name],
		[primary_server],
		[role],
		[state],
		[is_suspended],
		[is_ag_member],
		[owner],
		[jobs_status],
		[users_status],
		[other_status]
	)
	SELECT 
		[row_id],
		[db_name],
		[sync_type],
		[ag_name],
		[primary_server],
		[role],
		[state],
		[is_suspended],
		[is_ag_member],
		[owner],
		[jobs_status],
		[users_status],
		[other_status] 
	FROM 
		[shredded]
	ORDER BY 
		[row_id];


	DECLARE @serverName sysname = @@SERVERNAME;
	
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