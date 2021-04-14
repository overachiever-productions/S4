
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
			DECLARE @Result varchar(2000);
			EXEC execute_uncatchable_command 'BACKUP DATABASE Testing2 TO DISK=''NUL''', 'BACKUP', @Result = @Result OUTPUT;
			SELECT @Result;
			GO

			DECLARE @Result varchar(2000);
			EXEC execute_uncatchable_command 'BACKUP DATABASE Testing77 TO DISK=''NUL''', 'BACKUP', @Result = @Result OUTPUT;
			SELECT @Result;
			GO

			DECLARE @Result varchar(2000);
			EXEC execute_uncatchable_command 'EXECUTE master.dbo.xp_create_subdir N''D:\SQLBackups\Testing1'';', 'CREATEDIR', @Result = @Result OUTPUT;
			SELECT @Result;
			GO



	vNEXT:			(this is v6.0 'stuff')
		- dbo.execute_command
		- dbo.execute_remote_command
			
			signatures: 
				@Command						varchar(4000), 
				@ExecutionAttempts				int,				 = 1, 
				@ExclusionFilters				varchar(4000), 
				@ExecutionDetails				nvarchar(max),			-- keep a ... key value pair and/or a 'table' of some sort (hell, xml, ... whatever) of how things went - pass/fail - and if fail... the error, and so on... 
				@ResultText						varchar(4000)		
											
				

			


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.execute_uncatchable_command','P') IS NOT NULL
	DROP PROC dbo.execute_uncatchable_command;
GO

CREATE PROC dbo.execute_uncatchable_command
	@Statement				varchar(4000), 
	@FilterType				varchar(20), 
	@Result					varchar(4000)			OUTPUT	
AS
	SET NOCOUNT ON;

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Dependencies:
	EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs:

	IF @FilterType NOT IN (N'BACKUP',N'RESTORE',N'CREATEDIR',N'ALTER',N'DROP',N'DELETEFILE', N'UN-STANDBY') BEGIN;
		RAISERROR('Configuration Error: Invalid @FilterType specified.', 16, 1);
		SET @Result = 'Configuration Problem with dbo.execute_uncatchable_command.';
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
	('BACKUP DATABASE...FILE=<name> successfully processed % pages in % seconds %).', 'BACKUP'), -- for file/filegroup backups
	('The log was not truncated because records at the beginning %sp_repldone% to mark transactions as distributed %', 'BACKUP'),  -- NOTE: should only be enabled on systems where there's a JOB to force cleanup of replication in log... 

	-- RESTORE:
	('RESTORE DATABASE successfully processed % pages in %', 'RESTORE'),
	('RESTORE LOG successfully processed % pages in %', 'RESTORE'),
	('Processed % pages for database %', 'RESTORE'),
    ('DBCC execution completed. If DBCC printed error messages, contact your system administrator.', 'RESTORE'),  --  if CDC has been enabled (even if we're NOT running KEEP_CDC), recovery will throw in some sort of DBCC operation... 

		-- whenever there's a patch or upgrade...
	('Converting database % from version % to the current version %', 'RESTORE'), 
	('RESTORE DATABASE ... FILE=<name> successfully processed % pages in % seconds %).', N'RESTORE'),  -- partial recovery operations... 
	('Database % running the upgrade step from version % to version %.', 'RESTORE'),

	-- CREATEDIR:
	('Command(s) completed successfully.', 'CREATEDIR'), 

	-- ALTER:
	('Command(s) completed successfully.', 'ALTER'),
	('Nonqualified transactions are being rolled back. Estimated rollback completion%', 'ALTER'), 

	-- DROP:
	('Command(s) completed successfully.', 'DROP'),

	-- DELETEFILE:
	('Command(s) completed successfully.','DELETEFILE'),

	-- UN-STANDBY (i.e., pop a db out of STANDBY and into NORECOVERY... 
	('RESTORE DATABASE successfully processed % pages in % seconds%', 'UN-STANDBY'),
	('Command(s) completed successfully.', N'UN-STANDBY')

	-- add other filters here as needed... 
	;

	DECLARE @delimiter nchar(4) = N' -> ';

	CREATE TABLE #Results (
		result_id int IDENTITY(1,1),
		result nvarchar(MAX)
	);

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @command varchar(2000) = 'sqlcmd {0} -q "' + REPLACE(@Statement, @crlf, ' ') + '"';

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
		INNER JOIN @filters x ON x.filter_type = @FilterType AND r.result LIKE x.filter_text;

	IF EXISTS (SELECT NULL FROM #Results WHERE result IS NOT NULL) BEGIN;
		SET @Result = '';
		SELECT @Result = @Result + result + @delimiter FROM #Results WHERE result IS NOT NULL ORDER BY result_id;
		SET @Result = LEFT(@Result, LEN(@Result) - LEN(@delimiter));
	END

	RETURN 0;
GO
