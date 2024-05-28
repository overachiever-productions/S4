/*
	

*/

USE [admindb];
GO 

IF EXISTS (SELECT NULL FROM sys.key_constraints WHERE [parent_object_id] = OBJECT_ID(N'dbo.eventstore_extractions', N'U') AND [name] = N'PK_xestore_extractions') BEGIN 
	EXEC sys.sp_rename 
		@objname = N'dbo.eventstore_extractions.PK_xestore_extractions', 
		@newname = N'PK_eventstore_extractions';
END;

IF OBJECT_ID(N'dbo.eventstore_extractions', N'U') IS NULL BEGIN 
	CREATE TABLE dbo.eventstore_extractions ( 
		extraction_id int IDENTITY(1,1) NOT NULL, 
		session_name sysname NOT NULL, 
		cet datetime2 NOT NULL, 
		lset datetime2 NULL, 
		row_count int NOT NULL CONSTRAINT DF_eventstore_extractions_row_count DEFAULT(0),
		attributes nvarchar(300) NULL, 
		error nvarchar(MAX) NULL
		CONSTRAINT PK_eventstore_extractions PRIMARY KEY NONCLUSTERED (extraction_id)
	)
	WITH (DATA_COMPRESSION = PAGE);

	CREATE CLUSTERED INDEX CLIX_xestore_extractions_ByTraceAndLSET ON dbo.[eventstore_extractions] ([session_name], [extraction_id] DESC);
END;
GO