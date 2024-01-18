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

	DECLARE @errorID int, @errorMessage nvarchar(MAX), @errorLine int;
	BEGIN TRY 
		BEGIN TRAN;

-- TODO: maybe look at validating the statement via: https://overachieverllc.atlassian.net/browse/S4-564 (assuming I can ever get a viable option for that to work that doesn't do deferred name resolution).

			EXEC sys.sp_executesql 
				@sql,
				N'@EventData xml', 
				@EventData = @Output;

			EXEC dbo.[eventstore_finalize_extraction] 
				@SessionName = @SessionName, 
				@ExtractionId = @extractionID, 
				@Attributes = @extractionAttributes;
		
		COMMIT;
	END TRY
	BEGIN CATCH 
		SELECT @errorID = ERROR_NUMBER(), @errorLine = ERROR_LINE(), @errorMessage = ERROR_MESSAGE();
		RAISERROR(N'Exception processing ETL for Session: [%s]. Error Number %i, Line %i: %s', 16, 1, @SessionName, @errorID, @errorLine, @errorMessage);

		IF @@TRANCOUNT > 0 
			ROLLBACK;

		RETURN -100;
	END CATCH;

	RETURN 0;
GO