/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.force_removal_of_tempdb_file','P') IS NOT NULL
	DROP PROC dbo.[force_removal_of_tempdb_file];
GO

CREATE PROC dbo.[force_removal_of_tempdb_file]
	@FileName			sysname			= NULL, 
	@Force				sysname			= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @FileName = NULLIF(@FileName, N'');
	SET @Force = NULLIF(@Force, N'');

	IF @FileName IS NULL BEGIN 
		RAISERROR('Please specify the logical file name of a file for @FileName to continue.', 16, 1);
		RETURN -1;
	END;
	
	IF @Force IS NULL OR @Force <> N'FORCE' BEGIN 
		RAISERROR('Forcibly removing a data-file from the tempdb REQUIRES dropping plans and buffers from the cache. @Force MUST be set to ''FORCE'' before this script will run.', 16, 1);
		RETURN -2;
	END;
	
	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName) BEGIN 
		RAISERROR('A tempdb file matching the name ''%s'' was not found. Please check the input of @FileName and try again.', 16, 1, @FileName);
		RETURN -5;
	END;

	DECLARE @command nvarchar(MAX); 
	SET @command = N'ALTER DATABASE [tempdb] REMOVE FILE [' + @FileName + N']; ';

	BEGIN TRY 
		EXEC sp_executesql @command;
	END TRY
	BEGIN CATCH
		PRINT ''
	END CATCH

	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName)
		GOTO Done;

	SET @command = N'USE [tempdb]; DBCC SHRINKFILE(''' + @FileName + N''', EMPTYFILE) WITH NO_INFOMSGS;';

	BEGIN TRY 
		EXEC sp_executesql @command;
	END TRY
	BEGIN CATCH
		PRINT ''
	END CATCH

	SET @command = N'ALTER DATABASE [tempdb] REMOVE FILE [' + @FileName + N']; ';

	BEGIN TRY 
		EXEC sp_executesql @command;
	END TRY
	BEGIN CATCH
		PRINT ''
	END CATCH

	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName)
		GOTO Done;	

	-- If we're still here: 
	SET @command = N'DBCC FREESYSTEMCACHE (''ALL'');
	DBCC FREESESSIONCACHE();
	DBCC DROPCLEANBUFFERS();
	DBCC FREEPROCCACHE();';

	BEGIN TRY 
		EXEC sp_executesql @command;
	END TRY
	BEGIN CATCH
		PRINT ''
	END CATCH

	SET @command = N'ALTER DATABASE [tempdb] REMOVE FILE [' + @FileName + N']; ';

	BEGIN TRY 
		EXEC sp_executesql @command;
	END TRY
	BEGIN CATCH
		PRINT ''
	END CATCH

	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName)
		GOTO Done;	

	PRINT 'Unable to remove file. Recommend WAITING for 60 - 80 seconds, then a restart of SQL Server Service if needed.';
	RETURN -100;
	
Done: 
	PRINT 'File Removed';
	
	RETURN 0; 
GO

--	DECLARE @output xml;
--	DECLARE @command nvarchar(MAX); 
--	DECLARE @removeCommand nvarchar(MAX);

--	SET @removeCommand = N'ALTER DATABASE [tempdb] REMOVE FILE [' + @FileName + N']; ';
--	SET @command = @removeCommand;

--	EXEC dbo.[execute_command]
--		@Command = @command,
--		@ExecutionType = N'SQLCMD',
--		@ExecutionAttemptsCount = 1,
--		@DelayBetweenAttempts = 0,
--		@IgnoredResults = N'',
--		@Results = @output OUTPUT;

--	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName)
--		GOTO Done;
		
--	SET @command = N'USE [tempdb]; DBCC SHRINKFILE(''' + @FileName + N''', EMPTYFILE);';

--	EXEC dbo.[execute_command]
--		@Command = @command,
--		@ExecutionType = N'SQLCMD',
--		@ExecutionAttemptsCount = 1,
--		@DelayBetweenAttempts = 0,
--		@IgnoredResults = N'',
--		@Results = @output OUTPUT;

--	-- we WILL get results via the above... so just attempt to drop the file again: 
--	SET @command = @removeCommand
--	EXEC dbo.[execute_command]
--		@Command = @command,
--		@ExecutionType = N'SQLCMD',
--		@ExecutionAttemptsCount = 1,
--		@DelayBetweenAttempts = 0,
--		@IgnoredResults = N'',
--		@Results = @output OUTPUT;

--	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName)
--		GOTO Done;

--	-- if we're still here: 

--	SET @command = N'DBCC FREESYSTEMCACHE (''ALL'');
--DBCC FREESESSIONCACHE();
--DBCC DROPCLEANBUFFERS();
--DBCC FREEPROCCACHE();'; 

--	EXEC dbo.[execute_command]
--		@Command = @command,
--		@ExecutionType = N'SQLCMD',
--		@ExecutionAttemptsCount = 1,
--		@DelayBetweenAttempts = 0,
--		@IgnoredResults = N'',
--		@Results = @output OUTPUT;

--	-- again, we WILL get output from the above... so just re-attempt to remove the file: 
--	SET @command = @removeCommand
--	EXEC dbo.[execute_command]
--		@Command = @command,
--		@ExecutionType = N'SQLCMD',
--		@ExecutionAttemptsCount = 1,
--		@DelayBetweenAttempts = 0,
--		@IgnoredResults = N'',
--		@Results = @output OUTPUT;

--	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[database_files] WHERE name = @FileName)
--		GOTO Done;

--	-- If we're still here: 
--	PRINT N'ERROR: '; 
--	PRINT CAST(@output AS nvarchar(MAX)); 

--	RETURN -100;

--Done: 
--	PRINT 'File Removed';
	
	
