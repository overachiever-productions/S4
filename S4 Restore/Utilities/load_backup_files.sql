/*

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


	PROBLEM/ISSUE: 
		It's ENTIRELY possible to have FULL (or DIFF) backups that execute CONCURRENTLY with T-LOG backups. In this kind of scenario, it's ENTIRELY possible for either of the following outcomes to occur: 
				a. FULL supersedes current T-LOG meaning that if we have a FULL and T-LOG both created at 21:00... we'd do FULL_2100 + LOG_2110 (i..e, entirely next T-LOG - 10 mins later). 
				or 
				b. FULL and current/concurrent T-LOG overlap meaning we'd need FULL_2100 + LOG_2100 - or the 2 backups created at the SAME TIME (no 10 minute gap as above). 

				The ONLY way to know - for sure - which scenario we're in is to look at the First/Last LSNs for the backups involved. 

					In cases like this... 
						I'd have to do the following in terms of business logic: 
							a. watch for scenarios where T-LOGs 'overlapped' the previous FULL/DIFF
							b. grab 'both' the overlapping and 'next' T-LOGs. 
							c. when I have a scenario like this
								i. read the header details for both 'concurrent' and 'next' T-LOGs 
								ii. determine which one to use 'next' (i.e., LOG_2100 or LOG_2110?)
								iii. keep the OUTPUT/DIRECTIVES 'clean' by skipping any T-LOGS not needed (or, hell, maybe just putting in a comment "-- overlaps, but too early so skipped" 
										or whatever... 

							otherwise, the LOGIC for how to detect which T-LOG is correct is to look at the 
									???? 


				It's also possible to 'cheat' and simply watch for Error 4326 "which is too early to apply to the database" and ... simply 'skip' to the next backup.
					Or, in other words, if we always grab FULL_2100 + LOG_2100 + LOG_2110 ... we'd get 4326 on LOG_2100 in scenario B (but not in scenario A above - i.e., in scenario A, LOG_2100 would work)
							and then simply, 'skip' to LOG_2110... 



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
	@LastAppliedFile			nvarchar(400)			= NULL,	
-- TODO: 
-- REFACTOR: call this @BackupFinishTimeOfLastAppliedBackup ... er, well, that's what this IS... it's NOT the FINISH time of the last APPLY operation. 
	@LastAppliedFinishTime		datetime				= NULL, 
	@Output						xml						= N'<default/>'	    OUTPUT
AS
	SET NOCOUNT ON; 

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

	DECLARE @results table ([id] int IDENTITY(1,1) NOT NULL, [output] varchar(500), [timestamp] datetime NULL);

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	INSERT INTO @results ([output])
	EXEC xp_cmdshell 
		@stmt = @command;

	-- High-level Cleanup: 
	DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';

	UPDATE @results
	SET 
		[timestamp] = dbo.[parse_backup_filename_timestamp]([output])
	WHERE 
		[output] IS NOT NULL;

	IF EXISTS (SELECT NULL FROM @results WHERE [timestamp] IS NULL) BEGIN 
		DECLARE @fileName sysname;
		DECLARE @headerFullPath sysname;
		DECLARE @headerBackupTime datetime;
		DECLARE @rowId int;

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[id],
			[output]
		FROM 
			@results 
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
					UPDATE @results 
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

		DELETE FROM @results WHERE [timestamp] IS NULL;  -- again, assume that any .bak/.trn files that don't adhere to conventions and/or which aren't legit backups are in place explicitly.
	END;

	DECLARE @orderedResults table ( 
		[id] int IDENTITY(1,1) NOT NULL, 
		[output] varchar(500) NOT NULL, 
		[timestamp] datetime NULL
	);

	INSERT INTO @orderedResults (
		[output],
		[timestamp]
	)
	SELECT 
		[output], 
		[timestamp]
	FROM 
		@results 
	WHERE 
		[output] IS NOT NULL
	ORDER BY 
		[timestamp];

	-- Mode Processing: 
	IF UPPER(@Mode) = N'LIST' BEGIN 

		IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN -- if explicitly initialized to NULL/empty... 
			
			SELECT @Output = (SELECT
				[id] [file/@id],
				[output] [file/@file_name],
				[timestamp] [file/@timestamp]
			FROM 
				@orderedResults 
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
			@orderedResults 
		ORDER BY 
			[id];

        RETURN 0;
    END;

	IF UPPER(@Mode) = N'FULL' BEGIN
		-- most recent full only: 
		DELETE FROM @orderedResults WHERE id <> ISNULL((SELECT MAX(id) FROM @orderedResults WHERE [output] LIKE 'FULL%'), -1);
	END;

	IF UPPER(@Mode) = N'DIFF' BEGIN 
		-- start by deleting since the most recent file processed: 
		DELETE FROM @orderedResults WHERE [timestamp] <= @LastAppliedFinishTime;

		-- now dump everything but the most recent DIFF - if there is one: 
		IF EXISTS(SELECT NULL FROM @orderedResults WHERE [output] LIKE 'DIFF%')
			DELETE FROM @orderedResults WHERE id <> (SELECT MAX(id) FROM @orderedResults WHERE [output] LIKE 'DIFF%'); 
		ELSE
			DELETE FROM @orderedResults;
	END;

	IF UPPER(@Mode) = N'LOG' BEGIN
--SELECT @firstLSN [firstLSN], @lastLSN [lastLSN];

		DELETE FROM @orderedResults WHERE [timestamp] <= @LastAppliedFinishTime;
		DELETE FROM @orderedResults WHERE [output] NOT LIKE 'LOG%';
	END;

    IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN -- if explicitly initialized to NULL/empty... 
        
		SELECT @Output = (SELECT
			[id] [file/@id],
			[output] [file/@file_name]
		FROM 
			@orderedResults 
		ORDER BY 
			id 
		FOR XML PATH(''), ROOT('files'));

        RETURN 0;
    END;

    -- otherwise, project:
    SELECT 
        [output]
    FROM 
        @orderedResults
    ORDER BY 
        [id];

	RETURN 0;
GO