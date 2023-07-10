/*

	

*/

USE [admindb];
GO 

IF OBJECT_ID(N'dbo.xestore_extractions', N'U') IS NULL BEGIN 
	CREATE TABLE dbo.xestore_extractions ( 
		extraction_id int IDENTITY(1,1) NOT NULL, 
		session_name sysname NOT NULL, 
		cet datetime2 NOT NULL, 
		lset datetime2 NULL, 
		attributes sysname NULL, 
		CONSTRAINT PK_xestore_extractions PRIMARY KEY NONCLUSTERED (extraction_id)
	);

	CREATE CLUSTERED INDEX CLIX_xestore_extractions_ByTraceAndLSET ON dbo.[xestore_extractions] ([session_name], [extraction_id] DESC);

END;
GO