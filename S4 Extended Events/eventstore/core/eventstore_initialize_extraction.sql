/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_initialize_extraction]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_initialize_extraction];
GO

CREATE PROC dbo.[eventstore_initialize_extraction]
	@SessionName					sysname, 
	@ExtractionID					int					OUTPUT, 
	@CET							datetime2			OUTPUT, 
	@LSET							datetime2			OUTPUT, 
	@Attributes						nvarchar(300)		OUTPUT, 
	@InitializationDaysBack			int =				10
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SELECT @CET = DATEADD(MILLISECOND, -2, GETUTCDATE());

	-- grab LSET and attributes: 
	DECLARE @intializationLSET datetime2 = DATEADD(DAY, 0 - @InitializationDaysBack, GETUTCDATE());
	DECLARE @maxID int; 

	SELECT 
		@maxID = MAX(extraction_id)
	FROM 
		[dbo].[eventstore_extractions] 
	WHERE 
		[session_name] = @SessionName 
		AND [lset] IS NOT NULL;

	SELECT 
		@Attributes = [attributes]
	FROM 
		dbo.[eventstore_extractions] 
	WHERE 
		[extraction_id] = @maxID;

	SELECT @LSET = ISNULL(@LSET, @intializationLSET);

	-- start CET:
	INSERT INTO dbo.[eventstore_extractions] ([session_name], [cet]) 
	VALUES (@SessionName, @CET);

	SELECT @ExtractionID = SCOPE_IDENTITY();

	RETURN 0;
GO