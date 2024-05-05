/*

NOTE/REMINDER: 
	dbo.backup_databases 
	NOW supports a 'marker' directive - i.e., : 

	EXEC admindb.dbo.[backup_databases]
			@BackupType = N'FULL',
			@DatabasesToBackup = N'TeamSupportFIS',
			@DatabasesToExclude = N'%s4test',
			@BackupDirectory = N'{DEFAULT}',
			@CopyToBackupDirectory = N'\\{PARTNER}\SQLBackups',
			@OffSiteBackupPath = N'S3::ts-database-backup:prod\FIS\',
			@BackupRetention = N'3 days',
			@CopyToRetention = N'3 days',
			@OffSiteRetention = N'infinite',
			@LogSuccessfulOutcomes = 1,
			@AllowNonAccessibleSecondaries = 1,
-- this guy:
	@Directives = N'Marker:CheckPoint_0',
			@OperatorName = N'Alerts',
			@MailProfileName = N'General',
			@PrintOnly = 1;





	vNEXT:
		- This is all pretty happy-path - and assumes no problems/issues. So, basically, add some 'error' handling and/or various condition-checks and options for ... recovery. 
					(NOTE: normally... RAISERROR(xxx, 27,1) WITH LOG or whatever would be a great way to terminate execution of a script like this. 
							BUT... we're in SINGLE_USER mode for part of this - or expect to be. So, that'd suck. 
							GOTO? ... not going to work. so... i'll have to get creative with how to 'stop' execution if/when a specific condition hasn't been met. (Maybe there's a severity that kills execution but not the connection?)

			OTHERWISE, here are some of the core things to address: 
				- verify DB in SINGLE_USER mode before continuing with sanity-marker/backup/etc. 
				- check for successful completion of BACKUP before taking DB offline. 



	EXAMPLE:

			EXEC admindb.dbo.[script_sourcedb_migration_template]
				@SourceDatabase = N'IMAGE',  -- does NOT have to exist on server... i.e., string/text only... 
				@FinalBackupType = N'LOG',		-- FULL | DIFF | LOG
				--@FinalBackupDate = '2020-06-06',
				@BackupDirectory = N'{DEFAULT}';


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_sourcedb_migration_template','P') IS NOT NULL
	DROP PROC dbo.[script_sourcedb_migration_template];
GO

CREATE PROC dbo.[script_sourcedb_migration_template]
	@SourceDatabase					sysname				= NULL, 
	@FinalBackupType				sysname				= N'LOG',			-- { FULL | DIFF | LOG }
	@IncludeSanityMarker			bit					= 1, 
	@SingleUserRollbackSeconds		int					= 5,
	@BackupDirectory				nvarchar(2000)		= N'{DEFAULT}', 
	@CopyToBackupDirectory			nvarchar(2000)		= NULL,
	@OffSiteBackupPath				nvarchar(2000)		= NULL,
	@BackupRetention				sysname				= N'30 days',		
	@CopyToRetention				sysname				= N'30 days', 
	@OffSiteRetention				sysname				= N'30 days',
	@EncryptionCertName				sysname				= NULL,
	@FileMarker						sysname				= N'FINAL_BACKUP', 
	@OperatorName					sysname				= N'Alerts',
	@MailProfileName				sysname				= N'General',
	@EmailSubjectPrefix				nvarchar(50)		= N'[Migration Backup] '
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @SourceDatabase = NULLIF(@SourceDatabase, N'');
	SET @FinalBackupType = ISNULL(NULLIF(@FinalBackupType, N''), N'LOG');
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
	
	IF @SourceDatabase IS NULL BEGIN 
		RAISERROR(N'@SourceDatabase cannot be NULL or empty.', 16, 1);
		RETURN -2;
	END;

	IF @BackupDirectory IS NULL BEGIN
		RAISERROR(N'@BackupDirectory cannot be NULL or empty. Please specify a valid backup directory or the token {DEFAULT}.', 16, 1);
		RETURN -4;
	END;

	IF UPPER(@FinalBackupType) NOT IN (N'FULL', N'DIFF', N'LOG') BEGIN 
		RAISERROR('Allowed values for @FinalBackupType are { FULL | DIFF | LOG }.', 16, 1);
		RETURN -5;
	END;

	IF UPPER(@BackupDirectory) = N'{DEFAULT}' BEGIN
		SELECT @BackupDirectory = dbo.load_default_path('BACKUP');
	END;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	IF @IncludeSanityMarker = 1 BEGIN

		PRINT N'-----------------------------------------------------------------------------------------------------------------------------------------------------
-- Sanity-Marker Table:
-----------------------------------------------------------------------------------------------------------------------------------------------------';
		PRINT N'USE [' + @SourceDatabase + N'];
GO

IF OBJECT_ID(N''dbo.[___migrationMarker]'', N''U'') IS NOT NULL DROP TABLE dbo.[___migrationMarker];

CREATE TABLE dbo.[___migrationMarker] (
	[data] sysname NULL
); 

INSERT INTO [___migrationMarker] ([data]) SELECT CONCAT(''TimeStamp: '', CONVERT(sysname, GETDATE(), 113));

SELECT * FROM [___migrationMarker];
GO 

USE [master];
GO

';

	END;

	DECLARE @sql nvarchar(MAX) = N'USE [master]; -- Attempting to execute from within [{database_name}] will create realllllly ugly locking problems.
GO

EXEC [admindb].dbo.[backup_databases]
	@BackupType = N''{backup_type}'',
	@DatabasesToBackup = N''{database_name}'',
	@BackupDirectory = N''{backup_directory}'',{copy_to}{offsite_to}
	@BackupRetention = N''{backup_retention}'',{copy_to_retention}{offsite_retention}
	@RemoveFilesBeforeBackup = 0,{encryption}
--	@AddServerNameToSystemBackupPath = 0,
	@Directives = N''{directives}'',  -- FINAL (backup) : <file_name_marker> : <set_single_user_rollback_seconds>
	@LogSuccessfulOutcomes = 1,{operator}{profile}{subject}
	@PrintOnly = 0; ';

	SET @sql = REPLACE(@sql, N'{backup_type}', @FinalBackupType);
	SET @sql = REPLACE(@sql, N'{database_name}', @SourceDatabase);
	SET @sql = REPLACE(@sql, N'{backup_directory}', @BackupDirectory);
	SET @sql = REPLACE(@sql, N'{backup_retention}', @BackupRetention);
	SET @sql = REPLACE(@sql, N'{marker}', @FileMarker);
	SET @sql = REPLACE(@sql, N'{directives}', N'FINAL:' + @FileMarker + N':' + CAST(@SingleUserRollbackSeconds AS sysname));

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
		SET @sql = REPLACE(@sql, N'{subject}', @crlf + N'--' + @tab + N'@EmailSubjectPrefix = N''' + @EmailSubjectPrefix  + N''',');
	  END;
	ELSE BEGIN 
		SET @sql = REPLACE(@sql, N'{subject}', N'');
	END;

	PRINT N'-----------------------------------------------------------------------------------------------------------------------------------------------------
-- Final Backup (SINGLE_USER) + OFFLINE:
----------------------------------------------------------------------------------------------------------------------------------------------------- ';

	EXEC [admindb].dbo.[print_long_string] @sql;

	PRINT N'GO';

	RETURN 0;
GO	