/*


    

    SAMPLES / EXAMPLES: 
        
            Expect Exception: 
                    EXEC admindb.dbo.script_login;
                    GO

            Expect Error - No such Login: 
                    EXEC admindb.dbo.script_login '716CECA6-52EF-4F74-89EF-03BB5B550A6B;'
                    GO

            script/output the sa login - if it exists: 
                    EXEC admindb.dbo.script_login 'sa';

            As above, but ALLOW password ALTER IF exists: 
                    EXEC admindb.dbo.script_login 
                        @LoginName = 'sa', 
                        @BehaviorIfLoginExists = N'ALTER';
                    GO

            Similar, but with the 'test' login - if it exists - and ... allow it to be DROPed and CREATEd if it already exists: 
                    EXEC admindb.dbo.script_login 
                        @LoginName = 'test', 
                        @BehaviorIfLoginExists = N'DROP_AND_CREATE';
                    GO  

            dump a sample login - forcing the default db to master and disabling the policy checks... 
                    EXEC admindb.dbo.script_login 
                        @LoginName = 'periscope_demo', 
                        @DisableExpiryChecks = 1, 
                        @DisablePolicyChecks = 1,
                        @ForceMasterAsDefaultDB = 1;
                    GO

            API consumption example - expect failure (xxxx doesn't exist):

                    DECLARE @loginDefinition nvarchar(MAX); -- must be NULL; 
                    DECLARE @outcome int;

                    EXEC @outcome = dbo.script_login 
                        @LoginName = 'xxxxxxxx', 
                        @Output = @loginDefinition OUTPUT; 

                    IF @outcome = 0 
                        PRINT @loginDefinition; 
                    ELSE 
                        PRINT 'sad trombone';
                    GO

            API consumpton example - expect to have/load the @definition - and allow ALTER if exists:  
                    DECLARE @definition nvarchar(MAX); -- must be NULL; 
                    DECLARE @outcome int;

                    EXEC @outcome = dbo.script_login 
                        @LoginName = 'sa', 
                        @BehaviorIfLoginExists = N'ALTER',
                        @Output = @definition OUTPUT; 

                    IF @outcome = 0 
                        PRINT @definition; 
                    ELSE 
                        PRINT 'sad trombone';
                    GO

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_login','P') IS NOT NULL
	DROP PROC dbo.script_login;
GO

CREATE PROC dbo.script_login
    @LoginName                              sysname,       
    @BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_ANCE_CREATE }
	@DisableExpiryChecks					bit						= 0, 
    @DisablePolicyChecks					bit						= 0,
	@ForceMasterAsDefaultDB					bit						= 0, 
    @Output                                 nvarchar(MAX)           = ''        OUTPUT
AS 
    SET NOCOUNT ON; 

    -- {copyright}

    IF NULLIF(@LoginName, N'') IS NULL BEGIN 
        RAISERROR('@LoginName is required.', 16, 1);
        RETURN -1;
    END;

    DECLARE @enabled bit, @name sysname, @password nvarchar(2000), @sid nvarchar(1000); 
    DECLARE @defaultDB sysname, @defaultLang sysname, @checkExpiration bit, @checkPolicy bit;

    SELECT 
        @enabled = CASE WHEN [is_disabled] = 1 THEN 0 ELSE 1 END,
        @name = [name],
        @password = CONVERT(nvarchar(2000), [password_hash], 2),
        @sid = CONVERT(nvarchar(1000), [sid], 2),
        @defaultDB = [default_database_name],
        @defaultLang = [default_language_name],
        @checkExpiration = [is_expiration_checked], 
        @checkPolicy = [is_policy_checked]
    FROM 
        sys.[sql_logins]
    WHERE 
        [name] = @LoginName;

    IF @name IS NULL BEGIN 
        IF @Output IS NULL 
            SET @Output = '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';
        ELSE 
            PRINT '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';

        RETURN -2;
    END;

    ---------------------------------------------------------
    -- overrides:
    IF @ForceMasterAsDefaultDB = 1 
        SET @defaultDB = N'master';

    IF @DisableExpiryChecks = 1 
        SET @checkExpiration = 0;

    IF @DisablePolicyChecks = 1 
        SET @checkPolicy = 0;

    ---------------------------------------------------------
    -- load output:
    DECLARE @formatted nvarchar(MAX);
    SELECT @formatted = dbo.[format_sql_login](
        @enabled, 
        @BehaviorIfLoginExists,
        @LoginName, 
        @password, 
        @sid, 
        @defaultDB,
        @defaultLang, 
        @checkExpiration, 
        @checkPolicy
     );

    IF @Output IS NULL BEGIN 
        SET @Output = @formatted;
        RETURN 0;
    END;

    PRINT @formatted;
    RETURN 0;
GO