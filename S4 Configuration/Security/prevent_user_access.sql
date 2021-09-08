/*
	
		TODO: address scenarios where we want to block, say: SamProUser_MEC_xxxx (non-test) but don't want to block SamProUser_MEC_TEST_xxxx - i..e, N'SamProUser_MEC_[^Test]_%' or something like that... 
				and... another, ODD, option would be: 
					SELECT name FROM sys.server_principles 
					WHERE name LIKE 'SamProUser_MEC%' AND name NOT LIKE 'SamProUser_MEC_TEST_%'

				serialize THAT... and shove it into @ProhibitedUsernames
				And... DONE.... (i.e., wire up the logic in the 'call' to this job to target "one but not the other". 


		-- don't allow TEST users ... 
		EXEC admindb.dbo.[prevent_user_access]
			@TargetDatabases = N'MEC', 
			@ProhibitedLogins = N'Domain Users, TomStou%', 
			@ProhibitedUsernames = N'%`_TEST`_%',		-- ESCAPE is ... '`' by definition... (i.e., hard-coded)
			@Action = N'REMOVE_AND_REPORT';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.prevent_user_access','P') IS NOT NULL
	DROP PROC dbo.[prevent_user_access];
GO

CREATE PROC dbo.[prevent_user_access]
	@TargetDatabases					nvarchar(MAX),							-- { {ALL} | {USER} | {SYSTEM} }, etc.   -- standard tokens or names,etc./
	@ExcludedDatabases					nvarchar(MAX)	= NULL,
	@ProhibitedLogins					nvarchar(MAX)	= NULL,					-- allows wildcards with ` as escape
	@ProhibitedUsernames				nvarchar(MAX)	= NULL,					-- allows wildcards with ` as escape
	@Action								sysname			= N'REPORT',			-- { REPORT | REMOVE | REMOVE_AND_REPORT }
	@OperatorName						sysname			= N'Alerts',
    @MailProfileName					sysname			= N'General',
    @EmailSubjectPrefix					nvarchar(50)	= N'[Prohibited User Processing] ',

	@PrintOnly							bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDatabases = ISNULL(NULLIF(@TargetDatabases, N''), N'{ALL}');
	SET @ExcludedDatabases = NULLIF(@ExcludedDatabases, N'');
	SET @ProhibitedLogins = NULLIF(@ProhibitedLogins, N'');
	SET @ProhibitedUsernames = NULLIF(@ProhibitedUsernames, N'');

	SET @Action = ISNULL(NULLIF(@Action, N''), N'REPORT');

	-- TODO: Validate inputs/etc. 
	-- @TargetDBs can't be NULL
	-- @ProhibitedLogins / @ProhibitedUsernames can't BOTH be null/empty. 
	-- @Action has to be IN (REPORT, REMOVE, REMOVE+REPORT)...

	DECLARE @targetDBs table (
		[entry_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 

	INSERT INTO @targetDBs ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions =@ExcludedDatabases,
		@ExcludeClones = 1,
		@ExcludeSecondaries = 1,
		@ExcludeSimpleRecovery = 0,
		@ExcludeReadOnly = 1,
		@ExcludeRestoring = 1,
		@ExcludeRecovering = 1,
		@ExcludeOffline = 1;

	CREATE TABLE #targets ( 
		[entry_id] int IDENTITY(1,1) NOT NULL, 
		[target_type] sysname NOT NULL, 
		[target_value] sysname NOT NULL 
	);

	CREATE TABLE #matches ( 
		[match_id] int IDENTITY(1,1) NOT NULL, 
		[principal_id] int NOT NULL,
		[match_type] sysname NOT NULL, 
		[match_name] sysname NOT NULL, 
		[match_target] sysname NOT NULL
	);

	CREATE TABLE #databasePrincipals (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL,
		[user_name] sysname NOT NULL,
		[user_sid] varbinary(85) NULL,
		[type_desc] nvarchar(60) NULL,
		[user_create_date] datetime NOT NULL,
		[login_name] sysname NULL,
		[login_sid] varbinary(85) NULL,
		[is_disabled] bit NULL,
		[login_create_date] datetime NULL,
		[default_database_name] sysname NULL, 
		[match_target] sysname NULL
	);

	DECLARE @messages table (
		message_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		[message] nvarchar(MAX) NOT NULL, 
		[command] nvarchar(MAX) NULL,
		[outcome] sysname NULL, 
		[error] nvarchar(MAX) NULL
	);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @line nvarchar(MAX) = N'-------------------------------------------------------------------------------------------------------------------------------';
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @message nvarchar(MAX); 
	DECLARE @error nvarchar(MAX);
	DECLARE @removeSql nvarchar(MAX);

	IF @ProhibitedLogins IS NOT NULL BEGIN 
		INSERT INTO [#targets] (
			[target_type],
			[target_value]
		)
		SELECT 
			N'LOGIN', 
			[result]
		FROM 
			dbo.[split_string](@ProhibitedLogins, N',', 1)
		ORDER BY 
			[row_id];
	END; 

	IF @ProhibitedUsernames IS NOT NULL BEGIN 
		INSERT INTO [#targets] (
			[target_type],
			[target_value]
		)
		SELECT 
			N'USER', 
			[result]
		FROM 
			dbo.[split_string](@ProhibitedUsernames, N',', 1)
		ORDER BY 
			[row_id];
	END;

	DECLARE @principalsTemplate nvarchar(MAX) = N'
SELECT 
	N''{0}'' [database_name],
	[d].[name] [user_name],
	[d].[sid] [user_sid],
	[d].[type_desc],
	[d].[create_date] [user_create_date],
	[s].[name] [login_name],
	[s].[sid] [login_sid],
	[s].[is_disabled],
	[s].[create_date] [login_create_date],
	[s].[default_database_name]
FROM 
	[{0}].sys.[database_principals] d
	LEFT OUTER JOIN master.sys.[server_principals] s ON d.[sid] = s.[sid]
WHERE 
	[d].[type] NOT IN (''R'')
	AND [d].[principal_id] NOT IN (0, 1, 2, 3, 4)
ORDER BY 
	[d].[principal_id]; ';

	DECLARE @currentDatabase sysname;
	DECLARE @userName sysname, @loginName sysname, @loginType sysname, @isLoginDisabled bit, @matchValue sysname;
	DECLARE @sql nvarchar(MAX);

	DECLARE @id int = 1;  /* avoid using nested cursors by using an UGLY while loop here - so'z we can use cursors down below if/as needed: */
	WHILE EXISTS (SELECT NULL FROM @targetDBs WHERE [entry_id] = @id) BEGIN
		SELECT @currentDatabase = [database_name] FROM @targetDBs WHERE [entry_id] = @id;

		TRUNCATE TABLE [#databasePrincipals];
		TRUNCATE TABLE [#matches];

		SET @sql = REPLACE(@principalsTemplate, N'{0}', @currentDatabase);

		INSERT INTO [#databasePrincipals] (
			[database_name],
			[user_name],
			[user_sid],
			[type_desc],
			[user_create_date],
			[login_name],
			[login_sid],
			[is_disabled],
			[login_create_date],
			[default_database_name]
		)
		EXEC sp_executesql @sql;

		-- matching LOGINS:
		INSERT INTO [#matches] (
			[match_type],
			[principal_id],
			[match_name], 
			[match_target]
		)
		SELECT 
			N'LOGIN', 
			p.[row_id],
			p.[login_name], 
			t.[target_value]
		FROM 
			[#databasePrincipals] p 
			INNER JOIN [#targets] t ON p.[login_name] LIKE t.[target_value] ESCAPE N'`'
		WHERE 
			t.[target_type] = N'LOGIN';

		-- matching USERS:
		INSERT INTO [#matches] (
			[match_type],
			[principal_id],
			[match_name], 
			[match_target]
		)
		SELECT 
			N'USER', 
			p.[row_id],
			p.[user_name], 
			t.[target_value]
		FROM 
			[#databasePrincipals] p 
			INNER JOIN [#targets] t ON p.[user_name] LIKE t.[target_value] ESCAPE N'`'
		WHERE 
			t.[target_type] = N'USER'
			AND [p].[row_id] NOT IN (SELECT [principal_id] FROM [#matches]); /* -- avoid DUPLICATES */

		DELETE FROM [#databasePrincipals] WHERE [row_id] NOT IN (SELECT principal_id FROM [#matches]);
		
		UPDATE x 
		SET 
			x.[match_target] = m.[match_target]
		FROM 
			[#databasePrincipals] x
			INNER JOIN [#matches] m ON x.[row_id] = m.[principal_id];

		/* For each REMAINING entry, process as per @Action ... */
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[user_name], 
			[login_name], 
			[type_desc] [login_type], 
			[is_disabled], 
			[match_target]
		FROM 
			[#databasePrincipals]
		ORDER BY 
			[row_id];
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @userName, @loginName, @loginType, @isLoginDisabled, @matchValue;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			SET @error = NULL; 
			SET @message = NULL;

			SET @removeSql = @tab + @tab + N'USE [{db}];' + @crlf + @tab + @tab + N'IF EXISTS (SELECT NULL FROM [{db}].[sys].[database_principals] WHERE [name] = ''{user}'') BEGIN ' + @crlf 
				+ @tab + @tab + @tab + N'DROP USER [{user}]; ' + @crlf 
				+ @tab + @tab + N'END;';

			SET @removeSql = REPLACE(@removeSql, N'{db}', @currentDatabase);
			SET @removeSql = REPLACE(@removeSql, N'{user}', @userName);

			IF UPPER(@Action) = N'REPORT' BEGIN 
				
				SET @message = N'User [' + @userName + N'] (matching prohibited pattern [' + @matchValue + N']) currently exists in database [' + @currentDatabase + N']. ';
				IF @loginName IS NULL BEGIN 
					SET @message = @message + @crlf + @tab + N'NOTE: This user is current orphaned (there is no corresponding login).'	
				  END;
				ELSE BEGIN 
					SET @message = @message + @crlf + @tab + N'NOTE: This user is currently mapped to Login [' + @loginName + N'] - which is ' + CASE WHEN @isLoginDisabled = 1 THEN 'DISABLED' ELSE N'ENABLED' END + N'. ';
				END;

				SET @message = @message + @crlf + @tab + @tab +  N'To remove this user run the following: ' + @crlf 
					+ @tab + @tab + @line + @crlf 
					+ @removeSql + @crlf
					+ @tab + @tab + @line;

				INSERT INTO @messages (
					[database],
					[message]
				)
				SELECT 
					@currentDatabase, 
					@message;
			END;

			IF UPPER(@Action) LIKE '%REMOVE%' BEGIN 
				
				SET @message = N'REMOVING user [' + @userName + N'] from database [' + @currentDatabase + N'] because it matches prohibited pattern of [' + @matchValue + N']. ';
				IF @loginName IS NULL BEGIN 
					SET @message = @message + @crlf + @tab + N'NOTE: Target user is current orphaned (there is no corresponding login). LOGIN will NOT be modified.'; 	
				  END;
				ELSE BEGIN 
					SET @message = @message + @crlf + @tab + N'NOTE: Target user is currently mapped to Login [' + @loginName + N'] - which is ' + CASE WHEN @isLoginDisabled = 1 THEN 'DISABLED' ELSE N'ENABLED' END + N'. LOGIN will NOT be modified.';
				END;

				BEGIN TRY 
					
					IF @PrintOnly = 1 BEGIN 
						PRINT N'-- @PrintOnly = 1; Otherwise, WOULD exectute the following code: '; 
						PRINT @removeSql;
					  END;
					ELSE BEGIN 
						EXEC sp_executesql @removeSql;				
					END;

					INSERT INTO @messages (
						[database],
						[message], 
						[command],
						[outcome]
					)
					VALUES	(
						@currentDatabase, 
						@message,
						@removeSql,
						N'SUCCESS'
					);
				END TRY 
				BEGIN CATCH
					SET @error = CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();

					INSERT INTO @messages (
						[database],
						[message], 
						[command],
						[outcome], 
						[error]
					)
					VALUES	(
						@currentDatabase, 
						@message, 
						@removeSql,
						N'FAILURE', 
						@error
					);

				END CATCH;
			END;

			FETCH NEXT FROM [walker] INTO @userName, @loginName, @loginType, @isLoginDisabled, @matchValue;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		SET @id = @id + 1;
	END;

	IF UPPER(@Action) = N'REMOVE' BEGIN 
		/* only report on errors with remove(only) operations */
		DELETE FROM @messages WHERE [outcome] <> 'FAILURE';
	END;

	IF EXISTS(SELECT NULL FROM @messages) BEGIN 
		
		DECLARE @body nvarchar(MAX) = N'';
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix; 

		SELECT
			@body = @body + N'- ' + [message] + @crlf + @tab 
			+ CASE WHEN [command] IS NOT NULL THEN 'EXECUTED COMMAND: ' + @crlf + @tab + @line + @crlf + [command] + @crlf + @tab + @line ELSE N'' END
			+ CASE WHEN [outcome] = N'FAILURE' THEN @crlf + @tab + 'EXECUTION OUTCOME: FAILURE -> ' + [error] WHEN [outcome] = 'SUCCESS' THEN @crlf + @tab + @tab + 'EXECUTION OUTCOME: SUCCESS' ELSE N'' END + @crlf + @crlf
		FROM 
			@messages 
		ORDER BY 
			ISNULL([outcome], N'xxx'), [message_id];  /* failure, success, and xxxx */

		IF EXISTS (SELECT NULL FROM @messages WHERE [outcome] = N'FAILURE') BEGIN 
			SET @body = N'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' + @crlf + N'!	NOTE: ERRORS occurred. ' + @crlf + N'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!' + @crlf + @crlf;
			SET @subject = @subject + N'- ERRORS';
		  END
		ELSE BEGIN 
			SET @subject = @subject + N'- SUCCESS';
		END;

		IF @PrintOnly = 1 BEGIN 
			EXEC dbo.[print_long_string] @body;
		  END;
		ELSE BEGIN 
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @subject, 
				@body = @body;
		END;
	END;
	   
	RETURN 0;
GO