/*

	EXEC dbo.load_library_code @ResourceId = 3;


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[load_library_code]', N'P') IS NOT NULL
	DROP PROC  dbo.[load_library_code];
GO

CREATE PROC dbo.[load_library_code]
	@LibraryId					int 
AS
    SET NOCOUNT ON; 

	-- {copyright}

	IF NOT EXISTS (SELECT NULL FROM dbo.[code_library] WHERE [library_id] = @LibraryId) BEGIN
		RAISERROR(N'Requested ResourceID: [%d] not found.', 16, 1, @LibraryId);
		RETURN -1;
	END;

	SELECT 
		[code]
	FROM 
		dbo.[code_library] 
	WHERE 
		[library_id] = @LibraryId;

	RETURN 0;
GO