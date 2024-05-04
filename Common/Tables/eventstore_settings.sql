USE [admindb];
GO 

IF OBJECT_ID(N'dbo.[eventstore_settings]', N'U') IS NULL BEGIN 

	CREATE TABLE [dbo].[eventstore_settings] (
		[setting_id] int IDENTITY(1, 1) NOT NULL,
		[event_store_key] sysname NOT NULL,
		[session_name] sysname NOT NULL,
		[etl_proc_name] sysname NOT NULL,
		[target_table] sysname NOT NULL,
		[collection_enabled] bit NOT NULL,
		[etl_enabled] bit NOT NULL,
		[etl_frequency_minutes] smallint NOT NULL,
		[retention_days] smallint NOT NULL,
		[created] datetime CONSTRAINT [DF_eventstore_settings_created] DEFAULT (GETDATE()),
		[notes] nvarchar(MAX) NULL, 
		CONSTRAINT PK_eventstore_settings PRIMARY KEY CLUSTERED  ([event_store_key])
	);
END;
GO