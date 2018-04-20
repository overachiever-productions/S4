
/*
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



	SCALABLE: 
		2+ (for this sproc; + 2+ for wrapper/script_server_logins)

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
		[sid] varbinary(85) NOT NULL
	);

	CREATE TABLE #Orphans (
		name sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL
	);

	SELECT * 
	INTO #SqlLogins
	FROM master.sys.sql_logins;

	DECLARE @name sysname;
	DECLARE @sid varbinary(85); 
	DECLARE @passwordHash varbinary(256);
	DECLARE @policyChecked nvarchar(3);
	DECLARE @expirationChecked nvarchar(3);
	DECLARE @defaultDb sysname;
	DECLARE @defaultLang sysname;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @info nvarchar(MAX);

	INSERT INTO @ignoredDatabases ([database_name])
	SELECT [result] [database_name] FROM admindb.dbo.[split_string](@ExcludedDatabases, N',');

	INSERT INTO @ingnoredLogins ([login_name])
	SELECT [result] [login_name] FROM [admindb].dbo.[split_string](@ExcludedLogins, N',');

	IF @ExcludeMSAndServiceLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM [admindb].dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',');		
	END;

	INSERT INTO @ingoredUsers ([user_name])
	SELECT [result] [user_name] FROM [admindb].dbo.[split_string](@ExcludedUsers, N',');

	-- remove ignored logins:
	DELETE l 
	FROM [#SqlLogins] l
	INNER JOIN @ingnoredLogins i ON l.[name] LIKE i.[login_name];	
			
	DECLARE @currentDatabase sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @principalsTemplate nvarchar(MAX) = N'SELECT name, [sid] FROM [{0}].sys.database_principals WHERE type = ''S'' AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'')';

	DECLARE @dbNames nvarchar(MAX); 
	EXEC admindb.dbo.[load_database_names]
		@Input = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@Priorities = @DatabasePriorities,
		@Mode = N'LIST',
		@Output = @dbNames OUTPUT;

	SET @TargetDatabases = @dbNames;

	DECLARE db_walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT [result] 
	FROM admindb.dbo.[split_string](@TargetDatabases, N',');

	OPEN [db_walker];
	FETCH NEXT FROM [db_walker] INTO @currentDatabase;

	WHILE @@FETCH_STATUS = 0 BEGIN

		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
		PRINT '-- DATABASE: ' + @currentDatabase 
		PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'

		DELETE FROM [#Users];
		DELETE FROM [#Orphans];

		SET @command = REPLACE(@principalsTemplate, N'{0}', @currentDatabase); 
		INSERT INTO #Users ([name], [sid])
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
			INNER JOIN [#SqlLogins] l ON u.[sid] = l.[sid]
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
				LEFT OUTER JOIN [#SqlLogins] l ON u.[sid] = l.[sid]
			WHERE 
				u.[sid] NOT IN (SELECT [sid] FROM #Orphans)
				AND u.[name] NOT IN (SELECT [name] FROM #Orphans)
				AND l.default_database_name <> 'master'  -- master is fine... 
				AND l.default_database_name <> @currentDatabase; 				
				
			IF NULLIF(@info, N'') IS NOT NULL 
				PRINT @info;
		END;

		-- Output LOGINS:
		SET @info = N'';

		SELECT @info = @info +
			N'IF NOT EXISTS (SELECT NULL FROM master.sys.sql_logins WHERE [name] = ''' + u.[name] + N''') BEGIN ' 
			+ @crlf + @tab + N'CREATE LOGIN [' + u.[name] + N'] WITH '
			+ @crlf + @tab + @tab + N'PASSWORD = 0x' + CONVERT(nvarchar(MAX), l.[password_hash], 2) + N' HASHED,'
			+ @crlf + @tab + N'SID = 0x' + CONVERT(nvarchar(MAX), u.[sid], 2) + N','
			+ @crlf + @tab + N'CHECK_EXPIRATION = ' + CASE WHEN (l.is_expiration_checked = 1 AND @DisableExpiryChecks = 0) THEN N'ON' ELSE N'OFF' END + N','
			+ @crlf + @tab + N'CHECK_POLICY = ' + CASE WHEN (l.is_policy_checked = 1 AND @DisablePolicyChecks = 0) THEN N'ON' ELSE N'OFF' END + N','
			+ @crlf + @tab + N'DEFAULT_DATABASE = [' + CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE l.default_database_name END + N'],'
			+ @crlf + @tab + N'DEFAULT_LANGUAGE = [' + l.default_language_name + N'];'
			+ @crlf + N'END;'
			+ @crlf
			+ @crlf
		FROM 
			#Users u
			INNER JOIN [#SqlLogins] l ON u.[sid] = l.[sid]
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
