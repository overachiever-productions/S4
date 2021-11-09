/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.



	SAMPLE SIGNATURES: 
		
		--------------------------------------- 
		-- project: 
			EXEC admindb.dbo.list_orphaned_users 
				@ExcludedLogins = N'Exym.Ad%';


		--------------------------------------- 
		-- return vs project: 

			DECLARE @xml xml;
			EXEC [admindb].dbo.[list_orphaned_users]
				@ExcludedLogins = N'Exym.Adm%',
				@Output = @xml OUTPUT;

			SELECT @xml;



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_orphaned_users','P') IS NOT NULL
	DROP PROC dbo.[list_orphaned_users];
GO

CREATE PROC dbo.[list_orphaned_users]
	@TargetDatabases						nvarchar(MAX)			= N'{ALL}',
	@ExcludedDatabases						nvarchar(MAX)			= NULL,
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludedUsers							nvarchar(MAX)			= NULL, 
	@ExcludeMSAndServiceLogins				bit						= 1, 
	@Output									xml						= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF NULLIF(@TargetDatabases,'') IS NULL SET @TargetDatabases = N'{ALL}';
	SET @ExcludedDatabases = NULLIF(@ExcludedDatabases, N'');
	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');
	SET @ExcludedUsers = NULLIF(@ExcludedUsers, N'');
	SET @ExcludeMSAndServiceLogins = ISNULL(@ExcludeMSAndServiceLogins, 1);

	DECLARE @ignoredDatabases table (
		[database_name] sysname NOT NULL
	);

	DECLARE @ingnoredLogins table (
		[login_name] sysname NOT NULL 
	);

	DECLARE @ignoredUsers table (
		[user_name] sysname NOT NULL
	);

	IF @ExcludedDatabases IS NOT NULL BEGIN
		INSERT INTO @ignoredDatabases ([database_name])
		SELECT [result] [database_name] FROM dbo.[split_string](@ExcludedDatabases, N',', 1) ORDER BY row_id;
	END;

	IF @ExcludedLogins IS NOT NULL BEGIN 
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](@ExcludedLogins, N',', 1) ORDER BY row_id;
	END;

	IF @ExcludeMSAndServiceLogins = 1 BEGIN 
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',', 1) ORDER BY row_id;				
	END;

	IF @ExcludedUsers IS NOT NULL BEGIN 
		INSERT INTO @ignoredUsers ([user_name]) 
		SELECT [result] [user_name] FROM dbo.[split_string](@ExcludedUsers, N',', 1) ORDER BY row_id;
	END;

	CREATE TABLE #Users (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[type] char(1) NOT NULL
	);

	CREATE TABLE #Orphans (
		[name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[disabled] bit NULL
	);	

	SELECT 
        sp.[is_disabled][enabled],
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


	/* Remove any excluded logins: */
	DELETE l 
	FROM [#Logins] l 
	INNER JOIN @ingnoredLogins x ON l.[name] LIKE x.[login_name];

	DECLARE @currentDatabase sysname;
	DECLARE @dbPrincipalsTemplate nvarchar(MAX) = N'SELECT [name], [sid], [type] FROM [{0}].sys.database_principals WHERE type IN (''S'', ''U'') AND name NOT IN (''dbo'',''guest'',''INFORMATION_SCHEMA'',''sys'')';
	DECLARE @sql nvarchar(MAX);
	DECLARE @text nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

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

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@dbsToProcess 
	ORDER BY 
		[row_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDatabase;
	
	DECLARE @projectInsteadOfSendXmlAsOutput bit = 1;
	IF (SELECT dbo.is_xml_empty(@Output)) = 1 SET @projectInsteadOfSendXmlAsOutput = 0;
	CREATE TABLE #xmlOutput ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		[login_name] sysname NOT NULL, 
		[sid] varbinary(85) NOT NULL, 
		[disabled] bit NOT NULL 
	);

	WHILE @@FETCH_STATUS = 0 BEGIN
	
		DELETE FROM [#Users]; 
		DELETE FROM [#Orphans];

		SET @sql = REPLACE(@dbPrincipalsTemplate, N'{0}', @currentDatabase);

		INSERT INTO [#Users] ([name], [sid], [type])
		EXEC master.sys.sp_executesql @sql;

		/* Remove any explicitly ignored/excluded users: */
		DELETE u 
		FROM [#Users] u 
		INNER JOIN @ignoredUsers x ON u.[name] LIKE x.[user_name];

		INSERT INTO [#Orphans] ([name],	[sid], [disabled])
		SELECT 
			u.[name], 
			u.[sid], 
			l.[is_disabled]
		FROM 
			[#Users] u 
			INNER JOIN [#Logins] l ON u.[sid] = l.[sid] 
		WHERE 
			l.[name] IS NOT NULL OR l.[sid] IS NULL;

		IF EXISTS (SELECT NULL FROM [#Orphans]) BEGIN
			IF @projectInsteadOfSendXmlAsOutput = 1 BEGIN 
				
				PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'
				PRINT '-- DATABASE: ' + @currentDatabase 
				PRINT '----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------'

				SET @text = N'';
				SELECT 
					@text = @text +  N'-- ORPHAN: ' + [name] + N' (SID: ' + CONVERT(sysname, [sid], 1) + CASE WHEN [disabled] = 1 THEN N') - DISABLED ' ELSE N') ' END + @crlf
				FROM 
					[#Orphans] 
				ORDER BY 
					[name];

				EXEC [dbo].[print_long_string] @text;

			  END; 
			ELSE BEGIN 
				INSERT INTO [#xmlOutput] (
					[database],
					[login_name],
					[sid],
					[disabled]
				)
				SELECT 
					@currentDatabase [database],
					[name] [login_name],
					[sid],
					[disabled]
				FROM 
					[#Orphans]
				ORDER BY 
					[name];
			END;
		END;
	
		FETCH NEXT FROM [walker] INTO @currentDatabase;
	END;

	IF @projectInsteadOfSendXmlAsOutput = 0 BEGIN 
		SELECT @Output = (SELECT 
			[database] [login/@database],
			CONVERT(sysname, [sid], 1) [login/@sid],
			[disabled] [login/@disabled],
			[login_name] [login]
		FROM 
			[#xmlOutput] 
		ORDER BY 
			[row_id]
		FOR XML PATH(''), ROOT('orphans'), TYPE);
	END;

	CLOSE [walker];
	DEALLOCATE [walker];
