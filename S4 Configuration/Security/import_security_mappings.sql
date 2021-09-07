/*

	
	FLOW / LOGIC: 
		
			> For each database in <xml> (if not in @ExcludedDatabases)
				> For each user: 
					> If associated login = null/empty, login = user-name
					> If login (from above) exists - create user and map to login
						> then, for each role, add current user to membership. 
							> if count(roles) for current user > 1 AND one of the roles = 'db_owner' raise OPTIONAL warnings about db_owner + other roles. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.import_security_mappings','P') IS NOT NULL
	DROP PROC dbo.[import_security_mappings];
GO

CREATE PROC dbo.[import_security_mappings]
	@MappingXml							xml, 
	@ExcludedDatabases					nvarchar(MAX)		= NULL,						-- Excluded from the list of dbs in the @MappingXml
	@ExcludedLogins						nvarchar(MAX)		= NULL,					 
	@ExcludedUsers						nvarchar(MAX)		= NULL,
	@WarnOnDbOwnerPlusOtherRoles		bit					= 1, 
	@OperatorName						sysname				= N'Alerts',
    @MailProfileName					sysname				= N'General',
    @EmailSubjectPrefix					nvarchar(50)		= N'[Import Security Mappings] ',
	@PrintOnly							bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExcludedDatabases = NULLIF(@ExcludedDatabases, N'');
	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');
	SET @ExcludedUsers = NULLIF(@ExcludedUsers, N'');

	CREATE TABLE #hydrated ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		[user] sysname NOT NULL, 
		[login] sysname NULL, 
		[roles] nvarchar(MAX) NULL, 
		[outcome] sysname NULL, 
		[notes] nvarchar(MAX) NULL, 
		[exception] nvarchar(MAX) NULL
	); 

	DECLARE @hydrateSQL nvarchar(MAX) = N'	WITH shredded AS ( 
		SELECT 
			[data].[db].value(N''@name[1]'', N''sysname'') [database], 
			[user].[x].value(N''@user[1]'', N''sysname'') [user], 
			[user].[x].value(N''@login[1]'', N''sysname'') [login], 
			[roles].[r].value(N''.'', N''sysname'') [role]
		FROM 
			@MappingXml.nodes(N''//database'') [data]([db])
			CROSS APPLY [data].[db].nodes(N''user'') [user]([x])
			CROSS APPLY [user].[x].nodes(N''roles/role'') [roles]([r])
	), 
	aggregated AS ( 
		SELECT 
			[database],
			[user],
			{agg}  
		FROM 
			[shredded]
		GROUP BY 
			[database], [user]
	)

	SELECT 
		[a].[database],
		[a].[user],
		(SELECT TOP (1) ISNULL([x].[login], [x].[user]) FROM [shredded] [x] WHERE [x].[database] = [a].[database] AND [a].[user] = [x].[user]) [login],
		[a].[roles]
	FROM 
		[aggregated] [a]
	ORDER BY 
		[a].[database], [a].[user]; '; 

	IF (SELECT [admindb].dbo.[get_engine_version]()) < 14.0 BEGIN 
		SET @hydrateSQL = REPLACE(@hydrateSQL, N'{agg}', N'STUFF( (SELECT N'','' + s2.[role] FROM [shredded] s2 WHERE [shredded].[database] = s2.[database] AND [shredded].[user] = s2.[user] FOR XML PATH(N'''')), 1, 1, N'' '') [roles]');
	  END; 
	ELSE BEGIN
		SET @hydrateSQL = REPLACE(@hydrateSQL, N'{agg}', N'STRING_AGG([role], N'','') [roles]');
	END;

	INSERT INTO [#hydrated] (
		[database],
		[user],
		[login],
		[roles]
	)
	EXEC sp_executesql 
		@hydrateSQL, 
		N'@MappingXml xml', 
		@MappingXml = @MappingXml;

	IF @ExcludedDatabases IS NOT NULL BEGIN 
		DELETE x 
		FROM 
			[#hydrated] x 
			INNER JOIN dbo.[split_string](@ExcludedDatabases, N', ', 1) dbs ON x.[database] LIKE dbs.[result];
	END;

	IF @ExcludedLogins IS NOT NULL BEGIN 
		DELETE x 
		FROM 
			[#hydrated] x 
			INNER JOIN dbo.[split_string](@ExcludedLogins, N',', 1) l ON x.[login] LIKE l.[result];
	END;

	IF @ExcludedUsers IS NOT NULL BEGIN 
		DELETE x 
		FROM 
			[#hydrated] x 
			INNER JOIN dbo.[split_string](@ExcludedUsers, N',', 1) u ON x.[user] LIKE u.[result];
	END;

	DECLARE @rowId int, @database sysname, @user sysname, @login sysname, @roles nvarchar(MAX);
	DECLARE @sql nvarchar(MAX);
	DECLARE @role sysname;
	DECLARE @message nvarchar(MAX);
	DECLARE @error nvarchar(MAX);
	DECLARE @userExists bit = 0;

	SET @rowId = 0;
	WHILE 1 = 1 BEGIN  /* avoid using nested cursors by using an UGLY while loop here - so'z we can use cursors down below if/as needed: */
		SET @rowId = (SELECT TOP 1 [row_id] FROM [#hydrated] WHERE [row_id] > @rowId ORDER BY [row_id]); 

		IF @rowId IS NULL BEGIN 
			BREAK;
		END;

		SELECT 
			@database = [database],
			@user = [user],
			@login = [login],
			@roles = [roles]
		FROM 
			[#hydrated] 
		WHERE 
			[row_id] = @rowId;

		IF @roles LIKE '%db_owner%' AND @roles LIKE '%,%' BEGIN 
			IF @WarnOnDbOwnerPlusOtherRoles = 1 BEGIN 
				SET @message = N'WARNING: User ' + @user + N' in the [' + @database + N'] is a member of the [db_owner] and 1 or more other roles. Membership in [db_owner] is the super-set of all other roles/options available.';
				UPDATE [#hydrated] SET [notes] = @message WHERE [row_id] = @rowId;
			END;
		END;

		SET @userExists = 0;
		SET @sql = N'IF EXISTS (SELECT NULL FROM [{db}].sys.database_principals WHERE [name] = @user) SET @userExists = 1 ELSE SET @userExists = 0;'; 
		SET @sql = REPLACE(@sql, N'{db}', @database); 

		EXEC sp_executesql 
			@sql, 
			N'@user sysname, @userExists bit OUTPUT', 
			@user = @user, 
			@userExists = @userExists OUTPUT;
		
		IF (@userExists = 0) AND (EXISTS (SELECT NULL FROM sys.[server_principals] WHERE [name] = @login)) BEGIN 
			SET @sql = 'USE [' + @database + N']; CREATE USER [' + @user + N'] FOR LOGIN [' + @login + N'];'

			BEGIN TRY 
				
				IF @PrintOnly = 1 BEGIN 
					PRINT @sql;
				  END;
				ELSE BEGIN 
					EXEC sp_executesql 
						@sql

					UPDATE [#hydrated] 
					SET 
						[notes] = N'NOTE: Login [' + @login + N'] was created for user [' + @user + N'] in database [' + @database + N'].'
					WHERE 
						[row_id] = @rowId;

					SET @userExists = 1;
				END;
			END TRY 
			BEGIN CATCH
				SET @error = CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();

				UPDATE [#hydrated]
				SET 
					[outcome] = N'FAILURE', 
					[exception] = @error + N' '
				WHERE 
					[row_id] = @rowId;

			END CATCH
		END;

		IF @userExists = 1 BEGIN 

			DECLARE [roler] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT 
				[result] [role] 
			FROM 
				dbo.[split_string](@roles, N',', 1) 
			ORDER BY 
				[row_id]; 
		
			OPEN [roler];
			FETCH NEXT FROM [roler] INTO @role;

			WHILE @@FETCH_STATUS = 0 BEGIN
		
				SET @sql = N'USE [' + @database + N']; ALTER ROLE [' + @role + N'] ADD MEMBER [' + @user + N']; '; /* this command is idempotent by design ... no need to do if checks/etc. */

				BEGIN TRY 

					IF @PrintOnly = 1 BEGIN 
						PRINT @sql
					  END; 
					ELSE BEGIN 

						EXEC sp_executesql 
							@sql;

						UPDATE [#hydrated] 
						SET 
							[outcome] = N'SUCCESS' 
						WHERE 
							[row_id] = @rowId; 
					END;

				END TRY 
				BEGIN CATCH 
					SET @error = CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();

					UPDATE [#hydrated]
					SET 
						[outcome] = N'FAILURE', 
						[exception] = ISNULL(@error, N'') + @error
					WHERE 
						[row_id] = @rowId;

				END CATCH;
		
				FETCH NEXT FROM [roler] INTO @role;
			END;
		
			CLOSE [roler];
			DEALLOCATE [roler];

		  END;
		ELSE BEGIN
			/* User doesn't exist - and there is/was no matching LOGIN to bind/use for creation of the needed user, so ... we're going to SKIP... */
			SET @message = N'WARNING: Target User [' + @user + N'] did not exist in database [' + @database + N'] nor was a matching login for [' + @login + N'] found on the server. Mapping could NOT continue.';
			UPDATE [#hydrated] 
			SET 
				[outcome] = N'NOT PROCESSED', 
				[notes] = @message
			WHERE 
				[row_id] = @rowId;
		END;
	END;

	/* Reporting/Output */
	IF EXISTS (SELECT NULL FROM [#hydrated] WHERE [notes] IS NOT NULL OR [exception] IS NOT NULL) BEGIN 
		DECLARE @success int; 
		DECLARE @skipped int; 
		DECLARE @warning int;
		DECLARE @failed int;

		DECLARE @appendXml bit = 0;
		SET @success = (SELECT COUNT(*) FROM [#hydrated] WHERE [outcome] = N'SUCCESS');
		SET @failed = (SELECT COUNT(*) FROM [#hydrated] WHERE [exception] IS NOT NULL);
		SET @warning = (SELECT COUNT(*) FROM [#hydrated] WHERE [notes] LIKE N'WARN%');
		SET @skipped = (SELECT COUNT(*) FROM [#hydrated] WHERE [outcome] = N'NOT PROCESSED');

		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9);

		DECLARE @body nvarchar(MAX) = N'EXECUTION OUTCOME: ' + @crlf 
			+ @tab + N'User-Mappings Successfully Processed		: ' + CAST(@success AS sysname) + @crlf 
			+ @tab + N'User-Mappings Errors Encountered			: ' + CAST(@failed AS sysname) + @crlf 
			+ @tab + N'User-Mappings SKipped (No Usser/Login)		: ' + CAST(@skipped AS sysname) + @crlf 
			+ @tab + N'Total number of processing warnings			: ' + CAST(@warning AS sysname) + @crlf;

		IF @failed > 0 BEGIN 
			SET @body = @body + @crlf + @crlf + N'ERRORS: '; 

			SELECT 
				@body = @body + @crlf + @tab + N'> User [' + [user] + N'] in database [' + [database] + N'] encountered the following exception: ' + @crlf + @tab + @tab + @tab + [exception]
			FROM 
				[#hydrated]
			WHERE 
				[exception] IS NOT NULL 
			ORDER BY 
				[row_id];

			SET @appendXml = 1;
		END;

		IF @warning > 0 BEGIN 
			SET @body = @body + @crlf + @crlf + N'WARNINGS: '; 

			SELECT 
				@body = @body + @crlf + @tab + N'> User [' + [user] + N'] in database [' + [database] + N'] encountered the following WARNING: ' + @crlf + @tab + @tab + @tab + [notes]
			FROM 
				[#hydrated]
			WHERE 
				[notes] IS NOT NULL
			ORDER BY 
				[row_id];

			SET @appendXml = 1;
		END;

		IF @appendXml = 1 AND @PrintOnly = 0 BEGIN 
			SET @body = @body + @crlf + @crlf + @crlf + N'Mapping XML: ' + @crlf + @tab + CAST(@MappingXml AS nvarchar(MAX));
		END;
		
		IF @PrintOnly = 1 BEGIN 
			EXEC dbo.[print_long_string] @body;
		  END; 
		ELSE BEGIN 
			DECLARE @subject sysname = @EmailSubjectPrefix; 
			IF @failed > 0 BEGIN 
				SET @subject = @subject + N' - ERRORS';
			  END;
			ELSE BEGIN 
				SET @subject = @subject + N' - NOTES/WARNINGS';
			END;

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @subject, 
				@body = @body;			
		END;

	END;

	RETURN 0
GO