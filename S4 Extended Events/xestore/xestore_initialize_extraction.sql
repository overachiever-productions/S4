/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.xestore_initialize_extraction','P') IS NOT NULL
	DROP PROC dbo.[xestore_initialize_extraction];
GO

CREATE PROC dbo.[xestore_initialize_extraction]
	@SessionName			sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @CET datetime2 = DATEADD(MILLISECOND, -2, GETUTCDATE());
	DECLARE @LSET datetime2; 
	DECLARE @attributes sysname;

	-- grab LSET and attributes: 
	DECLARE @intializationLSET datetime2 = DATEADD(DAY, -3, GETDATE());
	DECLARE @maxID int; 

	SELECT 
		@maxID = MAX(extraction_id)
	FROM 
		[dbo].[xestore_extractions] 
	WHERE 
		[session_name] = @SessionName 
		AND [lset] IS NOT NULL;

	SELECT 
		@LSET = ISNULL([lset], @intializationLSET), 
		@attributes = [attributes]
	FROM 
		dbo.xestore_extractions 
	WHERE 
		[extraction_id] = @maxID;

	-- start CET:
	DECLARE @extractionID int; 
	INSERT INTO dbo.xestore_extractions ([session_name], [cet]) 
	VALUES (@SessionName, @CET);

	SELECT @extractionID = SCOPE_IDENTITY();

	SELECT 
		@extractionID [execution_id], 
		@SessionName [session_name], 
		@CET [cet], 
		@LSET [lset], 
		@attributes [attributes];

	RETURN 0;
GO