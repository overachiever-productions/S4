/*

    INTERNAL:
        This is an explicitly internal UDF - simply because the signature is 
            such an UGLY beast (i.e., way too many parameters). 

    PURPOSE: 
        Need a single place to define the logic (i.e., flow and formatting) for 'scripted' 
            logins - so that calling routines don't have to worry about formatting/outputs.

    LOGIC:
        - Outputs can vary between 4 different types of outcomes: 
            a. Error - Login and/or Password were NULL. 
            b. CREATE only. 
                @AllowUpdate = 0 AND @AllowRecreate = 0
            c. CREATE if NOT EXISTS ELSE ALTER;
                @AllowUpdate = 1 AND @AllowRecreate = 0
            d. CREATE if NOT EXISTS ELSE DROP + CREATE;
                @AllowRecreate = 1 (if @AllowRecreate = 1, @AllowUpdate is IGNORED).

        Outputs b, c, and d are all idempotent. (So is a - it's a comment). 


    SAMPLES / TESTS 
        
            SET NOCOUNT ON;
        
        Expected Error: 
                SELECT dbo.format_sql_login(1, 1, 1, N'', '', '0x0456598165fe', 'Billing', DEFAULT, NULL, NULL);

        CREATE only - with a (fake) SID and default DB of [Billing] specified
                SELECT dbo.format_sql_login(1, DEFAULT, DEFAULT, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        CREATE, but login defaults to NOT active... so it's disabled: 
                SELECT dbo.format_sql_login(NULL, DEFAULT, DEFAULT, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        CREATE or ALTER (if it exists - but SID can't be changed by the ALTER):
                SELECT dbo.format_sql_login(1, 1, DEFAULT, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        CREATE or DROP + CREATE (even though @AllowUpdate = 1, it's overruled/ignored by @AllowReCreate)
                SELECT dbo.format_sql_login(1, 1, 1, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        As above, but defaults to SAFE config (i.e., @Enabled is NOT specified):
                SELECT dbo.format_sql_login(NULL, 1, 1, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);



*/

USE [admindb];
GO


IF OBJECT_ID('dbo.format_sql_login','FN') IS NOT NULL
	DROP FUNCTION dbo.format_sql_login;
GO

CREATE FUNCTION dbo.format_sql_login (
    -- IF NULL the login will be DISABLED via the output/script.
    @Enabled                bit,  
    -- i.e., assume we're moving this login from prod to a dev/qa server - an 'update' would change passwords/defaults/etc. 
    @AllowUpdate            bit = 0,                        
    @AllowReCreate          bit = 0,                        -- effectively, allow the SID to be 'changed'.... 
    @Name                   sysname,                        -- always required.
    @Password               varchar(256),                   -- NOTE: while not 'strictly' required by ALTER LOGIN statements, @Password is ALWAYS required for dbo.format_sql_login.
    @SID                    varchar(100),                   -- only processed if this is a CREATE or a DROP/CREATE... 
    @DefaultDatabase        sysname = N'master',            -- have to specify DEFAULT for this to work... obviously
    @DefaultLanguage        sysname = N'[DEFAULT]',         -- have to specify DEFAULT for this to work... obviously
    @CheckExpriration       bit = 0,                        -- have to specify DEFAULT for this to work... obviously
    @CheckPolicy            bit = 0                         -- have to specify DEFAULT for this to work... obviously
)
RETURNS nvarchar(MAX)
AS 
    -- {copyright}

    BEGIN 
        DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
        DECLARE @newAtrributeLine sysname = @crlf + NCHAR(9) + N' ';

        DECLARE @output nvarchar(MAX) = N'-- ERROR scripting login. ' + @crlf 
            + N'--' + NCHAR(9) + N'Parameters @Name and @Password are both required.' + @crlf
            + N'--' + NCHAR(9) + '   Supplied Values: @Name -> [{Name}], @Password -> [{Password}].'
        
        IF (NULLIF(@Name, N'') IS NULL) OR (NULLIF(@Password, N'') IS NULL) BEGIN 
            SET @output = REPLACE(@output, N'{name}', ISNULL(NULLIF(@Name, N''), N'#NOT PROVIDED#'));
            SET @output = REPLACE(@output, N'{Password}', ISNULL(NULLIF(@Password, N''), N'#NOT PROVIDED#'));

            GOTO Done;
        END;        
        
        DECLARE @attributes sysname = N'{PASSWORD}{SID}{DefaultDatabase}{DefaultLanguage}{CheckExpiration}{CheckPolicy};';
        DECLARE @alterAttributes sysname = REPLACE(@attributes, N'{SID}', N'');

        DECLARE @template nvarchar(MAX) = N'
IF NOT EXISTS (SELECT NULL FROM [master].[sys].[server_principals] WHERE [name] = ''{Name}'') BEGIN 
    CREATE LOGIN [{Name}] WITH {Attributes} {Disable} {ElseClause} {SidReplacementDrop}{CreateOrAlter} {Attributes2} {Disable2}
END;
GO
';
        -- Main logic flow:
        IF ISNULL(@AllowReCreate, 0) = 1  -- CREATE else DROP + CREATE
            SET @AllowUpdate = 0; -- a recreate is obviously > an update (and accomplishes the same thing + enables a SID 'update').

        IF ISNULL(@AllowReCreate, 0) = 1 BEGIN 
            SET @template = REPLACE(@template, N'{ElseClause}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN' + @crlf);
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', NCHAR(9) + N'DROP LOGIN ' + QUOTENAME(@Name) + N';' + @crlf + @crlf);
            SET @template = REPLACE(@template, N'{CreateOrAlter}', NCHAR(9) + N'CREATE LOGIN [{Name}] WITH '); 
            
            SET @template = REPLACE(@template, N'{Attributes2}', @attributes);
            SET @template = REPLACE(@template, N'{Disable2}', N'{Disable}');

          END;
        ELSE BEGIN -- CREATE ONLY or CREATE else ALTER.. 
            
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', N'');

            IF ISNULL(@AllowUpdate, 0) = 1 BEGIN  -- CREATE else ALTER
                SET @template = REPLACE(@template, N'{ElseClause}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN' + @crlf);
                SET @template = REPLACE(@template, N'{CreateOrAlter}', NCHAR(9) + N'ALTER LOGIN [{Name}] WITH ');
                SET @template = REPLACE(@template, N'{Attributes2}', @alterAttributes);
                SET @template = REPLACE(@template, N'{Disable2}', N'{Disable}');
              END;
            ELSE BEGIN  -- CREATE only... 
                SET @template = REPLACE(@template, N'{ElseClause}', N'');
                SET @template = REPLACE(@template, N'{CreateOrAlter}', N''); 
                
                SET @template = REPLACE(@template, N'{Attributes2}', N'');
                SET @template = REPLACE(@template, N'{Disable2}', N'');
            END;
        END; 

        -- initialize output with basic details:
        SET @template = REPLACE(@template, N'{Attributes}', @attributes);
        SET @output = REPLACE(@template, N'{Name}', @Name);

        IF (@Password LIKE '0x%') AND (@Password NOT LIKE '%HASHED')
            SET @Password = @Password + N' HASHED';
        ELSE 
            SET @Password = N'''' + @Password + N'''';
        
        SET @output = REPLACE(@output, N'{PASSWORD}', @newAtrributeLine + NCHAR(9) + N'PASSWORD = ' + @Password);

        IF NULLIF(@SID, N'') IS NOT NULL BEGIN 
            SET @output = REPLACE(@output, N'{SID}', @newAtrributeLine + N',SID = ' + @SID);
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{SID}', N'');
        END;

        -- Defaults:
        IF NULLIF(@DefaultDatabase, N'') IS NOT NULL BEGIN 
            SET @output = REPLACE(@output, N'{DefaultDatabase}', @newAtrributeLine + N',DEFAULT_DATABASE = ' + QUOTENAME(@DefaultDatabase));
            END; 
        ELSE BEGIN
            SET @output = REPLACE(@output, N'{DefaultDatabase}', N'');
        END;

        IF NULLIF(@DefaultLanguage, N'') IS NOT NULL BEGIN 
            IF UPPER(@DefaultLanguage) = N'[DEFAULT]'
                SELECT @DefaultLanguage = [name] FROM sys.syslanguages WHERE 
                    [langid] = (SELECT [value_in_use] FROM sys.[configurations] WHERE [name] = N'default language');

            SET @output = REPLACE(@output, N'{DefaultLanguage}', @newAtrributeLine + N',DEFAULT_LANGUAGE = ' + QUOTENAME(@DefaultLanguage));
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{DefaultLanguage}', N'');
        END;

        -- checks:
        IF @CheckExpriration IS NULL BEGIN 
            SET @output = REPLACE(@output, N'{CheckExpiration}', N'');
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{CheckExpiration}', @newAtrributeLine + N',CHECK_EXPIRATION = ' + CASE WHEN @CheckExpriration = 1 THEN N'ON' ELSE 'OFF' END);
        END;

        IF @CheckPolicy IS NULL BEGIN 
            SET @output = REPLACE(@output, N'{CheckPolicy}', N'');
            END;
        ELSE BEGIN 
            SET @output = REPLACE(@output, N'{CheckPolicy}', @newAtrributeLine + N',CHECK_EXPIRATION = ' + CASE WHEN @CheckPolicy = 1 THEN N'ON' ELSE 'OFF' END);
        END;

        -- enabled:
        IF ISNULL(@Enabled, 0) = 0 BEGIN -- default secure (i.e., if we don't get an EXPLICIT enabled, disable... 
            SET @output = REPLACE(@output, N'{Disable}', @crlf + @crlf + NCHAR(9) + N'ALTER LOGIN ' + QUOTENAME(@Name) + N' DISABLE;');
            END;
        ELSE BEGIN
            SET @output = REPLACE(@output, N'{Disable}', N'');
        END;

Done:

        RETURN @output;
    END;
GO