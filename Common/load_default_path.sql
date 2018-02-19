


/*



	NOTES:
		- It'd be great to select path info from sys.dm_server_registry
			https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-server-registry-transact-sql

			only... that doesn't cover any of the path info we want/need. (which is lame.) 
			So.... xp_instance_regread is the only real option.

	Examples
		SELECT dbo.load_default_path('BACKUP');
		SELECT dbo.load_default_path('DATA');
		SELECT dbo.load_default_path('LOG');

*/



USE admindb;
GO


IF OBJECT_ID('dbo.load_default_path','FN') IS NOT NULL
	DROP FUNCTION dbo.load_default_path;
GO

CREATE FUNCTION dbo.load_default_path(@PathType sysname) 
RETURNS nvarchar(4000)
AS
BEGIN 
	DECLARE @output sysname;

	IF UPPER(@PathType) = N'BACKUPS'
		SET @PathType = N'BACKUP';

	IF UPPER(@PathType) = N'LOGS'
		SET @PathType = N'LOG';

	DECLARE @valueName nvarchar(4000);

	SET @valueName = CASE @PathType
		WHEN N'BACKUP' THEN N'BackupDirectory'
		WHEN N'DATA' THEN N'DefaultData'
		WHEN N'LOG' THEN N'DefaultLog'
		ELSE N''
	END;

	IF @valueName = N''
		RETURN 'Error. Invalid @PathType Specified.';

	EXEC master..xp_instance_regread
		N'HKEY_LOCAL_MACHINE',  
		N'Software\Microsoft\MSSQLServer\MSSQLServer',  
		@valueName,
		@output OUTPUT, 
		'no_output'

	RETURN @output;
END;
GO


