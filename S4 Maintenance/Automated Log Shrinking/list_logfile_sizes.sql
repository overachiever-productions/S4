/*

    NOTE: 
        - This sproc adheres to the PROJECT/REPLY usage convention.

	General Workflows: 
		- dbo.list_logfile_sizes  
			- spits out dbname, dbsize, logsize, log-file-size-as-percentage-of-db-size... , vlf count, current minimum size? 
			- can spit out as 'report' or as xml. 

		- dbo.shrink_logfiles 

			- FODDER??? https://tracyboggiano.com/archive/2017/09/high-vlf-count-fix/

			- get a list of those that need to be resized... 
			- attempte the resize...   (note: don't use a SPROC here... just send a "USE {dbname}; DBCC SHRINKFILE(2, {targetSize}); etc... " command to dbo.execute_command
			- get a list of those that STILL need to be resized... 
			- force backups and/or WAIT for backups (probably a better idea?)
					yeah, probably better to set an @WaitDurationForLogBackups = '12m' and ... @NumberOfTimesToWait... 

			- run CHECKPOINT (via execute_command)... 

			- retest/etc. 

			- send an email on any that were resized within X of the target and ... on any that could NOT be resized...



EXEC list_logfile_sizes
	@TargetDatabases = N'{ALL}';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_logfile_sizes','P') IS NOT NULL
	DROP PROC dbo.list_logfile_sizes;
GO

CREATE PROC dbo.list_logfile_sizes
	@TargetDatabases					nvarchar(MAX),															-- { {ALL} | {SYSTEM} | {USER} | name1,name2,etc }
	@DatabasesToExclude					nvarchar(MAX)							= NULL,							-- { NULL | name1,name2 }  
	@Priorities							nvarchar(MAX)							= NULL,
	@ExcludeSimpleRecoveryDatabases		bit										= 1,
	@SerializedOutput					xml										= N'<default/>'			OUTPUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs:




	-----------------------------------------------------------------------------
	
	CREATE TABLE #targetDatabases ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[vlf_count] int NULL, 
		[mimimum_allowable_log_size_gb] decimal(20,2) NULL
	);

	INSERT INTO [#targetDatabases] ([database_name])
	EXEC dbo.list_databases
		@Targets = @TargetDatabases, 
		@Exclusions = @DatabasesToExclude, 
		@Priorities = @Priorities, 
		@ExcludeSimpleRecovery = @ExcludeSimpleRecoveryDatabases;

	CREATE TABLE #logs (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[recovery_model] sysname NOT NULL,
		[database_size_gb] decimal(20,2) NOT NULL, 
		[log_size_gb] decimal(20,2) NOT NULL, 
		[log_percent_used] decimal(5,2) NOT NULL,
		[vlf_count] int NOT NULL,
		[log_as_percent_of_db_size] decimal(5,2) NULL, 
		[mimimum_allowable_log_size_gb] decimal(20,2) NOT NULL 
	);
	
	IF NOT EXISTS (SELECT NULL FROM [#targetDatabases]) BEGIN 
		PRINT 'No databases matched @TargetDatbases (and @DatabasesToExclude) Inputs.'; 
		SELECT * FROM [#logs];
		RETURN 0; -- success (ish).
	END;

	DECLARE walker CURSOR LOCAL READ_ONLY FAST_FORWARD FOR 
	SELECT [database_name] FROM [#targetDatabases];

	DECLARE @currentDBName sysname; 
	DECLARE @vlfCount int; 
	DECLARE @startOffset bigint;
	DECLARE @fileSize bigint;
	DECLARE @MinAllowableSize decimal(20,2);

	DECLARE @template nvarchar(1000) = N'INSERT INTO #logInfo EXECUTE (''DBCC LOGINFO([{0}]) WITH NO_INFOMSGS''); ';
	DECLARE @command nvarchar(2000);

	CREATE TABLE #logInfo (
		RecoveryUnitId bigint,
		FileID bigint,
		FileSize bigint,
		StartOffset bigint,
		FSeqNo bigint,
		[Status] bigint,
		Parity bigint,
		CreateLSN varchar(50)
	);

	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDBName;

	WHILE @@FETCH_STATUS = 0 BEGIN 
		
		DELETE FROM [#logInfo];
		SET @command = REPLACE(@template, N'{0}', @currentDBName); 

		EXEC master.sys.[sp_executesql] @command;
		SELECT @vlfCount = COUNT(*) FROM [#logInfo];

		SELECT @startOffset = MAX(StartOffset) FROM #LogInfo WHERE [Status] = 2;
		SELECT @fileSize = FileSize FROM #LogInfo WHERE StartOffset = @startOffset;
		SET @MinAllowableSize = CAST(((@startOffset + @fileSize) / (1024.0 * 1024.0 * 1024.0)) AS decimal(20,2))

		UPDATE [#targetDatabases] 
		SET 
			[vlf_count] = @vlfCount, 
			[mimimum_allowable_log_size_gb] = @MinAllowableSize 
		WHERE 
			[database_name] = @currentDBName;

		FETCH NEXT FROM [walker] INTO @currentDBName;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	WITH core AS ( 
		SELECT
			x.[row_id],
			db.[name] [database_name], 
			db.recovery_model_desc [recovery_model],	
			CAST((CONVERT(decimal(20,2), sizes.size * 8.0 / (1024.0) / (1024.0))) AS decimal(20,2)) database_size_gb,
			CAST((logsize.log_size / (1024.0)) AS decimal(20,2)) [log_size_gb],
			CASE 
				WHEN logsize.log_size = 0 THEN 0.0
				WHEN logused.log_used = 0 THEN 0.0
				ELSE CAST(((logused.log_used / logsize.log_size) * 100.0) AS decimal(5,2))
			END log_percent_used, 
			x.[vlf_count], 
			x.[mimimum_allowable_log_size_gb]
		FROM 
			sys.databases db
			INNER JOIN #targetDatabases x ON db.[name] = x.[database_name]
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / (1024.0)) AS decimal(20,2)) [log_size] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Size %') logsize ON db.[name] = logsize.[db_name]
			LEFT OUTER JOIN (SELECT instance_name [db_name], CAST((cntr_value / (1024.0)) AS decimal(20,2)) [log_used] FROM sys.dm_os_performance_counters WHERE counter_name LIKE 'Log File(s) Used %') logused ON db.[name] = logused.[db_name]
			LEFT OUTER JOIN (
				SELECT	database_id, SUM(size) size, COUNT(database_id) [Files] FROM sys.master_files WHERE [type] = 0 GROUP BY database_id
			) sizes ON db.database_id = sizes.database_id		
	) 

	INSERT INTO [#logs] (
        [database_name], 
        [recovery_model], 
        [database_size_gb], 
        [log_size_gb], 
        [log_percent_used], 
		[vlf_count],
		[log_as_percent_of_db_size], 
		[mimimum_allowable_log_size_gb] 
    )
	SELECT 
        [database_name],
        [recovery_model],
        [database_size_gb],
        [log_size_gb],
        [log_percent_used], 
		[vlf_count],
		CAST(((([log_size_gb] / CASE WHEN [database_size_gb] = 0 THEN 0.01 ELSE [core].[database_size_gb] END) * 100.0)) AS decimal(20,2)) [log_as_percent_of_db_size],		-- goofy issue with divide by zero is reason for CASE... 
		[mimimum_allowable_log_size_gb]
	FROM 
		[core]
	ORDER BY 
		[row_id];
	
	-----------------------------------------------------------------------------
    -- Send output as XML if requested:
	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY...
		SELECT @SerializedOutput = (SELECT 
			[database_name],
			[recovery_model],
			[database_size_gb],
			[log_size_gb],
			[log_percent_used],
			[vlf_count],  -- 160x
			[log_as_percent_of_db_size], 
			[mimimum_allowable_log_size_gb] 
		FROM 
			[#logs]
		ORDER BY 
			[row_id] 
		FOR XML PATH('database'), ROOT('databases'));

		RETURN 0;
	END; 

	-----------------------------------------------------------------------------
	-- otherwise, project:
	SELECT 
        [database_name],
        [recovery_model],
        [database_size_gb],
        [log_size_gb],
        [log_percent_used],
		[vlf_count],  -- 180x
		[log_as_percent_of_db_size], 
		[mimimum_allowable_log_size_gb] 
	FROM 
		[#logs]
	ORDER BY 
		[row_id];

	RETURN 0;
GO