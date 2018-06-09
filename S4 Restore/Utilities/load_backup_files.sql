

/*

	Sproc exists primarily for 1 reason: 
		- to 'wrap' logic for grabbing a list of available backups... 
		- so that this logic can be RE-USED multiple times (as needed) when running restore operations (so that we can look for NEWLY added files and such if/when restore operations take a long time to execute).



		-- FULL:
		DECLARE @lastFile nvarchar(400) = NULL;
		DECLARE @output nvarchar(MAX);
		EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'FULL', @LastAppliedFile = NULL, @Output = @output OUTPUT;
		SELECT @output [FULL BACKUP FILE];

		SELECT @lastFile = @output;

		-- DIFF (if present):
		EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'DIFF', @LastAppliedFile = @lastFile, @Output = @output OUTPUT;
		SET @lastFile = ISNULL(NULLIF(@output,''), @lastFile);
		SELECT @lastFile [Last Applied (DIFF if present - otherwise FULL)]


		-- T-LOGs:
		EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'LOG', @LastAppliedFile = @lastFile, @Output = @output OUTPUT;
		SELECT * FROM dbo.[split_string](@output, N',');
		GO





*/


USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_files','P') IS NOT NULL
	DROP PROC dbo.load_backup_files;
GO

CREATE PROC dbo.load_backup_files 
	@DatabaseToRestore			sysname,
	@SourcePath					nvarchar(400), 
	@Mode						sysname,				-- FULL | DIFF | LOG  
	@LastAppliedFile			nvarchar(400)			= NULL,	
	@Output						nvarchar(MAX)			OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @results table ([id] int IDENTITY(1,1), [output] varchar(500));

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	--PRINT @command
	INSERT INTO @results ([output])
	EXEC xp_cmdshell @command;

	-- High-level Cleanup: 
	DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';

	-- Mode Processing: 
	IF UPPER(@Mode) = N'FULL' BEGIN
		-- most recent full only: 
		DELETE FROM @results WHERE id <> (SELECT MAX(id) FROM @results WHERE [output] LIKE 'FULL%');
	END;

	IF UPPER(@Mode) = N'DIFF' BEGIN 
		-- start by deleting since the most recent file processed: 
		DELETE FROM @results WHERE id <= (SELECT id FROM @results WHERE [output] = @LastAppliedFile);

		-- now dump everything but the most recent DIFF - if there is one: 
		IF EXISTS(SELECT NULL FROM @results WHERE [output] LIKE 'DIFF%')
			DELETE FROM @results WHERE id <> (SELECT id FROM @results WHERE [output] LIKE 'DIFF%'); 
		ELSE
			DELETE FROM @results;
	END;

	IF UPPER(@Mode) = N'LOG' BEGIN

		-- grab everything (i.e., ONLY t-log backups) since the most recently 
		DELETE FROM @results WHERE id <= (SELECT MAX(id) FROM @results WHERE [output] = @LastAppliedFile);
		DELETE FROM @results WHERE [output] NOT LIKE 'LOG%';
	END;


	SET @Output = N'';
	SELECT @Output = @Output + [output] + N',' FROM @results ORDER BY [id];

	IF ISNULL(@Output,'') <> ''
		SET @Output = LEFT(@Output, LEN(@Output) - 1);

	RETURN 0;
GO

