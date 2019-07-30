/*

*/
IF OBJECT_ID('dbo.list_object_permissions','P') IS NOT NULL
	DROP PROC dbo.list_object_permissions;
GO

CREATE PROC dbo.list_object_permissions
    @ObjectIdentifier                   sysname                -- can be the NAME, schema+name, or an object id... 
AS 
    SET NOCOUNT ON; 

    -- {copyright}


    -- if is numeric...then... done. 
    --      otherwise, convert name to an ID... 

    -- https://dba.stackexchange.com/questions/134716/how-do-i-detect-execute-permission-granted-to-a-role-when-no-on-clause-was-used
    SELECT 
        dp.name
        , OBJECT_NAME(@objectID) [object_name]
        , perms.class_desc
        , perms.permission_name
        , perms.state_desc
    FROM sys.database_permissions perms
        INNER JOIN sys.database_principals dp ON perms.grantee_principal_id = dp.principal_id 
    WHERE 
        --dp.name = 'MyRole'
        perms.[major_id] = @objectID;

    -- https://docs.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-database-permissions-transact-sql?view=sql-server-2017


    -- TODO: 
        -- a) determine with GRANT and/or any other perms. 
        -- b) additional, logical/good, meta data
        -- c) for tables... get columns and/or other details... 


/*

    Example: 
DECLARE @objectID int; 
SELECT @objectID = OBJECT_ID('sp_rulecode');

    SELECT 
        dp.name
        , OBJECT_NAME(@objectID) [object_name]
        , perms.class_desc
        , perms.permission_name
        , perms.state_desc
    FROM sys.database_permissions perms
        INNER JOIN sys.database_principals dp ON perms.grantee_principal_id = dp.principal_id 
    WHERE 
        --dp.name = 'MyRole'
        perms.[major_id] = @objectID;
GO


-- another example - this time a table: 
DECLARE @objectID int; 
SELECT @objectID = OBJECT_ID('dbo.Activities');

    SELECT 
        dp.name
        , OBJECT_NAME(@objectID) [object_name]
        , perms.class_desc
        , perms.permission_name
        , perms.state_desc
    FROM sys.database_permissions perms
        INNER JOIN sys.database_principals dp ON perms.grantee_principal_id = dp.principal_id 
    WHERE 
        --dp.name = 'MyRole'
        perms.[major_id] = @objectID;
GO

*/