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
	@WarnWhenFreeGBsGoBelow				decimal(12,1)		= 22.0,				-- 
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

	DECLARE @core table (
		drive sysname NOT NULL, 
		available_gbs decimal(14,2) NOT NULL
	);

	INSERT INTO @core (drive, available_gbs)
	SELECT DISTINCT
		s.volume_mount_point [drive],
		CAST(s.available_bytes / 1073741824 as decimal(24,2)) [available_gbs]
	FROM 
		sys.master_files f
		CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) s;

	DECLARE @crlf char(2) = CHAR(13) + CHAR(10);
	DECLARE @tab char(1) = CHAR(9);
	DECLARE @message nvarchar(MAX) = N'';

	-- Start with the C:\ drive if it's present (i.e., has dbs on it - which is a 'worst practice'):
	SELECT 
		@message = @message + @tab + drive + N' -> ' + CAST(available_gbs AS nvarchar(20)) +  N' GB free (vs. threshold of ' + CAST((CASE WHEN @HalveThresholdAgainstCDrive = 1 THEN @WarnWhenFreeGBsGoBelow / 2 ELSE @WarnWhenFreeGBsGoBelow END) AS nvarchar(20)) + N' GB) '  + @crlf
	FROM 
		@core
	WHERE 
		UPPER(drive) = N'C:\' AND 
		CASE 
			WHEN @HalveThresholdAgainstCDrive = 1 THEN @WarnWhenFreeGBsGoBelow / 2 
			ELSE @WarnWhenFreeGBsGoBelow
		END > available_gbs;

	-- Now process all other drives: 
	SELECT 
		@message = @message + @tab + drive + N' -> ' + CAST(available_gbs AS nvarchar(20)) +  N' GB free (vs. threshold of ' + CAST(@WarnWhenFreeGBsGoBelow AS nvarchar(20)) + N' GB) '  + @crlf
	FROM 
		@core
	WHERE 
		UPPER(drive) <> N'C:\'
		AND @WarnWhenFreeGBsGoBelow > available_gbs;

	IF LEN(@message) > 3 BEGIN 

		DECLARE @subject nvarchar(200) = ISNULL(@EmailSubjectPrefix, N'') + N'Low Disk Notification';

		SET @message = N'The following disks on ' + QUOTENAME(@@SERVERNAME) + ' have dropped below specified thresholds for Free Space (GBs) Specified: ' + @crlf + @crlf + @message;

		IF @PrintOnly = 1 BEGIN 
			PRINT @subject;
			PRINT @message;
		  END;
		ELSE BEGIN 

			EXEC msdb..sp_notify_operator
				@profile_name = @MailProfileName,
				@name = @OperatorName, -- operator name
				@subject = @subject, 
				@body = @message;			
		END; 
	END; 


	RETURN 0;
GO