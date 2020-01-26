/*
	FACADE
		Actual 'work' of scripting a login is handled in either dbo.script_sql_login or dbo.script_windows_login.



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_login','P') IS NOT NULL
	DROP PROC dbo.[script_login];
GO

CREATE PROC dbo.[script_login]
    @LoginName                              sysname,       
    @BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
	@DisableExpiryChecks					bit						= 0, 
    @DisablePolicyChecks					bit						= 0,
	@ForceMasterAsDefaultDB					bit						= 0, 
	@IncludeDefaultLanguage					bit						= 0,
    @Output                                 nvarchar(MAX)           = ''        OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @name sysname, @loginType nvarchar(60);

	SELECT 
		@name = [name],
		@loginType = [type_desc]
	FROM 
		sys.[server_principals]
	WHERE
		[name] = @LoginName;

    IF @name IS NULL BEGIN 
        IF @Output IS NULL 
            SET @Output = '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';
        ELSE 
            PRINT '-- No Login matching the name ' + QUOTENAME(@LoginName) + N' exists on the current server.';

        RETURN -2;
    END;

	DECLARE @result int;
	DECLARE @formatted nvarchar(MAX);

	IF @loginType = N'WINDOWS_LOGIN' BEGIN

		EXEC @result = dbo.[script_windows_login]
			@LoginName = @name,
			@BehaviorIfLoginExists = @BehaviorIfLoginExists,
			@ForceMasterAsDefaultDB = @ForceMasterAsDefaultDB,
			@IncludeDefaultLanguage = @IncludeDefaultLanguage,
			@Output = @formatted OUTPUT;
		
		IF @result <> 0 
			RETURN @result;

		GOTO ScriptCreated;
	END; 

	IF @loginType = N'SQL_LOGIN' BEGIN

		EXEC @result = dbo.[script_sql_login]
			@LoginName = @name,
			@BehaviorIfLoginExists = @BehaviorIfLoginExists,
			@DisableExpiryChecks = @DisableExpiryChecks,
			@DisablePolicyChecks = @DisablePolicyChecks,
			@ForceMasterAsDefaultDB = @ForceMasterAsDefaultDB,
			@IncludeDefaultLanguage = @IncludeDefaultLanguage,
			@Output = @formatted OUTPUT

		IF @result <> 0 
			RETURN @result;

		GOTO ScriptCreated;
	END; 

	-- If we're still here, we tried to script/print a login type that's not yet supported. 
	RAISERROR('Sorry, S4 does not yet support scripting ''%s'' logins.', 16, 1);
	RETURN -20;

ScriptCreated: 

    IF @Output IS NULL BEGIN 
        SET @Output = @formatted;
        RETURN 0;
    END;

    PRINT @formatted;
    RETURN 0;
GO