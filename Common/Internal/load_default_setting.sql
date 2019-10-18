/*
	NOTE: Adheres to the PROJECT or RETURN convention.
	

    USAGE: 
        - Internal 
        - Called to grab (in the following order): 
            a) explicitly defined defaults (i.e., in dbo.settings)
            b) S4 conventions / defaults if/as there are no explicit settings. 

        - Supported Default Values: 
		            DEFAULT_BACKUP_PATH
		            DEFAULT_DATA_PATH
		            DEFAULT_LOG_PATH
		            DEFAULT_OPERATOR
		            DEFAULT_PROFILE
            i.e., if ANY of the values above are specified as the dbo.settings.setting_key, then the corresponding dbo.settings.setting_value will 
                be loaded as the default. 
                    OTHERWISE, for paths/etc. we'll query the registry, and for Operators/Profile we'll default to Alerts/General (i.e., conventions).


    SIGNATURE / TESTS: 
        
        -- Expect NULL (unless this value is defined):

                    EXEC dbo.load_default_setting 
                        'DEFAULT_PROFILE';

        -- Expect SQL Server default (if specified as a 'server property'): 

                    EXEC dbo.load_default_setting N'DEFAULT_BACKUP_PATH';

        -- As above, but expect output via @Result instead: 

                    DECLARE @result sysname; 
                    EXEC dbo.load_default_setting 
                        @SettingName = N'DEFAULT_BACKUP_PATH', 
                        @Result = @result OUTPUT;

                    SELECT @result;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.load_default_setting','P') IS NOT NULL
	DROP PROC dbo.load_default_setting;
GO

CREATE PROC dbo.load_default_setting
	@SettingName			sysname	                    = NULL, 
	@Result					sysname			            = N''       OUTPUT			-- NOTE: Non-NULL for PROJECT or REPLY convention
AS
	SET NOCOUNT ON; 
	
	-- {copyright}
	
	DECLARE @output sysname; 

    SET @output = (SELECT TOP 1 [setting_value] FROM dbo.settings WHERE UPPER([setting_key]) = UPPER(@SettingName) ORDER BY [setting_id] DESC);

    -- load convention 'settings' if nothing has been explicitly set: 
    IF @output IS NULL BEGIN
        DECLARE @conventions table ( 
            setting_key sysname NOT NULL, 
            setting_value sysname NOT NULL
        );

        INSERT INTO @conventions (
            [setting_key],
            [setting_value]
        )
        VALUES 
		    (N'DEFAULT_BACKUP_PATH', (SELECT dbo.[load_default_path](N'BACKUP'))),
		    (N'DEFAULT_DATA_PATH', (SELECT dbo.[load_default_path](N'LOG'))),
		    (N'DEFAULT_LOG_PATH', (SELECT dbo.[load_default_path](N'DATA'))),
		    (N'DEFAULT_OPERATOR', N'Alerts'),
		    (N'DEFAULT_PROFILE', N'General');            

        SELECT @output = [setting_value] FROM @conventions WHERE [setting_key] = @SettingName;

    END;

    IF @Result IS NULL 
        SET @Result = @output; 
    ELSE BEGIN 
        DECLARE @dynamic nvarchar(MAX) = N'SELECT @output [' + @SettingName + N'];';  
        
        EXEC sys.sp_executesql 
            @dynamic, 
            N'@output sysname', 
            @output = @output;
    END;
    
    RETURN 0;
GO