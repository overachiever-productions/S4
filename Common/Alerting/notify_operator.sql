/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[notify_operator]','P') IS NOT NULL
	DROP PROC dbo.[notify_operator];
GO

CREATE PROC dbo.[notify_operator]
	@profile_name				sysname			= NULL,
	@operator_name				sysname,
	@subject					sysname, 
	@body						nvarchar(max), 
	@body_format				char(4)			= 'HTML',  -- { TEXT | HTML }
	@print_only					bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @profile_name = NULLIF(@profile_name, N'');

	IF @profile_name IS NULL BEGIN
		-- TODO:
		-- lookup against admindb..default_email_profile logic. 
		-- but, for now: 
		RAISERROR(N'Lookup of Default @profile_name functionality is not yet supported.', 16, 1);
		RETURN -1;
	END;

	DECLARE @recipients nvarchar(100);
	SELECT 
		@recipients = [email_address] 
	FROM 
		[msdb]..[sysoperators] -- TODO: synonym as msdb_sysoperators
	WHERE 
		[name] = @operator_name;

	IF @recipients IS NULL BEGIN
		RAISERROR('Operator ''%s'' not found.', 16, 1, @operator_name);
		RETURN -10;
	END;

	IF NULLIF(@recipients, N'') IS NULL BEGIN
		RAISERROR('No email address found for operator ''%s''.', 16, 1, @operator_name);
		RETURN -20;
	END;

	IF @print_only = 1 BEGIN
		PRINT N'Email would be sent to: ' + @recipients;
		PRINT N'Subject: ' + @subject;
		PRINT N'Body: ' + @body;

		RETURN 0;
	END
	
	EXEC msdb..sp_send_dbmail		-- TODO: alias/synonym as EXEC msdb_sp_send_dbmail... 
		@profile_name = @profile_name,
		@recipients = @recipients,
		@subject = @subject,
		@body = @body,
		@body_format = @body_format;

	RETURN 0;
GO