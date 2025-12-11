/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[escalated_server_permissions]','P') IS NOT NULL
	DROP PROC dbo.[escalated_server_permissions];
GO

CREATE PROC dbo.[escalated_server_permissions]


AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @targetPermissions table (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[permission] sysname NOT NULL, 
		[allowed_principals] sysname NULL
	);

	INSERT INTO @targetPermissions ([permission], [allowed_principals])
	VALUES
		(N'ALTER ANY CREDENTIAL', N''), 
		(N'ALTER ANY DATABASE', N''), 
		(N'ALTER ANY ENDPOINT', N''), 
		(N'ALTER ANY LINKED SERVER', N''), 
		(N'ALTER ANY LOGIN', N''), 
		(N'ALTER TRACE', N''), 
		(N'AUTHENTICATE SERVER', N'##MS_SQLAuthenticatorCertificate##,##MS_SQLReplicationSigningCertificate##'), 
		(N'CONTROL SERVER', N'##MS_PolicySigningCertificate##'), 
		(N'CREATE ENDPOINT', N''), 
		(N'EXTERNAL ACCESS ASSEMBLY', N''), 
		(N'SHUTDOWN', N''), 
		(N'UNSAFE ASSEMBLY', N'');

	SELECT 
		[p].[name] [principal], 
		[p].[type_desc] [type], 
		[p].[is_disabled], 
		[perms].[state_desc] [permissions_state], 
		[perms].[permission_name]
	INTO 
		#escalatedPerms
	FROM 
		sys.[server_permissions] [perms]
		INNER JOIN sys.[server_principals] [p] ON [perms].[grantee_principal_id] = [p].[principal_id]
		-- MKC: Kinda losing my mind here. Why the F is my @tempTable using Latin1_General_CI_AS_KS_WS? ... like ... the universe no longer makes sense. 
		LEFT OUTER JOIN @targetPermissions [x] ON [perms].[permission_name] = [x].[permission] COLLATE SQL_Latin1_General_CP1_CI_AS
			AND [p].[name] NOT IN (SELECT [result] FROM dbo.split_string([x].[allowed_principals], N',', 1))
	WHERE 
		x.[permission] IS NOT NULL;
	
	SELECT 
		[principal],
		[type],
		[is_disabled],
		[permissions_state],
		[permission_name] 
	FROM 
		[#escalatedPerms]
	ORDER BY 
		[principal];

	RETURN 0;
GO