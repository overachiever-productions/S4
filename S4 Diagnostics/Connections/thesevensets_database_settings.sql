/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[thesevensets_database_settings]', N'P') IS NOT NULL
	DROP PROC dbo.[thesevensets_database_settings];
GO

CREATE PROC dbo.[thesevensets_database_settings]
	@databases						nvarchar(MAX)		= N'{ALL}',
	@verbose						bit					= 1,				-- Simplified view vs ... verbose view.
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @databases = ISNULL(NULLIF(@databases, N''), N'{ALL}');
	SET @verbose = ISNULL(@verbose, 1);

	DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
	IF @databases <> N'{ALL}' BEGIN 
		CREATE TABLE #ts_cp_databases ([row_id] int IDENTITY(1,1) NOT NULL, [database] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [database]));
	END;

	EXEC dbo.[core_predicates]
		@Databases = @databases,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	CREATE TABLE #targets (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database] sysname NOT NULL,
		[compatibility_level] tinyint NOT NULL,
		[quoted_identifier] bit NULL,
		[ansi_nulls] bit NULL,
		[ansi_padding] bit NULL,
		[ansi_warnings] bit NULL,
		[arithabort] bit NULL,
		[concat_null_yields_null] bit NULL,
		[numeric_roundabort] bit NULL, 
		[default_sum] int NULL, 
		[problem] nvarchar(MAX) NULL,
		[verbose] nvarchar(MAX) NULL,
		[mitigation] nvarchar(MAX) NULL
	);

	DECLARE @sql nvarchar(MAX) = N'WITH core AS ( 
	SELECT
		[name] [database],
		[database_id],
		[compatibility_level],
		[is_quoted_identifier_on], 
		[is_ansi_nulls_on],
		[is_ansi_padding_on],
		[is_ansi_warnings_on],
		[is_arithabort_on],
		[is_concat_null_yields_null_on],
		[is_numeric_roundabort_on]
	FROM
		[sys].[databases] [x]
)

SELECT
	[x].[database],
	[x].[compatibility_level],
	[x].[is_quoted_identifier_on],
	[x].[is_ansi_nulls_on],
	[x].[is_ansi_padding_on],
	[x].[is_ansi_warnings_on],
	[x].[is_arithabort_on],
	[x].[is_concat_null_yields_null_on],
	[x].[is_numeric_roundabort_on]
FROM 
	[core] [x]{joins}
WHERE 
	1 = 1{filters}
ORDER BY 
	[database_id]';

	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);

	INSERT INTO [#targets] (
		[database],
		[compatibility_level],
		[quoted_identifier],
		[ansi_nulls],
		[ansi_padding],
		[ansi_warnings],
		[arithabort],
		[concat_null_yields_null],
		[numeric_roundabort]
	)
	EXEC sys.sp_executesql 
		@sql;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for DEFAULT vs NON-DEFAULT settings. 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/	
	UPDATE [#targets] 
	SET 
		[default_sum] = (SELECT SUM([setting]) FROM 
			(VALUES 
				(CAST([quoted_identifier] AS tinyint)), 
				(CAST([ansi_nulls] AS tinyint)), 
				(CAST([ansi_padding] AS tinyint)),
				(CAST([ansi_warnings] AS tinyint)),
				(CAST([arithabort] AS tinyint)),
				(CAST([concat_null_yields_null] AS tinyint)),
				(CAST([numeric_roundabort] AS tinyint))
			) [x]([setting]));	
	
	UPDATE [#targets]
	SET 
		[verbose] = CASE WHEN [default_sum] = 0 THEN N'DEFAULT_SETTINGS' ELSE N'CUSTOM_SETTINGS' END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for Compound Logic of ARITHABORT. 
	--		a. IF ANSI_WARNINGS = ON, then ARITHABORT is (IMPLICITLY) ON, regardless of the ARITHABORT setting.
	--		b. COMPOUNDED BY: IF ANSI_DEFAULTS = ON, then ANSI_WARNINGS is (IMPLICITLY) ON, regardless of the ANSI_WARNINGS setting.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#targets]
	SET 
		[verbose] = [verbose] + N' ANSI_WARNINGS_ON = (IMPLICIT) ARITHABORT_ON.'
	WHERE 
		[arithabort] = 0
		AND [ansi_nulls] = 1;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for: ARITHABORT explictly OFF but ANSI_WARNINGS = ON and compat >= 90.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @minCompat tinyint = (SELECT MIN([compatibility_level]) FROM sys.databases);
	
	UPDATE [#targets]
	SET 
		[verbose] = [verbose] + N' COMPAT >= 90 + ANSI_WARNINGS_ON = (IMPLICIT) ARITHABORT_ON.'
	WHERE 
		[arithabort] = 0
		AND LEAST(@minCompat, [compatibility_level]) >= 90
		AND [ansi_warnings] = 1;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for [numeric_roundabort] OFF (as this could conflict with ... user_options).
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#targets] 
	SET 
		[problem] = N'NUMERIC_ROUNDABORT_OFF'
	WHERE 
		[verbose] NOT LIKE N'%DEFAULT_SETTING%'
		AND [numeric_roundabort] = 1;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Prep for Mitigations: 
	--		as on MOST systems, the default user_options (sys.settings) WILL yield CORRECT "the seven sets" settings. 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @userOptions xml;
	EXEC [admindb]..[thesevensets_server_useroptions]
		@serialized_output = @userOptions OUTPUT;

	IF (SELECT @userOptions.value(N'(/results/current_state)[1]', N'sysname')) = N'DEFAULT_OPTIONS' BEGIN
		UPDATE [#targets]
		SET 
			[mitigation] = 'SERVER''s [user_options] = (IMPLICIT) CORRECT_SETTINGS for DATABASE using DEFAULT_OPTIONS. '
		WHERE 
			[verbose] LIKE N'%DEFAULT_SETTING%'
	END;

	IF @verbose = 0 BEGIN 
		DELETE FROM [#targets]
		WHERE 
			[verbose] LIKE N'%DEFAULT_SETTING%' AND [mitigation] LIKE N'%(IMPLICIT) CORRECT%';
		
		IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

			SELECT @serialized_output = (
				SELECT 
					[database],
					[compatibility_level],
					(
						SELECT 
							[quoted_identifier],
							[ansi_nulls],
							[ansi_padding],
							[arithabort],
							[ansi_warnings],
							[concat_null_yields_null],
							[numeric_roundabort]
						FROM 
							[#targets] [t2]
						WHERE 
							[t2].[row_id] = [#targets].[row_id]
						FOR XML PATH(N'option'), TYPE
					) [settings],
					[problem],
					[mitigation]
				FROM 
					[#targets]
				ORDER BY 
					[row_id]
				FOR XML PATH(N'database'), ROOT(N'problem_databases'), TYPE
			);

			RETURN 0;
		END;

		SELECT 
			[database],
			[compatibility_level],
			(
				SELECT 
					[quoted_identifier],
					[ansi_nulls],
					[ansi_padding],
					[arithabort],
					[ansi_warnings],
					[concat_null_yields_null],
					[numeric_roundabort]
				FROM 
					[#targets] [t2]
				WHERE 
					[t2].[row_id] = [#targets].[row_id]
				FOR XML PATH(N'option'), TYPE
			) [settings],
			[problem],
			[mitigation]
		FROM 
			[#targets]
		ORDER BY 
			[row_id];

		RETURN 0;
	END;

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

		SELECT @serialized_output = (
			SELECT 
				[row_id],
				[database],
				[compatibility_level],
				(
					SELECT 
						[quoted_identifier],
						[ansi_nulls],
						[ansi_padding],
						[arithabort],
						[ansi_warnings],
						[concat_null_yields_null],
						[numeric_roundabort]
					FROM 
						[#targets] [t2]
					WHERE 
						[t2].[row_id] = [#targets].[row_id]
					FOR XML PATH(N'option'), TYPE
				) [settings],
				[problem],
				[verbose],
				[mitigation]
			FROM 
				[#targets]
			ORDER BY 
				[row_id]
			FOR XML PATH(N'problem'), ROOT(N'problem_database'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[row_id],
		[database],
		[compatibility_level],
		(
			SELECT 
				[quoted_identifier],
				[ansi_nulls],
				[ansi_padding],
				[arithabort],
				[ansi_warnings],
				[concat_null_yields_null],
				[numeric_roundabort]
			FROM 
				[#targets] [t2]
			WHERE 
				[t2].[row_id] = [#targets].[row_id]
			FOR XML PATH(N'option'), TYPE
		) [settings],
		[problem],
		[verbose],
		[mitigation]
	FROM 
		[#targets]
	ORDER BY 
		[row_id];

	RETURN 0; 
GO