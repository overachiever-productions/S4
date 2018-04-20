
/*
	DEPENDENCIES:
		- Requires that xp_cmdshell be enabled.

	NOTE:
		This stored procedure exists as a work-around for the following bug within SQL Server:
			https://connect.microsoft.com/SQLServer/feedback/details/746979/try-catch-construct-catches-last-error-only


	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple

	EXECUTION SAMPLES:
			DECLARE @result varchar(2000);
			EXEC execute_uncatchable_command 'BACKUP DATABASE Testing2 TO DISK=''NUL''', 'BACKUP', @result = @result OUTPUT;
			SELECT @result;
			GO

			DECLARE @result varchar(2000);
			EXEC execute_uncatchable_command 'BACKUP DATABASE Testing77 TO DISK=''NUL''', 'BACKUP', @result = @result OUTPUT;
			SELECT @result;
			GO

			DECLARE @result varchar(2000);
			EXEC execute_uncatchable_command 'EXECUTE master.dbo.xp_create_subdir N''D:\SQLBackups\Testing1'';', 'CREATEDIR', @result = @result OUTPUT;
			SELECT @result;
			GO



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NOT NULL
	DROP PROC dbo.execute_uncatchable_command;
GO

CREATE PROC dbo.execute_uncatchable_command
	@statement				varchar(4000), 
	@filterType				varchar(20), 
	@result					varchar(4000)			OUTPUT	
AS
	SET NOCOUNT ON;

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	IF @filterType NOT IN ('BACKUP','RESTORE','CREATEDIR','ALTER','DROP','DELETEFILE') BEGIN;
		RAISERROR('Configuration Problem: Non-Supported @filterType value specified.', 16, 1);
		SET @result = 'Configuration Problem with dba_ExecuteAndFilterNonCatchableCommand.';
		RETURN -1;
	END 

	DECLARE @filters table (
		filter_text varchar(200) NOT NULL, 
		filter_type varchar(20) NOT NULL
	);

	INSERT INTO @filters (filter_text, filter_type)
	VALUES 
	-- BACKUP:
	('Processed % pages for database %', 'BACKUP'),
	('BACKUP DATABASE successfully processed % pages in %','BACKUP'),
	('BACKUP DATABASE WITH DIFFERENTIAL successfully processed % pages in %', 'BACKUP'),
	('BACKUP LOG successfully processed % pages in %', 'BACKUP'),
	('The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %', 'BACKUP'),  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 

	-- RESTORE:
	('RESTORE DATABASE successfully processed % pages in %', 'RESTORE'),
	('RESTORE LOG successfully processed % pages in %', 'RESTORE'),
	('Processed % pages for database %', 'RESTORE'),
		-- whenever there's a patch or upgrade...
	('Converting database % from version % to the current version %', 'RESTORE'), 
	('Database % running the upgrade step from version % to version %.', 'RESTORE'),

	-- CREATEDIR:
	('Command(s) completed successfully.', 'CREATEDIR'), 

	-- ALTER:
	('Command(s) completed successfully.', 'ALTER'),
	('Nonqualified transactions are being rolled back. Estimated rollback completion%', 'ALTER'), 

	-- DROP:
	('Command(s) completed successfully.', 'DROP'),

	-- DELETEFILE:
	('Command(s) completed successfully.','DELETEFILE')

	-- add other filters here as needed... 
	;

	DECLARE @delimiter nchar(4) = N' -> ';

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @command varchar(2000) = 'sqlcmd {0} -q "' + REPLACE(@statement, @crlf, ' ') + '"';

	-- Account for named instances:
	DECLARE @serverName sysname = '';
	IF @@SERVICENAME <> N'MSSQLSERVER'
		SET @serverName = N' -S .\' + @@SERVICENAME;
		
	SET @command = REPLACE(@command, '{0}', @serverName);

	--PRINT @command;

	INSERT INTO #Results (result)
	EXEC master.sys.xp_cmdshell @command;

	DELETE r
	FROM 
		#Results r 
		INNER JOIN @filters x ON x.filter_type = @filterType AND r.RESULT LIKE x.filter_text;

	IF EXISTS (SELECT NULL FROM #Results WHERE result IS NOT NULL) BEGIN;
		SET @result = '';
		SELECT @result = @result + result + @delimiter FROM #Results WHERE result IS NOT NULL ORDER BY result_id;
		SET @result = LEFT(@result, LEN(@result) - LEN(@delimiter));
	END

	RETURN 0;
GO
