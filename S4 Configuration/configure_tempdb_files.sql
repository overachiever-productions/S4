/*

	NOTES:
		- current implementation = MVP implementation

		- Only expects/accounts for 1x log file (anything else is a serious edge-case and/or bad/wrong/weird).


	WARNING: 
		- This script requires a RESTART of SQL Server if setting files to smaller size or lower-file-count. 
	
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.configure_tempdb_files','P') IS NOT NULL
	DROP PROC dbo.[configure_tempdb_files];
GO

CREATE PROC dbo.[configure_tempdb_files]
	@TargetDataFileCount				int				= NULL, 
	@TargetDataFilePath					sysname			= NULL, 
	@TargetLogFilePath					sysname			= NULL, 
	@DataFileStartSizeInMBs				int				= NULL, 
	@DataFileGrowthSizeInMBs			int				= NULL,
	@DataFileMaxSizeInMBs				int				= NULL, 
	@LogFileStartSizeInMBs				int				= NULL, 
	@LogFileGrowthSizeInMBs				int				= NULL, 
	@LogFileMaxSizeInMBs				int				= NULL, 
	@PrintOnly							bit				= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDataFilePath	= NULLIF(@TargetDataFilePath, N'');
	SET @TargetLogFilePath	= NULLIF(@TargetLogFilePath, N'');

	-- Normalize Paths: 
	IF @TargetDataFilePath IS NOT NULL AND @TargetDataFilePath NOT LIKE N'%\' SET @TargetDataFilePath = @TargetDataFilePath + N'\';
	IF @TargetLogFilePath IS NOT NULL AND @TargetLogFilePath NOT LIKE N'%\' SET @TargetLogFilePath = @TargetLogFilePath + N'\';

	DECLARE @currentDataFilesCount int; 
	SELECT @currentDataFilesCount = COUNT(*) FROM [tempdb].sys.[database_files] WHERE [type] = 0;

	DECLARE @removeTemplate nvarchar(MAX) = N'ALTER DATABASE [tempdb] REMOVE FILE [{name}]; ';
	--DECLARE @removeTemplate nvarchar(MAX) = N'EXEC admindb.dbo.force_removal_of_tempdb_file @FileName = N''{name}'', @Force = N''FORCE''; ';
	DECLARE @addTemplate nvarchar(MAX) = N'ALTER DATABASE [tempdb] ADD FILE (NAME = ''{name}'', FILENAME = ''{fileName}'', SIZE = {size}, MAXSIZE = {maxSize}, FILEGROWTH = {growth}); ';
	DECLARE @modifyTemplate nvarchar(MAX) = N'ALTER DATABASE [tempdb] MODIFY FILE (NAME = ''{name}'', FILENAME = ''{path}{name}.ndf''); ';
	DECLARE @modifyLogTemplate nvarchar(MAX) = N'ALTER DATABASE [tempdb] MODIFY FILE (NAME =''{name}'', FILENAME = ''{fileName}''); ';

	DECLARE @command nvarchar(MAX);
	DECLARE @currentFileName sysname;
	DECLARE @currentFilePhysicalName nvarchar(260);

	DECLARE @oldPathName nvarchar(260);
	DECLARE @newPathName nvarchar(260);

	DECLARE @commands table (
		command_id int IDENTITY(1, 1) NOT NULL, 
		command nvarchar(MAX) NOT NULL 
	);

	-- Modify existing files if needed: 
	IF @TargetDataFilePath IS NOT NULL BEGIN 
		IF EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE [type] = 0 AND [physical_name] NOT LIKE @TargetDataFilePath + N'%') BEGIN
			
			SET @modifyTemplate = REPLACE(@modifyTemplate, N'{path}', @TargetDataFilePath);

			INSERT INTO  @commands (
				[command]
			)
			SELECT 
				REPLACE(@modifyTemplate, N'{name}', [name])
			FROM 
				[tempdb].sys.[database_files] 
			WHERE 
				[type] = 0 
				AND [physical_name] NOT LIKE @TargetDataFilePath + N'%' 
			ORDER BY 
				[file_id];

		END;
	END;

	-- account for removing files (if target count is < current file count):
	IF @currentDataFilesCount > @TargetDataFileCount BEGIN
		
		DECLARE @currentRemovedFileID int;
		DECLARE @currentRemovedFile sysname;

		DECLARE remover CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[x].[data_file_id], 
			[x].[name]
		FROM (
			SELECT 
				ROW_NUMBER() OVER (ORDER BY file_id) [data_file_id], 
				[name] 
			FROM 
				tempdb.sys.[database_files] 
			WHERE 
				[type] = 0
			) x 
		WHERE 
			[x].[data_file_id] > @TargetDataFileCount
		ORDER BY 
			[x].[data_file_id];
		
		
		OPEN remover;
		FETCH NEXT FROM remover INTO @currentRemovedFileID, @currentRemovedFile;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			SET @command = REPLACE(@removeTemplate, N'{name}', @currentRemovedFile);

			INSERT INTO @commands (command) VALUES (@command);
		
			FETCH NEXT FROM remover INTO @currentRemovedFileID, @currentRemovedFile;
		END;
		
		CLOSE remover;
		DEALLOCATE remover;

	END;

	-- add additional data files (if desired file count > current count):
	IF @TargetDataFileCount > @currentDataFilesCount BEGIN 
		DECLARE @fileNamePattern sysname;  

		SELECT @fileNamePattern = [name] FROM [tempdb].sys.[database_files] WHERE [file_id] = 3;

		-- simplified implementation for now: 
		IF @fileNamePattern IS NOT NULL BEGIN
			IF RIGHT(@fileNamePattern, 1) = N'2' BEGIN
				SET @fileNamePattern = REPLACE(@fileNamePattern, N'2', N'');
			END;
		END;

		IF @fileNamePattern IS NULL 
			SET @fileNamePattern = N'tempdev'; 

		IF @TargetDataFilePath IS NULL BEGIN 
			SELECT 
				@currentFilePhysicalName = [physical_name]
			FROM 
				[tempdb].sys.[database_files] 
			WHERE 
				file_id = 1;

			SET @TargetDataFilePath = LEFT(@currentFilePhysicalName, 1 + LEN(@currentFilePhysicalName) - CHARINDEX(N'\', REVERSE(@currentFilePhysicalName)));
		END;

-- until vNEXT: 
DECLARE @size sysname; 
DECLARE @maxSize sysname; 
DECLARE @growth sysname;

SELECT
	@size = CAST(([size] * 8) AS sysname) + N'KB', 
	@maxSize = CASE WHEN [max_size] = -1 THEN N'UNLIMITED' WHEN [max_size] = 0 THEN N'0' ELSE CAST(([max_size] * 8) AS sysname) + N'KB' END,
	@growth = CASE WHEN [growth] = 0 THEN N'0' ELSE CAST(([growth] * 8) AS sysname) + N'KB' END
FROM 
	[tempdb].sys.[database_files] 
WHERE 
	[file_id] = 1;

		DECLARE @currentFileCount int = @currentDataFilesCount;

		WHILE @currentFileCount < @TargetDataFileCount BEGIN 

			SET @command = REPLACE(@addTemplate, N'{name}', @fileNamePattern + CAST(@currentFileCount + 1 AS sysname));
			SET @command = REPLACE(@command, N'{fileName}', @TargetDataFilePath + @fileNamePattern + CAST(@currentFileCount + 1 AS sysname) + N'.ndf');

			SET @command = REPLACE(@command, N'{size}', @size);
			SET @command = REPLACE(@command, N'{maxSize}', @maxSize);
			SET @command = REPLACE(@command, N'{growth}', @growth);

			INSERT INTO @commands (command) VALUES (@command);

			SET @currentFileCount = @currentFileCount + 1;
		END;
	END;

	-- move the tempdb log if needed:
	IF @TargetLogFilePath IS NOT NULL BEGIN 
		IF EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE [type] = 1 AND [physical_name] NOT LIKE @TargetLogFilePath + N'%') BEGIN
			SELECT 
				@currentFileName = [name], 
				@currentFilePhysicalName = [physical_name]
			FROM 
				[tempdb].sys.[database_files] 
			WHERE 
				file_id = 2;

			SET @oldPathName = LEFT(@currentFilePhysicalName, 1 + LEN(@currentFilePhysicalName) - CHARINDEX(N'\', REVERSE(@currentFilePhysicalName)));
			SET @newPathName = REPLACE(@currentFilePhysicalName, @oldPathName, @TargetLogFilePath);

			SET @command = REPLACE(@modifyLogTemplate, N'{name}', @currentFileName);
			SET @command = REPLACE(@command, N'{fileName}', @newPathName);

			INSERT INTO @commands (command) VALUES (@command);
		END;
	END;
	
	-- Process/Finalize:
	DECLARE runner CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		command 
	FROM 
		@commands 
	ORDER BY 
		command_id;
		
	OPEN runner;
	FETCH NEXT FROM runner INTO @command;
		
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		IF @PrintOnly = 1 BEGIN
			PRINT @command;
			PRINT N'GO'
			PRINT N'';
		  END; 
		ELSE BEGIN 
			EXEC sp_executesql @command;
		END;
		
		FETCH NEXT FROM runner INTO @command;
	END;
		
	CLOSE runner;
	DEALLOCATE runner;

	RETURN 0;
GO