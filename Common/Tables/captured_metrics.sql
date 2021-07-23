/*

	TODO: 
		- Look at using data-compression for this table... 
		- specifically: 
			it's currently ENABLED... 
			but not sure that it's really helping at all. 






*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.captured_metrics', N'U') IS NULL BEGIN 

	CREATE TABLE dbo.captured_metrics (
		[metrics_id] int IDENTITY(1,1) NOT NULL, 
		[captured] datetime NOT NULL CONSTRAINT DF_captured_metrics_captured DEFAULT (GETDATE()), 
		[workload_group_stats] nvarchar(MAX) NULL, 
		[pool_stats] nvarchar(MAX) NULL, 
		[cpu_stats] nvarchar(MAX) NOT NULL, 
		[perf_counters] nvarchar(MAX) NOT NULL, 
		[wait_stats] nvarchar(MAX) NOT NULL,
		[batch_stats] nvarchar(MAX) NOT NULL, 
		CONSTRAINT PK_captured_metrics PRIMARY KEY NONCLUSTERED ([metrics_id]) /* --2019 only: WITH (OPTIMIZE_FOR_SEQUENTIAL_KEY = ON) */
	)
	WITH (DATA_COMPRESSION = PAGE)

END;
GO