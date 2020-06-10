/*

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
	@FinalBackupType				sysname				= NULL,			-- { FULL | DIFF | LOG }
	@FinalBackupDate				date				= NULL, 
	@BackupDirectory				nvarchar(2000)		= N'{DEFAULT}', 
	@IncludeSanityMarker			bit					= 1, 
	@FileMarker						sysname				= N'FINAL'
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @FinalBackupDate = ISNULL(@FinalBackupDate, GETDATE());
	SET @FileMarker = ISNULL(NULLIF(@FileMarker, N''), N'FINAL');

	SET @SourceDatabase = NULLIF(@SourceDatabase, N'');
	SET @FinalBackupType = NULLIF(@FinalBackupType, N'');

	SET @BackupDirectory = NULLIF(@BackupDirectory, N'');

	IF @SourceDatabase IS NULL BEGIN 
		RAISERROR(N'@SourceDatabase cannot be NULL or empty.', 16, 1);
		RETURN -2;
	END;

	IF @FinalBackupType IS NULL BEGIN
		RAISERROR(N'@FinalBackupType cannot be NULL or empty. Allowed values are { FULL | DIFF | LOG }.', 16, 1);
		RETURN -3;
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

	PRINT N'
------------------------------------------------------------------------	
-- Set SINGLE_USER:
ALTER DATABASE [' + @SourceDatabase + N'] SET SINGLE_USER WITH ROLLBACK AFTER 20 SECONDS;
GO

';


	IF @IncludeSanityMarker = 1 BEGIN

		PRINT N'------------------------------------------------------------------------
-- Sanity Marker Table: ';
		PRINT N'USE [' + @SourceDatabase + N'];
GO

IF OBJECT_ID(N''dbo.[___migrationMarker]'', N''U'') IS NOT NULL BEGIN
	DROP TABLE dbo.[___migrationMarker];
END;

CREATE TABLE dbo.[___migrationMarker] (
	nodata sysname NULL
); 

INSERT INTO [___migrationMarker] (nodata) SELECT CONCAT(''TimeStamp: '', CONVERT(sysname, GETDATE(), 113));

SELECT * FROM [___migrationMarker];
GO 

';

	END;

	DECLARE @fullTemplate nvarchar(MAX) = N'BACKUP DATABASE [{database_name}] TO DISK = N''{backup_directory}\{database_name}\FULL_{database_name}_backup_{date}_<hhmm, sysname, 0117>00_{marker}.bak''  
	WITH 
		COMPRESSION, NAME = N''FULL_{database_name}_backup_{date}_<hhmm, sysname, 0117>00_{marker}.bak'', SKIP, REWIND, NOUNLOAD, CHECKSUM, STATS = 5; ';

	DECLARE @diffTemplate nvarchar(MAX) = N'BACKUP DATABASE [{database_name}] TO DISK = N''{backup_directory}\{database_name}\DIFF_{database_name}_backup_{date}_<hhmm, sysname, 0117>00_{marker}.bak''  
	WITH 
		COMPRESSION, DIFFERENTIAL, NAME = N''DIFF_{database_name}_backup_{date}_<hhmm, sysname, 0117>00_{marker}.bak'', SKIP, REWIND, NOUNLOAD, CHECKSUM, STATS = 10; ';

	DECLARE @logTemplate nvarchar(MAX) = N'BACKUP LOG [{database_name}] TO DISK = N''{backup_directory}\{database_name}\LOG_{database_name}_backup_{date}_<hhmm, sysname, 0117>00_{marker}.trn''  
	WITH 
		COMPRESSION, NAME = N''LOG_{database_name}_backup_{date}_<hhmm, sysname, 0117>00_{marker}.trn'', SKIP, REWIND, NOUNLOAD, CHECKSUM, STATS = 25; ';

	DECLARE @sql nvarchar(MAX);

	IF UPPER(@FinalBackupType) = N'FULL' BEGIN
		SET @sql = @fullTemplate;
	END;
	
	IF UPPER(@FinalBackupType) = N'DIFF' BEGIN
		SET @sql = @diffTemplate;
	END;
	
	IF UPPER(@FinalBackupType) = N'LOG' BEGIN
		SET @sql = @logTemplate;
	END;
	
	--DECLARE @timeStamp sysname = REPLACE(REPLACE(REPLACE((CONVERT(sysname, GETDATE(), 120)), N' ', N'_'), N':', N''), N'-', N'_');
	DECLARE @timeStamp sysname = REPLACE(CONVERT(sysname, GETDATE(), 23), N'-', N'_');

	SET @sql = REPLACE(@sql, N'{database_name}', @SourceDatabase);
	SET @sql = REPLACE(@sql, N'{backup_directory}', @BackupDirectory);
	SET @sql = REPLACE(@sql, N'{date}', @timeStamp);
	SET @sql = REPLACE(@sql, N'{marker}', @FileMarker);

	PRINT N'------------------------------------------------------------------------
-- Final Backup - CTRL+SHIFT+M at execution time to set HHMM for final backup:'
	PRINT @sql;

	PRINT N'
';

	PRINT N'------------------------------------------------------------------------
-- Take [' + @SourceDatabase + N'] Offline: 	
USE [master];
GO

ALTER DATABASE [' + @SourceDatabase + N'] SET OFFLINE;
GO 

';

	RETURN 0;
GO
	
	
	