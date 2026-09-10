USE [admindb];
GO 

IF OBJECT_ID(N'dbo.[alert_state_details]', N'U') IS NULL BEGIN
	CREATE TABLE dbo.[alert_state_details] (
		[state_id] int NOT NULL,
		[timestamp] datetime NOT NULL DEFAULT GETDATE(),
		[summary] sysname NOT NULL, 	
		[detail] xml NOT NULL, 
		CONSTRAINT pk_alert_state_details PRIMARY KEY CLUSTERED ([state_id], [timestamp] DESC) 
			WITH (DATA_COMPRESSION = PAGE)
	);
END;
GO