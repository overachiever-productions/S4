
/*

	DEPENDENCIES:
		- None.

	NOTES:
		- This sproc was created to enble reuse and encapsulation of the logic that tackles determining whether 
			a specified path (to backup files/etc.) is valid or not - as a means of helping short-circuit any
			additional complexity in errors thrown when SQL Server is instructed to restore a backup that doesn't 
			exist (i.e., it's a lot easier to read an error that says: invalid path... than "the backup specified
			is not valid, or you don't have permissions, etc." (i.e., SQL Server 'catch all' error). 

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple


*/

USE master;
GO

IF OBJECT_ID('dbo.dba_CheckPaths','P') IS NOT NULL
	DROP PROC dbo.dba_CheckPaths;
GO

CREATE PROC dbo.dba_CheckPaths 
	@Path				nvarchar(MAX),
	@Exists				bit					OUTPUT
AS
	SET NOCOUNT ON;

	-- Version 3.3.0.16581		
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	SET @Exists = 0;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @commdand nvarchar(2000) = N'IF EXIST "' + @Path + N'" ECHO EXISTS';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @commdand;

	IF EXISTS (SELECT NULL FROM @results WHERE [output] = 'EXISTS')
		SET @Exists = 1;

	RETURN 0;
GO


