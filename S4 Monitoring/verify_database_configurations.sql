


/*

	NOTE: 
		- This can be pretty easily extended to check for other/additional 'settings' that should be contained for certain databases and/or various exceptions. 
			for example, say you want this to report on any database that is NOT 'ONLINE' or... is_trustworthy_on = 1... 
				then you'd just:
					a) add a new @OnlineExclusions nvarchar(max) or @TrustworthyRequired nvarchar(max) parameter as needed... 
						
					b) add a new check that either includes/excludes based upon a LEFT OUTER JOIN to dbo.split_string(@yourVariableNameHere, N',') ON sys.databases.name LIKE [result] (from split_string)... 
							and report on any things that are/are-not as expected or defined/allowed. 



*/


USE admindb;
GO


IF OBJECT_ID('dbo.verify_database_configurations','P') IS NOT NULL
	DROP PROC dbo.verify_database_configurations;
GO

CREATE PROC dbo.verify_database_configurations 
	@DatabasesToExclude				nvarchar(MAX) = NULL,
	@CompatabilityExclusions		nvarchar(MAX) = NULL,
	@ReportDatabasesNotOwnedBySA	bit	= 0,
	@OperatorName					sysname = N'Alerts',
	@MailProfileName				sysname = N'General',
	@EmailSubjectPrefix				nvarchar(50) = N'[Database Configuration Alert] ',
	@PrintOnly						bit = 0
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

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

	IF RTRIM(LTRIM(@DatabasesToExclude)) = N''
		SET @DatabasesToExclude = NULL;

	IF RTRIM(LTRIM(@CompatabilityExclusions)) = N''
		SET @DatabasesToExclude = NULL;

	-----------------------------------------------------------------------------
	-- Set up / initialization:

	-- start by (messily) grabbing the current version on the server:
	DECLARE @serverVersion int;
	SET @serverVersion = (SELECT CAST((LEFT(CAST(SERVERPROPERTY('ProductVersion') AS sysname), CHARINDEX('.', CAST(SERVERPROPERTY('ProductVersion') AS sysname)) - 1)) AS int)) * 10;

	DECLARE @serialized nvarchar(MAX);
	DECLARE @databasesToCheck table (
		[name] sysname
	);
	
	EXEC dbo.load_database_names 
		@Input = N'[USER]',
		@Exclusions = @DatabasesToExclude, 
		@Mode = N'VERIFY', 
		@BackupType = N'FULL',
		@Output = @serialized OUTPUT;

	INSERT INTO @databasesToCheck ([name])
	SELECT [result] FROM dbo.split_string(@serialized, N',') ORDER BY row_id;

	DECLARE @excludedComptabilityDatabases table ( 
		[name] sysname NOT NULL
	); 

	IF @CompatabilityExclusions IS NOT NULL BEGIN 
		INSERT INTO @excludedComptabilityDatabases ([name])
		SELECT [result] FROM dbo.split_string(@CompatabilityExclusions, N',') ORDER BY row_id;
	END; 

	DECLARE @issues table ( 
		issue_id int IDENTITY(1,1) NOT NULL, 
		[database] sysname NOT NULL, 
		issue varchar(2000) NOT NULL 
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);

	-----------------------------------------------------------------------------
	-- Checks: 
	
	-- Compatablity Checks: 
	INSERT INTO @issues ([database], issue)
	SELECT 
		d.[name] [database],
		N'Compatibility should be ' + CAST(@serverVersion AS sysname) + N' but is currently set to ' + CAST(d.compatibility_level AS sysname) + N'.' + @crlf + @tab + @tab + N'To correct, execute: ALTER DATABASE' + QUOTENAME(d.[name]) + N' SET COMPATIBILITY_LEVEL = ' + CAST(@serverVersion AS sysname) + N';' [issue]
	FROM 
		sys.databases d
		INNER JOIN @databasesToCheck x ON d.[name] = x.[name]
		LEFT OUTER JOIN @excludedComptabilityDatabases e ON d.[name] LIKE e.[name] -- allow LIKE %wildcard% exclusions
	WHERE 
		d.[compatibility_level] <> CAST(@serverVersion AS tinyint)
		AND e.[name] IS  NULL -- only include non-exclusions
	ORDER BY 
		d.[name] ;
		

	-- Page Verify: 
	INSERT INTO @issues ([database], issue)
	SELECT 
		[name] [database], 
		N'Page Verify should be set to CHECKSUM - but is currently set to ' + ISNULL(page_verify_option_desc, 'NOTHING') + N'.' + @crlf + @tab + @tab + N'To correct, execute: ALTER DATABASE ' + QUOTENAME([name]) + N' SET PAGE_VERIFY CHECKSUM; ' [issue]
	FROM 
		sys.databases 
	WHERE 
		page_verify_option_desc <> N'CHECKSUM'
	ORDER BY 
		[name];

	-- OwnerChecks:
	IF @ReportDatabasesNotOwnedBySA = 1 BEGIN
		INSERT INTO @issues ([database], issue)
		SELECT 
			[name] [database], 
			N'Should by Owned by 0x01 (SysAdmin) but is currently owned by 0x' + CONVERT(nvarchar(MAX), owner_sid, 2) + N'.' + @crlf + @tab + @tab + N'To correct, execute:  ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME([name]) + N' TO sa;' [issue]
		FROM 
			sys.databases 
		WHERE 
			owner_sid <> 0x01;
	END;

	-- AUTO_CLOSE:
	INSERT INTO @issues ([database], issue)
	SELECT 
		[name] [database], 
		N'AUTO_CLOSE is enabled - and should be DISABLED.' + @crlf + @tab + @tab + N'To correct, execute: ALTER DATABASE ' + QUOTENAME([name]) + N' SET AUTO_CLOSE OFF; ' [issue]
	FROM 
		sys.databases 
	WHERE 
		[is_auto_close_on] = 1
	ORDER BY 
		[name];

	-- AUTO_SHRINK:
	INSERT INTO @issues ([database], issue)
	SELECT 
		[name] [database], 
		N'AUTO_SHRINK is enabled - and should be DISABLED.' + @crlf + @tab + @tab + N'To correct, execute: ALTER DATABASE ' + QUOTENAME([name]) + N' SET AUTO_SHRINK OFF; ' [issue]
	FROM 
		sys.databases 
	WHERE 
		[is_auto_shrink_on] = 1
	ORDER BY 
		[name];
		
	-----------------------------------------------------------------------------
	-- add other checks as needed/required per environment:




	-----------------------------------------------------------------------------
	-- reporting: 
	DECLARE @emailErrorMessage nvarchar(MAX);
	IF EXISTS (SELECT NULL FROM @issues) BEGIN 
		
		DECLARE @emailSubject nvarchar(300);

		SET @emailErrorMessage = N'The following configuration discrepencies were detected: ' + @crlf;

		SELECT 
			@emailErrorMessage = @emailErrorMessage + @tab + QUOTENAME([database]) + N'. ' + [issue] + @crlf
		FROM 
			@issues 
		ORDER BY 
			[database],
			issue_id;

	END;

	-- send/display any problems:
	IF @emailErrorMessage IS NOT NULL BEGIN
		IF @PrintOnly = 1 
			PRINT @emailErrorMessage;
		ELSE BEGIN 
			SET @emailSubject = @EmailSubjectPrefix + N' - Configuration Problems Detected';

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName,
				@subject = @emailSubject, 
				@body = @emailErrorMessage;

		END
	END;

	RETURN 0;
GO