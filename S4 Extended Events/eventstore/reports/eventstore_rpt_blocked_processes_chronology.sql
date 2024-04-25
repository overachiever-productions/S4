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

IF OBJECT_ID('dbo.[eventstore_rpt_blocked_processes_chronology]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_rpt_blocked_processes_chronology];
GO

CREATE PROC dbo.[eventstore_rpt_blocked_processes_chronology]
	@Start						datetime		= NULL, 
	@End						datetime		= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @eventStoreKey sysname = N'BLOCKED_PROCESSES';
	DECLARE @eventStoreTarget sysname = (SELECT [target_table] FROM [dbo].[eventstore_settings] WHERE [event_store_key] = @eventStoreKey); 

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @eventStoreTarget, 
		@ParameterNameForTarget = N'@eventStoreTarget', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised...

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Time-Bounding Predicates and Translations:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	IF @Start IS NULL AND @End IS NULL BEGIN 
		SET @Start = DATEADD(HOUR, -2, GETDATE());
		SET @End = GETDATE();
	  END; 
	ELSE BEGIN 
		IF @Start IS NOT NULL BEGIN 
			SET @End = DATEADD(HOUR, 2, @Start);
		END;

		IF @End IS NULL AND @Start IS NOT NULL BEGIN 
			RAISERROR(N'A value for @End can ONLY be specified if a value for @Start has been provided.', 16, 1);
			RETURN -2;
		END;

		IF @End < @Start BEGIN 
			RAISERROR(N'Specified value for @End can NOT be less than (earlier than) value provided for @Start.', 16, 1);
			RETURN -3;
		END;
	END;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Extraction / Work-Table:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
	CREATE TABLE #work (
		[row_id] int NOT NULL,
		[timestamp] [datetime2](7) NOT NULL,
		[database_name] [nvarchar](128) NOT NULL,
		[seconds_blocked] [decimal](24, 2) NOT NULL,
		[report_id] [int] NOT NULL,
		[blocking_id] sysname NULL,  -- ''self blockers'' can/will be NULL
		[blocked_id] sysname NOT NULL,
		[blocking_xactid] [bigint] NULL,  -- ''self blockers'' can/will be NULL
		[blocking_request] [nvarchar](MAX) NOT NULL,
		[blocking_sproc_statement] [nvarchar](MAX) NOT NULL,
		[blocking_resource_id] [nvarchar](80) NULL,
		[blocking_resource] [varchar](2000) NOT NULL,
		[blocking_wait_time] [int] NULL,
		[blocking_tran_count] [int] NULL,  -- ''self blockers'' can/will be NULL
		[blocking_isolation_level] [nvarchar](128) NULL,   -- ''self blockers'' can/will be NULL
		[blocking_status] sysname NULL,
		[blocking_start_offset] [int] NULL,
		[blocking_end_offset] [int] NULL,
		[blocking_host_name] sysname NULL,
		[blocking_login_name] sysname NULL,
		[blocking_client_app] sysname NULL,
		[blocked_spid] [int] NOT NULL,
		[blocked_ecid] [int] NOT NULL,
		[blocked_xactid] [bigint] NULL,  -- can be NULL
		[blocked_request] [nvarchar](max) NOT NULL,
		[blocked_sproc_statement] [nvarchar](max) NOT NULL,
		[blocked_resource_id] [nvarchar](80) NOT NULL,
		[blocked_resource] [varchar](2000) NULL,  -- can be NULL if/when there isn''t an existing translation
		[blocked_wait_time] [int] NOT NULL,
		[blocked_tran_count] [int] NOT NULL,
		[blocked_log_used] [int] NOT NULL,
		[blocked_lock_mode] sysname NULL, -- CAN be NULL
		[blocked_isolation_level] [nvarchar](128) NULL,
		[blocked_status] sysname NOT NULL,
		[blocked_start_offset] [int] NOT NULL,
		[blocked_end_offset] [int] NOT NULL,
		[blocked_host_name] sysname NULL,
		[blocked_login_name] sysname NULL,
		[blocked_client_app] sysname NULL,
		[report] [xml] NOT NULL
	);

	CREATE CLUSTERED INDEX [____CLIX_#work_byReportId] ON [#work] (report_id);

	DECLARE @sql nvarchar(MAX) = N'	SELECT 
		*
	FROM 
		{SourceTable}
	WHERE
		[timestamp] >= @Start
		AND [timestamp] < @End
	ORDER BY 
		[row_id]; ';

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);

	INSERT INTO [#work] (
		[row_id],
		[timestamp],
		[database_name],
		[seconds_blocked],
		[report_id],
		[blocking_id],
		[blocked_id],
		[blocking_xactid],
		[blocking_request],
		[blocking_sproc_statement],
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
		@sql, 
		N'@Start datetime, @End datetime', 
		@Start = @Start, 
		@End = @End;

	-----------------------------------------------------------------------------------------------------------------------------------------------------
	-- Correlation + Projection:
	-----------------------------------------------------------------------------------------------------------------------------------------------------
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
			CAST(blocking_id AS sysname) [blocking_chain]
		FROM 
			leads 

		UNION ALL 

		SELECT 
			base.report_id, 
			c.[level] + 1 [level],
			base.blocked_id, 
			CAST(c.[blocking_chain] + N' -> ' + CAST(base.blocked_id AS nvarchar(10)) AS sysname)
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

--
	WITH normalized AS ( 

		SELECT 
			ISNULL([c].[level], -1) [level],
			[w].[blocking_id],
			[w].[blocked_id],
			LAG([w].[report_id], 1, 0) OVER (ORDER BY [w].[report_id], ISNULL([c].[level], -1)) [previous_report_id],

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
		
			--[w].[blocking_weight],
			--[w].[blocked_weight],

			[w].[blocking_host_name],
			[w].[blocking_login_name],
			[w].[blocking_client_app],
		
			[w].[blocked_host_name],
			[w].[blocked_login_name],
			[w].[blocked_client_app],
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

	RETURN 0;
GO


