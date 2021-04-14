/*

	'Forces' databases into DEV/Test config mode (i.e., SIMPLE Recovery). 
		Also ensures other best-practices for configuration as well. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_dev_configurations','P') IS NOT NULL
	DROP PROC dbo.[verify_dev_configurations];
GO

CREATE PROC dbo.[verify_dev_configurations]
	@TargetDatabases				nvarchar(MAX)		= NULL, 
	@DatabasesToExclude				nvarchar(MAX)		= NULL, 
	@SendChangeNotifications		bit					= 0, 
	@OperatorName					sysname				= N'Alerts',
	@MailProfileName				sysname				= N'General',
	@EmailSubjectPrefix				nvarchar(50)		= N'[Database Configuration Alert] ',
	@PrintOnly						bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF @PrintOnly = 0 BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 
		
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -2;
		 END;
		ELSE BEGIN 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalild Operator Name Specified.', 16, 1);
				RETURN -2;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255)
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output'
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -2;
		END; 
	END;

	-----------------------------------------------------------------------------
	-- Set up / initialization:
	DECLARE @databasesToCheck table (
		[name] sysname
	);
	
	INSERT INTO @databasesToCheck ([name])
	EXEC dbo.list_databases 
		@Targets = @TargetDatabases,
		@Exclusions = @DatabasesToExclude;

	DECLARE @issues table ( 
		issue_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		issue varchar(2000) NOT NULL, 
		command nvarchar(2000) NOT NULL, 
		success_message varchar(2000) NOT NULL,
		succeeded bit NOT NULL DEFAULT (0),
		[error_message] nvarchar(MAX) NULL 
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);


	-----------------------------------------------------------------------------
	-- Checks: 
		
	-- SIMPLE RECOVERY: 
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'Recovery Model should be set to SIMPLE. Currently set to ' + d.[recovery_model_desc] + N'.0' [issue],
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET RECOVERY SIMPLE; ' [command],
		N'Recovery Model successfully set to SIMPLE.' [success_message]
	FROM 
		sys.databases d 
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		[recovery_model_desc] <> N'SIMPLE'
	ORDER BY 
		d.[name];

	-- Page Verify: 
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'Page Verify should be set to CHECKSUM. Currently set to ' + ISNULL(page_verify_option_desc, 'NOTHING') + N'.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET PAGE_VERIFY CHECKSUM; ' [command], 
		N'Page Verify successfully set to CHECKSUM.' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		page_verify_option_desc <> N'CHECKSUM'
	ORDER BY 
		d.[name];

	-- OwnerChecks:
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'Should be owned by 0x01 (SysAdmin). Currently owned by 0x' + CONVERT(nvarchar(MAX), owner_sid, 2) + N'.' [issue], 
		N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(d.[name]) + N' TO sa;' [command], 
		N'Database owndership successfully transferred to 0x01 (SysAdmin).' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		owner_sid <> 0x01;

	-- AUTO_CLOSE:
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'AUTO_CLOSE should be DISABLED. Currently ENABLED.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET AUTO_CLOSE OFF; ' [command], 
		N'AUTO_CLOSE successfully set to DISABLED.' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		[is_auto_close_on] = 1
	ORDER BY 
		d.[name];

	-- AUTO_SHRINK:
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'AUTO_SHRINK should be DISABLED. Currently ENABLED.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET AUTO_SHRINK OFF; ' [command], 
		N'AUTO_SHRINK successfully set to DISABLED.' [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
	WHERE 
		[is_auto_shrink_on] = 1
	ORDER BY 
		d.[name];


	-- other checks as needed... 


	-----------------------------------------------------------------------------
	-- (attempted) fixes: 
	IF EXISTS (SELECT NULL FROM @issues) BEGIN 

		DECLARE fixer CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[issue_id], 
			[command] 
		FROM 
			@issues 
		ORDER BY [issue_id];

		DECLARE @currentID int;
		DECLARE @currentCommand nvarchar(2000); 
		DECLARE @errorMessage nvarchar(MAX);

		OPEN [fixer];
		FETCH NEXT FROM [fixer] INTO @currentID, @currentCommand;

		WHILE @@FETCH_STATUS = 0 BEGIN 
			
			SET @errorMessage = NULL;

			BEGIN TRY 
                IF @PrintOnly = 0 BEGIN 
				    EXEC sp_executesql @currentCommand;
                END;

                UPDATE @issues SET [succeeded] = 1 WHERE [issue_id] = @currentID;

			END TRY 
			BEGIN CATCH
				SET @errorMessage = CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
				UPDATE @issues SET [error_message] = @errorMessage WHERE [issue_id] = @currentID;
			END CATCH

			FETCH NEXT FROM [fixer] INTO @currentID, @currentCommand;
		END;

		CLOSE [fixer]; 
		DEALLOCATE fixer;

	END;

	-----------------------------------------------------------------------------
	-- reporting: 
	DECLARE @emailBody nvarchar(MAX) = NULL;
	DECLARE @emailSubject nvarchar(300);
	IF EXISTS (SELECT NULL FROM @issues) BEGIN 
		SET @emailBody = N'';
		
		DECLARE @correctionErrorsOccurred bit = 0;
		DECLARE @correctionsCompletedSuccessfully bit = 0; 

		IF EXISTS (SELECT NULL FROM @issues WHERE [succeeded] = 0) BEGIN -- process ERRORS first. 
			SET @correctionErrorsOccurred = 1;
		END; 

		IF EXISTS (SELECT NULL FROM @issues WHERE [succeeded] = 1) BEGIN -- report on successful changes: 
			SET @correctionsCompletedSuccessfully = 1;
		END;

		IF @correctionErrorsOccurred = 1 BEGIN
			SET @emailSubject = @EmailSubjectPrefix + N' - Errors Addressing Database Settings';
			
			IF @correctionsCompletedSuccessfully = 1 
				SET @emailBody = N'Configuration Problems Detected. Some were automatically corrected; Others encountered errors during attempt to correct:' + @crlf + @crlf;
			ELSE 
				SET @emailBody = N'Configuration Problems Detected.' + @crlf + @crlf + UPPER(' Errors encountred while attempting to correct:') + @crlf + @crlf;

			SELECT 
				@emailBody = @emailBody + @tab + QUOTENAME([database]) + N' - ' + [issue] + @crlf
					+ @tab + @tab + N'ATTEMPTED CORRECTION: -> ' + [command] + @crlf
					+ @tab + @tab + @tab + N'ERROR: ' + ISNULL([error_message], N'##Unknown/Uncaptured##') + @crlf + @crlf
			FROM 
				@issues 
			WHERE 
				[succeeded] = 0 
			ORDER BY [issue_id];

		END;

		IF @correctionsCompletedSuccessfully = 1 BEGIN
			SET @emailSubject = @EmailSubjectPrefix + N' - Database Configuration Settings Successfully Updated';

			IF @correctionErrorsOccurred = 1
				SET @emailBody = @emailBody + @crlf + @crlf;

			SET @emailBody = @emailBody + N'The following database configuration changes were successfully applied:' + @crlf + @crlf;

			SELECT 
				@emailBody = @emailBody + @tab + QUOTENAME([database]) + @crlf
				+ @tab + @tab + N'OUTCOME: ' + [success_message] + @crlf + @crlf
				+ @tab + @tab + @tab + @tab + N'Detected Problem: ' + [issue] + @crlf
				+ @tab + @tab + @tab + @tab + N'Executed Correction: ' + [command] + @crlf + @crlf
			FROM 
				@issues 
			WHERE 
				[succeeded] = 1 
			ORDER BY [issue_id];
		END;

	END;

	-- send/display any problems:
	IF @emailBody IS NOT NULL BEGIN
		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
            PRINT N'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!';
            PRINT N'! NOTE: _NO CHANGES_ were made. The output below simply ''simulates'' what would have been done had @PrintOnly been set to 0:';
            PRINT N'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!';
			PRINT @emailBody;
		  END;
		ELSE BEGIN 
			
			IF @SendChangeNotifications = 1 BEGIN
				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @emailBody;
			  END;
			ELSE BEGIN 
				-- Print to job output - so there's a 'history' (ish) of these changes:
				PRINT @emailSubject;
				EXEC admindb.dbo.[print_long_string] @emailBody;
			END;
		END
	END;

	RETURN 0;
GO