/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.fix_orphaned_logins','P') IS NOT NULL
	DROP PROC dbo.[fix_orphaned_logins];
GO

CREATE PROC dbo.[fix_orphaned_logins]
	@TargetDatabase			sysname	,
	@ExcludedLogins			nvarchar(MAX)	= NULL, 
	@ExcludedUsers			nvarchar(MAX)	= NULL,
	@PrintOnly				bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

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
		UserName sysname, 
		ErrorMessage nvarchar(MAX)
	);

	DECLARE @sql nvarchar(MAX) = N'EXEC [{db}]..sp_change_users_login ''Report''; ';
	SET @sql = REPLACE(@sql, N'{db}', @TargetDatabase);

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
				IF @PrintOnly = 0 BEGIN
					PRINT N'	-- ATTEMPTING correction for [' + @target + N']... ';
				END; 

				IF NOT EXISTS (SELECT NULL FROM sys.[server_principals] WHERE [name] = @target) BEGIN
					RAISERROR('A matching login for user: [%s] does not exist.', 16, 1, @target); 
				END;

				SET @sql = N'EXEC [{db}]..sp_change_users_login @Action = ''Update_One'', @UserNamePattern = @target, @LoginName = @target; ';
				SET @sql = REPLACE(@sql,  N'{db}', @TargetDatabase);

				IF @PrintOnly = 1 BEGIN 
					PRINT @sql; 
					PRINT N'GO';
					PRINT N'';
				  END; 
				ELSE BEGIN
					EXEC sp_executesql 
						@sql, 
						N'@target sysname', 
						@target = @target;
				END;

			END TRY 
			BEGIN CATCH 
				INSERT INTO [#failures] ([UserName], [ErrorMessage])
				VALUES (@target, ERROR_MESSAGE());
			END CATCH
			
			FETCH NEXT FROM [fixer] INTO @target;
		END;
		
		CLOSE [fixer];
		DEALLOCATE [fixer];

		/* Just cuz we didn't get an explicit error doesn't ALWAYS mean we were successful in reparing ... */
		IF @PrintOnly = 0 BEGIN
			DELETE [#orphans];

			SET @sql = N'EXEC [{db}]..sp_change_users_login ''Report''; ';
			SET @sql = REPLACE(@sql, N'{db}', @TargetDatabase);

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
				INSERT INTO [#failures] ([UserName], [ErrorMessage])
				SELECT [UserName], N'STILL Orphaned (no error - but NOT repaired).' FROM [#orphans];
			END;
		END;
	END;

	IF EXISTS (SELECT NULL FROM [#failures]) BEGIN 
		SELECT 
			[UserName] [NON-REPAIRED-ORPHAN],
			[ErrorMessage] [ERROR]
		FROM 
			[#failures] 
		ORDER BY 
			[UserName];
	END;

	RETURN 0;
GO