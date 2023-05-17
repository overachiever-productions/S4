/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_logins','P') IS NOT NULL
	DROP PROC dbo.[script_logins];
GO

CREATE PROC dbo.[script_logins]
	@ExcludedLogins							nvarchar(MAX)			= NULL, 
	@ExcludeMSAndServiceLogins				bit						= 1,
	@ExcludeLocalPrincipalLogins			bit						= 1,
	@BehaviorIfLoginExists                  sysname                 = N'DROP_AND_CREATE',            -- { NONE | ALTER | DROP_AND_CREATE }
    @DisablePolicyChecks					bit						= 1,
	@DisableExpiryChecks					bit						= 1, 
	@ForceMasterAsDefaultDB					bit						= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');

	DECLARE @ingnoredLogins table (
		[login_name] sysname NOT NULL 
	);

	IF @ExcludedLogins IS NOT NULL BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](@ExcludedLogins, N',', 1) ORDER BY row_id;
	END;

	IF @ExcludeMSAndServiceLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [result] [login_name] FROM dbo.[split_string](N'##MS%, NT AUTHORITY\%, NT SERVICE\%', N',', 1) ORDER BY row_id;		
	END;

	IF @ExcludeLocalPrincipalLogins = 1 BEGIN
		INSERT INTO @ingnoredLogins ([login_name])
		SELECT [name] FROM sys.[server_principals] WHERE [type] = 'U' AND [name] LIKE @@SERVERNAME + N'\%';
	END;
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @output nvarchar(MAX);

	SELECT 
        CASE WHEN sp.[is_disabled] = 1 THEN 0 ELSE 1 END [enabled],
		sp.[name], 
		sp.[sid],
		sp.[type], 
		sp.[default_database_name],
		sl.[password_hash], 
		sl.[is_expiration_checked], 
		sl.[is_policy_checked], 
		sp.[default_language_name]
	INTO 
		#Logins
	FROM 
		sys.[server_principals] sp
		LEFT OUTER JOIN sys.[sql_logins] sl ON sp.[sid] = sl.[sid]
	WHERE 
		sp.[type] NOT IN ('R');

	IF EXISTS (SELECT NULL FROM @ingnoredLogins) BEGIN 
		DELETE l 
		FROM 
			[#Logins] l
			INNER JOIN @ingnoredLogins x ON l.[name] LIKE x.[login_name];
	END;

	SET @output = N'';

	SELECT 
		@output = @output + 
		CASE 
			WHEN [type] = N'S' THEN 
				dbo.[format_sql_login] (
					[enabled], 
					@BehaviorIfLoginExists, 
					[name], 
					N'0x' + CONVERT(nvarchar(MAX), [password_hash], 2) + N' ', 
					N'0x' + CONVERT(nvarchar(MAX), [sid], 2), 
					CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE [default_database_name] END, 
					[default_language_name], 
					CASE WHEN @DisableExpiryChecks = 1 THEN 0 ELSE [is_expiration_checked] END,
					CASE WHEN @DisablePolicyChecks = 1 THEN 0 ELSE [is_policy_checked] END
				)

			WHEN [type] IN (N'U', N'G') THEN 
				dbo.[format_windows_login] (
					[enabled], 
					@BehaviorIfLoginExists, 
					[name], 
					CASE WHEN @ForceMasterAsDefaultDB = 1 THEN N'master' ELSE [default_database_name] END, 
					[default_language_name]
				)
			ELSE 
				N'-- CERTIFICATE and SYMMETRIC KEY login types are NOT currently supported. (Nor are Roles)' 
		END 
			+ @crlf + N'GO' + @crlf
	FROM 
		[#Logins]
	ORDER BY 
		[name];


	IF NULLIF(@output, N'') IS NOT NULL BEGIN
		EXEC dbo.[print_long_string] @output;

		PRINT @crlf;
	END;

	RETURN 0;
GO