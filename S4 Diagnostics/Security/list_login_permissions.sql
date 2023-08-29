/*

		EXEC admindb.dbo.list_login_permissions
			@ExcludedLogins = N'%mike%'; 


		EXEC admindb.dbo.list_login_permissions
			@Mode = 'SUMMARY'; -- or 'TABLE'


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_login_permissions','P') IS NOT NULL
	DROP PROC dbo.[list_login_permissions];
GO

CREATE PROC dbo.[list_login_permissions]
	@Mode									sysname					= N'SUMMARY',  -- { SUMMARY | TABLE }
	@ExcludedLogins							nvarchar(MAX)			= NULL,
	@ExcludeMSAndServiceLogins				bit						= 1, 
	@ExcludedDatabases						sysname					= NULL

AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @Mode = ISNULL(NULLIF(@Mode, N''), N'SUMMARY');

	DECLARE @ingnoredLogins table (
		[login_name] sysname NOT NULL 
	);	

	INSERT INTO @ingnoredLogins (
		[login_name]
	)
	VALUES	
		--(N'sa'), 
		(N'public');

	IF @ExcludedLogins IS NOT NULL BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](@ExcludedLogins, N',', 1) ORDER BY row_id;
	END;

	IF @ExcludeMSAndServiceLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',', 1) ORDER BY row_id;		
	END;

	SELECT 
		[p].[principal_id],
		[p].[sid],
		[p].[name],
		CASE WHEN [p].[is_disabled] = 1 THEN 0 ELSE 1 END [enabled],
		[p].[default_database_name] [default_database]
	INTO 
		#Logins
	FROM 
		sys.[server_principals] [p]
		LEFT OUTER JOIN sys.[sql_logins] sl ON [p].[sid] = sl.[sid]
	WHERE 
		[is_fixed_role] = 0;

	DELETE l 
	FROM 
		#Logins l
		INNER JOIN @ingnoredLogins x ON l.[name] LIKE x.[login_name];

	WITH [server_role_members] AS (
		SELECT 
			[members].[principal_id],
			[roles].[name] [role_name]
		FROM 
			sys.[server_role_members] [rm]
			INNER JOIN sys.[server_principals] [roles] ON [rm].[role_principal_id] = [roles].[principal_id] 
			INNER JOIN sys.[server_principals] [members] ON [rm].[member_principal_id] = [members].[principal_id]
		WHERE 
			[members].[principal_id] IN (SELECT [principal_id] FROM [#Logins])
	)

	SELECT 
		[m].[principal_id], 
		STUFF(
			(SELECT N', ' + [x].[role_name] FROM [server_role_members] [x] WHERE [x].[principal_id] = [m].[principal_id] FOR XML PATH('')),
		1, 1, N' ') [roles]
	INTO 
		#serverRoleMembership
	FROM 
		[server_role_members] [m]
	GROUP BY 
		[m].[principal_id];
	
	/* Extract per-database role_memberships */
	CREATE TABLE #dbRoleMembers (
		[row_id] int IDENTITY(1, 1),
		[database] sysname NOT NULL,
		[sid] varbinary(85) NOT NULL,
		[user_name] sysname NOT NULL, 
		[schema] sysname NOT NULL, 
		[roles] nvarchar(MAX) NOT NULL
	);

	DECLARE @targetDBs table ( 
		row_id int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL
	);

	INSERT INTO @targetDBs (
		[database_name]
	)
	EXEC dbo.[list_databases]
		@Targets = N'{ALL}',
		@Exclusions = @ExcludedDatabases,
		@Priorities = NULL,
		@ExcludeClones = 1,
		@ExcludeSecondaries = 1,
		@ExcludeSimpleRecovery = 0,
		@ExcludeReadOnly = 0,
		@ExcludeRestoring = 1,
		@ExcludeRecovering = 1,
		@ExcludeOffline = 1;

	DECLARE @databaseName sysname;
	DECLARE @template nvarchar(MAX) = N'WITH [users] AS ( 
		SELECT 
			[p].[sid],
			[x].[name] [user_name]
		FROM 
			[{dbname}].sys.[database_principals] p
			INNER JOIN [#Logins] x ON [p].[sid] = [x].[sid]
		WHERE 
			[p].[sid] <> 0x01
	), 
	[role_members] AS (
		SELECT
			[members].[sid],
			[members].[default_schema_name] [default_schema],
			[roles].[name] [role]
		FROM 
			[{dbname}].sys.[database_role_members] [rm]
			INNER JOIN [{dbname}].[sys].[database_principals] AS [roles] ON [rm].[role_principal_id] = [roles].[principal_id]
			INNER JOIN [{dbname}].[sys].[database_principals] AS [members] ON [rm].[member_principal_id] = [members].[principal_id]
		WHERE
			[roles].[type] = ''R''		
			AND [members].[sid] IN (SELECT [sid] FROM [#Logins])
			AND [members].[sid] <> 0x01
	), 
	[joined] AS (
		SELECT 
			[u].[sid],
			[u].[user_name],
			ISNULL([r].[default_schema], N'''') [schema],
			ISNULL([r].[role], N''public'') [role]
		FROM 
			[users] [u]
			LEFT OUTER JOIN [role_members] [r] ON [u].[sid] = [r].[sid]
	)

	SELECT 
		N''{dbname}'' [database],
		[j].[sid], 
		[j].[user_name], 
		[j].[schema], 
		LTRIM(STUFF(
			(SELECT N'', '' + [x].[role] FROM [joined] [x] WHERE [x].[sid] = [j].[sid] FOR XML PATH('''')),
		1, 1, N'' '')) [roles]
	FROM 
		[joined] [j]
	GROUP BY 
		[j].[sid], 
		[j].[user_name], 
		[j].[schema]; '

	DECLARE @command nvarchar(MAX);
	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@targetDBs
	ORDER BY 
		[row_id];

	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @databaseName;
		
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @command = REPLACE(@template, N'{dbname}', @databaseName);

		INSERT INTO [#dbRoleMembers] (
			[database],
			[sid],
			[user_name],
			[schema],
			[roles]
		)
		EXEC sp_executesql 
			@command;
		
		FETCH NEXT FROM [walker] INTO @databaseName;
	END;
		
	CLOSE [walker];
	DEALLOCATE [walker];

	WITH core AS ( 
		SELECT
			[l].[principal_id],
			[l].[name],
			[l].[enabled],
			[l].[default_database], 
			LTRIM(ISNULL([s].[roles], N'')) [roles], 
			[d].[database],
			[d].[user_name],
			[d].[schema],
			[d].[roles] [db_roles]
		FROM 
			[#Logins] [l]
			LEFT OUTER JOIN #serverRoleMembership [s] ON [l].[principal_id] = [s].[principal_id]
			LEFT OUTER JOIN [#dbRoleMembers] [d] ON [l].[sid] = [d].[sid]
	) 

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[c].[enabled],
		[c].[name] [login],
		[c].[default_database] [default_db], 
		[c].[roles] [server_roles], 
		ISNULL([c].[database], CASE WHEN [c].[roles] LIKE N'%sysadmin%' THEN N'ALL' ELSE N'' END) [database],
		ISNULL([c].[user_name], CASE WHEN [c].[roles] LIKE N'%sysadmin%' THEN N'db_owner' ELSE N'' END) [user_name],
		ISNULL([c].[schema], CASE WHEN [c].[roles] LIKE N'%sysadmin%' THEN N'dbo' ELSE N'' END) [schema],
		ISNULL([c].[db_roles], CASE WHEN [c].[roles] LIKE N'%sysadmin%' THEN N'db_owner' ELSE N'' END) [db_roles]
	INTO 
		#report
	FROM 
		core c
	ORDER BY 
		c.[principal_id];

	IF UPPER(@Mode) = N'SUMMARY' BEGIN 
		WITH core AS (
			SELECT 
				[enabled],
				[login],
				LAG([login], 1, NULL) OVER (ORDER BY [row_id]) [lagged],
				[default_db],
				[server_roles],
				[database],
				[user_name],
				[schema],
				[db_roles] 
			FROM 
				[#report] 
		) 

		SELECT 
			CASE WHEN [lagged] = [login] THEN N'' ELSE [login] END [login],
			CASE WHEN [lagged] = [login] THEN N'' ELSE CAST([enabled] AS sysname) END [enabled],
			CASE WHEN [lagged] = [login] THEN N'' ELSE [default_db] END [default_db],
			[server_roles],
			N' ' [ ],
			[database],
			[user_name],
			[schema],
			[db_roles] 
		FROM 
			[core];

		RETURN 0;
	END;

	SELECT 
		[enabled],
		[login],
		[default_db],
		[server_roles],
		[database],
		[user_name],
		[schema],
		[db_roles] 
	FROM 
		[#report];

	RETURN 0;
GO	