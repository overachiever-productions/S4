/*

	NOTE:
		- SQL Server 2008 R2 and above. (Won't work on SQL Server 2008.)

	TODO:
		- POSSIBLY look at putting in dynamic processing to handle 2008 vs 2008 R2+


	SIGNATURE: 

			EXEC admindb.dbo.verify_drivespace 
				@WarnWhenFreeGBsGoBelow	= 22.5, 
				@PrintOnly = 1;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_drivespace','P') IS NOT NULL
	DROP PROC dbo.verify_drivespace;
GO

CREATE PROC dbo.verify_drivespace 
	@WarnWhenFreeGBsGoBelow				decimal(12,1)		= NULL,				-- 
	@WarnWhenUsageExceedsPercentage		decimal(4,2)		= NULL,
	@HalveThresholdAgainstCDrive		bit					= 0,				-- In RARE cases where some (piddly) dbs are on the C:\ drive, and there's not much space on the C:\ drive overall, it can make sense to treat the C:\ drive's available space as .5x what we'd see on a 'normal' drive.
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[DriveSpace Checks] ', 
	@PrintOnly							bit					= 0
AS
	SET NOCOUNT ON;

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	SET @OperatorName = ISNULL(NULLIF(@OperatorName, N''), N'Alerts');
	SET @MailProfileName = ISNULL(NULLIF(@MailProfileName, N''), N'General');
	SET @EmailSubjectPrefix = ISNULL(NULLIF(@EmailSubjectPrefix, N''), N'[DriveSpace Checks] ');

	IF @WarnWhenFreeGBsGoBelow IS NOT NULL AND @WarnWhenUsageExceedsPercentage IS NOT NULL BEGIN 
		RAISERROR(N'Values can NOT be specified for BOTH @WarnWhenFreeGBsGoBelow and @WarnWhenUsageExceedsPercentage. Specify one or the other.', 16, 1);
		RETURN -1;
	END;

	IF @WarnWhenUsageExceedsPercentage IS NULL AND @WarnWhenFreeGBsGoBelow IS NULL BEGIN 
		RAISERROR(N'A value MUST be specified for EITHER @WarnWhenFreeGBsGoBelow or @WarnWhenUsageExceedsPercentage.', 16, 1);
		RETURN -1;
	END;

	-- Operator Checks:
	IF ISNULL(@OperatorName, '') IS NULL BEGIN
		RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
		RETURN -4;
		END;
	ELSE BEGIN
		IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
			RAISERROR('Invalild Operator Name Specified.', 16, 1);
			RETURN -4;
		END;
	END;

	-- Profile Checks:
	DECLARE @DatabaseMailProfile nvarchar(255);
	EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
	IF @DatabaseMailProfile != @MailProfileName BEGIN
		RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
		RETURN -5;
	END;

	DECLARE @GBsOrPercentages sysname = 'GBs';
	IF @WarnWhenUsageExceedsPercentage IS NOT NULL SET @GBsOrPercentages = 'Percentage';
	DECLARE @core table (
		drive sysname NOT NULL, 
		available_gbs decimal(14,2) NOT NULL, 
		total_gbs decimal(14,2) NOT NULL, 
		[%_used] decimal(5,2) NOT NULL
	);

	WITH gbs AS ( 
		SELECT DISTINCT
			s.volume_mount_point [drive],
			CAST(s.available_bytes / 1073741824 as decimal(24,2)) [available_gbs], 
			CAST(s.[total_bytes] / 1073741824 as decimal(24,2)) [total_gbs]
		FROM 
			sys.master_files f
			CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) s
	) 

	INSERT INTO @core (drive, [available_gbs], [total_gbs], [%_used])
	SELECT 
		[drive],
		[available_gbs],
		[total_gbs], 
		CAST(100.0 - ([available_gbs] / [gbs].[total_gbs] * 100.0) AS decimal(5,2)) [%_used]
	FROM 
		gbs 
	ORDER BY 
		[gbs].[drive];

	DECLARE @problems table (
		[drive] sysname NOT NULL,
		[available_gbs] decimal(14, 2) NOT NULL,
		[total_gbs] decimal(14, 2) NOT NULL,
		[%_used] decimal(5, 2) NOT NULL,
		[threshold] sysname NOT NULL
	);
	
	IF @GBsOrPercentages = N'GBs' BEGIN
		INSERT INTO @problems ([drive], [available_gbs], [total_gbs], [%_used], [threshold])
		SELECT 
			[drive],
			[available_gbs],
			[total_gbs],
			[%_used], 
			N'< ' + CAST((CASE WHEN @HalveThresholdAgainstCDrive = 1 THEN @WarnWhenFreeGBsGoBelow / 2 ELSE @WarnWhenFreeGBsGoBelow END) AS sysname) + N'GB' [threshold]
		FROM 
			@core 
		WHERE 
			UPPER(drive) = N'C:\' -- config smell. 
			AND CASE 
				WHEN @HalveThresholdAgainstCDrive = 1 THEN @WarnWhenFreeGBsGoBelow / 2 
				ELSE @WarnWhenFreeGBsGoBelow
			END > available_gbs;

		-- Now process all other drives: 
		INSERT INTO @problems ([drive], [available_gbs], [total_gbs], [%_used], [threshold])
		SELECT 
			[drive],
			[available_gbs],
			[total_gbs],
			[%_used], 
			N'< ' + CAST(@WarnWhenFreeGBsGoBelow AS sysname) + N'GB' [threshold]
		FROM 
			@core 
		WHERE 
			UPPER(drive) <> N'C:\'
			AND @WarnWhenFreeGBsGoBelow > available_gbs;
	  END; 
	ELSE BEGIN 
		INSERT INTO @problems ([drive], [available_gbs], [total_gbs], [%_used], [threshold])
		SELECT 
			[drive],
			[available_gbs],
			[total_gbs],
			[%_used], 
			N'> ' + CAST(CAST(@WarnWhenUsageExceedsPercentage AS decimal(5,2)) AS sysname) + N'%' [threshold]
		FROM 
			@core 
		WHERE 
			[%_used] > CAST(@WarnWhenUsageExceedsPercentage AS decimal(5,2));
	END;

	IF EXISTS (SELECT NULL FROM @problems) BEGIN 

		DECLARE @subject nvarchar(200) = ISNULL(@EmailSubjectPrefix, N'') + N'Low Disk Notification';
		DECLARE @warningsCount int = (SELECT COUNT(*) FROM @problems);

		DECLARE @indicators xml = N'<indicators>
		<indicator priority="1">
			<name>SERVER</name>
			<value>' + @@SERVERNAME + N'</value>
			<style>error</style>
		</indicator>
		<indicator priority="2">
			<name>Warnings Count</name>
			<value>'+ CAST(@warningsCount AS sysname) + '</value>
			<style>warning</style>
			<context>Drives with Problems</context>
		</indicator>
		<indicator priority="3">
			<name>Alert Raised</name>
			<value>' + CONVERT(sysname, GETDATE(), 8) + N'</value>
			<style>info</style>
			<context>Local Server Time</context>
		</indicator>
	</indicators>';

		DECLARE @details xml = (
			SELECT 
				[drive],
				CAST([total_gbs] AS sysname) + N'GB' [disk_size],
				CAST([available_gbs] AS sysname) + N'GB' [free_space],
				[threshold],
				CAST([%_used] AS sysname) + N'%' [used]
			FROM 
				@problems
			ORDER BY 
				[drive]
			FOR XML PATH(N'detail'), ROOT(N'details'), TYPE
		);

		IF @PrintOnly = 1 BEGIN 
			PRINT N'SUBJECT: ' + @subject; 
			PRINT N'BODY: '; 
			PRINT N'	INDICATORS: ' + dbo.[format_xml_string](@indicators);
			PRINT N'	DETAILS: ' + dbo.[format_xml_string](@details);
		  END;
		ELSE BEGIN
			DECLARE @body nvarchar(MAX);
			EXEC [dbo].[format_html_email]
				@classification = N'ALERT',
				@title = @subject,
				@execution_date = '2026-06-12 18:50:30',
				@recipients = @OperatorName,
				@indicators = @indicators,
				@details = @details,
				@output = @body OUTPUT;
		
			EXEC dbo.[notify_operator]
				@profile_name = @MailProfileName,
				@operator_name = @OperatorName,
				@subject = @subject,
				@body = @body,
				@body_format = 'HTML',
				@print_only = 0;
		END;
	END; 

	RETURN 0;
GO