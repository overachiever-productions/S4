
/*


	INTERPRETING OUTPUT:
		- command outcome/success will be indicated by the RETURN value of dbo.execute_command. 
			If the value is 0, then the @Command sent in either INITIALLY executed as desired or EVENTUALLY executed - based on 'retry' rules. 
			If the value is 1, then the @Command failed. 
			For values other than 0 or 1, dbo.execute_command ran into a bug, problem, unexpected scenario or exception and IT failed. 

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




*/

USE [admindb];
GO

IF OBJECT_ID('dbo.execute_command','P') IS NOT NULL
	DROP PROC dbo.execute_command;
GO

CREATE PROC dbo.execute_command
	@Command								nvarchar(MAX), 
	@ExecutionType							sysname						= N'EXEC',							-- { EXEC | SHELL | PARTNER }
	@ExecutionRetryCount					int							= 2,								-- number of times to try executing process - until either success (no error) or @ExecutionRetryCount reached. 
	@DelayBetweenAttempts					sysname						= N'5s',
	
	@IgnoredResults							nvarchar(2000)				= N'[COMMAND_SUCCESS]',				--  'comma, delimited, list of, wild%card, statements, to ignore, can include, [tokens]'. Allowed Tokens: [COMMAND_SUCCESS] | [USE_DB_SUCCESS] | [ROWS_AFFECTED] | [BACKUP] | [RESTORE] | [SHRINKLOG] | [DBCC] ... 

	@Results								xml							OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:
	IF @ExecutionRetryCount <= 0 SET @ExecutionRetryCount = 1;


	-- if @ExecutionType = PARTNER, make sure we have a PARTNER entry in sys.servers... 


	-- for SHELL and PARTNER... final 'statement' needs to be varchar(4000) or less. 

	DECLARE @delay sysname; 
	DECLARE @error nvarchar(MAX);
	EXEC [admindb].dbo.[translate_vector_delay]
	    @Vector = @DelayBetweenAttempts,
	    @ParameterName = N'@DelayBetweenAttempts',
	    @Output = @delay OUTPUT, 
	    @Error = @error OUTPUT;

	IF @error IS NOT NULL BEGIN 
		RAISERROR(@error, 16, 1);
		RETURN -5;
	END;

	-----------------------------------------------------------------------------
	-- Processing: 
	DECLARE @ExecutionAttemptCount int = 0; -- set to 1 during first exectuion attempt:
	DECLARE @succeeded bit = 0;

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
			('RESTORE', 'RESTORE DATABASE ... FILE=<name> successfully processed % pages in % seconds %).');  -- partial recovery operations... 
		
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

	SET @xpCmd = 'sqlcmd {0} -q "' + REPLACE(@Command, @crlf, ' ') + '"';
	IF UPPER(@ExecutionType) = N'SHELL' BEGIN 
		
		IF @@SERVICENAME <> N'MSSQLSERVER'  -- Account for named instances:
			SET @serverName = N' -S .\' + @@SERVICENAME;
		
		SET @xpCmd = REPLACE(@xpCmd, '{0}', @serverName);
	END; 

	IF UPPER(@ExecutionType) = N'PARTNER' BEGIN 
		SELECT @serverName = REPLACE(data_source, N'tcp:', N'') FROM sys.servers WHERE [name] = N'PARTNER';

-- TODO: ensure that this accounts for named instances:
		SET @xpCmd = REPLACE(@xpCmd, '{0}', ' -S' + @serverName);
	END; 
	
ExecutionAttempt:
	
	SET @ExecutionAttemptCount = @ExecutionAttemptCount + 1;
	SET @result = NULL;

	BEGIN TRY 

		IF UPPER(@ExecutionType) = N'EXEC' BEGIN 
			
			EXEC sp_executesql @Command; 
			SET @succeeded = 1;

		  END; 
		ELSE BEGIN 
			DELETE FROM #Results;

			INSERT INTO #Results (result) 
			EXEC master.sys.[xp_cmdshell] @xpCmd;

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
		IF @ExecutionAttemptCount < @ExecutionRetryCount BEGIN 
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
