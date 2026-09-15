/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[thesevensets_problem_connections]','P') IS NOT NULL
	DROP PROC dbo.[thesevensets_problem_connections];
GO

CREATE PROC dbo.[thesevensets_problem_connections]
	@databases						nvarchar(MAX)		= N'{ALL}', 
	@include_system					bit					= 0,
	@verbose						bit					= 1,				-- Simplified view vs ... verbose view.
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @databases = ISNULL(NULLIF(@databases, N''), N'{ALL}');
	SET @include_system = ISNULL(@include_system, 0);
	SET @verbose = ISNULL(@verbose, 1);

	IF @verbose = 1 BEGIN
		PRINT N'WARNING: SQL Server does NOT expose NUMERIC_ROUND_ABORT settings per connection/session/request.';
		PRINT N'  There are only 3x ways to spot potential problems and/or see NUMERIC_ROUND_ABORT settings: ';
		PRINT N'	A. Within YOUR session, use SESSIONPROPERTY(''NUMERIC_ROUNDABORT''), or evaluate @@OPTIONS.';
		PRINT N'	B. TRAP errors 8115 and 1934 (an ''Errors'' XE session OR modify sys.messages.is_event_logged).';
		PRINT N'	C. sys.dm_exec_plan_attributes'' [set_options] tracks 8192 (NUMERIC_ROUNDABORT) if/when on. ';
		PRINT N'	   also: sys.query_context_settings (via sys.query_store_query) has a [set_options] mask.'
	END; 

	SELECT 
		[s].[session_id],
		[s].[quoted_identifier], 
		[s].[ansi_nulls],
		[s].[ansi_padding],  
		[s].[arithabort], 
		[s].[ansi_warnings], 
		[s].[concat_null_yields_null],
		N'!' [numeric_round_abort],
		[s].[ansi_defaults], 
		[s].[login_time],
		[s].[host_name],
		[s].[program_name],
		[s].[login_name],
		[s].[nt_domain],
		[s].[nt_user_name],
		[s].[status],
		[s].[total_elapsed_time],
		[s].[endpoint_id],
		[s].[last_request_end_time],
		[s].[is_user_process],
		[s].[original_login_name],
		[d].[name] [current_database], 
		[ad].[name] [authenticating_database],
		[d].[compatibility_level] [current_database_compat_level], 
		CAST(N'' AS nvarchar(MAX)) [problem],
		CAST(N'' AS nvarchar(MAX)) [verbose],
		CAST(N'' AS nvarchar(MAX)) [mitigation]
	INTO 
		#targets
	FROM 
		sys.[dm_exec_sessions] [s]
		LEFT OUTER JOIN sys.[databases] [d] ON [s].[database_id] = [d].[database_id]
		LEFT OUTER JOIN sys.[databases] [ad] ON [s].[authenticating_database_id] = [ad].[database_id]
	WHERE 
		([s].[is_user_process] = 1 OR @include_system = 1)
		AND (
			[s].[quoted_identifier] = 0
			OR [s].[ansi_nulls] = 0
			OR [s].[ansi_padding] = 0
			OR [s].[arithabort] = 0
			OR [s].[ansi_warnings] = 0
			OR [s].[concat_null_yields_null] = 0
		);
		
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for Compound Logic of ARITHABORT. 
	--		a. IF ANSI_WARNINGS = ON, then ARITHABORT is (IMPLICITLY) ON, regardless of the ARITHABORT setting.
	--		b. COMPOUNDED BY: IF ANSI_DEFAULTS = ON, then ANSI_WARNINGS is (IMPLICITLY) ON, regardless of the ANSI_WARNINGS setting.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#targets]
	SET 
		[verbose] = N' ANSI_WARNINGS_ON = (IMPLICIT) ARITHABORT_ON.'
	WHERE
		[arithabort] = 0 
		AND [ansi_defaults] = 1;

	UPDATE [#targets]
	SET 
		[verbose] = [verbose] + N' ANSI_DEFAULTS_ON = (IMPLICIT) ANSI_WARNINGS_ON = (IMPLICIT) ARITHABORT_ON.'
	WHERE 
		[ansi_defaults] = 1;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for OTHER ANSI_DEFAULTS:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#targets]
	SET 
		[verbose] = [verbose] + 
			CASE WHEN [quoted_identifier] = 0 AND [ansi_defaults] = 1 THEN N' ANSI_DEFAULTS_ON = QUOTED_IDENTIFIERS_ON;' ELSE N'' END +
			CASE WHEN [ansi_nulls] = 0 AND [ansi_defaults] = 1 THEN N' ANSI_DEFAULTS_ON = ANSI_NULLS_ON;' ELSE N'' END +
			CASE WHEN [ansi_padding] = 0 AND [ansi_defaults] = 1 THEN N' ANSI_DEFAULTS_ON = ANSI_PADDING_ON;' ELSE N'' END +
			CASE WHEN [ansi_warnings] = 0 AND [ansi_defaults] = 1 THEN N' ANSI_DEFAULTS_ON = ANSI_WARNINGS_ON;' ELSE N'' END
	WHERE 
		([quoted_identifier] = 0 AND [ansi_defaults] = 1)
		OR ([ansi_nulls] = 0 AND [ansi_defaults] = 1)
		OR ([ansi_padding] = 0 AND [ansi_defaults] = 1)
		OR ([ansi_warnings] = 0 AND [ansi_defaults] = 1);

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for: ARITHABORT explictly OFF but ANSI_WARNINGS = ON and compat >= 90.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @minCompat tinyint = (SELECT MIN([compatibility_level]) FROM sys.databases);
	
	UPDATE [#targets]
	SET 
		[verbose] = [verbose] + N' COMPAT >= 90 + ANSI_WARNINGS_ON = (IMPLICIT) ARITHABORT_ON.'
	WHERE 
		[arithabort] = 0
		AND LEAST(@minCompat, [current_database_compat_level]) >= 90
		AND [ansi_warnings] = 1;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Account for LEGIT Problems (i.e., those where an IMPLICIT setting change hasn't 'fixed' issues):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#targets]
	SET 
		[problem] = N'ARITHABORT = OFF.', 
		[mitigation] = CASE WHEN [is_user_process] = 1 THEN N'' ELSE N'SYSTEM commonly uses ARITHABORT_OFF.' END
	WHERE 
		[arithabort] = 0 
		AND [verbose] = N'';

	UPDATE [#targets]
	SET 
		[problem] = 
			CASE WHEN [quoted_identifier] = 0 AND [ansi_defaults] = 0 THEN [problem] + N' QUOTED_IDENTIFIERS = OFF;' ELSE N'' END +
			CASE WHEN [ansi_nulls] = 0 AND [ansi_defaults] = 0 THEN [problem] + N' ANSI_NULLS = OFF;' ELSE N'' END +
			CASE WHEN [ansi_padding] = 0 AND [ansi_defaults] = 0 THEN [problem] + N' ANSI_PADDING = OFF;' ELSE N'' END +
			CASE WHEN [ansi_warnings] = 0 AND [ansi_defaults] = 0 THEN [problem] + N' ANSI_WARNINGS = OFF;' ELSE N'' END +
			CASE WHEN [concat_null_yields_null] = 0 THEN [problem] + N' CONCAT_NULL_YIELDS_NULL = OFF;' ELSE N'' END
	WHERE
		[quoted_identifier] = 0 
		OR [ansi_nulls] = 0
		OR [ansi_padding] = 0
		OR [ansi_warnings] = 0
		OR [concat_null_yields_null] = 0;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Mitigations:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	UPDATE [#targets]
	SET 
		[mitigation] = N'SQLAgent PROCESSES default to QUOTED_IDENTS_OFF.'
	WHERE 
		[program_name] LIKE N'SQLAgen%'
		AND [program_name] NOT LIKE N'%JobStep% (Job 0x%';

	UPDATE [#targets]
	SET 
		[mitigation] = N'SQLAgent JOBS default to QUOTED_IDENTS_OFF + ANSI_NULLS_OFF.'
	WHERE
		[program_name] LIKE N'SQLAgen%'
		AND [program_name] LIKE N'%JobStep% (Job 0x%';

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Cleanup / Logic Processing:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @verbose = 0 BEGIN
		DELETE FROM [#targets] 
		WHERE 
			[problem] = TRIM(N'')
			AND [verbose] <> TRIM(N'');
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Final Projections / XML Output:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	IF @verbose = 0 BEGIN 
		IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
			
			SET @serialized_output = (
				SELECT 
					[session_id],
					TRIM([problem]) [problem],
					TRIM([mitigation]) [mitigation],
					[status],
					[current_database],
					[program_name],
					[login_name],
					[host_name]
				FROM 
					[#targets]
				WHERE 
					TRIM([problem]) <> N''
				ORDER BY 
					[session_id]
				FOR XML PATH(N'connection'), ROOT(N'problem_connections'), TYPE
			);
			RETURN 0;
		END;

		SELECT 
			[session_id],
			TRIM([problem]) [problem],
			TRIM([mitigation]) [mitigation],
			[status],
			[current_database],
			[program_name],
			[login_name],
			[host_name]
		FROM 
			[#targets]
		WHERE 
			TRIM([problem]) <> N''
		ORDER BY 
			[session_id];

		RETURN 0;
	END;
	
	
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		
		SELECT @serialized_output = (
			SELECT 
				[session_id],
				TRIM([problem]) [problem],
				(
					SELECT 
						[quoted_identifier],
						[ansi_nulls],
						[ansi_padding],
						[arithabort],
						[ansi_warnings],
						[concat_null_yields_null],
						[numeric_round_abort],
						[ansi_defaults]
					FROM 
						[#targets] [s2]
					WHERE 
						[s2].[session_id] = [#targets].[session_id]
					FOR XML PATH(N'option'), TYPE
				) [settings],
				TRIM([mitigation]) [mitigation],
				(
					SELECT 
						[result] [*]
					FROM 
						dbo.[split_string](TRIM([verbose]), N'.', 1)
					ORDER BY 
						[row_id]
					FOR XML PATH(N'correction'), TYPE
				) [implicit_corrections],
				[status],
				[current_database],
				[program_name],
				[login_name],
				[host_name],
				[last_request_end_time]
			FROM 
				[#targets]
			WHERE 
				TRIM([problem]) <> N''
			ORDER BY 
				[session_id]	
			FOR XML PATH(N'connection'), ROOT(N'problem_connections'), TYPE
		);	
	
		RETURN 0;
	END;

	SELECT 
		[session_id],
		TRIM([problem]) [problem],
		(
			SELECT 
				[quoted_identifier],
				[ansi_nulls],
				[ansi_padding],
				[arithabort],
				[ansi_warnings],
				[concat_null_yields_null],
				[numeric_round_abort],
				[ansi_defaults]
			FROM 
				[#targets] [s2]
			WHERE 
				[s2].[session_id] = [#targets].[session_id]
			FOR XML PATH(N'option'), TYPE
		) [settings],
		TRIM([mitigation]) [mitigation],
		(
			SELECT 
				[result] [*]
			FROM 
				dbo.[split_string](TRIM([verbose]), N'.', 1)
			ORDER BY 
				[row_id]
			FOR XML PATH(N'correction'), TYPE
		) [implicit_correction],
		[status],
		[current_database],
		[program_name],
		[login_name],
		[host_name],
		[last_request_end_time]
	FROM 
		[#targets]
	WHERE 
		TRIM([problem]) <> N''
	ORDER BY 
		[session_id];

	RETURN 0;
GO