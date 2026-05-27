/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[initialize_migration]','P') IS NOT NULL
	DROP PROC dbo.[initialize_migration];
GO

CREATE PROC dbo.[initialize_migration]
	@Databases						nvarchar(MAX),							-- Must be EXPLICITLY defined. 
	@Priorities						nvarchar(MAX)		= NULL,
	@FinalBackupType				sysname				= N'LOG',			-- { FULL | DIFF | LOG }
	@MigrationType					sysname				= N'OFFLINE',		-- { OFFLINE | ONLINE }  -- Offline = SINGLE_USER + FINAL BACKUP + OFFLINE, ONLINE = MARKER for final backup and NO offline.
	@IncludeSanityMarker			bit					= 1, 
	@SingleUserRollbackSeconds		int					= 5,
	@BackupDirectory				nvarchar(2000)		= N'{DEFAULT}', 
	@CopyToBackupDirectory			nvarchar(2000)		= NULL,
	@OffSiteBackupPath				nvarchar(2000)		= NULL,
	@BackupRetention				sysname				= N'30 days',		
	@CopyToRetention				sysname				= N'30 days', 
	@OffSiteRetention				sysname				= N'30 days',
	@EncryptionCertName				sysname				= NULL,
	@FileMarker						sysname				= N'MIGRATION_BACKUP', 
	@OperatorName					sysname				= N'Alerts',
	@MailProfileName				sysname				= N'General',
	@EmailSubjectPrefix				nvarchar(50)		= N'[Migration Backup] ', 
	@PrintOnly						bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Databases = NULLIF(@Databases, N'');
	SET @FinalBackupType = ISNULL(NULLIF(@FinalBackupType, N''), N'LOG');
	SET @MigrationType = ISNULL(NULLIF(@MigrationType, N''), N'OFFLINE');
	SET @IncludeSanityMarker = ISNULL(@IncludeSanityMarker, 1);
	SET @SingleUserRollbackSeconds = ISNULL(@SingleUserRollbackSeconds, 5);
	SET @BackupDirectory = ISNULL(@BackupDirectory, N'{DEFAULT}');
	
	SET @CopyToBackupDirectory = NULLIF(@CopyToBackupDirectory, N'');
	SET @OffSiteBackupPath = NULLIF(@OffSiteBackupPath, N'');

	SET @BackupRetention = ISNULL(@BackupRetention, N'30 days');
	SET @CopyToRetention = NULLIF(@CopyToRetention, N'');
	SET @OffSiteRetention = NULLIF(@OffSiteRetention, N'');

	SET @EncryptionCertName = NULLIF(@EncryptionCertName, N'');
	SET @FileMarker = ISNULL(NULLIF(@FileMarker, N''), N'FINAL');

	SET @OperatorName = NULLIF(@OperatorName, N'');
	SET @MailProfileName = NULLIF(@MailProfileName, N'');
	SET @EmailSubjectPrefix = ISNULL(@EmailSubjectPrefix, N'[Migraton Backup] ');
	SET @PrintOnly = ISNULL(@PrintOnly, 0);

	IF @Databases IS NULL BEGIN 
		IF @Databases IS NULL BEGIN 
			RAISERROR(N'Invalid Input. Value for @Databases cannot be null or empty.', 16, 1);
			RETURN -1;
		END;
	  END
	ELSE BEGIN
		IF @Databases IN (N'master', N'msdb', N'tempdb') BEGIN 
			RAISERROR(N'Migration can only be initiated against USER databases.', 16, 1);
			RETURN -1;
		END;
	END;

	IF @BackupDirectory IS NULL BEGIN
		RAISERROR(N'@BackupDirectory cannot be NULL or empty. Please specify a valid backup directory or the token {DEFAULT}.', 16, 1);
		RETURN -4;
	END;

	IF UPPER(@FinalBackupType) NOT IN (N'FULL', N'DIFF', N'LOG') BEGIN 
		RAISERROR('Allowed values for @FinalBackupType are { FULL | DIFF | LOG }.', 16, 1);
		RETURN -5;
	END;

	IF UPPER(@MigrationType) NOT IN (N'OFFLINE', N'ONLINE') BEGIN
		RAISERROR(N'Allowe values for @MigrationType are { OFFLINE | ONLINE }.', 16, 1);
		RETURN -16;
	END;

	IF UPPER(@BackupDirectory) = N'{DEFAULT}' BEGIN
		SELECT @BackupDirectory = dbo.load_default_path('BACKUP');
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- HACK: @targets/@exclusions should handled via calls into dbo.load_database_names (but it's not done yet).
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @exclusions nvarchar(MAX) = N'';
	SELECT 
		@exclusions = @exclusions + LTRIM(SUBSTRING([result], CHARINDEX(N'-', [result]) + 1, LEN([result]))) + N','
	FROM 
		dbo.[split_string](@Databases, N',', 1)
	WHERE 
		[result] LIKE N'-%'
	ORDER BY 
		[row_id];

	IF @exclusions <> N''
		SET @exclusions = LEFT(@exclusions, LEN(@exclusions) - 1);

	DECLARE @targets nvarchar(MAX) = N'';
	SELECT 
		@targets = @targets + [result] + N','
	FROM 
		dbo.[split_string](@Databases, N',', 1)
	WHERE 
		[result] NOT LIKE N'-%'
	ORDER BY 
		[row_id];

	IF @targets <> N''
		SET @targets = LEFT(@targets, LEN(@targets) - 1);

	DECLARE @targetDatabases table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL 
	);

	INSERT INTO @targetDatabases ([database_name])
	EXEC dbo.list_databases
		@Targets = @targets,
	    @Exclusions = @exclusions,
		@Priorities = @Priorities,
		@ExcludeSecondaries = 0,
		@ExcludeRestoring = 0, 
		@ExcludeRecovering = 0, 
		@ExcludeOffline = 1;
	
	DECLARE @errors table (
		[error_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[timestamp] datetime NOT NULL, 
		[operation] sysname NOT NULL, 
		[exception] nvarchar(MAX) NOT NULL 
	);

	DECLARE @currentDb sysname; 
	DECLARE @sql nvarchar(MAX);

	DECLARE @errorMessage nvarchar(MAX), @errorLine int;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		REPLACE(REPLACE([database_name], N'[', N''), N']', N'')
	FROM 
		@targetDatabases 
	ORDER BY 
		[row_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDb;

	WHILE @@FETCH_STATUS = 0 BEGIN

		PRINT N'/*---------------------------------------------------------------------------------------------------------------------------------------------------';
		PRINT N'-- ' + @currentDb;
		PRINT N'---------------------------------------------------------------------------------------------------------------------------------------------------*/';
-- TODO: make sure @currentDB exists. 

		IF @IncludeSanityMarker = 1 BEGIN 
			SET @sql = N'USE [' + @currentDb + N'];
IF OBJECT_ID(N''dbo.[___migrationMarker]'', N''U'') IS NOT NULL DROP TABLE dbo.[___migrationMarker];
CREATE TABLE dbo.[___migrationMarker] (
	[data] sysname NULL
); 
INSERT INTO [___migrationMarker] ([data]) VALUES(N''Timestamp: '' + CONVERT(sysname, GETDATE(), 121));
SELECT @@SERVERNAME [server], DB_NAME() [database], * FROM [___migrationMarker];';
			
			BEGIN TRY 
				IF @PrintOnly = 0 BEGIN 
					EXEC sys.[sp_executesql]
						@sql;
				  END; 
				ELSE BEGIN 
					PRINT N'';
					PRINT @sql;
					PRINT N'GO';
				END;
			END TRY 
			BEGIN CATCH
				SELECT 
					@errorLine = ERROR_LINE(), 
					@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
				INSERT INTO @errors ([database_name], [timestamp], [operation], [exception])
				VALUES (@currentDb, GETDATE(), N'EXECUTE_RECOVERY', @errorMessage);

				IF @@TRANCOUNT > 0 
					ROLLBACK;
			END CATCH;
		END;

		SET @sql = N'USE [master]; -- Attempting to execute from within [{database_name}] will create realllllly ugly locking problems.

EXEC [admindb].dbo.[backup_databases]
	@BackupType = N''{backup_type}'',
	@DatabasesToBackup = N''{database_name}'',
	@BackupDirectory = N''{backup_directory}'',{copy_to}{offsite_to}
	@BackupRetention = N''{backup_retention}'',{copy_to_retention}{offsite_retention}
	@RemoveFilesBeforeBackup = 0,{encryption}
	@Directives = N''{directives}'',  -- {directiveDesc}
	@LogSuccessfulOutcomes = 1,{operator}{profile}{subject}
	@PrintOnly = 0; ';

		SET @sql = REPLACE(@sql, N'{backup_type}', @FinalBackupType);
		SET @sql = REPLACE(@sql, N'{database_name}', @currentDb);
		SET @sql = REPLACE(@sql, N'{backup_directory}', @BackupDirectory);
		SET @sql = REPLACE(@sql, N'{backup_retention}', @BackupRetention);
		SET @sql = REPLACE(@sql, N'{marker}', @FileMarker);

		IF @MigrationType = N'OFFLINE' BEGIN
			SET @sql = REPLACE(@sql, N'{directives}', N'FINAL:' + @FileMarker + N':' + CAST(@SingleUserRollbackSeconds AS sysname));
			SET @sql = REPLACE(@sql, N'{directiveDesc}', N'-- FINAL (backup) : <file_name_marker> : <set_single_user_rollback_seconds>');
			
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{directives}', N'MARKER:' + @FileMarker);
			SET @sql = REPLACE(@sql, N'{directiveDesc}', N'MARKER: <file_name_marker>');
		END;

		IF @CopyToBackupDirectory IS NOT NULL BEGIN 
			SET @sql = REPLACE(@sql, N'{copy_to}',  @crlf + @tab + N'@CopyToBackupDirectory = N''' + @CopyToBackupDirectory + N''', ');
			SET @sql = REPLACE(@sql, N'{copy_to_retention}',  @crlf + @tab + N'@CopyToRetention = N''' + @CopyToRetention + N''', ');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{copy_to}', N'');
			SET @sql = REPLACE(@sql, N'{copy_to_retention}', N'');
		END;

		IF @OffSiteBackupPath IS NOT NULL BEGIN 
			SET @sql = REPLACE(@sql, N'{offsite_to}',  @crlf + @tab + N'@OffSiteBackupPath = N''' + @OffSiteBackupPath + N''',');
			SET @sql = REPLACE(@sql, N'{offsite_retention}',  @crlf + @tab + N'@OffSiteRetention = N''' + @OffSiteRetention + N''', ');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{offsite_to}', N'');
			SET @sql = REPLACE(@sql, N'{offsite_retention}', N'');
		END;

		IF @EncryptionCertName IS NOT NULL BEGIN 
			SET @sql = REPLACE(@sql, N'{encryption}',  @crlf + @tab + N'@EncryptionCertName = N''' + @EncryptionCertName + N''',' + @crlf + @tab + N'@EncryptionAlgorithm = N''AES_256'', ');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{encryption}', N'');
		END;

		IF NULLIF(@OperatorName, N'Alerts') IS NOT NULL BEGIN 
			SET @sql = REPLACE(@sql, N'{operator}', @crlf + @tab + N'@OperatorName = N''' + @OperatorName + N''',');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{operator}', N'');
		END;

		IF NULLIF(@MailProfileName, N'General') IS NOT NULL BEGIN 
			SET @sql = REPLACE(@sql, N'{profile}', @crlf + @tab + N'@MailProfileName = N''' + @MailProfileName + N''',');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{profile}', N'');
		END;

		IF @EmailSubjectPrefix IS NOT NULL BEGIN 
			SET @sql = REPLACE(@sql, N'{subject}', @crlf + @tab + N'@EmailSubjectPrefix = N''' + @EmailSubjectPrefix  + N''',');
		  END;
		ELSE BEGIN 
			SET @sql = REPLACE(@sql, N'{subject}', N'');
		END;

		IF @PrintOnly = 0 BEGIN 
			BEGIN TRY 
				EXEC sys.[sp_executesql]
					@sql;
			END TRY 
			BEGIN CATCH 
				SELECT 
					@errorLine = ERROR_LINE(), 
					@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
				INSERT INTO @errors ([database_name], [timestamp], [operation], [exception])
				VALUES (@currentDb, GETDATE(), N'COMPAT_MULTI_USER_ETC', @errorMessage);

				IF @@TRANCOUNT > 0 
				ROLLBACK;
			END CATCH
		  END; 
		ELSE BEGIN 
			PRINT N'';
			PRINT @sql;
			PRINT N'GO';
			PRINT N'';
		END;

		FETCH NEXT FROM [walker] INTO @currentDb;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	IF EXISTS (SELECT NULL FROM @errors) BEGIN 
		SELECT * FROM @errors ORDER BY [error_id];
	END;

	IF NOT EXISTS (SELECT NULL FROM @errors) BEGIN
		IF @PrintOnly = 0 BEGIN
			SELECT N'operation complete' [outcome];
		END;
	END;

	RETURN 0;
GO