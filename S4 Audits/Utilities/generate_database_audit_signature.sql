
/*

	Signature: 

			EXEC dbo.generate_database_audit_signature 
				@Target	= N'msdb',
				@AuditName = N'Jobs Monitoring (msdb)', 
				@IncludeAuditGUIDInHash	= 1;		

		OR

			DECLARE @output bigint = 0;  -- Note, value must be NON-NULL... 
			EXEC dbo.generate_database_audit_signature 
				@Target	= N'msdb',
				@AuditName = N'Jobs Monitoring (msdb)', 
				@IncludeAuditGUIDInHash	= 1, 
				@AuditSignature	= @output OUTPUT;

			SELECT @output;




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.generate_database_audit_signature','P') IS NOT NULL
	DROP PROC dbo.generate_database_audit_signature;
GO

CREATE PROC dbo.generate_database_audit_signature 
	@Target							sysname,
	@AuditName						sysname, 
	@IncludeAuditGUIDInHash			bit	= 0, 
	@AuditSignature					bigint = NULL OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @errorMessage nvarchar(MAX);

	-- Make sure the target exists:
	DECLARE @targetOutput nvarchar(max);

	EXEC dbo.load_database_names
		@Input = @Target,
		@Mode = N'LIST_ACTIVE',
		@Output = @targetOutput OUTPUT;

	IF LEN(ISNULL(@targetOutput,'')) < 1 BEGIN
		SET @errorMessage = N'Specified @Target [' + @Target + N'] does not exist. Please check your input and try again.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -1;
	END;

	DECLARE @specificationID int; 
	DECLARE @auditGUID uniqueidentifier;
	DECLARE @isEnabled bit;
	DECLARE @createDate datetime;
	DECLARE @modifyDate datetime;

	DECLARE @sql nvarchar(max) = N'
	SELECT 
		@specificationID = [database_specification_id], 
		@auditGUID = [audit_guid], 
		@createDate = [create_date],
		@modifyDate = [modify_date],
		@isEnabled = [is_state_enabled] 
	FROM 
		[{0}].sys.database_audit_specifications 
	WHERE 
		[name] = @AuditName;';

	SET @sql = REPLACE(@sql, N'{0}', @Target);

	EXEC sys.sp_executesql 
		@sql, 
		N'@AuditName sysname, @specificationID int OUTPUT, @auditGuid uniqueidentifier OUTPUT, @isEnabled bit OUTPUT, @createDate datetime OUTPUT, @modifyDate datetime OUTPUT', 
		@AuditName = @AuditName, @specificationID = @specificationID OUTPUT, @auditGUID = @auditGUID OUTPUT, @isEnabled = @isEnabled OUTPUT, @createDate = @createDate OUTPUT, @modifyDate = @modifyDate OUTPUT;

	IF @specificationID IS NULL BEGIN
		SET @errorMessage = N'Specified Database Audit Specification Name: [' + @AuditName + N'] does NOT exist. Please check your input and try again.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -2;		
	END;

	DECLARE @hash int = 0;
	
	IF @IncludeAuditGUIDInHash = 1 
		SELECT @hash = CHECKSUM(@AuditName, @auditGUID, @specificationID, @createDate, @modifyDate, @isEnabled);
	ELSE	
		SELECT @hash = CHECKSUM(@AuditName, @specificationID, @createDate, @modifyDate, @isEnabled);

	DECLARE @hashes table ( 
			[hash] bigint NOT NULL
		);
	INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));
	
	SET @hash = 0;

	--SELECT 
	--	@hash = @hash + CHECKSUM([name], [is_state_enabled])
	--FROM 
	--	sys.[server_audit_specifications] 
	--WHERE 
	--	[audit_guid] = @auditGuid;

	--INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));

	DECLARE details CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[audit_action_id], 
		[class], 
		[major_id],
		[minor_id], 
		[audited_principal_id], 
		[audited_result], 
		[is_group]
	FROM
		sys.[database_audit_specification_details]  
	WHERE 
		 [database_specification_id] = @specificationID
	ORDER BY 
		[major_id];

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
		SELECT @AuditSignature = SUM([hash]) FROM @hashes;

	RETURN 0;
GO
