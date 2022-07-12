/*
    
    INTERNAL:
        - Replacement for xp_create_subdir() (as that consistently created file-handle leaks - or, I'm ASSUMING it was the culprit). 
        - Checks to see if a directory exists
            if not, it'll attempt to chunk/build it as needed. 

    NOTE: 
        - It's SLIGHTLY counter-intuitive (or arguably could be) but this sproc returns 0 or non-0 based upon success. 
            0 = success (i.e., directory EITHER exists OR we created it without any issues)
            non-0 = error (check @Error for output/details). 

            IF/WHEN success = 0, @Error will be NULL - otherwise, if there was a problem, the inverse is true... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.establish_directory','P') IS NOT NULL
	DROP PROC dbo.establish_directory;
GO

CREATE PROC dbo.establish_directory
    @TargetDirectory                nvarchar(100), 
    @PrintOnly                      bit                     = 0,
    @Error                          nvarchar(MAX)           OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
    
	IF NULLIF(@TargetDirectory, N'') IS NULL BEGIN 
        SET @Error = N'The @TargetDirectory parameter for dbo.establish_directory may NOT be NULL or empty.';
        RETURN -1;
    END; 

    -- Normalize Path: 
    IF @TargetDirectory LIKE N'%\' OR @TargetDirectory LIKE N'%/'
        SET @TargetDirectory = LEFT(@TargetDirectory, LEN(@TargetDirectory) - 1);

    SET @Error = NULL;

    DECLARE @exists bit = 0; 
    IF @PrintOnly = 0 BEGIN 
        EXEC dbo.[check_paths] 
            @Path = @TargetDirectory, 
            @Exists = @exists OUTPUT;
    END;

    IF @exists = 1            
        RETURN 0; -- short-circuit. directory already exists.
    
    -- assume that we can/should be able to BUILD the path if it doesn't already exist: 
    DECLARE @command nvarchar(1000) = N'if not exist "' + @TargetDirectory + N'" mkdir "' + @TargetDirectory + N'"'; -- windows

    DECLARE @results xml;
	DECLARE @errorMessage nvarchar(MAX);
    EXEC dbo.[execute_command]
        @Command = @command, 
        @ExecutionType = N'SHELL',
        @ExecutionAttemptsCount = 1,
        @PrintOnly = @PrintOnly,
        @Outcome = @results OUTPUT, 
		@ErrorMessage = @errorMessage OUTPUT;

	IF @errorMessage IS NULL 
		RETURN 0; 
    
	SELECT @Error = @errorMessage;

    RETURN -1;
GO