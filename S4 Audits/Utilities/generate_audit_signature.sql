/*
    NOTE: 
        - This sproc adheres to the PROJECT/REPLY usage convention.


	TODO:
		- Assert/Check dependencies prior to execution of core logic.
		- Predicates weren't available with 2008R2 instances ... nor was it possible to add a max_files detail to the audit's definition (well, see it via dmv). 

	vNEXT: 
		- POSSIBLY look at an @IncludePredicates parameter and when it's 0 (vs default of 1)... exclude [predicate] from the signature... 

	SAMPLE EXECUTION:

				EXEC dbo.generate_audit_signature 
					@AuditName = N'Server Audit';

		OR

				DECLARE @signature bigint; 
				EXEC dbo.generate_audit_signature
					@AuditName = N'Server Audit', 
					@AuditSignature = @signature OUTPUT; 

				SELECT @signature;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.generate_audit_signature','P') IS NOT NULL
	DROP PROC dbo.generate_audit_signature;
GO

--##CONDITIONAL_SUPPORT(> 10.5)

CREATE PROC dbo.generate_audit_signature 
	@AuditName					sysname, 
	@IncludeGuidInHash			bit			= 1, 
	@AuditSignature				bigint		= -1 OUTPUT
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

	DECLARE @hashes table ( 
			[hash] bigint NOT NULL
	);

	IF @IncludeGuidInHash = 1
		SELECT @hash = CHECKSUM([name], [audit_guid], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;
	ELSE 
		SELECT @hash = CHECKSUM([name], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;

	INSERT INTO @hashes ([hash])
	VALUES (@hash);

	-- hash storage details (if file log storage is used):
	IF EXISTS (SELECT NULL FROM sys.[server_audits] WHERE [name] = @AuditName AND [type] = 'FL') BEGIN
		SELECT 
			@hash = CHECKSUM(max_file_size, max_files, reserve_disk_space, log_file_path) 
		FROM 
			sys.[server_file_audits] 
		WHERE 
			[audit_id] = @auditID;  -- note, log_file_name will always be different because of the GUIDs. 

		INSERT INTO @hashes ([hash])
		VALUES (@hash);
	END

	IF @AuditSignature = -1
		SELECT SUM([hash]) [audit_signature] FROM @hashes; 
	ELSE	
		SELECT @AuditSignature = SUM(hash) FROM @hashes;

	RETURN 0;
GO