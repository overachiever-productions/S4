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

        Outputs b, c, and d are all idempotent. (So is output a - it's a comment). 


    SAMPLES / TESTS 
        
            SET NOCOUNT ON;
        
        Expected Error: 
                SELECT dbo.format_windows_login(1, N'NONE', N'', 'Billing', DEFAULT);

        CREATE only - with a (fake) SID and default DB of [Billing] specified
                SELECT dbo.format_windows_login(1, DEFAULT, N'Bilbo', 'Billing', NULL);

        CREATE, but login defaults to NOT active... so it's disabled: 
                SELECT dbo.format_windows_login(NULL, DEFAULT, N'Bilbo', 'Billing', NULL);

        CREATE or ALTER (if it exists - but SID can't be changed by the ALTER):
                SELECT dbo.format_windows_login(1, N'ALTER', N'Bilbo', 'Billing', NULL);

        CREATE or DROP + CREATE 
                SELECT dbo.format_windows_login(1, N'DROP_AND_CREATE', N'Bilbo', 'Billing', NULL);

        As above, but defaults to SAFE config (i.e., @Enabled is NOT specified):
                SELECT dbo.format_windows_login(NULL, N'DROP_AND_CREATE', N'Bilbo', 'Billing', NULL);


		Formatting/Output Test Cases:

			SET NOCOUNT ON;
				SELECT admindb.dbo.[format_windows_login](1, N'NONE', 'DEV\Mike', DEFAULT, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](1, N'ALTER', 'DEV\Mike', DEFAULT, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](1, N'DROP_AND_CREATE', 'DEV\Mike', DEFAULT, DEFAULT);

				SELECT admindb.dbo.[format_windows_login](1, N'NONE', 'DEV\Mike', NULL, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](1, N'ALTER', 'DEV\Mike', NULL, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](1, N'DROP_AND_CREATE', 'DEV\Mike', NULL, DEFAULT);

				SELECT admindb.dbo.[format_windows_login](1, N'NONE', 'DEV\Mike', DEFAULT, NULL);
				SELECT admindb.dbo.[format_windows_login](1, N'ALTER', 'DEV\Mike', DEFAULT, NULL);
				SELECT admindb.dbo.[format_windows_login](1, N'DROP_AND_CREATE', 'DEV\Mike', DEFAULT, NULL);

				SELECT admindb.dbo.[format_windows_login](1, N'NONE', 'DEV\Mike', NULL, NULL);
				SELECT admindb.dbo.[format_windows_login](1, N'ALTER', 'DEV\Mike', NULL, NULL);
				SELECT admindb.dbo.[format_windows_login](1, N'DROP_AND_CREATE', 'DEV\Mike', NULL, NULL);

				----------

				SELECT admindb.dbo.[format_windows_login](0, N'NONE', 'DEV\Mike', DEFAULT, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](0, N'ALTER', 'DEV\Mike', DEFAULT, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](0, N'DROP_AND_CREATE', 'DEV\Mike', DEFAULT, DEFAULT);

				SELECT admindb.dbo.[format_windows_login](0, N'NONE', 'DEV\Mike', NULL, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](0, N'ALTER', 'DEV\Mike', NULL, DEFAULT);
				SELECT admindb.dbo.[format_windows_login](0, N'DROP_AND_CREATE', 'DEV\Mike', NULL, DEFAULT);

				SELECT admindb.dbo.[format_windows_login](0, N'NONE', 'DEV\Mike', DEFAULT, NULL);
				SELECT admindb.dbo.[format_windows_login](0, N'ALTER', 'DEV\Mike', DEFAULT, NULL);
				SELECT admindb.dbo.[format_windows_login](0, N'DROP_AND_CREATE', 'DEV\Mike', DEFAULT, NULL);

				SELECT admindb.dbo.[format_windows_login](0, N'NONE', 'DEV\Mike', NULL, NULL);
				SELECT admindb.dbo.[format_windows_login](0, N'ALTER', 'DEV\Mike', NULL, NULL);
				SELECT admindb.dbo.[format_windows_login](0, N'DROP_AND_CREATE', 'DEV\Mike', NULL, NULL);



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_windows_login', 'FN') IS NOT NULL DROP FUNCTION [dbo].[format_windows_login];
GO

CREATE	FUNCTION [dbo].[format_windows_login] (
	@Enabled bit, -- IF NULL the login will be DISABLED via the output/script.
	@BehaviorIfLoginExists sysname = N'NONE', -- { NONE | ALTER | DROP_ANCE_CREATE }
	@Name sysname, -- always required.
	@DefaultDatabase sysname = N'master', -- have to specify DEFAULT for this to work... obviously
	@DefaultLanguage sysname = N'{DEFAULT}' -- have to specify DEFAULT for this to work... obviously
)
RETURNS nvarchar(MAX)
AS

	-- {copyright}

BEGIN

	SET @Enabled = ISNULL(@Enabled, 0);
	SET @DefaultDatabase = NULLIF(@DefaultDatabase, N'');
	SET @DefaultLanguage = NULLIF(@DefaultLanguage, N'');
	SET @BehaviorIfLoginExists = ISNULL(NULLIF(@BehaviorIfLoginExists, N''), N'NONE');
	
	IF UPPER(@BehaviorIfLoginExists) NOT IN (N'NONE', N'ALTER', N'DROP_AND_CREATE') SET @BehaviorIfLoginExists = N'NONE';

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @newAtrributeLine sysname = @crlf + NCHAR(9) + NCHAR(9);

	DECLARE @output nvarchar(MAX) = N'-- ERROR scripting login. ' + @crlf + N'--' + NCHAR(9) + N'Parameter @Name is required.';

	IF (NULLIF(@Name, N'') IS NULL) BEGIN
		-- output is already set/defined.
		GOTO Done;
	END;

	IF (UPPER(@BehaviorIfLoginExists) = N'ALTER') AND (@DefaultDatabase IS NULL) AND (@DefaultLanguage IS NULL) BEGIN
		-- if these values are EXPLICITLY set to NULL (vs using the defaults), then we CAN'T run an alter - the statement would be: "ALTER LOGIN [principal\name];" ... which no worky. 
		SET @BehaviorIfLoginExists = N'DROP_AND_CREATE';
	END;

	DECLARE @attributesPresent bit = 1;
	IF @DefaultDatabase IS NULL AND @DefaultLanguage IS NULL 
		SET @attributesPresent = 0;

	DECLARE @createAndDisable nvarchar(MAX) = N'CREATE LOGIN [{Name}] FROM WINDOWS{withAttributes};{disable}';

	IF @Enabled = 0  
		SET @createAndDisable = REPLACE(@createAndDisable, N'{disable}', @crlf + @crlf + NCHAR(9) + N'ALTER LOGIN ' + QUOTENAME(@Name) + N' DISABLE;');
	ELSE 
		SET @createAndDisable = REPLACE(@createAndDisable, N'{disable}', N'');
		
	IF @attributesPresent = 1 BEGIN 
		DECLARE @attributes nvarchar(MAX) = N' WITH';

		IF @DefaultDatabase IS NOT NULL BEGIN
			SET @attributes = @attributes + @newAtrributeLine + N'DEFAULT_DATABASE = ' + QUOTENAME(@DefaultDatabase);
		END;

		IF @DefaultLanguage IS NOT NULL BEGIN 
			
			IF UPPER(@DefaultLanguage) = N'{DEFAULT}'
				SELECT
					@DefaultLanguage = [name]
				FROM
					[sys].[syslanguages]
				WHERE
					[langid] = (
					SELECT [value_in_use] FROM [sys].[configurations] WHERE [name] = N'default language'
				);

			IF @DefaultDatabase IS NULL 
				SET @attributes = @attributes + @newAtrributeLine + N'DEFAULT_LANGUAGE = ' + QUOTENAME(@DefaultLanguage)
			ELSE 
				SET @attributes = @attributes +  @newAtrributeLine + N',DEFAULT_LANGUAGE = ' + QUOTENAME(@DefaultLanguage)
		END;

		SET @createAndDisable = REPLACE(@createAndDisable, N'{withAttributes}', @attributes);
	  END
	ELSE BEGIN
		SET @createAndDisable = REPLACE(@createAndDisable, N'{withAttributes}', N'');
	END;

	DECLARE @flowTemplate nvarchar(MAX) = N'
IF NOT EXISTS (SELECT NULL FROM [master].[sys].[server_principals] WHERE [name] = ''{EscapedName}'') BEGIN 
	{createAndDisable}{else}{alterOrCreateAndDisable}
END; ';

	SET @output = REPLACE(@flowTemplate, N'{createAndDisable}', @createAndDisable);

	IF UPPER(@BehaviorIfLoginExists) = N'NONE' BEGIN
		SET @output = REPLACE(@output, N'{else}', N'');
		SET @output = REPLACE(@output, N'{alterOrCreateAndDisable}', N'');
	END;

	IF UPPER(@BehaviorIfLoginExists) = N'ALTER' BEGIN
		SET @output = REPLACE(@output, N'{else}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN ');

		SET @createAndDisable = REPLACE(@createAndDisable, N'CREATE', N'ALTER');
		SET @createAndDisable = REPLACE(@createAndDisable, N' FROM WINDOWS', N'');

		SET @output = REPLACE(@output, N'{alterOrCreateAndDisable}', @crlf + NCHAR(9) + @createAndDisable);
	END;


	IF UPPER(@BehaviorIfLoginExists) = N'DROP_AND_CREATE' BEGIN
		SET @output = REPLACE(@output, N'{else}', @crlf + N'  END;' + @crlf + N'ELSE BEGIN ');

		SET @createAndDisable = @crlf + NCHAR(9) + N'DROP LOGIN [{Name}];' + @crlf + @crlf + NCHAR(9) + @createAndDisable;

		SET @output = REPLACE(@output, N'{alterOrCreateAndDisable}', @crlf + NCHAR(9) + @createAndDisable);
	END;

	SET @output = REPLACE(@output, N'{Name}', @Name);
	SET @output = REPLACE(@output, N'{EscapedName}', REPLACE(@Name, N'''', N''''''));

Done:

	RETURN @output;

END;
GO