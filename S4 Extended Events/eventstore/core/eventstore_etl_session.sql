/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_session]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_session];
GO

CREATE PROC dbo.[eventstore_etl_session]
	@SessionName					sysname, 
	@EventStoreTarget				sysname,
	@TranslationDML					nvarchar(MAX),
	@InitializeDaysBack				int						= 10
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @InitializeDaysBack = ISNULL(@InitializeDaysBack, 10);	

	/* Verify that the XE Session (SessionName) exists: */
	DECLARE @SerializedOutput xml;
	EXEC dbo.[list_xe_sessions] 
		@TargetSessionName = @SessionName, 
		@IncludeDiagnostics = 1,
		@SerializedOutput = @SerializedOutput OUTPUT;

	IF dbo.[is_xml_empty](@SerializedOutput) = 1 BEGIN 
		RAISERROR(N'Target @SessionName: [%s] not found. Please verify @SessionName input.', 16, 1, @SessionName); 
		RETURN -10;
	END;

	/* Verify that the target table (XEStoreTarget) exists: */ 
	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
	SELECT 
		@targetDatabase = PARSENAME(@EventStoreTarget, 3), 
		@targetSchema = ISNULL(PARSENAME(@EventStoreTarget, 2), N'dbo'), 
		@targetObjectName = PARSENAME(@EventStoreTarget, 1);
	
	IF @targetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		
		IF @targetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for @EventStoreTarget and/or S4 was unable to determine calling-db-context. Please use [db_name].[schema_name].[object_name] qualified names.', 16, 1);
			RETURN -5;
		END;
	END;

	DECLARE @fullyQualifiedTargetTableName nvarchar(MAX) = QUOTENAME(@targetDatabase) + N'.' + QUOTENAME(@targetSchema) + N'.' + QUOTENAME(@targetObjectName) + N'';
	DECLARE @check nvarchar(MAX) = N'SELECT @targetObjectID = OBJECT_ID(''' + @fullyQualifiedTargetTableName + N''');';

	DECLARE @targetObjectID int;
	EXEC [sys].[sp_executesql] 
		@check, 
		N'@targetObjectID int OUTPUT', 
		@targetObjectID = @targetObjectID OUTPUT; 

	IF @targetObjectID IS NULL BEGIN 
		RAISERROR('The target table-name specified by @EventStoreTarget: [%s] could not be located. Please create it using admindb.dbo.eventstore_init_%s or create a new table following admindb documentation.', 16, 1, @EventStoreTarget, @SessionName);
		RETURN -7;
	END;

	/* Otherwise, init extraction, grab rows, and ... if all passes, finalize extraction (i.e., LSET/CET management). */
	DECLARE @Output xml, @extractionID int,	@extractionAttributes nvarchar(300);
	EXEC dbo.[eventstore_extract_session_xml]
		@SessionName = @SessionName,
		@Output = @Output OUTPUT,
		@ExtractionID = @extractionID OUTPUT,
		@ExtractionAttributes = @extractionAttributes OUTPUT, 
		@InitializationDaysBack = @InitializeDaysBack;

	DECLARE @sql nvarchar(MAX) = @TranslationDML;

	SET @sql = REPLACE(@sql, N'{targetDatabase}', @targetDatabase);
	SET @sql = REPLACE(@sql, N'{targetSchema}', @targetSchema);
	SET @sql = REPLACE(@sql, N'{targetTable}', @targetObjectName);

-- TODO: use a helper func to get this - based on underlying OS (windows or linux). 
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @rowCount int;
	DECLARE @errorMessage nvarchar(MAX), @errorLine int;
	BEGIN TRY 
		BEGIN TRAN;

			EXEC sys.sp_executesql 
				@sql,
				N'@EventData xml', 
				@EventData = @Output;

			SELECT @rowCount = @@ROWCOUNT;

			EXEC dbo.[eventstore_finalize_extraction] 
				@SessionName = @SessionName, 
				@ExtractionId = @extractionID, 
				@RowCount = @rowCount,
				@Attributes = @extractionAttributes;
		
		COMMIT;
	END TRY
	BEGIN CATCH 
		SELECT 
			@errorLine = ERROR_LINE(), 
			@errorMessage = N'Exception processing ETL for Session: [%s].' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();

		IF @@TRANCOUNT > 0 
			ROLLBACK;

		RAISERROR(@errorMessage, 16, 1, @SessionName);
		EXEC dbo.[extract_dynamic_code_lines] @sql, @errorLine, 6;

		UPDATE dbo.[eventstore_extractions] 
		SET
			[error] = @errorMessage
		WHERE 
			[extraction_id] = @extractionID 
			AND [session_name] = @SessionName;

		RETURN -100;
	END CATCH;

	RETURN 0;
GO