
/*


	EXEC dbo.verify_audit_configuration
		@AuditName = N'Server Audit', 
		@OptionalAuditSignature = 1744809880, -- 1744809880
		@ExpectedEnabledState = N'ON', 
		@PrintOnly = 1;


*/

USE [admindb];
GO


IF OBJECT_ID('dbo.verify_audit_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_audit_configuration;
GO

CREATE PROC dbo.verify_audit_configuration 
	@AuditName							sysname, 
	@OptionalAuditSignature				bigint				= NULL, 
	@IncludeAuditIdInSignature			bit					= 1,
	@ExpectedEnabledState				sysname				= N'ON',   -- ON | OFF
	@EmailSubjectPrefix					nvarchar(50)		= N'[Audit Configuration] ',
	@MailProfileName					sysname				= N'General',	
	@OperatorName						sysname				= N'Alerts',	
	@PrintOnly							bit					= 0	
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

	-- make sure audit exists and and verify is_enabled status:
	DECLARE @auditID int; 
	DECLARE @isEnabled bit;

	SELECT 
		@auditID = audit_id, 
		@isEnabled = is_state_enabled 
	FROM 
		sys.[server_audits] 
	WHERE 
		[name] = @AuditName;
	
	IF @auditID IS NULL BEGIN 
		SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] does not currently exist on [' + @@SERVERNAME + N'].';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
		GOTO ALERTS;
	END;

	-- check on enabled state: 
	IF UPPER(@ExpectedEnabledState) = N'ON' BEGIN 
		IF @isEnabled <> 1 BEGIN
			SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] expected is_enabled state was: ''ON'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	  END; 
	ELSE BEGIN 
		IF @isEnabled <> 0 BEGIN 
			SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] expected is_enabled state was: ''OFF'', but current value was ' + CAST(@isEnabled AS sysname) + N'.';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END;
	END; 

	-- If we have a checksum, verify that as well: 
	IF @OptionalAuditSignature IS NOT NULL BEGIN 
		DECLARE @currentSignature bigint = 0;
		DECLARE @returnValue int; 

		EXEC @returnValue = dbo.generate_audit_signature
			@AuditName = @AuditName, 
			@IncludeGuidInHash = @IncludeAuditIdInSignature,
			@AuditSignature = @currentSignature OUTPUT;

		IF @returnValue <> 0 BEGIN 
				SELECT @errorMessage = N'ERROR: Problem generating audit signature for [' + @AuditName + N'] on ' + @@SERVERNAME + N'.';
				INSERT INTO @errors([error]) VALUES (@errorMessage);			
		  END;
		ELSE BEGIN
			IF @OptionalAuditSignature <> @currentSignature BEGIN
				SELECT @errorMessage = N'WARNING: Expected signature for Audit [' + @AuditName + N'] (with a value of ' + CAST(@OptionalAuditSignature AS sysname) + N') did NOT match currently generated signature (with value of ' + CAST(@currentSignature AS sysname) + N').';
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