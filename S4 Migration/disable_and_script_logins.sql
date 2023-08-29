/*

	SAMPLE/EXAMPLE:
			EXEC [admindb].dbo.[disable_and_script_logins]
				@ExcludedLogins	= N'%admin%, NT SERVICE%, NT AUTH%',
				@SummarizeExcludedLogins = 1,		
				@ScriptDirectives = 'ENABLE_AND_DISABLE',			
				@PrintOnly = 1;	

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.disable_and_script_logins','P') IS NOT NULL
	DROP PROC dbo.[disable_and_script_logins];
GO

CREATE PROC dbo.[disable_and_script_logins]
	@ExcludeSaLogin					bit				= 1, 
	@ExcludeAllSysAdminMembers		bit				= 0,
	@ExcludeMS##Logins				bit				= 1,
	@ExcludedLogins					nvarchar(MAX)	= NULL, 
	@SummarizeExcludedLogins		bit				= 1,
	@ScriptDirectives				sysname			= N'ENABLE_AND_DISABLE',	-- { ENABLE | ENABLE_AND_DISABLE }
	@PrintOnly						bit				= 0

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExcludedLogins = NULLIF(@ExcludedLogins, N'');
	SET @ScriptDirectives = UPPER(ISNULL(NULLIF(@ScriptDirectives, N''), N'ENABLE_AND_DISABLE'));

	DECLARE @exclusions table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[login_name] sysname NOT NULL 
	); 

	IF @ExcludeAllSysAdminMembers = 1 BEGIN 
		INSERT INTO @exclusions ([login_name])
		SELECT
			[sp].[name] [login_name]
		FROM
			[sys].[server_principals] [sp],
			[sys].[server_role_members] [rm],
			[sys].[server_principals] [r]
		WHERE
			[sp].[principal_id] = [rm].[member_principal_id] AND [r].[principal_id] = [rm].[role_principal_id] AND LOWER([r].[name]) IN (N'sysadmin')
		ORDER BY
			[r].[name],
			[sp].[name];
	  END;
	ELSE BEGIN 
		IF @ExcludeSaLogin = 1 BEGIN 
			INSERT INTO @exclusions ([login_name]) VALUES (N'sa');
		END;
	END;

	IF @ExcludeMS##Logins = 1 BEGIN 
		INSERT INTO @exclusions ([login_name]) VALUES (N'##MS_%');
	END;

	IF @ExcludedLogins IS NOT NULL BEGIN 
		INSERT INTO @exclusions (
			[login_name]
		)
		SELECT [result] FROM [admindb].[dbo].[split_string](@ExcludedLogins, N',', 1) ORDER BY [row_id];
	END;

	SELECT 
		[p].[name], 
		CASE WHEN [p].[is_disabled] = 1 THEN 0 ELSE 1 END [enabled],
		[p].[sid],
		CASE WHEN [x].[login_name] IS NULL THEN 0 ELSE 1 END [excluded]
	INTO 
		[#loginStates]
	FROM 
		sys.[server_principals] [p]
		LEFT OUTER JOIN @exclusions [x] ON [p].[name] LIKE [x].[login_name]
	WHERE 
		[p].[type] IN ('U', 'S') --,'G')  TODO: fix groups... 
	ORDER BY 
		[p].[name];

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @enabled nchar(3) = N'[+]';
	DECLARE @disabled nchar(3) = N'[_]';
	DECLARE @ignoredEnabled nchar(3) = N'[*]';
	DECLARE @ignoredDisabled nchar(3) = N'[.]';

	PRINT N'-----------------------------------------------------------------------------------------------------------------------------------------------------';
	PRINT N'-- PRE-CHANGE LOGIN STATES:  ' + @disabled + N' = disabled, ' + @enabled + N' = enabled ';
	PRINT N'-----------------------------------------------------------------------------------------------------------------------------------------------------';

	DECLARE @summary nvarchar(MAX) = N'';

	SELECT 
		@summary = @summary + CASE WHEN [enabled] = 1 THEN @enabled ELSE @disabled END + N' - ' + [name] + @crlf
	FROM 
		[#loginStates] 
	WHERE 
		[excluded] = 0 
	ORDER BY 
		[name];

	EXEC [dbo].[print_long_string] @summary;

	IF @SummarizeExcludedLogins = 1 BEGIN 
	
	PRINT @crlf;
			PRINT N'--------------------------------------------------------------------------------';
			PRINT N'-- IGNORED LOGIN STATES: ' + @ignoredDisabled + N' = disabled (ignored), ' + @ignoredEnabled + N' = enabled (ignored)';
			PRINT N'--------------------------------------------------------------------------------';
			SET @summary = N'';

			SELECT 
				@summary = @summary + CASE WHEN [enabled] = 1 THEN @ignoredEnabled ELSE @ignoredDisabled END + N' - ' + [name] + @crlf
			FROM 
				[#loginStates] 
			WHERE 
				[excluded] = 1 
			ORDER BY 
				[name];

			EXEC dbo.[print_long_string] @summary;
	END;

	PRINT @crlf;
	PRINT N'---------------------------------------------------------------------------------------------------------------------';
	PRINT N'-- RE-ENABLE' + CASE @ScriptDirectives WHEN N'ENABLE_AND_DISABLE' THEN ' + RE-DISABLE' ELSE N'' END + N' DIRECTIVES: ';
	PRINT N'---------------------------------------------------------------------------------------------------------------------';

	DECLARE @enablingTemplate nvarchar(MAX) = N'
-- Enabling Login [{login_name}]. State When Scripted: ENABLED. Generated: [{timestamp}]
ALTER LOGIN [{login_name}] ENABLE;
GO
';

	DECLARE @disablingTemplate nvarchar(MAX) = N'
-- Disabling Login [{login_name}]. State When Scripted: DISABLED. Generated: [{timestamp}]
ALTER LOGIN [{login_name}] DISABLE;
GO
';

	DECLARE @sql nvarchar(MAX) = N'';
	DECLARE @loginName sysname, @loginEnabled bit; 

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[name], 
		[enabled]
	FROM 
		[#loginStates] 
	WHERE 
		[excluded] = 0 
	ORDER BY 
		[name];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @loginName, @loginEnabled;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		IF @loginEnabled = 1 BEGIN 
			SET @sql = REPLACE(@enablingTemplate, N'{login_name}', @loginName);
			SET @sql = REPLACE(@sql, N'{timestamp}', CONVERT(sysname, GETDATE(), 120));

			PRINT @sql;

		  END; 
		ELSE BEGIN 
			IF @ScriptDirectives = N'ENABLE_AND_DISABLE' BEGIN
				SET @sql = REPLACE(@disablingTemplate, N'{login_name}', @loginName);
				SET @sql = REPLACE(@sql, N'{timestamp}', CONVERT(sysname, GETDATE(), 120));

				PRINT @sql;				
			END;
		END;		
	
		FETCH NEXT FROM [walker] INTO @loginName, @loginEnabled;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	PRINT @crlf;

	IF @PrintOnly = 1 BEGIN 
		PRINT N'---------------------------------------------------------------------------------------------------------------------';
		PRINT N'-- @PrintOnly = 1.  Printing DISABLE commands (vs executing)...';
		PRINT N'---------------------------------------------------------------------------------------------------------------------';		
	END;

	SET @disablingTemplate = N'ALTER LOGIN [{login_name}] DISABLE; ';

	DECLARE [disabler] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[name]
	FROM 
		[#loginStates] 
	WHERE 
		[excluded] = 0 
		AND [enabled] = 1 
	ORDER BY 
		[name];
	
	OPEN [disabler];
	FETCH NEXT FROM [disabler] INTO @loginName;

	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @sql = REPLACE(@disablingTemplate, N'{login_name}', @loginName);

		IF @PrintOnly = 1 BEGIN 
			PRINT N'-- DISABLE LOGIN: ' + @loginName + N'.'
			PRINT @sql;
			PRINT N'GO';
			PRINT N'';
		  END;
		ELSE BEGIN 
			EXEC sp_executesql 
				@sql;
		END;
	
		FETCH NEXT FROM [disabler] INTO @loginName;
	END;
	
	CLOSE [disabler];
	DEALLOCATE [disabler];
	
	RETURN 0; 
GO