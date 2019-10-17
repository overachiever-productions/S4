/*
    INTERNAL 


    vNEXT:
        Make sure that 
            a) database mail has actually been setup. (pretty sure the profile check will do JUST that)
            b) that the SQL Server Agent has the ability to TALK TO database mail and can USE the profile supplied/specified (hmmm do we set the profile to USE or is that the default profile in the 'ALerting' tab in SQL Agent?)



    SIGNATURE TESTS: 

        -- Expect an exception (unless 'bilbo' is a defined operator on your system):

                EXEC dbo.verify_alerting_configuration
                    N'bilbo', 
                    NULL;

        -- Expect an exception for invalid email profile (unless it exists): 

                EXEC dbo.verify_alerting_configuration
                    NULL,
                    N'kittens';

        -- Expect defaults / successful outputs (i.e., NO exceptions): 

                EXEC dbo.verify_alerting_configuration
                    NULL,
                    NULL;
            
        -- Likewise (no exceptions):

                EXEC dbo.verify_alerting_configuration
                    N'Alerts',
                    N'General';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_alerting_configuration','P') IS NOT NULL
	DROP PROC dbo.[verify_alerting_configuration];
GO

CREATE PROC dbo.[verify_alerting_configuration]
	@OperatorName						    sysname									= N'{DEFAULT}',
	@MailProfileName					    sysname									= N'{DEFAULT}'
AS
    SET NOCOUNT ON; 

    -- {copyright}
    DECLARE @output sysname;

    IF UPPER(@OperatorName) = N'{DEFAULT}' OR (NULLIF(@OperatorName, N'') IS NULL) BEGIN 
        SET @output = NULL;
        EXEC dbo.load_default_setting 
            @SettingName = N'DEFAULT_OPERATOR', 
            @Result = @output OUTPUT;

        SET @OperatorName = @output;
    END;

    IF UPPER(@MailProfileName) = N'{DEFAULT}' OR (NULLIF(@MailProfileName, N'') IS NULL) BEGIN
        SET @output = NULL;
        EXEC dbo.load_default_setting 
            @SettingName = N'DEFAULT_PROFILE', 
            @Result = @output OUTPUT;   
            
        SET @MailProfileName = @output;
    END;
	
    -- Operator Check:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be via email if encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalid Operator Name Specified.', 16, 1);
			RETURN -4;
		END;
	END;

	-- Profile Check:
	DECLARE @DatabaseMailProfile nvarchar(255);
	EXEC master.dbo.xp_instance_regread 
        N'HKEY_LOCAL_MACHINE', 
        N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', 
        @param = @DatabaseMailProfile OUT, 
        @no_output = N'no_output';
 
	IF @DatabaseMailProfile != @MailProfileName BEGIN
		RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
		RETURN -5;
	END; 

    RETURN 0;
GO