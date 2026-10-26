/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.kill_resource_governor_connections','P') IS NOT NULL
	DROP PROC dbo.[kill_resource_governor_connections];
GO

CREATE PROC dbo.[kill_resource_governor_connections]
	@TargetWorkgroups					nvarchar(MAX)		= N'{ALL}',					-- cannot/does-not include internal or default
	@TargetResourcePools				nvarchar(MAX)		= N'{ALL}',					-- cannot/does-not include internal or default
	@TerminationLoopCount				int					= 3,
	@WaitForDelay						sysname				= N'00:00:01.500',
	@ListOnly							bit					= 0,						-- instead of executing a KILL, just lists connections that WOULD be killed. 
	@KillSelf							bit					= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TargetWorkgroups = ISNULL(NULLIF(@TargetWorkgroups, N''), N'{ALL}');
	SET @TargetResourcePools = ISNULL(NULLIF(@TargetResourcePools, N''), N'{ALL}');
	SET @WaitForDelay = ISNULL(NULLIF(@WaitForDelay, N''), N'00:00:01.500');
	SET @TerminationLoopCount = ISNULL(@TerminationLoopCount, 3);
	SET @ListOnly = ISNULL(@ListOnly, 0);
	SET @KillSelf = ISNULL(@KillSelf, 1);

	CREATE TABLE #targets (
		row_id int IDENTITY(1,1) NOT NULL, 
		session_id int NOT NULL, 
		login_name sysname NOT NULL,
		[host_name] sysname NULL, 
		[program_name] sysname NULL, 
		[status] sysname NULL, 
		[last_request_end_time] datetime NULL,
		[workgroup] sysname NULL, 
		[pool] sysname NULL, 
		[killed] datetime NULL, 
		[error] nvarchar(MAX) NULL
	);

	DECLARE @crlfTabTab sysname = NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9);
	DECLARE @selectionSql nvarchar(MAX) = N'
	SELECT 
		s.[session_id],
		s.[login_name],
		s.[host_name], 
		s.[program_name], 
		s.[status], 
		s.[last_request_end_time],
		g.[name] [workgroup],
		p.[name] [pool]
	FROM 
		sys.[dm_exec_sessions] s 
		INNER JOIN sys.[dm_resource_governor_workload_groups] g ON [s].[group_id] = [g].[group_id]
		INNER JOIN sys.[dm_resource_governor_resource_pools] p ON [g].[pool_id] = [p].[pool_id] 
	WHERE 
		g.[name] NOT IN (N''internal'', N''default'') 
		AND p.[name] NOT IN (N''internal'', N''default''){targets}
		
		AND s.[session_id] NOT IN (SELECT session_id FROM #targets);';

	DECLARE @targets nvarchar(MAX) = N'';
	IF @TargetWorkgroups <> N'{ALL}' BEGIN 
		SET @targets = @crlfTabTab + N'AND [g].[name] IN (SELECT [result] FROM dbo.split_string(@TargetWorkGroups, N'','', 1)) ';
	END;

	IF @TargetResourcePools <> N'{ALL}' BEGIN 
		IF @targets = N'' BEGIN 
			SET @targets =  @crlfTabTab + N'AND [p].[name] IN (SELECT [result] FROM dbo.split_string(@TargetResourcePools, N'','', 1)) ';
		  END; 
		ELSE BEGIN 
			SET @targets = @crlfTabTab + N'AND (';
			SET @targets = @targets + @crlfTabTab + NCHAR(9) + N'([g].[name] IN (SELECT [result] FROM dbo.split_string(@TargetWorkGroups, N'','', 1))) ';
			SET @targets = @targets + @crlfTabTab + N'  OR ';
			SET @targets = @targets + @crlfTabTab + NCHAR(9) + N'([p].[name] IN (SELECT [result] FROM dbo.split_string(@TargetResourcePools, N'','', 1))) ';
			SET @targets = @targets + @crlfTabTab + N')'
		END;
	END;

	SET @selectionSql = REPLACE(@selectionSql, N'{targets}', @targets);

	DECLARE @loopsProcessed int = 0;

LoadAndKill:
	INSERT INTO [#targets] (
		[session_id],
		[login_name],
		[host_name],
		[program_name],
		[status], 
		[last_request_end_time],
		[workgroup],
		[pool]
	)
	EXEC sp_executesql 
		@selectionSql, 
		N'@TargetWorkGroups nvarchar(MAX), @TargetResourcePools nvarchar(MAX)', 
		@TargetWorkgroups = @TargetWorkgroups, 
		@TargetResourcePools = @TargetResourcePools;

	IF @ListOnly = 1 BEGIN 
		IF EXISTS (SELECT NULL FROM [#targets]) BEGIN
			SELECT 
				[session_id],
				[login_name],
				[host_name],
				CASE 
					WHEN [status] = 'sleeping' THEN 
						CASE 
							WHEN DATEDIFF(MINUTE, [last_request_end_time], GETDATE()) > 2880 THEN 'sleeping - DAYS (2+)'
							WHEN DATEDIFF(MINUTE, [last_request_end_time], GETDATE()) > 1440 THEN 'sleeping - DAY'
							WHEN DATEDIFF(MINUTE, [last_request_end_time], GETDATE()) > 120 THEN 'sleeping - HOURS+'
							WHEN DATEDIFF(MINUTE, [last_request_end_time], GETDATE()) > 60 THEN 'sleeping - HOUR+'
							WHEN DATEDIFF(MINUTE, [last_request_end_time], GETDATE()) > 10 THEN 'sleeping - MINUTES (10+)'
							WHEN DATEDIFF(MINUTE, [last_request_end_time], GETDATE()) > 2 THEN 'sleeping - MINUTES'
							ELSE 'sleeping - SECONDS'
						END
					ELSE [status]
				END [state], 
				[program_name],
				[workgroup],
				[pool]
			FROM 
				[#targets]
			ORDER BY 
				[state],
				[session_id];
		END;
		RETURN 0;
	END;

	DECLARE @rowId int, @sessionID int;
	DECLARE @error nvarchar(MAX);
	DECLARE @killSql nvarchar(MAX);

	DECLARE [killer] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		row_id, 
		session_id 
	FROM 
		[#targets]
	WHERE 
		[killed] IS NULL;
	
	OPEN [killer];
	FETCH NEXT FROM [killer] INTO @rowId, @sessionID;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @error = NULL;

		IF @sessionID <> @@SPID BEGIN 
			SET @killSql = N'KILL ' + CAST(@sessionID AS sysname) + N';';
		
			BEGIN TRY 
				EXEC sp_executesql 
					@killSql; 
			END TRY 
			BEGIN CATCH 
				SET @error = CAST(ERROR_NUMBER() AS sysname) + N' - ' + ERROR_MESSAGE();
			END CATCH

			UPDATE [#targets] 
			SET 
				[killed] = GETDATE(), 
				[error] = @error 
			WHERE 
				[row_id] = @rowId
		END;
	
		FETCH NEXT FROM [killer] INTO @rowId, @sessionID;
	END;
	
	CLOSE [killer];
	DEALLOCATE [killer];

	SET @loopsProcessed = @loopsProcessed + 1;

	IF @loopsProcessed <= @TerminationLoopCount BEGIN 
		WAITFOR DELAY @WaitForDelay;
		RAISERROR(N'-- Starting a new pass to load and KILL session_ids ... ', 8, 1) WITH NOWAIT; /* NOWAIT really never works... but, worth trying vs PRINT... */
		GOTO LoadAndKill;
	END;

	IF EXISTS (SELECT NULL FROM [#targets] WHERE [error] IS NOT NULL) BEGIN 
		SELECT 
			[session_id],
			[host_name],
			[program_name],
			[workgroup],
			[pool],
			[killed],
			[error] 
		FROM 
			[#targets] 
		WHERE 
			[error] IS NOT NULL;
	END;

	IF @KillSelf = 1 BEGIN 
		IF EXISTS (SELECT NULL FROM [#targets] WHERE [session_id] = @@SPID) BEGIN
			/* we can't KILL our own spid... but we CAN terminate it:   */
			RAISERROR(N'Terminating current session_id due to @KillSelf Directive set to value of 1.', 22, 16) WITH LOG;
		END;
	END;

	RETURN 0;
GO