/*

PICKUP/NEXT: 
	Need to standardize and simplify the @Command handling. 
	Specifically: 
		- all callers will define 'native' commands for whatever 'shell' they're trying to use... 
			e.g., PARTNERs will simply run SQL statements. 
			e.g., SHELL will be a set of simple CMD-line statemetns, e.g., 'Ping 10.10.0.1' 
			e.g., POSH will be the PoshCommands - such as: 'Write-S3Object -BucketName ''string here'' -Stuff ''another string'' -Switch -CommandSOmething 2';

		- this sproc will 
			a. verify they don't have padding/overhead/gunk (i.e., that a call to SHELL doesn't have/contain xp_executesql and/or that a PARTNER or SQLCMD doesn't have sqlcmd and so on... 
			b. 'wrap' the contents of each command into the syntax/commands needed. 

			(This means that code that calls into these piglets does NOT have to worry about escaping strings and crap... just define the commands 'natively' and this 'shell-wrapper' will do what we need. 
		- document the exact types of inputs by 'shell'/@ExecutionType i.e., make it so that this is easy to 'read the docs' on/against in the future. 



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
				RETURN value of something OTHER than 0 or 1 and ??? 

	vNEXT:
        - allow {DEFAULT} tokens/valus to be passed into @DelayBetweenAttempts and @IgnoredResults
            i.e., if those values are set to {DEFAULT}... then load in the defaults (2 and 5s - respectively)
		- allow the OPTION for PARTNER:serverNameHere ... or, maybe LINKED:serverNameHere... 
		- potentially allow for DAC connections... i.e., -A via SQLCMD... 
			obviously, this wouldn't really be for things like ... troubleshooting via the DAC but it MIGHT (might) make sense for things like decrypting sprocs, 
				or taking a peek at some DAC-only-ish data from the master/resource db(s).

	SAMPLE SIGNATURES (these are pretty ugly/raw): 


		----------------------------------------------------------------------------------------------
			-- example of ALL results/outputs being whitelisted:

				DECLARE
					@outcome xml, 
					@errorMessage nvarchar(MAX);

				EXEC [admindb].dbo.[execute_command]
					@Command = N'ping 10.0.0.1', -- nvarchar(max)
					@ExecutionType = N'SHELL', -- sysname
					@ExecutionAttemptsCount = 2, -- int
					@IgnoredResults = N'Reply from 10.0.%',
					@SafeResults = N'{ALL}',
					@Outcome = @outcome OUTPUT, 
					@ErrorMessage = @errorMessage OUTPUT;

				SELECT @outcome, @errorMessage;
				GO

		----------------------------------------------------------------------------------------------
				DECLARE
					@outcome xml, 
					@errorMessage nvarchar(MAX);

				EXEC [admindb].dbo.[execute_command]
					@Command = N'SELECT COUNT(*) [total] FROM Counters.dbo.MeM_Disk1;', -- nvarchar(max)
					@ExecutionType = N'PARTNER', -- sysname
					@ExecutionAttemptsCount = 2, -- int
					@IgnoredResults = N'{ROWS_AFFECTED}, %----%',
					--@SafeResults = N'{ALL}',
					--@ErrorResults = N'total',
					@Outcome = @outcome OUTPUT, 
					@ErrorMessage = @errorMessage OUTPUT;

				SELECT @outcome, @errorMessage;
				GO

		----------------------------------------------------------------------------------------------
			-- unexpected / un-white-listed results (i.e., failure):
				DECLARE
					@outcome xml, 
					@errorMessage nvarchar(MAX);

				EXEC [admindb].dbo.[execute_command]
					@Command = N'ping 10.0.0.1', -- nvarchar(max)
					@ExecutionType = N'SHELL', -- sysname
					@ExecutionAttemptsCount = 2, -- int
					--@DelayBetweenAttempts = NULL, -- sysname
					@IgnoredResults = N'oink, failure example,{ROWS_AFFECTED}, %This is a sample % wildcard message%, %another wildcard%, {COMMAND_SUCCESS}', -- nvarchar(2000)
					@Outcome = @outcome OUTPUT, 
					@ErrorMessage = @errorMessage OUTPUT;

				SELECT @outcome, @errorMessage;
				GO

		----------------------------------------------------------------------------------------------
			-- exception/error example: 
-- TODO: fix this ... there's an error/exception - but it's NOT the thrown exception, instead it's a problem with the command and (presumably?) escaped quotes?
				DECLARE
					@outcome xml, 
					@errorMessage nvarchar(MAX);

				EXEC [admindb].dbo.[execute_command]
					@Command = N'RAISERROR(''doh!'', 16, 1);', -- nvarchar(max)
					@ExecutionType = N'SQLCMD', -- sysname
					@ExecutionAttemptsCount = 1, -- int
					--@DelayBetweenAttempts = NULL, -- sysname
					@IgnoredResults = N'oink, failure example,{ROWS_AFFECTED}, %This is a sample % wildcard message%, %another wildcard%, {COMMAND_SUCCESS}', -- nvarchar(2000)
					@Outcome = @outcome OUTPUT, 
					@ErrorMessage = @errorMessage OUTPUT;

				SELECT @outcome, @errorMessage;
				GO

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.execute_command','P') IS NOT NULL
	DROP PROC dbo.[execute_command];
GO

CREATE PROC dbo.[execute_command]
	@Command								nvarchar(MAX), 
	@ExecutionType							sysname						= N'SQLCMD',						-- { SQLCMD | SHELL | PS | PS_CORE | PARTNER }
	@ExecutionAttemptsCount					int							= 2,								-- TOTAL number of times to try executing process - until either success (no error) or @ExecutionAttemptsCount reached. a value of 1 = NO retries... 
	@DelayBetweenAttempts					sysname						= N'5s',
	@IgnoredResults							nvarchar(2000)				= N'{COMMAND_SUCCESS}',				--  'comma, delimited, list of, wild%card, statements, to ignore, can include, {tokens}'. Allowed Tokens: {COMMAND_SUCCESS} | {USE_DB_SUCCESS} | {ROWS_AFFECTED} | {BACKUP} | {RESTORE} | {SHRINKLOG} | {DBCC} ... 
    @SafeResults							nvarchar(2000)				= N'',								-- { ALL | custom_pattern } just like @IgnoredResults but marked as 'safe' (i.e., ALSO ignored and won't trigger error conditions), meaning that they're something the user wants back (e.g., results of a ping 10.0.0.1... various 'bits' of result could be flagged as SAFE.
	@ErrorResults							nvarchar(2000)				= N'',								-- 'Inverse' of @SafeResults - i.e., if setting @SafeResults to {ALL}... that's a pain IF there's one or three various bits of exact text that result in an error... 
	@PrintOnly                              bit                         = 0,
	@Outcome								xml							OUTPUT, 
	@ErrorMessage							nvarchar(MAX)				OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	SET @ExecutionType = UPPER(ISNULL(@ExecutionType, N'SQLCMD'));
	SET @IgnoredResults = NULLIF(@IgnoredResults, N'');
	SET @SafeResults = NULLIF(@SafeResults, N'');

	IF @ExecutionAttemptsCount <= 0 SET @ExecutionAttemptsCount = 1;

    IF @ExecutionAttemptsCount > 0 

    IF @ExecutionType NOT IN (N'SQLCMD', N'SHELL', N'PS', N'PS_CORE', N'PARTNER') BEGIN 
        RAISERROR(N'Permitted @ExecutionType values are { SQLCMD | SHELL | PS | PS_CORE | PARTNER }.', 16, 1);
        RETURN -2;
    END; 

	-- if @ExecutionType = PARTNER, make sure we have a PARTNER entry in sys.servers... 
	--  or, vNEXT: @ExecutionType of PARTNER:SQL-130-11B can/will ultimately be allowed... 

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
	
	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{USE_DB_SUCCESS}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('USE_DB_SUCCESS', 'Changed database context to ''%');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{USE_DB_SUCCESS}', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{COMMAND_SUCCESS}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('COMMAND_SUCCESS', 'Command(s) completed successfully.');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{COMMAND_SUCCESS}', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{ROWS_AFFECTED}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('ROWS_AFFECTED', '% rows affected)%');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{ROWS_AFFECTED}', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{BACKUP}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('BACKUP', 'Processed % pages for database %'),
			('BACKUP', 'BACKUP DATABASE successfully processed % pages in %'),
			('BACKUP', 'BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %'),
			('BACKUP', 'BACKUP LOG successfully processed % pages in %'),
			('BACKUP', 'BACKUP DATABASE...FILE=<name> successfully processed % pages in % seconds %).'), -- for file/filegroup backups
			('BACKUP', 'The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %');  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{BACKUP}', N'');
	END; 

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{DELETEFILE}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('DELETEFILE', 'Command(s) completed successfully.');
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{DELETEFILE}', N'');
	END; 
	
	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{RESTORE}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('RESTORE', 'RESTORE DATABASE successfully processed % pages in %'),
			('RESTORE', 'RESTORE LOG successfully processed % pages in %'),
			('RESTORE', 'Processed % pages for database %'),
			('RESTORE', 'Converting database % from version % to the current version %'),    -- whenever there's a patch or upgrade... 
			('RESTORE', 'Database % running the upgrade step from version % to version %.'),	-- whenever there's a patch or upgrade... 
			('RESTORE', 'RESTORE DATABASE ... FILE=<name> successfully processed % pages in % seconds %).'),  -- partial recovery operations... 
            ('RESTORE', 'DBCC execution completed. If DBCC printed error messages, contact your system administrator.');  -- if CDC was enabled on source (even if we don't issue KEEP_CDC), some sort of DBCC command fires during RECOVERY.
		
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{RESTORE}', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{SINGLE_USER}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('SINGLE_USER', 'Changed database context to %'),
			('SINGLE_USER', 'Nonqualified transactions are being rolled back. Estimated rollback completion%');
					
		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{SINGLE_USER}', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{COPYFILE}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('COPYFILE', '%1 [Ff]ile(s) copied%');

		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{COPYFILE}', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{S3COPYFILE}', N'')))) BEGIN
		-- PlaceHolder: there isn't, currently, any 'noise' output from Write-S3Object...

		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{S3COPYFILE}', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{OFFLINE}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type],[filter_text])
		VALUES 
			('OFFLINE', 'Failed to restart the current database. The current database is switched to master%');

		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{OFFLINE}', N'');
	END;

	IF (LEN(@IgnoredResults) <> LEN((REPLACE(@IgnoredResults, N'{B2COPYFILE}', N'')))) BEGIN
		INSERT INTO @filters ([filter_type], [filter_text])
		VALUES
			(N'B2COPYFILE', N'URL by file name:%'),
			(N'B2COPYFILE', N'URL by fileId:%'),
			(N'B2COPYFILE', N'{'),
			(N'B2COPYFILE', N'    },'),
			(N'B2COPYFILE', N'    "accountId"%'),
			(N'B2COPYFILE', N'    "action":%'),
			(N'B2COPYFILE', N'    "bucketId":%'),
			(N'B2COPYFILE', N'    "content%'),
			(N'B2COPYFILE', N'    "file%'),
			(N'B2COPYFILE', N'        "src_last_modified_millis%'),
			(N'B2COPYFILE', N'    "serverSideEncryption":%'),
			(N'B2COPYFILE', N'        "mode": %'),
			(N'B2COPYFILE', N'        "retainUntilTimestamp": null'),
			(N'B2COPYFILE', N'    "legalHold":%'),
			(N'B2COPYFILE', N'    "replicationStatus":%'),
			(N'B2COPYFILE', N'    "size": %'),
			(N'B2COPYFILE', N'    "uploadTimestamp": %'),
			(N'B2COPYFILE', N'}');

		SET @IgnoredResults = REPLACE(@IgnoredResults, N'{B2COPYFILE}', N'')
	END;

	-- TODO: {SHRINKLOG}
	-- TODO: {DBCC} (success)

	INSERT INTO @filters ([filter_type], [filter_text])
	SELECT 'CUSTOM_IGNORED', [result] FROM dbo.[split_string](@IgnoredResults, N',', 1) WHERE LEN([result]) > 0;

	IF @SafeResults IS NOT NULL BEGIN 
		IF UPPER(@SafeResults) = N'{ALL}' BEGIN 
			INSERT INTO @filters ([filter_type], [filter_text]) 
			VALUES ('SAFE_WILDCARD', N'%_%');
		  END; 
		ELSE BEGIN
			INSERT INTO @filters ([filter_type], [filter_text])
			SELECT 'SAFE', [result] FROM dbo.[split_string](@SafeResults, N',', 1) WHERE LEN([result]) > 0;
		END;
	END;

	DECLARE @explicitErrors table (error_id int IDENTITY(1,1) NOT NULL, error_text sysname); 
	IF @ErrorResults IS NOT NULL BEGIN 
		INSERT INTO @explicitErrors ([error_text])
		SELECT [result] FROM dbo.[split_string](@ErrorResults, N',', 1) WHERE LEN([result]) > 0;
	END;

	CREATE TABLE #cmd_results (
		[result_id] int IDENTITY(1,1),
		[result_text] nvarchar(MAX), 
		[ignored_match] sysname NULL, 
		[explicit_error] sysname NULL
	);

	DECLARE @result xml;
	DECLARE @iterations table ( 
		iteration_id int IDENTITY(1,1) NOT NULL, 
		execution_time datetime NOT NULL,
		succeeded bit NOT NULL, 
		exception bit NOT NULL,
		result xml NOT NULL
	);

	DECLARE @xpCmd varchar(2000);
	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @serverName sysname = '.';
    DECLARE @execOutput int;

	IF @ExecutionType = N'SHELL' BEGIN
        SET @xpCmd = CAST(@Command AS varchar(2000));
    END;
    
    IF @ExecutionType IN (N'SQLCMD', N'PARTNER') BEGIN
		SET @xpCmd = 'sqlcmd{0} -Q "' + REPLACE(CAST(@Command AS varchar(2000)), @crlf, ' ') + '"';

        IF @ExecutionType = N'SQLCMD' BEGIN 
		    IF @@SERVICENAME <> N'MSSQLSERVER'  -- Account for named instances:
			    SET @serverName = N' .\' + @@SERVICENAME;
	    END; 

	    IF @ExecutionType = N'PARTNER' BEGIN 
		    SELECT @serverName = REPLACE([data_source], N'tcp:', N'') FROM sys.servers WHERE [name] = N'PARTNER';
	    END; 

		SET @xpCmd = REPLACE(@xpCmd, '{0}', ' -S' + @serverName);
    END;

	IF @ExecutionType IN (N'PS', N'PS_CORE') BEGIN 
		--SET @xpCmd = CASE WHEN @ExecutionType = N'PS' THEN 'Powershell ' ELSE 'pwsh ' END + N'-noni -c "' + REPLACE(CAST(@Command AS varchar(2000)), @crlf, ' ') + '"';
		SET @xpCmd = CASE WHEN @ExecutionType = N'PS' THEN 'Powershell ' ELSE 'pwsh ' END + N'-noni -nop -ec ' + dbo.[base64_encode](@Command);
	END;
	
	DECLARE @executionCount int = 0;
	DECLARE @succeeded bit = 0; 
	DECLARE @executionTime datetime;
	DECLARE @exceptionOccurred bit = 0;
    
ExecutionAttempt:
	
	SET @executionCount = @executionCount + 1;
	SET @result = NULL;
	SET @succeeded = 0;
	SET @exceptionOccurred = 0;
	SET @executionTime = GETDATE();

	DELETE FROM #cmd_results;

	IF @PrintOnly = 1 BEGIN 
		PRINT N'-- xp_cmdshell ''' + @xpCmd + ''';';
        --PRINT @xpCmd;
		SET @succeeded = 1; 
		GOTO Terminate;
	END;

	BEGIN TRY 
		--PRINT @xpCmd;
		
		INSERT INTO #cmd_results ([result_text]) 
		EXEC master.sys.[xp_cmdshell] @xpCmd;

		DELETE FROM #cmd_results WHERE [result_text] IS NULL;

		UPDATE r 
		SET 
			r.[ignored_match] = x.[filter_type]
		FROM 
			#cmd_results r
			LEFT OUTER JOIN @filters x ON (r.[result_text] LIKE x.[filter_text]) OR (r.[result_text] = x.[filter_text]) 
				OR (x.[filter_type] IN (N'SAFE', N'SAFE_WILDCARD') AND r.[result_text] = x.[filter_text]); 

		IF EXISTS (SELECT NULL FROM @explicitErrors) BEGIN 
			UPDATE r 
			SET 
				r.[explicit_error] = x.error_text
			FROM 
				[#cmd_results] r 
				INNER JOIN @explicitErrors x ON (r.[result_text] LIKE x.[error_text]) OR (r.[result_text] = x.[error_text]);
		END;

		SELECT @result = (SELECT 
			result_id [result_row/@result_id], 
			CASE WHEN [ignored_match] IN (N'SAFE', N'SAFE_WILDCARD') THEN NULL ELSE [ignored_match] END [result_row/@ignored],
			CASE WHEN [ignored_match] IN (N'SAFE', N'SAFE_WILDCARD') THEN [ignored_match] ELSE NULL END [result_row/@safe],
			[explicit_error] [result_row/@explicit_error],
			CASE 
				WHEN [ignored_match] IS NOT NULL AND [explicit_error] IS NOT NULL THEN 1
				WHEN [ignored_match] IS NULL THEN 1
				ELSE 0 
			END [result_row/@is_error],
			REPLACE([result_text], NCHAR(0), N'') [result_row]
		FROM 
			[#cmd_results] 
		ORDER BY 
			[result_id]
		FOR XML PATH(''), TYPE);

		/* Determine Success or Error based on ... ignored/safe vs explicit errors and ... NULLs/etc. */
		WITH simplified AS ( 
			SELECT 
				CASE 
					WHEN [ignored_match] IS NOT NULL AND [explicit_error] IS NOT NULL THEN 1
					WHEN [ignored_match] IS NULL THEN 1
					ELSE 0 
				END [success]
			FROM 
				[#cmd_results] 
		) 

		SELECT @succeeded = CASE WHEN MAX(success) > 0 THEN 0 ELSE 1 END FROM [simplified];
	END TRY

	BEGIN CATCH 
		WITH faked AS ( 
			SELECT 
				ERROR_NUMBER() [error_number], 
				ERROR_LINE() [error_line], 
				ERROR_SEVERITY() [severity],
				ERROR_MESSAGE() [error_message]
		)
		
		SELECT @result = (SELECT 
			[error_number] [exception/@error_number], 
			[error_line] [exception/@error_line], 
			[severity] [exception/@severity],
			[error_message] [exception]
		FROM 
			faked
		FOR XML PATH(''), TYPE);

		SET @exceptionOccurred = 1;
	END CATCH;

	IF @result IS NOT NULL BEGIN 
		INSERT INTO @iterations ([result], [execution_time], [succeeded], [exception])
		VALUES (@result, @executionTime, @succeeded, @exceptionOccurred);
	END; 

Terminate:
	IF @succeeded = 0 BEGIN 
		IF @executionCount < @ExecutionAttemptsCount BEGIN 
			WAITFOR DELAY @delay; 
			GOTO ExecutionAttempt;
		END;
	END;  

	SELECT @Outcome = (SELECT 
		CASE 
			WHEN [exception] = 1 THEN N'EXCEPTION' 
			WHEN [exception] = 0 AND [succeeded] = 1 THEN N'SUCCEEDED'
			ELSE N'FAILED'
		END [iteration/@execution_outcome],
		[iteration_id] [iteration/@iteration_id],
		[execution_time] [iteration/@execution_time],
		[result] [iteration]
	FROM 
		@iterations 
	ORDER BY 
		[iteration_id] 
	FOR XML PATH(''), ROOT('iterations'), TYPE);

	IF @succeeded = 1
		RETURN 0;

	/* Otherwise: serialize/output error details: */
	SET @ErrorMessage = N'';
	
	WITH core AS ( 
		SELECT 
			[i].[iteration_id],
			x.result_row.value(N'(@result_id)', N'int') [row_id], 
			x.result_row.value(N'(@is_error)', N'bit') [is_error], 
			CAST(0 AS bit) [is_exception],
			x.result_row.value(N'.', N'nvarchar(max)') [content]
		FROM 
			@iterations i  
			CROSS APPLY i.result.nodes(N'/result_row') x(result_row)
		WHERE 
			[i].[exception] = 0

		UNION SELECT 
			[i].[iteration_id],
			1 [row_id], 
			0 [is_error], 
			CAST(1 AS bit) [is_exception],
			N'EXCEPTION::> ErrorNumber: ' + CAST(x.exception.value(N'(@error_number)', N'int') AS sysname) + N', LineNumber: ' + CAST(x.exception.value(N'(@error_line)', N'int') AS sysname) + N', Severity: ' + CAST(x.exception.value(N'(@severity)', N'int') AS sysname) + N', Message: ' + x.exception.value(N'.', N'nvarchar(max)') [content]
			
		FROM 
			@iterations i 
			CROSS APPLY i.result.nodes(N'/exception') x(exception)
	) 

	SELECT 
		@ErrorMessage = @ErrorMessage + [content] + @crlf
	FROM 
		core 
	WHERE 
		[is_error] = 1 OR [is_exception] = 1
	ORDER BY	
		[iteration_id], [row_id];

	RETURN -1;
GO