/*

	vNEXT: 
		- Currently pulling 1x 'header' row PER each lead-blocker - normally, that's fine/good-ish. But if there's > 1 lead blocker, this quickly gets ugly/lame. 
			Especially if/when there are, say, 20 or 60+ lead blockers (yeah, it happens). In that case, there's like 30 or 60 some-odd 'header' rows... then the individual blocked process reports. 
				and... that all totally sucks. 
					A better approach for 1 or MORE (i.e., all scenarios) would be: 
							- 1x (only) 'header' row PER EACH blocked-process report_id. 
							- [process_count] still shows what it does now, e.g., 57 or 28 (i.e., total number of lead blockers and/or blocked process reports)
							- [blocking_chain] column shows: lead-blockers: 503, 128, 119, etc. - i.e., a 'serialized' list of lead blockers. 
							


	FODDER: 
		- Notes/Info about EMPTY processes: 
			https://dba.stackexchange.com/questions/168646/empty-blocking-process-in-blocked-process-report

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_chronological_blockedprocesses','P') IS NOT NULL
	DROP PROC dbo.[view_chronological_blockedprocesses];
GO

CREATE PROC dbo.[view_chronological_blockedprocesses]
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

	), 
	aggregated AS ( 
		SELECT 
			report_id, 
			MIN([timestamp]) [timestamp], 
			COUNT(*) [process_count]
		FROM 
			[#work] 
		GROUP BY 
			report_id
	)

	SELECT 
		CASE WHEN s.[timestamp] IS NULL THEN CAST(c.report_id AS sysname) ELSE N'' END [report_id],
		CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.[database_name], N'') ELSE ISNULL([s].[database_name], N'') END [database_name],
		CASE WHEN s.[report] IS NULL THEN CONVERT(sysname,  a.[timestamp], 120) ELSE N'' END [timestamp],
		CASE WHEN s.[report] IS NULL THEN CAST(a.[process_count] AS sysname) ELSE N'' END [process_count],
		
		CASE WHEN c.blocking_chain IS NULL THEN N'     ' + CAST(detail.blocked_id AS sysname) + N' -> (' + CAST(detail.blocked_id AS sysname) + N')'  ELSE SPACE(4 * c.[level]) + c.blocking_chain END [blocking_chain],

		CASE WHEN c.blocking_chain IS NULL THEN dbo.[format_timespan](detail.blocked_wait_time) ELSE dbo.format_timespan(s.blocked_wait_time) END [time_blocked],

		s.blocking_tran_count, 
		ISNULL(CAST(s.blocking_xactid AS sysname), '') blocking_xactid,  -- VERY helpful in determining which 'blocker' is the same from one blocked-process-report to the next... 
		ISNULL(s.blocking_isolation_level, '') blocking_isolation_level,
		CASE WHEN c.blocking_chain IS NULL THEN N'<blocking-self>' ELSE ISNULL(s.blocking_status, N'') END [blocking_status],	
		CASE WHEN s.blocking_request LIKE N'%Object Id = [0-9]%' THEN s.blocking_request + N' --> ' + ISNULL(s.blocking_sproc_statement, N'#sproc_statement_extraction_error#') ELSE ISNULL(s.blocking_request, '') END [blocking_request],
		ISNULL(s.blocking_resource, '') blocking_resource, 

		CASE WHEN c.blocking_chain IS NULL 
			THEN CASE WHEN detail.blocked_request LIKE N'xx' THEN detail.blocked_request + N' --> ' + detail.blocked_sproc_statement ELSE ISNULL(detail.blocked_request, '') END
			ELSE CASE WHEN s.blocked_request LIKE N'xx' THEN s.blocked_request + N' --> ' + s.blocked_sproc_statement ELSE ISNULL(s.blocked_request, '') END 
		END [blocked_request],
		
		CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.blocked_resource, N'') ELSE ISNULL(s.blocked_resource, N'') END [blocked_resource],
		CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.blocked_status, N'') ELSE ISNULL(s.blocked_status, '') END [blocked_status],
		
		CASE WHEN c.blocking_chain IS NULL THEN ISNULL(detail.blocked_isolation_level, N'') ELSE ISNULL(s.blocked_isolation_level, N'') END blocked_isolation_level,
		CASE WHEN c.blocking_chain IS NULL THEN detail.blocked_tran_count ELSE s.blocked_tran_count END [blocked_tran_count],
		CASE WHEN c.blocking_chain IS NULL THEN detail.blocked_log_used ELSE s.blocked_log_used END [blocked_log_used],
		
		s.[blocking_weight],
		s.[blocking_host_name], 
		s.[blocking_client_app] [blocking_app_name],
		CASE WHEN c.blocking_chain IS NULL THEN detail.[blocked_weight] ELSE s.[blocked_weight] END [blocked_weight],
		CASE WHEN c.blocking_chain IS NULL THEN detail.[blocked_host_name] ELSE s.[blocked_host_name] END [blocked_host_name], 
		CASE WHEN c.blocking_chain IS NULL THEN detail.[blocked_client_app] ELSE s.[blocked_client_app] END [blocked_app_name],
		
		CASE WHEN c.blocking_chain IS NULL THEN detail.[report] ELSE ISNULL(s.[report], N'<lead_blocker/>') END [report]
	FROM 
		chain c
		INNER JOIN #work detail ON c.report_id = detail.report_id
		LEFT OUTER JOIN [#work] s ON c.report_id = s.report_id AND c.blocking_id = s.blocked_id 
		LEFT OUTER JOIN aggregated a ON c.report_id = a.report_id
	ORDER BY 
		c.report_id, c.[level];

	RETURN 0;
GO