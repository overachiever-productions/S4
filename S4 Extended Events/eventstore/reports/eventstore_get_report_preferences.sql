/*


		EXAMPLE: 
			DECLARE
				@PreferredTimeZone SYSNAME,
				@PreferredStartTime datetime,
				@PreferredPredicates nvarchar(MAX);

			EXEC [dbo].[eventstore_get_report_preferences]
				@EventStoreKey = N'ALL_ERRORS',
				@ReportType = N'COUNT',
				@Granularity = N'HOUR',
				@PreferredTimeZone = @PreferredTimeZone OUTPUT,
				@PreferredStartTime = @PreferredStartTime OUTPUT,
				@PreferredPredicates = @PreferredPredicates OUTPUT;


			SELECT 
				@PreferredTimeZone, @PreferredStartTime, @PreferredPredicates;

*/


USE [admindb];
GO
	
IF OBJECT_ID('dbo.[eventstore_get_report_preferences]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_get_report_preferences];
GO
	
CREATE PROC dbo.[eventstore_get_report_preferences]
	@EventStoreKey					sysname, 
	@ReportType						sysname,
	@Granularity					sysname			= NULL, 
	@PreferredTimeZone				sysname			OUTPUT, 
	@PreferredStartTime				datetime		OUTPUT, 
	@PreferredPredicates			nvarchar(MAX)	OUTPUT
AS
	SET NOCOUNT ON; 
	
	-- {copyright}
		
	SELECT 
		@PreferredTimeZone = ISNULL([setting_value], N'{SERVER_LOCAL}') 
	FROM 
		dbo.[eventstore_report_preferences] 
	WHERE 
		[eventstore_key] = @EventStoreKey 
		AND [report_type] = @ReportType
		AND [setting_key] = N'TIME_ZONE';


	DECLARE @startSetting sysname; 
	SELECT 
		@startSetting = LTRIM(RTRIM([setting_value]))
	FROM 
		[dbo].[eventstore_report_preferences] 
	WHERE 
		[eventstore_key] = @EventStoreKey 
		AND [report_type] = @ReportType
		AND [setting_key] = N'START_OFFSET' + CASE WHEN @Granularity IS NOT NULL THEN N'_' + @Granularity ELSE N'' END;

	IF @startSetting IS NOT NULL BEGIN 
		DECLARE @sql nvarchar(MAX); 	
		DECLARE @timeUnit sysname = LTRIM(RTRIM(SUBSTRING(@startSetting, CHARINDEX(N' ', @startSetting), LEN(@startSetting))));
		DECLARE @timeValue sysname = LTRIM(RTRIM(SUBSTRING(@startSetting, 0, CHARINDEX(N' ', @startSetting))));

		IF LOWER(RIGHT(@timeUnit, 1)) = N's' SET @timeUnit = LEFT(@timeUnit, LEN(@timeUnit) - 1);
		IF LEFT(@timeValue, 1) <> N'-' SET @timeValue = N'-' + @timeValue;

		SET @sql = N'SELECT @PreferredStartTime = DATEADD(' + UPPER(@timeUnit) + N', ' + @timeValue + N', GETUTCDATE());';

		BEGIN TRY 
			EXEC sys.sp_executesql 
				@sql, 
				N'@PreferredStartTime datetime OUTPUT', 
				@PreferredStartTime = @PreferredStartTime OUTPUT;
		END TRY 
		BEGIN CATCH 
			SET @PreferredStartTime = NULL;
			RAISERROR('run roh', 16, 1); 
			RETURN -10;
		END CATCH;
	END;

	SELECT 
		@PreferredPredicates = STRING_AGG([setting_key] + N':' + [setting_value], N';')
	FROM 
		[dbo].[eventstore_report_preferences] 
	WHERE 
		[eventstore_key] = @EventStoreKey 
		AND [report_type] = @ReportType
		AND [setting_key] NOT LIKE N'START_OFFSET%'
		
	RETURN 0;
GO 