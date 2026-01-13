/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[restore_encoded_certificate]','P') IS NOT NULL
	DROP PROC dbo.[restore_encoded_certificate];
GO

CREATE PROC dbo.[restore_encoded_certificate]
	@private_key_password					sysname,
	@certificate_name						sysname,
	@execute_backup_and_cleanup				bit				= 1, 
	@encoded_certificate					nvarchar(MAX), 
	@encoded_private_key					nvarchar(MAX)
AS
    SET NOCOUNT ON; 

	-- {copyright}

	


	DECLARE @encodedCert varbinary(MAX), @encodedKey varbinary(MAX);
	
	SELECT @encodedCert = CONVERT(varbinary(MAX), @encoded_certificate, 1);
	