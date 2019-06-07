/*

	NOTES:
		- This sproc was created to enble reuse and encapsulation of the logic that tackles determining whether 
			a specified path (to backup files/etc.) is valid or not - as a means of helping short-circuit any
			additional complexity in errors thrown when SQL Server is instructed to restore a backup that doesn't 
			exist (i.e., it's a lot easier to read an error that says: invalid path... than "the backup specified
			is not valid, or you don't have permissions, etc." (i.e., SQL Server 'catch all' error). 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.check_paths','P') IS NOT NULL
	DROP PROC dbo.check_paths;
GO

CREATE PROC dbo.check_paths 
	@Path				nvarchar(MAX),
	@Exists				bit					OUTPUT
AS
	SET NOCOUNT ON;

	-- {copyright}

	SET @Exists = 0;

	DECLARE @results TABLE (
		[output] varchar(500)
	);

	DECLARE @command nvarchar(2000) = N'IF EXIST "' + @Path + N'" ECHO EXISTS';

	INSERT INTO @results ([output])  
	EXEC sys.xp_cmdshell @command;

	IF EXISTS (SELECT NULL FROM @results WHERE [output] = 'EXISTS')
		SET @Exists = 1;

	RETURN 0;
GO