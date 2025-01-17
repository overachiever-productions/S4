/*

	LOGIC (FATAL Errors vs Logged Errors) 
		Goal is to accomplish as MANY tasks relative to a backup (or group of backups) as POSSIBLE. Obviously, if we're trying to backup to a directory that doesn't exist, and so on... then, some things are fatal. 
		But other things are not... 
			Overall chain of operations and fatal or not is: 
				Validations			(Can be fatal or not - just depends)
				Create Backup		Fatal if it fails. 
				Verify Backup		Fatal? 
				Copy Backup			Non-Fatal - log and continue
				Offsite Copy		Non-Fatal - log and continue
				Cleanup Files		Non-Fatal - log and continue



	NOTES:
		- There's a serious bug/problem with T-SQL and how it handles TRY/CATCH (or other error-handling) operations:
			https://connect.microsoft.com/SQLServer/feedback/details/746979/try-catch-construct-catches-last-error-only
			This sproc gets around that limitation via the logic defined in dbo.dba_ExecuteAndFilterNonCatchableCommand;

		- A good way to simulate (er, well, create) errors and issues while executing backups is to:
			a) start executing a backup of, say, databaseN FROM a query/session in, say, databaseX (where databaseX is NOT the database you want to backup). 
			b) once the process (working in databaseX) is running, switch to another session/window and DROP databaseX WITH ROLLBACK IMMEDIATE... 
			and you'll get a whole host of errors/problems. 

		- This sproc explicitly uses RAISERROR instead of THROW for 'backwards compat' down to SQL Server 2008. 

	TODO:
		- Review and potentially integrate any details defined here: 
			http://vickyharp.com/2013/12/killing-sessions-with-external-wait-types/

		- vNEXT: 
			In addition to the 'retry' logic stuff below... need to 'decouple' secondary/copy-to backups from this sproc. 
				specifically, implementation logic shouldn't be handled here... it should be handled in the \utilities\dba_SynchronizeBackups sproc... 
				AND this sproc will just attempt to CALL that... and handle errors/issues when that won't work... i..e, that'd be a situation where a) we retry, b) we warn that off-box backups/copies weren't able to run as expected... 

				then... in the core of dba_SynchronizeBackups the following would be done: 
					a) copy files from primary to secondary that aren't already there... 
					b) remove any files > @CopyToRetention... 
					
					I BELIEVE the logic there should be fairly tricksy/hard... 
					 vs what i'm doing now - which is 'hard coupled' logic (local backup and then COPY - or the operation FAILS).... 
					
					BUT, i think i could probably do something where... i added a new column to dba_BackupLogs... that would keep tabs of any files that hadn't been copied over? or maybe a whole new table? 
						so that once 'connectivity' is back up... we just copy any files that need to be copied... and something lilke that... right? 
						 

		- Add in simplified 'retry' logic for both backups and copy-to operations (i.e., something along the lines of adding a column to the 'list' of 
			dbs being backed up and if there's a failure... just add a counter/increment-counter for number of failures into @targetDatabases along
			with some meta-data about what the failure was (i.e., if we can't copy a file, don't re-backup the entire db) and then drop this into the 
			'bottom' of @targetDatabases... and when done with other dbs... retry  up to N times on/against certain types of operations. 
				that'll make things a wee bit more resilient (and, arguably... should throw in a WAITFOR DELAY once we start 'reprocessing') without
				hitting a point where a failed backup and/or copy operation could, say, retry 10x times with 30 seconds lag between each try because... 
					ALLOWING that much 'retry' typically means there's a huge problem and... we're hurting ourselves rather than failing and reporting 
					the error. I could/should also keep tabs on the AMOUNT of time spent ... and log it into a 'notes' column in .. dbo.backup_log.

		- vNEXT: Additional integration with AGs (simple 2-node AGs first via preferred replica UDF), then on to multi-node configurations. 
			And, in the process, figure out how to address DIFFs as... they're not supported on secondaries: 
				http://dba.stackexchange.com/questions/152622/differential-backups-are-not-supported-on-secondary-replicas

		- vNEXT: Potentially look at an @NumberOfFiles option - for striping backups across multiple files
			there aren't THAT many benefits (in most cases) to having multiple files (though I have seen some perf benefits in the past on SOME systems)



-- REFACTORING:
--  need to make sure that @cummulativeErrorMessage isn't 'leaking' info from ONE step/section of processing (e.g., backups, verify, copy, offsitecopy, cleanup, etc) to the next. 
--		not sure when/where I thought that all of the SET @x = ISNULL(@x, N'') + x-data-here ... was a good idea. it was a hack... and it has made things stupid hard. 
--  ARGUABLY, with the above, i should be able to UPDATE @executionDetails SET error_message|copy_message|whatever = @currentNasty... instead of carrying stuff along in @cummulative variables... 



*/



USE [admindb];
GO

IF OBJECT_ID('dbo.backup_databases','P') IS NOT NULL
	DROP PROC dbo.backup_databases;
GO

CREATE PROC dbo.backup_databases 
	@BackupType							sysname,																-- { FULL|DIFF|LOG }
	@DatabasesToBackup					nvarchar(MAX),															-- { {SYSTEM} | {USER} |name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX)							= NULL,							-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX)							= NULL,							-- { higher,priority,dbs,*,lower,priority,dbs } - where * represents dbs not specifically specified (which will then be sorted alphabetically
	@BackupDirectory					nvarchar(2000)							= N'{DEFAULT}',					-- { {DEFAULT} | path_to_backups }
	@CopyToBackupDirectory				nvarchar(2000)							= NULL,							-- { NULL | path_for_backup_copies } NOTE {PARTNER} allowed as a token (if a PARTNER is defined).
	@OffSiteBackupPath					nvarchar(2000)							= NULL,							-- e.g., S3::bucket-name:path\sub-path'
	@BackupRetention					nvarchar(10),															-- [DOCUMENT HERE]
	@CopyToRetention					nvarchar(10)							= NULL,							-- [DITTO: As above, but allows for diff retention settings to be configured for copied/secondary backups.]
	@OffSiteRetention					nvarchar(10)							= NULL,							-- { vector | n backups | {INFINITE} }   - where {INFINITE} is a token meaning: S4 won't tackle cleanups, instead this is handled by retention policies.
	@RemoveFilesBeforeBackup			bit										= 0,							-- { 0 | 1 } - when true, then older backups will be removed BEFORE backups are executed.
	@EncryptionCertName					sysname									= NULL,							-- Ignored if not specified. 
	@EncryptionAlgorithm				sysname									= NULL,							-- Required if @EncryptionCertName is specified. AES_256 is best option in most cases.
	@AddServerNameToSystemBackupPath	bit										= 0,							-- If set to 1, backup path is: @BackupDirectory\<db_name>\<server_name>\
	@AllowNonAccessibleSecondaries		bit										= 0,							-- If review of @DatabasesToBackup yields no dbs (in a viable state) for backups, exception thrown - unless this value is set to 1 (for AGs, Mirrored DBs) and then execution terminates gracefully with: 'No ONLINE dbs to backup'.
	@AlwaysProcessRetention				bit										= 0,							-- IF @AllowNonAccessibleSecondaries = 1, then if @AlwaysProcessRetention = 1, if/when we find NO databases to backup, we'll pass in the @TargetDatabases to a CLEANUP process vs simply short-circuiting execution.
	@Directives							nvarchar(400)							= NULL,							-- { KEEP_ONLINE | TAIL_OF_LOG[:<marker>][:<rollback_seconds>] | FINAL[:<marker>][:<rollback_seconds>] | COPY_ONLY | FILE:logical_file_name | FILEGROUP:file_group_name | MARKER:file-name-tail-marker }  - NOTE: NOT mutually exclusive. Also, MULTIPLE FILE | FILEGROUP directives can be specified - just separate with commas. e.g., FILE:secondary, FILE:tertiarty. 
	@LogSuccessfulOutcomes				bit										= 0,							-- By default, exceptions/errors are ALWAYS logged. If set to true, successful outcomes are logged to dba_DatabaseBackup_logs as well.
	@OperatorName						sysname									= N'Alerts',
	@MailProfileName					sysname									= N'General',
	@EmailSubjectPrefix					nvarchar(50)							= N'[Database Backups] ',
	@PrintOnly							bit										= 0								-- Instead of EXECUTING commands, they're printed to the console only. 	
AS
	SET NOCOUNT ON;

	-- {copyright}

	SET @CopyToBackupDirectory = NULLIF(@CopyToBackupDirectory, N'');
	SET @OffSiteBackupPath = NULLIF(@OffSiteBackupPath, N'');
	SET @CopyToRetention = NULLIF(@CopyToRetention, N'');
	SET @OffSiteRetention = NULLIF(@OffSiteRetention, N'');

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = N'WEB';

		IF @@VERSION LIKE '%Workgroup Edition%' SET @Edition = N'WORKGROUP';
	END;
	
	IF @Edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF (@PrintOnly = 0) AND (@Edition != 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF UPPER(@BackupDirectory) = N'{DEFAULT}' BEGIN
		SELECT @BackupDirectory = dbo.load_default_path('BACKUP');
	END;

	IF NULLIF(@BackupDirectory, N'') IS NULL BEGIN
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG') BEGIN
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	IF UPPER(@DatabasesToBackup) = N'{READ_FROM_FILESYSTEM}' BEGIN
		RAISERROR('@DatabasesToBackup may NOT be set to the token {READ_FROM_FILESYSTEM} when processing backups.', 16, 1);
		RETURN -9;
	END

	EXEC @return = dbo.validate_retention @BackupRetention, N'@BackupRetention';
	IF @return <> 0 RETURN @return;

	IF @CopyToBackupDirectory IS NOT NULL BEGIN 
		EXEC @return = dbo.[validate_retention] @CopyToRetention, N'@CopyToRetention';
		IF @return <> 0 RETURN @return;
	END;

	IF @OffSiteBackupPath IS NOT NULL BEGIN 
		EXEC @return = dbo.[validate_retention] @OffSiteRetention, N'@OffSiteRetention';
		IF @return <> 0 RETURN @return;
	END;

	IF (SELECT dbo.[count_matches](@CopyToBackupDirectory, N'{PARTNER}')) > 0 BEGIN 

		IF NOT EXISTS (SELECT NULL FROM sys.servers WHERE [name] = N'PARTNER') BEGIN
			RAISERROR('THe {PARTNER} token can only be used in the @CopyToBackupDirectory if/when a PARTNER server has been registered as a linked server.', 16, 1);
			RETURN -20;
		END;

		DECLARE @partnerName sysname; 
		EXEC sys.[sp_executesql]
			N'SET @partnerName = (SELECT TOP 1 [name] FROM PARTNER.master.sys.servers WHERE [is_linked] = 0 ORDER BY [server_id]);', 
			N'@partnerName sysname OUTPUT', 
			@partnerName = @partnerName OUTPUT;

		SET @CopyToBackupDirectory = REPLACE(@CopyToBackupDirectory, N'{PARTNER}', @partnerName);
	END;

	IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
		IF (CHARINDEX(N'[', @EncryptionCertName) > 0) OR (CHARINDEX(N']', @EncryptionCertName) > 0) 
			SET @EncryptionCertName = REPLACE(REPLACE(@EncryptionCertName, N']', N''), N'[', N'');
		
		-- make sure the cert name is legit and that an encryption algorithm was specified:
		IF NOT EXISTS (SELECT NULL FROM master.sys.certificates WHERE name = @EncryptionCertName) BEGIN
			RAISERROR('Certificate name specified by @EncryptionCertName is not a valid certificate (not found in sys.certificates).', 16, 1);
			RETURN -15;
		END;

		IF NULLIF(@EncryptionAlgorithm, '') IS NULL BEGIN
			RAISERROR('@EncryptionAlgorithm must be specified when @EncryptionCertName is specified.', 16, 1);
			RETURN -15;
		END;
	END;

	DECLARE @isCopyOnlyBackup bit = 0;
	DECLARE @fileOrFileGroupDirective nvarchar(2000) = '';
	DECLARE @setSingleUser bit = 0;
	DECLARE @keepOnline bit = 0; 
	DECLARE @setSingleUserRollbackSeconds int = 10;
	DECLARE @markerOverride sysname;

	IF NULLIF(@Directives, N'') IS NOT NULL BEGIN
		SET @Directives = UPPER(LTRIM(RTRIM(@Directives)));
		
		DECLARE @allDirectives table ( 
			row_id int NOT NULL, 
			directive sysname NOT NULL, 
			detail sysname NULL, 
			detail2 sysname NULL
		);

		INSERT INTO @allDirectives ([row_id], [directive])
		SELECT * FROM dbo.[split_string](@Directives, N',', 1);

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] LIKE N'%:%') BEGIN 
			UPDATE @allDirectives 
			SET 
				[directive] = SUBSTRING([directive], 0, CHARINDEX(N':', [directive])), 
				[detail] = SUBSTRING([directive], CHARINDEX(N':', [directive]) + 1, LEN([directive]))
			WHERE 
				[directive] LIKE N'%:%';
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [detail] LIKE N'%:%') BEGIN 
			UPDATE @allDirectives 
			SET 
				[detail] = SUBSTRING([detail], 0, CHARINDEX(N':', [detail])), 
				[detail2] = REPLACE(SUBSTRING([detail], CHARINDEX(N':', [detail]) + 1, LEN([detail])), N':', N'')			
			WHERE 
				[detail] LIKE N'%:%';
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] NOT IN (N'COPY_ONLY', N'FILE', N'FILEGROUP', N'MARKER', N'KEEP_ONLINE', N'TAIL_OF_LOG', N'FINAL')) BEGIN 
			RAISERROR(N'Invalid @Directives value specified. Permitted values are { FINAL | TAIL_OF_LOG | KEEP_ONLINE | COPY_ONLY | FILE:logical_name | FILEGROUP:group_name | MARKER:filename_tail_marker } only.', 16, 1);
			RETURN -20;
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives GROUP BY [directive] HAVING COUNT(*) > 1) BEGIN 
			RAISERROR(N'Duplicate Directives are NOT allowed within @Directives.', 16, 1);	
			RETURN -200;
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] = N'COPY_ONLY') BEGIN 
			IF UPPER(@BackupType) = N'DIFF' BEGIN
				-- NOTE: COPY_ONLY DIFF backups won't throw an error (in SQL Server) but they're logically 'wrong' - hence the S4 warning: https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql?view=sql-server-ver16
				RAISERROR(N'Invalid @Directives value specified. COPY_ONLY can NOT be specified when @BackupType = DIFF. Only FULL and LOG backups may be COPY_ONLY (and should be used only for one-off testing or other specialized needs.', 16, 1);
				RETURN -21;
			END; 

			SET @isCopyOnlyBackup = 1;
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE ([directive] = N'FILE') OR ([directive] = N'FILEGROUP')) BEGIN 
			SELECT 
				@fileOrFileGroupDirective = @fileOrFileGroupDirective + [directive] + N' = ''' + [detail] + N''', '
			FROM 
				@allDirectives
			WHERE 
				([directive] = N'FILE') OR ([directive] = N'FILEGROUP')
			ORDER BY 
				row_id;

			SET @fileOrFileGroupDirective = NCHAR(13) + NCHAR(10) + NCHAR(9) + LEFT(@fileOrFileGroupDirective, LEN(@fileOrFileGroupDirective) -1) + NCHAR(13) + NCHAR(10)+ NCHAR(9) + NCHAR(9);
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] = N'TAIL_OF_LOG') BEGIN 
			SELECT
				@setSingleUser = 1,
				@markerOverride = ISNULL([detail], N'tail_of_log'), 
				@setSingleUserRollbackSeconds = ISNULL([detail2], @setSingleUserRollbackSeconds)
			FROM 
				@allDirectives 
			WHERE 
				[directive] = N'TAIL_OF_LOG';
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] = N'FINAL') BEGIN 
			SELECT
				@setSingleUser = 1,
				@markerOverride = ISNULL([detail], N'tail_of_log'), 
				@setSingleUserRollbackSeconds = ISNULL([detail2], @setSingleUserRollbackSeconds)
			FROM 
				@allDirectives 
			WHERE 
				[directive] = N'FINAL';			
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] = N'KEEP_ONLINE') BEGIN 
			SET @keepOnline = 1;
		END;

		IF EXISTS (SELECT NULL FROM @allDirectives WHERE [directive] = N'MARKER') BEGIN
			SELECT @markerOverride = [detail] FROM @allDirectives WHERE [directive] = N'MARKER';
		END;
	END;

	IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
		IF @OffSiteBackupPath NOT LIKE 'S3::%' BEGIN 
			RAISERROR('S3 Backups are the only OffSite Backup Types currently supported. Please use the format S3::bucket-name:path\sub-path', 16, 1);
			RETURN -200;
		END;
	END;

	IF @AlwaysProcessRetention = 1 BEGIN 
		IF @AllowNonAccessibleSecondaries = 0 BEGIN 
			RAISERROR(N'@AlwaysProcessRetention can ONLY be set when @AllowNonAccessibleSecondaries = 1.', 16, 1);
			RETURN -19;
		END;
	END;

	-----------------------------------------------------------------------------
	DECLARE @excludeSimple bit = 0;

	IF UPPER(@BackupType) = N'LOG'
		SET @excludeSimple = 1;

	-- Determine which databases to backup:
	DECLARE @targetDatabases table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDatabases ([database_name])
	EXEC dbo.list_databases
	    @Targets = @DatabasesToBackup,
	    @Exclusions = @DatabasesToExclude,
		@Priorities = @Priorities,
		-- NOTE: @ExcludeSecondaries, @ExcludeRecovering, @ExcludeRestoring, @ExcludeOffline ALL default to 1 - meaning that, for backups, we want the default (we CAN'T back those databases up no matter how much we want). (Well, except for secondaries...hmm).
		@ExcludeSimpleRecovery = @excludeSimple;

	-- verify that we've got something: 
	IF (SELECT COUNT(*) FROM @targetDatabases) <= 0 BEGIN
		IF @AllowNonAccessibleSecondaries = 1 BEGIN

			IF @AlwaysProcessRetention = 1 BEGIN 
				/* S4-529: In this case, we've got synchronized servers where we're NOT pushing backups to {PARTNER}... and want to force cleanup on secondary. */
				EXEC @return = [admindb].dbo.[remove_backup_files]
					@BackupType = @BackupType,
					@DatabasesToProcess = @DatabasesToBackup,
					@DatabasesToExclude = @DatabasesToExclude,
					@TargetDirectory = @BackupDirectory,
					@Retention = @BackupRetention,
					@ForceSecondaryCleanup = N'FORCE',
					@ServerNameInSystemBackupPath = NULL,
					@SendNotifications = 1,
					@OperatorName = @OperatorName,
					@MailProfileName = @MailProfileName,
					@EmailSubjectPrefix = @EmailSubjectPrefix,
					@PrintOnly = @PrintOnly;				
				
				RETURN @return;
			  END;
			ELSE BEGIN
				-- Because we're dealing with Synchronized DBs, we won't fail or throw an error here. Instead, we'll just report success (with no DBs to backup).
				PRINT 'No ONLINE databases available for backup. BACKUP terminating with success.';
				RETURN 0;
			END;
		   END; 
		ELSE BEGIN
			PRINT 'Usage: @DatabasesToBackup = {SYSTEM}|{USER}|dbname1,dbname2,dbname3,etc';
			RAISERROR('No databases specified for backup.', 16, 1);
			RETURN -20;
		END;
	END;

	IF @BackupDirectory = @CopyToBackupDirectory BEGIN
		RAISERROR('@BackupDirectory and @CopyToBackupDirectory can NOT be the same directory.', 16, 1);
		RETURN - 50;
	END;

	-- normalize paths: 
	SET @BackupDirectory = dbo.normalize_file_path(@BackupDirectory);
	SET @CopyToBackupDirectory = dbo.normalize_file_path(@CopyToBackupDirectory);
	SET @OffSiteBackupPath = dbo.normalize_file_path(@OffSiteBackupPath);

	IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
		DECLARE @s3BucketName sysname; 
		DECLARE @s3KeyPath sysname;
		DECLARE @s3FullFileKey sysname;
		DECLARE @s3fullOffSitePath sysname;

		DECLARE @s3Parts table (row_id int NOT NULL, result nvarchar(MAX) NOT NULL);

		INSERT INTO @s3Parts (
			[row_id],
			[result]
		)
		SELECT [row_id], [result] FROM dbo.[split_string](REPLACE(@OffSiteBackupPath, N'S3::', N''), N':', 1)

		SELECT @s3BucketName = [result] FROM @s3Parts WHERE [row_id] = 1;
		SELECT @s3KeyPath = [result] FROM @s3Parts WHERE [row_id] = 2;
	END;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- meta-data:
	DECLARE @operationStart datetime;
	DECLARE @executionID uniqueidentifier = NEWID();
	
	DECLARE @currentBackupHistoryId int;
	DECLARE @executionDetails dbo.backup_history_entry;  /* TVP... */

	DECLARE @currentDatabase sysname;
	DECLARE @backupPath nvarchar(2000);
	DECLARE @copyToBackupPath nvarchar(2000);

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	DECLARE @serverName sysname;
	DECLARE @extension sysname;
	DECLARE @now datetime;
	DECLARE @timestamp sysname;
	DECLARE @offset sysname;
	DECLARE @backupName sysname;
	DECLARE @encryptionClause nvarchar(2000);

	DECLARE @ignoredResultTypes sysname;
	DECLARE @outcome xml;
	DECLARE @errorMessage nvarchar(MAX);

	DECLARE @copyStart datetime;
	DECLARE @copyDetails xml;
	DECLARE @offSiteCopyStart datetime;
	DECLARE @offSiteCopyDetails xml;

	DECLARE @cleanupErrorOccurred bit;

	DECLARE @command nvarchar(MAX);

	DECLARE backups CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name] 
	FROM 
		@targetDatabases
	ORDER BY 
		[entry_id];

	OPEN backups;

	FETCH NEXT FROM backups INTO @currentDatabase;
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		DELETE @executionDetails;
		SET @outcome = NULL;
		SET @currentBackupHistoryId = NULL;
		SET @errorMessage = NULL; 

		-- TODO: Full details here: https://overachieverllc.atlassian.net/browse/S4-107
		-- start by making sure the current DB (which we grabbed during initialization) is STILL online/accessible (and hasn't failed over/etc.): 
		DECLARE @synchronized table ([database_name] sysname NOT NULL);
		INSERT INTO @synchronized ([database_name])
		SELECT [name] FROM sys.databases WHERE UPPER(state_desc) <> N'ONLINE';  -- mirrored dbs that have failed over and are now 'restoring'... 

		-- account for SQL Server 2008/2008 R2 (i.e., pre-HADR):
		IF (SELECT dbo.[get_engine_version]()) > 11.0 BEGIN
			INSERT INTO @synchronized ([database_name])
			EXEC sp_executesql N'SELECT d.[name] FROM sys.databases d INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id WHERE hars.role_desc != ''PRIMARY'';'	
		END

		IF @currentDatabase IN (SELECT [database_name] FROM @synchronized) BEGIN
			PRINT 'Skipping database: ' + @currentDatabase + ' because it is no longer available, online, or accessible.';
			GOTO NextDatabase;  -- just 'continue' - i.e., short-circuit processing of this 'loop'... 
		END; 

		-- specify and verify path info:
		IF ((SELECT dbo.[is_system_database](@currentDatabase)) = 1) AND @AddServerNameToSystemBackupPath = 1
			SET @serverName = N'\' + REPLACE(@@SERVERNAME, N'\', N'_'); -- account for named instances. 
		ELSE 
			SET @serverName = N'';

		SET @backupPath = @BackupDirectory + N'\' + @currentDatabase + @serverName;
		SET @copyToBackupPath = REPLACE(@backupPath, @BackupDirectory, @CopyToBackupDirectory); 

		SET @operationStart = GETDATE();
		
		INSERT INTO @executionDetails (execution_id, backup_date, [database], backup_type, backup_path, copy_path, backup_start, [backup_succeeded])
		VALUES (@executionID, GETDATE(), @currentDatabase, @BackupType, @backupPath, @copyToBackupPath, @operationStart, 0);

		EXEC dbo.[log_backup_history_detail] 
			@LogSuccessfulOutcomes = @LogSuccessfulOutcomes, 
			@ExecutionDetails = @executionDetails, 
			@BackupHistoryId = @currentBackupHistoryId OUTPUT;  

		IF @RemoveFilesBeforeBackup = 1 BEGIN
			GOTO RemoveOlderFiles; 

DoneRemovingFilesBeforeBackup:
		END

		BEGIN TRY
            EXEC dbo.establish_directory
                @TargetDirectory = @backupPath, 
                @PrintOnly = @PrintOnly,
                @Error = @errorMessage OUTPUT;

			IF @errorMessage IS NOT NULL
				SET @errorMessage = N' Error verifying directory: [' + @backupPath + N']: ' + @errorMessage;

		END TRY
		BEGIN CATCH 
			SET @errorMessage = ISNULL(@errorMessage, '') + N'Exception attempting to validate file path for backup: [' + @backupPath + N']. Error: [' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N']. Backup Filepath non-valid. Cannot continue with backup.';
		END CATCH;

		-- No directory = FATAL: log and GOTO NextDatabase... 
		IF @errorMessage IS NOT NULL BEGIN 
			UPDATE @executionDetails 
			SET 
				[error_details] = ISNULL([error_details], N'') + @errorMessage + N' '
			WHERE 
				[execution_id] = @executionID;			
			
			GOTO NextDatabase;
		END;

		-----------------------------------------------------------------------------
		-- Create/Execute Backup Command:

		-- Create a Backup Name: 
		SET @extension = N'.bak';
		IF @BackupType = N'LOG'
			SET @extension = N'.trn';

		SET @now = GETDATE();
		SET @timestamp = REPLACE(REPLACE(REPLACE(CONVERT(sysname, @now, 120), '-','_'), ':',''), ' ', '_');
		SET @offset = RIGHT(N'0000' + DATENAME(MILLISECOND, @now), 4) + RIGHT(CAST(CAST(RAND() AS decimal(12,11)) AS varchar(20)),3);
		IF NULLIF(@markerOverride, N'') IS NOT NULL
			SET @offset = @markerOverride;

		SET @backupName = @BackupType + N'_' + @currentDatabase + (CASE WHEN @fileOrFileGroupDirective = '' THEN N'' ELSE N'_PARTIAL' END) + '_backup_' + @timestamp + '_' + @offset + @extension;

		SET @command = N'';
		IF @setSingleUser = 1 BEGIN 
			SET @command = N'USE ' + QUOTENAME(@currentDatabase) + N';
ALTER DATABASE ' + QUOTENAME(@currentDatabase) + N' SET SINGLE_USER WITH ROLLBACK AFTER ' + CAST(@setSingleUserRollbackSeconds AS sysname) + N' SECONDS; ';
		END;

		SET @command = @command + N'BACKUP {type} ' + QUOTENAME(@currentDatabase) + N'{FILE|FILEGROUP} TO DISK = N''' + @backupPath + N'\' + @backupName + ''' 
	WITH 
		{COPY_ONLY}{COMPRESSION}{DIFFERENTIAL}{MAXTRANSFER}{ENCRYPTION}NAME = N''' + @backupName + ''', SKIP, REWIND, NOUNLOAD, CHECKSUM;
	
	';

		IF @BackupType IN (N'FULL', N'DIFF')
			SET @command = REPLACE(@command, N'{type}', N'DATABASE');
		ELSE 
			SET @command = REPLACE(@command, N'{type}', N'LOG');

		IF @Edition IN (N'EXPRESS',N'WEB',N'WORKGROUP') OR ((SELECT dbo.[get_engine_version]()) < 10.5 AND @Edition NOT IN ('ENTERPRISE'))
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'');
		ELSE 
			SET @command = REPLACE(@command, N'{COMPRESSION}', N'COMPRESSION, ');

		IF @BackupType = N'DIFF'
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'DIFFERENTIAL, ');
		ELSE 
			SET @command = REPLACE(@command, N'{DIFFERENTIAL}', N'');

		IF @isCopyOnlyBackup = 1 
			SET @command = REPLACE(@command, N'{COPY_ONLY}', N'COPY_ONLY, ');
		ELSE 
			SET @command = REPLACE(@command, N'{COPY_ONLY}', N'');

		IF NULLIF(@EncryptionCertName, '') IS NOT NULL BEGIN
			SET @encryptionClause = ' ENCRYPTION (ALGORITHM = ' + ISNULL(@EncryptionAlgorithm, N'AES_256') + N', SERVER CERTIFICATE = ' + ISNULL(@EncryptionCertName, '') + N'), ';
			SET @command = REPLACE(@command, N'{ENCRYPTION}', @encryptionClause);
		  END;
		ELSE 
			SET @command = REPLACE(@command, N'{ENCRYPTION}','');

		-- account for 'partial' backups: 
		SET @command = REPLACE(@command, N'{FILE|FILEGROUP}', @fileOrFileGroupDirective);

		-- Account for TDE and 2016+ Compression: 
		IF EXISTS (SELECT NULL FROM sys.[dm_database_encryption_keys] WHERE [database_id] = DB_ID(@currentDatabase) AND [encryption_state] <> 0) BEGIN 

			IF (SELECT dbo.[get_engine_version]()) > 13.0
				SET @command = REPLACE(@command, N'{MAXTRANSFER}', N'MAXTRANSFERSIZE = 2097152, ');
			ELSE BEGIN 
				-- vNEXT / when adding processing-bus implementation and 'warnings' channel... output the following into WARNINGS: 
				PRINT 'Disabling Database Compression for database [' + @currentDatabase + N'] because TDE is enabled on pre-2016 SQL Server instance.';
				SET @command = REPLACE(@command, N'COMPRESSION, ', N'');
				SET @command = REPLACE(@command, N'{MAXTRANSFER}', N'');
			END;
		  END;
		ELSE BEGIN 
			SET @command = REPLACE(@command, N'{MAXTRANSFER}', N'');
		END;
		
		IF @setSingleUser = 1 BEGIN 
			IF @keepOnline = 1 BEGIN 
				PRINT '-- Directive ''KEEP_ONLINE'' was specified - NOT taking database ' + QUOTENAME(@currentDatabase) + N' offline.';
			  END; 
			ELSE BEGIN 
				SET @command = @command + N' ALTER DATABASE ' + QUOTENAME(@currentDatabase) + N' SET OFFLINE; ';
			END;
		END;

		BEGIN TRY 
			
			SET @errorMessage = NULL;
			SET @ignoredResultTypes = N'{BACKUP}';
			IF @setSingleUser = 1 SET @ignoredResultTypes = @ignoredResultTypes + N',{SINGLE_USER}';
			IF @keepOnline = 0 SET @ignoredResultTypes = @ignoredResultTypes + N',{OFFLINE}'

			EXEC dbo.[execute_command]
				@Command = @command,
				@ExecutionType = N'SQLCMD',
				@ExecutionAttemptsCount = 1,
				@IgnoredResults = @ignoredResultTypes,
				@PrintOnly = @PrintOnly,
				@Outcome = @outcome OUTPUT,
				@ErrorMessage = @errorMessage OUTPUT;
			
			IF @errorMessage IS NOT NULL 
				SET @errorMessage = N'Error with BACKUP command: ' + @errorMessage;

		END TRY 
		BEGIN CATCH 
			SET @errorMessage = N'Exception executing backup with the following command: [' + @command + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
		END CATCH;

		UPDATE @executionDetails 
		SET 
			backup_end = GETDATE(),
			backup_succeeded = CASE WHEN @errorMessage IS NULL THEN 1 ELSE 0 END, 
			verification_start = CASE WHEN @errorMessage IS NULL THEN GETDATE() ELSE NULL END, 
			[error_details] = ISNULL([error_details], N'') + @errorMessage + N' '
		WHERE 
			[execution_id] = @executionID;

		EXEC dbo.[log_backup_history_detail] 
			@LogSuccessfulOutcomes = @LogSuccessfulOutcomes, 
			@ExecutionDetails = @executionDetails, 
			@BackupHistoryId = @currentBackupHistoryId OUTPUT;  

		-- Backup failed, FATAL - already logged, so Goto NextDatabase.
		IF @errorMessage IS NOT NULL
			GOTO NextDatabase;

		-----------------------------------------------------------------------------
		-- Kick off the verification:
		SET @errorMessage = NULL;
		SET @command = N'RESTORE VERIFYONLY FROM DISK = N''' + @backupPath + N'\' + @backupName + N''' WITH NOUNLOAD, NOREWIND;';

		IF @PrintOnly = 1 
			PRINT @command;
		ELSE BEGIN
			BEGIN TRY
				EXEC sys.sp_executesql @command;
			END TRY
			BEGIN CATCH
				SET @errorMessage = N'Exception during backup verification for backup of database: [' + @currentDatabase + ']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH;
		END;

		UPDATE @executionDetails
		SET 
			verification_end = GETDATE(),
			verification_succeeded = CASE WHEN @errorMessage IS NULL THEN 1 ELSE 0 END,
			[error_details] = ISNULL([error_details], N'') + @errorMessage + N' '
		WHERE
			[execution_id] = @executionID;

		EXEC dbo.[log_backup_history_detail] 
			@LogSuccessfulOutcomes = @LogSuccessfulOutcomes, 
			@ExecutionDetails = @executionDetails, 
			@BackupHistoryId = @currentBackupHistoryId OUTPUT;  

		-- Fatal. Logged... so go next... 
		IF @errorMessage IS NOT NULL 
			GOTO NextDatabase;

		-----------------------------------------------------------------------------
		-- Now that the backup (and, optionally/ideally) verification are done, copy the file to a secondary location if specified:
		SET @errorMessage = NULL;
		SET @copyDetails = NULL;
		IF NULLIF(@CopyToBackupDirectory, N'') IS NOT NULL BEGIN
			
			SET @copyStart = GETDATE();

            BEGIN TRY 
                EXEC dbo.establish_directory
                    @TargetDirectory = @copyToBackupPath, 
                    @PrintOnly = @PrintOnly,
                    @Error = @errorMessage OUTPUT;                

                IF @errorMessage IS NOT NULL
				    SET @errorMessage = N'Error verifying COPY_TO directory: [' + @copyToBackupPath + N']: ' + @errorMessage;  

            END TRY
            BEGIN CATCH 
                SET @errorMessage = N'Exception attempting to validate COPY_TO file path for backup: [' + @copyToBackupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
            END CATCH

			IF @errorMessage IS NULL BEGIN
				
				SET @command = N'XCOPY "' + @backupPath + N'\' + @backupName + N'" "' + @copyToBackupPath + N'\" /q';  -- XCOPY supported on Windows 2003+; robocopy is supported on Windows 2008+

				BEGIN TRY 
					EXEC dbo.[execute_command]
						@Command = @command,
						@ExecutionType = N'SHELL',
						@ExecutionAttemptsCount = 2,
						@DelayBetweenAttempts = N'5 seconds',
						@IgnoredResults = N'{COPYFILE}',
						@PrintOnly = @PrintOnly,
						@Outcome = @outcome OUTPUT,
						@ErrorMessage = @errorMessage OUTPUT; 

					IF @errorMessage IS NOT NULL OR dbo.[transient_error_occurred](@outcome) = 1 
						SET @copyDetails = @outcome;

				END TRY 
				BEGIN CATCH 
					SET @errorMessage = N'Exception copying backup to [' + @copyToBackupPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
				END CATCH;
		    END;

			UPDATE @executionDetails
			SET 
				copy_succeeded = CASE WHEN @errorMessage IS NULL THEN 1 ELSE 0 END, 
				copy_seconds = DATEDIFF(SECOND, @copyStart, GETDATE()), 
				failed_copy_attempts = (SELECT @outcome.value(N'count(/iterations/iteration)', N'int')) - 1, 
				copy_details = CAST(@copyDetails AS nvarchar(MAX)), 
				[error_details] = ISNULL([error_details], N'') + @errorMessage + N' '
			WHERE 
				[execution_id] = @executionID;

			EXEC dbo.[log_backup_history_detail] 
				@LogSuccessfulOutcomes = @LogSuccessfulOutcomes, 
				@ExecutionDetails = @executionDetails, 
				@BackupHistoryId = @currentBackupHistoryId OUTPUT;  
			
			-- NON-FATAL... (if there were errors)

		END;

		-----------------------------------------------------------------------------
		-- Process @OffSite backups as necessary: 
		SET @errorMessage = NULL;
		SET @offSiteCopyDetails = NULL;
		SET @outcome = NULL;
		IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
			
			SET @offSiteCopyStart = GETDATE();

			DECLARE @offsiteCopy table ([row_id] int IDENTITY(1, 1) NOT NULL, [output] nvarchar(2000));
			DELETE FROM @offsiteCopy;

			SET @s3FullFileKey = @s3KeyPath + '\' + @currentDatabase + @serverName + N'\' + @backupName;
			SET @s3fullOffSitePath = N'S3::' + @s3BucketName + N':' + @s3FullFileKey;

			SET @command = N'Write-S3Object -BucketName ''' + @s3BucketName + N''' -Key ''' + @s3FullFileKey + N''' -File ''' + @backupPath + N'\' + @backupName + N''' -ConcurrentServiceRequest 2';

			BEGIN TRY 
				EXEC dbo.[execute_command]
					@Command = @command,
					@ExecutionType = N'POSH',
					@ExecutionAttemptsCount = 3,
					@DelayBetweenAttempts = N'3 seconds',
					@IgnoredResults = N'{S3COPYFILE}',
					@PrintOnly = @PrintOnly,
					@Outcome = @outcome OUTPUT,
					@ErrorMessage = @errorMessage OUTPUT

			END TRY 
			BEGIN CATCH
				SET @errorMessage = N'Exception copying backup to OffSite Location [' + @s3fullOffSitePath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
			END CATCH;

			IF @errorMessage IS NOT NULL OR dbo.[transient_error_occurred](@outcome) = 1 BEGIN
				SET @offSiteCopyDetails = @outcome;
			END;

			UPDATE @executionDetails
			SET 
				offsite_path = @s3fullOffSitePath,
				offsite_succeeded = CASE WHEN @errorMessage IS NULL THEN 1 ELSE 0 END,
				offsite_seconds = DATEDIFF(SECOND, @offSiteCopyStart, GETDATE()), 
				failed_offsite_attempts = ((SELECT @outcome.value(N'count(/iterations/iteration)', N'int')) - (CASE WHEN @errorMessage IS NULL THEN 0 ELSE 1 END)), 
				offsite_details = CAST(@offSiteCopyDetails AS nvarchar(MAX)), 
				[error_details] = ISNULL([error_details], N'') + @errorMessage + N' '
			WHERE
				[execution_id] = @executionID;

			EXEC dbo.[log_backup_history_detail] 
				@LogSuccessfulOutcomes = @LogSuccessfulOutcomes, 
				@ExecutionDetails = @executionDetails, 
				@BackupHistoryId = @currentBackupHistoryId OUTPUT;  

			-- NON-FATAL... (if there were errors)

		END;

		-----------------------------------------------------------------------------
		-- Remove backups:
		IF @RemoveFilesBeforeBackup = 0 BEGIN;
RemoveOlderFiles:
			SET @cleanupErrorOccurred = 0;
			SET @errorMessage = NULL;
			BEGIN TRY
				
				EXEC dbo.[remove_backup_files]
                    @BackupType = @BackupType,
                    @DatabasesToProcess = @currentDatabase,
                    @TargetDirectory = @BackupDirectory,
                    @Retention = @BackupRetention, 
					@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
					@OperatorName = @OperatorName,
					@MailProfileName  = @DatabaseMailProfile,
					@Output = @errorMessage OUTPUT, 
					@PrintOnly = @PrintOnly;

			END TRY 
			BEGIN CATCH 
				SET @errorMessage = ISNULL(@errorMessage, '') + 'Exception removing backups. Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
			END CATCH;

			IF @errorMessage IS NOT NULL BEGIN
				UPDATE @executionDetails SET [error_details] = ISNULL([error_details], N'') + @errorMessage + N' ' WHERE [execution_id] = @executionID;
				SET @cleanupErrorOccurred = 1;
			END;
			
			IF NULLIF(@CopyToBackupDirectory,'') IS NOT NULL BEGIN;
				SET @errorMessage = NULL;

				BEGIN TRY 
					EXEC dbo.remove_backup_files
						@BackupType= @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@TargetDirectory = @CopyToBackupDirectory,
						@Retention = @CopyToRetention, 
						@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
						@OperatorName = @OperatorName,
						@MailProfileName  = @DatabaseMailProfile,
						@Output = @errorMessage OUTPUT, 
						@PrintOnly = @PrintOnly;

				END TRY 
				BEGIN CATCH 
					SET @errorMessage = ISNULL(@errorMessage, '') + 'Exception removing COPY_TO backups. Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
				END CATCH;
				
				IF @errorMessage IS NOT NULL BEGIN
					UPDATE @executionDetails SET [error_details] = ISNULL([error_details], N'') + @errorMessage + N' ' WHERE [execution_id] = @executionID;
					SET @cleanupErrorOccurred = 1;
				END;
					
			END;

			IF NULLIF(@OffSiteBackupPath, N'') IS NOT NULL BEGIN 
				SET @errorMessage = NULL;
		
				BEGIN TRY 
					EXEC dbo.[remove_offsite_backup_files]
						@BackupType = @BackupType,
						@DatabasesToProcess = @currentDatabase,
						@OffSiteBackupPath = @OffSiteBackupPath,
						@OffSiteRetention = @OffSiteRetention,
						@ServerNameInSystemBackupPath = @AddServerNameToSystemBackupPath,
						@OperatorName = @OperatorName,
						@MailProfileName = @DatabaseMailProfile,
						@Output = @errorMessage OUTPUT, 
						@PrintOnly = @PrintOnly;

				END TRY 
				BEGIN CATCH 
					SET @errorMessage = ISNULL(@errorMessage, '') + 'Exception removing OFFSITE backups. Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
				END CATCH;

				IF @errorMessage IS NOT NULL BEGIN
					UPDATE @executionDetails SET [error_details] = ISNULL([error_details], N'') + @errorMessage + N' ' WHERE [execution_id] = @executionID;
					SET @cleanupErrorOccurred = 1;
				END;

			END;

			IF @RemoveFilesBeforeBackup = 1 BEGIN;
				IF @cleanupErrorOccurred = 0 -- there weren't any problems/issues - so keep processing.
					GOTO DoneRemovingFilesBeforeBackup;

				-- otherwise, the remove operations failed, they were set to run FIRST, which means we now might not have enough disk - so we need to 'fail' this operation and move on to the next db... 
				GOTO NextDatabase;
			END
		END

NextDatabase:
		EXEC dbo.[log_backup_history_detail] 
			@LogSuccessfulOutcomes = @LogSuccessfulOutcomes, 
			@ExecutionDetails = @executionDetails, 
			@BackupHistoryId = @currentBackupHistoryId OUTPUT;  

		PRINT '
';

		IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
			CLOSE nuker;
			DEALLOCATE nuker;
		END;

		FETCH NEXT FROM backups INTO @currentDatabase;
	END;

	CLOSE backups;
	DEALLOCATE backups;

	----------------------------------------------------------------------------------------------------------------------------------------------------------
	-----------------------------------------------------------------------------
	-- Cleanup:

	-- close/deallocate any cursors left open:
	IF (SELECT CURSOR_STATUS('local','backups')) > -1 BEGIN;
		CLOSE backups;
		DEALLOCATE backups;
	END;

	-- MKC:
--			need to add some additional logic/processing here. 
--			a) look for failed copy operations up to X hours ago? 
--		    b) try to re-run them - via dba_sync... or ... via 'raw' roboopy? hmmm. 
--			c) mark any that succeed as done... success. 
--			d) up-tick any that still failed. 
--			e) for any that exceed @maxCopyToRetries - create an error and log it against all previous rows/databases that have failed? hmmm. Yeah... if we've been failing for, say, 45 minutes and sending 'warnings'... then we want to 
--				'call it' for all of the ones that have failed up to this point... and flag them as 'errored out' (might require a new column in the table). OR... maybe it works by me putting something like the following into error details
--				(for ALL rows that have failed up to this point - i.e., previous attempts + the current attempt/iteration):
--				"Attempts to copy backups from @sourcePath to @copyToPath consistently failed from @backupEndTime to @now (duration?) over @MaxSomethingAttempts. No longer attempting to synchronize files - meaning that backups are in jeopardy. Please
--					fix @CopyToPath and, when complete, run dba_syncDbs with such and such arguments? to ensure dbs copied on to secondary...."
--			   because, if that happens... then... the 'history' for backups will show errors (whereas they didn't show/report errors previously - so that covers 'history' - with a summary of when we 'called it'... 
--				and, this covers... the current rows as well. i.e., they'll have errors... which will then get picked up by the logic below. 
--			f) for any true 'errors', those get picked up below. 
--			g) for any non-errors - but failures to copy, there needs to be a 'warning' email sent - with a summary (list) of each db that hasn't copied - current number of attempts, how long it's been, etc. 

	DECLARE @emailErrorMessage nvarchar(MAX);

	IF EXISTS (SELECT NULL FROM dbo.backup_log WHERE execution_id = @executionID AND error_details IS NOT NULL) BEGIN;
		SET @emailErrorMessage = N'BACKUP TYPE: ' + @BackupType + @crlf
			+ N'TARGETS: ' + @DatabasesToBackup + @crlf
			+ @crlf 
			+ N'The following errors were encountered: ' + @crlf;

		SELECT @emailErrorMessage = @emailErrorMessage + @tab + N'- Target Database: [' + [database] + N']. Error: ' + error_details + @crlf + @crlf
		FROM 
			dbo.backup_log
		WHERE 
			execution_id = @executionID
			AND error_details IS NOT NULL 
		ORDER BY 
			backup_id;

	END;

	DECLARE @emailSubject nvarchar(2000);
	IF @emailErrorMessage IS NOT NULL BEGIN;
		
		IF RIGHT(@EmailSubjectPrefix, 1) <> N' ' SET @EmailSubjectPrefix = @EmailSubjectPrefix + N' ';
		SET @emailSubject = @EmailSubjectPrefix + N'- ' + @BackupType + N' - ERROR';
		SET @emailErrorMessage = @emailErrorMessage + @crlf + @crlf + N'Execute [ SELECT * FROM [admindb].dbo.backup_log WHERE execution_id = ''' + CAST(@executionID AS nvarchar(36)) + N'''; ] for details.';

		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
			PRINT @emailErrorMessage;
		  END;
		ELSE BEGIN 

			IF UPPER(@Edition) <> N'EXPRESS' BEGIN;
				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @emailErrorMessage;
			END;

		END;
	END;

	RETURN 0;
GO