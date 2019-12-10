/*

	TODO: this needs the 'execute in calling-context' convention
		as in ... it needs to do MORE than just run this query against roles in the admindb... 
			it can/should be able to run against ... other dbs and their roles. 

			which means 2 changes: 
				1. get the context ... via 'dynamic' detection + and/or via @TargetDatabase (if that's null, then dynamic... and if we can't tell after @TargetDB and dynamic... then error). 
				2. the query then needs to be DYNAMIC... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_role_members','P') IS NOT NULL
	DROP PROC dbo.list_role_members
GO

CREATE PROC dbo.list_role_members
    @RoleName           sysname
AS 
    SET NOCOUNT ON; 

    -- {copyright}


   WITH RoleMembers (member_principal_id, role_principal_id) 
    AS 
    (
      SELECT 
       rm1.member_principal_id, 
       rm1.role_principal_id
      FROM sys.database_role_members rm1 (NOLOCK)
       UNION ALL
      SELECT 
       d.member_principal_id, 
       rm.role_principal_id
      FROM sys.database_role_members rm (NOLOCK)
       INNER JOIN RoleMembers AS d 
       ON rm.member_principal_id = d.role_principal_id
    )
    select 
		--distinct rp.name as database_role, 
		mp.name as [user]
    from RoleMembers drm
      join sys.database_principals rp on (drm.role_principal_id = rp.principal_id)
      join sys.database_principals mp on (drm.member_principal_id = mp.principal_id)
	WHERE 
		rp.[name] = @RoleName
    order by rp.name

    -- TODO:
    --      maybe grab sids and/or info on whether the user in question is active and so on ... i..e, @IncludeExtendedUserData = 1
    --      maybe look for roles that are members of this role - i.e., if I made a role called ExymAdmins and ... made them a member of the admins role
    --          i'd like to see a 'nested_role_members' xml do-hickie that would show these permissions/memberships in greater detail... 
    --              and... use the above via something like .. @IncludeChildRoleMembers or something like that... 


	RETURN 0;
GO