/*

	NOTES:


*/

USE [admindb];
GO

	-- {copyright}

IF OBJECT_ID(N'dbo.[eventstore_report_preferences]', N'U') IS NULL BEGIN
	CREATE TABLE dbo.[eventstore_report_preferences] (
		[preference_id] int IDENTITY(1,1) NOT NULL, 
		[eventstore_key] sysname NOT NULL,			-- TODO: add an FK to/against dbo.eventstore_settings.event_store_key
		[report_type] sysname NOT NULL,				-- TODO: add a check for IN ('ERRORS', 'COUNT', 'CHRONOLOGY', 'PROBLEMS')
		[setting_key] sysname NOT NULL, 
		[setting_value] nvarchar(MAX) NOT NULL
	)
	WITH (DATA_COMPRESSION = PAGE);
END; 
GO 

-- Some SAMPLE preferences: 
INSERT INTO dbo.[eventstore_report_preferences] ([eventstore_key], [report_type], [setting_key], [setting_value])
VALUES 
	(N'ALL_ERRORS', N'COUNT', N'START_OFFSET_HOUR', N'48 hours'),		-- DATEADD(HOUR, -48, GETUTCDATE())
	(N'ALL_ERRORS', N'COUNT', N'START_OFFSET_MINUTE', N'2 hours'),		-- DATEADD(HOUR, -2, GETUTCDATE())
	(N'ALL_ERRORS', N'COUNT', N'START_OFFSET_DAY', N'8 days'),			-- DATEADD(DAY, -8, GETUTCDATE())
	(N'ALL_ERRORS', N'COUNT', N'TIME_ZONE', N'{SERVERL_LOCAL}');

INSERT INTO dbo.[eventstore_report_preferences] ([eventstore_key], [report_type], [setting_key], [setting_value])
VALUES 
	(N'ALL_ERRORS', N'COUNT', '@MinimumSeverity', N'16'),
	(N'ALL_ERRORS', N'COUNT', '@ErrorIds', N'-{REPLICATION_ERRORS},-{STATS_UPDATE_NOISE}');
GO