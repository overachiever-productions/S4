/*
	WARNING: 
		- This sproc is designed for emergency scenarios where 'runaway' statements are causing major perf issues (swamping a given server). 
		- It is only designed to temporarily remove/alleviate load while a better solution is found. 

	vNEXT:
		- Add an [exclusion] column to #results. 
				and instead of simply DELETE-ing from #results when white-listing or excluding/etc.... 
				'update' this column to explain why... 
				Then... only KILL where [exclusion] IS NULL... 
					and spit out a list of matches that were, otherwise, excluded (i.e., SELECT * FROM #results - so'z we can see exclusion reasons).



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.kill_connections_by_statement','P') IS NOT NULL
	DROP PROC dbo.[kill_connections_by_statement];
GO

CREATE PROC dbo.[kill_connections_by_statement]
	@StatementPattern						nvarchar(MAX), 
	@CpuMillisecondsThreshold				int					= 2200,
	@KillableApplicationNames				nvarchar(MAX)		= NULL,			
	@KillableHostNames						nvarchar(MAX)		= NULL,			
	@KillableLogins							nvarchar(MAX)		= NULL,
	@KillableDatabases						nvarchar(MAX)		= NULL,
	@ExcludeBackupsAndRestores				bit					= 1,			
	@ExcludeSqlServerAgentJobs				bit					= 1,			
	@ExcludedApplicationNames				nvarchar(MAX)		= NULL,		
	@ExcludedHostNames						nvarchar(MAX)		= NULL, 
	@ExcludedLogins							nvarchar(MAX)		= NULL,
	@ExcludedDatabases						nvarchar(MAX)		= NULL,
	@PrintOnly								bit					= 0	
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @CpuMillisecondsThreshold = ISNULL(@CpuMillisecondsThreshold, 2200);

	SET @ExcludeBackupsAndRestores = ISNULL(@ExcludeBackupsAndRestores, 1);
	SET @ExcludeSqlServerAgentJobs = ISNULL(@ExcludeSqlServerAgentJobs, 1);
	SET @ExcludedApplicationNames = NULLIF(@ExcludedApplicationNames, N'');
	SET @ExcludedDatabases = NULLIF(@ExcludedDatabases, N'');
	SET @ExcludedHostNames = NULLIF(@ExcludedHostNames, N'');
	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');

	SET @KillableApplicationNames = NULLIF(@KillableApplicationNames, N'');
	SET @KillableHostNames = NULLIF(@KillableHostNames, N'');
	SET @KillableLogins = NULLIF(@KillableLogins, N'');
	SET @KillableDatabases = NULLIF(@KillableDatabases, N'');

	CREATE TABLE [#results] ( 
		[session_id] smallint NOT NULL,
		[database] sysname NOT NULL,
		[elapsed_milliseconds] int NOT NULL,
		[status] nvarchar(30) NOT NULL,
		[command] nvarchar(32) NOT NULL,
		[program_name] sysname NULL,
		[login_name] sysname NOT NULL,
		[host_name] sysname NULL,
		[statement] nvarchar(max) NULL
	) 

	INSERT INTO [#results] (
		[session_id],
		[database],
		[elapsed_milliseconds],
		[status],
		[command],
		[program_name],
		[login_name],
		[host_name],
		[statement]
	)
	SELECT 
		r.[session_id], 
		DB_NAME(r.[database_id]) [database], 
		r.[total_elapsed_time] [elapsed_milliseconds], 
		r.[status], 
		r.[command], 
		s.[program_name], 
		s.[login_name], 
		s.[host_name], 
		t.[text] [statement]
	FROM 
		sys.dm_exec_requests r
		INNER JOIN sys.[dm_exec_sessions] s ON r.[session_id] = s.[session_id]
		OUTER APPLY sys.[dm_exec_sql_text](r.[sql_handle]) t
	WHERE 
		[r].[session_id] > 50
		AND s.[is_user_process] = 1
		AND r.[session_id] <> @@SPID
		AND r.[total_elapsed_time] >= @CpuMillisecondsThreshold;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Normalize % within @StatementPattern - i.e., LEAVE any inside... but strip start/end ... then ADD % and % to start and end... 
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	DECLARE @normalizedStatementPattern nvarchar(MAX) = @StatementPattern;
	IF LEFT(@normalizedStatementPattern, 1) = N'%'
		SET @normalizedStatementPattern = RIGHT(@normalizedStatementPattern, LEN(@normalizedStatementPattern) -1);

	IF RIGHT(@normalizedStatementPattern, 1) = N'%'
		SET @normalizedStatementPattern = LEFT(@normalizedStatementPattern, LEN(@normalizedStatementPattern) -1);

	SET @normalizedStatementPattern = N'%' + @normalizedStatementPattern + N'%';
	
	PRINT N'Normalized @StatementPattern used for matching target statements to kill: [' + @normalizedStatementPattern + N']';

	DELETE FROM [#results] WHERE [statement] NOT LIKE @normalizedStatementPattern;


	IF EXISTS (SELECT NULL FROM [#results]) BEGIN 

		DELETE FROM [#results] WHERE [session_id] IS NULL; -- no idea why/how this one happens... but it occasionally does. 

		-----------------------------------------------------------------------------------------------------------------------------------------------------
		-- Process Explicit Exclusions (i.e., white-listed - or un-KILL-able) operations:
		-----------------------------------------------------------------------------------------------------------------------------------------------------
		IF @ExcludeBackupsAndRestores = 1 BEGIN 
			DELETE FROM [#results]
			WHERE 
				[command] LIKE N'%BACKUP%'
				OR 
				[command] LIKE N'%RESTORE%'
		END;



		IF NOT EXISTS (SELECT NULL FROM [#results]) BEGIN
			RETURN 0; -- short-circuit (i.e., nothing to do or report).
		END;

		DECLARE @excludedApps table (
			row_id int IDENTITY(1,1) NOT NULL, 
			[app_name] sysname NOT NULL 
		);

		IF @ExcludeSqlServerAgentJobs = 1 BEGIN 
			INSERT INTO @excludedApps ([app_name])
			VALUES	(N'SQLAgent - TSQL JobStep%');
		END;

		IF @ExcludedApplicationNames IS NOT NULL BEGIN 
			INSERT INTO @excludedApps ([app_name])
			SELECT [result] FROM dbo.[split_string](@ExcludedApplicationNames, N', ', 1);
		END;

		IF EXISTS (SELECT NULL FROM @excludedApps) BEGIN 
			DELETE b
			FROM 
				[#results] b 
				INNER JOIN @excludedApps x ON b.[program_name] LIKE x.[app_name];
		END;

		IF @ExcludedHostNames IS NOT NULL BEGIN 
			DELETE r 
			FROM 
				[#results] r 
				INNER JOIN (SELECT [result] FROM dbo.[split_string](@ExcludedHostNames, N', ', 1)) x ON r.[host_name] LIKE x.[result];
		END;

		IF @ExcludedLogins IS NOT NULL BEGIN 
			DELETE r 
			FROM 
				[#results] r 
				INNER JOIN (SELECT [result] FROM dbo.[split_string](@ExcludedLogins, N', ', 1)) x ON r.[login_name] LIKE x.[result];
		END;

		IF @ExcludedDatabases IS NOT NULL BEGIN 
			DELETE r
			FROM 
				[#results] r
				INNER JOIN (SELECT [result] FROM dbo.[split_string](@ExcludedDatabases, N', ', 1)) x ON r.[database] LIKE x.[result];
		END;


		-- Don't attempt to KILL anything already in a kill state:
		DELETE FROM [#results] 
		WHERE 
			[command] = N'KILLED/ROLLBACK';

		-----------------------------------------------------------------------------------------------------------------------------------------------------
		-- Remove Operations that DON'T match applicable INCLUSIONS:
		-----------------------------------------------------------------------------------------------------------------------------------------------------
		IF @KillableApplicationNames IS NOT NULL BEGIN 
			DECLARE @killableApps table (
				[row_id] int IDENTITY(1,1) NOT NULL, 
				[app_name] sysname NOT NULL
			); 

			INSERT INTO @killableApps ([app_name])
			SELECT [result] FROM dbo.[split_string](@KillableApplicationNames, N', ', 1);
		
			DELETE x 
			FROM 
				[#results] x  
				INNER JOIN @killableApps t ON x.[program_name] NOT LIKE t.[app_name];
		END;

		IF @KillableHostNames IS NOT NULL BEGIN 
			DECLARE @killableHosts table (
				[row_id] int IDENTITY(1,1) NOT NULL, 
				[host_name] sysname NOT NULL
			); 

			INSERT INTO @killableHosts ([host_name])
			SELECT [result] FROM dbo.[split_string](@KillableHostNames, N', ', 1);

			DELETE x 
			FROM 
				[#results] x 
				INNER JOIN @killableHosts t ON [x].[host_name] NOT LIKE [t].[host_name];
		END;

		IF @KillableLogins IS NOT NULL BEGIN 
			DECLARE @killable_Logins table (
				[row_id] int IDENTITY(1,1) NOT NULL, 
				[login_name] sysname NOT NULL
			); 

			INSERT INTO @killable_Logins ([login_name])
			SELECT [result] FROM dbo.[split_string](@KillableLogins, N', ', 1);

			DELETE x 
			FROM 
				[#results] x 
				INNER JOIN @killable_Logins t ON [x].[login_name] NOT LIKE [t].[login_name];
		END;

		IF @KillableDatabases IS NOT NULL BEGIN 
			DECLARE @killable_databases table (
				[row_id] int IDENTITY(1,1) NOT NULL, 
				[database] sysname NOT NULL
			); 

			INSERT INTO @killable_databases ([database])
			SELECT [result] FROM dbo.[split_string](@KillableDatabases, N', ', 1);

			DELETE x 
			FROM 
				[#results] x 
				INNER JOIN @killable_databases d ON x.[database] NOT LIKE d.[database];
		END;

		-----------------------------------------------------------------------------------------------------------------------------------------------------
		-- KILL whatever is left:
		-----------------------------------------------------------------------------------------------------------------------------------------------------
		IF EXISTS (SELECT NULL FROM [#results]) BEGIN 
			DECLARE @sessionId int, @elapsed int;
			DECLARE @command sysname;
			DECLARE @statement nvarchar(MAX);
			DECLARE @errorId int, @errorMessage nvarchar(MAX);

			DECLARE @template nvarchar(MAX) = N'-- Elapsed (ms): {ms}. Command: {command}. 
--		Statement: {statement}
KILL {id};
' ;
			DECLARE @sql nvarchar(MAX);

			PRINT N'';
			PRINT N'';

			DECLARE [cursorName] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				session_id, 
				[command], 
				[statement], 
				[elapsed_milliseconds]
			FROM 
				[#results]
			ORDER BY 
				[elapsed_milliseconds] DESC;			
			
			OPEN [cursorName];
			FETCH NEXT FROM [cursorName] INTO @sessionId, @command, @statement, @elapsed;
			
			WHILE @@FETCH_STATUS = 0 BEGIN
	
				IF LEN(@statement) > 140
					SET @statement = LEFT(@statement, 140) + N' ... ';
				
				SET @statement = REPLACE(@statement, NCHAR(13) + NCHAR(10), N' ');

				SET @sql = REPLACE(@template, N'{id}', @sessionId);
				SET @sql = REPLACE(@sql, N'{command}', @command);
				SET @sql = REPLACE(@sql, N'{statement}', @statement);
				SET @sql = REPLACE(@sql, N'{ms}', FORMAT(@elapsed, N'N0'));
				
				IF @PrintOnly = 1 BEGIN 
					PRINT @sql;
				  END; 
				ELSE BEGIN 
					BEGIN TRY 
						EXEC sys.[sp_executesql] 
							@sql;

						PRINT N'KILL executed against session_id: ' + CAST(@sessionId AS sysname);
					END TRY 
					BEGIN CATCH 
						SELECT @errorId = ERROR_NUMBER(), @errorMessage = ERROR_MESSAGE();

						PRINT N'Error Attempting KILL against session_id: ' + CAST(@sessionId AS sysname) + N'. Error ' + CAST(@errorId AS sysname) + N' - ' + @errorMessage;
					END CATCH;
				END;
			
				FETCH NEXT FROM [cursorName] INTO @sessionId, @command, @statement, @elapsed;
			END;
			
			CLOSE [cursorName];
			DEALLOCATE [cursorName];




		  END;
		ELSE BEGIN
			PRINT 'Matches excluded or white-listed.';
		END;

	  END; 
	ELSE BEGIN 
		PRINT 'No Matches.';
	END
	
	RETURN 0; 
GO