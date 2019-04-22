
/*

	TODO:
		- This is actually MISSING a key bit of functionality - if this db is going to be a COPY... then ... 
			the logical file-names of the files need to change... 
				er... well, maybe they don't.... 
					but... that should be an OPTION - i.e., @RenameLogicalFileNames - when 0 don't... just let them 'inherit'... when 1, then a) grab the logical file names and IDs from the SOURCE db BEFORE we start doing any processing and b) apply those AFTER the new db has been restored but before the backup kicks off.... 

			AND... arguably, push this option down into dbo.restore_databases cuz... that's where it really needs to be... 


		-  ALSO... 
				@PrintOnly - need that as a standard across most all sprocs (except 'print' sprocs of course).



	NOTES:
		- This is really just a 'wrapper' around dbo.restore_databases and dbo.backup_databases such that it allows quick/easy duplication of a single
			database (to be used for production) such that a) it 'copies' the db from backups from an existing database and b) kicks off an immediate FULL backup upon db creation. 


*/



USE admindb;
GO


IF OBJECT_ID('dbo.copy_database','P') IS NOT NULL
	DROP PROC dbo.copy_database;
GO

CREATE PROC dbo.copy_database 
	@SourceDatabaseName			sysname, 
	@TargetDatabaseName			sysname, 
	@BackupsRootDirectory		nvarchar(2000)	= N'[DEFAULT]', 
	@CopyToBackupDirectory		nvarchar(2000)	= NULL,
	@DataPath					sysname			= N'[DEFAULT]', 
	@LogPath					sysname			= N'[DEFAULT]',
	@OperatorName				sysname			= N'Alerts',
	@MailProfileName			sysname			= N'General'
AS
	SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@SourceDatabaseName,'') IS NULL BEGIN
		RAISERROR('@SourceDatabaseName cannot be Empty/NULL. Please specify the name of the database you wish to copy (from).', 16, 1);
		RETURN -1;
	END;

	IF NULLIF(@TargetDatabaseName, '') IS NULL BEGIN
		RAISERROR('@TargetDatabaseName cannot be Empty/NULL. Please specify the name of new database that you want to create (as a copy).', 16, 1);
		RETURN -1;
	END;

	-- Make sure the target database doesn't already exist: 
	IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabaseName) BEGIN
		RAISERROR('@TargetDatabaseName already exists as a database. Either pick another target database name - or drop existing target before retrying.', 16, 1);
		RETURN -5;
	END;

	-- Allow for default paths:
	IF UPPER(@BackupsRootDirectory) = N'[DEFAULT]' BEGIN
		SELECT @BackupsRootDirectory = dbo.load_default_path('BACKUP');
	END;

	IF UPPER(@DataPath) = N'[DEFAULT]' BEGIN
		SELECT @DataPath = dbo.load_default_path('DATA');
	END;

	IF UPPER(@LogPath) = N'[DEFAULT]' BEGIN
		SELECT @LogPath = dbo.load_default_path('LOG');
	END;

	DECLARE @retention nvarchar(10) = N'110w'; -- if we're creating/copying a new db, there shouldn't be ANY backups. Just in case, give it a very wide berth... 
	DECLARE @copyToRetention nvarchar(10) = NULL;
	IF @CopyToBackupDirectory IS NOT NULL 
		SET @copyToRetention = @retention;

	PRINT N'Attempting to Restore a backup of [' + @SourceDatabaseName + N'] as [' + @TargetDatabaseName + N']';
	
	DECLARE @restored bit = 0;
	DECLARE @errorMessage nvarchar(MAX); 

	BEGIN TRY 
		EXEC dbo.restore_databases
			@DatabasesToRestore = @SourceDatabaseName,
			@BackupsRootPath = @BackupsRootDirectory,
			@RestoredRootDataPath = @DataPath,
			@RestoredRootLogPath = @LogPath,
			@RestoredDbNamePattern = @TargetDatabaseName,
			@SkipLogBackups = 0,
			@CheckConsistency = 0, 
			@DropDatabasesAfterRestore = 0,
			@OperatorName = @OperatorName, 
			@MailProfileName = @MailProfileName, 
			@EmailSubjectPrefix = N'[COPY DATABASE OPERATION] : ';

	END TRY
	BEGIN CATCH
		SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception while restoring copy of database. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
	END CATCH

	-- 'sadly', restore_databases does a great job of handling most exceptions during execution - meaning that if we didn't get errors, that doesn't mean there weren't problems. So, let's check up: 
	IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = @TargetDatabaseName AND state_desc = N'ONLINE')
		SET @restored = 1; -- success (the db wasn't there at the start of this sproc, and now it is (and it's online). 
	ELSE BEGIN 
		-- then we need to grab the latest error: 
		SELECT @errorMessage = error_details FROM dbo.restore_log WHERE restore_id = (
			SELECT MAX(restore_id) FROM dbo.restore_log WHERE operation_date = GETDATE() AND [database] = @SourceDatabaseName AND restored_as = @TargetDatabaseName);

		IF @errorMessage IS NULL -- hmmm weird:
			SET @errorMessage = N'Unknown error with restore operation - execution did NOT complete as expected. Please Check Email for additional details/insights.';

	END

	IF @errorMessage IS NULL
		PRINT N'Restore Complete. Kicking off backup [' + @TargetDatabaseName + N'].';
	ELSE BEGIN
		PRINT @errorMessage;
		RETURN -10;
	END;
	
	-- Make sure the DB owner is set correctly: 
	DECLARE @sql nvarchar(MAX) = N'ALTER AUTHORIZATION ON DATABASE::[' + @TargetDatabaseName + N'] TO sa;';
	EXEC sp_executesql @sql;

	DECLARE @backedUp bit = 0;
	IF @restored = 1 BEGIN
		
		BEGIN TRY
			EXEC dbo.backup_databases
				@BackupType = N'FULL',
				@DatabasesToBackup = @TargetDatabaseName,
				@BackupDirectory = @BackupsRootDirectory,
				@BackupRetention = @retention,
				@CopyToBackupDirectory = @CopyToBackupDirectory, 
				@CopyToRetention = @copyToRetention,
				@OperatorName = @OperatorName, 
				@MailProfileName = @MailProfileName, 
				@EmailSubjectPrefix = N'[COPY DATABASE OPERATION] : ';

			SET @backedUp = 1;
		END TRY
		BEGIN CATCH
			SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected Exception while executing backup of new/copied database. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
		END CATCH

	END;

	IF @restored = 1 AND @backedUp = 1 
		PRINT N'Operation Complete.';
	ELSE BEGIN
		PRINT N'Errors occurred during execution:';
		PRINT @errorMessage;
	END;

	RETURN 0;
GO
	