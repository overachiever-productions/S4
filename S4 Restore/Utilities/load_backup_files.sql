/*

	ADMINDB: 
		- This needs a full-ish rewrite - something where the primary focus is more on LSNs than timestamps. 
		- And, needs to account for equivalent of @StopAt logic as well - right out of the gate. 
		- I think it probably also makes more sense to get a full list of all files to restore based on the FULL ... 
		-		i.e., if RESTORE-type = FULL, don't just get the last FULL, get FULL + DIFF + LOG - based on whether or not LOGs are to be applied or not. 
		-			YES, there will be additional 'checks' for more T-LOGs after everything above is restored, but that's a lot easier to process than the current
		--				implementation below which kind of treats the difference between FULL | DIFF and LOG as 'stateless' and tries to rebuild correct-ish LSNs/sequences on the fly. 
		-- See https://overachieverllc.atlassian.net/browse/S4-510 for more info/insights.

    NOTES: 
        - This sproc adheres to the PROJECT/REPLY usage convention.

		- This sproc 
			a. PRIMARILY exists for internal use/operations (in the form of providing a list of backups available for restore or CLEANUP. 
				In this capacity, it is called/used by dbo.apply_logs, dbo.restore_backups, and ALSO by dbo.remove_backup_files (using the LIST mode). 

			b. BUT, it was also DESIGNED to be used/called MANUALLY - for whatever reasons. 

			Because of the above, there are, in essence 2 'overloads' or signatures that can be used when calling this sproc. 
				For scenario (a) usages, S4 code will pass in @LastAppliedFinishTime - so that, if for example, we've restored a FULL (that took 64 minutes to create)
						we make sure to start grabbing DIFF or T-LOGS > @CompletionTimeOfLastAppliedBackup ... (vs attempting to use time-stamp of filename - which represents backup start - i.e., 64 minutes EARLIER).

				For scenario (b) usage (which was the 'legacy' signature), @LastAppliedFile can OPTIONALLY be passed in INSTEAD. 
					In which case, this sproc will: 
						i. load header details for the last-applied file. 
						ii. bind the value of @LastAppliedFinishTime by derived info from header data... 
					(Legacy behavior was to simply use the file-name timestamp of the backup file defined by @LastAppliedFile and grab anything > @thatTimestamp. 
							This could/would/did lead to the dreaded "This LSN is too recent to apply... " errors... for which S4 code USED to try and 'loop' through the next N T-LOGs as a work-around).



	SIGNATURES / EXAMPLES: 

        -- Expect PROJECTion as output:
                EXEC dbo.load_backup_files 
                    @DatabaseToRestore = N'Billing', 
                    @SourcePath = N'D:\SQLBackups\Billing', 
                    @Mode = N'FULL';

                EXEC dbo.load_backup_files 
                    @DatabaseToRestore = N'Billing', 
                    @SourcePath = N'D:\SQLBackups\Billing', 
                    @Mode = N'LIST';


        -- Example of (iterative) REPLY outputs - for all file-types... 

		        -- FULL:
		        DECLARE @lastFile nvarchar(400) = NULL;
		        DECLARE @output xml;
		        EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'FULL', @LastAppliedFile = NULL, @Output = @output OUTPUT;
		        --SELECT @output [FULL BACKUP FILE];

				SELECT @lastFile = @output.value('(/files/file/@file_name)[1]', 'sysname');
				SELECT @lastFile [LastFullBackupToRestore];

		        -- DIFF (if present):
                SET @output = NULL;
		        EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'DIFF', @LastAppliedFile = @lastFile, @Output = @output OUTPUT;
		        
				IF @Output IS NOT NULL BEGIN 
					SELECT @lastFile = @output.value('(/files/file/@file_name)[1]', 'sysname');

					SELECT @lastFile [MostRecentDiffToApply];
				END; ELSE BEGIN 
					SELECT N'-' [NoDiffFoundForRestore];
				END;
				
		        -- T-LOGs:
                SET @output = NULL;
		        EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'LOG', @LastAppliedFile = @lastFile, @Output = @output OUTPUT;
		        
				IF @Output IS NOT NULL BEGIN 
					SELECT 
						x.r.value('@file_name', 'sysname') [T-LogsToRestore]
					FROM 
						@output.nodes('//file') x(r)

				END; ELSE BEGIN 
					SELECT '-' [NoLogsFoundForRestore];
				END;


*/


USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_files','P') IS NOT NULL
	DROP PROC dbo.load_backup_files;
GO

CREATE PROC dbo.load_backup_files 
	@DatabaseToRestore			sysname,
	@SourcePath					nvarchar(400), 
	@Mode						sysname,				-- FULL | DIFF | LOG | LIST			-- where LIST = 'raw'/translated results.
	@LastAppliedFile			nvarchar(400)			= NULL,	  -- Hmmm. 260 chars is max prior to Windows Server 2016 - and need a REGISTRY tweak to support 1024: https://www.intel.com/content/www/us/en/support/programmable/articles/000075424.html 
-- TODO: 
-- REFACTOR: call this @BackupFinishTimeOfLastAppliedBackup ... er, well, that's what this IS... it's NOT the FINISH time of the last APPLY operation. 
	@LastAppliedFinishTime		datetime				= NULL, 
	@StopAt						datetime				= NULL,
	@Output						xml						= N'<default/>'	    OUTPUT
AS
	SET NOCOUNT ON; 
	SET ANSI_WARNINGS OFF;  -- for NULL/aggregates

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;

	IF @Mode NOT IN (N'FULL',N'DIFF',N'LOG',N'LIST') BEGIN;
		RAISERROR('Configuration Error: Invalid @Mode specified.', 16, 1);
		SET @Output = NULL;
		RETURN -1;
	END; 

	DECLARE @firstLSN decimal(25,0), @lastLSN decimal(25,0);

	IF @Mode IN (N'DIFF', N'LOG') BEGIN

		IF @LastAppliedFinishTime IS NULL AND @LastAppliedFile IS NOT NULL BEGIN 
			DECLARE @fullPath nvarchar(260) = dbo.[normalize_file_path](@SourcePath + N'\' + @LastAppliedFile);

			EXEC dbo.load_header_details 
				@BackupPath = @fullPath, 
				@BackupDate = @LastAppliedFinishTime OUTPUT, 
				@BackupSize = NULL, 
				@Compressed = NULL, 
				@Encrypted = NULL, 
				@FirstLSN = @firstLSN OUTPUT, 
				@LastLSN = @lastLSN OUTPUT;
		END;
		
		IF @LastAppliedFinishTime IS NULL BEGIN 
			RAISERROR(N'Execution in ''DIFF'' or ''LOG'' Mode requires either a valid @LastAppliedFile or @LastAppliedFinishTime for filtering.', 16, 1);
			RETURN -20;
		END;
	END;

	CREATE TABLE #results ([id] int IDENTITY(1,1) NOT NULL, [output] varchar(500), [timestamp] datetime NULL);

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	INSERT INTO #results ([output])
	EXEC xp_cmdshell 
		@stmt = @command;

	-- High-level Cleanup: 
	DELETE FROM #results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';

	UPDATE #results
	SET 
		[timestamp] = dbo.[parse_backup_filename_timestamp]([output])
	WHERE 
		[output] IS NOT NULL;

	IF EXISTS (SELECT NULL FROM #results WHERE [timestamp] IS NULL) BEGIN 
		DECLARE @fileName varchar(500);
		DECLARE @headerFullPath nvarchar(1024);  -- using optimal LONG value... even though it might not be configured. https://www.intel.com/content/www/us/en/support/programmable/articles/000075424.html 
		DECLARE @headerBackupTime datetime;
		DECLARE @rowId int;

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[id],
			[output]
		FROM 
			#results 
		WHERE 
			[timestamp] IS NULL
		ORDER BY 
			[id];

		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @rowId, @fileName;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
			SET @headerFullPath = @SourcePath + N'\' + @fileName;

			BEGIN TRY 
				EXEC dbo.[load_header_details]
					@BackupPath = @headerFullPath,
					@BackupDate = @headerBackupTime OUTPUT, 
					@BackupSize = NULL,
					@Compressed = NULL,
					@Encrypted = NULL,
					@FirstLSN = NULL,
					@LastLSN = NULL; 

				IF @headerBackupTime IS NOT NULL BEGIN 
					UPDATE #results 
					SET 
						[timestamp] = @headerBackupTime
					WHERE 
						[id] = @rowId;
				END;
			END TRY 
			BEGIN CATCH
				-- Strangely enough: DO NOTHING here. The file in question is NOT a backup file. But, we'll ASSUME it was put in here by someone who WANTED it here - for whatever reason.
			END CATCH
		
			FETCH NEXT FROM [walker] INTO @rowId, @fileName;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		DELETE FROM #results WHERE [timestamp] IS NULL;  -- again, assume that any .bak/.trn files that don't adhere to conventions and/or which aren't legit backups are in place explicitly.
	END;

	CREATE TABLE #orderedResults ( 
		[id] int IDENTITY(1,1) NOT NULL, 
		[output] varchar(500) NOT NULL, 
		[timestamp] datetime NULL, 
		[duplicate_id] int NULL, 
		[first_lsn] decimal(25,0) NULL,
		[last_lsn] decimal(25,0) NULL, 
		[modified_timestamp] datetime NULL, 
		[should_include] bit DEFAULT(0) NOT NULL
	);

	INSERT INTO #orderedResults (
		[output],
		[timestamp]
	)
	SELECT 
		[output], 
		[timestamp]
	FROM 
		#results 
	WHERE 
		[output] IS NOT NULL
	ORDER BY 
		[timestamp], [output];  /* [output] is FILENAME, and needs to be included as an ORDER BY (ASC) to ensure that ties between FULL & LOG push LOG to the end, and that ties between DIFF & LOG push LOG to the end... */

	/* 
		Account for special/edge-case where FULL or DIFF + 'next' LOG backup both have the SAME timestamp (down to the second) 
		And, the way this is done is: 
			a) identify duplicate timestamps (to the second). 
			b) check start/end LSNs for LOG, 
			c) compare vs DIFF/FULL and see if overlaps 
			d) if, so, 'bump' timestamp of LOG forward by .5 seconds - so it's now 'after' the FULL/DIFF.
	*/
	IF EXISTS (SELECT NULL FROM #orderedResults GROUP BY [timestamp] HAVING COUNT(*) > 1) BEGIN 

		WITH duplicates AS ( 		
			SELECT  
				[timestamp], 
				COUNT(*) [x], 
				ROW_NUMBER() OVER (ORDER BY [timestamp]) [duplicate_id]
			FROM 
				#orderedResults 
			GROUP BY	
				[timestamp]
			HAVING 
				COUNT(*) > 1
		) 

		UPDATE x 
		SET 
			x.[duplicate_id] = d.[duplicate_id]
		FROM 
			#orderedResults x 
			INNER JOIN [duplicates] d ON [x].[timestamp] = [d].[timestamp];
		
		DECLARE @duplicateTimestampFile varchar(500);
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[output]
		FROM 
			#orderedResults 
		WHERE  
			[duplicate_id] IS NOT NULL 
		ORDER BY 
			[duplicate_id];
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @duplicateTimestampFile;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			SET @headerFullPath = @SourcePath + N'\' + @duplicateTimestampFile;
			SET @firstLSN = NULL;
			SET @lastLSN = NULL;			
		
			EXEC dbo.[load_header_details]
				@BackupPath = @headerFullPath,
				@BackupDate = NULL,
				@BackupSize = NULL,
				@Compressed = NULL,
				@Encrypted = NULL,
				@FirstLSN = @firstLSN OUTPUT,
				@LastLSN = @lastLSN OUTPUT; 

			UPDATE #orderedResults 
			SET 
				[first_lsn] = @firstLSN, 
				[last_lsn] = @lastLSN
			WHERE 
				[output] = @duplicateTimestampFile;

			FETCH NEXT FROM [walker] INTO @duplicateTimestampFile;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		DECLARE @duplicateID int = 1; 
		DECLARE @maxDuplicateID int = (SELECT MAX(duplicate_id) FROM #orderedResults); 

		DECLARE @logFirstLSN decimal(25,0), @logLastLSN decimal(25,0), @fullOrDiffLastLSN decimal(25,2);

		WHILE @duplicateID <= @maxDuplicateID BEGIN 

			SELECT
				@logFirstLSN = first_lsn, 
				@logLastLSN = last_lsn
			FROM 
				#orderedResults 
			WHERE 
				[duplicate_id] = @duplicateID 
				AND [output] LIKE 'LOG%'

			SELECT 
				@fullOrDiffLastLSN = last_lsn 
			FROM 
				#orderedResults 
			WHERE 
				[duplicate_id] = @duplicateID 
				AND [output] NOT LIKE 'LOG%'

			IF @logFirstLSN <= @fullOrDiffLastLSN AND @logLastLSN >= @fullOrDiffLastLSN BEGIN 
				UPDATE #orderedResults 
				SET 
					[modified_timestamp] = DATEADD(MILLISECOND, 500, [timestamp])
				WHERE 
					[duplicate_id] = @duplicateID 
					AND [output] LIKE 'LOG%'
			END;

			SET @duplicateID = @duplicateID +1; 
		END;

		IF EXISTS (SELECT NULL FROM #orderedResults WHERE [modified_timestamp] IS NOT NULL) BEGIN 
			UPDATE #orderedResults 
			SET 
				[timestamp] = [modified_timestamp]
			WHERE 
				[modified_timestamp] IS NOT NULL;
		END;
		
	END;

	/*
		Need to account for a scenario where FULL/DIFF backup EXTENDS to or past the end of a T-LOG Backup running concurrently
		What follows below is a BIT of a hack... because it only looks for LSNs when we're dealing with FULL/DIFF and a LOG backup. 
			i.e., the non-HACK way would be to effectively ONLY(ish) look at LSNs. 	
	*/
	IF UPPER(@Mode) IN (N'LOG', N'LIST') AND (@LastAppliedFile IS NULL AND @LastAppliedFinishTime IS NOT NULL) BEGIN 
		/* This is a fairly nasty hack... */
		SELECT @LastAppliedFile = output FROM #orderedResults WHERE id = (SELECT MAX(id) FROM #orderedResults WHERE ([output] LIKE N'FULL%' OR [output] LIKE N'DIFF%') AND [timestamp] < @LastAppliedFinishTime)
	END;

	IF @LastAppliedFile LIKE N'FULL%' OR @LastAppliedFile LIKE N'DIFF%' BEGIN
		DECLARE @currentFileName varchar(500);
		DECLARE @lowerId int = ISNULL((SELECT id FROM #orderedResults WHERE [output] = @LastAppliedFile), 2) - 1; 
		IF @lowerId < 1 SET @lowerId = 1;

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[output]
		FROM 
			#orderedResults
		WHERE 
			id >= @lowerID
			-- TODO / vNEXT: if/when there's an @StopTime feature added, put an upper bound on any rows > @StopTime - i.e., AND timestamp < @StopAt.
		ORDER BY 
			[id];

		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @currentFileName;
	
		WHILE @@FETCH_STATUS = 0 BEGIN
	
			SET @headerFullPath = @SourcePath + N'\' + @currentFileName;
			SET @firstLSN = NULL;
			SET @lastLSN = NULL;			
		
			EXEC dbo.[load_header_details]
				@BackupPath = @headerFullPath,
				@BackupDate = NULL,
				@BackupSize = NULL,
				@Compressed = NULL,
				@Encrypted = NULL,
				@FirstLSN = @firstLSN OUTPUT,
				@LastLSN = @lastLSN OUTPUT; 

			UPDATE #orderedResults 
			SET 
				[first_lsn] = @firstLSN, 
				[last_lsn] = @lastLSN
			WHERE 
				[output] = @currentFileName;
	
			FETCH NEXT FROM [walker] INTO @currentFileName;
		END;
	
		CLOSE [walker];
		DEALLOCATE [walker];

		SELECT @fullOrDiffLastLSN = last_lsn FROM #orderedResults WHERE [output] = @LastAppliedFile;

		WITH tweaker AS ( 
			SELECT 
				r.[output], 
				CASE WHEN [r].[first_lsn] <= @fullOrDiffLastLSN AND r.[last_lsn] >= @fullOrDiffLastLSN THEN 1 ELSE 0 END [should_include]
			FROM 
				#orderedResults r
		)

		UPDATE x 
		SET 
			[x].[should_include] = t.should_include
		FROM 
			#orderedResults x
			INNER JOIN [tweaker] t ON [x].[output] = [t].[output]
		WHERE 
			t.[should_include] = 1
			AND x.[output] LIKE N'LOG%';


		/* Additional 'special use case' for scenarios where MULTIPLE T-LOGs have been executing while a DIFF or FULL was being created */
		UPDATE #orderedResults 
		SET 
			should_include = 1 
		WHERE 
			[output] LIKE N'%LOG%' 
			AND [timestamp] <= @LastAppliedFinishTime 
			AND [id] > (SELECT MAX(id) FROM #orderedResults WHERE should_include = 1);

		/* This is a bit of an odd/weird hack - i.e., I could also exclude [should_include] = 1 from DELETE operations down below) */
		UPDATE #orderedResults 
		SET 
			[timestamp] = DATEADD(MILLISECOND, 500, @LastAppliedFinishTime) 
		WHERE 
			should_include = 1; 
	END;

	IF UPPER(@Mode) = N'LIST' BEGIN 

		IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN -- if explicitly initialized to NULL/empty... 
			
			SELECT @Output = (SELECT
				[id] [file/@id],
				[output] [file/@file_name],
				[timestamp] [file/@timestamp]
			FROM 
				#orderedResults 
			ORDER BY 
				id 
			FOR XML PATH(''), ROOT('files'));

			RETURN 0;

		END;

		SELECT 
			[id],
			[output] [file_name],
			[timestamp] 
		FROM 
			#orderedResults 
		ORDER BY 
			[id];

        RETURN 0;
    END;

	IF UPPER(@Mode) = N'FULL' BEGIN
		IF @StopAt IS NOT NULL BEGIN 
			-- grab the most recent full before the STOP AT directive (vs the last/most-recent of all time):
			DELETE FROM [#orderedResults] WHERE id <> ISNULL((SELECT MAX(id) FROM [#orderedResults] WHERE [output] LIKE 'FULL%' AND [timestamp] < @StopAt), -1);
		  END;
		ELSE BEGIN
			-- most recent full only: 
			DELETE FROM #orderedResults WHERE id <> ISNULL((SELECT MAX(id) FROM #orderedResults WHERE [output] LIKE 'FULL%'), -1);
		END;
	END;

	IF UPPER(@Mode) = N'DIFF' BEGIN 
		DELETE FROM #orderedResults WHERE [timestamp] <= @LastAppliedFinishTime;

		-- now dump everything but the most recent DIFF - if there is one: 
		IF EXISTS(SELECT NULL FROM #orderedResults WHERE [output] LIKE 'DIFF%') BEGIN
			IF @StopAt IS NULL BEGIN
				DELETE FROM #orderedResults WHERE id <> (SELECT MAX(id) FROM #orderedResults WHERE [output] LIKE 'DIFF%'); 
			  END
			ELSE BEGIN
				DELETE FROM [#orderedResults] WHERE id <> ISNULL((SELECT MAX(id) FROM [#orderedResults] WHERE [output] LIKE 'DIFF%' AND [timestamp] < @StopAt), -1);	
			END;
		  END;
		ELSE
			DELETE FROM #orderedResults;
	END;

	IF UPPER(@Mode) = N'LOG' BEGIN
		DELETE FROM #orderedResults WHERE [timestamp] <= @LastAppliedFinishTime;
		DELETE FROM #orderedResults WHERE [output] NOT LIKE 'LOG%';

		IF @StopAt IS NOT NULL 
			DELETE FROM [#orderedResults] WHERE id > (SELECT MIN(id) FROM [#orderedResults] WHERE [output] LIKE 'LOG%' AND [timestamp] > @StopAt);
	END;

    IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN 
        
		SELECT @Output = (SELECT
			[id] [file/@id],
			[output] [file/@file_name]
		FROM 
			#orderedResults 
		ORDER BY 
			id 
		FOR XML PATH(''), ROOT('files'));

        RETURN 0;
    END;

    SELECT 
        [output]
    FROM 
        #orderedResults
    ORDER BY 
        [id];

	RETURN 0;
GO