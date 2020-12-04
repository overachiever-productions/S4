/*

	vNEXT: 
		- account for system-level/database-level and ... uh, <phantom-blockers> 
			i.e., where: 
				blocking_xactid
				blocking_request
				blocking_resource are all NULL (i.e., NOTHING is blocking)

				and, unlike self-blockers - where ... there IS something being blocked (the self-blocker). 
				in this new/additional scenario, the following are ALSO, uh, blank: 
					- blocked_xactid
					- blocked_request 
					OR
					- blocked_resource 
						
					i.e., we USUALLY get at least ONE of the request/resource values - (but seems like we never get both? ) 


	FODDER: 
		- Notes/Info about EMPTY processes: 
			https://dba.stackexchange.com/questions/168646/empty-blocking-process-in-blocked-process-report

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_blockedprocess_chronology','P') IS NOT NULL
	DROP PROC dbo.[view_blockedprocess_chronology];
GO

CREATE PROC dbo.[view_blockedprocess_chronology]
	@TranslatedBlockedProcessesTable					sysname, 
	@OptionalStartTime									datetime	= NULL, 
	@OptionalEndTime									datetime	= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TranslatedBlockedProcessesTable = NULLIF(@TranslatedBlockedProcessesTable, N'');

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @TranslatedBlockedProcessesTable, 
		@ParameterNameForTarget = N'@TranslatedBlockedProcessesTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 
	
	CREATE TABLE #work (
		[row_id] int NOT NULL,
		[timestamp] datetime NULL,
		[database_name] sysname NULL,
		[seconds_blocked] decimal(6,2) NULL,
		[report_id] int NULL,
		[blocking_spid] int NULL,
		[blocking_ecid] int NULL,
		[blocking_id] nvarchar(max) NULL,
		[blocked_id] nvarchar(max) NULL,
		[blocking_xactid] bigint NULL,
		[blocking_request] nvarchar(max) NULL,
		[blocking_sproc_statement] nvarchar(max) NULL,
		[blocking_weight] sysname NULL,
		[blocking_resource_id] nvarchar(80) NULL,
		[blocking_resource] varchar(400) NULL,
		[blocking_wait_time] int NULL,
		[blocking_tran_count] int NULL,
		[blocking_isolation_level] sysname NULL,
		[blocking_status] sysname NULL,
		[blocking_start_offset] int NOT NULL,
		[blocking_end_offset] int NOT NULL,
		[blocking_host_name] sysname NULL,
		[blocking_login_name] sysname NULL,
		[blocking_client_app] sysname NULL,
		[blocked_spid] int NULL,
		[blocked_ecid] int NULL,
		[blocked_xactid] bigint NULL,
		[blocked_request] nvarchar(max) NULL,
		[blocked_sproc_statement] nvarchar(max) NULL,
		[blocked_weight] sysname NULL,
		[blocked_resource_id] nvarchar(80) NULL,
		[blocked_resource] varchar(400) NULL,
		[blocked_wait_time] int NULL,
		[blocked_tran_count] int NULL,
		[blocked_log_used] int NULL,
		[blocked_lock_mode] sysname NULL,
		[blocked_isolation_level] sysname NULL,
		[blocked_status] sysname NULL,
		[blocked_start_offset] int NOT NULL,
		[blocked_end_offset] int NOT NULL,
		[blocked_host_name] sysname NULL,
		[blocked_login_name] sysname NULL,
		[blocked_client_app] sysname NULL,
		[report] xml NULL
	);

	CREATE CLUSTERED INDEX [____CLIX_#work_byReportId] ON [#work] (report_id);

	DECLARE @sql nvarchar(MAX) = N'SELECT 
		*
	FROM {SourceTable}{WHERE}
	ORDER BY 
		[row_id]; ';

	DECLARE @dateTimePredicate nvarchar(MAX) = N'';
	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @dateTimePredicate = N'WHERE [timestamp] >= ''' + CONVERT(sysname, @OptionalStartTime, 121) + N'''';
	END; 

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF NULLIF(@dateTimePredicate, N'') IS NOT NULL BEGIN 
			SET @dateTimePredicate = @dateTimePredicate + N' AND [timestamp] <= ''' + CONVERT(sysname, @OptionalEndTime, 121) + N'''';
		  END; 
		ELSE BEGIN 
			SET @dateTimePredicate = N'WHERE [timestamp] <= ''' + CONVERT(sysname, @OptionalEndTime, 121) + N'''';
		END;
	END;

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{WHERE}', @dateTimePredicate);

	INSERT INTO [#work] (
		[row_id],
		[timestamp],
		[database_name],
		[seconds_blocked],
		[report_id],
		[blocking_spid],
		[blocking_ecid],
		[blocking_id],
		[blocked_id],
		[blocking_xactid],
		[blocking_request],
		[blocking_sproc_statement],
		[blocking_weight],
		[blocking_resource_id],
		[blocking_resource],
		[blocking_wait_time],
		[blocking_tran_count],
		[blocking_isolation_level],
		[blocking_status],
		[blocking_start_offset],
		[blocking_end_offset],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_spid],
		[blocked_ecid],
		[blocked_xactid],
		[blocked_request],
		[blocked_sproc_statement],
		[blocked_weight],
		[blocked_resource_id],
		[blocked_resource],
		[blocked_wait_time],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_lock_mode],
		[blocked_isolation_level],
		[blocked_status],
		[blocked_start_offset],
		[blocked_end_offset],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report]
	)
	EXEC sys.sp_executesql 
		@sql; 

	-- Projection/Output:
	WITH leads AS (		
	
		SELECT report_id, blocking_id
		FROM [#work] 

		EXCEPT 

		SELECT report_id, blocked_id
		FROM [#work] 

	), 
	chain AS ( 
	
		SELECT 
			report_id, 
			0 AS [level],
			blocking_id, 
			blocking_id [blocking_chain]
		FROM 
			leads 

		UNION ALL 

		SELECT 
			base.report_id, 
			c.[level] + 1 [level],
			base.blocked_id, 
			c.[blocking_chain] + N' -> ' + base.blocked_id
		FROM 
			[#work] base 
			INNER JOIN chain c ON base.report_id = c.report_id AND base.blocking_id = c.blocking_id 

	)
	SELECT 
		[report_id],
		[level],
		[blocking_id],
		[blocking_chain]
	INTO 
		#chain
	FROM 
		chain
	WHERE 
		[level] <> 0;


	--SELECT * FROM #chain; 
	--RETURN 0;

	SELECT 
		report_id, 
		MIN([timestamp]) [timestamp], 
		COUNT(*) [process_count]
	INTO 
		#aggregated
	FROM 
		[#work]
	GROUP BY 
		[report_id];


	WITH normalized AS ( 

		SELECT 
			ISNULL([c].[level], -1) [level],
			[w].[blocking_id],
			[w].[blocked_id],
			LAG([w].[report_id], 1, 0) OVER (ORDER BY [w].[report_id], ISNULL([c].[level], -1)) [previous_report_id],

			--[w].[report_id],
			[w].[report_id] [original_report_id],
			[w].[database_name],
			[w].[timestamp],
			[a].[process_count],

			ISNULL([c].[blocking_chain], N'    ' + CAST([w].[blocked_id] AS sysname) + N' -> (' + CAST([w].[blocked_id] AS sysname) + N')') [blocking_chain],
			
			dbo.[format_timespan]([w].[blocked_wait_time]) [time_blocked],
			
			CASE WHEN [w].[blocking_id] IS NULL THEN N'<blocking-self>' ELSE [w].[blocking_status] END [blocking_status],
			[w].[blocking_isolation_level],
			CASE WHEN [w].[blocking_id] IS NULL THEN N'(' + CAST([w].[blocked_xactid] AS sysname) + N')' ELSE CAST([w].[blocking_xactid] AS sysname) END [blocking_xactid],
			[w].[blocking_tran_count],
			CASE WHEN [w].blocking_request LIKE N'%Object Id = [0-9]%' THEN [w].[blocking_request] + N' --> ' + ISNULL([w].[blocking_sproc_statement], N'#sproc_statement_extraction_error#') ELSE ISNULL([w].[blocking_request], N'') END [blocking_request],
			[w].[blocking_resource],

			-- blocked... 
			[w].[blocked_status], -- always suspended or background - but background can be important to know... 
			[w].[blocked_isolation_level],
			[w].[blocked_xactid],
			[w].[blocked_tran_count],
			[w].[blocked_log_used],
			
			CASE WHEN [w].[blocked_request] LIKE N'%Object Id = [0-9]%' THEN [w].[blocked_request] + N' --> ' + ISNULL([w].[blocked_sproc_statement], N'#sproc_statement_extraction_error#') ELSE ISNULL([w].[blocked_request], N'') END [blocked_request],
			[w].[blocked_resource],
		
			[w].[blocking_weight],
			[w].[blocked_weight],

			[w].[blocking_host_name],
			[w].[blocking_login_name],
			[w].[blocking_client_app],
		
			[w].[blocked_host_name],
			[w].[blocked_login_name],
			[w].[blocked_client_app],

			----------
		
			--[w].[blocking_sproc_statement],
			--[w].[blocking_resource_id],
		
			--[w].[blocking_wait_time],
			--[w].[blocking_start_offset],
			--[w].[blocking_end_offset],
			--[w].[blocking_host_name],
			--[w].[blocking_login_name],
			--[w].[blocking_client_app],

			--[w].[blocked_spid],
			--[w].[blocked_ecid],
		
			--[w].[blocked_sproc_statement],
		
			--[w].[blocked_resource_id],
			--[w].[blocked_wait_time],
			--[w].[blocked_lock_mode],
			--[w].[blocked_start_offset],
			--[w].[blocked_end_offset],

			[w].[report]
		FROM 
			[#work] w
			LEFT OUTER JOIN [#aggregated] a ON [w].[report_id] = [a].[report_id]
			LEFT OUTER JOIN [#chain] c ON [w].[report_id] = [c].[report_id] AND w.blocked_id = c.[blocking_id]
	)

	SELECT 
		--[level],
		--[blocking_id],
		--[blocked_id],
		--[previous_report_id],
		
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE CAST([original_report_id] AS sysname) END [report_id],
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE [database_name] END [database_name],
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE CONVERT(sysname, [timestamp], 121) END [timestamp],
		CASE WHEN [original_report_id] = [previous_report_id] THEN N'' ELSE CAST([process_count] AS sysname) END [process_count],
		[blocking_chain],
		[time_blocked],
		[blocking_status],
		[blocking_isolation_level],
		[blocking_xactid],
		[blocking_tran_count],
		[blocking_request],
		[blocking_resource],
		[blocked_status],
		[blocked_isolation_level],
		[blocked_xactid],
		[blocked_tran_count],
		[blocked_log_used],
		[blocked_request],
		[blocked_resource],
		[blocking_weight],
		[blocked_weight],
		[blocking_host_name],
		[blocking_login_name],
		[blocking_client_app],
		[blocked_host_name],
		[blocked_login_name],
		[blocked_client_app],
		[report] 
	FROM 
		[normalized] 
	ORDER BY 
		[original_report_id], [level];


	--SELECT 
					--	CASE WHEN s.[timestamp] IS NULL THEN CAST(c.report_id AS sysname) ELSE N'' END [report_id],
					--	CASE WHEN s.[report] IS NULL THEN CONVERT(sysname,  a.[timestamp], 120) ELSE N'' END [timestamp],
					--	CASE WHEN s.[report] IS NULL THEN CAST(a.[process_count] AS sysname) ELSE N'' END [process_count],
		


	--	s.blocking_tran_count, 
	--	ISNULL(CAST(s.blocking_xactid AS sysname), '') blocking_xactid,  -- VERY helpful in determining which 'blocker' is the same from one blocked-process-report to the next... 
	--	ISNULL(s.blocking_isolation_level, '') blocking_isolation_level,
	--	CASE WHEN c.blocking_chain IS NULL THEN N'<blocking-self>' ELSE ISNULL(s.blocking_status, N'') END [blocking_status],	
				--	CASE WHEN s.blocking_request LIKE N'%Object Id = [0-9]%' THEN s.blocking_request + N' --> ' + ISNULL(s.blocking_sproc_statement, N'#sproc_statement_extraction_error#') ELSE ISNULL(s.blocking_request, '') END [blocking_request],
	--	ISNULL(s.blocking_resource, '') blocking_resource, 

	--	CASE WHEN c.blocking_chain IS NULL 
	--		THEN CASE WHEN detail.blocked_request LIKE N'xx' THEN detail.blocked_request + N' --> ' + detail.blocked_sproc_statement ELSE ISNULL(detail.blocked_request, '') END
	--		ELSE CASE WHEN s.blocked_request LIKE N'xx' THEN s.blocked_request + N' --> ' + s.blocked_sproc_statement ELSE ISNULL(s.blocked_request, '') END 
	--	END [blocked_request],
		
	--	CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.blocked_resource, N'') ELSE ISNULL(s.blocked_resource, N'') END [blocked_resource],
	--	CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.blocked_status, N'') ELSE ISNULL(s.blocked_status, '') END [blocked_status],
		
	--	CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.blocked_isolation_level, N'') ELSE ISNULL(s.blocked_isolation_level, N'') END blocked_isolation_level,
	--	CASE WHEN c.blocking_chain IS NULL THEN detail.blocked_tran_count ELSE s.blocked_tran_count END [blocked_tran_count],
	--	CASE WHEN c.blocking_chain IS NULL THEN detail.blocked_log_used ELSE s.blocked_log_used END [blocked_log_used],
		
	--	s.[blocking_weight],
	--	s.[blocking_host_name], 
	--	s.[blocking_client_app] [blocking_app_name],
	--	CASE WHEN c.blocking_chain IS NULL THEN detail.[blocked_weight] ELSE s.[blocked_weight] END [blocked_weight],
	--	CASE WHEN c.blocking_chain IS NULL THEN detail.[blocked_host_name] ELSE s.[blocked_host_name] END [blocked_host_name], 
	--	CASE WHEN c.blocking_chain IS NULL THEN detail.[blocked_client_app] ELSE s.[blocked_client_app] END [blocked_app_name],
		
	--	CASE WHEN c.blocking_chain IS NULL THEN detail.[report] ELSE ISNULL(s.[report], N'<lead_blocker/>') END [report]
	--FROM 
	--	chain c
	--	INNER JOIN #work detail ON c.report_id = detail.report_id
	--	LEFT OUTER JOIN [#work] s ON c.report_id = s.report_id AND c.blocking_id = s.blocked_id 
	--	LEFT OUTER JOIN aggregated a ON c.report_id = a.report_id
	--ORDER BY 
	--	c.report_id, c.[level];

	RETURN 0;
GO