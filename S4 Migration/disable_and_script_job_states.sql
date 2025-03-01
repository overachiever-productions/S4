/*

	REWRITE (not REFACTOR):
		The functionality here is great. 
		The ... naming and @Params are a train-wreck. 

		i.e., sprocs should, IDEALLY, do 'one' thing. 
			This has an AND in the name - which indicates an immediate problem. 

		ALSO... 
			if I JUST want to SCRIPT the enabled/disabled statuses ... 
			that's what? @PrintOnly = 1?

		LIKEWISE
			what if I just want to DISABLE jobs - and not script their states? 

		i.e., this needs to be 2x sprocs. 
			dbo.script_job_states
			dbo.disable_agent_jobs

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.disable_and_script_job_states','P') IS NOT NULL
	DROP PROC dbo.[disable_and_script_job_states];
GO

CREATE PROC dbo.[disable_and_script_job_states]
	@ExcludedJobs				nvarchar(MAX)	= NULL, 
	@SummarizeExcludedJobs		bit				= 1,
	@ScriptDirectives			sysname			= N'ENABLE_AND_DISABLE',	-- { ENABLE | ENABLE_AND_DISABLE }
	@PrintOnly					bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExcludedJobs = NULLIF(@ExcludedJobs, N'');
	SET @ScriptDirectives = UPPER(ISNULL(NULLIF(@ScriptDirectives, N''), N'ENABLE_AND_DISABLE'));;

	DECLARE @exclusions table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[job_name] sysname NOT NULL
	); 

	IF @ExcludedJobs IS NOT NULL BEGIN 
		INSERT INTO @exclusions (
			[job_name]
		)
		SELECT [result] FROM [admindb].[dbo].[split_string](@ExcludedJobs, N',', 1) ORDER BY [row_id];
	END;

	SELECT 
		[j].[name], 
		[j].[job_id],
		[j].[enabled],
		CASE WHEN [x].[job_name] IS NULL THEN 0 ELSE 1 END [excluded]
	INTO 
		#jobStates
	FROM 
		[msdb].dbo.[sysjobs] [j]
		LEFT OUTER JOIN @exclusions [x] ON [j].[name] LIKE [x].[job_name]
	ORDER BY 
		[j].[name];


	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @enabled nchar(3) = N'[+]';
	DECLARE @disabled nchar(3) = N'[_]';
	DECLARE @ignoredEnabled nchar(3) = N'[*]';
	DECLARE @ignoredDisabled nchar(3) = N'[.]';

	PRINT N'-----------------------------------------------------------------------------------------------------------------------------------------------------';
	PRINT N'-- PRE-CHANGE JOB STATES:  ' + @disabled + N' = disabled, ' + @enabled + N' = enabled ';
	PRINT N'-----------------------------------------------------------------------------------------------------------------------------------------------------';

	DECLARE @summary nvarchar(MAX) = N'';

	SELECT 
		@summary = @summary + CASE WHEN [enabled] = 1 THEN @enabled ELSE @disabled END + N' - ' + [name] + @crlf
	FROM 
		[#jobStates] 
	WHERE 
		[excluded] = 0 
	ORDER BY 
		[name];

	EXEC [dbo].[print_long_string] @summary;

	IF @SummarizeExcludedJobs = 1 BEGIN 
		IF EXISTS (SELECT NULL FROM [#jobStates] WHERE [excluded] = 1) BEGIN 

			PRINT @crlf;
			PRINT N'--------------------------------------------------------------------------------';
			PRINT N'-- IGNORED JOBS STATES: ' + @ignoredDisabled + N' = disabled (ignored), ' + @ignoredEnabled + N' = enabled (ignored)';
			PRINT N'--------------------------------------------------------------------------------';
			SET @summary = N'';

			SELECT 
				@summary = @summary + CASE WHEN [enabled] = 1 THEN @ignoredEnabled ELSE @ignoredDisabled END + N' - ' + [name] + @crlf
			FROM 
				[#jobStates] 
			WHERE 
				[excluded] = 1 
			ORDER BY 
				[name];

			EXEC dbo.[print_long_string] @summary;
		END;
	END;

	PRINT @crlf;
	PRINT N'---------------------------------------------------------------------------------------------------------------------';
	PRINT N'-- RE-ENABLE' + CASE @ScriptDirectives WHEN N'ENABLE_AND_DISABLE' THEN ' + RE-DISABLE' ELSE N'' END + N' DIRECTIVES: ';
	PRINT N'---------------------------------------------------------------------------------------------------------------------';

	DECLARE @enablingTemplate nvarchar(MAX) = N'
-- Enabling Job [{job_name}]. State When Scripted: ENABLED, JobID: [{job_id}]. Generated: [{timestamp}]
EXEC msdb.dbo.sp_update_job
	@job_name = N''{job_name}'', 
	@enabled = 1;
GO
';

	DECLARE @disablingTemplate nvarchar(MAX) = N'
-- Disabling Job [{job_name}]. State When Scripted: DISABLED, JobID: [{job_id}]. Generated: [{timestamp}]
EXEC msdb.dbo.sp_update_job
	@job_name = N''{job_name}'', 
	@enabled = 0;
GO
';

	DECLARE @sql nvarchar(MAX) = N'';
	DECLARE @jobName sysname, @jobId uniqueidentifier, @jobEnabled bit;

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[name],
		[job_id],
		[enabled]
	FROM 
		[#jobStates] 
	WHERE 
		[excluded] = 0 
	ORDER BY 
		[name];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @jobName, @jobId, @jobEnabled;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		IF @jobEnabled = 1 BEGIN 
			SET @sql = REPLACE(@enablingTemplate, N'{job_name}', @jobName);
			SET @sql = REPLACE(@sql, N'{timestamp}', CONVERT(sysname, GETDATE(), 120));
			SET @sql = REPLACE(@sql, N'{job_id}', @jobId);

			PRINT @sql;

		  END; 
		ELSE BEGIN 
			IF @ScriptDirectives = N'ENABLE_AND_DISABLE' BEGIN
				SET @sql = REPLACE(@disablingTemplate, N'{job_name}', @jobName);
				SET @sql = REPLACE(@sql, N'{timestamp}', CONVERT(sysname, GETDATE(), 120));
				SET @sql = REPLACE(@sql, N'{job_id}', @jobId);

				PRINT @sql;				
			END;
		END;
	
		FETCH NEXT FROM [walker] INTO @jobName, @jobId, @jobEnabled;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	PRINT @crlf;

	IF @PrintOnly = 1 BEGIN 
		PRINT N'---------------------------------------------------------------------------------------------------------------------';
		PRINT N'-- @PrintOnly = 1.  Printing DISABLE commands (vs executing)...';
		PRINT N'---------------------------------------------------------------------------------------------------------------------';		
	END;

	DECLARE [disabler] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[job_id], [name]
	FROM 
		[#jobStates] 
	WHERE 
		[excluded] = 0 
		AND [enabled] = 1 
	ORDER BY 
		[name];
	
	OPEN [disabler];
	FETCH NEXT FROM [disabler] INTO @jobId, @jobName;

	WHILE @@FETCH_STATUS = 0 BEGIN
	
		IF @PrintOnly = 1 BEGIN 
			PRINT N'-- DISABLE JOB: ' + @jobName + N'.';
			PRINT 'EXEC msdb..sp_update_job @job_id = ''' + CAST(@jobId AS sysname) + N''', @enabled = 0; ';
			PRINT N'GO';
			PRINT N'';
		  END;
		ELSE BEGIN 
			EXEC [msdb]..[sp_update_job]
				@job_id = @jobId,
				@enabled = 0;
		END;
	
		FETCH NEXT FROM [disabler] INTO @jobId, @jobName;
	END;
	
	CLOSE [disabler];
	DEALLOCATE [disabler];
	
	RETURN 0; 
GO