
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


	NOTE: 
		- Not really intended to be called directly. Should typically be called by dbo.script_server_logins. 

	DEPENDENCIES:
		- dbo.split_string
		- dbo.


	SIGNATURE / EXAMPLE: 
		
		EXEC [admindb].[dbo].[print_logins]
			@TargetDatabases = N'[ALL]',
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

IF OBJECT_ID('dbo.print_logins','P') IS NOT NULL
	DROP PROC dbo.print_logins;
GO

CREATE PROC dbo.print_logins 
	@TargetDatabases						nvarchar(MAX)			= N'[ALL]',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@DatabasePriorities						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL,
	@ExcludeMSAndServiceLogins				bit						= 1,
	@DisablePolicyChecks					bit						= 0,
	@DisableExpiryChecks					bit						= 0, 
	@ForceMasterAsDefaultDB					bit						= 0,
	@WarnOnLoginsHomedToOtherDatabases		bit						= 0				-- warns when a) set to 1, and b) default_db is NOT master NOR the current DB where the user is defined... (for a corresponding login).
AS
	SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@TargetDatabases,'') IS NULL BEGIN
		RAISERROR('Parameter @TargetDatabases cannot be NULL or empty.', 16, 1)
		RETURN -1;
	END; 

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

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @info nvarchar(MAX);

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

		INSERT INTO #Orphans (name, [sid])
		SELECT 
			u.[name], 
			u.[sid]
		FROM 
			#Users u 
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		WHERE
			l.[name] IS NULL OR l.[sid] IS NULL;

		SET @info = N'';

		-- Report on Orphans:
		SELECT @info = @info + 
			N'-- ORPHAN DETECTED: ' + [name] + N' (SID: ' + CONVERT(nvarchar(MAX), [sid], 2) + N')' + @crlf
		FROM 
			[#Orphans]
		ORDER BY 
			[name]; 

		IF NULLIF(@info,'') IS NOT NULL
			PRINT @info; 

		-- Report on differently-homed logins if/as directed:
		IF @WarnOnLoginsHomedToOtherDatabases = 1 BEGIN
			SET @info = N'';

			SELECT @info = @info +
				N'-- NOTE: Login ' + u.[name] + N' is set to use [' + l.[default_database_name] + N'] as its default database instead of [' + @currentDatabase + N'].'
			FROM 
				[#Users] u
				LEFT OUTER JOIN [#Logins] l ON u.[sid] = l.[sid]
			WHERE 
				u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
				AND u.[name] NOT IN (SELECT [name] FROM #Orphans)
				AND l.default_database_name <> 'master'  -- master is fine... 
				AND l.default_database_name <> @currentDatabase; 				
				
			IF NULLIF(@info, N'') IS NOT NULL 
				PRINT @info;
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
				@Targets = N'[ALL]',  -- has to be all when looking for login-only logins
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
				EXEC master.sys.[sp_executesql] @sql;

				FETCH NEXT FROM [looper] INTO @dbName;
			END; 

			CLOSE [looper];
			DEALLOCATE [looper];

			SET @info = N'';
			
			SELECT @info = @info + 
				N'-- Server-Level Login:'
				+ @crlf + N'IF NOT EXISTS (SELECT NULL FROM master.sys.server_principals WHERE [name] = ''' + l.[name] + N''') BEGIN ' 
				+ @crlf + @tab + N'CREATE LOGIN [' + l.[name] + N'] ' + CASE WHEN l.[type] = 'U' THEN 'FROM WINDOWS WITH ' ELSE 'WITH ' END
				+ CASE 
					WHEN l.[type] = 'S' THEN 
						@crlf + @tab + @tab + N'PASSWORD = 0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' HASHED,'
						+ @crlf + @tab + N'SID = 0x' + CONVERT(nvarchar(MAX), l.[sid], 2) + N','
						+ @crlf + @tab + N'CHECK_EXPIRATION = ' + CASE WHEN (l.is_expiration_checked = 1 AND @DisableExpiryChecks = 0) THEN N'ON' ELSE N'OFF' END + N','
						+ @crlf + @tab + N'CHECK_POLICY = ' + CASE WHEN (l.is_policy_checked = 1 AND @DisablePolicyChecks = 0) THEN N'ON' ELSE N'OFF' END + N','				
					ELSE ''
				END 
				+ @crlf + @tab + N'DEFAULT_DATABASE = [' + CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.default_database_name END + N'],'
				+ @crlf + @tab + N'DEFAULT_LANGUAGE = [' + l.default_language_name + N'];'
				+ @crlf + N'END;'
				+ @crlf
			FROM 
				[#Logins] l
			WHERE 
				l.[sid] NOT IN (SELECT [sid] FROM [#SIDs]);

			IF NULLIF(@info, '') IS NOT NULL BEGIN 
				PRINT @info + @crlf;
			END 
		END; 

		-- Output LOGINS:
		SET @info = N'';

		SELECT @info = @info +
			N'IF NOT EXISTS (SELECT NULL FROM master.sys.server_principals WHERE [name] = ''' + l.[name] + N''') BEGIN ' 
			+ @crlf + @tab + N'CREATE LOGIN [' + l.[name] + N'] ' + CASE WHEN l.[type] = 'U' THEN 'FROM WINDOWS WITH ' ELSE 'WITH ' END
			+ CASE 
				WHEN l.[type] = 'S' THEN 
					@crlf + @tab + @tab + N'PASSWORD = 0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' HASHED,'
					+ @crlf + @tab + N'SID = 0x' + CONVERT(nvarchar(MAX), l.[sid], 2) + N','
					+ @crlf + @tab + N'CHECK_EXPIRATION = ' + CASE WHEN (l.is_expiration_checked = 1 AND @DisableExpiryChecks = 0) THEN N'ON' ELSE N'OFF' END + N','
					+ @crlf + @tab + N'CHECK_POLICY = ' + CASE WHEN (l.is_policy_checked = 1 AND @DisablePolicyChecks = 0) THEN N'ON' ELSE N'OFF' END + N','				
				ELSE ''
			END 
			+ @crlf + @tab + N'DEFAULT_DATABASE = [' + CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.default_database_name END + N'],'
			+ @crlf + @tab + N'DEFAULT_LANGUAGE = [' + l.default_language_name + N'];'
			+ @crlf + N'END;'
			+ @crlf
			+ @crlf
		FROM 
			#Users u
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid]
		WHERE 
			u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
			AND u.[name] NOT IN (SELECT name FROM #Orphans);
			
		IF NULLIF(@info, N'') IS NOT NULL
			PRINT @info;

		PRINT @crlf;

		FETCH NEXT FROM [db_walker] INTO @currentDatabase;
	END; 

	CLOSE [db_walker];
	DEALLOCATE [db_walker];

	RETURN 0;
GO