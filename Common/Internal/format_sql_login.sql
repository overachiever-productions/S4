/*

    INTERNAL
        This is an explicitly internal UDF - simply because the signature is 
            such an UGLY beast (i.e., way too many parameters). 

    PURPOSE: 
        Need a single place to define the logic (i.e., flow and formatting) for 'scripted' 
            logins - so that calling routines don't have to worry about formatting/outputs.

    LOGIC:
        - Outputs can vary between 4 different types of outcomes: 
            a. Error - Login and/or Password were NULL. 
            b. CREATE only. 
                @BehaviorIfLoginExists = N'NONE'
            c. CREATE if NOT EXISTS ELSE ALTER;
                @BehaviorIfLoginExists = N'ALTER'
            d. CREATE if NOT EXISTS ELSE DROP + CREATE;
                @BehaviorIfLoginExists = N'DROP_AND_CREATE'

        Outputs b, c, and d are all idempotent. (So is a - it's a comment). 


    SAMPLES / TESTS 
        
            SET NOCOUNT ON;
        
        Expected Error: 
                SELECT dbo.format_sql_login(1, N'NONE', N'', '', '0x0456598165fe', 'Billing', DEFAULT, NULL, NULL);

        CREATE only - with a (fake) SID and default DB of [Billing] specified
                SELECT dbo.format_sql_login(1, DEFAULT, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        CREATE, but login defaults to NOT active... so it's disabled: 
                SELECT dbo.format_sql_login(NULL, DEFAULT, N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        CREATE or ALTER (if it exists - but SID can't be changed by the ALTER):
                SELECT dbo.format_sql_login(1, N'ALTER', N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        CREATE or DROP + CREATE 
                SELECT dbo.format_sql_login(1, N'DROP_AND_CREATE', N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);

        As above, but defaults to SAFE config (i.e., @Enabled is NOT specified):
                SELECT dbo.format_sql_login(NULL, N'DROP_AND_CREATE', N'Bilbo', 'THe One Ring 1s fun.', '0x0456598165fe', 'Billing', NULL, NULL, NULL);



*/

USE [admindb];
GO


IF OBJECT_ID('dbo.format_sql_login','FN') IS NOT NULL
	DROP FUNCTION dbo.format_sql_login;
GO

CREATE FUNCTION dbo.format_sql_login (
    @Enabled                          bit,                                  -- IF NULL the login will be DISABLED via the output/script.
    @BehaviorIfLoginExists            sysname         = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
    @Name                             sysname,                              -- always required.
    @Password                         varchar(256),                         -- NOTE: while not 'strictly' required by ALTER LOGIN statements, @Password is ALWAYS required for dbo.format_sql_login.
    @SID                              varchar(100),                         -- only processed if this is a CREATE or a DROP/CREATE... 
    @DefaultDatabase                  sysname         = N'master',          -- have to specify DEFAULT for this to work... obviously
    @DefaultLanguage                  sysname         = N'{DEFAULT}',       -- have to specify DEFAULT for this to work... obviously
    @CheckExpriration                 bit             = 0,                  -- have to specify DEFAULT for this to work... obviously
    @CheckPolicy                      bit             = 0                   -- have to specify DEFAULT for this to work... obviously
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
        
        IF NULLIF(@BehaviorIfLoginExists, N'') IS NULL 
            SET @BehaviorIfLoginExists = N'NONE';

        IF UPPER(@BehaviorIfLoginExists) NOT IN (N'NONE', N'ALTER', N'DROP_AND_CREATE')
            SET @BehaviorIfLoginExists = N'NONE';

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
END; ';
        -- Main logic flow:
        IF UPPER(@BehaviorIfLoginExists) = N'NONE' BEGIN 
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', N'');
            SET @template = REPLACE(@template, N'{ElseClause}', N'');
            SET @template = REPLACE(@template, N'{CreateOrAlter}', N''); 
                
            SET @template = REPLACE(@template, N'{Attributes2}', N'');
            SET @template = REPLACE(@template, N'{Disable2}', N'');

        END;

        IF UPPER(@BehaviorIfLoginExists) = N'ALTER' BEGIN 
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', N'');

            SET @template = REPLACE(@template, N'{ElseClause}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN' + @crlf);
            SET @template = REPLACE(@template, N'{CreateOrAlter}', NCHAR(9) + N'ALTER LOGIN [{Name}] WITH ');
            SET @template = REPLACE(@template, N'{Attributes2}', @alterAttributes);
            SET @template = REPLACE(@template, N'{Disable2}', N'{Disable}');
        END;

        IF UPPER(@BehaviorIfLoginExists) = N'DROP_AND_CREATE' BEGIN 
            SET @template = REPLACE(@template, N'{ElseClause}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN' + @crlf);
            SET @template = REPLACE(@template, N'{SidReplacementDrop}', NCHAR(9) + N'DROP LOGIN ' + QUOTENAME(@Name) + N';' + @crlf + @crlf);
            SET @template = REPLACE(@template, N'{CreateOrAlter}', NCHAR(9) + N'CREATE LOGIN [{Name}] WITH '); 
            
            SET @template = REPLACE(@template, N'{Attributes2}', @attributes);
            SET @template = REPLACE(@template, N'{Disable2}', N'{Disable}');
        END;
  
        -- initialize output with basic details:
        SET @template = REPLACE(@template, N'{Attributes}', @attributes);
        SET @output = REPLACE(@template, N'{Name}', @Name);

        IF (@Password LIKE '0x%') --AND (@Password NOT LIKE '%HASHED')
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
            IF UPPER(@DefaultLanguage) = N'{DEFAULT}'
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
            SET @output = REPLACE(@output, N'{CheckPolicy}', @newAtrributeLine + N',CHECK_POLICY = ' + CASE WHEN @CheckPolicy = 1 THEN N'ON' ELSE 'OFF' END);
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