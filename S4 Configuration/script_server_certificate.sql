/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[script_server_certificate]','P') IS NOT NULL
	DROP PROC dbo.[script_server_certificate];
GO

CREATE PROC dbo.[script_server_certificate]
	@certificate_name				sysname, 
	@private_key_password			sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @private_key_password = NULLIF(@private_key_password, N'');

	IF NOT EXISTS (SELECT NULL FROM [master].sys.[certificates] WHERE [name] = @certificate_name) BEGIN
		RAISERROR(N'Specified Server Name: [%s] not found in [master].[sys].[certificates].', 16, 1, @certificate_name);
		RETURN -10;
	END;

	IF @private_key_password IS NULL OR LEN(@private_key_password) <= 8 BEGIN 
		RAISERROR(N'Value for @private_key_password may NOT be NULL and must be at LEAST 8 characters long.', 16, 1);
		RETURN -12;
	END;

	DECLARE @cert varbinary(MAX), @key varbinary(MAX);
	DECLARE @certId int; 
	SELECT @certId = [certificate_id] FROM [master].[sys].[certificates] WHERE [name] = @certificate_name;

	DECLARE @sql nvarchar(MAX) = N'USE [master]; 
	SELECT 
		@cert = COMPRESS(CERTENCODED(@certId)), 
		@key = COMPRESS(CERTPRIVATEKEY(@certId, @private_key_password)); ';
	
	EXEC sys.[sp_executesql]
		@sql,  
		N'@certId int, @private_key_password sysname, @cert varbinary(MAX) OUTPUT, @key varbinary(MAX) OUTPUT', 
		@certId = @certId, 
		@private_key_password = @private_key_password,
		@cert = @cert OUTPUT, 
		@key = @key OUTPUT; 

	DECLARE @width int = 220; 

	DECLARE @template nvarchar(MAX) = N'EXEC [admindb].dbo.[restore_encoded_certificate]
	@private_key_password = N'''',			-- !!!!! MUST BE MANUALLY SPECIFIED (i.e., should be stored in Password Vault).
	@certificate_name = N''{cert_name}'',	-- NOTE: The Certificate NAME can be changed with NO problems.
	@execute_backup_and_cleanup = 1,		-- sdflksdjalkfj	
	@print_only = 0,
	@encoded_certificate = N''{public_key}'', 
	@encoded_private_key = N''{private_key}''; 
GO ';

	SET @template = REPLACE(@template, N'{cert_name}', @certificate_name);
	SET @template = REPLACE(@template, N'{public_key}', dbo.[format_hex_string](@cert, 240, N'NONE', 10, 19));
	SET @template = REPLACE(@template, N'{private_key}', dbo.[format_hex_string](@key, 240, N'NONE', 10, 19));

	EXEC dbo.[print_long_string] @template;

	RETURN 0;
GO		