

/*

	Sproc exists primarily for 1 reason: 
		- to 'wrap' logic for grabbing a list of available backups... 
		- so that this logic can be RE-USED multiple times (as needed) when running restore operations (so that we can look for NEWLY added files and such if/when restore operations take a long time to execute).



	DECLARE @out nvarchar(max) = NULL;
	EXEC dbo.load_backup_files 
		@SourcePath = N'D:\SQLBackups\TESTS\Billing', 
		@Output = @out OUTPUT; 

	SELECT * FROM dbo.split_string(@out, N',');


*/


USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_files','P') IS NOT NULL
	DROP PROC dbo.load_backup_files;
GO

CREATE PROC dbo.load_backup_files 
	@SourcePath			nvarchar(400), 
	@Output				nvarchar(MAX)	OUTPUT
AS
	SET NOCOUNT ON; 

	DECLARE @results table ([id] int IDENTITY(1,1), [output] varchar(500));

	DECLARE @command varchar(2000);
	SET @command = 'dir "' + @SourcePath + '\" /B /A-D /OD';

	PRINT @command
	INSERT INTO @results ([output])
	EXEC xp_cmdshell @command;

	DELETE FROM @results WHERE [output] IS NULL;

	SET @Output = N'';
	SELECT @Output = @Output + [output] + N',' FROM @results ORDER BY [id];

	IF ISNULL(@Output,'') <> ''
		SET @Output = LEFT(@Output, LEN(@Output) - 1);

	RETURN 0;
GO