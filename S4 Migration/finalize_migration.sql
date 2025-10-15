/*



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[finalize_migration]','P') IS NOT NULL
	DROP PROC dbo.[finalize_migration];
GO

CREATE PROC dbo.[finalize_migration]
	@Databases						nvarchar(MAX),				
	@Priorities						nvarchar(MAX)		= NULL,
	@ExecuteRecovery				bit					= 1,				
	@TargetCompatLevel				sysname				= N'{LATEST}', 
	@CheckSanityMarker				bit					= 1, 
	@Directives						sysname				= NULL, 
	@UpdateStatistics				bit					= 1,				-- NOTE: StatsUpdates are handled AFTER ALL @Databases have been restored, updated, brought-online, etc. - to avoid serialization/blocking. 
	@IndirectCheckpointSeconds		int					= 60,				-- if 0/NULL ... then won't be set. 
	@EnableADR						bit					= 1, 
	@CheckForOrphans				bit					= 1, 
	@IgnoredOrphans					nvarchar(MAX)		= NULL, 
	@PrintOnly						bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Databases = NULLIF(@Databases, N'');
	SET @Priorities = NULLIF(@Priorities, N'');
	SET @ExecuteRecovery = ISNULL(@ExecuteRecovery, 0);
	SET @TargetCompatLevel = ISNULL(NULLIF(@TargetCompatLevel, N''), N'{LATEST}');

	SET @EnableADR = ISNULL(@EnableADR, 1);
	SET @CheckSanityMarker = ISNULL(@CheckSanityMarker, 1);
	SET @Directives = NULLIF(@Directives, N'');

	SET @UpdateStatistics = ISNULL(@UpdateStatistics, 1);
	SET @CheckForOrphans = ISNULL(@CheckForOrphans, 1);
	SET @IgnoredOrphans = NULLIF(@IgnoredOrphans, N'');
	SET @PrintOnly = ISNULL(@PrintOnly, 0);

	IF @Databases IS NULL BEGIN 
		IF @Databases IS NULL BEGIN 
			RAISERROR(N'Invalid Input. Value for @Databases cannot be null or empty.', 16, 1);
			RETURN -1;
		END;
	  END
	ELSE BEGIN
		IF @Databases IN (N'master', N'msdb', N'tempdb') BEGIN 
			RAISERROR(N'Migration can only be initiated against USER databases.', 16, 1);
			RETURN -1;
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- HACK: @targets/@exclusions should handled via calls into dbo.load_database_names (but it's not done yet).
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @exclusions nvarchar(MAX) = N'';
	SELECT 
		@exclusions = @exclusions + LTRIM(SUBSTRING([result], CHARINDEX(N'-', [result]) + 1, LEN([result]))) + N','
	FROM 
		dbo.[split_string](@Databases, N',', 1)
	WHERE 
		[result] LIKE N'-%'
	ORDER BY 
		[row_id];

	IF @exclusions <> N''
		SET @exclusions = LEFT(@exclusions, LEN(@exclusions) - 1);

	DECLARE @targets nvarchar(MAX) = N'';
	SELECT 
		@targets = @targets + [result] + N','
	FROM 
		dbo.[split_string](@Databases, N',', 1)
	WHERE 
		[result] NOT LIKE N'-%'
	ORDER BY 
		[row_id];

	IF @targets <> N''
		SET @targets = LEFT(@targets, LEN(@targets) - 1);

	DECLARE @targetDatabases table (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL 
	);

	INSERT INTO @targetDatabases ([database_name])
	EXEC dbo.list_databases
		@Targets = @targets,
	    @Exclusions = @exclusions,
		@Priorities = @Priorities,
		@ExcludeSecondaries = 0,
		@ExcludeRestoring = 0, 
		@ExcludeRecovering = 0;

	IF UPPER(@TargetCompatLevel) = N'{LATEST}' BEGIN
		DECLARE @output decimal(4,2) = (SELECT admindb.dbo.[get_engine_version]());
		IF @output = 10.50 SET @output = 10.00; 

		SET @TargetCompatLevel = LEFT(REPLACE(CAST(@output AS sysname), N'.', N''), 3);
	END;

	IF @Directives IS NOT NULL BEGIN 
		SET @Directives = LTRIM(RTRIM(@Directives));
		IF ASCII(@Directives) <> 44 
			SET @Directives = N',' + @Directives;
	END;

	DECLARE @errors table (
		[error_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[timestamp] datetime NOT NULL, 
		[operation] sysname NOT NULL, 
		[exception] nvarchar(MAX) NOT NULL 
	);

	DECLARE @currentDb sysname; 
	DECLARE @sql nvarchar(MAX);

	DECLARE @errorMessage nvarchar(MAX), @errorLine int;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		REPLACE(REPLACE([database_name], N'[', N''), N']', N'')
	FROM 
		@targetDatabases 
	ORDER BY 
		[row_id];
	
	OPEN [walker];
	FETCH NEXT FROM [walker] INTO @currentDb;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		PRINT N'/*---------------------------------------------------------------------------------------------------------------------------------------------------';
		PRINT N'-- ' + @currentDb;
		PRINT N'---------------------------------------------------------------------------------------------------------------------------------------------------*/';
-- TODO: make sure @currentDB exists. 

		IF @ExecuteRecovery = 1 BEGIN 
			SET @sql = N'USE [master]; 
IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = N''' + @currentDb + N''' AND [state_desc] = N''RESTORING'') BEGIN 
	RESTORE DATABASE [' + @currentDb + N'] WITH RECOVERY' + ISNULL(@Directives, N'') + N';
END;';	
			BEGIN TRY 
				IF @PrintOnly = 0 BEGIN 
					EXEC sys.[sp_executesql] 
						@sql;
				  END 
				ELSE BEGIN 
					PRINT @sql;
					PRINT N'GO'; 
				END;
			END TRY
			BEGIN CATCH
				SELECT 
					@errorLine = ERROR_LINE(), 
					@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
				INSERT INTO @errors ([database_name], [timestamp], [operation], [exception])
				VALUES (@currentDb, GETDATE(), N'EXECUTE_RECOVERY', @errorMessage);

				IF @@TRANCOUNT > 0 
					ROLLBACK;
			END CATCH;
		END;

		SET @sql = N'USE [master]; 
ALTER DATABASE [' + @currentDb + N'] SET MULTI_USER; 
ALTER DATABASE [' + @currentDb + N'] SET COMPATIBILITY_LEVEL = ' + @TargetCompatLevel + N';
ALTER DATABASE [' + @currentDb + N'] SET PAGE_VERIFY CHECKSUM;
ALTER AUTHORIZATION ON DATABASE::[' + @currentDb + N'] TO [sa];';

		BEGIN TRY 
			IF @PrintOnly = 0 BEGIN 
				EXEC sys.[sp_executesql] 
					@sql;
				END; 
			ELSE BEGIN 
				PRINT N'';
				PRINT @sql;
				PRINT N'GO';
			END; 
		END TRY
		BEGIN CATCH
			SELECT 
				@errorLine = ERROR_LINE(), 
				@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
			INSERT INTO @errors ([database_name], [timestamp], [operation], [exception])
			VALUES (@currentDb, GETDATE(), N'COMPAT_MULTI_USER_ETC', @errorMessage);

			IF @@TRANCOUNT > 0 
				ROLLBACK;
		END CATCH

		IF NULLIF(@IndirectCheckpointSeconds, 0) IS NOT NULL BEGIN 
			SET @sql = N'USE [master];
IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = N''' + @currentDb + ''' AND [target_recovery_time_in_seconds] <> ' + CAST(@IndirectCheckpointSeconds AS sysname) + N') BEGIN 
	ALTER DATABASE [' + @currentDb + N'] SET TARGET_RECOVERY_TIME = ' + CAST(@IndirectCheckpointSeconds AS sysname) + ' SECONDS;
END;'
			
			BEGIN TRY 
				IF @PrintOnly = 0 BEGIN 
					EXEC sys.[sp_executesql]
						@sql;
				  END; 
				ELSE BEGIN 
					PRINT N'';
					PRINT @sql;
					PRINT N'GO';
				END; 
			END TRY
			BEGIN CATCH
				SELECT 
					@errorLine = ERROR_LINE(), 
					@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
				INSERT INTO @errors ([database_name], [timestamp], [operation], [exception])
				VALUES (@currentDb, GETDATE(), N'INDIRECT_CHECKPOINT', @errorMessage);

				IF @@TRANCOUNT > 0 
					ROLLBACK;
			END CATCH
		END;

		IF @EnableADR = 1 BEGIN 
			SET @sql = N'USE [master];
ALTER DATABASE [' + @currentDb + N'] SET ACCELERATED_DATABASE_RECOVERY = ON;';
			BEGIN TRY 
				IF @PrintOnly = 0 BEGIN 
					EXEC sys.[sp_executesql] 
						@sql;
				  END 
				ELSE BEGIN 
					PRINT N'';
					PRINT @sql;
					PRINT N'GO';
				END;
			END TRY 
			BEGIN CATCH

			END CATCH
		END;

		IF @CheckSanityMarker = 1 BEGIN 
			SET @sql = N'SELECT @@SERVER [server], N''' + @currentDb + N''' [database], * FROM [' + @currentDb + N']..[___migrationMarker];'

			BEGIN TRY 
				IF @PrintOnly = 0 BEGIN 
					EXEC sys.[sp_executesql] 
						@sql;
				  END; 
				ELSE BEGIN 
					PRINT N'';
					PRINT @sql; 
					PRINT N'GO';
				END;
			END TRY
			BEGIN CATCH

			END CATCH
		END;

		IF @CheckForOrphans = 1 BEGIN 
			SET @sql = N'EXEC [admindb].[dbo].[list_orphaned_users]
	@TargetDatabases = N'''+ @currentDb + N''', 
	@ExcludedUsers = N''' + ISNULL(@IgnoredOrphans, N'') + N'''; ';

			BEGIN TRY 
				IF @PrintOnly = 0 BEGIN 
					EXEC sys.[sp_executesql]
						@sql;
				  END; 
				ELSE BEGIN 
					PRINT N'';
					PRINT @sql; 
					PRINT N'GO';
				END;
			END TRY
			BEGIN CATCH
				SELECT 
					@errorLine = ERROR_LINE(), 
					@errorMessage = N'Exception: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
				INSERT INTO @errors ([database_name], [timestamp], [operation], [exception])
				VALUES (@currentDb, GETDATE(), N'ORPHAN_CHECKS', @errorMessage);

				IF @@TRANCOUNT > 0 
					ROLLBACK;
			END CATCH
		END;

		IF @PrintOnly = 0 BEGIN
			IF EXISTS (SELECT NULL FROM @errors WHERE [database_name] = @currentDb) BEGIN
				SELECT N'Encountered ' + CAST(COUNT(*) AS sysname) + N' errors within [' + @currentDb + N'.' [outcome] FROM @errors WHERE [database_name] = @currentDb;
			  END; 
			ELSE BEGIN 
				SELECT N'Operations for [' + @currentDb + N'] are complete.' [outcome];
			END;
		END;

		FETCH NEXT FROM [walker] INTO @currentDb;
	END;
	
	CLOSE [walker];
	DEALLOCATE [walker];

	IF EXISTS (SELECT NULL FROM @errors) BEGIN 
		SELECT * FROM @errors ORDER BY [error_id];
	END;

	IF @UpdateStatistics = 1 BEGIN 
		IF @PrintOnly = 0 BEGIN
			SELECT N'STARTING STATS UPDATES' [stats_status];
		END; 

		DECLARE [updater] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			REPLACE(REPLACE([database_name], N'[', N''), N']', N'')
		FROM 
			@targetDatabases 
		ORDER BY 
			[row_id];			
		
		OPEN [updater];
		FETCH NEXT FROM [updater] INTO @currentDb;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			SET @sql = N'EXEC [' + @currentDb + N']..[sp_updatestats];';
			
			IF @PrintOnly = 0 BEGIN 
				EXEC sys.sp_executesql 
					@sql;

				SELECT N'	Stats updates for [' + @currentDb + N'] complete.' [stats_status];
			  END;
			ELSE BEGIN
				PRINT N'';
				PRINT @sql;
				PRINT N'GO';
			END;
		
			FETCH NEXT FROM [updater] INTO @currentDb;
		END;
		
		CLOSE [updater];
		DEALLOCATE [updater];

	END;
GO