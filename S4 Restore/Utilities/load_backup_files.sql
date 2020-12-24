/*

    NOTE: 
        - This sproc adheres to the PROJECT/REPLY usage convention.


	Sproc exists primarily for 1 reason: 
		- to 'wrap' logic for grabbing a list of available backups... 
		- so that this logic can be RE-USED multiple times (as needed) when running restore operations (so that we can look for NEWLY added files and such if/when restore operations take a long time to execute).

        -- Expect PROJECTion as output:
                EXEC dbo.load_backup_files 
                    @DatabaseToRestore = N'Billing', 
                    @SourcePath = N'D:\SQLBackups\Billing', 
                    @Mode = N'FULL', 
                    @LastAppliedFile = NULL;


        -- Example of REPLY outputs - for all file-types... 

		        -- FULL:
		        DECLARE @lastFile nvarchar(400) = NULL;
		        DECLARE @output nvarchar(MAX);
		        EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'FULL', @LastAppliedFile = NULL, @Output = @output OUTPUT;
		        SELECT @output [FULL BACKUP FILE];

		        SELECT @lastFile = @output;

		        -- DIFF (if present):
                SET @output = NULL;
		        EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'DIFF', @LastAppliedFile = @lastFile, @Output = @output OUTPUT;
		        SET @lastFile = ISNULL(NULLIF(@output,''), @lastFile);
		        SELECT @lastFile [Last Applied (DIFF if present - otherwise FULL)]


		        -- T-LOGs:
                SET @output = NULL;
		        EXEC dbo.load_backup_files @DatabaseToRestore = N'Billing', @SourcePath = N'D:\SQLBackups\Billing', @Mode = N'LOG', @LastAppliedFile = @lastFile, @Output = @output OUTPUT;
		        SELECT * FROM dbo.[split_string](@output, N',', 1);
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
	@Mode						sysname,				-- FULL | DIFF | LOG | LIST			-- where LIST = 'raw'/translated results.
	@LastAppliedFile			nvarchar(400)			= NULL,	
	@Output						xml						= N'<default/>'	    OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

    -----------------------------------------------------------------------------
    -- Dependencies Validation:
	EXEC dbo.verify_advanced_capabilities;

	IF @Mode NOT IN (N'FULL',N'DIFF',N'LOG',N'LIST') BEGIN;
		RAISERROR('Configuration Error: Invalid @Mode specified.', 16, 1);
		SET @Output = NULL;
		RETURN -1;
	END 

	DECLARE @results table ([id] int IDENTITY(1,1) NOT NULL, [output] varchar(500), [timestamp] datetime NULL);

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	--PRINT @command
	INSERT INTO @results ([output])
	EXEC xp_cmdshell 
		@stmt = @command;

	-- High-level Cleanup: 
	DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';

	-- if this is a SYSTEM database and we didn't get any results, test for @AppendServerNameToSystemDbs 
	IF ((SELECT dbo.[is_system_database](@DatabaseToRestore)) = 1) AND NOT EXISTS (SELECT NULL FROM @results) BEGIN

		SET @SourcePath = @SourcePath + N'\' + REPLACE(@@SERVERNAME, N'\', N'_');

		SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';
		INSERT INTO @results ([output])
		EXEC xp_cmdshell 
			@stmt = @command;

		DELETE FROM @results WHERE [output] IS NULL OR [output] NOT LIKE '%' + @DatabaseToRestore + '%';
	END;

	UPDATE @results
	SET 
		[timestamp] = dbo.[parse_backup_filename_timestamp]([output])
	WHERE 
		[output] IS NOT NULL;




	DECLARE @orderedResults table ( 
		[id] int IDENTITY(1,1) NOT NULL, 
		[output] varchar(500) NOT NULL, 
		[timestamp] datetime NOT NULL 
	);

	INSERT INTO @orderedResults (
		[output],
		[timestamp]
	)
	SELECT 
		[output], 
		[timestamp]
	FROM 
		@results 
	WHERE 
		[output] IS NOT NULL
	ORDER BY 
		[timestamp];

	-- Mode Processing: 
	IF UPPER(@Mode) = N'LIST' BEGIN 
		
		IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN -- if explicitly initialized to NULL/empty... 
			
			SELECT @Output = (SELECT
				[id] [file/@id],
				[output] [file/@file_name],
				[timestamp] [file/@timestamp]
			FROM 
				@orderedResults 
			ORDER BY 
				id 
			FOR XML PATH(''), ROOT('files'));

			RETURN 0;

		END;

		SELECT 
			[id],
			[output] [file_name],
			[timestamp] 
		FROM 
			@orderedResults 
		ORDER BY 
			[id];

        RETURN 0;
    END;

	IF UPPER(@Mode) = N'FULL' BEGIN
		-- most recent full only: 
		DELETE FROM @orderedResults WHERE id <> ISNULL((SELECT MAX(id) FROM @orderedResults WHERE [output] LIKE 'FULL%'), -1);
	END;

	IF UPPER(@Mode) = N'DIFF' BEGIN 
		-- start by deleting since the most recent file processed: 
		DELETE FROM @orderedResults WHERE id <= (SELECT id FROM @orderedResults WHERE [output] = @LastAppliedFile);

		-- now dump everything but the most recent DIFF - if there is one: 
		IF EXISTS(SELECT NULL FROM @orderedResults WHERE [output] LIKE 'DIFF%')
			DELETE FROM @orderedResults WHERE id <> (SELECT MAX(id) FROM @orderedResults WHERE [output] LIKE 'DIFF%'); 
		ELSE
			DELETE FROM @orderedResults;
	END;

	IF UPPER(@Mode) = N'LOG' BEGIN
		
		DELETE FROM @orderedResults WHERE id <= (SELECT MIN(id) FROM @orderedResults WHERE [output] = @LastAppliedFile);
		DELETE FROM @orderedResults WHERE [output] NOT LIKE 'LOG%';
	END;

    IF (SELECT dbo.is_xml_empty(@Output)) = 1 BEGIN -- if explicitly initialized to NULL/empty... 
        
		SELECT @Output = (SELECT
			[id] [file/@id],
			[output] [file/@file_name]
		FROM 
			@orderedResults 
		ORDER BY 
			id 
		FOR XML PATH(''), ROOT('files'));

        RETURN 0;
    END;

    -- otherwise, project:
    SELECT 
        [output]
    FROM 
        @orderedResults
    ORDER BY 
        [id];

	RETURN 0;
GO