/*
	INTERNAL
		

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_windows_login','P') IS NOT NULL
	DROP PROC dbo.[script_windows_login];
GO

CREATE PROC dbo.[script_windows_login]
    @LoginName                              sysname,       
    @BehaviorIfLoginExists                  sysname                 = N'NONE',            -- { NONE | ALTER | DROP_AND_CREATE }
	@ForceMasterAsDefaultDB					bit						= 0, 
	@IncludeDefaultLanguage					bit						= 0,
    @Output                                 nvarchar(MAX)           = ''        OUTPUT

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @enabled bit, @name sysname;
	DECLARE @defaultDB sysname, @defaultLang sysname;

	SELECT 
        @enabled = CASE WHEN [is_disabled] = 1 THEN 0 ELSE 1 END,
        @name = [name],
        @defaultDB = [default_database_name],
        @defaultLang = [default_language_name]
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

    ---------------------------------------------------------
    -- overrides:
    IF @ForceMasterAsDefaultDB = 1 
        SET @defaultDB = N'master';

	IF @IncludeDefaultLanguage = 0
		SET @defaultLang = NULL;

    ---------------------------------------------------------
    -- load output:
    DECLARE @formatted nvarchar(MAX);
	SELECT @formatted = dbo.[format_windows_login](
		@enabled, 
		@BehaviorIfLoginExists, 
		@name,
		@defaultDB, 
		@defaultLang
	);

    IF @Output IS NULL BEGIN 
        SET @Output = @formatted;
        RETURN 0;
    END;

    PRINT @formatted;
    RETURN 0;
GO