
/*
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



v6.5 Refactor Impacts the following: 

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
