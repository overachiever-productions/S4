/*

		
	TODO: 
		Is there a REASON that I'm: 
			- executing sp_update_stats
			- THEN removing / dropping the __sanity marker table? 
				instead of the inverse??? 
				I MIGHT be doing this because I want enough time to SEE that the sanity marker table was there? 
				But... 
					a) there's a SELECT (maybe set that up to select a 'NULL' / default if the sanity marker table is NOT present). 
					b) I commonly run these either ... 1) the whole thing - so  ... it won't matter cuz I'll have already restored and will THEN know something is wrong. 
									or 2) I run them a few steps at a time - in which case I have to wait for stats to update BEFORE I can 'finish' with a given 
									db migration cuz I then have to come back in and nuke the sanity marker.


	TODO: 
		restrict @Directives to RESTRICTED_USER, KEEP_REPLICATION, KEEP_CDC, ENABLE_BROKER | ERROR_BROKER_CONVERSATIONS | NEW_BROKER, STOP_ON_ERROR | CONTINUE_ON_ERROR
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[script_targetdb_migration_template]','P') IS NOT NULL
	DROP PROC dbo.[script_targetdb_migration_template];
GO

CREATE PROC dbo.[script_targetdb_migration_template]
	@TargetDatabase					sysname				= NULL, 
	@TargetCompatLevel				sysname				= N'{LATEST}',			-- { {LATEST} | 150 | 140 | 130 | 120 } 
	@EnableADR						bit					= 1, 
	@CheckSanityMarker				bit					= 1, 
	@Directives						sysname				= NULL,					-- USAGE: this is just a LITERAL string to add to the end of the RESTORE <dbName> WITH RECOVERY<x>; (where x = @Directives LITERAL TEXT). 
	@UpdateStatistics				bit					= 1, 
	@CheckForOrphans				bit					= 1, 
	@IgnoredOrphans					nvarchar(MAX)		= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SET @TargetCompatLevel = ISNULL(NULLIF(@TargetCompatLevel, N''), N'{LATEST}');

	SET @EnableADR = ISNULL(@EnableADR, 1);
	SET @CheckSanityMarker = ISNULL(@CheckSanityMarker, 1);
	SET @Directives = NULLIF(@Directives, N'');

	SET @UpdateStatistics = ISNULL(@UpdateStatistics, 1);
	SET @CheckForOrphans = ISNULL(@CheckForOrphans, 1);
	SET @IgnoredOrphans = NULLIF(@IgnoredOrphans, N'');

	IF @TargetDatabase IS NULL BEGIN 
		RAISERROR(N'@TargetDatabase cannot be NULL or empty.', 16, 1);
		RETURN -2;
	END;

	IF @Directives IS NOT NULL BEGIN 
		SET @Directives = LTRIM(RTRIM(@Directives));
		IF ASCII(@Directives) <> 44 
			SET @Directives = N',' + @Directives;
	END;

	IF UPPER(@TargetCompatLevel) = N'{LATEST}' BEGIN
		DECLARE @output decimal(4,2) = (SELECT admindb.dbo.[get_engine_version]());
		IF @output = 10.50 SET @output = 10.00; 

		SET @TargetCompatLevel = LEFT(REPLACE(CAST(@output AS sysname), N'.', N''), 3);
	END;

	PRINT '------------------------------------------------------------------------	
-- Execute RECOVERY if/as needed: 
USE [master];
GO

IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = N''' + @TargetDatabase + N''' AND [state_desc] = N''RESTORING'') BEGIN
	RESTORE DATABASE [' + @TargetDatabase + N'] WITH RECOVERY' + ISNULL(@Directives, N'') + N';
END;
GO

ALTER DATABASE [' + @TargetDatabase + N'] SET COMPATIBILITY_LEVEL = ' + @TargetCompatLevel + N'; 
GO

ALTER DATABASE [' + @TargetDatabase + N'] SET MULTI_USER;
GO

ALTER AUTHORIZATION ON DATABASE::[' + @TargetDatabase + N'] TO sa;
GO

IF EXISTS (SELECT NULL FROM sys.databases WHERE [name] = N''' + @TargetDatabase + ''' AND [target_recovery_time_in_seconds] = 0) BEGIN 
	ALTER DATABASE [' + @TargetDatabase + N'] SET TARGET_RECOVERY_TIME = 60 SECONDS;
END;
GO

ALTER DATABASE [' + @TargetDatabase + N'] SET PAGE_VERIFY CHECKSUM;
GO
';

	IF @EnableADR = 1 BEGIN 
		PRINT '
ALTER DATABASE [' + @TargetDatabase + N'] SET ACCELERATED_DATABASE_RECOVERY = ON;
GO
'
	END;

	IF @CheckSanityMarker = 1 BEGIN
		PRINT N'
------------------------------------------------------------------------
-- Check for Sanity Table:
SELECT * FROM [' + @TargetDatabase + N']..[___migrationMarker];
GO 		
';

	END;

	IF @CheckForOrphans = 1 BEGIN 

		PRINT N'------------------------------------------------------------------------
-- Check for Orphans: 
EXEC admindb.dbo.list_orphaned_users 
	@TargetDatabases = N''' + @TargetDatabase + N''', 
	@ExcludedUsers = N''' + @IgnoredOrphans + N''';
GO
';

	END; 

	IF @UpdateStatistics = 1 BEGIN 

		PRINT N'------------------------------------------------------------------------
EXEC [' + @TargetDatabase + N']..sp_updatestats;
GO

';

	END;

	PRINT N'------------------------------------------------------------------------
-- TODO: Kick off FULL backups, enable jobs, etc. 

';

	IF @CheckSanityMarker = 1 BEGIN

		PRINT N'------------------------------------------------------------------------
-- DROP Sanity Marker Table: 
USE [' + @TargetDatabase + N'];
GO

IF OBJECT_ID(N''dbo.[___migrationMarker]'', N''U'') IS NOT NULL BEGIN
	DROP TABLE dbo.[___migrationMarker];
END;
';

	END;

	RETURN 0;
GO