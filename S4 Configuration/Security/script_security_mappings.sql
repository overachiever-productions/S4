/*

	NOTE: 
		This sproc is going to be implemented in 2 phases/versions: 
			1. role membership (only). 
			2. security details OUTSIDE of role-membership (along with role membership); 
				basically, take something like this: 
						D:\Dropbox\Repositories\S4\S4 Diagnostics\Security\list_object_permissions.sql
						Actually, THIS is what I want/need:
							D:\Dropbox\Projects\SQLServerAudits.com\Scripts\Security\Enumerate Permissions - All Details - By All Users and Roles.sql
						Only, yeah, almost certainly will need some sort of way to determine what is INHERITED from a role vs what is NOT part of the role 
							i.e., I don't want every permission. 
								I want roles permissions +- any grants/revokes OUTSIDE of the roles. 



				and 'string_aggregate()'/serialize into perms/details that extend OUTSIDE of role-membership/etc. 
					(MAY need to establish 'baselines' for each role? and then 'vector' from/against those details? )

    NOTE: 
        - This sproc adheres to the PROJECT/REPLY usage convention.



	SAMPLE EXECUTIONs:
	
				-- projection example:
						EXEC [admindb].dbo.[script_security_mappings]
							@TargetDatabases = N'PSPData_DEV, demo', 
							@ExcludedDatabases = N'AfdDb',
							@ExcludedLogins = N'Exym.Admin29'


				-- params/output:
						DECLARE @out xml;
						EXEC [admindb].dbo.[script_security_mappings]
							@TargetDatabases = N'PSPData_DEV, demo', 
							@ExcludedDatabases = N'AfdDb',
							@ExcludedLogins = N'Exym.Admin29', 
							@Output = @out OUTPUT;


						SELECT @out;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_security_mappings','P') IS NOT NULL
	DROP PROC dbo.[script_security_mappings];
GO

CREATE PROC dbo.[script_security_mappings]
	@TargetDatabases					nvarchar(MAX),				-- { {ALL} | {USER} | {SYSTEM} }, etc.   -- standard tokens or names,etc./
	@ExcludedDatabases					nvarchar(MAX)		= NULL,	
	@ExcludedLogins						nvarchar(MAX)		= NULL, 
	@ExcludedUsers						nvarchar(MAX)		= NULL, 
	@Output								xml					= N'<default/>'			OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TargetDatabases = ISNULL(NULLIF(@TargetDatabases, N''), N'{ALL}');
	SET @ExcludedDatabases = NULLIF(@ExcludedDatabases, N'');

	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');
	SET @ExcludedUsers = NULLIF(@ExcludedUsers, N'');

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

	CREATE TABLE #exclusions (
		[exclusion_id] int IDENTITY(1,1) NOT NULL, 
		[exclusion_type] sysname NOT NULL, 
		[exclusion] sysname NOT NULL 
	);

	CREATE TABLE #results ( 
		[result_id] int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL,
		[result] xml NOT NULL 
	);

	IF @ExcludedLogins IS NOT NULL BEGIN 
		INSERT INTO [#exclusions] (
			[exclusion_type],
			[exclusion]
		)
		SELECT 
			N'LOGIN', 
			[result]
		FROM 
			dbo.[split_string](@ExcludedLogins, N',', 1)
		ORDER BY 
			[row_id];
	END; 

	IF @ExcludedUsers IS NOT NULL BEGIN 
		INSERT INTO [#exclusions] (
			[exclusion_type],
			[exclusion]
		)
		SELECT 
			N'USER', 
			[result]
		FROM 
			dbo.[split_string](@ExcludedUsers, N',', 1)
		ORDER BY 
			[row_id];
	END;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @line nvarchar(MAX) = N'-------------------------------------------------------------------------------------------------------------------------------';
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @message nvarchar(MAX); 
	DECLARE @error nvarchar(MAX);
	DECLARE @removeSql nvarchar(MAX);
	
	DECLARE @mappingsTemplate nvarchar(MAX) = N'WITH core AS ( 

	SELECT 
		[principals].[name] [user], 
		[l].[name] [login],
		[roles].[name] [role]
	FROM 
		[{0}].sys.[database_role_members] rm 
		INNER JOIN [{0}].sys.[database_principals] principals ON rm.[member_principal_id] = principals.[principal_id]
		INNER JOIN [{0}].sys.[database_principals] roles ON rm.[role_principal_id] = roles.[principal_id] 
		LEFT OUTER JOIN master.sys.server_principals l ON principals.[sid] = l.[sid]
	WHERE 
		[principals].[principal_id] NOT IN (0, 1, 2, 3, 4){excludedLogins}{excludedUsers}

) 

SELECT @result = (SELECT 
	[user] [@user], 
	(SELECT TOP 1 x.[login] FROM core x WHERE [core].[user] = x.[user]) [@login],  -- hack-ish... 
	(SELECT x.[role] FROM core x WHERE core.[user] = x.[user] FOR XML PATH(''''), TYPE) [roles]
FROM 
	core 
GROUP BY 
	[core].[user]
ORDER BY 
	[core].[user]
FOR 
	XML PATH (''user''), TYPE); ';
	
	IF @ExcludedLogins IS NULL BEGIN 
		SET @mappingsTemplate = REPLACE(@mappingsTemplate, N'{excludedLogins}', N'')
	  END;
	ELSE BEGIN 
		SET @mappingsTemplate = REPLACE(@mappingsTemplate, N'{excludedLogins}', N' AND ISNULL([l].[name], N''`~~`|`~~`'') NOT IN (SELECT [exclusion] FROM #exclusions WHERE [exclusion_type] = ''LOGIN'')')
	END;	

	IF @ExcludedUsers IS NULL BEGIN 
		SET @mappingsTemplate = REPLACE(@mappingsTemplate, N'{excludedUsers}', N'')
	  END;
	ELSE BEGIN 
		SET @mappingsTemplate = REPLACE(@mappingsTemplate, N'{excludedUsers}', N' AND [principals].[name] NOT IN (SELECT [exclusion] FROM #exclusions WHERE [exclusion_type] = ''USER'')')
	END;	

	DECLARE @currentDatabase sysname;

	DECLARE @sql nvarchar(MAX);
	DECLARE @result xml;

	DECLARE @id int = 1;  /* avoid using nested cursors by using an UGLY while loop here - so'z we can use cursors down below if/as needed: */
	WHILE EXISTS (SELECT NULL FROM @targetDBs WHERE [entry_id] = @id) BEGIN
		SELECT @currentDatabase = [database_name] FROM @targetDBs WHERE [entry_id] = @id;

		SET @sql = REPLACE(@mappingsTemplate, N'{0}', @currentDatabase);
			   
		EXEC sp_executesql 
			@sql, 
			N'@result xml OUTPUT', 
			@result = @result OUTPUT;

		INSERT INTO [#results] (
			[database],
			[result]
		)
		VALUES	(
			@currentDatabase, 
			@result
		);

		SET @id = @id + 1;
	END;

	-- Hack-ish: 
	DECLARE @stringOutput nvarchar(MAX) = N'';

	SELECT 
		@stringOutput = @stringOutput + N'<database name="' + [database] + N'">' + CAST([result] AS nvarchar(MAX)) + N'</database>'
	FROM 
		[#results] 
	ORDER BY 
		[result_id]

	SET @stringOutput = N'<databases>' + @stringOutput + N'</databases>';
	
	/* Send results via @Output if being called for by-parameter usage: */
	IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN
		SET @Output = CAST(@stringOutput AS xml);
		RETURN 0;
	END;

	/* -- Otherwise, Project: */
	SELECT CAST(@stringOutput AS xml) [output];

	RETURN 0; 
GO