/*
	TODO:
		- Look at moving these details into a server_configuration table
			where I can use KVPs... with keys as simple 'handles' and the values as JSON strings... 
				i.e., TraceFlags -> {json details here }

				well. problem with that is... that's going to be harder to deal with in non 2016 instances - so ... maybe not. 

	
	DEPENDENCIES:
		- Mirroring or AvailabilityGroups (in most cases) be set-up/configured. However, this may be used to check on differences between any two servers, provided they're configured as 'PARTNER' servers. 
		- Full usage of this table requires a PARTNER linked-server to be created. 

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple

	NOTES:
		- This table exists to get 'around' the problem/issue that there's no way to 'query' TraceFlags without executing DBCC TRACESTATUS() - which, when being called from 
			a remote server, requires RPC permissions. So, instead of enabling RPC/RPC-out on PARTNER servers, each server (when it runs the first part of dba_ServerSyncChecks) will
			run DBCC TRACESTATUS() locally, and 'dump' the results into this file, so that the PRIMARY server (when it keeps checking), will be able to query these 'cached' values
			instead of having to try and wrap a 'dynamic' call into DBCC TRACESTATUS() (which would require RPC permissions). 
*/


USE [admindb];
GO

IF OBJECT_ID('dbo.server_trace_flags','U') IS NOT NULL
	DROP TABLE dbo.server_trace_flags;
GO

CREATE TABLE dbo.server_trace_flags (
	[trace_flag] [int] NOT NULL,
	[status] [bit] NOT NULL,
	[global] [bit] NOT NULL,
	[session] [bit] NOT NULL,
	CONSTRAINT [PK_server_traceflags] PRIMARY KEY CLUSTERED ([trace_flag] ASC)
) 
ON [PRIMARY];

GO