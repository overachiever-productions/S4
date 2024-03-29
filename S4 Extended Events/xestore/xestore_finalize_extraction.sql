/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.xestore_finalize_extraction','P') IS NOT NULL
	DROP PROC dbo.[xestore_finalize_extraction];
GO

CREATE PROC dbo.[xestore_finalize_extraction]
	@SessionName			sysname,
	@ExtractionId			int, 
	@Attributes				nvarchar(300)		= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Attributes = NULLIF(@Attributes, N'');

	IF NOT EXISTS (SELECT NULL FROM dbo.[xestore_extractions] WHERE [extraction_id] = @ExtractionId AND [session_name] = @SessionName AND [lset] IS NULL) BEGIN 
		RAISERROR(N'Invalid @ExtractionId or @SessionName - no match for specified @SessionName + @ExtractionId exists - or LSET has already been assigned.', 16, 1);
		RETURN -10;
	END;
	
	UPDATE [dbo].[xestore_extractions] 
	SET 
		[lset] = [cet], 
		[attributes] = @Attributes 
	WHERE 
		[extraction_id] = @ExtractionId; 

	RETURN 0; 
GO