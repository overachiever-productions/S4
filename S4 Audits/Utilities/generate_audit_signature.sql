
/*


	SAMPLE EXECUTION

				EXEC dbo.generate_audit_signature 
					@AuditName = N'Server Audit';

		OR

				DECLARE @signature int = 0;	-- NOTE: value MUST be set to a non-NULL value. 
				EXEC dbo.generate_audit_signature
					@AuditName = N'Server Audit', 
					@AuditSignature = @signature OUTPUT; 

				SELECT @signature;


*/


IF OBJECT_ID('dbo.generate_audit_signature','P') IS NOT NULL
	DROP PROC dbo.generate_audit_signature;
GO

CREATE PROC dbo.generate_audit_signature 
	@AuditName					sysname, 
	@IncludeGuidInHash			bit			= 1, 
	@AuditSignature				bigint		= NULL OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @hash int = 0;
	DECLARE @auditID int; 

	SELECT 
		@auditID = audit_id
	FROM 
		sys.[server_audits] 
	WHERE 
		[name] = @AuditName;

	IF @auditID IS NULL BEGIN 
		SET @errorMessage = N'Specified Server Audit Name: [' + @AuditName + N'] does NOT exist. Please check your input and try again.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END;

	IF @IncludeGuidInHash = 1
		SELECT @hash = CHECKSUM([name], [audit_guid], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;
	ELSE 
		SELECT @hash = CHECKSUM([name], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;

	-- hash storage details (if file log storage is used):
	IF EXISTS (SELECT NULL FROM sys.[server_audits] WHERE [name] = @AuditName AND [type] = 'FL') BEGIN
		SELECT 
			@hash = CHECKSUM(max_file_size, max_files, reserve_disk_space, log_file_path) 
		FROM 
			sys.[server_file_audits] 
		WHERE 
			[audit_id] = @auditID;  -- note, log_file_name will always be different because of the GUIDs. 
	END

	IF @AuditSignature IS NULL
		SELECT @hash [audit_signature]; 
	ELSE	
		SELECT @AuditSignature = @hash;

	RETURN 0;
GO