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

USE [admindb];
GO


IF OBJECT_ID('dbo.load_default_path','FN') IS NOT NULL
	DROP FUNCTION dbo.load_default_path;
GO

CREATE FUNCTION dbo.load_default_path(@PathType sysname) 
RETURNS nvarchar(4000)
AS
BEGIN
 
	-- {copyright}

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
		'no_output';

	-- account for older versions and/or values not being set for data/log paths: 
	IF @output IS NULL BEGIN 
		IF @PathType = 'DATA' BEGIN 
			EXEC master..xp_instance_regread
				N'HKEY_LOCAL_MACHINE',  
				N'Software\Microsoft\MSSQLServer\MSSQLServer\Parameters',  
				N'SqlArg0',  -- try grabbing service startup parameters instead: 
				@output OUTPUT, 
				'no_output';			

			IF @output IS NOT NULL BEGIN 
				SET @output = SUBSTRING(@output, 3, 255)
				SET @output = SUBSTRING(@output, 1, LEN(@output) - CHARINDEX('\', REVERSE(@output)))
			  END;
			ELSE BEGIN
				SELECT @output = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(400)); -- likely won't provide any data if we didn't get it previoulsy... 
			END;
		END;

		IF @PathType = 'LOG' BEGIN 
			EXEC master..xp_instance_regread
				N'HKEY_LOCAL_MACHINE',  
				N'Software\Microsoft\MSSQLServer\MSSQLServer\Parameters',  
				N'SqlArg0',  -- try grabbing service startup parameters instead: 
				@output OUTPUT, 
				'no_output';			

			IF @output IS NOT NULL BEGIN 
				SET @output = SUBSTRING(@output, 3, 255)
				SET @output = SUBSTRING(@output, 1, LEN(@output) - CHARINDEX('\', REVERSE(@output)))
			  END;
			ELSE BEGIN
				SELECT @output = CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(400)); -- likely won't provide any data if we didn't get it previoulsy... 
			END;
		END;
	END;

	SET @output = dbo.[normalize_file_path](@output);

	RETURN @output;
END;
GO


