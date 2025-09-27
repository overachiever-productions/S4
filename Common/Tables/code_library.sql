/*




*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[code_library]', N'U') IS NULL BEGIN
	CREATE TABLE dbo.[code_library] (
		[script_id] int IDENTITY(1,1) NOT NULL, 
		[library_key] sysname NOT NULL, 
		[file_hash] varchar(64) NOT NULL, 
		[file_path] sysname NOT NULL, 
		[output_encoding] sysname NOT NULL, 
		[code] varbinary(MAX) NOT NULL, 
		CONSTRAINT PK_code_library PRIMARY KEY CLUSTERED ([script_id])
	);

	CREATE NONCLUSTERED INDEX IX_code_library_library_key ON dbo.[code_library] ([library_key]);
END;
GO

EXEC('TRUNCATE TABLE dbo.[code_library];');

DECLARE @fmtFile varchar(MAX) = N'{version}
1
1       SQLBINARY              0       0       ""   1     code           ""
';

INSERT INTO [dbo].[code_library] ([library_key], [file_hash], [file_path], [output_encoding], [code])
VALUES (N'BCP_FMT_FILE', '', N'C:\Perflogs\lib\code.fmt', N'UTF-8', CAST(@fmtFile AS varbinary(MAX)));

