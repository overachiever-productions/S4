
/*




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_specification_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_specification_configuration;
GO

CREATE PROC dbo.verify_specification_configuration 
	@Target									sysname				= N'SERVER',		--SERVER | 'db_name' - SERVER represents a server-level specification whereas a specific dbname represents a db-level specification.
	@SpecificationName						sysname, 
	@ExpectedEnabledState					sysname				= N'ON',   -- ON | OFF
	@OptionalSpecificationSignature			bigint				= NULL, 
	@IncludeParentAuditIdInSignature		bit					= 1,		-- i.e., defines setting of @IncludeParentAuditIdInSignature when original signature was signed. 
	@EmailSubjectPrefix						nvarchar(50)		= N'[Audit Configuration] ',
	@MailProfileName						sysname				= N'General',	
	@OperatorName							sysname				= N'Alerts',	
	@PrintOnly								bit					= 0	
AS	
	SET NOCOUNT ON; 

	-- {copyright}

	IF UPPER(@ExpectedEnabledState) NOT IN (N'ON', N'OFF') BEGIN
		RAISERROR('Allowed values for @ExpectedEnabledState are ''ON'' or ''OFF'' - no other values are allowed.', 16, 1);
		RETURN -1;
	END;

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) NOT NULL
	);

	DECLARE @specificationScope sysname;

	 IF NULLIF(@Target, N'') IS NULL OR @Target = N'SERVER'
		SET @specificationScope = N'SERVER';
	ELSE 
		SET @specificationScope = N'DATABASE';

	DECLARE @sql nvarchar(max) = N'
		SELECT 
			@specificationID = [{1}_specification_id], 
			@auditGUID = [audit_guid], 
			@isEnabled = [is_state_enabled] 
		FROM 
			[{0}].sys.[{1}_audit_specifications] 
		WHERE 
			[name] = @SpecificationName;';

	-- make sure specification (and target db - if db-level spec) exist and grab is_enabled status: 
	IF @specificationScope = N'SERVER' BEGIN	
		SET @sql = REPLACE(@sql, N'{0}', N'master');
		SET @sql = REPLACE(@sql, N'{1}', N'server');
	  END;
	ELSE BEGIN 
		
		-- Make sure the target database exists:
		DECLARE @targetOutput nvarchar(max);

		EXEC dbo.list_databases
			@Target = @Target,
			@ExcludeDev = 1,
			@Output = @targetOutput OUTPUT;

		IF LEN(ISNULL(@targetOutput,'')) < 1 BEGIN
			SET @errorMessage = N'ERROR: Specified @Target database [' + @Target + N'] does not exist. Please check your input and try again.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
			GOTO ALERTS;
		END;

		SET @sql = REPLACE(@sql, N'{0}', @Target);
		SET @sql = REPLACE(@sql, N'{1}', N'database');
	END;

	DECLARE @specificationID int; 
	DECLARE @isEnabled bit; 
	DECLARE @auditGUID uniqueidentifier;

	-- fetch details: 
	EXEC sys.[sp_executesql]
		@stmt = @sql, 
		@params = N'@specificationID int OUTPUT, @isEnabled bit OUTPUT, @auditGUID uniqueidentifier OUTPUT', 
		@specificationID = @specificationID OUTPUT, @isEnabled = @isEnabled OUTPUT, @auditGUID = @auditGUID OUTPUT;

	-- verify spec exists: 
	IF @auditGUID IS NULL BEGIN
		SET @errorMessage = N'WARNING: Specified @SpecificationName [' + @SpecificationName + N'] does not exist in @Target database [' + @Target + N'].';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
		GOTO ALERTS;
	END;

	-- check on/off state:
	IF UPPER(@ExpectedEnabledState) = N'ON' BEGIN 
		IF @isEnabled <> 1 BEGIN
			SELECT @errorMessage = N'WARNING: Specification [' + @SpecificationName + N'] expected is_enabled state was: ''ON'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	  END; 
	ELSE BEGIN 
		IF @isEnabled <> 0 BEGIN 
			SELECT @errorMessage = N'WARNING: Specification [' + @SpecificationName + N'] expected is_enabled state was: ''OFF'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	END; 

	-- verify signature: 
	IF @OptionalSpecificationSignature IS NOT NULL BEGIN 
		DECLARE @currentSignature bigint = 0;
		DECLARE @returnValue int; 

		EXEC @returnValue = dbo.generate_specification_signature
			@Target = @Target, 
			@SpecificationName = @SpecificationName, 
			@IncludeParentAuditIdInSignature = @IncludeParentAuditIdInSignature,
			@SpecificationSignature = @currentSignature OUTPUT;

		IF @returnValue <> 0 BEGIN 
				SELECT @errorMessage = N'ERROR: Problem generating specification signature for [' + @SpecificationName + N'] on ' + @@SERVERNAME + N'.';
				INSERT INTO @errors([error]) VALUES (@errorMessage);			
		  END;
		ELSE BEGIN
			IF @OptionalSpecificationSignature <> @currentSignature BEGIN
				SELECT @errorMessage = N'WARNING: Expected signature for Specification [' + @SpecificationName + N'] (with a value of ' + CAST(@OptionalSpecificationSignature AS sysname) + N') did NOT match currently generated signature (with value of ' + CAST(@currentSignature AS sysname) + N').';
				INSERT INTO @errors([error]) VALUES (@errorMessage);	
			END;
		END;
	END;

ALERTS:

	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';
		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9);

		SET @errorMessage = N'The following conditions were detected: ' + @crlf;

		SELECT @errorMessage = @errorMessage + @tab + N'- ' + error + @crlf
		FROM @errors
		ORDER BY error_id;

		IF @PrintOnly = 1 BEGIN
			PRINT N'SUBJECT: ' + @subject;
			PRINT N'BODY: ' + @errorMessage;
		  END
		ELSE BEGIN 
			EXEC msdb.dbo.sp_notify_operator 
				@profile_name = @MailProfileName, 
				@name = @OperatorName, 
				@subject = @Subject, 
				@body = @errorMessage;	
		END;
	END;

	RETURN 0;
GO	