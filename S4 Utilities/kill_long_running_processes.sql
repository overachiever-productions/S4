/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[kill_long_running_processes]','P') IS NOT NULL
	DROP PROC dbo.[kill_long_running_processes];
GO

CREATE PROC dbo.[kill_long_running_processes]
	@ExecutionThresholdSeconds				int					= 70, 
	@ExcludeBackupsAndRestores				bit					= 1, 
	@ExcludeSqlServerAgentJobs				bit					= 1, 
	@Databases								nvarchar(MAX)		= NULL,
	@Applications							nvarchar(MAX)		= NULL, 
	@Principals								nvarchar(MAX)		= NULL, 
	@Hosts									nvarchar(MAX)		= NULL, 
	@Statements								nvarchar(MAX)		= NULL,
	@CaptureDetails							bit					= 1, 
	@SendAlerts								bit					= 1, 
	@OperatorName							sysname				= N'Alerts',
	@MailProfileName						sysname				= N'General',
	@EmailSubjectPrefix						nvarchar(50)		= N'[Long-Running Processes]',
	@PrintOnly								bit					= 0		
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExecutionThresholdSeconds = ISNULL(@ExecutionThresholdSeconds, 70);
	SET @ExcludeBackupsAndRestores = ISNULL(@ExcludeBackupsAndRestores, 1);
	SET @ExcludeSqlServerAgentJobs = ISNULL(@ExcludeSqlServerAgentJobs, 1);

	SET @Databases = NULLIF(@Databases, N'');
	SET @Applications = NULLIF(@Applications, N'');
	SET @Principals = NULLIF(@Principals, N'');
	SET @Hosts = NULLIF(@Hosts, N'');
	SET @Statements = NULLIF(@Statements, N'');

	SET @CaptureDetails = ISNULL(@CaptureDetails, 1);
	SET @SendAlerts = ISNULL(@SendAlerts, 1);
	SET @OperatorName = ISNULL(NULLIF(@OperatorName, N''), N'Alerts');
	SET @MailProfileName = ISNULL(NULLIF(@MailProfileName, N''), N'General');
	SET @EmailSubjectPrefix = ISNULL(NULLIF(@EmailSubjectPrefix, N''), N'[Long-Running Processes]');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Extract TOP N results - and run basic (short-circuiting) predicates:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #results (
		[session_id] smallint NOT NULL,
		[blocked_by] smallint NULL,
		[db_name] nvarchar(128) NULL,
		[text] nvarchar(max) NULL,
		[cpu_time] int NOT NULL,
		[reads] bigint NOT NULL,
		[writes] bigint NOT NULL,
		[elapsed_time] int NOT NULL,
		[wait_time] int NOT NULL,
		[last_wait_type] nvarchar(60) NOT NULL,
		[granted_mb] decimal(20, 2) NOT NULL,
		[status] nvarchar(30) NOT NULL,
		[command] nvarchar(32) NOT NULL,
		[program_name] nvarchar(128) NULL,
		[host_name] nvarchar(128) NULL,
		[login_name] nvarchar(128) NULL,
		[percent_complete] real NOT NULL,
		[isolation_level] varchar(14) NULL,
		[open_tran] int NOT NULL,
		[statement_plan] xml NULL,
		[batch_plan] xml NULL,
		[plan_handle] varbinary(64) NULL
	);

	INSERT INTO [#results]
	(
		[session_id],
		[blocked_by],
		[db_name],
		[text],
		[cpu_time],
		[reads],
		[writes],
		[elapsed_time],
		[wait_time],
		[last_wait_type],
		[granted_mb],
		[status],
		[command],
		[program_name],
		[host_name],
		[login_name],
		[percent_complete],
		[isolation_level],
		[open_tran],
		[statement_plan],
		[batch_plan],
		[plan_handle]
	)
	EXEC dbo.[list_top]
		@TopRequests = 100;

	IF EXISTS (SELECT NULL FROM [#results]) BEGIN 
		DELETE FROM [#results] WHERE [session_id] IS NULL; -- no idea why/how this one happens... but it occasionally does. 
		DELETE FROM [#results] WHERE [session_id] IN (SELECT [session_id] FROM sys.[dm_exec_sessions] WHERE [is_user_process] = 0);

		DELETE FROM [#results] WHERE [text] = N'sp_server_diagnostics'; -- i.e., don't kill long-running clustering diagnostics.

		DELETE FROM [#results] WHERE [elapsed_time] < @ExecutionThresholdSeconds * 1000;

		IF @ExcludeSqlServerAgentJobs = 1 BEGIN 
			DELETE FROM [#results] WHERE [program_name] LIKE N'SQLAgent%';
		END;

		IF @ExcludeBackupsAndRestores = 1 BEGIN 
			DELETE FROM [#results] WHERE [command] LIKE N'%BACKUP%' OR [command] LIKE N'%RESTORE%' OR [command] LIKE N'%DBCC%';
		END;
	END;

	IF NOT EXISTS (SELECT NULL FROM [#results]) BEGIN 
		RETURN 0; -- short-circuit.
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Explicit Filtering / Predication:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @rowId int; 
	DECLARE @outcome int = 0;

	IF @Databases IS NOT NULL BEGIN 
		DECLARE @databasesValues table (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[databases_value] sysname NOT NULL 
		); 

		CREATE TABLE #expandedDatabases (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [database_name])
		);

		INSERT INTO @databasesValues ([databases_value])
		SELECT [result] FROM dbo.[split_string](@Databases, N',', 1);

		INSERT INTO [#expandedDatabases] ([database_name], [is_exclude])
		SELECT 
			CASE WHEN [databases_value] LIKE N'-%' THEN RIGHT([databases_value], LEN([databases_value]) -1) ELSE [databases_value] END [database_name],
			CASE WHEN [databases_value] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			@databasesValues 
		WHERE 
			[databases_value] NOT LIKE N'%{%';

		IF EXISTS (SELECT NULL FROM @databasesValues WHERE [databases_value] LIKE N'%{%') BEGIN 
			DECLARE @databasesToken sysname, @dbTokenAbsolute sysname;
			DECLARE @databasesXml xml;

			DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				[row_id], 
				[databases_value]
			FROM 
				@databasesValues 
			WHERE 
				[databases_value] LIKE N'%{%';
			
			OPEN [walker];
			FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			
			WHILE @@FETCH_STATUS = 0 BEGIN
				
				SET @outcome = 0;
				SET @databasesXml = NULL;
				SELECT @dbTokenAbsolute = CASE WHEN @databasesToken LIKE N'-%' THEN RIGHT(@databasesToken, LEN(@databasesToken) -1) ELSE @databasesToken END;

				EXEC @outcome = dbo.[list_databases_matching_token]
					@Token = @dbTokenAbsolute,
					@SerializedOutput = @databasesXml OUTPUT;

				IF @outcome <> 0 
					RETURN @outcome; 

				WITH shredded AS ( 
					SELECT
						[data].[row].value('@id[1]', 'int') [row_id], 
						[data].[row].value('.[1]', 'sysname') [database_name]
					FROM 
						@databasesXml.nodes('//database') [data]([row])
				) 
				
				INSERT INTO [#expandedDatabases] ([database_name], [is_exclude])
				SELECT 
					[database_name], 
					CASE WHEN @databasesToken LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
				FROM 
					shredded
				WHERE 
					[database_name] NOT IN (SELECT [database_name] FROM [#expandedDatabases])
				ORDER BY 
					[row_id];
				
				FETCH NEXT FROM [walker] INTO @rowId, @databasesToken;
			END;
			
			CLOSE [walker];
			DEALLOCATE [walker];
		END;

		IF EXISTS (SELECT NULL FROM [#expandedDatabases] WHERE [is_exclude] = 1) BEGIN 
			DELETE FROM [#results] 
			WHERE [db_name] IN (SELECT [database_name] FROM [#expandedDatabases] WHERE [is_exclude] = 1);
		END;

		IF EXISTS (SELECT NULL FROM [#expandedDatabases] WHERE [is_exclude] = 0) BEGIN
			DELETE FROM [#results] 
			WHERE [db_name] NOT IN (SELECT [database_name] FROM [#expandedDatabases] WHERE [is_exclude] = 0);
		END;
	END;

	IF @Applications IS NOT NULL BEGIN 
		CREATE TABLE #applications (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[application_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [application_name]) 
		);

		INSERT INTO [#applications] ([application_name], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [application_name], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			[dbo].[split_string](@Applications, N',', 1);

		IF EXISTS (SELECT NULL FROM [#applications] WHERE [is_exclude] = 1) BEGIN
			DELETE FROM [#results] 
			WHERE [program_name] IN (SELECT [application_name] FROM [#applications] WHERE [is_exclude] = 1);
		END;

		IF EXISTS (SELECT NULL FROM [#applications] WHERE [is_exclude] = 0) BEGIN 
			DELETE FROM [#results] 
			WHERE [program_name] NOT IN (SELECT [application_name] FROM [#applications] WHERE [is_exclude] = 0);
		END; 
	END;

	IF @Hosts IS NOT NULL BEGIN 
		CREATE TABLE #hosts (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[host_name] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [host_name])
		); 

		INSERT INTO [#hosts] ([host_name], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [host], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM	
			dbo.[split_string](@Hosts, N',', 1);

		IF EXISTS (SELECT NULL FROM [#hosts] WHERE [is_exclude] = 1) BEGIN
			DELETE FROM [#results] 
			WHERE [host_name] IN (SELECT [host_name] FROM [#hosts] WHERE [is_exclude] = 1);
		END;

		IF EXISTS (SELECT NULL FROM [#hosts] WHERE [is_exclude] = 0) BEGIN
			DELETE FROM [#results] 
			WHERE [host_name] NOT IN (SELECT [host_name] FROM [#hosts] WHERE [is_exclude] = 0);				
		END;
	END;

	IF @Principals IS NOT NULL BEGIN
		CREATE TABLE #principals (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[principal] sysname NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude], [principal])
		); 

		INSERT INTO [#principals] ([principal], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) END [principal],
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]
		FROM 
			[dbo].[split_string](@Principals, N',', 1);

		IF EXISTS (SELECT NULL FROM [#principals] WHERE [is_exclude] = 1) BEGIN 
			DELETE FROM [#results] 
			WHERE [login_name] IN (SELECT [principal] FROM [#principals] WHERE [is_exclude] = 1);
		END;

		IF EXISTS (SELECT NULL FROM [#principals] WHERE [is_exclude] = 0) BEGIN 
			DELETE FROM [#results] 
			WHERE [login_name] NOT IN (SELECT [principal] FROM [#principals] WHERE [is_exclude] = 0);
		END; 
	END;

	IF @Statements IS NOT NULL BEGIN 
		CREATE TABLE #statements (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[statement] nvarchar(MAX) NOT NULL, 
			[is_exclude] bit DEFAULT(0), 
			PRIMARY KEY CLUSTERED ([is_exclude]) 
		);

		INSERT INTO [#statements] ([statement], [is_exclude])
		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) - 1) ELSE [result] END [statement],
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [is_exclude]			
		FROM 
			dbo.[split_string](@Statements, N', ', 1);

		IF EXISTS (SELECT NULL FROM [#statements] WHERE [is_exclude] = 1) BEGIN 
			DELETE r
			FROM 
				[#results] r 
				INNER JOIN [#statements] s ON r.[text] LIKE s.[statement] AND [s].[is_exclude] = 1;
		END; 

		IF EXISTS (SELECT NULL FROM [#statements] WHERE [is_exclude] = 0) BEGIN 
			DELETE r 
			FROM 
				[#results] r 
				LEFT OUTER JOIN [#statements] s ON r.[text] LIKE s.[statement] AND s.[is_exclude] = 0
			WHERE 
				s.[statement] IS NULL;
		END;
	END;		

	IF NOT EXISTS (SELECT NULL FROM [#results]) BEGIN 
		RETURN 0; -- short-circuit.
	END;	

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Snapshot / Persist any Processes that have made it to this point (whether @PrintOnly = 1 or not):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @CaptureDetails = 1 BEGIN 
		INSERT INTO dbo.[long_running_process_snapshots]
		(
			[timestamp],
			[print_only],
			[send_alerts],
			[session_id],
			[blocked_by],
			[db_name],
			[text],
			[cpu_time],
			[reads],
			[writes],
			[elapsed_time],
			[wait_time],
			[last_wait_type],
			[granted_mb],
			[status],
			[command],
			[program_name],
			[host_name],
			[login_name],
			[percent_complete],
			[isolation_level],
			[open_tran],
			[statement_plan],
			[batch_plan],
			[plan_handle]
		)
		SELECT 
			GETUTCDATE() [timestamp], 
			@PrintOnly [print_only], 
			@SendAlerts [sent_alerts],
			[session_id],
			[blocked_by],
			[db_name],
			[text],
			[cpu_time],
			[reads],
			[writes],
			[elapsed_time],
			[wait_time],
			[last_wait_type],
			[granted_mb],
			[status],
			[command],
			[program_name],
			[host_name],
			[login_name],
			[percent_complete],
			[isolation_level],
			[open_tran],
			[statement_plan],
			[batch_plan],
			[plan_handle]
		FROM 
			[#results] 
		ORDER BY 
			[cpu_time] DESC;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Execute KILL operations:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @command nvarchar(MAX); 
	DECLARE @sessionId int; 

	DECLARE [killer] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[session_id] 
	FROM 
		[#results] 
	ORDER BY 
		[cpu_time] DESC;
	
	OPEN [killer];
	FETCH NEXT FROM [killer] INTO @sessionId;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @command = N'KILL ' + CAST(@sessionId AS sysname) + N';';

		IF @PrintOnly = 1 
			PRINT @command; 
		ELSE BEGIN 
			BEGIN TRY 
				EXEC(@command);
			END TRY 
			BEGIN CATCH

			END CATCH;
		END;
	
		FETCH NEXT FROM [killer] INTO @sessionId;
	END;
	
	CLOSE [killer];
	DEALLOCATE [killer];

	DECLARE @body nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	SELECT 
		@body = @body + N'KILLED -> ' + 
			@crlf + @tab + N'SESSION ID             : ' + CAST(ISNULL([session_id], -1) AS sysname) +
			@crlf + @tab + N'Database			    : ' + CAST(ISNULL([db_name], N'') AS sysname) + 
			@crlf + @tab + N'CPU Time (ms)		    : ' + CAST(ISNULL([cpu_time], N'') AS sysname) + 
			@crlf + @tab + N'Elapsed Time (ms)      : ' + CAST(ISNULL([elapsed_time], N'') AS sysname) +
			@crlf + @tab + N'Command                : ' + ISNULL([command], N'') +
			@crlf + @tab + N'Last Wait Type         : ' + ISNULL([last_wait_type], N'') +
			@crlf + @tab + N'Isolation Level        : ' + ISNULL([isolation_level], N'#UNKNOWN#') +
			@crlf + @tab + N'Program Name           : ' + ISNULL([program_name], N'') +
			@crlf + @tab + N'Host                   : ' + ISNULL([host_name], N'') +
			@crlf + @tab + N'Login                  : ' + ISNULL([login_name], N'') +
			@crlf + @tab + N'Statement: [' + 
			@crlf + @tab + @tab + REPLACE(RTRIM(ISNULL([text], N'')), @crlf, @crlf + @tab + @tab) +
			@crlf + @crlf + @tab + N']' +
			@crlf + @crlf
	FROM 
		[#results] 
	ORDER BY 
		[elapsed_time] DESC;


	DECLARE @subject sysname; 
	DECLARE @message nvarchar(MAX);

	SET @subject = ISNULL(@EmailSubjectPrefix, N'') + N' - Long-Running Processes were KILLED';
	SET @message = N'The following long-running processes were detected and _KILLED_ on ' + @@SERVERNAME + N' because they exceeded execution thresholds of ' + CAST(@ExecutionThresholdSeconds AS sysname) + N' seconds: ' + @crlf + @crlf;
	SET @message = @message + @body; 

	IF @SendAlerts = 1 BEGIN 
		IF @PrintOnly = 1 BEGIN 
			PRINT N'---------------------------------------------------------------------------------------------';
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @message;
		  END;
		ELSE BEGIN 
			EXEC [msdb]..[sp_notify_operator]
			@profile_name = @MailProfileName,
			@name = @OperatorName,
			@subject = @subject, 
			@body = @message;	
		END;
	END;

	RETURN 0;
GO