
/*
	TODO:
		- Assert/Check dependencies prior to execution of core logic.


	NOTE:
		- Can be used for server-level OR datbase-level specifications. 
			To target server-level specifications, set @Target = NULL or @Target = N'[SYSTEM]'. 
			Otherwise, @Target is the name of the database to check for the @SpecificationName. 


	EXECUTION EXAMPLES / SIGNATURES:

				-- db-level specification (as target)... 
				EXEC dbo.generate_specification_signature 
					@Target						= N'msdb',			
					@SpecificationName			= N'Jobs Monitoring (msdb)',
					@IncludeAuditGUIDInHash		= 1;
				GO

				-- server-level specification: 
				EXEC dbo.generate_specification_signature 
					@SpecificationName			= N'Server Audit Specification',
					@IncludeAuditGUIDInHash		= 1;
				GO

		OR 
				
				-- db-level specification (as target)... 
				DECLARE @signature bigint = 0;  -- must be set to a non-NULL value: 
				EXEC dbo.generate_specification_signature 
					@Target						= N'msdb',			
					@SpecificationName			= N'Jobs Monitoring (msdb)',
					@IncludeAuditGUIDInHash		= 1, 
					@SpecificationSignature		= @signature OUTPUT;

				SELECT @signature [signature];
				GO

				-- server-level specification: 
				DECLARE @signature bigint = 0;  -- must be set to a non-NULL value: 
				EXEC dbo.generate_specification_signature 
					@SpecificationName			= N'Server Audit Specification',
					@IncludeAuditGUIDInHash		= 1, 
					@SpecificationSignature		= @signature OUTPUT;

				SELECT @signature [signature];
				GO


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.generate_specification_signature','P') IS NOT NULL
	DROP PROC dbo.generate_specification_signature;
GO

CREATE PROC dbo.generate_specification_signature 
	@Target										sysname				= N'SERVER',			-- SERVER | 'db_name' - SERVER is default and represents a server-level specification, whereas a db_name will specify that this is a database specification).
	@SpecificationName							sysname,
	@IncludeParentAuditIdInSignature			bit					= 1,
	@SpecificationSignature						bigint				= NULL OUTPUT
AS
	SET NOCOUNT ON; 
	
	-- {copyright}
	
	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @specificationScope sysname;

	 IF NULLIF(@Target, N'') IS NULL OR @Target = N'SERVER'
		SET @specificationScope = N'SERVER';
	ELSE 
		SET @specificationScope = N'DATABASE';

	CREATE TABLE #specificationDetails (
		audit_action_id varchar(10) NOT NULL, 
		class int NOT NULL, 
		major_id int NOT NULL, 
		minor_id int NOT NULL, 
		audited_principal_id int NOT NULL, 
		audited_result nvarchar(60) NOT NULL, 
		is_group bit NOT NULL 
	);

	DECLARE @hash int = 0;
	DECLARE @hashes table ( 
			[hash] bigint NOT NULL
	);

	DECLARE @specificationID int; 
	DECLARE @auditGUID uniqueidentifier;
	DECLARE @createDate datetime;
	DECLARE @modifyDate datetime;
	DECLARE @isEnabled bit;

	DECLARE @sql nvarchar(max) = N'
		SELECT 
			@specificationID = [{1}_specification_id], 
			@auditGUID = [audit_guid], 
			@createDate = [create_date],
			@modifyDate = [modify_date],
			@isEnabled = [is_state_enabled] 
		FROM 
			[{0}].sys.[{1}_audit_specifications] 
		WHERE 
			[name] = @SpecificationName;';

	DECLARE @specificationSql nvarchar(MAX) = N'
		SELECT 
			[audit_action_id], 
			[class], 
			[major_id],
			[minor_id], 
			[audited_principal_id], 
			[audited_result], 
			[is_group]
		FROM
			[{0}].sys.[{1}_audit_specification_details]  
		WHERE 
			 [{1}_specification_id] = @specificationID
		ORDER BY 
			[major_id];'; 

	IF @specificationScope = N'SERVER' BEGIN

		SET @sql = REPLACE(@sql, N'{0}', N'master');
		SET @sql = REPLACE(@sql, N'{1}', N'server');
		SET @specificationSql = REPLACE(@specificationSql, N'{0}', N'master');
		SET @specificationSql = REPLACE(@specificationSql, N'{1}', N'server');		

	  END
	ELSE BEGIN 

		-- Make sure the target database exists:
		DECLARE @targetOutput nvarchar(max);

		EXEC dbo.list_databases
			@Target = @Target,
			@ExcludeDev = 1,
			@Output = @targetOutput OUTPUT;

		IF LEN(ISNULL(@targetOutput,'')) < 1 BEGIN
			SET @errorMessage = N'Specified @Target database [' + @Target + N'] does not exist. Please check your input and try again.';
			RAISERROR(@errorMessage, 16, 1);
			RETURN -1;
		END;

		SET @sql = REPLACE(@sql, N'{0}', @Target);
		SET @sql = REPLACE(@sql, N'{1}', N'database');
		SET @specificationSql = REPLACE(@specificationSql, N'{0}', @Target);
		SET @specificationSql = REPLACE(@specificationSql, N'{1}', N'database');
	END; 

	EXEC sys.sp_executesql 
		@stmt = @sql, 
		@params = N'@SpecificationName sysname, @specificationID int OUTPUT, @auditGuid uniqueidentifier OUTPUT, @isEnabled bit OUTPUT, @createDate datetime OUTPUT, @modifyDate datetime OUTPUT', 
		@SpecificationName = @SpecificationName, @specificationID = @specificationID OUTPUT, @auditGUID = @auditGUID OUTPUT, @isEnabled = @isEnabled OUTPUT, @createDate = @createDate OUTPUT, @modifyDate = @modifyDate OUTPUT;

	IF @specificationID IS NULL BEGIN
		SET @errorMessage = N'Specified '+ CASE WHEN @specificationScope = N'SERVER' THEN N'Server' ELSE N'Database' END + N' Audit Specification Name: [' + @SpecificationName + N'] does NOT exist. Please check your input and try again.';
		RAISERROR(@errorMessage, 16, 1);
		RETURN -2;		
	END;		

	-- generate/store a hash of the specification details:
	IF @IncludeParentAuditIdInSignature = 1 
		SELECT @hash = CHECKSUM(@SpecificationName, @auditGUID, @specificationID, @createDate, @modifyDate, @isEnabled);
	ELSE	
		SELECT @hash = CHECKSUM(@SpecificationName, @specificationID, @createDate, @modifyDate, @isEnabled);

	INSERT INTO @hashes ([hash]) VALUES (CAST(@hash AS bigint));

	INSERT INTO [#specificationDetails] ([audit_action_id], [class], [major_id], [minor_id], [audited_principal_id], [audited_result], [is_group])
	EXEC sys.[sp_executesql] 
		@stmt = @specificationSql, 
		@params = N'@specificationID int', 
		@specificationID = @specificationID;

	DECLARE @auditActionID char(4), @class tinyint, @majorId int, @minorInt int, @principal int, @result nvarchar(60), @isGroup bit; 
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
		[#specificationDetails]
	ORDER BY 
		[audit_action_id];

	OPEN [details]; 
	FETCH NEXT FROM [details] INTO @auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup;

	WHILE @@FETCH_STATUS = 0 BEGIN 

		SELECT @hash = CHECKSUM(@auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup)
		
		INSERT INTO @hashes ([hash]) 
		VALUES (CAST(@hash AS bigint));

		FETCH NEXT FROM [details] INTO @auditActionID, @class, @majorId, @minorInt, @principal, @result, @isGroup;
	END;	

	CLOSE [details];
	DEALLOCATE [details];

	IF @SpecificationSignature IS NULL
		SELECT SUM([hash]) [audit_signature] FROM @hashes; 
	ELSE	
		SELECT @SpecificationSignature = SUM(hash) FROM @hashes;

	RETURN 0;
GO
