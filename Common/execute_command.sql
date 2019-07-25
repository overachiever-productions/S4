/*

   PICKUP/NEXT:
        v6.5 - currently in the middle of a MAJOR 'refactor' - which is a lot more like a rewrite/re-think (to enable all sorts of retry-interactions and better auditing + flow-of-control).

    TODO:
        - move this into \internal ... 
    

    vNEXT: 
        -- Hmmm. All of this 'hard-coded' stuff is all fine. 
            but... what if there were a table for command_results or something like that - i.e. key value entries for things to ignore? 
                along with a number of DEFAULT (S4) entries to ignore... 
                and... the ability to add 'custom' ignore thingies... 



	INTERPRETING OUTPUT:
		- command outcome/success will be indicated by the RETURN value of dbo.execute_command. 
			If the value is 0, then the @Command sent in either INITIALLY executed as desired or EVENTUALLY executed - based on 'retry' rules. 
			If the value is 1, then the @Command failed. 
			For values other than 0 or 1, dbo.execute_command ran into a bug, problem, unexpected scenario or exception and code within dbo.execute_command failed or was PREVENTED from executing. 

		- @Results
			For each and every attempt, an xml 'row'/entry will be added for any EXCEPTION messages/errors (for any/all @ExecutionTypes) 
			Likewise, for SHELL and PARTNER execution, an xml 'row'/entry will be added for every command-line result NOT excluded by @IgnoredResults. 
			Consequently, a call to dbo.execute_command can result in the following 'outcomes': 
				RETURN value of 0 and @Results are EMPTY (i.e., this command succeeded without any problems/issues on the first attempt). 
				RETURN value of 0 and @Results contains 1 or more rows (i.e., there were one or more INITIAL failures (detailed by @Results per each attempt) and then the @Command succceeded). 
				RETURN value of 1 and @Results contains 1 or more rows (i.e., the @command NEVER succeeded and each time it was attempted the specific error/outcome was added as a new 'row' in @Results).

	TODO: 
		- should I put @PrintOnly in here? 
			that'd streamline the HELL out of a lot of other code... 


	vNEXT: 
		- I could probably create an @ExecutionType of REMOTE:NAME
			where REMOTE would tell us to look into sys.servers for ... WHERE [name] = 'NAME'... 
				meaning that ... if a remote server is set up... we should be able to work against it ... 



v6.5 Refactor / REWRITE 

    Changes to Make: 
        - allow [DEFAULT] tokens/valus to be passed into @DelayBetweenAttempts and @IgnoredResults
            i.e., if those values are set to [DEFAULT]... then load in the defaults (2 and 5s - respectively)

        - @RetryCount has been changed to @ExecutionAttemptsCount (might want to make that @TotalExecutionAttemptsCount (though that's a bit of a mouth-ful). 
            I'll have to change this through all callers... 

        - still bugged that I came up with an option for EXEC and... there's no real way to capture any of the output... 
            that seems insane/bad/stupid/dumb. 
                arguably... i MIGHT want to drop it as an option (entirely) and just use SQLCMD instead ... cuz a KEY part of the 'rewrite' is to 
                    address the idea/need to CAPTURE all output and store/save it... etc. 

            NOTE: 
                the ONLY reason that 'EXEC' is an ExecutionType is cuz i (rightly-ish) realized that dbo.execute_command (with 'retry' logic built in)
                    would be a GREAT way to make everything 'retry-able' - including 'simple stuff' that didn't need to be executed in an external thread... 
                        the rub, of course, is that I can't get the outputs... 
                            meaning that either: 
                                a) i figure out SOME way to get outputs from sp_executesql (yeah... no)
                                b) I figure out a SMART/RELIABLE way to wrap every input/command into a try/catch/capture... of some sorts that accomplishes the above
                                    
                                        EXAMPLE: 
                                            assume that @Command = N'USE [dbname];  CHECKPOINT;]; 

                                            in, say, 99.9% of cases, that'll work JUST fine... unless, of course, [dbname] doesn't exist. 
                                            HAPPILY, with a TRY/CATCH wrapped around the call to sp_executesql @Command... i'll capture crap like that. 

                                            but... what about non errors - is there ANY way to do something like... dynamically wrap @command with: 
                                                    
                                                            BEGIN TRY 

                                                                   EXEC @completedCorrectly = sp_executesql @command ... 

                                                            END TRY
                                                            BEGIN CATCH 
                                                                ... 
                                                            END CATCH
                                                    
                                                            -- is there a way to read the output buffer? 

                                            YES... (well - ish and MAYBE)
                                                project details found here: 
                                                    



                                                                    The only way I can think to possibly pull-off option b here would be to: 
                                                                        i) somehow tweak/modify 'sp_outputbuffer' to a point where it would be viable/reliable in terms 
                                                                            of what ever it is that it's parsing... 
                                                                                https://www.itprotoday.com/sql-server/cool-way-spy-output-buffer

                                                                                seriously... he's removing a bunch of stuff. 
                                                                                    what if I figured out some way to REMOVE the 'text' and chained the HEX out into something
                                                                                        then CONVERTED/TRANSLATED the hex into something good? 

                                                                        ii) could somehow mark and trace... 
                                                                                e.g., each EXEC operation would run something like the following: 


                                                                                            PRINT 'EXEC marker here';
                                                                                            SET @spid = @@SPID; 

                                                                                            EXEC sp_executesql @command... 

                                                                                        and then... SOMEHOW ... a) grab that @spid value (might be able to 'infuse' that into the @command 
                                                                                            itself... but that's damned sketchy/crazy... 

                                                                                            and, b) (once i get the spid), run DBCC OUTPUTBUFFER ... clean up the data
                                                                                                and ... return everything since the 'EXEC marker here';
                                                                                                    seems insanely hard... 
                                                                                    Oh... wait. 
                                                                                        dummy. 

                                                                                        EXEC doesn't leave my current spid... 
                                                                                            so... this is a lot simpler: 

                                                                                            1. drop a marker. 
                                                                                            2. exec @worked = sp_executesql @command
                                                                                            3. EXEC load_buffer_since_mark(@spid, 'mark name here'); 
                                                                                                
                                                                                                report on what I find in 3... 
                                                                                  




                                                                                ALTER PROC sp_outputbuffer
                                                                                    -- Produce cleaned-up DBCC OUTPUTBUFFER report for a given SPID.
                                                                                    -- Author: Andrew Zanevsky, 2001-06-29

                                                                                    @spid smallint
                                                                                AS
                                                                                    SET NOCOUNT ON;
                                                                                    SET ANSI_PADDING ON;

                                                                                    DECLARE
                                                                                        @outputbuffer varchar(80),
                                                                                        @clean varchar(16),
                                                                                        @pos smallint;

                                                                                    CREATE TABLE #out (
                                                                                        -- Primary key on IDENTITY column prevents rows
                                                                                        -- from changing order when you update them later.
                                                                                        line int IDENTITY PRIMARY KEY CLUSTERED,
                                                                                        dirty varchar(255) NULL,
                                                                                        clean varchar(16) NULL
                                                                                    );

                                                                                    INSERT #out (
                                                                                        dirty
                                                                                    )
                                                                                    EXEC ('DBCC OUTPUTBUFFER(' + @spid + ') WITH NO_INFOMSGS');

                                                                                    SET @pos = 0;
                                                                                    WHILE @pos < 16
                                                                                        BEGIN
                                                                                            SET @pos = @pos + 1;
                                                                                            -- 1. Eliminate 0x00 symbols.
                                                                                            -- 2. Keep line breaks.
                                                                                            -- 3. Eliminate dots substituted by DBCC OUTPUTBUFFER
                                                                                            --  for nonprintable symbols, but keep real dots.
                                                                                            -- 4. Keep all printable characters.
                                                                                            -- 5. Convert anything else to blank,
                                                                                            --  but compress multiple blanks to one.
                                                                                            UPDATE
                                                                                                #out
                                                                                            SET
                                                                                                clean = ISNULL(clean, '') + CASE
                                                                                                                                WHEN SUBSTRING(dirty, 9 + @pos * 3, 2) = '0a' THEN CHAR(10)
                                                                                                                                WHEN SUBSTRING(dirty, 9 + @pos * 3, 2) BETWEEN '20' AND '7e' THEN SUBSTRING(dirty, 61 + @pos, 1)
                                                                                                                                ELSE ' '
                                                                                                                            END
                                                                                            WHERE
                                                                                                CASE
                                                                                                    WHEN SUBSTRING(dirty, 9 + @pos * 3, 2) = '0a' THEN 1
                                                                                                    WHEN SUBSTRING(dirty, 61 + @pos, 1) = '.' AND SUBSTRING(dirty, 9 + @pos * 3, 2) <> '2e' THEN 0
                                                                                                    WHEN SUBSTRING(dirty, 9 + @pos * 3, 2) BETWEEN '20' AND '7e' THEN 1
                                                                                                    WHEN SUBSTRING(dirty, 9 + @pos * 3, 2) = '00' THEN 0
                                                                                                    WHEN RIGHT('x' + clean, 1) IN (' ', CHAR(10)) THEN 0
                                                                                                    ELSE 1
                                                                                                END = 1;
                                                                                        END;

                                                                                    DECLARE c_output CURSOR FOR SELECT clean FROM #out;
                                                                                    OPEN c_output;
                                                                                    FETCH c_output
                                                                                    INTO
                                                                                        @clean;

                                                                                    SET @outputbuffer = '';

                                                                                    WHILE @@FETCH_STATUS = 0
                                                                                        BEGIN
                                                                                            SET @outputbuffer = @outputbuffer + CASE
                                                                                                                                    WHEN RIGHT(@outputbuffer, 1) = ' ' OR @outputbuffer = '' THEN LTRIM(ISNULL(@clean, ''))
                                                                                                                                    ELSE ISNULL(@clean, '')
                                                                                                                                END;

                                                                                            IF DATALENGTH(@outputbuffer) > 64 BEGIN
                                                                                    PRINT @outputbuffer;
                                                                                    SET @outputbuffer = '';
                                                                                    END;

                                                                                            FETCH c_output
                                                                                            INTO
                                                                                                @clean;
                                                                                        END;
                                                                                    PRINT @outputbuffer;

                                                                                    CLOSE c_output;
                                                                                    DEALLOCATE c_output;

                                                                                    DROP TABLE #out;

                                                                                GO














                                c) I get rid of EXEC as an option... 


        - @Results needs to be re-named to @Outcomes ... i.e., to match the xml node being sent out... 

        - Callers will need to be able to a) store/keep (eventually) the outcomes and b) parse/examine them for any kinds of non-success details
            so that ... 


    Impacts the following sprocs (i.e., the changes above will apply to all of the following callers): 

        establish_directory
        restore_databases
        shrink_logfiles
        execute_command




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.execute_command','P') IS NOT NULL
	DROP PROC dbo.execute_command;
GO

CREATE PROC dbo.execute_command
	@Command								nvarchar(MAX), 
	@ExecutionType							sysname						= N'EXEC',							-- { EXEC | SQLCMD | SHELL | PARTNER }
	@ExecutionAttemptsCount					int							= 2,								-- TOTAL number of times to try executing process - until either success (no error) or @ExecutionAttemptsCount reached. a value of 1 = NO retries... 
	@DelayBetweenAttempts					sysname						= N'5s',
	@IgnoredResults							nvarchar(2000)				= N'[COMMAND_SUCCESS]',				--  'comma, delimited, list of, wild%card, statements, to ignore, can include, [tokens]'. Allowed Tokens: [COMMAND_SUCCESS] | [USE_DB_SUCCESS] | [ROWS_AFFECTED] | [BACKUP] | [RESTORE] | [SHRINKLOG] | [DBCC] ... 
    @PrintOnly                              bit                         = 0,
	@Results								xml							OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	IF @ExecutionAttemptsCount <= 0 SET @ExecutionAttemptsCount = 1;

    IF @ExecutionAttemptsCount > 0 

    IF UPPER(@ExecutionType) NOT IN (N'EXEC', N'SQLCMD', N'SHELL', N'PARTNER') BEGIN 
        RAISERROR(N'Permitted @ExecutionType values are { EXEC | SQLCMD | SHELL | PARTNER }.', 16, 1);
        RETURN -2;
    END; 

	-- if @ExecutionType = PARTNER, make sure we have a PARTNER entry in sys.servers... 


	-- for SQLCMD, SHELL, and PARTNER... final 'statement' needs to be varchar(4000) or less. 


    -- validate @DelayBetweenAttempts (if required/present):
    IF @ExecutionAttemptsCount > 1 BEGIN
	    DECLARE @delay sysname; 
	    DECLARE @error nvarchar(MAX);
	    EXEC dbo.[translate_vector_delay]
	        @Vector = @DelayBetweenAttempts,
	        @ParameterName = N'@DelayBetweenAttempts',
	        @Output = @delay OUTPUT, 
	        @Error = @error OUTPUT;

	    IF @error IS NOT NULL BEGIN 
		    RAISERROR(@error, 16, 1);
		    RETURN -5;
	    END;
    END;

	-----------------------------------------------------------------------------
	-- Processing: 


	DECLARE @filters table (
		filter_type varchar(20) NOT NULL, 
		filter_text varchar(2000) NOT NULL
	); 
	
	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[USE_DB_SUCCESS]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('USE_DB_SUCCESS', 'Changed database context to ''%');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[USE_DB_SUCCESS]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[COMMAND_SUCCESS]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('COMMAND_SUCCESS', 'Command(s) completed successfully.');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[COMMAND_SUCCESS]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[ROWS_AFFECTED]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('ROWS_AFFECTED', '% rows affected)%');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[ROWS_AFFECTED]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[BACKUP]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('BACKUP', 'Processed % pages for database %'),
			('BACKUP', 'BACKUP DATABASE successfully processed % pages in %'),
			('BACKUP', 'BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %'),
			('BACKUP', 'BACKUP LOG successfully processed % pages in %'),
			('BACKUP', 'BACKUP DATABASE...FILE=<name> successfully processed % pages in % seconds %).'), -- for file/filegroup backups
			('BACKUP', 'The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %');  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[BACKUP]', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[RESTORE]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('RESTORE', 'RESTORE DATABASE successfully processed % pages in %'),
			('RESTORE', 'RESTORE LOG successfully processed % pages in %'),
			('RESTORE', 'Processed % pages for database %'),
			('RESTORE', 'Converting database % from version % to the current version %'),    -- whenever there's a patch or upgrade... 
			('RESTORE', 'Database % running the upgrade step from version % to version %.'),	-- whenever there's a patch or upgrade... 
			('RESTORE', 'RESTORE DATABASE ... FILE=<name> successfully processed % pages in % seconds %).'),  -- partial recovery operations... 
            ('RESTORE', 'DBCC execution completed. If DBCC printed error messages, contact your system administrator.');  -- if CDC was enabled on source (even if we don't issue KEEP_CDC), some sort of DBCC command fires during RECOVERY.
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[RESTORE]', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'[SINGLE_USER]', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('SINGLE_USER', 'Nonqualified transactions are being rolled back. Estimated rollback completion%');
					
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'[SINGLE_USER]', N'');
	END;

	INSERT INTO @filters ([filter_type], [filter_text])
	SELECT 'CUSTOM', [result] FROM dbo.[split_string](@IgnoredResults, N',', 1) WHERE LEN([result]) > 0;

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @result nvarchar(MAX);
	DECLARE @resultDetails table ( 
		result_id int IDENTITY(1,1) NOT NULL, 
		execution_time datetime NOT NULL DEFAULT (GETDATE()),
		result nvarchar(MAX) NOT NULL
	);

	DECLARE @xpCmd varchar(2000);
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @serverName sysname = '';
    DECLARE @execOutput int;

	IF UPPER(@ExecutionType) = N'SHELL' BEGIN
        SET @xpCmd = CAST(@Command AS varchar(2000));
    END;
    
    IF UPPER(@ExecutionType) IN (N'SQLCMD', N'PARTNER') BEGIN
        SET @xpCmd = 'sqlcmd {0} -q "' + REPLACE(CAST(@Command AS varchar(2000)), @crlf, ' ') + '"';
    
        IF UPPER(@ExecutionType) = N'SQLCMD' BEGIN 
		
		    IF @@SERVICENAME <> N'MSSQLSERVER'  -- Account for named instances:
			    SET @serverName = N' -S .\' + @@SERVICENAME;
		
		    SET @xpCmd = REPLACE(@xpCmd, '{0}', @serverName);
	    END; 

	    IF UPPER(@ExecutionType) = N'PARTNER' BEGIN 
		    SELECT @serverName = REPLACE([data_source], N'tcp:', N'') FROM sys.servers WHERE [name] = N'PARTNER';

		    SET @xpCmd = REPLACE(@xpCmd, '{0}', ' -S' + @serverName);
	    END; 
    END;
	
	DECLARE @ExecutionAttemptCount int = 0; -- set to 1 during first exectuion attempt:
	DECLARE @succeeded bit = 0;
    
ExecutionAttempt:
	
	SET @ExecutionAttemptCount = @ExecutionAttemptCount + 1;
	SET @result = NULL;

	BEGIN TRY 

		IF UPPER(@ExecutionType) = N'EXEC' BEGIN 
			
            SET @execOutput = NULL;

            IF @PrintOnly = 1 
                PRINT @Command 
            ELSE 
			    EXEC @execOutput = sp_executesql @Command; 

            IF @execOutput = 0
                SET @succeeded = 1;

		  END; 
		ELSE BEGIN 
			DELETE FROM #Results;

            IF @PrintOnly = 1
                PRINT @xpCmd 
            ELSE BEGIN
			    INSERT INTO #Results (result) 
			    EXEC master.sys.[xp_cmdshell] @xpCmd;

-- v6.5
-- don't delete... either: a) update to set column treat_as_handled = 1 or... b) just use a sub-select/filter in the following query... or something. 
--  either way, the idea is: 
--              we capture ALL output - and spit it out for review/storage/auditing/trtoubleshooting and so on. 
---                 but .. only certain outputs are treated as ERRORS or problems... 
			    DELETE r
			    FROM 
				    #Results r 
				    INNER JOIN @filters x ON (r.[result] LIKE x.[filter_text]) OR (r.[result] = x.[filter_text]);

			    IF EXISTS(SELECT NULL FROM [#Results] WHERE [result] IS NOT NULL) BEGIN 
				    SET @result = N'';
				    SELECT 
					    @result = @result + [result] + CHAR(13) + CHAR(10)
				    FROM 
					    [#Results] 
				    WHERE 
					    [result] IS NOT NULL
				    ORDER BY 
					    [result_id]; 
									
			      END;
			    ELSE BEGIN 
				    SET @succeeded = 1;
			    END;
            END;
		END;

	END TRY

	BEGIN CATCH 
		SET @result = N'EXCEPTION: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N' ';
	END CATCH;
	
	IF @result IS NOT NULL BEGIN 
		INSERT INTO @resultDetails ([result])
		VALUES 
			(@result);
	END; 

	IF @succeeded = 0 BEGIN 
		IF @ExecutionAttemptCount < @ExecutionAttemptsCount BEGIN 
			WAITFOR DELAY @delay; 
			GOTO ExecutionAttempt;
		END;
	END;  

	IF EXISTS(SELECT NULL FROM @resultDetails) BEGIN
		SELECT @Results = (SELECT 
			[result_id] [result/@id],  
            [execution_time] [result/@timestamp], 
            [result]
		FROM 
			@resultDetails 
		ORDER BY 
			[result_id]
		FOR XML PATH(''), ROOT('results'));
	END; 

	IF @succeeded = 1
		RETURN 0;

	RETURN 1;
GO