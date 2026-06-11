/*

    OUTSTANDING / UNFINISHED TASKS:
        Server-wide perms are effectively tackled. So are Endpoints. 
        SERVER_PRINCIPALs are also - mostly tackled - LOGINS and ROLES. 
            BUT, I need to look at groups, cert-logins, and a few other "edge-ish" cases to make sure that I'm handling those correctly.
            ergo: https://overachieverllc.atlassian.net/browse/S4-862
        I also have NOT TOUCHED AVAILABILITY GROUP permissions at all yet.
            ergo: 


    FODDER: 
        I've got this: 
            "D:\Dropbox\Repositories\S4\S4 Diagnostics\Security\~~enumeration of all sql server permissions - pulled from BOL.sql"
            That's a 'dump' of ALLLLLL PERMISSIONS from BOL. 
            I've 'sliced' it at the bottom for those that map/apply to the sys.server_permissions.class_desc 
                which are the permissions that THIS sproc cares about. 
                Everything else in that list ends up going to sys.database_permissions (per database) - which ... I might address in a dbo.database_permissions sproc.

    SCOPE:
        The scope of THIS sproc is solely to enumerate + dump ALL Server Permissions. 
            I MIGHT add a 'smells' column to this sproc - but... think I want that for the CONSUMERS instead. 

        sqlmonitor.ing sprocs/logic can/will look for specific elevations
            and identify smells/elevation-concerns and other potential problems. (99% sure this is the ONLY place to put this logic). 

    UNIT TEST CASES:
        i.e., stuff to shove into the SYNONYM/FAKE of sys_server_permissions (vs ... adding into SQL Server directly). 
            though... to figure out how to populate the values ... I'm going to have to run some 'tests' on a controlled server to see what the "rows" end up looking like. 

       TESTS / ACTUAL SCRIPTS: 
            GRANT IMPERSONATE ON LOGIN::[Billing] TO [WIN-MNPBJ8S77R6\Administrator];
                REVOKE IMPERSONATE ON LOGIN::[Billing] TO [WIN-MNPBJ8S77R6\Administrator];    

            GRANT IMPERSONATE ANY LOGIN TO [Billing];
                REVOKE IMPERSONATE ANY LOGIN TO [Billing];

    -- NOTE: this does NOT grant the ability to ALTER/control built-in server roles (only CUSTOM server roles).
    -- NOTE: this'll be scoped at "SERVER" as the class_desc cuz ... it's an ANY.
            GRANT ALTER ANY SERVER ROLE TO [Billing];
                REVOKE ALTER ANY SERVER ROLE TO [Billing];

       -- SAMPLE: 
            USE master;
            CREATE SERVER ROLE [bogusadmin];
       
    -- NOTE:  this uses a slightly weirder / different syntax... 
    -- NOTE: that you can NOT grant ANY kind of CONTROL on BUILT-IN Server-Roles. 
            GRANT ALTER ON SERVER ROLE::[bogusadmin] TO [WIN-MNPBJ8S77R6\Administrator];


     TODO: for LOGINS and ROLES ... there are two main permutations/patterns: 
         A. when major_id and min_id are both 0 ... then the syntax is GRANT|REVOKE <permission> ANY <securable> TO [grantee]. 
              e.g., GRANT IMPERSONATE ANY LOGIN TO [bilbo];
         B. the other approach is - obviously - more granular and is when major_id/min_id are non-0. 
              e.g., GRANT IMPERSONATE ON LOGIN::[Bilbo] TO [Frodo]. 
              syntax pattern/rule is VERY similar - in that it's:      GRANT|REVOKE <permission> ON <securable>::<target> TO [grantee]. 
                  the only real difference is that we have an explict TARGET. 
        AND ... NOTE: 
          the 'row' for this info in sys.server_permissions will be as follows: 
              class_desc = SERVER_PRINCIPAL
              major_id = <ID of the LOGIN::[{target_here}]> ... which makes perfect sense. 

     TODO: need to address HOW I'm going to ... handle GRANTS when grantee_disabled = 1. 
          Do I ... a) comment them out? or b) do I script the PERMISSION AND then ALTER LOGIN xxx DISABLE ? 

     'DOCS'/INTERNAL:
     and ... here's how it looks like things work: 
         1. Anything with a class_desc of SERVER is going to have a major_id and minor_id of 0 and 0 - i.e., this looks like the PERMS 
                  are things like CONNECT SQL, VIEW SERVER STATE, VIEW ANY DEFINITION, and ... similar. 
                  BUT, there are also some 'uber' options in here too - in the form of ALTER ANY AG... 
                  BUT, still, these are done/applied AT THE SERVER LEVEL. 
          2. there's also a class_desc of Endpoint. 
              these look pretty simple - as in: the major_id is ... the endpoint in question. Looks like this NEVER gets any more complex than
              ENDPOINT => major_id = endpoint-name. 
          3. SERVER_PRINCIPAL is also an option. I don't see any EXAMPLES of this one in any of the environments I have access to. 
              I'm going to have to TEST this out. 
                  this'll spit out SERVER_PRINCIPAL in the class_desc, and then ... the major_id is ... the principal in question.
                  works similarly for ROLEs
          4. AVAILABILITY_GROUP is the 4th/last class_desc (documented). 
              I probably? have some examples I can look at? 
              though, i suspect that ... we're talking about granular-ish perms at the level of either specific AGs or ... AG component-types? 



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[server_permissions]','P') IS NOT NULL
	DROP PROC dbo.[server_permissions];
GO

CREATE PROC dbo.[server_permissions]
    -- TODO: https://overachieverllc.atlassian.net/browse/S4-861
    --@permissions                nvarchar(MAX)        = N'{ALL}', 
    --@members                    nvarchar(MAX)        = N'{ALL}'
    @serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
    SELECT
		[perms].[class_desc],
        [perms].[state_desc],
        [perms].[major_id], 
        [perms].[minor_id],
        [perms].[permission_name],
        [grantees].[name] [grantee],
        [grantees].[is_disabled] [grantee_disabled],
        [grantors].[name] [grantor], 
        CAST(N'' AS sysname) [target], 
        [perms].[class_desc] [securable]
    INTO 
        #permissions
    FROM 
        sys.[server_permissions] [perms]
        INNER JOIN sys.[server_principals] [grantees] ON [perms].[grantee_principal_id] = [grantees].[principal_id]
        INNER JOIN sys.[server_principals] [grantors] ON [perms].[grantor_principal_id] = [grantors].[principal_id];

    IF EXISTS (SELECT NULL FROM [#permissions] WHERE [major_id] <> 0 OR [minor_id] <> 0) BEGIN

        UPDATE [p]
        SET 
            [p].[target] = [e].[name]
        FROM 
            [#permissions] [p] 
            INNER JOIN sys.[endpoints] [e] ON [p].[major_id] = [e].[endpoint_id]
        WHERE 
            [p].[class_desc] = N'ENDPOINT';

        UPDATE [p] 
        SET 
            [p].[target] = [x].[name], 
            [p].[securable] = 
            CASE [x].[type_desc] 
                WHEN 'SQL_LOGIN' THEN N'LOGIN' 
                WHEN 'WINDOWS_LOGIN' THEN N'LOGIN' 
                ELSE [x].[type_desc]
            END
        FROM 
            [#permissions] [p]
            INNER JOIN sys.[server_principals] [x] ON [p].[major_id] = [x].[principal_id]
        WHERE 
            [p].[class_desc] = N'SERVER_PRINCIPAL';
    END;

    SELECT 
        [class_desc],
		[state_desc],
        [major_id], 
        [minor_id],
		[permission_name],
		[grantee],
		[grantee_disabled],
		[grantor], 
        CASE [state_desc]
            WHEN 'GRANT_WITH_GRANT_OPTION' THEN N'GRANT'
            ELSE [state_desc]
        END + N' ' + [permission_name] COLLATE SQL_Latin1_General_CP1_CI_AS +
        CASE [class_desc]
            WHEN N'SERVER' THEN N' TO ' + QUOTENAME([grantee])
            ELSE N' ON ' + [securable] + N'::' + QUOTENAME([target]) + N' TO ' + QUOTENAME([grantee]) 
        END + 
        CASE [state_desc] 
            WHEN N'GRANT_WITH_GRANT_OPTION' THEN 'WITH GRANT'
            ELSE N''
        END + N';' [scripted]
    INTO 
        #output
    FROM 
        [#permissions];
	
    IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

        SELECT @serialized_output = (
            SELECT 
                [class_desc],
		        [state_desc],
		        [major_id],
		        [minor_id],
		        [permission_name],
		        [grantee],
		        [grantee_disabled],
		        [grantor],
		        [scripted] [definition]
            FROM 
                [#output]
            FOR XML PATH(N'permission'), ROOT(N'permissions'), TYPE
        );

        RETURN 0;
    END;

    SELECT 
        [class_desc],
		[state_desc],
		[major_id],
		[minor_id],
		[permission_name],
		[grantee],
		[grantee_disabled],
		[grantor],
		[scripted] [definition]
    FROM 
        [#output];

    RETURN 0;
GO