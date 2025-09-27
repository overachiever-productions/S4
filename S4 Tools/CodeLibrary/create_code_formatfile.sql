/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[create_code_formatfile]','P') IS NOT NULL
	DROP PROC dbo.[create_code_formatfile];
GO

CREATE PROC dbo.[create_code_formatfile]
	@BcpVersion			sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @binary varbinary(MAX) = (SELECT [code] FROM dbo.[code_library] WHERE [library_key] = N'BCP_FMT_FILE');

	DECLARE @fmtFile varchar(MAX) = CAST(@binary AS varchar(MAX));

	SET @fmtFile = REPLACE(@fmtFile, N'{version}', LTRIM(RTRIM(@BcpVersion)));

	PRINT @fmtFile;
	
	RETURN 0;
GO