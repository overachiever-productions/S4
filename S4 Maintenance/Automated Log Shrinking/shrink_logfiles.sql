

/*




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
	@TargetPercentageSize						int										= 20,										-- can be > 100? i.e., 200? would be 200% - which ... i guess is legit, right? 
	@ExcludeSimpleRecoveryDatabases				bit										= 1,										
	@MinimumLogSizeThresholdInGBs				decimal(5,1)							= 0.2,										-- e.g., don't bother shrinking anything > 200MB in size... 								
	@SizingBufferInGBs							decimal(4,1)							= 0.4,										-- e.g., a) when targetting a log for DBCC SHRINKFILE() add this into the target and b) when checking on dbs POST shrink, if they're under target + this Buffer, they're FINE/done/shrunk/ignored.
	@MaxLogWaitTime								int										= 20,		-- TODO set this to a 'span' -i.e., 20m or 2h ... whatever (and just allow hours and minutes.. 

	@OperatorName								sysname									= N'Alerts',
	@MailProfileName							sysname									= N'General',
	@EmailSubjectPrefix							nvarchar(50)							= N'[Log Shrink Operations ] ',
	@PrintOnly									bit										= 0
AS
	SET NOCOUNT ON; 

	-- {copyright} 

	-----------------------------------------------------------------------------
	-- Dependencies Validation:

	IF OBJECT_ID('dbo.load_databases', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_databases not defined - unable to continue.', 16, 1);
		RETURN -1;
	END
	

	-----------------------------------------------------------------------------
	-- Validate Inputs:






	

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @targetRatio decimal(6,2) = @TargetPercentageSize / 100.0;

-- NOTE: this is used a bit 'oddly'. When we first check for current_log_size < target_log_size we don't account for this 'buffer' IF the current_log_size < @MinSize or target_log_size < @MinSize.
--		then, if/when we target any log for a shrink operation, the target will be [target_size] - @bufferSizeInMBs (so if we were shooting for a 12GB log as our target, we'd 'bake in', say, the @SizingBufferInGBs as well - so 12GB - 1GB (or whatever sizing buffer is)... for an 11GB target instead of a 12 GB target. 
--			THEN, when we finally check, again, to make sure everything got 'below' targets... we'll do comparisons of [current-and-shrunk_log_size] > [target_size] + @BufferGBs ... to see if a log size did NOT get below what was expected... 

	DECLARE @BufferMBs int = CAST((@SizingBufferInGBs * 1024) AS int);  


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
		[timestamp] datetime NOT NULL, 
		[operation] nvarchar(MAX) NOT NULL, 
	);

	DECLARE @SerializedOutput xml = '';
	EXEC [admindb].dbo.[list_logfile_sizes]
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
		CAST((CASE WHEN t.[target_log_size] < @MinimumLogSizeThresholdInGBs THEN @MinimumLogSizeThresholdInGBs ELSE t.[target_log_size] END) AS decimal(20,2)) [target_log_size]
	FROM 
		[shredded] s 
		INNER JOIN [targets] t ON [s].[database_name] = [t].[database_name];

	WITH operations AS ( 
		SELECT 
			[database_name], 
			CASE 
				WHEN [log_size_gb] <= [target_log_size] THEN 'NOTHING' -- N'N/A - Log file is already at target size or smaller. (Current Size: ' + CAST([log_size_gb] AS sysname) + N' GB - Target Size: ' + CAST([target_log_size] AS sysname) + N' GB)'
				ELSE CASE 
					WHEN [initial_min_allowed_gbs] <= ([target_log_size] + @SizingBufferInGBs) THEN 'SHRINK'
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
		INSERT INTO [#operations] ([database_name], [timestamp], [operation])
		SELECT 
			[database_name],
			GETDATE() [timestamp], 
			N'IGNORE. Log file is already at target size or smaller. (Current Size: ' + CAST([log_size_gb] AS sysname) + N' GB - Target Size: ' + CAST([target_log_size] AS sysname) + N' GB)' [operation]
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

	DECLARE @outcome nvarchar(MAX);
	DECLARE @currentDatabase sysname;
	DECLARE @targetSize int;
	DECLARE @command nvarchar(2000); 

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
			ls.[processing_complete] = 0 AND [operation] = N'CHECKPOINT + BACKUP + SHRINK';


		SET @command = N'CHECKPOINT; ' + NCHAR(13) + NCHAR(10) + N'CHECKPOINT;' + NCHAR(13) + NCHAR(10) + N'CHECKPOINT;';
-- TODO: execute... 

		SET @checkpointComplete = GETDATE();

		INSERT INTO [#operations] ([database_name], [timestamp], [operation])
		SELECT 
			[database_name],
			@checkpointComplete [timestamp], 
			N'Checkpoint Operation Issued (3x).' [operation]
		FROM 
			[#logSizes] 
		WHERE 
			[operation] = N'CHECKPOINT + BACKUP + SHRINK'
		ORDER BY 
			[row_id];

		SET @waitStarted = GETDATE();
WaitAndCheck:
		-- Wait for new T-LOG backups:
		WAITFOR DELAY '00:01:00';

		-- keep looping/waiting while a) we have time left, and b) there are dbs that have NOT been backed up.... 
		IF DATEDIFF(MINUTE, @waitStarted, GETDATE()) < @MaxLogWaitTime BEGIN 
			IF EXISTS (SELECT NULL FROM [#logSizes] ls 
				INNER JOIN (SELECT [database_name], MAX([backup_finish_date]) latest FROM msdb.dbo.[backupset] WHERE type = 'L' GROUP BY [database_name]) x ON ls.[database_name] = [x].[database_name] 
					WHERE ls.[last_log_backup] IS NOT NULL AND x.[latest] < @checkpointComplete
			) BEGIN
					GOTO WaitAndCheck;
			END;
		END;

		-- done waiting - either we've now got T-LOG backups for all DBs, or we hit our max wait time: 
		INSERT INTO [#operations] ([database_name], [timestamp], [operation])
		SELECT 
			ls.[database_name], 
			GETDATE() [timestamp], 
			N'Max Wait Time of (N) reached - last t-log backup of x was found (vs t-log backup > checkpoint date that was needed. SHRINKFILE won''t work.. ' [operation]
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

	IF EXISTS (SELECT NULL FROM [#logSizes] WHERE ([operation] = N'SHRINK') OR ([operation] = N'CHECKPOINT + BACKUP + SHRINK')) BEGIN 
		
		DECLARE shrinker CURSOR LOCAL READ_ONLY FAST_FORWARD FOR 
		SELECT [database_name], (CAST([target_log_size] AS int) - @BufferMBs) [target_log_size] FROM [#logSizes] WHERE [processing_complete] = 0 AND ([operation] = N'SHRINK') OR ([operation] = N'CHECKPOINT + BACKUP + SHRINK');

		OPEN [shrinker]; 
		FETCH NEXT FROM [shrinker] INTO @currentDatabase, @targetSize;

		WHILE @@FETCH_STATUS = 0 BEGIN

			BEGIN TRY 
-- TODO: implement
				SET @command = N'USE [{DatbaseName}];' + NCHAR(13) + NCHAR(10) + N'DBCC SHRINKFILE(2, {TargetLogSize}) WITH NO_INFOMSGS;';

				SET @outcome = N'SUCCESS';
			END TRY 
			BEGIN CATCH 
				SET @outcome = N'ERROR: '; -- + error message details... 
			END	CATCH

			INSERT INTO [#operations] ([database_name], [timestamp], [operation])
			VALUES (@currentDatabase, GETDATE(), 'SHRINK. ' + @outcome);

			FETCH NEXT FROM [shrinker] INTO @currentDatabase, @targetSize;
		END;

		CLOSE shrinker;
		DEALLOCATE [shrinker];

	END; 

	-- TODO: final operation... 
	--   a) go get a new 'logFileSizes' report... 
	--	b) report on any t-logs that are still > target... 

	-- otherwise... spit out whatever form of output/report would make sense at this point... where... we can bind #operations up as XML ... as a set of details about what happened here... 

	SELECT * FROM [#logSizes];


	SELECT * FROM [#operations];