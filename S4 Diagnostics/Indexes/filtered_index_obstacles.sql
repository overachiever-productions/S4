/*

	ODD IDEA: 
		- another thing to do to potentially CHECK to see if Filtered Indexes are going to be a problem or not
			would be to check sys.indexes (per @databases) and ... look for any IXes with predicates/where clauses AND gobs of writes.


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[filtered_index_obstacles]','P') IS NOT NULL
	DROP PROC dbo.[filtered_index_obstacles];
GO

CREATE PROC dbo.[filtered_index_obstacles]
	@databases					nvarchar(MAX)			= N'{USER}', 
	@priorities					nvarchar(MAX)			= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @databases  = ISNULL(NULLIF(@databases, N''), N'{USER}');
	SET @priorities = NULLIF(@priorities, N'');

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Server Level Defaults. 
	--		These are a PAIN. 
	--		sys.configurations 'user options' is ... STUPID. 
	--			- It SHOULD default to a MASK of all of the enabled/disabled options. 
	--			- Instead, it defaults to 0. 
	--			ONLY if someone has modified one of the settings, explicitly, does it become anything OTHER than 0. 
	--			BUT, that's the rub. If I want to FORCE ARITHABORT to ON, I'd do something like: `EXEC sp_configure 'user options', 64); RECONFIGURE;` etc... 
	--			Except: 
	--				The docs do NOT cover whether the above operation just a) flipped ARITHABORT to ON or b) flipped ARITHABORT from the server-default (or c) disables the option (really doubt this)). 
	--					LOGICALLY?? option a) is the obvious? choice. 
	--					Except... guess what? 
	--						IF 'user options' is now 64 - wouldn't that, in turn, mean that 8, 15, 32, 128, 256, etc. (since they're NOT included in the bit-mask) are now OFF? 
	--			Seriously:
	--				Seems to me that you either spam in a bitmask of EVERYTHING you want enabled/disabled or ... changing a SINGLE option to (presumably) 'ON' ...disables all of the others. 
	--				Right? 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #userOptions (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[mask] bigint NOT NULL, 
		[option] sysname NOT NULL, 
		[warning] sysname NOT NULL 
	);

	DECLARE @BitMask int = (SELECT CAST([value_in_use] AS bigint) FROM sys.[configurations] WHERE [name] = N'user options');

	IF @BitMask <> 0 BEGIN

		WITH options AS (
			SELECT [option], [mask] FROM (VALUES 
				(8		, N'ANSI_WARNINGS'),
				(16		, N'ANSI_PADDING'),
				(32		, N'ANSI_NULLS'),
				(64		, N'ARITHABORT'),
				(256	, N'QUOTED_IDENTIFIER'),
				--(1024	, N'ANSI_NULL_DFLT_ON'),			-- handled down below... 
				(4096	, N'CONCAT_NULL_YIELDS_NULL') --,	
			) [opts]([mask], [option])
		), 
		matched AS ( 
			SELECT 
				[mask], 
				[option], 
				CASE WHEN @BitMask & [mask] > 0 THEN [option] ELSE N'' END [matched]
			FROM 
				[options]
		) 

		INSERT INTO [#userOptions] ([mask], [option], [warning])
		SELECT 
			[mask],
			[option],
			N'Default Connection Settings (via sp_configure ''user options'') does NOT have ' + [matched].[option] + N' set to ON.' [warning]
		FROM 
			[matched]
		WHERE 
			[matched].[matched] = N''

		IF @BitMask & 1024 > 0 BEGIN 
			DELETE FROM [#userOptions] WHERE [mask] = 32; -- ANSI_NULL_DFLT_ON ... obviously overrides ANSI_NULLs... 
		END;

		IF @BitMask & 8192 > 0 BEGIN  -- ENABLED - which it should NOT BE. 
			INSERT INTO [#userOptions] ([mask], [option], [warning]) VALUES(8192, N'NUMERIC_ROUNDABORT', N'Default Connection Settings (via sp_configure ''user options'') has NUMERIC_ARITHABORT set to ON.');
		END;

		IF @BitMask & 2048 > 0 BEGIN 
			INSERT INTO [#userOptions] ([mask], [option], [warning]) VALUES(8192, N'ANSI_NULL_DFLT_OFF', N'Default Connection Settings (via sp_configure ''user options'') has ANSI_NULL_DFLT_OFF set to ON.');
		END;
	END;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Default Database Settings that do NOT match settings REQUIRED for Filtered Indexes: 
			NOTE: 
				a) these are RARELY set 'correctly' or to anything other than 0 "across the board" for all of the settings in question. 
				b) and, insanely enough, this typically never 'matters' - because DEFAULTs via @@OPTIONS/sys.configurations 'user options' ... are typically set correctly. 

	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #dbSettings (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[name] [sysname] NOT NULL,
		[database_id] [int] NOT NULL,
		[compatibility_level] [tinyint] NOT NULL,
		[is_ansi_null_default_on] [bit] NULL,
		[is_ansi_nulls_on] [bit] NULL,
		[is_ansi_padding_on] [bit] NULL,
		[is_ansi_warnings_on] [bit] NULL,
		[is_arithabort_on] [bit] NULL,
		[is_concat_null_yields_null_on] [bit] NULL,
		[is_numeric_roundabort_on] [bit] NULL,
		[is_quoted_identifier_on] [bit] NULL
	); 

	INSERT INTO [#dbSettings] (
		[name],
		[database_id],
		[compatibility_level],
		[is_ansi_null_default_on],
		[is_ansi_nulls_on],
		[is_ansi_padding_on],
		[is_ansi_warnings_on],
		[is_arithabort_on],
		[is_concat_null_yields_null_on],
		[is_numeric_roundabort_on],
		[is_quoted_identifier_on]
	)
	SELECT 
		[name],
		[database_id],
		[compatibility_level],
		[is_ansi_null_default_on],
		[is_ansi_nulls_on],
		[is_ansi_padding_on],
		[is_ansi_warnings_on],
		[is_arithabort_on],
		[is_concat_null_yields_null_on],
		[is_numeric_roundabort_on],
		[is_quoted_identifier_on]
	FROM 
		sys.databases
	WHERE 
		CASE WHEN [is_ansi_nulls_on] = 0 AND [is_ansi_null_default_on] = 0 THEN 0 ELSE 1 END = 0
		OR CASE WHEN ([is_arithabort_on] = 1 OR ([compatibility_level] >= 90 AND [is_ansi_warnings_on] = 1)) THEN 1 ELSE 0 END = 0
		OR [is_ansi_nulls_on] = 0
		OR [is_ansi_padding_on] = 0
		OR [is_ansi_warnings_on] = 0
		OR [is_arithabort_on] = 0
		OR [is_concat_null_yields_null_on] = 0
		OR [is_numeric_roundabort_on] = 1
		OR [is_quoted_identifier_on] = 0;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Active Connections
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @minCompat tinyint = (SELECT MIN([compatibility_level]) FROM sys.databases);

	WITH core AS ( 

		SELECT 
			[s].[session_id],
			[s].[quoted_identifier], 
			[s].[arithabort], 
			[s].[ansi_null_dflt_on],  -- what mess. there's also ansi_null_dflt_off - and DRIVERS set different values for these settings (as is possible): https://learn.microsoft.com/en-us/sql/t-sql/statements/set-ansi-null-dflt-on-transact-sql?view=sql-server-ver17
			[s].[ansi_defaults], -- see notes below... 
			[s].[ansi_warnings], 
			[s].[ansi_padding],  
			[s].[ansi_nulls],  
			[s].[concat_null_yields_null], -- deprecated, should ALWAYS be set to ON. 
			CASE 
				WHEN [s].[arithabort] = 1 THEN N'ON (EXPLICIT)'
				WHEN ([s].[arithabort] = 0 AND [s].[ansi_warnings] = 1) THEN 
					CASE 
						WHEN @minCompat < 90 THEN N'ON (IMPLICIT) - CROSS DB WARNING' -- https://learn.microsoft.com/en-us/sql/t-sql/statements/set-arithabort-transact-sql?view=sql-server-ver16#remarks
						ELSE N'ON (IMPLICIT)'
					END
				WHEN [s].[arithabort] = 0 AND [s].[ansi_warnings] = 0 THEN N'OFF (ANSI_WARNINGS = 0)'
				ELSE '##ERROR##'
			END [arithabort_status],
			[s].[login_time],
			[s].[host_name],
			[s].[program_name],
			[s].[login_name],
			[s].[nt_domain],
			[s].[nt_user_name],
			[s].[status],
			[s].[context_info],
			[s].[cpu_time],
			[s].[memory_usage],
			[s].[total_elapsed_time],
			[s].[endpoint_id],
			[s].[last_request_end_time],
			[s].[reads],
			[s].[logical_reads],
			[s].[is_user_process],
			[s].[transaction_isolation_level],
			[s].[original_login_name],
			[d].[name] [current_database], 
			[ad].[name] [authenticating_database],
			[d].[compatibility_level] [current_database_compat_level]
		FROM 
			sys.[dm_exec_sessions] [s]
			LEFT OUTER JOIN sys.[databases] [d] ON [s].[database_id] = [d].[database_id]
			LEFT OUTER JOIN sys.[databases] [ad] ON [s].[authenticating_database_id] = [ad].[database_id]
		WHERE 
			([s].[quoted_identifier] = 0 AND [s].[is_user_process] = 1)
			OR ([s].[ansi_nulls] = 0 AND [s].[is_user_process] = 1)
			OR ([s].[arithabort] = 0 AND [s].[is_user_process] = 1)
			OR ([s].[ansi_padding] = 0 AND [s].[is_user_process] = 1)
			-- i've personally flipped this a FEW times in some of my code.  ah. but there's a crazy interplay between ANSI_WARNINGS and ... ARITHABORT. 
			--  see this on ANSI_WARNINGS: https://www.notion.so/overachiever/Connection-Options-98e84166fd504cf9b39fdd86e6c0a5fa?source=copy_link#df55c0a75c63434494ae3b5369ebd6a5
			OR ([s].[ansi_warnings] = 0 AND [s].[is_user_process] = 1) 
	
			-- ansi_defaults is the same as "turn on a whole family of ANSI_xxx" settings - to their (good/ANSI) defaults: 
			-- https://learn.microsoft.com/en-us/sql/t-sql/statements/set-ansi-defaults-transact-sql?view=sql-server-ver17
			-- I'm pretty sure I can drop/ignore this one - it only adds complexity and NOISE, with no real benefit. 
			--		ah, actually, i THINK I should do this: a) don't evaluate it for smells/etc. b) do 'publish' it as part of the output/projection.
			-- OR ([ansi_defaults] = 0 AND [is_user_process] = 1)  -- arguably... not a problem IF all of the other settings that we care about are 'defaulted' correctly.
			OR ([s].[concat_null_yields_null] = 0 AND [s].[is_user_process] = 1)
	) 

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[session_id],
		[arithabort_status],
		CASE 
			WHEN [is_user_process] = 1 AND [quoted_identifier] = 0 THEN N'QUOTED_IDENTIFIERS = OFF; ' -- might want to point out that THIS one is a BIGGIE.
			WHEN [is_user_process] = 1 AND [ansi_nulls] = 0 THEN N'ANSI_NULLS = OFF; '
			WHEN ([is_user_process] = 1 AND [arithabort_status] LIKE N'OFF%') THEN N'ARITHABORT = OFF; '
			WHEN [is_user_process] = 1 AND [ansi_padding] = 0 THEN N'ANSI_PADDING = OFF; '
			WHEN [is_user_process] = 1 AND [ansi_warnings] = 0 THEN N'ANSI_WARNINGS = OFF; '
			WHEN [is_user_process] = 1 AND [concat_null_yields_null] = 0 THEN N'CONCAT_NULL_YIELDS_NULL = OFF; '
			ELSE N''
		END [warning],

		CASE 
			WHEN ([is_user_process] = 1 AND [quoted_identifier] = 0) AND [program_name] LIKE N'SQLAgent%' THEN N'The SQL Server Agent does NOT connect with QUOTED_IDENTIFIER or ANSI_XXX set to ON.'

			-- HMM. according to the DOCS, SSMS defaults Arithabort to ON... but I do NOT see that in the wild (SSMS 21 - for example, defaults to OFF)
			--		https://learn.microsoft.com/en-us/sql/t-sql/statements/set-arithabort-transact-sql?view=sql-server-ver16
			-- ah. i THINK they claim this because SSMS sets ANSI_WARNINGs = ON ... which is fine/great - except/unless you've got a wretched DB somewhere using compat 80 or lower. i mean - mega-bletch. but, still. 
			WHEN ([is_user_process] = 1 AND [arithabort] = 0) AND [program_name] LIKE N'%Management Studio%' THEN 'SSMS defaults to arithabort = 0 (off), which is odd....'
			ELSE N''
		END [mitigation], 
		CASE 
			WHEN ([is_user_process] = 1 AND [quoted_identifier] = 0) THEN N'https://www.totalsql.tips/xx/some-key'
			ELSE N''
		END [recommendation],
		N' ' [ ],

		-- HMM... i might want to just dump all of these details into XML and call it [context]?
		[quoted_identifier],
		[arithabort],
		[ansi_null_dflt_on],
		[ansi_defaults],
		[ansi_warnings],
		[ansi_padding],
		[ansi_nulls],
		[concat_null_yields_null],
		N'' [ ], -- nbsp
		[login_time],
		[host_name],
		[program_name],
		[login_name],
		[nt_domain],
		[nt_user_name],
		[status],
		[context_info],
		[cpu_time],
		[memory_usage],
		[total_elapsed_time],
		[endpoint_id],
		[last_request_end_time],
		[reads],
		[logical_reads],
		[is_user_process],
		[transaction_isolation_level],
		[original_login_name],
		[current_database],
		[authenticating_database] 
		[current_database_compat_level],
		@minCompat [minimum_database_compat_level]
	INTO 
		#currentUserConnections
	FROM 
		core
	ORDER BY 
		[core].[session_id];

	/* Ignore/Remove rows that report `ON (IMPLICIT)` for arithabort_status ... and which have NO OTHER issues/warnings/problems.  */
	DELETE FROM [#currentUserConnections] WHERE [warning] = N'';

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Exclude Results from Databases not targeted by @databases
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @sqlAgentConnectionsFound bit = 0;
	IF EXISTS (SELECT NULL FROM [#currentUserConnections] WHERE [program_name] LIKE N'SQLAgent -%')
		SET @sqlAgentConnectionsFound = 1;

	IF UPPER(@databases) <> N'{USER}' BEGIN
		
		DECLARE @targetDatabases table (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[database_name] sysname NOT NULL 
		);

		DECLARE @xmlOutput xml;
		EXEC dbo.[targeted_databases]
			@Databases = @databases,
			@Priorities = @priorities,
			@ExcludeClones = 1,
			@ExcludeSecondaries = 1,
			@ExcludeSimpleRecovery = 0,
			@ExcludeReadOnly = 1,
			@ExcludeRestoring = 1,
			@ExcludeRecovering = 1,
			@ExcludeOffline = 1,
			@SerializedOutput = @xmlOutput OUTPUT;

		WITH shredded AS ( 
			SELECT 
				[data].[row].value('@id[1]', 'int') [row_id], 
				[data].[row].value('.[1]', 'sysname') [database_name]
			FROM 
				@xmlOutput.nodes('//database') [data]([row])
		)

		INSERT INTO @targetDatabases ([database_name])
		SELECT [database_name] FROM [shredded] ORDER BY [row_id];

		DELETE FROM [#dbSettings] WHERE [name] NOT IN (SELECT [database_name] FROM @targetDatabases);
		DELETE FROM [#currentUserConnections] WHERE [current_database] NOT IN (SELECT [database_name] FROM @targetDatabases);
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Tables & Columns:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #tables (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database] sysname NOT NULL,
		[table] nvarchar(257) NULL,
		[type_desc] nvarchar(60) NULL,
		[uses_ansi_nulls] bit NULL
	);

	CREATE TABLE #columns (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database] sysname NOT NULL,
		[parent] nvarchar(257) NULL,
		[column] sysname NULL,
		[column_id] int NOT NULL,
		[type] sysname NULL,
		[is_ansi_padded] bit NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}];
	INSERT INTO [#tables] ([database], [table], [type_desc], [uses_ansi_nulls])
	SELECT
		N''[{CURRENT_DB}]'' [database],
		SCHEMA_NAME([schema_id]) + N''.'' + [name] [table],
		[type_desc],
		[uses_ansi_nulls]
	FROM 
		sys.[tables]
	WHERE 
		[uses_ansi_nulls] = 0; ';
	
	DECLARE @errors xml;
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Priorities = @priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT;

	IF @errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected error. See [Errors] XML for more details.', 16, 1);
		SELECT @errors;
		RETURN -100;
	END;
	
	SET @sql = N'USE [{CURRENT_DB}];
	INSERT INTO [#columns] ([database], [parent], [column], [column_id], [type], [is_ansi_padded])
	SELECT 
		N''[{CURRENT_DB}]'' [database],
		SCHEMA_NAME([o].[schema_id]) + N''.'' + OBJECT_NAME([c].[object_id]) [parent], 
		[c].[name] [column], 
		[c].[column_id], 
		TYPE_NAME([c].[system_type_id]) [type], 
		[c].[is_ansi_padded]
	FROM 
		sys.columns [c]
		LEFT OUTER JOIN sys.[objects] [o] ON [c].[object_id] = [o].[object_id]
	WHERE 
		TYPE_NAME([c].[system_type_id]) LIKE N''%char%'' AND TYPE_NAME([c].[system_type_id]) NOT LIKE N''%MAX%)''
		AND [c].[is_ansi_padded] = 0
	ORDER BY 
		1; ';

	SET @errors = NULL; 
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Priorities = @priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT;
	
	IF @errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected error. See [Errors] XML for more details.', 16, 1);
		SELECT @errors;
		RETURN -100;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Modules:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #modules (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database] sysname NOT NULL,
		[module_name] nvarchar(257) NULL,
		[definition] nvarchar(max) NULL,
		[quoted_identifier] bit NULL,
		[ansi_nulls] bit NULL
	);
	
	SET @sql = N'USE [{CURRENT_DB}];
	INSERT INTO [#modules] ([database], [module_name], [definition], [quoted_identifier], [ansi_nulls])
	SELECT 
		N''[{CURRENT_DB}]'' [database],
		SCHEMA_NAME([o].[schema_id]) + N''.'' + OBJECT_NAME([m].[object_id]) [name], 
		[m].[definition], 
		[m].[uses_quoted_identifier] [quoted_identifier], 
		[m].[uses_ansi_nulls] [ansi_nulls]
	FROM 
		sys.[sql_modules] [m]
		LEFT OUTER JOIN sys.[objects] [o] ON [m].[object_id] = [o].[object_id]
	WHERE 
		[m].[uses_ansi_nulls] = 0 
		OR [m].[uses_quoted_identifier] = 0; ';

	SET @errors = NULL; 
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Priorities = @priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT;
	
	IF @errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected error. See [Errors] XML for more details.', 16, 1);
		SELECT @errors;
		RETURN -100;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Reporting
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #findings (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[key] sysname NOT NULL,
		[obstacle] sysname NOT NULL, 
		[reference] sysname NOT NULL 
	);

	IF EXISTS (SELECT NULL FROM [#userOptions]) BEGIN
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'DEFAULT_USER_OPTIONS',
			N'Default Settings for sp_configure ''user options'' have been modified. Default Value: [0]. Current value: [' + CAST(@BitMask AS sysname) +  N']',
			N'https://www.totalsql.com/xxx/short-code-here' 
		);
	END;

	IF EXISTS (SELECT NULL FROM [#dbSettings]) BEGIN
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'DB_SETTINGS',
			N'Default options for one or more databases do NOT match required settings for Filtered Indexes.', 
			N'https://www.totalsql.com/xxx/short-code-here2'
		);
	END;

	IF @sqlAgentConnectionsFound = 1 BEGIN
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'SQL_AGENT_CONNECTIONS', 
			N'The SQL Server Agent is Connected. It connects with QUOTED_IDENTIFIERS = OFF.', 
			N'https://www.totalsql.com/xxx/short-code-here7' -- need to make sure to mention, too, that ansi_warnings ON + COMPAT > 90 is required for equivalent of ARITHABORT = ON. 
		);		
	END;

	IF EXISTS (SELECT NULL FROM [#currentUserConnections]) BEGIN
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'CURRENT_USER_CONNECTIONS', 
			N'One or more user connections has SET OPTIONS that do NOT match required settings for Filtered Indexes.', 
			N'https://www.totalsql.com/xxx/short-code-here3'
		);
	END;

	IF EXISTS (SELECT NULL FROM [#tables]) BEGIN
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'TABLE_SETTINGS',
			N'One or more table definitions uses options that are incompatible with required settings for Filtered Indexes.', 
			N'https://www.totalsql.com/xxx/short-code-here4'
		);
	END;

	IF EXISTS (SELECT NULL FROM [#columns]) BEGIN
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'COLUMN_SETTINGS',
			N'One or more columns uses options that are incompatible with required settings for Filtered Indexes.', 
			N'https://www.totalsql.com/xxx/short-code-here5'
		);
	END;

	IF EXISTS (SELECT NULL FROM [#modules]) BEGIN
-- TODO: DELETE from modules that aren't triggers or sprocs. 
--			i.e., delete funcs (not even sure they can have their own, 'BAD', settings ... but no sense reporting on them. 
		INSERT INTO [#findings] ([key], [obstacle], [reference])
		VALUES (
			N'MODULE_SETTINGS',
			N'One or more Triggers or Stored Procedures uses options that are incompatible with required settings for Filtered Indexes..', 
			N'https://www.totalsql.com/xxx/short-code-here6'
		);
	END;

	SELECT
		[key],
		[obstacle],
		[reference]
	FROM
		[#findings]
	ORDER BY 
		[row_id];

	IF EXISTS (SELECT NULL FROM [#findings]) 
		SELECT N'REQUIRED_SETTINGS' [key], [x].[setting], [x].[required_value], [x].[notes] FROM (VALUES 
			(N'ANSI_NULLS', N'ON', N'ANSI_NULLS_DFLT_ON = 1 is Equivalent of ANSI_NULLS = 1'),
			(N'ANSI_PADDING', N'ON', N''),
			(N'ANSI_WARNINGS', N'ON', N''),
			(N'ARITHABORT', N'ON', N'In DBs with compat >= 90, ANSI_WARNINGS = 1 is equivalent to ARITHABORT = 1'),
			(N'CONCAT_NULL_YIELDS_NULL', N'ON', N''),
			(N'QUOTED_IDENTIFIER', N'ON', N''),
			(N'NUMERIC_ROUNDABORT', N'OFF', N'')
		) [x]([setting], [required_value], [notes]);


	IF EXISTS (SELECT NULL FROM [#userOptions])
		SELECT
			N'DEFAULT_USER_OPTIONS' [key],
			[mask],
			[option],
			[warning] 
		FROM
			[#userOptions]
		ORDER BY 
			[row_id];

	IF EXISTS (SELECT NULL FROM [#dbSettings])
-- TODO: order by @priorities... 
		SELECT
			N'DATABASE_SETTINGS' [key],
			[name],
			[database_id],
			[compatibility_level],
			[is_ansi_null_default_on],
			[is_ansi_nulls_on],
			[is_ansi_padding_on],
			[is_ansi_warnings_on],
			[is_arithabort_on],
			[is_concat_null_yields_null_on],
			[is_numeric_roundabort_on],
			[is_quoted_identifier_on]
		FROM
			[#dbSettings]
		ORDER BY
			[row_id];

	IF EXISTS (SELECT NULL FROM [#currentUserConnections]) 
		SELECT 
			N'CURRENT_USER_CONNECTIONS' [key],
			[session_id],
			[arithabort_status],
			[warning],
			[mitigation],
			[recommendation],
			[ ],
			[quoted_identifier],
			[arithabort],
			[ansi_null_dflt_on],
			[ansi_defaults],
			[ansi_warnings],
			[ansi_padding],
			[ansi_nulls],
			[concat_null_yields_null],
			[ ],
			[login_time],
			[host_name],
			[program_name],
			[login_name],
			[nt_domain],
			[nt_user_name],
			[status],
			[context_info],
			[cpu_time],
			[memory_usage],
			[total_elapsed_time],
			[endpoint_id],
			[last_request_end_time],
			[reads],
			[logical_reads],
			[is_user_process],
			[transaction_isolation_level],
			[original_login_name],
			[current_database],
			[current_database_compat_level],
			[minimum_database_compat_level]
		FROM 
			[#currentUserConnections] 
		ORDER BY 
			[row_id];

	IF EXISTS (SELECT NULL FROM [#tables])
		SELECT
			N'TABLE_SETTINGS' [key],
			[database],
			[table],
			[type_desc],
			[uses_ansi_nulls]
		FROM
			[#tables]
		ORDER BY
			[row_id];

	IF EXISTS (SELECT NULL FROM [#columns])
		SELECT
			N'COLUMN_SETTINGS' [key],
			[database],
			[parent],
			[column],
			[column_id],
			[type],
			[is_ansi_padded]
		FROM
			[#columns]
		ORDER BY
			[row_id];

	IF EXISTS (SELECT NULL FROM [#modules])
		SELECT
			N'MODULE_SETTINGS' [key],
			[database],
			[module_name],
			[definition],
			[quoted_identifier],
			[ansi_nulls]
		FROM
			[#modules]
		ORDER BY
			[row_id];

	RETURN 0;
GO