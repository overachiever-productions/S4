/*


*/

--USE [admindb];
--GO

--IF OBJECT_ID('dbo.list_trace_flags','P') IS NOT NULL
--	DROP PROC dbo.[list_trace_flags];
--GO
/*
	CONVENTIONS:
		- INTERNAL

	NOTES:
		- code is pretty obvious - but it's CALLED from it's partner via EXEC [PARTNER].admindb.dbo.populate_trace_flags;
			so that dbo.server_trace_flags is up-to-date/recently-populated.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.populate_trace_flags','P') IS NOT NULL
	DROP PROC dbo.[populate_trace_flags];
GO

CREATE PROC dbo.[populate_trace_flags]

AS
    SET NOCOUNT ON; 

    -- {copyright}

	TRUNCATE TABLE dbo.[server_trace_flags];

	INSERT INTO dbo.[server_trace_flags] (
		[trace_flag],
		[status],
		[global],
		[session]
	)
	EXECUTE ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

	RETURN 0;
GO