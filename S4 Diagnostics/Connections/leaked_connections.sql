/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[leaked_connections]','P') IS NOT NULL
	DROP PROC dbo.[leaked_connections];
GO

CREATE PROC dbo.[leaked_connections]
	@idle_threshold							sysname				= N'120 seconds',
	@pool_count_threshold					int					= 20,
	@aggregate								sysname				= N'DB_APP_LOGIN',			-- { DB_APP_LOGIN | APP_LOGIN | LOGIN | DB_APP_LOGIN_HOST | DB_APP_LOGIN_IP }
	@mode									sysname				= N'DETAIL',				-- { SUMMARY | DETAIL }
	@databases								nvarchar(MAX)		= NULL,
	@applications							nvarchar(MAX)		= NULL, 
	@principals								nvarchar(MAX)		= NULL, 
	@roles									nvarchar(MAX)		= NULL,						
	@hosts									nvarchar(MAX)		= NULL, 
	@ips									nvarchar(MAX)		= NULL, 
	@statements								nvarchar(MAX)		= NULL,	
	@print_only								bit					= 0,
	@serialized_output						xml					= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @idle_threshold = ISNULL(NULLIF(@idle_threshold, N''), N'120 seconds');
	SET @pool_count_threshold = ISNULL(NULLIF(@pool_count_threshold, 0), 20);
	SET @aggregate = UPPER(ISNULL(NULLIF(@aggregate, N''), N'DB_APP_LOGIN'));
	SET @mode = UPPER(ISNULL(NULLIF(@mode, N''), N'DETAIL'));
	SET @databases = NULLIF(@databases, N'');
	SET @applications = NULLIF(@applications, N'');
	SET @principals = NULLIF(@principals, N'');
	SET @roles = NULLIF(@roles, N'');
	SET @hosts = NULLIF(@hosts, N'');
	SET @ips = NULLIF(@ips, N'');
	SET @statements = NULLIF(@statements, N'');
	SET @print_only = ISNULL(@print_only, 0);

	IF @aggregate NOT IN (N'DB_APP_LOGIN', N'APP_LOGIN', N'LOGIN', N'DB_APP_LOGIN_HOST', N'DB_APP_LOGIN_IP') BEGIN
		RAISERROR(N'Invalid value for @aggregate parameter. Valid values are: { DB_APP_LOGIN, APP_LOGIN, LOGIN, DB_APP_LOGIN_HOST, DB_APP_LOGIN_IP }.', 16, 1);
		RETURN -10;
	END

	DECLARE @idleThresholdMilliseconds bigint = -1, @vectorError nvarchar(MAX);

	IF @idle_threshold IS NOT NULL BEGIN 
		EXEC admindb.dbo.[translate_vector]
			@Vector = @idle_threshold,
			@ValidationParameterName = N'@idle_threshold',
			@Output = @idleThresholdMilliseconds OUTPUT,
			@Error = @vectorError OUTPUT; 

		IF @vectorError IS NOT NULL BEGIN
			RAISERROR(@vectorError, 16, 1);
			RETURN -11;  
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Identify Leaks (via aggregated idle connections):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #conn_pool_leaks (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[connections] int NOT NULL
	);

	IF @aggregate LIKE N'%DB%' ALTER TABLE [#conn_pool_leaks] ADD [database] sysname NOT NULL;
	IF @aggregate LIKE N'%APP%' ALTER TABLE [#conn_pool_leaks] ADD [application] sysname NOT NULL;
	IF @aggregate LIKE N'%LOGIN%' ALTER TABLE [#conn_pool_leaks] ADD [principal] sysname NOT NULL;
	IF @aggregate LIKE N'%HOST%' ALTER TABLE [#conn_pool_leaks] ADD [host] sysname NOT NULL;
	IF @aggregate LIKE N'%IP%' ALTER TABLE [#conn_pool_leaks] ADD [ip] sysname NOT NULL;

	DECLARE @sql nvarchar(MAX) = N'SELECT
		COUNT([s].[session_id]) [connections],
		{GroupBy}
	FROM
		[sys].[dm_exec_sessions] [s]
		INNER JOIN [sys].[dm_exec_connections] [c] ON [s].[session_id] = [c].[session_id]
	WHERE
		[s].[is_user_process] = 1 --AND [s].[status] != ''running''
	GROUP BY
		{GroupBy}
	HAVING
		COUNT([s].[session_id]) > @pool_count_threshold
	ORDER BY
		COUNT([s].[session_id]) DESC; ';

	DECLARE @crlftabtab nchar(4) = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9);
	DECLARE @groupBy nvarchar(MAX) = '', @cursorVars nvarchar(MAX), @predicates nvarchar(MAX) = N'', @fetchedCols nvarchar(MAX) = N'', @columns nvarchar(MAX) = N'';
	SELECT 
		@groupBy = STRING_AGG([x].[translation], N', ') WITHIN GROUP (ORDER BY [x].[order] ASC), 
		@cursorVars = STRING_AGG(N'@' + LOWER([a].[result]) + N' sysname', N', ') WITHIN GROUP (ORDER BY [x].[order] ASC), 
		@predicates = STRING_AGG(N'AND ' + [x].[translation] + N' = @' + LOWER([a].[result]), @crlftabtab) WITHIN GROUP (ORDER BY [x].[order] ASC), 
		@fetchedCols = STRING_AGG(N'@' + LOWER([a].[result]), N', ') WITHIN GROUP (ORDER BY [x].[order] ASC), 
		@columns = STRING_AGG([x].[column], N', ') WITHIN GROUP (ORDER BY [x].[order] ASC)
	FROM 
		dbo.[split_string](@aggregate, N'_', 1) [a]
		INNER JOIN (
		SELECT 
			[source], 
			[translation], 
			[column],
			[order]
		FROM 
			(VALUES
				(N'DB', N'DB_NAME([s].[database_id])', N'[database]', 1), 
				(N'APP', N'[s].[program_name]', N'[application]', 2),
				(N'LOGIN', N'[s].[login_name]', N'[principal]', 3), 
				(N'HOST', N'[s].[host_name]', N'[host]', 4), 
				(N'IP', N'[c].[client_net_address]', N'[ip]', 5)
			) [x]([source], [translation], [column], [order])
		) [x] ON [x].[source] = [result];
	
	SET @sql = REPLACE(@sql, N'{GroupBy}', @groupBy);

	INSERT INTO [#conn_pool_leaks] -- I hate NON-EXPLICIT INSERTs... but... 
	EXEC sp_executesql 
		@sql, 
		N'@pool_count_threshold int', 
		@pool_count_threshold = @pool_count_threshold;

	IF NOT EXISTS (SELECT NULL FROM [#conn_pool_leaks]) BEGIN 
		RETURN 0;
	END;

	IF @print_only = 1 BEGIN 
		SELECT * FROM [#conn_pool_leaks] ORDER BY [connections] DESC;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Expand all Leaks > @pool_count_threshold
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	CREATE TABLE #all_leaked_spids (
		[session_id] smallint NOT NULL,
		[login_time] datetime NOT NULL,
		[host] sysname NULL,
		[application] sysname NULL,
		[principal] sysname NOT NULL,
		[status] nvarchar(30) NOT NULL,
		[last_request_end_time] datetime NULL,
		[is_user_process] bit NOT NULL,
		[prev_error] int NOT NULL,
		[last_successful_logon] datetime NULL,
		[open_transaction_count] int NOT NULL,
		[ip] nvarchar(48) NULL,
		[most_recent_sql_handle] varbinary(64) NULL, 
		[statement] nvarchar(MAX) NULL
	);

	DECLARE @selectTemplate nvarchar(MAX) = N'SELECT
		[s].[session_id],
		[s].[login_time],
		[s].[host_name] [host],
		[s].[program_name] [application],
		[s].[login_name] [principal],
		[s].[status],
		[s].[last_request_end_time],
		[s].[is_user_process],
		[s].[prev_error],
		[s].[last_successful_logon],
		[s].[open_transaction_count],
		[c].[client_net_address] [ip],
		[c].[most_recent_sql_handle], 
		[t].[text] [statement]
	FROM
		[sys].[dm_exec_sessions] [s]
		INNER JOIN [sys].[dm_exec_connections] [c] ON [s].[session_id] = [c].[session_id]
		OUTER APPLY sys.[dm_exec_sql_text]([c].[most_recent_sql_handle]) [t]
	WHERE
		[s].[status] = ''sleeping''
		' + @predicates;

	SET @sql = N'DECLARE {declarations};
DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
SELECT 
	{columns}
FROM 
	[#conn_pool_leaks];
	
OPEN [walker];
FETCH NEXT FROM [walker] INTO {fetchedCols};
	
WHILE @@FETCH_STATUS = 0 BEGIN
	
	INSERT INTO [#all_leaked_spids]
	(
		[session_id],
		[login_time],
		[host],
		[application],
		[principal],
		[status],
		[last_request_end_time],
		[is_user_process],
		[prev_error],
		[last_successful_logon],
		[open_transaction_count],
		[ip],
		[most_recent_sql_handle], 
		[statement]
	)
	{selectTemplate}
	
	FETCH NEXT FROM [walker] INTO {fetchedCols};
END;
	
CLOSE [walker];
DEALLOCATE [walker]; ';

	SET @sql = REPLACE(@sql, N'{selectTemplate}', @selectTemplate);
	SET @sql = REPLACE(@sql, N'{declarations}', @cursorVars);
	SET @sql = REPLACE(@sql, N'{fetchedCols}', @fetchedCols);
	SET @sql = REPLACE(@sql, N'{columns}', REPLACE(REPLACE(@columns, N'DB_NAME([s].[database_id])', N'[s].[database_id]'), N'[s].', N''));

	EXEC [sys].[sp_executesql] 
		@sql;
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Filters / Exclusions (Predicates):
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
PREDICATES:
	IF @databases IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_databases ([row_id] int IDENTITY(1,1) NOT NULL, [database] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [database]));
	END;
	
	IF @applications IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_applications ([row_id] int IDENTITY(1,1) NOT NULL, [application] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [application]));
	END; 

	IF @hosts IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_hosts ([row_id] int IDENTITY(1,1) NOT NULL, [host] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [host])); 
	END;

	IF @ips IS NOT NULL BEGIN 
		CREATE TABLE #ts_cp_ips ([row_id] int IDENTITY(1,1) NOT NULL, [ip] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [ip]));		
	END;

	IF @principals IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_principals ([row_id] int IDENTITY(1,1) NOT NULL, [principal] sysname NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude], [principal]));
	END;

	IF @statements IS NOT NULL BEGIN
		CREATE TABLE #ts_cp_statements ([row_id] int IDENTITY(1,1) NOT NULL, [statement] nvarchar(MAX) NOT NULL, [exclude] bit DEFAULT(0), PRIMARY KEY CLUSTERED ([exclude]));
	END;

	DECLARE @joins nvarchar(MAX), @filters nvarchar(MAX);
	EXEC dbo.[core_predicates]
		@Databases = @databases,
		@Applications = @applications,
		@Hosts = @hosts,
		@IPs = @ips,
		@Principals = @principals,
		@Statements = @statements,
		@JoinPredicates = @joins OUTPUT,
		@FilterPredicates = @filters OUTPUT;

	IF @mode = N'SUMMARY' BEGIN 
		
		-- push the results of this into #intermediateSummary ... 
		--    with predicates ... 
		--   and order by POOL_COUNT desc... 
		-- OBVIOUSLY ... figuring out WHICH columns exist is ... going to be a bit odd/weird/different. 

		SELECT * FROM #conn_pool_leaks ORDER BY [connections] DESC;
		
		-- THEN, from intermediateSummary ... project or push the results into @serialized_output ...

		RETURN 0;
	END;

	CREATE TABLE #intermediate (
		[session_id] smallint NOT NULL,
		[login_time] datetime NOT NULL,
		[host] sysname NULL,
		[application] sysname NULL,
		[principal] sysname NOT NULL,
		[status] nvarchar(30) NOT NULL,
		[last_request_end_time] datetime NULL,
		[is_user_process] bit NOT NULL,
		[prev_error] int NOT NULL,
		[last_successful_logon] datetime NULL,
		[open_transaction_count] int NOT NULL,
		[ip] nvarchar(48) NULL,
		[most_recent_sql_handle] varbinary(64) NULL, 
		[statement] nvarchar(MAX) NULL
	);


-- TODO: the following SELECT is fine/great - but it's missing something: identification of which sessions are ... part of which connection-pool leak GROUPS. 
--    To 'solve' for this, I should do the following: 
--	   a. tweak my (dynamic) cursor to pull in the @connections (count) per each row being walked through ...
--			b. push that into the #all_leaked_spids table (as a new column) ...
--     c. and... better than just a 'number' (like 48, 22)... 
--        1. ROW_NUMBER() OVER ... partition by COUNT... to ASCII => A, B, C, D, E etc. 
--        2. and have this [pool_id] column in the SUMMARY output
--		3 as well as in the DETAIL ... that way you can see that pool B is xxx... and pull the detail and get all sorts of details on Pool B. 

	SET @sql = N'SELECT 
	[x].[session_id],
	[x].[login_time],
	[x].[host],
	[x].[application],
	[x].[principal],
	[x].[status],
	[x].[last_request_end_time],
	[x].[is_user_process],
	[x].[prev_error],
	[x].[last_successful_logon],
	[x].[open_transaction_count],
	[x].[ip],
	[x].[most_recent_sql_handle],
	[x].[statement] 
FROM 
	[#all_leaked_spids] [x]{joins}
WHERE 
	1 = 1{filters}
ORDER BY 
	[x].[session_id];';  -- TODO: need to order by the columns that we're aggregating against? right? 

	SET @sql = REPLACE(@sql, N'{joins}', @joins);
	SET @sql = REPLACE(@sql, N'{filters}', @filters);

	INSERT INTO [#intermediate]
	EXEC [sys].[sp_executesql] 
		@sql;

	SELECT 
		* 
	FROM 
		#intermediate;