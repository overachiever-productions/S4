/*

	NOTE: 
		- This can be pretty easily extended to check for other/additional 'settings' that should be contained for certain databases and/or various exceptions. 
			for example, say you want this to report on any database that is NOT 'ONLINE' or... is_trustworthy_on = 1... 
				then you'd just:
					a) add a new @OnlineExclusions nvarchar(max) or @TrustworthyRequired nvarchar(max) parameter as needed... 
						
					b) add a new check that either includes/excludes based upon a LEFT OUTER JOIN to dbo.split_string(@yourVariableNameHere, N',') ON sys.databases.name LIKE [result] (from split_string)... 
							and report on any things that are/are-not as expected or defined/allowed. 


EXEC [admindb].dbo.[verify_database_configurations]
    --@DatabasesToExclude = N'', 
    --@CompatabilityExclusions = N'', 
    @ReportDatabasesNotOwnedBySA = 1, 
    @PrintOnly = 1;


*/



USE admindb;
GO

IF OBJECT_ID('dbo.verify_database_configurations','P') IS NOT NULL
	DROP PROC dbo.verify_database_configurations;
GO

CREATE PROC dbo.verify_database_configurations 
	@DatabasesToExclude				nvarchar(MAX)	= NULL,
	@EnableRcsi						bit				= 0,
	@RcsiExclusions					nvarchar(MAX)	= NULL,
	@CompatabilityExclusions		nvarchar(MAX)	= NULL,
	@ReportDatabasesNotOwnedBySA	bit				= 0,
	@OperatorName					sysname			= N'Alerts',
	@MailProfileName				sysname			= N'General',
	@EmailSubjectPrefix				nvarchar(50)	= N'[Database Configuration Alert] ',
	@PrintOnly						bit				= 0
AS
	SET NOCOUNT ON;

	-- {copyright}
	SET @RcsiExclusions = NULLIF(@RcsiExclusions, N'');
	SET @DatabasesToExclude = NULLIF(@DatabasesToExclude, N'');
	SET @CompatabilityExclusions = NULLIF(@CompatabilityExclusions, N'');

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

	-- start by (messily) grabbing the current version on the server:
	DECLARE @serverVersion int;
	SET @serverVersion = (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) * 10;

	DECLARE @databasesToCheck table (
		[name] sysname
	);
	
	INSERT INTO @databasesToCheck ([name])
	EXEC dbo.list_databases 
		@Targets = N'{USER}',
		@Exclusions = @DatabasesToExclude;

	DECLARE @excludedComptabilityDatabases table ( 
		[name] sysname NOT NULL
	); 

	IF @CompatabilityExclusions IS NOT NULL BEGIN 
		INSERT INTO @excludedComptabilityDatabases ([name])
		SELECT [result] FROM dbo.split_string(@CompatabilityExclusions, N',', 1) ORDER BY row_id;
	END; 

	DECLARE @excludedRcsiDatabases table (
		[name] sysname NOT NULL
	);

	IF @RcsiExclusions IS NOT NULL BEGIN 
		INSERT INTO @excludedRcsiDatabases ([name])
		SELECT [result] FROM dbo.[split_string](@RcsiExclusions, N',', 1);
	END;

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
	
	-- Compatablity Checks: 
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database],
		N'Compatibility should be ' + CAST(@serverVersion AS sysname) + N'. Currently set to ' + CAST(d.[compatibility_level] AS sysname) + N'.' [issue], 
		N'ALTER DATABASE' + QUOTENAME(d.[name]) + N' SET COMPATIBILITY_LEVEL = ' + CAST(@serverVersion AS sysname) + N';' [command], 
		N'Database Compatibility successfully set to ' + CAST(@serverVersion AS sysname) + N'.'  [success_message]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
		LEFT OUTER JOIN @excludedComptabilityDatabases e ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE e.[name] -- allow LIKE %wildcard% exclusions
	WHERE 
		d.[compatibility_level] <> CAST(@serverVersion AS tinyint)
		AND e.[name] IS  NULL -- only include non-exclusions
	ORDER BY 
		d.[name] ;
		
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
	IF @ReportDatabasesNotOwnedBySA = 1 BEGIN
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
	END;

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
		
	-- RCSI: 
	INSERT INTO @issues ([database], [issue], [command], [success_message])
	SELECT 
		d.[name] [database], 
		N'RCSI should be ' + CASE WHEN @EnableRcsi = 1 THEN N'ENABLED' ELSE N'DISABLED' END + '. Currently ' + CASE WHEN @EnableRcsi = 1 THEN N'DISABLED' ELSE N'ENABLED' END + '.' [issue], 
		N'ALTER DATABASE ' + QUOTENAME(d.[name]) + N' SET READ_COMMITTED_SNAPSHOT ' + CASE WHEN @EnableRcsi = 1 THEN N'ON' ELSE N'OFF' END + ' WITH ROLLBACK AFTER 2 SECONDS; ' [command], 
		N'RCSI successfully set to ' + CASE WHEN @EnableRcsi = 1 THEN N'ENABLED' ELSE N'DISABLED' END + '.' [success_message]
	FROM 
		sys.databases d 
		INNER JOIN @databasesToCheck x ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS = x.[name]
		LEFT OUTER JOIN @excludedRcsiDatabases e ON d.[name] COLLATE SQL_Latin1_General_CP1_CI_AS LIKE e.[name] -- allow LIKE %wildcard% exclusions
	WHERE 
		[d].[is_read_committed_snapshot_on] <> @EnableRcsi 
		AND e.[name] IS  NULL -- only include non-exclusions
	ORDER BY 
		d.[name];

	-----------------------------------------------------------------------------
	-- add other checks as needed/required per environment:

    -- vNEXT: figure out how to drop these details into a table and/or something that won't 'change' per environment. 
    --          i.e., say that in environment X we NEED to check for ABC... great. we hard code in here for that. 
    --              then S4 vNext comes out, ALTERS this (assuming there were changes) and the logic for ABC checks is overwritten... 



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
			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailBody;
		END
	END;

	RETURN 0;
GO