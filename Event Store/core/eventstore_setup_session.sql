/*

	BUG/TODO: 
		if @OverwriteTableIfIExists = N'REPLACE' 
			then... need to DELETE FROM dbo.eventstore_extractions WHERE session_name = <session_name> too...


	vNEXT: 
		- move ALL checks for '@OverwriteXXXIfExists' up to the TOP of the sproc
			and throw errors IF overwrites not allowed (and data already exists). 
				(AND set @deleteXXX = 1 for logic/processing further down in the sproc when/as needed). 
			THAT way we fail EARLY for any potential problems
				where "fail early" means ... we fail BEFORE making partial changes/writes that MIGHT put things in a crummy/semi-inconsistent state.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_setup_session]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_setup_session];
GO

CREATE PROC dbo.[eventstore_setup_session]
	@EventStoreKey							sysname,
	@TargetSessionName						sysname,
	@TargetEventStoreTable					sysname,
	@TraceTarget							sysname = N'event_file',	-- { event_file | ring_buffer }. When 'ring_buffer', use/set @MaxBufferEvents; when event_file, use/set @MaxiFiles + @FileSizeMB + @TraceFilePath.
	@TraceFilePath							sysname = N'D:\Traces', 
	@MaxFiles								int = 10, 
	@FileSizeMB								int = 200, 
	@MaxBufferEvents						int = 1024,
	@StartupState							bit = 1, 
	@StartSessionOnCreation					bit = 1,
	@EtlEnabled								bit = 1,
	@EtlFrequencyMinutes					int = 10,
	@EtlProcedureName						sysname,
	@DataRetentionDays						int = 90,
	@OverwriteSessionIfExists				sysname = NULL,				-- { KEEP | REPLACE}
	@OverwriteTableIfExists					sysname = NULL,				-- { KEEP | REPLACE}
	@OverwriteSettingsIfExist				sysname = NULL,				-- { KEEP | REPLACE}
	@EventStoreTableDDL						nvarchar(MAX),				-- Expect exact/raw table DDL - with any IXes, compression, etc. defined as needed. ONLY 'templating' is {schema} and {table} vs hard-coded values.
	@EventStoreSessionDDL					nvarchar(MAX),				-- Expeect MOSTLY raw Session DDL. Tokens for: {session_name}, ON {server_or_database}, {xe_target}, and {starupt_state}
	@PrintOnly								bit = 0	
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @PrintOnly = ISNULL(@PrintOnly, 0);
	SET @MaxFiles = ISNULL(NULLIF(@MaxFiles, 0), 10);
	SET @FileSizeMB = ISNULL(NULLIF(@FileSizeMB, 0), 200);
	SET @MaxBufferEvents = ISNULL(NULLIF(@MaxBufferEvents, 0), 1024);

	SET @StartupState = ISNULL(@StartupState, 1);
	SET @StartSessionOnCreation = ISNULL(@StartSessionOnCreation, 1);	

	SET @OverwriteSessionIfExists = NULLIF(@OverwriteSessionIfExists, N'');
	SET @OverwriteTableIfExists = NULLIF(@OverwriteTableIfExists, N'');

	IF LOWER(@TraceTarget) NOT IN (N'event_file', N'ring_buffer') BEGIN 
		RAISERROR(N'Allowed values for @TraceTarget are ''event_file'' or ''ring_buffer''.', 16, 1);
		RETURN -110;
	END;

-- TODO: use a helper func to get this - based on underlying OS (windows or linux). 
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	/* Check for EventStore Table (@TargetEventStoreTable) exists + extract DB info/etc.: */
	DECLARE @dropTable nvarchar(MAX) = N'';
	DECLARE @targetDatabase sysname, @targetSchema sysname, @targetObjectName sysname;
	SELECT 
		@targetDatabase = PARSENAME(@TargetEventStoreTable, 3), 
		@targetSchema = ISNULL(PARSENAME(@TargetEventStoreTable, 2), N'dbo'), 
		@targetObjectName = PARSENAME(@TargetEventStoreTable, 1);
	
	IF @targetDatabase IS NULL BEGIN 
		IF @@VERSION NOT LIKE N'%Azure%' BEGIN
			EXEC dbo.[get_executing_dbname] @ExecutingDBName = @targetDatabase OUTPUT;
		  END; 
		ELSE BEGIN 
			SELECT @targetDatabase = DB_NAME();   -- TODO: need to verify that this works... 
		END;

		IF @targetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified for %s and/or unable to determine calling-db-context. Please use dbname.schemaname.objectname qualified names.', 16, 1, @TargetEventStoreTable);
			RETURN -15;
		END;
	END;

	DECLARE @fullyQualifiedTargetTableName nvarchar(MAX) = QUOTENAME(@targetDatabase) + N'.' + QUOTENAME(@targetSchema) + N'.' + QUOTENAME(@targetObjectName) + N'';
	DECLARE @check nvarchar(MAX) = N'SELECT @targetObjectID = OBJECT_ID(''' + @fullyQualifiedTargetTableName + N''');'

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Check for Overwrite Options/Settings (and needs):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @targetObjectID int;
	EXEC [sys].[sp_executesql] 
		@check, 
		N'@targetObjectID int OUTPUT', 
		@targetObjectID = @targetObjectID OUTPUT; 

	DECLARE @keepTable bit = 0;
	IF @targetObjectID IS NOT NULL BEGIN 
		IF @OverwriteTableIfExists IS NULL BEGIN 
			RAISERROR(N'The target table-name specified for @TargetEventStoreTable: [%s] already exists. Either a) manually drop it, b) set @OverwriteTableIfExists = N''KEEP'' to KEEP as-is, or c) set @OverwriteTableIfExists = N''REPLACE'' to DROP and re-CREATE.', 16, 1, @TargetEventStoreTable);
			RETURN -20;
		END;

		IF UPPER(@OverwriteTableIfExists) = N'REPLACE' BEGIN 
			SET @dropTable = N'DROP TABLE [{schema}].[{table}];' + @crlf;

			SET @dropTable = @dropTable + N'DELETE FROM dbo.eventstore_extractions WHERE [session_name] = N''' + @TargetSessionName + N'''' + @crlf;
		END;

		IF UPPER(@OverwriteTableIfExists) = N'KEEP' BEGIN 
			SET @keepTable = 1;
		END;
	END;

	/* Check for XE Session (@TargetSessionName) exists: */
	DECLARE @dropSession nvarchar(MAX) = N'';
	DECLARE @SerializedOutput xml;
	EXEC dbo.[list_xe_sessions] 
		@TargetSessionName = @TargetSessionName, 
		@IncludeDiagnostics = 1,
		@SerializedOutput = @SerializedOutput OUTPUT;

	DECLARE @keepSession bit = 0;
	IF dbo.[is_xml_empty](@SerializedOutput) <> 1 BEGIN 
		
		IF @OverwriteSessionIfExists IS NULL BEGIN 
			RAISERROR('Target XE Session (@TargetSessionName): [%s] already exists. Either a ) manually drop it, b) set @OverwriteSessionIfExists = N''KEEP'' to keep as-is, or c) set @OverwriteSessionIfExists = N''REPLACE'' to DROP and re-CREATE.', 16, 1, @TargetSessionName);
			RETURN -5;
		END; 

		IF UPPER(@OverwriteSessionIfExists) = N'REPLACE' BEGIN 
			SET @dropSession = N'DROP EVENT SESSION [{session_name}] ON {server_or_database};' + @crlf;
		END;

		IF UPPER(@OverwriteSessionIfExists) = N'KEEP' BEGIN 
			SET @keepSession =1;
		END;
	END;

	/* Check to see if dbo.eventstore_settings has row-data for this session already:	*/
	DECLARE @keepSetting bit = 0;
	DECLARE @deleteSettingRow nvarchar(MAX) = N'';
	IF EXISTS (SELECT NULL FROM dbo.[eventstore_settings] WHERE [event_store_key] = @EventStoreKey) BEGIN 
		IF @OverwriteSettingsIfExist IS NULL BEGIN 
			RAISERROR(N'Settings for event_key [%s] already exist in admindb.dbo.eventstore_settings. Either a) manually modify dbo.evenstore_settings, b) set @OverwriteSettingsIfExist = N''KEEP'' to keep as-is, or c) set @OverwriteSettingsIfExist = N''REPLACE''.', 16, 1, @EventStoreKey);
			RETURN -100;
		END;
		
		IF UPPER(@OverwriteSettingsIfExist) = N'REPLACE' BEGIN 
			SET @deleteSettingRow = N'DELETE FROM dbo.eventstore_settings WHERE [event_store_key] = N''' + @EventStoreKey + N'''; ';
		END;

		IF UPPER(@OverwriteSettingsIfExist) = N'KEEP' BEGIN 
			SET @keepSetting = 1;
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process Table DDL
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @tableDDLCommand nvarchar(MAX) = @EventStoreTableDDL;
	SET @tableDDLCommand = N'/*---------------------------------------------------------------------------------------------------------------------------------------------------
-- Create EventStore Table: [{database}].[{schema}].[{table}]
---------------------------------------------------------------------------------------------------------------------------------------------------*/
USE [{database}]; 
{drop}' + @tableDDLCommand;

	SET @tableDDLCommand = REPLACE(@tableDDLCommand, N'{drop}', @dropTable);
	SET @tableDDLCommand = REPLACE(@tableDDLCommand, N'{database}', @targetDatabase);
	SET @tableDDLCommand = REPLACE(@tableDDLCommand, N'{schema}', @targetSchema);
	SET @tableDDLCommand = REPLACE(@tableDDLCommand, N'{table}', @targetObjectName);	

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Process Session DDL
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @serverOrDatabase sysname = N'SERVER';
	IF @@VERSION LIKE N'%Azure%'
		SET @serverOrDatabase = N'DATABASE';

	DECLARE @startup sysname = N'OFF';
	IF @StartupState = 1 SET @startup = N'ON';

	DECLARE @eventFileTemplate nvarchar(MAX) = N'package0.event_file (
		SET FILENAME = N''{event_file_path}\{session_name}.xel'', 
		max_file_size = ({file_size}), 
		MAX_ROLLOVER_FILES = ({max_files})
	)';

	DECLARE @ringBufferTemplate nvarchar(MAX) = N'package0.ring_buffer (
		SET 
			MAX_MEMORY = 2048,  -- recommended by MS: https://docs.microsoft.com/en-us/sql/t-sql/statements/create-event-session-transact-sql?view=sql-server-ver15
			MAX_EVENTS_LIMIT = ' + CAST(@MaxBufferEvents AS sysname) + N'
	)';

	DECLARE @sessionDDLCommand nvarchar(MAX) = @EventStoreSessionDDL;
	SET @sessionDDLCommand = N'/*---------------------------------------------------------------------------------------------------------------------------------------------------
-- Create EventStore Session: [{session_name}]
---------------------------------------------------------------------------------------------------------------------------------------------------*/
USE [{database}]; 
{drop}' + @sessionDDLCommand;

	IF @StartSessionOnCreation = 1 BEGIN 
		SET @sessionDDLCommand = @sessionDDLCommand + @crlf + @crlf + N'ALTER EVENT SESSION [{session_name}] ON {server_or_database} STATE = START;'
	END;

	IF LOWER(@TraceTarget) = N'ring_buffer' 
		SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{xe_target}', @ringBufferTemplate);
	ELSE 
		SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{xe_target}', @eventFileTemplate);

	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{drop}', @dropSession);
	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{database}', @targetDatabase);

	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{session_name}', @TargetSessionName);
	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{server_or_database}', @serverOrDatabase);
	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{event_file_path}', dbo.[normalize_file_path](@TraceFilePath));
	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{file_size}', @FileSizeMB);
	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{max_files}', @MaxFiles);
	SET @sessionDDLCommand = REPLACE(@sessionDDLCommand, N'{startup_state}', @startup);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Setup Jobs/Processing details within eventstore_settings:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @settingDMLCommand nvarchar(MAX) = N'/*---------------------------------------------------------------------------------------------------------------------------------------------------
-- Settings: 
---------------------------------------------------------------------------------------------------------------------------------------------------*/
USE [{database}];
';

	IF @keepSetting = 0 
		SET @settingDMLCommand = @settingDMLCommand + @deleteSettingRow + @crlf;

	DECLARE @collectionEnabled bit = COALESCE(NULLIF(@StartupState, 0), NULLIF(@StartSessionOnCreation, 0), 0);

	SET @settingDMLCommand = @settingDMLCommand + N'INSERT INTO [dbo].[eventstore_settings] (
	[event_store_key],
	[session_name],
	[etl_proc_name],
	[target_table],
	[collection_enabled],
	[etl_enabled],
	[etl_frequency_minutes],
	[retention_days]
)
VALUES (
	N''' + @EventStoreKey + N''',
	N''' + @TargetSessionName + N''',
	N''' + @EtlProcedureName + N''',
	N''' + @TargetEventStoreTable + N''',
	' + CAST(@collectionEnabled AS sysname) + N',
	' + CAST(@EtlEnabled AS sysname) + N',
	' + CAST(@EtlFrequencyMinutes AS sysname) + N',
	' + CAST(@DataRetentionDays AS sysname) + N'
); ';

	SET @settingDMLCommand = REPLACE(@settingDMLCommand, N'{database}', @targetDatabase);

	-- create a job if/as needed... 

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing / Output
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @finalSQL nvarchar(MAX) = N'';

	/* Always create the table first ... (just in case there's a job out there trying to push data from an EXISTING XE Session into a table... */
	IF @keepTable = 1 
		SET @finalSQL = @finalSQL + N'-- @OverwriteTableIfExists set to ''KEEP'' - Keeping Table ' + @TargetEventStoreTable + N' as-is.';
	ELSE 
		SET @finalSQL = @finalSQL + @tableDDLCommand; 

	IF @PrintOnly = 1 
		SET @finalSQL = @finalSQL + @crlf + N'GO'

	SET @finalSQL = @finalSQL + @crlf + @crlf;

	IF @keepSession = 1 
		SET @finalSQL = @finalSQL + N'-- @OverwriteSessionIfExists set to ''KEEP'' - Keeping XE Session [' + @TargetSessionName + N'] as-is.' ; 
	ELSE 
		SET @finalSQL = @finalSQL + @sessionDDLCommand; 

	IF @PrintOnly = 1 
		SET @finalSQL = @finalSQL + @crlf + N'GO';

	SET @finalSQL = @finalSQL + @crlf + @crlf;

	IF @keepSetting = 1  
		SET @finalSQL = @finalSQL + N'-- @OverwriteSettingsIfExist set to ''KEEP'' - Keeping dbo.evenstore_settings for [' + @EventStoreKey + N'] as-is.';
	ELSE 
		SET @finalSQL = @finalSQL + @settingDMLCommand;

	IF @PrintOnly = 1 
		SET @finalSQL = @finalSQL + @crlf + N'GO';

	SET @finalSQL = @finalSQL + @crlf;

	DECLARE @errorMessage nvarchar(MAX), @errorLine int;

	IF @PrintOnly = 1 BEGIN 
		EXEC dbo.[print_long_string] @finalSQL;
	  END;
	ELSE BEGIN 
		BEGIN TRY 

			EXEC sys.[sp_executesql]
				@finalSQL; 

		END TRY 
		BEGIN CATCH
			SELECT @errorLine = ERROR_LINE(), @errorMessage = N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();

			RAISERROR(@errorMessage, 16, 1);
			EXEC dbo.[extract_dynamic_code_lines] @finalSQL, @errorLine, 6;
			RETURN -100;

		END CATCH;
	END;

	RETURN 0;
GO