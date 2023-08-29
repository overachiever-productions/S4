/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_server_role','P') IS NOT NULL
	DROP PROC dbo.[script_server_role];
GO

CREATE PROC dbo.[script_server_role]
	@RoleName						sysname, 
--	@BehaviorIfRoleExists			sysname = N'NONE', 

	@IncludeMembers					bit = 1, 
	@IncludePermissions				bit = 1,
	@TokenizePrincipalNames			bit = 0,

	@Output							nvarchar(MAX) = N''		OUTPUT, 
	@OutputHash						varchar(2000) = N''		OUTPUT			-- Primarily designed/used-for comparisons BETWEEN synchronized servers. 
AS
    SET NOCOUNT ON; 

	-- {copyright}

	IF NOT EXISTS (SELECT NULL FROM sys.[server_principals] WHERE [name] = @RoleName AND [type] = 'R' AND [is_fixed_role] = 0) BEGIN 
		DECLARE @message nvarchar(MAX) = N'-- No Server Role matching the name: [' + @RoleName + N'] exists on the current server.';

		IF @Output IS NULL OR @OutputHash IS NULL BEGIN 
			SET @Output = @message;
			SET @OutputHash = 0;
		  END;
		ELSE 
			PRINT @message;

		RETURN -2;
	END;
	
	DECLARE @principalID int, @role sysname, @owner sysname;

	SELECT 
		@principalID = [principal_id],
		@role = [name], 
		@owner = (SELECT x.[name] FROM sys.[server_principals] x WHERE sp.[owning_principal_id] = x.[principal_id])
	FROM 
		sys.[server_principals] sp
	WHERE 
		sp.[name] = @RoleName;

-- TODO: process... @BehaviorIfExists... 
--		honestly, don't think I want to drop these things? ... 

	DECLARE @definition nvarchar(MAX) = N'USE [master];
GO

----------------------------------------------------------------------------------
-- Definition: 
----------------------------------------------------------------------------------
CREATE SERVER ROLE [' + @role + N'] AUTHORIZATION [' + @owner + N']; 
GO

';

	IF @IncludePermissions = 1 AND EXISTS (SELECT NULL FROM sys.[server_permissions] WHERE [grantee_principal_id] = @principalID) BEGIN 

		SET @definition = @definition + N'	---------------------------------------------------------------------------
	-- Permissions:
';		
		
		/*
			CONTEXT: 
				all server-level permission types are defined here: 
					https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-server-permissions-transact-sql?view=sql-server-ver16 

				[class] lets us know which kind of granular object a non 'ANY/ALL' targets (e.g., endpoint, principal (role/login/etc.))
					though... I can't ever see that class 108 (AGs) are EVER used for anything granular (i.e., current perms are all/any..)
					and...docs point out that class 100 will ALWAYS be 0 (major). 
					I also can't see that MINOR is EVER used. 
		*/

		CREATE TABLE #rolePermissions (
			row_id int IDENTITY(1,1) NOT NULL, 
			[class] int NOT NULL, 
			[state] char(1) NOT NULL, 
			[permission_name] sysname NOT NULL, 
			[major_id] int NOT NULL, 
			[minor_id] int NOT NULL, 
			[is_granular] bit NOT NULL,  --see comment in final projection about bug/problem
			[target_type] sysname NULL, 
			[target_name] sysname NULL
		); 

		INSERT INTO [#rolePermissions] (
			[class],
			[state],
			[permission_name],
			[major_id],
			[minor_id], 
			[is_granular]
		)
		SELECT 
			[class], 
			[state], 
			[permission_name], 
			[major_id],
			[minor_id], 
			CASE WHEN [major_id] = 0 THEN 0 ELSE 1 END
		FROM 
			sys.[server_permissions] 
		WHERE 
			[grantee_principal_id] = @principalID;

		UPDATE [#rolePermissions] 
		SET 
			[target_type] = CASE 
				WHEN [class] = 105 THEN N'ENDPOINT'
				--WHEN [class] = 108 THEN N'AVAILABILITY GROUP'  -- can't see that these are actually in use.
				WHEN [class] = 101 THEN (SELECT CASE WHEN x.[type_desc] = N'SERVER_ROLE' THEN N'ROLE' ELSE N'LOGIN' END FROM sys.[server_principals] x WHERE x.[principal_id] = [major_id])
				ELSE N''
			END, 
			[target_name] = CASE 
				WHEN [class] = 105 THEN (SELECT x.[name] FROM sys.[endpoints] x WHERE [x].[endpoint_id] = [major_id])
				--WHEN [class] = 108 THEN (SELECT 'ag') 
				WHEN [class] = 101 THEN (SELECT x.[name] FROM sys.[server_principals] x WHERE x.[principal_id] = major_id)
				ELSE N''
			END
		WHERE 
			[major_id] IS NOT NULL;

		-- Projection: 
		SELECT 
			@definition = @definition + N'	' +
			CASE 
				WHEN [state] IN ('G', 'W') THEN N'GRANT ' 
				WHEN [state] = 'D' THEN N'DENY '
				WHEN [state] = 'R' THEN N'REVOKE '
			END + 
			[permission_name] + 
			CASE 
				WHEN [major_id] <> 0 THEN N' ON ' + [target_type] + N'::[' +  [target_name] + N']'
				ELSE N''
			END + 	
			N' TO [' + @RoleName + N']' +
			CASE 
				WHEN [state] = 'W' THEN N' WITH GRANT OPTION' 
				WHEN [state] IN ('R', 'D') THEN N' CASCADE'
				ELSE N'' 
			END + 
			N';
	GO

'
		FROM 
			[#rolePermissions] 
		ORDER BY
			-- wow... what crazy bug... 
			-- CASE WHEN [major_id] = 0 THEN 0 ELSE 1 END, [class], [state], [permission_name];
			[is_granular], [class], [state], [permission_name];


	END;

	IF @IncludeMembers = 1 AND EXISTS (SELECT NULL FROM sys.server_role_members WHERE [role_principal_id] = @principalID) BEGIN 

		SET @definition = @definition + N'	---------------------------------------------------------------------------
	-- Role Members:
';

		SELECT 
			@definition = @definition + N'	ALTER SERVER ROLE [' + @role + N'] ADD MEMBER [' + [sp].[name] + N'];
	GO

'
		FROM 
			sys.[server_role_members] srm 
			INNER JOIN sys.[server_principals] sp ON srm.[member_principal_id] = sp.[principal_id]
		WHERE 
			[role_principal_id] = @principalID
		ORDER BY 
			sp.[name];

	END;

	IF @Output IS NULL OR @OutputHash IS NULL BEGIN 
		SET @Output = @definition;
	
		IF @TokenizePrincipalNames = 1 BEGIN
			SET @definition = REPLACE(@definition, @@SERVERNAME + N'\', N'LOCAL_SERVER_NAME_FOR_TOKENIZATION_ONLY\');
			SET @OutputHash = HASHBYTES('SHA2_512', @definition);
		  END;
		ELSE BEGIN
			SET @OutputHash = HASHBYTES('SHA2_512', @definition);
		END;
		RETURN 0;
	END;

	PRINT @definition;
	RETURN 0;
GO