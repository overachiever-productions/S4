
/*


	SAMPLE Execution: 
		EXEC [dbo].[generate_server_audit_signature] 'Server Audit';

		or... 
		DECLARE @sig bigint = 0; 
		EXEC dbo.generate_server_audit_signature 'Server Audit', @AuditSignature = @sig OUTPUT;
		SELECT @sig;

*/





-- decent enough idea... only... .. hmmm (was going to say, can't use this inside of server_synchronization_checks - as I can't... because i'd need RPC perms on the PARTNER. 
--			but... hmmm. yeah... still sort of makes sense with being able to set up a hash for a spec/audit 'on the fly' so that it can be used to 'lock' or 'bind' a job that checks up?
USE [admindb];
GO

IF OBJECT_ID('dbo.generate_server_audit_signature','P') IS NOT NULL
	DROP PROC dbo.generate_server_audit_signature;
GO

CREATE PROC dbo.generate_server_audit_signature 
	@AuditName						sysname, 
	@IncludeAuditGUIDInHash			bit	= 0, 
	@AuditSignature					bigint = NULL OUTPUT
AS
	SET NOCOUNT ON; 
	DECLARE @errorMessage nvarchar(MAX);

	DECLARE @hashes table ( 
		[hash] bigint NOT NULL
	);

	DECLARE @hash int = 0;
	DECLARE @auditID int; 
	DECLARE @auditGUID uniqueidentifier;

	SELECT @auditID = audit_id, @auditGUID = [audit_guid] FROM sys.[server_audits] WHERE [name] = @AuditName;
	IF @auditID IS NULL BEGIN 
		SET @errorMessage = N'Specified Server Audit Name: [' + @AuditName + N'] does NOT exist. Please check your input and try again.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END;

	IF @IncludeAuditGUIDInHash = 1
		SELECT @hash = CHECKSUM([name], [audit_guid], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;
	ELSE 
		SELECT @hash = CHECKSUM([name], [type], [on_failure], [is_state_enabled], [queue_delay], [predicate]) FROM sys.[server_audits] WHERE [name] = @AuditName;

	INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));

	-- hash storage details (if file log storage is used):
	IF EXISTS (SELECT NULL FROM sys.[server_audits] WHERE [name] = @AuditName AND [type] = 'FL') BEGIN
		SELECT @hash = CHECKSUM(max_file_size, max_files, reserve_disk_space, log_file_path) FROM sys.[server_file_audits] WHERE [audit_id] = @auditID;  -- note, log_file_name will always be different because of the GUIDs. 
		INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));
	END


	SET @hash = 0;
	SELECT 
		@hash = @hash + CHECKSUM([name], [is_state_enabled])
	FROM 
		sys.[server_audit_specifications] 
	WHERE 
		[audit_guid] = @auditGuid;

	INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));

	DECLARE details CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[sasd].[audit_action_id], 
		[sasd].[class], 
		[sasd].[major_id],
		[sasd].[minor_id], 
		[sasd].[audited_principal_id], 
		[sasd].[audited_result], 
		[sasd].[is_group]
	FROM
		sys.[server_audit_specification_details] sasd 
		INNER JOIN sys.[server_audit_specifications] sas ON sasd.[server_specification_id] = sas.[server_specification_id]
	WHERE 
		sas.[audit_guid] = @auditGUID
	ORDER BY 
		[sasd].[audit_action_id];

	DECLARE @auditActionID char(4), @class tinyint, @majorId int, @minorInt int, @principal int, @result nvarchar(60), @isGroup bit; 

	OPEN [details]; 
	FETCH NEXT FROM [details] INTO @auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup;

	WHILE @@FETCH_STATUS = 0 BEGIN 

		SELECT @hash = CHECKSUM(@auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup)
		INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));

		FETCH NEXT FROM [details] INTO @auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup;
	END;

	CLOSE [details];
	DEALLOCATE [details];

	IF @AuditSignature IS NULL
		SELECT SUM([hash]) [audit_signature] FROM @hashes; 
	ELSE	
		SELECT @AuditSignature = SUM(hash) FROM @hashes;

	RETURN 0;
GO




