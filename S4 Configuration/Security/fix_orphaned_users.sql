/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.fix_orphaned_users','P') IS NOT NULL
	DROP PROC dbo.[fix_orphaned_users];
GO

CREATE PROC dbo.[fix_orphaned_users]
	@TargetDatabases		nvarchar(MAX)		= N'{ALL}',
	@ExcludedDatabases		nvarchar(MAX)		= NULL,
	@ExcludedLogins			nvarchar(MAX)		= NULL, 
	@ExcludedUsers			nvarchar(MAX)		= NULL,
	@PrintOnly				bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	IF NULLIF(@TargetDatabases,'') IS NULL SET @TargetDatabases = N'{ALL}';
	SET @ExcludedDatabases = NULLIF(@ExcludedDatabases, N'');
	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');
	SET @ExcludedUsers = NULLIF(@ExcludedUsers, N'');

	DECLARE @ignored table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	IF @ExcludedLogins IS NOT NULL BEGIN 
		INSERT INTO @ignored ([name])
		SELECT [result] FROM [dbo].[split_string](@ExcludedLogins, N', ', 1);
	END;

	IF @ExcludedUsers IS NOT NULL BEGIN 
		INSERT INTO @ignored ([name])
		SELECT [result] FROM [dbo].[split_string](@ExcludedUsers, N', ', 1);
	END;

	CREATE TABLE #orphans (
		UserName sysname, 
		UserSID varbinary(85)
	); 

	CREATE TABLE #failures ( 
		DatabaseName sysname NOT NULL,
		UserName sysname NOT NULL, 
		ErrorMessage nvarchar(MAX)
	);

	DECLARE @currentDatabase sysname;
	DECLARE @dbsToProcess table ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL 
	);

	INSERT INTO @dbsToProcess ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@ExcludeClones = 1,
		@ExcludeSecondaries = 1,
		@ExcludeSimpleRecovery = 0,
		@ExcludeReadOnly = 0,
		@ExcludeRestoring = 1,
		@ExcludeRecovering = 1,
		@ExcludeOffline = 1;

	DECLARE @template nvarchar(MAX) = N'EXEC [{db}]..sp_change_users_login ''Report''; ';
	DECLARE @sql nvarchar(MAX);

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@dbsToProcess 
	ORDER BY 
		[row_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN
		SET @sql = REPLACE(@template, N'{db}', @currentDatabase);

		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
		PRINT '-- DATABASE: ' + @currentDatabase 
		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'

		DELETE FROM [#orphans];

		INSERT INTO #orphans (UserName, UserSID)
		EXEC [sys].[sp_executesql]
			@sql;
		
		IF EXISTS (SELECT NULL FROM @ignored) BEGIN 
			DELETE x 
			FROM 
				[#orphans] x 
				INNER JOIN @ignored i ON [x].[UserName] LIKE i.[name];
		END;
		
		IF EXISTS (SELECT NULL FROM [#orphans]) BEGIN
			DECLARE @target sysname; 

			DECLARE [fixer] CURSOR LOCAL FAST_FORWARD FOR 
			SELECT UserName FROM [#orphans];
		
			OPEN [fixer];
			FETCH NEXT FROM [fixer] INTO @target;
		
			WHILE @@FETCH_STATUS = 0 BEGIN
		
				BEGIN TRY 
					PRINT N'  -- Processing User: [' + @target + N']... ';

					IF NOT EXISTS (SELECT NULL FROM sys.[server_principals] WHERE [name] = @target) BEGIN
						PRINT N'  --	ERROR - Cannot repair orphaned-user [' + @target + N'], because a matching login does NOT exist.';
						
						IF @PrintOnly = 0 BEGIN
							PRINT N'';
							RAISERROR('A matching login for user: [%s] does not exist.', 16, 1, @target); 
						END;
					  END;
					ELSE BEGIN
						SET @sql = N'EXEC [{db}]..sp_change_users_login @Action = ''Update_One'', @UserNamePattern = N''{target}'', @LoginName = N''{target}''; ';
						SET @sql = REPLACE(@sql,  N'{db}', @currentDatabase);
						SET @sql = REPLACE(@sql,  N'{target}', @target);

						IF @PrintOnly = 1 BEGIN 
							PRINT N'  ' + @sql; 
							PRINT N'  GO';
						  END; 
						ELSE BEGIN
							EXEC sp_executesql 
								@sql;
						END;
					END;

					PRINT N'';

				END TRY 
				BEGIN CATCH 
					INSERT INTO [#failures] ([DatabaseName], [UserName], [ErrorMessage])
					VALUES (@currentDatabase, @target, ERROR_MESSAGE());
				END CATCH
			
				FETCH NEXT FROM [fixer] INTO @target;
			END;
		
			CLOSE [fixer];
			DEALLOCATE [fixer];

			/* Just cuz we didn't get an explicit error doesn't ALWAYS mean we were successful in reparing ... */
			IF @PrintOnly = 0 BEGIN
				DELETE [#orphans];

				SET @sql = N'EXEC [{db}]..sp_change_users_login ''Report''; ';
				SET @sql = REPLACE(@sql, N'{db}', @currentDatabase);

				INSERT INTO #orphans (UserName, UserSID)
				EXEC [sys].[sp_executesql]
					@sql;

				IF EXISTS (SELECT NULL FROM @ignored) BEGIN 
					DELETE x 
					FROM 
						[#orphans] x 
						INNER JOIN @ignored i ON [x].[UserName] LIKE i.[name];
				END;		

				IF EXISTS (SELECT NULL FROM [#failures]) BEGIN 
					DELETE FROM [#orphans] WHERE [UserName] IN (SELECT [UserName] FROM [#failures]);
				END;

				IF EXISTS (SELECT NULL FROM [#orphans]) BEGIN 
					INSERT INTO [#failures] ([DatabaseName], [UserName], [ErrorMessage])
					SELECT @currentDatabase, [UserName], N'STILL Orphaned (no error - but NOT repaired).' FROM [#orphans];
				END;
			END;
		END;

		FETCH NEXT FROM [walker] INTO @currentDatabase;
	END;

		IF EXISTS (SELECT NULL FROM [#failures]) BEGIN 
			SELECT 
				[DatabaseName],
				[UserName] [NON-REPAIRED-ORPHAN],
				[ErrorMessage] [ERROR]
			FROM 
				[#failures] 
			ORDER BY 
				[DatabaseName], [UserName];
		END;

	RETURN 0;
GO