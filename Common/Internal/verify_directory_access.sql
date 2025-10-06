/*
		NOTE... this is PRETTY rough and tumble - and was built up as part of the path of ... getting dbo.deploy_library_code to work. 
			And... actually, it's not that "rough and tumble" other than that ... it MIGHT be a bit of a DRY violation in some ways... 
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[verify_directory_access]','P') IS NOT NULL
	DROP PROC dbo.[verify_directory_access];
GO

CREATE PROC dbo.[verify_directory_access]
	@TargetPath					nvarchar(MAX),
	@Accessible					bit					OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	-- verify that the directory exists BEFORE attempting to check on permissions:
	DECLARE @e bit; 
	EXEC dbo.[check_paths]
		@Path = @TargetPath,
		@Exists = @e OUTPUT;

	IF @e = 0 BEGIN 
		RAISERROR(N'Directory Not Found: [%s].', 16, 1, @TargetPath);
		RETURN -1;
	END;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @command nvarchar(2000) = 'dir "' + @TargetPath + '" /B /A-D /OD';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @command;

	IF EXISTS (SELECT NULL FROM @results WHERE LOWER([output]) LIKE '%access denied%' OR [output] LIKE 'file not found') 
		SET @Accessible = 0; 
	ELSE 
		SET @Accessible = 1;

	RETURN 0;
GO	