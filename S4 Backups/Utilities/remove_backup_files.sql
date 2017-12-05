


/*
	DEPENDENCIES:
		- Requires dbo.execute_uncatchable_command - for low-level file-interactions and 'capture' of errors (since try/catch no worky).
		- Requires dbo.check_paths - sproc to verify that paths are valid. 
		- Requires dbo.load_database_names - sproc that centralizes handling of which dbs/folders to process.
		- Requires dbo.split_string - udf to parse the above.
		- Requires that xp_cmdshell must be enabled.

	NOTES:
		- WARNING: This script does what it says - it'll remove files exactly as specified. 

		- BUG? 
			May be an issue where using xp_delete_file MIGHT be causing issues with directories. 
			Specifically:
				on Windows Server 2012R2 and 2016... if there's a folder ... and it has files... 
				and we run xp_delete_file against said folder.... 
				THEN get to a point where ALL files in that folder are gone/deleted (either xp_delete_file removes all folders OR we manually delete everything)
					then there's an 'Access Denied' issue - where the folder can't be accessed or DELETED at ALL - until a reboot. 
						And... once the reboot happens... the folders aren't there anymore. 

						It's ALSO possible that xp_create_subdir is causing the problem... i.e., it MIGHT not be an issue with deleting files - it could be that file-creation had some weird issues... 
							in which case... i'll need to use cd or something - along with ensuring that we get the right perms... 

				IF i can confirm that this is being caused by xp_delete_file... 
					I'm going to have to do something different - like:
						a) RESTORE FILEHEADER ONLY.... 
							get the time in question... 
						b) DOS delete the thing... IF it should be deleted... 


		- Not yet documented. 
			-	Behaves, essentially, like dba_BackupDatabases - only it doesn't do backups... it just removes files from ONE root directory for 1st level of child directories NOT excluded. 
			- Main Differences:
				- @RetentionMINUTES - not Hours. 
				- @SendNotifications - won't send notifications unless set to 1. 

	FODDER:
		xp_dirtree:
			http://www.sqlservercentral.com/blogs/everyday-sql/2012/12/31/how-to-use-xp_dirtree-to-list-all-files-in-a-folder-part-2/
			http://stackoverflow.com/questions/26750054/xp-dirtree-in-sql-server


	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple

	Scalable:
		1.5+
*/



/*


EXEC dbo.remove_backup_files 
	@BackupType = 'FULL', -- sysname
    @DatabasesToProcess = N'[READ_FROM_FILESYSTEM]', -- nvarchar(1000)
    @DatabasesToExclude = N'', -- nvarchar(600)
    @TargetDirectory = N'D:\SQLBackups', -- nvarchar(2000)
    @Retention = '12m', -- int
    @PrintOnly = 1 -- bit

*/

USE [admindb];
GO

IF OBJECT_ID('[dbo].[remove_backup_files]','P') IS NOT NULL
	DROP PROC [dbo].[remove_backup_files];
GO

CREATE PROC [dbo].[remove_backup_files] 
	@BackupType							sysname,						-- { ALL | FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),					-- { [READ_FROM_FILESYSTEM] | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600) = NULL,			-- { NULL | name1,name2 }  
	@TargetDirectory					nvarchar(2000),					-- { path_to_backups }
	@Retention							nvarchar(10),					-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@Output								nvarchar(MAX) = NULL OUTPUT,	-- When set to non-null value, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@SendNotifications					bit	= 0,						-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname = N'Alerts',		
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Backups Cleanup ] ',
	@PrintOnly							bit = 0 						-- { 0 | 1 }
AS
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.execute_uncatchable_command', 'P') IS NULL BEGIN;
		RAISERROR('S4 Stored Procedure dbo.execute_uncatchable_command not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN;
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN;
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN;
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN;
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN;
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF ((@PrintOnly = 0) OR (@Output IS NULL)) AND (@Edition != 'EXPRESS') BEGIN; -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN;
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN; 
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN;
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN;
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN;
		RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
		RETURN -6;
	END;

	IF UPPER(@BackupType) NOT IN ('FULL', 'DIFF', 'LOG', 'ALL') BEGIN;
		PRINT 'Usage: @BackupType = FULL|DIFF|LOG';
		RAISERROR('Invalid @BackupType Specified.', 16, 1);

		RETURN -7;
	END;

	SET @Retention = LTRIM(RTRIM(@Retention));
	DECLARE @retentionType char(1);
	DECLARE @retentionValue int;

	SET @retentionType = LOWER(RIGHT(@Retention,1));

	-- Only approved values are allowed: (m[inutes], [h]ours, [d]ays, [b]ackups (a specific count)). 
	IF @retentionType NOT IN ('m','h','d','w','b') BEGIN 
		RAISERROR('Invalid @Retention value specified. @Retention must take the format of #L - where # is a positive integer, and L is a SINGLE letter [m | h | d | w | b] for minutes, hours, days, weeks, or backups (i.e., a specific number of most recent backups to retain).', 16, 1);
		RETURN -10000;	
	END 

	-- a WHOLE lot of negation going on here... but, this is, insanely, right:
	IF NOT EXISTS (SELECT 1 WHERE LEFT(@Retention, LEN(@Retention) - 1) NOT LIKE N'%[^0-9]%') BEGIN 
		RAISERROR('Invalid @Retention specified defined (more than one non-integer value found in @Retention value). Please specify an integer and then either [ m | h | d | w | b ] for minutes, hours, days, weeks, or backups (specific number of most recent backups) to retain.', 16, 1);
		RETURN -10001;
	END
	
	SET @retentionValue = CAST(LEFT(@Retention, LEN(@Retention) -1) AS int);

	IF @retentionType = 'b'
		PRINT 'Retention specification is to keep the last ' + CAST(@retentionValue AS sysname) + ' backup(s).';
	ELSE 
		PRINT 'Retention specification is to remove backups more than ' + CAST(@retentionValue AS sysname) + CASE @retentionType WHEN 'm' THEN ' minutes ' WHEN 'h' THEN ' hour(s) ' WHEN 'd' THEN ' day(s) ' ELSE ' week(s) ' END + 'old.';

	DECLARE @retentionCutoffTime datetime = NULL; 
	IF @retentionType != 'b' BEGIN
		IF @retentionType = 'm'
			SET @retentionCutoffTime = DATEADD(MINUTE, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'h'
			SET @retentionCutoffTime = DATEADD(HOUR, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'd'
			SET @retentionCutoffTime = DATEADD(DAY, 0 - @retentionValue, GETDATE());

		IF @retentionType = 'w'
			SET @retentionCutoffTime = DATEADD(WEEK, 0 - @retentionValue, GETDATE());
		
		IF @RetentionCutoffTime >= GETDATE() BEGIN; 
			 RAISERROR('Invalid @Retention specification. Specified value is in the future.', 16, 1);
			 RETURN -10;
		END;		
	END

	-- normalize paths: 
	IF(RIGHT(@TargetDirectory, 1) = '\')
		SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

	-- verify that path exists:
	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN;
		RAISERROR('Invalid @TargetDirectory specified - either the path does not exist, or SQL Server''s Service Account does not have permissions to access the specified directory.', 16, 1);
		RETURN -10;
	END

	-----------------------------------------------------------------------------
	DECLARE @routeInfoAsOutput bit = 0;
	IF @Output IS NOT NULL 
		SET @routeInfoAsOutput = 1; 

	SET @Output = NULL;

	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToProcess,
	    @Exclusions = @DatabasesToExclude,
	    @Mode = N'REMOVE',
	    @BackupType = @BackupType, 
		@TargetDirectory = @TargetDirectory,
		@Output = @serialized OUTPUT;

	DECLARE @targetDirectories table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [directory_name] sysname NOT NULL
    ); 

	INSERT INTO @targetDirectories ([directory_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	-----------------------------------------------------------------------------
	-- Process files for removal:

	DECLARE @currentDirectory sysname;
	DECLARE @command nvarchar(MAX);
	DECLARE @targetPath nvarchar(512);
	DECLARE @outcome varchar(4000);
	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @file nvarchar(512);

	DECLARE @files table (
		id int IDENTITY(1,1),
		subdirectory nvarchar(512), 
		depth int, 
		isfile bit
	);

	DECLARE @lastN table ( 
		id int IDENTITY(1,1) NOT NULL, 
		original_id int NOT NULL, 
		backup_name nvarchar(512), 
		backup_type sysname
	);

	DECLARE @errors table (
		error_id int IDENTITY(1,1) NOT NULL, 
		[error_message] nvarchar(MAX) NOT NULL
	);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		directory_name
	FROM 
		@targetDirectories
	ORDER BY 
		[entry_id];

	OPEN processor;

	FETCH NEXT FROM processor INTO @currentDirectory;

	WHILE @@FETCH_STATUS = 0 BEGIN;
		
		SET @targetPath = @TargetDirectory + N'\' + @currentDirectory;

		SET @errorMessage = NULL;
		SET @outcome = NULL;

		IF @retentionType = 'b' BEGIN -- Remove all backups of target type except the most recent N (where N is @retentionValue).
			
			-- clear out any state from previous iterations.
			DELETE FROM @files;
			DELETE FROM @lastN;

			SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

			IF @PrintOnly = 1
				PRINT N'--' + @command;

			INSERT INTO @files (subdirectory, depth, isfile)
			EXEC sys.sp_executesql @command;

			-- Remove non-matching files/entries:
			DELETE FROM @files WHERE isfile = 0; -- remove directories.

			IF @BackupType IN ('LOG', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'LOG'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'LOG%.trn'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN
					DELETE FROM @files WHERE subdirectory NOT LIKE '%.trn';  -- if we're NOT doing all, then remove DIFF and FULL backups... 
				END;
			END;

			IF @BackupType IN ('FULL', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'FULL'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'FULL%.bak'
				ORDER BY 
					id DESC;

				IF @BackupType != 'ALL' BEGIN 
					DELETE FROM @files WHERE subdirectory NOT LIKE 'FULL%.bak'; -- if we're NOT doing all, then remove all non-FULL backups...  
				END
			END;

			IF @BackupType IN ('DIFF', 'ALL') BEGIN
				INSERT INTO @lastN (original_id, backup_name, backup_type)
				SELECT TOP (@retentionValue)
					id, 
					subdirectory, 
					'DIFF'
				FROM 
					@files
				WHERE 
					subdirectory LIKE 'DIFF%.bak'
				ORDER BY 
					id DESC;

					IF @BackupType != 'ALL' BEGIN 
						DELETE FROM @files WHERE subdirectory NOT LIKE 'DIFF%.bak'; -- if we're NOT doing all, the remove non-DIFFs so they won't be nuked.
					END
			END;
			
			-- prune any/all files we're supposed to keep: 
			DELETE x 
			FROM 
				@files x 
				INNER JOIN @lastN l ON x.id = l.original_id AND x.subdirectory = l.backup_name;

			-- and delete all, enumerated, files that are left:
			DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
			SELECT subdirectory FROM @files ORDER BY id;

			OPEN nuker;
			FETCH NEXT FROM nuker INTO @file;

			WHILE @@FETCH_STATUS = 0 BEGIN;

				-- reset per each 'grab':
				SET @errorMessage = NULL;
				SET @outcome = NULL

				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), GETDATE(), 120), ' ', 'T') + ''', 0;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN; 

					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting backup [' + @file + N'] from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();
					END CATCH

				END;

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END

				FETCH NEXT FROM nuker INTO @file;

			END;

			CLOSE nuker;
			DEALLOCATE nuker;
		  END;
		ELSE BEGIN -- Any backups older than @RetentionCutoffTime are removed. 

			IF @BackupType IN ('LOG', 'ALL') BEGIN;
			
				SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + ''', N''trn'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 1;';

				IF @PrintOnly = 1 
					PRINT @command;
				ELSE BEGIN 
					BEGIN TRY
						EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;

						IF @outcome IS NOT NULL 
							SET @errorMessage = ISNULL(@errorMessage, '') + @outcome + N' ';

					END TRY 
					BEGIN CATCH
						SET @errorMessage = ISNULL(@errorMessage, '') + N'Unexpected error deleting older LOG backups from [' + @targetPath + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE();

					END CATCH;				
				END

				IF @errorMessage IS NOT NULL BEGIN;
					SET @errorMessage = ISNULL(@errorMessage, '') + N' [Command: ' + @command + N']';

					INSERT INTO @errors ([error_message])
					VALUES (@errorMessage);
				END
			END

			IF @BackupType IN ('FULL', 'DIFF', 'ALL') BEGIN;

				-- start by clearing any previous values:
				DELETE FROM @files;
				SET @command = N'EXEC master.sys.xp_dirtree ''' + @targetPath + ''', 1, 1;';

				IF @PrintOnly = 1
					PRINT N'--' + @command;

				INSERT INTO @files (subdirectory, depth, isfile)
				EXEC sys.sp_executesql @command;

				DELETE FROM @files WHERE isfile = 0; -- remove directories.
				DELETE FROM @files WHERE subdirectory NOT LIKE '%.bak'; -- remove (from processing) any files that don't use the .bak extension. 

				-- If a specific backup type is specified ONLY target that backup type:
				IF @BackupType != N'ALL' BEGIN;
				
					IF @BackupType = N'FULL'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'FULL%';

					IF @BackupType = N'DIFF'
						DELETE FROM @files WHERE subdirectory NOT LIKE N'DIFF%';
				END

				DECLARE nuker CURSOR LOCAL FAST_FORWARD FOR 
				SELECT subdirectory FROM @files WHERE isfile = 1 AND subdirectory NOT LIKE '%.trn' ORDER BY id;

				OPEN nuker;
				FETCH NEXT FROM nuker INTO @file;

				WHILE @@FETCH_STATUS = 0 BEGIN;

					-- reset per each 'grab':
					SET @errorMessage = NULL;
					SET @outcome = NULL

					SET @command = N'EXECUTE master.sys.xp_delete_file 0, N''' + @targetPath + N'\' + @file + ''', N''bak'', N''' + REPLACE(CONVERT(nvarchar(20), @RetentionCutoffTime, 120), ' ', 'T') + ''', 0;';

					IF @PrintOnly = 1 
						PRINT @command;
					ELSE BEGIN; 

						BEGIN TRY
							EXEC dbo.execute_uncatchable_command @command, 'DELETEFILE', @result = @outcome OUTPUT;
						
							IF @outcome IS NOT NULL 
								SET @errorMessage = ISNULL(@errorMessage, '')  + @outcome + N' ';

						END TRY 
						BEGIN CATCH
							SET @errorMessage = ISNULL(@errorMessage, '') +  N'Error deleting DIFF/FULL Backup with command: [' + ISNULL(@command, '##NOT SET YET##') + N']. Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
						END CATCH

					END;

					IF @errorMessage IS NOT NULL BEGIN;
						SET @errorMessage = ISNULL(@errorMessage, '') + '. Command: [' + ISNULL(@command, '#EMPTY#') + N']. ';

						INSERT INTO @errors ([error_message])
						VALUES (@errorMessage);
					END

					FETCH NEXT FROM nuker INTO @file;
				END;

				CLOSE nuker;
				DEALLOCATE nuker;

		    END
		END;

		FETCH NEXT FROM processor INTO @currentDirectory;
	END

	CLOSE processor;
	DEALLOCATE processor;

	-----------------------------------------------------------------------------
	-- Cleanup:
	IF (SELECT CURSOR_STATUS('local','nuker')) > -1 BEGIN;
		CLOSE nuker;
		DEALLOCATE nuker;
	END;

	-----------------------------------------------------------------------------
	-- Error Reporting:
	DECLARE @errorInfo nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	IF EXISTS (SELECT NULL FROM @errors) BEGIN;
		
		-- format based on output type (output variable or email/error-message), then 'raise, return, or send'... 
		IF @routeInfoAsOutput = 1 BEGIN;
			SELECT @errorInfo = @errorInfo + [error_message] + N', ' FROM @errors ORDER BY error_id;
			SET @errorInfo = LEFT(@errorInfo, LEN(@errorInfo) - 2);

			SET @output = @errorInfo;
		  END
		ELSE BEGIN;

			SELECT @errorInfo = @errorInfo + @tab + N'- ' + [error_message] + @crlf + @crlf
			FROM 
				@errors
			ORDER BY 
				error_id;

			IF (@SendNotifications = 1) AND (@Edition != 'EXPRESS') BEGIN;
				DECLARE @emailSubject nvarchar(2000);
				SET @emailSubject = @EmailSubjectPrefix + N' - ERROR';

				SET @errorInfo = N'The following errors were encountered: ' + @crlf + @errorInfo;

				EXEC msdb..sp_notify_operator
					@profile_name = @MailProfileName,
					@name = @OperatorName,
					@subject = @emailSubject, 
					@body = @errorInfo;				
			END

			-- this is being executed as a stand-alone job (most likely) so... throw the output into the job's history... 
			PRINT @errorInfo;  
			
			RAISERROR(@errorMessage, 16, 1);
			RETURN -100;
		END
	END;

	RETURN 0;
GO