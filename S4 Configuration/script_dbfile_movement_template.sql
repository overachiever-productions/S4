/*



	SAMPLE EXECUTIONS: 
		EXEC [dbo].[script_dbfile_movement_template]
			@TargetDatabase = N'TeamSupportNA4',
			@TargetFiles = N'{LOG}',
			@NewDirectory = N'D:\SQLLogs',
			@RollbackImmediate = 1;


		EXEC [dbo].[script_dbfile_movement_template]
			@TargetDatabase = N'TeamSupportNA4',
			@TargetFiles = N'{ALL}',
			@NewDirectory = N'D:\SQLLogs',
			@RollbackImmediate = 1;


		EXEC [dbo].[script_dbfile_movement_template]
			@TargetDatabase = N'TeamSupportNA4',
			@TargetFiles = N'TeamSupportNA4_log, TeamSupportNA4',
			@NewDirectory = N'D:\SQLLogs',
			@RollbackImmediate = 1;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_dbfile_movement_template','P') IS NOT NULL
	DROP PROC dbo.[script_dbfile_movement_template];
GO

CREATE PROC dbo.[script_dbfile_movement_template]
	@TargetDatabase						sysname, 
	@TargetFiles						sysname,										-- {ALL} | {LOG} {DATA} | logical_filename, logical_filename2 
	@NewDirectory						sysname,
	@RollbackImmediate					bit				= 0,
	@RollbackSeconds					int				= 5	
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SET @TargetFiles = NULLIF(@TargetFiles, N'');
	SET @NewDirectory = NULLIF(@NewDirectory, N'');

	SET @RollbackImmediate = ISNULL(@RollbackImmediate, 0);
	SET @RollbackSeconds = ISNULL(@RollbackSeconds, 5);

	DECLARE @rollback sysname = N'AFTER ' + CAST(@RollbackSeconds AS sysname) + N' SECONDS';
	IF @RollbackImmediate = 1 SET @rollback = N'IMMEDIATE';


	IF UPPER(@TargetDatabase) NOT IN (SELECT UPPER([name]) FROM sys.databases) BEGIN
		RAISERROR(N'@TargetDatabase ''%s'' was not found.', 16, 1, @TargetDatabase);
		RETURN -1;
	END;

	DECLARE @filesToMove table (
		[file_id] int NOT NULL, 
		[file_name] sysname NOT NULL, 
		[current_location] nvarchar(2000) NOT NULL, 
		[new_location] nvarchar(2000) NOT NULL
	); 

	DECLARE @sourceDirectory sysname;
	   
	IF UPPER(@TargetFiles) IN (N'{ALL}', N'{DATA}') BEGIN
		INSERT INTO @filesToMove (
			[file_id],
			[file_name],
			[current_location],
			[new_location]
		)
		SELECT 
			[file_id], 
			[name], 
			[physical_name] [current_location], 
			REPLACE([physical_name], dbo.extract_directory_from_fullpath([physical_name]), @NewDirectory)
		FROM 
			[master].sys.[master_files]
		WHERE 
			[database_id] = DB_ID(@TargetDatabase)
			AND [type_desc] = N'ROWS';
	END;

	IF UPPER(@TargetFiles) IN (N'{ALL}', N'{LOG}') BEGIN
		
		INSERT INTO @filesToMove (
			[file_id],
			[file_name],
			[current_location],
			[new_location]
		)
		SELECT 
			[file_id], 
			[name], 
			[physical_name] [current_location], 
			REPLACE([physical_name], dbo.extract_directory_from_fullpath([physical_name]), @NewDirectory)
		FROM 
			[master].sys.[master_files]
		WHERE 
			[database_id] = DB_ID(@TargetDatabase)
			AND [type_desc] = N'LOG';
	END;

	IF UPPER(@TargetFiles) NOT IN (N'{ALL}', N'{DATA}', N'{LOG}') BEGIN 
		
		INSERT INTO @filesToMove (
			[file_id],
			[file_name],
			[current_location],
			[new_location]
		)
		SELECT 
			[file_id], 
			[name], 
			[physical_name] [current_location], 
			REPLACE([physical_name], dbo.extract_directory_from_fullpath([physical_name]), @NewDirectory)
		FROM 
			[master].sys.[master_files]
		WHERE 
			[database_id] = DB_ID(@TargetDatabase)
			AND [name] IN (SELECT [result] FROM dbo.[split_string](@TargetFiles, N',', 1));
	END;

	DECLARE @template nvarchar(MAX) = N'USE [{targetDatabase}]; 
GO

---------------------------------------------------------------------------------------------------------------------------------------------------
-- Knock Offline: 
ALTER DATABASE [{targetDatabase}] SET SINGLE_USER WITH ROLLBACK {rollback}; 

USE [master]; 

ALTER DATABASE [{targetDatabase}] SET OFFLINE; 
GO 

{fileMoves}

---------------------------------------------------------------------------------------------------------------------------------------------------
-- Bring Back Online: 
ALTER DATABASE [{targetDatabase}] SET ONLINE;
ALTER DATABASE [{targetDatabase}] SET MULTI_USER;
GO

SELECT * FROM sys.master_files WHERE database_id = DB_ID(''{targetDatabase}''); 
'; 
	
	DECLARE @filesMoveTemplate nvarchar(MAX) = N'---------------------------------------------------------------------------------------------------------------------------------------------------
-- MOVE {sourceFilePath} to {targetFilePath}
EXEC xp_cmdshell ''copy "{sourceFilePath}" "{targetFilePath}"'';
EXEC xp_cmdshell ''rename "{sourceFilePath}" "{sourceFileName}.old"'';

ALTER DATABASE [{targetDatabase}] 
	MODIFY FILE (NAME = {logicalName}, FILENAME = ''{targetFilePath}'');
GO 

'; 

	DECLARE @filesMove nvarchar(MAX) = N'';
	DECLARE @directives nvarchar(MAX);

	DECLARE @currentLocation sysname, @newLocation sysname, @logicalName sysname;
	DECLARE @sourceFileName sysname;

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[file_name],
		[current_location],
		[new_location] 
	FROM 
		@filesToMove 
	ORDER BY 
		[file_id];
		
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @logicalName, @currentLocation, @newLocation;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @directives = @filesMoveTemplate;

		SELECT @sourceFileName = dbo.extract_filename_from_fullpath(@currentLocation);

		SET @directives = REPLACE(@directives, N'{sourceFilePath}', @currentLocation);
		SET @directives = REPLACE(@directives, N'{sourceFileName}', @sourceFileName);
		SET @directives = REPLACE(@directives, N'{targetFilePath}', @newLocation);
		SET @directives = REPLACE(@directives, N'{logicalName}', @logicalName);

		SET @filesMove = @filesMove + @directives;
	
		FETCH NEXT FROM [walker] INTO @logicalName, @currentLocation, @newLocation;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	DECLARE @sql nvarchar(MAX) = @template; 

	SET @sql = REPLACE(@sql, N'{fileMoves}', @filesMove);
	SET @sql = REPLACE(@sql, N'{targetDatabase}', @TargetDatabase);
	SET @sql = REPLACE(@sql, N'{rollback}', @rollback);


	EXEC [dbo].[print_long_string] @sql;

	RETURN 0; 
GO