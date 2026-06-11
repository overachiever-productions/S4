/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[server_role_members]','P') IS NOT NULL
	DROP PROC dbo.[server_role_members];
GO

CREATE PROC dbo.[server_role_members]
	@server_roles					nvarchar(MAX)		= N'{ALL}',
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @server_roles = (ISNULL(NULLIF(@server_roles, N''), N'{ALL}'));

	CREATE TABLE #roleMembers (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[server_role] sysname NOT NULL, 
		[principal] sysname NOT NULL, 
		[type] sysname NOT NULL, 
		[is_disabled] bit NOT NULL 
	);

	INSERT INTO [#roleMembers] ([server_role], [principal], [type], [is_disabled])
	SELECT
		[r].[name] [server_role],
		[m].[name] [principal],
		[m].[type_desc] [type],
		[m].[is_disabled]
	FROM
		[sys].[server_principals] [r]
		INNER JOIN [sys].[server_role_members] [srm] ON [r].[principal_id] = [srm].[role_principal_id]
		INNER JOIN [sys].[server_principals] [m] ON [srm].[member_principal_id] = [m].[principal_id]
	WHERE
		[r].[type] = 'R' -- Server roles only
	ORDER BY
		[r].[name],
		[m].[principal_id]

	IF UPPER(@server_roles) <> N'{ALL}' BEGIN

		SELECT 
			CASE WHEN [result] LIKE N'-%' THEN RIGHT([result], LEN([result]) -1) ELSE [result] END [server_role], 
			CASE WHEN [result] LIKE N'-%' THEN 1 ELSE 0 END [exclude]	
		INTO 
			#filters
		FROM 
			[dbo].[split_string](@server_roles, N',', 1);	
		
		SELECT 
			[x].[row_id],
			[x].[server_role],
			[x].[principal],
			[x].[type],
			[x].[is_disabled]
		INTO 
			#filtered
		FROM 
			[#roleMembers] [x]
			INNER JOIN [#filters] [inclusions] ON [inclusions].[exclude] = 0 AND [x].[server_role] LIKE [inclusions].[server_role]
			LEFT OUTER JOIN [#filters] [exclusions] ON [exclusions].[exclude] = 1 AND [x].[server_role] LIKE [exclusions].[server_role]
		WHERE 
			[exclusions].[server_role] IS NULL;

		DELETE FROM [#roleMembers];
		INSERT INTO [#roleMembers] ([server_role], [principal], [type], [is_disabled])
		SELECT 
			[server_role],
			[principal],
			[type],
			[is_disabled] 
		FROM 
			[#filtered] 
		ORDER BY 
			[row_id];

	END;

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

		WITH roles AS ( 
			SELECT 
				[server_role]
			FROM 
				[#roleMembers]
			GROUP BY 
				[server_role]
		) 

		SELECT @serialized_output = (
			SELECT
				[r].[server_role] [@name], 
				(
					SELECT 
						[x].[principal],
						[x].[type],
						[x].[is_disabled]
					FROM 
						[#roleMembers] [x]
					WHERE 
						[x].[server_role] = [r].[server_role]
					ORDER BY 
						[x].[row_id]
					FOR XML PATH(N'member'), TYPE
				)
			FROM 
				roles [r]
			FOR XML PATH(N'role'), ROOT(N'roles'), TYPE
		);
			
		RETURN 0;	
	END;
	
	SELECT 
		[server_role],
		[principal] [member],
		[type],
		[is_disabled]
	FROM 
		[#roleMembers]
	ORDER BY 
		[row_id]; 

	RETURN 0;
GO