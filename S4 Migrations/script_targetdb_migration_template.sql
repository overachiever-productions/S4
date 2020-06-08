/*

	vNEXT: 
		address CDC, TRUSTWORTHY, REPL, BROKER, and other directives. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.script_targetdb_migration_template','P') IS NOT NULL
	DROP PROC dbo.[script_targetdb_migration_template];
GO

CREATE PROC dbo.[script_targetdb_migration_template]
	@TargetDatabase					sysname				= NULL, 
	@TargetCompatLevel				sysname				= N'{LATEST}',			-- { {LATEST} | 150 | 140 | 130 | 120 } 
	@CheckSanityMarker				bit					= 1, 
	--@EnableBroker					sysname				= NULL, -- ' ... steps/modes to enable broker here - and integrate those into RECOVERY... 
	@UpdateStatistics				bit					= 1, 
	@CheckForOrphans				bit					= 1
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDatabase = NULLIF(@TargetDatabase, N'');
	SET @TargetCompatLevel = ISNULL(NULLIF(@TargetCompatLevel, N''), N'{LATEST}');

	SET @UpdateStatistics = ISNULL(@UpdateStatistics, 1);
	SET @CheckForOrphans = ISNULL(@CheckForOrphans, 1);

	IF @TargetDatabase IS NULL BEGIN 
		RAISERROR(N'@TargetDatabase cannot be NULL or empty.', 16, 1);
		RETURN -2;
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
	RESTORE DATABASE [' + @TargetDatabase + N'] WITH RECOVERY;
END;
GO


ALTER DATABASE [' + @TargetDatabase + N'] SET COMPATIBILITY_LEVEL = ' + @TargetCompatLevel + N'; 
GO

ALTER DATABASE [' + @TargetDatabase + N'] SET MULTI_USER;
GO

ALTER AUTHORIZATION ON DATABASE::[' + @TargetDatabase + N'] TO sa;
GO

ALTER DATABASE [' + @TargetDatabase + N'] SET PAGE_VERIFY CHECKSUM;
GO

------------------------------------------------------------------------
-- NOTE/TODO: 
--		Address CDC, REPL, BROKER, TRUSTWORTHY and any other directives necessary. (NOTE THAT SOME OF THESE SHOULD BE ADDRESSED during RECOVERY process... 

';


	IF @CheckForOrphans = 1 BEGIN 

		PRINT N'------------------------------------------------------------------------
-- Check for Orphans: 
EXEC [' + @TargetDatabase + N']..sp_change_users_login ''Report'';
GO

';

	END; 


	IF @UpdateStatistics = 1 BEGIN 

		PRINT N'------------------------------------------------------------------------
EXEC [<target, sysname, dbNameHere>]..sp_updatestats;
GO

';

	END;

	PRINT N'------------------------------------------------------------------------
-- TODO: Kick off FULL backups, enable jobs, etc. 

';

	RETURN 0;
GO