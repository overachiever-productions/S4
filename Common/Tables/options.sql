USE [admindb];
GO

IF OBJECT_ID(N'dbo.[options]', N'U') IS NULL BEGIN

	CREATE TABLE dbo.[options] (
		[option_id] int IDENTITY(1,1) NOT NULL,
		[module] sysname NOT NULL, 
		[key] sysname NOT NULL, 
		[value] sysname NOT NULL, 
		[summary] nvarchar(1024) NULL,   -- for documentation - i.e., overview of a bit more info on what param is and ... WHY it exists, how it's used/etc. 
		[example] nvarchar(1024) NULL,  --  e.g., `@options = N'CACHE_DURATION:45'` ... etc. 
		[notes] nvarchar(1024) NULL,		-- for use by local DBAs or to keep LOCAL/environment-level notes on current settings. 
		CONSTRAINT [pk_options] PRIMARY KEY NONCLUSTERED ([option_id])
	); 

	CREATE CLUSTERED INDEX [clix_options_by_module_and_key] ON dbo.options ([module], [key]) WITH (DATA_COMPRESSION = PAGE);
	
END;

-- SEE: https://overachieverllc.atlassian.net/browse/S4-944