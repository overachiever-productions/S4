USE [admindb];
GO

IF OBJECT_ID(N'dbo.[alert_states]', N'U') IS NULL BEGIN

	CREATE TABLE dbo.[alert_states] (
		[state_id] int IDENTITY(1,1) NOT NULL,
		[alert_type] sysname NOT NULL, 
		[start] datetime NOT NULL,
		[end] datetime NULL,
		CONSTRAINT [pk_alert_states] PRIMARY KEY NONCLUSTERED ([state_id])
	); 

	CREATE CLUSTERED INDEX [clix_alert_states_by_type] ON dbo.[alert_states]([alert_type], [start])
		WITH (DATA_COMPRESSION = PAGE);
END;
GO