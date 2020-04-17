
/*
	BUG:
		- I'm pulling db names as @Mode = N'ALL_ACTIVE'... that doesn't work if/when a db is offline. 
			instead, I need to: 
				a) @Mode = 'ALL' active or not... 
				b) when i get to the point of processing 'server level only' logins... i need to see if the default db of the login in question points to an offline database. 
					in many cases it will and I can just 'drop' it out of the bottom of this script as a member of database that is OFFLINE or something. 


				A similar approach would be to simply get a list of 'OFFLINE'/SINGLE_USER/WHATEVER dbs... 
					and... see if the @masterDB for a given login (while processing their print operations) is found in @offlineDBs or something... at which point, it's NOT a 'server level only' login - it's a user bound to an offline db (most likely).

	TODO
		- Implement logic to handle logins NOT mapped to ANY db - as per: https://trello.com/c/dCbst8kZ/46-bug-print-logins (I've got a stub-in for this in the main loop... (line 203-ish)


	SIGNATURE / EXAMPLE: 
		
		EXEC [admindb].[dbo].[script_logins]
			@TargetDatabases = N'{ALL}',
			@ExcludedDatabases = N'Compression%,Masked%, %_Test',
			@DatabasePriorities = N'Billing,*,SSVDev',
			--@ExcludedLogins = N'%illi%', 
			@ExcludedUsers = NULL, 
			@ExcludeMSAndServiceLogins = 1,
			@DisablePolicyChecks = 1, 
			@DisableExpiryChecks = 1, 
			@ForceMasterAsDefaultDB = 0, 
			@WarnOnLoginsHomedToOtherDatabases = 1; 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_logins','P') IS NOT NULL
	DROP PROC dbo.script_logins;
GO

CREATE PROC dbo.script_logins 
	@TargetDatabases						nvarchar(MAX)			= N'{ALL}',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@DatabasePriorities						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL,
	@ExcludeMSAndServiceLogins				bit						= 1,
	@BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
    @DisablePolicyChecks					bit						= 0,
	@DisableExpiryChecks					bit						= 0, 
	@ForceMasterAsDefaultDB					bit						= 0,
-- TODO: remove this functionality - and... instead, have a sproc that lists logins that have access to MULTIPLE databases... 
	@WarnOnLoginsHomedToOtherDatabases		bit						= 0				-- warns when a) set to 1, and b) default_db is NOT master NOR the current DB where the user is defined... (for a corresponding login).
AS
	SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@TargetDatabases,'') IS NULL 
        SET @TargetDatabases = N'{ALL}';

	DECLARE @ignoredDatabases table (
		[database_name] sysname NOT NULL
	);

	DECLARE @ingnoredLogins table (
		[login_name] sysname NOT NULL 
	);

	DECLARE @ingoredUsers table (
		[user_name] sysname NOT NULL
	);

	CREATE TABLE #Users (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[type] char(1) NOT NULL
	);

	CREATE TABLE #Orphans (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL
	);

	CREATE TABLE #Vagrants ( 
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[default_database] sysname NOT NULL
	);

	SELECT 
        CASE WHEN sp.[is_disabled] = 1 THEN 0 ELSE 1 END [enabled],
		sp.[name], 
		sp.[sid],
		sp.[type], 
		sp.[is_disabled], 
		sp.[default_database_name],
		sl.[password_hash], 
		sl.[is_expiration_checked], 
		sl.[is_policy_checked], 
		sp.[default_language_name]
	INTO 
		#Logins
	FROM 
		sys.[server_principals] sp
		LEFT OUTER JOIN sys.[sql_logins] sl ON sp.[sid] = sl.[sid]
	WHERE 
		sp.[type] NOT IN ('R');

	DECLARE @count int; 
	SET @count = (SELECT COUNT(*) FROM [#Logins]); 

	PRINT N'--- ' + CAST(@count AS sysname) + N' total logins detected (before filters/exclusions).';

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @output nvarchar(MAX);

	INSERT INTO @ignoredDatabases ([database_name])
	SELECT [result] [database_name] FROM dbo.[split_string](@ExcludedDatabases, N',', 1) ORDER BY row_id;

	INSERT INTO @ingnoredLogins ([login_name])
	SELECT [result] [login_name] FROM dbo.[split_string](@ExcludedLogins, N',', 1) ORDER BY row_id;

	IF @ExcludeMSAndServiceLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',', 1) ORDER BY row_id;		
	END;

	INSERT INTO @ingoredUsers ([user_name])
	SELECT [result] [user_name] FROM dbo.[split_string](@ExcludedUsers, N',', 1) ORDER BY row_id;

	-- remove ignored logins:
	DELETE l 
	FROM [#Logins] l
	INNER JOIN @ingnoredLogins i ON l.[name] LIKE i.[login_name];	
			
	DECLARE @currentDatabase sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @principalsTemplate nvarchar(MAX) = N'SELECT [name], [sid], [type] FROM [{0}].sys.database_principals WHERE type IN (''S'', ''U'') AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'')';

	DECLARE @serializedLogin nvarchar(MAX) = N'';

	DECLARE @dbsToWalk table ( 
		row_id int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL
	); 

	INSERT INTO @dbsToWalk ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@ExcludeSecondaries = 1,
		@ExcludeOffline = 1,
		@Priorities = @DatabasePriorities;

	DECLARE db_walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [database_name] FROM @dbsToWalk ORDER BY [row_id]; 

	OPEN [db_walker];
	FETCH NEXT FROM [db_walker] INTO @currentDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN

		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
		PRINT '-- DATABASE: ' + @currentDatabase 
		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'

		DELETE FROM [#Users];
		DELETE FROM [#Orphans];

		SET @command = REPLACE(@principalsTemplate, N'{0}', @currentDatabase); 
		INSERT INTO #Users ([name], [sid], [type])
		EXEC master.sys.sp_executesql @command;

		-- remove any ignored users: 
		DELETE u 
		FROM [#Users] u 
		INNER JOIN 
			@ingoredUsers i ON i.[user_name] LIKE u.[name];

		INSERT INTO #Orphans ([name], [sid])
		SELECT 
			u.[name], 
			u.[sid]
		FROM 
			#Users u 
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		WHERE
			l.[name] IS NULL OR l.[sid] IS NULL;

		SET @output = N'';

		-- Report on Orphans:
		SELECT @output = @output + 
			N'-- ORPHAN DETECTED: ' + [name] + N' (SID: ' + CONVERT(nvarchar(MAX), [sid], 2) + N')' + @crlf
		FROM 
			[#Orphans]
		ORDER BY 
			[name]; 

		IF NULLIF(@output, '') IS NOT NULL
			PRINT @output; 

		-- Report on differently-homed logins if/as directed:
		IF @WarnOnLoginsHomedToOtherDatabases = 1 BEGIN
			SET @output = N'';

			SELECT @output = @output +
				N'-- NOTE: Login ' + u.[name] + N' is set to use [' + l.[default_database_name] + N'] as its default database instead of [' + @currentDatabase + N'].'
			FROM 
				[#Users] u
				LEFT OUTER JOIN [#Logins] l ON u.[sid] = l.[sid]
			WHERE 
				u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
				AND u.[name] NOT IN (SELECT [name] FROM #Orphans)
				AND l.default_database_name <> 'master'  -- master is fine... 
				AND l.default_database_name <> @currentDatabase; 				
				
			IF NULLIF(@output, N'') IS NOT NULL 
				PRINT @output;
		END;

		-- Process 'logins only' logins (i.e., not mapped to any databases as users): 
		IF LOWER(@currentDatabase) = N'master' BEGIN

			CREATE TABLE #SIDs (
				[sid] varbinary(85) NOT NULL, 
				[database] sysname NOT NULL
				PRIMARY KEY CLUSTERED ([sid], [database]) -- WITH (IGNORE_DUP_KEY = ON) -- looks like an EXCEPT might be faster: https://dba.stackexchange.com/a/90003/6100
			);

			DECLARE @allDbsToWalk table ( 
				row_id int IDENTITY(1,1) NOT NULL, 
				[database_name] sysname NOT NULL
			);

			INSERT INTO @allDbsToWalk ([database_name])
			EXEC dbo.[list_databases]
				@Targets = N'{ALL}',  -- has to be all when looking for login-only logins
				@ExcludeSecondaries = 1,
				@ExcludeOffline = 1;

			DECLARE @sidTemplate nvarchar(MAX) = N'SELECT [sid], N''{0}'' [database] FROM [{0}].sys.database_principals WHERE [sid] IS NOT NULL;';
			DECLARE @sql nvarchar(MAX);

			DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
			SELECT [database_name] FROM @allDbsToWalk ORDER BY [row_id];

			DECLARE @dbName sysname; 

			OPEN [looper]; 
			FETCH NEXT FROM [looper] INTO @dbName;

			WHILE @@FETCH_STATUS = 0 BEGIN
		
				SET @sql = REPLACE(@sidTemplate, N'{0}', @dbName);

				INSERT INTO [#SIDs] ([sid], [database])
				EXEC sys.[sp_executesql] @sql;

				FETCH NEXT FROM [looper] INTO @dbName;
			END; 

			CLOSE [looper];
			DEALLOCATE [looper];

			SET @output = N'';
			
            SELECT 
                @output = @output + 
                CASE 
                    WHEN [l].[type] = N'S' THEN 
                        dbo.[format_sql_login] (
                            l.[enabled], 
                            @BehaviorIfLoginExists, 
                            l.[name], 
                            N'0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' ', 
                            N'0x' + CONVERT(nvarchar(MAX), l.[sid], 2), 
                            CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.[default_database_name] END,
                            l.[default_language_name], 
                            CASE WHEN @DisableExpiryChecks = 1 THEN 0 ELSE l.[is_expiration_checked] END,
                            CASE WHEN @DisablePolicyChecks = 1 THEN 0 ELSE l.[is_policy_checked] END
                         )
                    WHEN l.[type] IN (N'U', N'G') THEN 
                        dbo.[format_windows_login] (
                            l.[enabled], 
                            @BehaviorIfLoginExists, 
                            l.[name], 
                            CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.[default_database_name] END,
                            l.[default_language_name]
                        )
                    ELSE 
                        '-- CERTIFICATE and SYMMETRIC KEY login types are NOT currently supported. (Nor are Roles)'  -- i..e, C (cert), K (symmetric key) or R (role)
                END
                 + @crlf + N'GO' + @crlf
            FROM 
				[#Logins] l
			WHERE 
				l.[sid] NOT IN (SELECT [sid] FROM [#SIDs]);                

			IF NULLIF(@output, '') IS NOT NULL BEGIN 
				PRINT @output + @crlf;
			END 
		END; 

		-- Output LOGINS:
		DECLARE [login_walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
            CASE 
                WHEN [l].[type] = N'S' THEN 
                    dbo.[format_sql_login] (
                        l.[enabled], 
                        @BehaviorIfLoginExists, 
                        l.[name], 
                        N'0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' ', 
                        N'0x' + CONVERT(nvarchar(MAX), l.[sid], 2), 
                        CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.[default_database_name] END, 
                        l.[default_language_name], 
                        CASE WHEN @DisableExpiryChecks = 1 THEN 0 ELSE l.[is_expiration_checked] END,
                        CASE WHEN @DisablePolicyChecks = 1 THEN 0 ELSE l.[is_policy_checked] END
                        )
                WHEN l.[type] IN (N'U', N'G') THEN 
                    dbo.[format_windows_login] (
                        l.[enabled], 
                        @BehaviorIfLoginExists, 
                        l.[name], 
                        CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.[default_database_name] END,
                        l.[default_language_name]
                    )
                ELSE 
                    '-- CERTIFICATE and SYMMETRIC KEY login types are NOT currently supported. (Nor are Roles)'  -- i..e, C (cert), K (symmetric key) or R (role)
            END
                + @crlf + N'GO' + @crlf [serialized_login]
		FROM 
			#Users u
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		WHERE 
			u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
			AND u.[name] NOT IN (SELECT name FROM #Orphans);		
		
		OPEN [login_walker];
		FETCH NEXT FROM [login_walker] INTO @serializedLogin;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			PRINT @serializedLogin;
		
			FETCH NEXT FROM [login_walker] INTO @serializedLogin;
		END;
		
		CLOSE [login_walker];
		DEALLOCATE [login_walker];
			   
--		SELECT 
  --          --@output = @output + 
  --          CASE 
  --              WHEN [l].[type] = N'S' THEN 
  --                  dbo.[format_sql_login] (
  --                      l.[enabled], 
  --                      @BehaviorIfLoginExists, 
  --                      l.[name], 
  --                      N'0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' ', 
  --                      N'0x' + CONVERT(nvarchar(MAX), l.[sid], 2), 
  --                      l.[default_database_name], 
  --                      l.[default_language_name], 
  --                      CASE WHEN @DisableExpiryChecks = 1 THEN 1 ELSE l.[is_expiration_checked] END,
  --                      CASE WHEN @DisablePolicyChecks = 1 THEN 1 ELSE l.[is_policy_checked] END
  --                      )
  --              WHEN l.[type] IN (N'U', N'G') THEN 
  --                  dbo.[format_windows_login] (
  --                      l.[enabled], 
  --                      @BehaviorIfLoginExists, 
  --                      l.[name], 
  --                      l.[default_database_name], 
  --                      l.[default_language_name]
  --                  )
  --              ELSE 
  --                  '-- CERTIFICATE and SYMMETRIC KEY login types are NOT currently supported. (Nor are Roles)'  -- i..e, C (cert), K (symmetric key) or R (role)
  --          END
  --              + @crlf + N'GO' + @crlf
		--FROM 
		--	#Users u
		--	INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		--WHERE 
		--	u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
		--	AND u.[name] NOT IN (SELECT name FROM #Orphans);
			
		--IF NULLIF(@output, N'') IS NOT NULL
		--	PRINT @output;

		PRINT @crlf;

		FETCH NEXT FROM [db_walker] INTO @currentDatabase;
	END; 

	CLOSE [db_walker];
	DEALLOCATE [db_walker];

	RETURN 0;
GO