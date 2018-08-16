
/*

	exec dbo.verify_audit_configuration
		@Target = N'',   -- NULL | 'SERVER' | 'db_name'  - if NULL/SERVER... then assume server in scope... 


	Sample Execution/Example:
		EXEC verify_server_audit_configuration 'Server Audit2', -34135575811, @printOnly = 1;

*/

IF OBJECT_ID('dbo.verify_server_audit_configuration','P') IS NOT NULL
	DROP PROC dbo.verify_server_audit_configuration;
GO

CREATE PROC dbo.verify_server_audit_configuration 
	@AuditName				sysname, 
	@OptionalAuditHash		bigint = NULL, 
	@EmailSubjectPrefix		nvarchar(50)		= N'[Audit Configuration] ',
	@MailProfileName		sysname				= N'General',	
	@OperatorName			sysname				= N'Alerts',	
	@PrintOnly				bit					= 0	
AS
	SET NOCOUNT ON; 

	DECLARE @errorMessage nvarchar(MAX);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		error nvarchar(MAX) NOT NULL
	);

	-- make sure audit exists and is enabled. 
	DECLARE @auditID int; 
	DECLARE @isEnabled bit;

	SELECT @auditID = audit_id, @isEnabled = is_state_enabled FROM sys.[server_audits] WHERE [name] = @AuditName;
	IF @auditID IS NULL BEGIN 
		SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] does not currently exist on [' + @@SERVERNAME + N'].';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
		GOTO ALERTS;
	END;

	IF @isEnabled = 0 BEGIN 
		SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] on [' + @@SERVERNAME + N'] is currently NOT enabled.';
		INSERT INTO @errors([error]) VALUES (@errorMessage);
	END;

	-- if there's a checksum, verify that they match: 
	IF @OptionalAuditHash IS NOT NULL BEGIN
		DECLARE @auditSignature bigint = 0;

		EXEC admindb.dbo.generate_server_audit_signature @AuditName, @AuditSignature = @auditSignature OUTPUT;

		IF @auditSignature <> 0 AND (@OptionalAuditHash <> @auditSignature) BEGIN
			SELECT @errorMessage = N'WARNING: Server Audit [' + @AuditName + N'] on [' + @@SERVERNAME + N'] does NOT match signature defined via call to admindb.dbo.verify_server_audit_configuration. (If you recently made an audit/audit specification change, review audit change logs then regenerate @OptionalAuditHash using admindbo.generate_server_audit_hash.)';
			INSERT INTO @errors([error]) VALUES (@errorMessage);
		END
	END;

ALERTS:
	IF EXISTS (SELECT NULL FROM	@errors) BEGIN 
		DECLARE @subject nvarchar(MAX) = @EmailSubjectPrefix + N' - Synchronization Problems Detected';
		DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
		DECLARE @tab nchar(1) = NCHAR(9);

		SET @errorMessage = N'The following errors were detected: ' + @crlf;

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

