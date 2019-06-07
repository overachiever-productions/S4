/*

	TODO: 
		- this current implementation is, in some ways, an MVP. Specifically, there are some known problems/issues/tweaks that should be made to get this up to speed: 
			- For starters, I need to 'finish' this - right now it just spits out SELECTs from both of the 'temp tables' it uses along the way. Instead, I need to output some sort of summary or whatever... 
				and, of course, it needs to be able to send this 'output' as an email - in the sense of "These dbs were shrunk..." and "these were not for the following reasons..." 
			- Then, STILL having some issues and problems with sizing issues.
				case in point: I had a 7GB t-log that I wanted to shrink to 63xx or somethign like that - but, nope, got the whole "is larger than the start of the last logical log file"... 
					but, i was able to knock it down to 5GB no problem (as in, no additional log-file backups, no checkpoint - NUFFIN: just a smaller attempted size). 
						and, i repeated that again - it wouldn't go with 4xxx but 4000 had no problems, and it wouldn't do 3xx but 200 was FINE, and then 20, and then 2... 

						so. I've got to get a better handle on that. 
							possibly? wire in some logic that has an @DecrementSize or whatever that we try to use when trying to shrink 'lower and lower' through subsequent operations... or something like that. 
								and... not sure why DBCC LOGINF() and status 2 ... was 'lying' to me in these cases. (Well, it wasn't 'lying' - but there's got to be a way to figure out what's up based on dbcc logfile info ... 

								some potential fodder: 
									http://sqlblog.com/blogs/kalen_delaney/archive/2009/12/21/exploring-the-transaction-log-structure.aspx
											https://www.mssqltips.com/sqlservertip/3491/determine-minimum-possible-size-to-shrink-the-sql-server-transaction-log-file/

									https://stackoverflow.com/questions/7193445/dbcc-shrinkfile-on-log-file-not-reducing-size-even-after-backup-log-to-disk
										the 2nd answer (non-destructive) is ... what i'm doing but it's not 'as simple' as 'advertised'... 


			- I've also got an 'issue' in terms of workflow where, currently, the entire idea of the work flow is: 
						a) get a list of dbs to process. 
						b) mark them with whatever operations they need (nothing, shrink, or 'enchilada'). 
						c) IF there are any enchiladas... checkpoint and wait... 
						d) then, once we either time out or get a NOT EXISTS on checks for dbs we're waiting against, then... 
						e) we try to shrink... 
						f) and we're done. 

				I think a better workflow might be to: 
						a) get the list. 
						b) mark them as i'm doing now. 
						c) potentially ALWAYS do a CHECKPOINT (i.e., pssibly just run it 'regardless' - because i can see it being 'needed' in a buch of scenarios. 
							and, the way i account for this is: i) run it WITHOUT this approach for a while and watch how many errors/issues/problems arise. 
									then, ii) run it 'always' and see if any of those errors decrease and/or 'go away'. 

						d) instead of 'wait all' and then 'shrink all'... try a different approach (that's a bit more complicated, obviously). 
							  1. for any all that are at 'shrink' stage (i.e., NOT waiting on LOG backup) ... go ahead and run a sproc called dbo.shrink_logfile - against the targetDB, with the target size, the number of times to try, and the 'decrement' size to try if/as there are any 'size is larger than last logical'... type issues. 
							  2. as we wait and detect/mark that new dbs are ready to shrink (i.e., their t-log backups have been processed), then they get processed as above... 
							  3. after we get done WAITING (either cuz we hit 0 dbs left to wait on or cuz we time out), we retry ? any that haven't completely succeeded at this point (and dbs don't get marked as succeeded unless dbo.shrink_logfile reports that @currentSize = @targetSize + or - @BufferSize (i.e., 'close enough')... 
									that way there's a final pass/attempt at the end - which isn't going to make any difference for ... those that are waiting on a t-log backup... hmmm... or any others. 

									FINE. so i don't do a final 'pass for the hell of it' - there's no point. 
									BUT, i do make it so that dbo.shrink_logfile is a bit more intelligent - as in, it can 'decrement', it can 'retry', and it'll tell us if we were able to shrink to the TARGET size desired (plus/minus the @BufferSize) when it's all said 
										and done... (and, of course, it'll simply report an 'output' and the RETURN value will indicate 0 or non-zero relative to 'success' or not. 








*/

USE [admindb];
GO

IF OBJECT_ID('dbo.shrink_logfiles','P') IS NOT NULL
	DROP PROC dbo.shrink_logfiles;
GO

CREATE PROC dbo.shrink_logfiles
	@TargetDatabases							nvarchar(MAX),																		-- { [SYSTEM]|[USER]|name1,name2,etc }
	@DatabasesToExclude							nvarchar(MAX)							= NULL,										-- { NULL | name1,name2 }  
	@Priorities									nvarchar(MAX)							= NULL,										
	@TargetLogPercentageSize					int										= 20,										-- can be > 100? i.e., 200? would be 200% - which ... i guess is legit, right? 
	@ExcludeSimpleRecoveryDatabases				bit										= 1,										
	@IgnoreLogFilesSmallerThanGBs				decimal(5,2)							= 0.25,										-- e.g., don't bother shrinking anything > 200MB in size... 								
	@LogFileSizingBufferInGBs					decimal(5,2)							= 0.25,										-- a) when targetting a log for DBCC SHRINKFILE() add this into the target and b) when checking on dbs POST shrink, if they're under target + this Buffer, they're FINE/done/shrunk/ignored.
	@MaxTimeToWaitForLogBackups					sysname									= N'20m',		
	@LogBackupCheckPollingInterval				sysname									= N'40s',									-- Interval that defines how long to wait between 'polling' attempts to look for new T-LOG backups... 
	@OperatorName								sysname									= N'Alerts',
	@MailProfileName							sysname									= N'General',
	@EmailSubjectPrefix							nvarchar(50)							= N'[Log Shrink Operations ] ',
	@PrintOnly									bit										= 0
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Dependencies:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:

	DECLARE @maxSecondsToWaitForLogFileBackups int; 
	DECLARE @error nvarchar(MAX);
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	EXEC dbo.[translate_vector]
	    @Vector = @MaxTimeToWaitForLogBackups,
	    @ValidationParameterName = N'@MaxTimeToWaitForLogBackups',
		@ProhibitedIntervals = N'MILLISECOND, DAY, WEEK, MONTH, QUARTER, YEAR',
	    @TranslationDatePart = N'SECOND',
	    @Output = @maxSecondsToWaitForLogFileBackups OUTPUT,
	    @Error = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN -10;
	END; 

	DECLARE @waitDuration sysname;
	EXEC dbo.[translate_vector_delay]
	    @Vector = @LogBackupCheckPollingInterval,
	    @ParameterName = N'@LogBackupCheckPollingInterval',
	    @Output = @waitDuration OUTPUT,
	    @Error = @error OUTPUT;
	
	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1); 
		RETURN -11;
	END; 

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @targetRatio decimal(6,2) = @TargetLogPercentageSize / 100.0;
	DECLARE @BufferMBs int = CAST((@LogFileSizingBufferInGBs * 1024.0) AS int);  

	-- get a list of dbs to target/review: 
	CREATE TABLE #logSizes (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[recovery_model] sysname NOT NULL,
		[database_size_gb] decimal(20,2) NOT NULL, 
		[log_size_gb] decimal(20,2) NOT NULL, 
		[log_percent_used] decimal(5,2) NOT NULL,
		[initial_min_allowed_gbs] decimal(20,2) NOT NULL, 
		[target_log_size] decimal(20,2) NOT NULL, 
		[operation] sysname NULL, 
		[last_log_backup] datetime NULL, 
		[processing_complete] bit NOT NULL DEFAULT (0)
	);

	CREATE TABLE #operations (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[timestamp] datetime NOT NULL DEFAULT(GETDATE()), 
		[operation] nvarchar(2000) NOT NULL, 
		[outcome] nvarchar(MAX) NOT NULL, 
	);

	DECLARE @SerializedOutput xml = '';
	EXEC dbo.[list_logfile_sizes]
	    @TargetDatabases = @TargetDatabases,
	    @DatabasesToExclude = @DatabasesToExclude,
	    @Priorities = @Priorities,
	    @ExcludeSimpleRecoveryDatabases = @ExcludeSimpleRecoveryDatabases,
	    @SerializedOutput = @SerializedOutput OUTPUT;
	
	WITH shredded AS ( 
		SELECT 
			[data].[row].value('database_name[1]', 'sysname') [database_name], 
			[data].[row].value('recovery_model[1]', 'sysname') recovery_model, 
			[data].[row].value('database_size_gb[1]', 'decimal(20,1)') database_size_gb, 
			[data].[row].value('log_size_gb[1]', 'decimal(20,1)') log_size_gb,
			[data].[row].value('log_percent_used[1]', 'decimal(5,2)') log_percent_used, 
			--[data].[row].value('vlf_count[1]', 'int') vlf_count,
			--[data].[row].value('log_as_percent_of_db_size[1]', 'decimal(5,2)') log_as_percent_of_db_size,
			[data].[row].value('mimimum_allowable_log_size_gb[1]', 'decimal(20,1)') [initial_min_allowed_gbs]
		FROM 
			@SerializedOutput.nodes('//database') [data]([row])
	), 
	targets AS ( 
		SELECT
			[database_name],
			CAST(([shredded].[database_size_gb] * @targetRatio) AS decimal(20,2)) [target_log_size] 
		FROM 
			[shredded]
	) 
	
	INSERT INTO [#logSizes] ( [database_name], [recovery_model], [database_size_gb], [log_size_gb], [log_percent_used], [initial_min_allowed_gbs], [target_log_size])
	SELECT 
		[s].[database_name],
        [s].[recovery_model],
        [s].[database_size_gb],
        [s].[log_size_gb],
        [s].[log_percent_used],
        [s].[initial_min_allowed_gbs] [starting_mimimum_allowable_log_size_gb], 
		CAST((CASE WHEN t.[target_log_size] < @IgnoreLogFilesSmallerThanGBs THEN @IgnoreLogFilesSmallerThanGBs ELSE t.[target_log_size] END) AS decimal(20,2)) [target_log_size]
	FROM 
		[shredded] s 
		INNER JOIN [targets] t ON [s].[database_name] = [t].[database_name];

	WITH operations AS ( 
		SELECT 
			[database_name], 
			CASE 
				WHEN [log_size_gb] <= [target_log_size] THEN 'NOTHING' -- N'N/A - Log file is already at target size or smaller. (Current Size: ' + CAST([log_size_gb] AS sysname) + N' GB - Target Size: ' + CAST([target_log_size] AS sysname) + N' GB)'
				ELSE CASE 
					WHEN [initial_min_allowed_gbs] <= ([target_log_size] + @LogFileSizingBufferInGBs) THEN 'SHRINK'
					ELSE N'CHECKPOINT + BACKUP + SHRINK'
				END
			END [operation]
		FROM 
			[#logSizes]
	) 

	UPDATE x 
	SET 
		x.[operation] = o.[operation]
	FROM 
		[#logSizes] x 
		INNER JOIN [operations] o ON [x].[database_name] = [o].[database_name];

	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE [operation] = N'NOTHING') BEGIN 
		INSERT INTO [#operations] ([database_name], [operation], [outcome])
		SELECT 
			[database_name],
			N'NOTHING. Log file is already at target size or smaller. (Current Size: ' + CAST([log_size_gb] AS sysname) + N' GB - Target Size: ' + CAST([target_log_size] AS sysname) + N' GB)' [operation],
			N'' [outcome]
		FROM 
			[#logSizes] 
		WHERE 
			[operation] = N'NOTHING'
		ORDER BY 
			[row_id];

		UPDATE [#logSizes] 
		SET 
			[processing_complete] = 1
		WHERE 
			[operation] = N'NOTHING';
	END;

	DECLARE @returnValue int;
	DECLARE @outcome nvarchar(MAX);
	DECLARE @currentDatabase sysname;
	DECLARE @targetSize int;
	DECLARE @command nvarchar(2000); 
	DECLARE @executionResults xml;

	DECLARE @checkpointComplete datetime; 
	DECLARE @waitStarted datetime;
	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE [operation] = N'CHECKPOINT + BACKUP + SHRINK') BEGIN 
		
		-- start by grabbing the latest backups: 
		UPDATE [ls]
		SET 
			ls.[last_log_backup] = x.[backup_finish_date]
		FROM 
			[#logSizes] ls
			INNER JOIN ( 
				SELECT
					[database_name],
					MAX([backup_finish_date]) [backup_finish_date]
				FROM 
					msdb.dbo.[backupset]
				WHERE 
					[type] = 'L'
				GROUP BY 
					[database_name]
			) x ON [ls].[database_name] = [x].[database_name]
		WHERE 
			ls.[processing_complete] = 0 AND ls.[operation] = N'CHECKPOINT + BACKUP + SHRINK';


		DECLARE @checkpointTemplate nvarchar(200) = N'USE [{0}]; ' + @crlf + N'CHECKPOINT; ' + @crlf + N'CHECKPOINT;' + @crlf + N'CHECKPOINT;';
		DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[database_name]
		FROM 
			[#logSizes] 
		WHERE 
			[processing_complete] = 0 AND [operation] = N'CHECKPOINT + BACKUP + SHRINK';

		OPEN walker; 
		FETCH NEXT FROM walker INTO @currentDatabase;

		WHILE @@FETCH_STATUS = 0 BEGIN

			SET @command = REPLACE(@checkpointTemplate, N'{0}', @currentDatabase);

			IF @PrintOnly = 1 
				PRINT @command;
			ELSE BEGIN 
			
				EXEC @returnValue = dbo.[execute_command]
					@Command = @command,
					@ExecutionType = N'SQLCMD',
					@ExecutionRetryCount = 1, 
					@DelayBetweenAttempts = N'5s',
					@Results = @executionResults OUTPUT 
			
				IF @returnValue = 0	BEGIN
					SET @outcome = N'SUCCESS';
				  END;
				ELSE BEGIN
					SET @outcome = N'ERROR: ' + CAST(@executionResults AS nvarchar(MAX));
				END;

				SET @checkpointComplete = GETDATE();

				INSERT INTO [#operations] ([database_name], [timestamp], [operation], [outcome])
				VALUES (@currentDatabase, @checkpointComplete, @command, @outcome);

				IF @returnValue <> 0 BEGIN
					-- we needed a checkpoint before we could go any further... it didn't work (somhow... not even sure that's a possibility)... so, we're 'done'. we need to terminate early.
					PRINT 'run an update where operation = checkpoint/backup/shrink and set those pigs to done with an ''early termination'' summary as the operation... we can keep trying other dbs... ';
				END;

			END;

			FETCH NEXT FROM walker INTO @currentDatabase;
		END;

		CLOSE walker;
		DEALLOCATE walker;


		SET @waitStarted = GETDATE();
WaitAndCheck:
		
		IF @PrintOnly = 1 BEGIN 
			SET @command = N'';
			SELECT @command = @command + [database_name] + N', ' FROM [#logSizes] WHERE [operation] = N'CHECKPOINT + BACKUP + SHRINK';
			
			PRINT N'-- NOTE: LogFileBackups of the following databases are required before processing can continue: '
			PRINT N'--		' + LEFT(@command, LEN(@command) - 1);

			GOTO ShrinkLogFile;
		END;

		WAITFOR DELAY @waitDuration;  -- Wait, then poll for new T-LOG backups:
-- TODO: arguably... i could keep track of the # of dbs we're waiting on ... and, each time we detect that a new DB has been T-log backed up... i could 'GOTO ShrinkDBs;' and then... if there are any dbs to process (at the end of that block of logic (i.e., @dbsWaitingOn > 0) then... GOTO WaitAndStuff;.. and, then, just tweak the way we do the final error/check - as in, if we've waited too long and stil have dbs to process, then.. we log the error message and 'goto' some other location (the end).
--			that way, say we've got t-logs cycling at roughly 2-3 minute intervals over the next N minutes... ... currently, if we're going to wait up to 20 minutes, we'll wait until ALL of them have been be backed up (or as many as we could get to before we timed out) and then PROCESS ALL of them. 
--				the logic above would, effectively, process each db _AS_ its t-log backup was completed... making it a bit more 'robust' and better ... 
		-- keep looping/waiting while a) we have time left, and b) there are dbs that have NOT been backed up.... 
		IF DATEDIFF(MINUTE, @waitStarted, GETDATE()) < @maxSecondsToWaitForLogFileBackups BEGIN 
			IF EXISTS (SELECT NULL FROM [#logSizes] ls 
				INNER JOIN (SELECT [database_name], MAX([backup_finish_date]) latest FROM msdb.dbo.[backupset] WHERE type = 'L' GROUP BY [database_name]) x ON ls.[database_name] = [x].[database_name] 
					WHERE ls.[last_log_backup] IS NOT NULL AND x.[latest] < @checkpointComplete
			) BEGIN
					GOTO WaitAndCheck;
			END;
		END;

		-- done waiting - either we've now got T-LOG backups for all DBs, or we hit our max wait time: 
		INSERT INTO [#operations] ([database_name], [operation], [outcome])
		SELECT 
			ls.[database_name], 
			N'TIMEOUT' [operation], 
			N'Max Wait Time of (N) reached - last t-log backup of x was found (vs t-log backup > checkpoint date that was needed. SHRINKFILE won''t work.. ' [outcome]
		FROM 
			[#logSizes] ls 
			INNER JOIN ( 
				SELECT
					[database_name],
					MAX([backup_finish_date]) [backup_finish_date]
				FROM 
					msdb.dbo.[backupset]
				WHERE 
					[type] = 'L'
				GROUP BY 
					[database_name]
			) x ON [ls].[database_name] = [x].[database_name] 
		WHERE 
			ls.[operation] = N'CHECKPOINT + BACKUP + SHRINK'
			AND x.[backup_finish_date] < @checkpointComplete;
		
	END;


ShrinkLogFile:
	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE ([operation] = N'SHRINK') OR ([operation] = N'CHECKPOINT + BACKUP + SHRINK')) BEGIN 
		
		DECLARE @minLogFileSize int = CAST((@IgnoreLogFilesSmallerThanGBs * 1024.0) as int);
		DECLARE shrinker CURSOR LOCAL READ_ONLY FAST_FORWARD FOR 
		SELECT [database_name], (CAST(([target_log_size] * 1024.0) AS int) - @BufferMBs) [target_log_size] FROM [#logSizes] WHERE [processing_complete] = 0 AND ([operation] = N'SHRINK') OR ([operation] = N'CHECKPOINT + BACKUP + SHRINK');

		OPEN [shrinker]; 
		FETCH NEXT FROM [shrinker] INTO @currentDatabase, @targetSize;

		WHILE @@FETCH_STATUS = 0 BEGIN

			BEGIN TRY 

				IF @targetSize < @minLogFileSize
					SET @targetSize = @minLogFileSize;

				SET @command = N'USE [{database}];' + @crlf + N'DBCC SHRINKFILE(2, {size}) WITH NO_INFOMSGS;';
				SET @command = REPLACE(@command, N'{database}', @currentDatabase);
				SET @command = REPLACE(@command, N'{size}', @targetSize);

				IF @PrintOnly = 1 BEGIN
					PRINT @command; 
					SET @outcome = N'';
				  END;
				ELSE BEGIN
					
					EXEC @returnValue = dbo.[execute_command]
					    @Command = @command, 
					    @ExecutionType = N'SQLCMD', 
					    @IgnoredResults = N'[COMMAND_SUCCESS],[USE_DB_SUCCESS]', 
					    @Results = @executionResults OUTPUT;
					
					IF @returnValue = 0
						SET @outcome = N'SUCCESS';	
					ELSE 
						SET @outcome = N'ERROR: ' + CAST(@executionResults AS nvarchar(MAX));
				END;
				
			END TRY 
			BEGIN CATCH 
				SET @outcome = N'EXCEPTION: ' + CAST(ERROR_LINE() AS sysname ) + N' - ' + ERROR_MESSAGE();
			END	CATCH

			INSERT INTO [#operations] ([database_name], [operation], [outcome])
			VALUES (@currentDatabase, @command, @outcome);

			FETCH NEXT FROM [shrinker] INTO @currentDatabase, @targetSize;
		END;

		CLOSE shrinker;
		DEALLOCATE [shrinker];

	END; 



	-- TODO: final operation... 
	--   a) go get a new 'logFileSizes' report... 
	--	b) report on any t-logs that are still > target... 

	-- otherwise... spit out whatever form of output/report would make sense at this point... where... we can bind #operations up as XML ... as a set of details about what happened here... 

	SET @SerializedOutput = '';
	EXEC dbo.[list_logfile_sizes]
	    @TargetDatabases = @TargetDatabases,
	    @DatabasesToExclude = @DatabasesToExclude,
	    @Priorities = @Priorities,
	    @ExcludeSimpleRecoveryDatabases = @ExcludeSimpleRecoveryDatabases,
	    @SerializedOutput = @SerializedOutput OUTPUT;

	WITH shredded AS ( 
		SELECT 
			[data].[row].value('database_name[1]', 'sysname') [database_name], 
			[data].[row].value('recovery_model[1]', 'sysname') recovery_model, 
			[data].[row].value('database_size_gb[1]', 'decimal(20,1)') database_size_gb, 
			[data].[row].value('log_size_gb[1]', 'decimal(20,1)') log_size_gb,
			[data].[row].value('log_percent_used[1]', 'decimal(5,2)') log_percent_used, 
			--[data].[row].value('vlf_count[1]', 'int') vlf_count,
			--[data].[row].value('log_as_percent_of_db_size[1]', 'decimal(5,2)') log_as_percent_of_db_size,
			[data].[row].value('mimimum_allowable_log_size_gb[1]', 'decimal(20,1)') [initial_min_allowed_gbs]
		FROM 
			@SerializedOutput.nodes('//database') [data]([row])
	)

	SELECT 
		[origin].[database_name], 
		[origin].[database_size_gb], 
		[origin].[log_size_gb] [original_log_size_gb], 
		[origin].[target_log_size], 
		x.[log_size_gb] [current_log_size_gb], 
		CASE WHEN (x.[log_size_gb] - @LogFileSizingBufferInGBs) <= [origin].[target_log_size] THEN 'SUCCESS' ELSE 'FAILURE' END [shrink_outcome], 
		CAST((
			SELECT  
				[row_id] [operation/@id],
				[timestamp] [operation/@timestamp],
				[operation],
				[outcome]		
			FROM 
				[#operations] o 
			WHERE 
				o.[database_name] = x.[database_name]
			ORDER BY 
				[o].[row_id]
			FOR XML PATH('operation'), ROOT('operations')) AS xml) [xml_operations]		
	FROM 
		[shredded] x 
		INNER JOIN [#logSizes] origin ON [x].[database_name] = [origin].[database_name]
	ORDER BY 
		[origin].[row_id];

	-- TODO: send email alerts based on outcomes above (specifically, pass/fail and such).

	-- in terms of output: 
	--		want to see those that PASSED and those that FAILED> 
	--			also? I'd like to see a summary of how much disk was reclaimed ... and how much stands to be reclaimed if/when we fix the 'FAILURE' outcomes. 
	--				so, in other words, some sort of header... 
	--		and... need the output sorted by a) failures first, then successes, b) row_id... (that way... it's clear which ones passed/failed). 
	--		

	--	also... MIGHT want to look at removing the WITH NO_INFOMSGS switch from the DBCC SHRINKFILE operations... 
	--			cuz.. i'd like to collect/gather the friggin errors - they seem to consistently keep coming back wiht 'end of file' crap - which is odd, given that I'm running checkpoint up the wazoo. 

	RETURN 0;
GO