/*

	This COULD also be implemented as a sproc - but the logic is light-weight enough. 

	EXAMPLES:

		DECLARE @command nvarchar(MAX) = N'. .C:\SomeDir\MyScript.ps1' + NCHAR(13) + NCHAR(10) + N'Do-MyFunc -Param1 ''foo'' -Param2 12';
		SELECT dbo.base64_encode(@command);

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[base64_encode]','FN') IS NOT NULL
	DROP FUNCTION dbo.[base64_encode];
GO

CREATE FUNCTION dbo.[base64_encode] (@Input nvarchar(MAX))
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	RETURN (
			SELECT CAST(@Input AS varbinary(MAX)) FOR XML PATH(N'node'), BINARY BASE64, TYPE
		).value(N'(node)[1]', N'nvarchar(MAX)');
    END;
GO
