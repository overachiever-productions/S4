/*

*/
USE [admindb];
GO

IF OBJECT_ID(N'dbo.[database_settings]', N'TF') IS NOT NULL
	DROP FUNCTION dbo.[database_settings];
GO

CREATE FUNCTION dbo.[database_settings] (@database_id int)
RETURNS @defaults table (
	[default_name] sysname NOT NULL, 
	[default_value] sysname NOT NULL
)
AS BEGIN 

	-- {copyright}
	
	DECLARE @xml xml = (SELECT * FROM sys.databases WHERE [database_id] = @database_id FOR XML PATH(N'db'), TYPE);

	INSERT INTO @defaults ([default_name], [default_value])
	SELECT 
		[x].[r].value(N'local-name(.)', N'sysname') [default_name],
		x.[r].value(N'.', N'nvarchar(MAX)') [default_value]
	FROM 
		@xml.nodes(N'//db/*') AS [x]([r]);

	UPDATE @defaults SET [default_value] = CONVERT(sysname, (SELECT [owner_sid] FROM sys.databases WHERE [database_id] = @database_id), 1) WHERE [default_name] = N'owner_sid';

	DELETE FROM @defaults WHERE [default_name] NOT IN (SELECT [default_name] FROM dbo.[database_defaults](@database_id));

	RETURN;
END;
GO