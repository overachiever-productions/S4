/*

	TODO: 
		- Needs parameter validations... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_sysadmins_and_owners','P') IS NOT NULL
	DROP PROC dbo.[list_sysadmins_and_owners];
GO

CREATE PROC dbo.[list_sysadmins_and_owners]
	@ListType				sysname						= N'SYSADMINS_AND_OWNERS',			-- { SYSADMINS | OWNERS | SYSADMINS_AND_OWNERS }
	@TargetDatabases		nvarchar(MAX)				= N'{ALL}', 
	@Exclusions				nvarchar(MAX)				= NULL, 
	@Priorities				nvarchar(MAX)				= NULL
AS
    SET NOCOUNT ON; 

    -- {copyright}

	CREATE TABLE #principals (
		[row_id] int IDENTITY(1, 1),
		[scope] sysname NOT NULL,
		[database] sysname NOT NULL,
		[role] sysname NOT NULL,
		[login_or_user_name] sysname NOT NULL
	);

	IF UPPER(@ListType) LIKE '%SYSADMINS%' BEGIN

		INSERT INTO #principals (
			[scope],
			[database],
			[role],
			[login_or_user_name]
		)
		SELECT
			N'SERVER' [scope],
			N'' [database],
			[r].[name] [role],
			[sp].[name] [login_name]
		FROM
			[sys].[server_principals] [sp],
			[sys].[server_role_members] [rm],
			[sys].[server_principals] [r]
		WHERE
			[sp].[principal_id] = [rm].[member_principal_id] AND [r].[principal_id] = [rm].[role_principal_id] AND LOWER([r].[name]) IN (N'sysadmin', N'securityadmin')
		ORDER BY
			[r].[name],
			[sp].[name];

	END;

	IF UPPER(@ListType) LIKE '%OWNER%' BEGIN
		DECLARE @targetDBs table ( 
			row_id int IDENTITY(1,1) NOT NULL,
			[database_name] sysname NOT NULL
		);

		INSERT INTO @targetDBs (
			[database_name]
		)
		EXEC dbo.[list_databases]
			@Targets = @TargetDatabases,
			@Exclusions = @Exclusions,
			@Priorities = @Priorities,
			@ExcludeClones = 1,
			@ExcludeSecondaries = 1,
			@ExcludeSimpleRecovery = 0,
			@ExcludeReadOnly = 0,
			@ExcludeRestoring = 1,
			@ExcludeRecovering = 1,
			@ExcludeOffline = 1;
		
		DECLARE @databaseName sysname;
		DECLARE @template nvarchar(MAX) = N'
			INSERT INTO #principals ([scope], [database], [role], [login_or_user_name]) 
			SELECT ''DATABASE'' [scope], ''{dbname}'', ''db_owner'' [role], p.[name] [login_or_user_name]
			FROM 
				[{dbname}].sys.database_role_members m
				INNER JOIN [{dbname}].sys.database_principals r ON m.role_principal_id = r.principal_id
				INNER JOIN [{dbname}].sys.database_principals p ON m.member_principal_id = p.principal_id
			WHERE 
				r.[name] = ''db_owner''
				AND p.[name] <> ''dbo''; ';

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

			EXEC sp_executesql @command;
		
			FETCH NEXT FROM [walker] INTO @databaseName;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

	END;

	SELECT
		*
	FROM
		#principals
	ORDER BY 
		row_id;

	RETURN 0;
GO


