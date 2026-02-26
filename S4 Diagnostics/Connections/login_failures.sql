

/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[login_failures]','P') IS NOT NULL
	DROP PROC dbo.[login_failures];
GO

CREATE PROC dbo.[login_failures]
	@start							sysname				= N'2 weeks',		-- see https://www.notion.so/overachiever/2026-02-25-3125380af00e8039aba7ed71e6d4bcd6?source=copy_link
	--@end							sysname				= NULL, 
	@mode							sysname				= N'SUMMARY',		-- SUMMARY | DETAIL
	@exclude_local_connections		bit					= 0, 
	@ips							nvarchar(MAX)		= NULL, 
	@principals						nvarchar(MAX)		= NULL, 
	@text							nvarchar(MAX)		= NULL,				-- any specific text to exclude OR include. 
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @start = ISNULL(NULLIF(@start, N''), N'2 weeks');
	--SET @end = NULLIF(@end, N'');
	SET @exclude_local_connections = ISNULL(@exclude_local_connections, 0);
	SET @ips = NULLIF(@ips, N'');
	SET @principals = NULLIF(@principals, N'');

	DECLARE @startTime datetime;
	DECLARE @error nvarchar(MAX);
	EXEC dbo.[translate_vector_datetime]
		@Vector = @start,
		@Operation = N'SUBTRACT',
		@Output = @startTime OUTPUT,
		@Error = @error OUTPUT

	IF @error IS NOT NULL BEGIN
		RAISERROR(@error, 16, 1);
		RETURN 1;
	END;

-- TODO: extract vectors... 
--		and then validate them - make sure they're not too long/etc. 
--		also ... there's an option for FILES here... which ... hmmm. yeah.... as per: https://www.notion.so/overachiever/2026-02-25-3125380af00e8039aba7ed71e6d4bcd6?source=copy_link

-- HACK for now: 
--	DECLARE @endTime datetime;

	CREATE TABLE #event_log_entries (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[log_date] datetime NOT NULL,
		[process_info] sysname NOT NULL,
		[text] varchar(2048) NOT NULL
	);	

	DECLARE @minTimeStamp datetime = GETDATE();	
	DECLARE @targetLog int = 0;
	DECLARE @rowCount int = 999; 

	WHILE (@rowCount > 0) AND (@minTimeStamp > @startTime) BEGIN 
		INSERT INTO [#event_log_entries]
		EXEC sys.[xp_readerrorlog] @targetLog, 1;   -- TODO: https://www.notion.so/overachiever/Testing-Seams-2995380af00e806d93f7f9f318da000e?v=2b28b332289541a6a43c48c583c14d97&source=copy_link
	
		SELECT @rowCount = @@ROWCOUNT;
		SET @minTimeStamp = (SELECT MIN([log_date]) FROM #event_log_entries);
		SET @targetLog = @targetLog + 1;
	END;

	WITH identified AS (
		SELECT
			[row_number],
			[e].[log_date], 
			[e].[text], 
			REPLACE(RIGHT([e].[text], LEN([e].[text]) - PATINDEX(N'%CLIENT: %', [e]. [text]) - 7), N']', N'') [ip]
		FROM 
			[#event_log_entries] [e]
		WHERE 
			[e].[text] LIKE N'Login failed%'
	), 
	expanded AS ( 
		SELECT 
			[i].[row_number],
			[p].[row_id],
			[p].[result]
		FROM 
			[identified] [i]
			CROSS APPLY dbo.[split_string]([i].[text], N'.', 1) [p]
		WHERE 
			[p].[row_id] < 3
	)

	/* NOTE: this is projected into a #tempTable here because string_split() perf sucks otherwise.  */
	SELECT 
		[i].[row_number], 
		[i].[log_date], 
		[i].[ip],
		[e].[row_id],
		[e].[result] 
	INTO 
		[#intermediate_login_failures]
	FROM 
		expanded [e]
		INNER JOIN [identified] [i] ON [e].[row_number] = [i].[row_number];

	--SELECT 
	--	[f].[log_date],
	--	LTRIM((SELECT REPLACE(REPLACE([result], N'Login failed for user', N''), N'''', N'') FROM [#intermediate_login_failures] [x] WHERE [x].[row_number] = [f].[row_number] AND [x].[row_id] = 1)) [principal], 
	--	(SELECT REPLACE([result], N'Reason: ', N'') + N'.' FROM [#intermediate_login_failures] [x] WHERE [x].[row_number] = [f].[row_number] AND [x].[row_id] = 2) [reason], 
	--	[f].[ip]
	--INTO 
	--	[#login_failures]
	--FROM 
	--	[#intermediate_login_failures] [f]
	--WHERE 
	--	[f].[row_id] = 1;

	IF @exclude_local_connections = 1 BEGIN
		IF ISNULL(@ips, N'') NOT LIKE N'%<local machine>%' BEGIN
			IF LEN(ISNULL(@ips, N'')) < 1 SET @ips = N'-<local machine>';
			ELSE SET @ips = @ips + N',-<local machine>';
		END;
	END;

	IF @ips IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_ips ([row_id] int IDENTITY(1,1) NOT NULL, [ip] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [ip]));		
	END;

	IF @principals IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_principals ([row_id] int IDENTITY(1,1) NOT NULL, [principal] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [principal]));
	END;

	DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
	EXEC dbo.[core_predicates]
		@IPs = @ips,
		@Principals = @principals,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	CREATE TABLE #login_failures (
		[log_date] [datetime] NOT NULL,
		[principal] [nvarchar](max) NULL,
		[reason] [nvarchar](max) NULL,
		[ip] sysname NULL
	); 

	DECLARE @sql nvarchar(MAX) = N'WITH core AS (SELECT 
		[f].[log_date],
		LTRIM((SELECT REPLACE(REPLACE([result], N''Login failed for user'', N''''), N'''''''', N'''') FROM [#intermediate_login_failures] [x] WHERE [x].[row_number] = [f].[row_number] AND [x].[row_id] = 1)) [principal], 
		(SELECT REPLACE([result], N''Reason: '', N'''') + N''.'' FROM [#intermediate_login_failures] [x] WHERE [x].[row_number] = [f].[row_number] AND [x].[row_id] = 2) [reason], 
		[f].[ip]
	FROM 
		[#intermediate_login_failures] [f]
	WHERE 
		[f].[row_id] = 1
) 

SELECT 
	[x].[log_date],
	[x].[principal],
	[x].[reason],
	[x].[ip]
FROM 
	[core] [x]{joins} 
{filters}';

	SET @sql = REPLACE(@sql, N'{joins}', @joins);

	IF NULLIF(@filters, N'') IS NULL SET @sql = REPLACE(@sql, N'{filters}', N'');
	ELSE SET @sql = REPLACE(@sql, N'{filters}', N'WHERE' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'1 = 1' + @filters);

	INSERT INTO [#login_failures] ([log_date], [principal], [reason], [ip])
	EXEC sys.sp_executesql 
		@sql;

	IF @mode = N'DETAIL' BEGIN
		IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
			SELECT @serialized_output = (
				SELECT 
					[log_date],
					[principal],
					[reason],
					[ip] 
				FROM 
					[#login_failures] 
				ORDER BY 
					[log_date]
				FOR XML PATH(N'failure'), ROOT(N'failures'), TYPE
			);

			RETURN 0;
		END;

		SELECT 
			[log_date],
			[principal],
			[reason],
			[ip] 
		FROM 
			[#login_failures] 
		ORDER BY 
			[log_date];

		RETURN 0;
	END;

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				[principal], 
				[ip], 
				COUNT(*) [fail_count],
				[reason] 
			FROM 
				#login_failures 
			GROUP BY
				[principal], [ip], [reason]
			ORDER BY 
				COUNT(*) DESC
			FOR XML PATH(N'failure'), ROOT(N'failures'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[principal], 
		[ip], 
		COUNT(*) [fail_count],
		[reason] 
	FROM 
		#login_failures 
	GROUP BY
		[principal], [ip], [reason]
	ORDER BY 
		COUNT(*) DESC;
	
	