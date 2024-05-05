/*
	vNEXT: 
		add @profile and @operator for alerts. 
		and ... figure out a way to send (periodic) alerts for anything that has failed N times back to back (by virtue of LSET not being set each time we run). 
			though, again: periodic reminders - maybe 1x/hour then 1x/day or whatever... i.e., need to tie this into new alerting approach.

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_etl_processor]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_etl_processor];
GO

CREATE PROC dbo.[eventstore_etl_processor]

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Get Sessions to Process:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	WITH core AS ( 
		SELECT 
			[session_name],
			[etl_proc_name],
			[target_table],
			[etl_enabled],
			[etl_frequency_minutes],
			ISNULL((SELECT MAX([e].[lset]) FROM [dbo].[eventstore_extractions] [e] WHERE [e].[session_name] = [s].[session_name]), DATEADD(MINUTE, 0 - 12, GETUTCDATE())) [lset]
		FROM 
			dbo.[eventstore_settings] [s]
		WHERE 
			[etl_enabled] = 1 
	) 

	SELECT 
		[session_name],
		[etl_proc_name],
		[target_table],
		[etl_enabled],
		[etl_frequency_minutes],
		[lset]
	INTO 
		#sessions_to_process
	FROM 
		core 
	WHERE 
		DATEDIFF(MINUTE, [lset], GETUTCDATE()) > [etl_frequency_minutes]
	ORDER BY
		[etl_frequency_minutes];

	IF NOT EXISTS (SELECT NULL FROM [#sessions_to_process]) BEGIN 
		RETURN 0; -- nothing to process. 
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- AND execute each etl that needs to be handled.
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @sprocToExecute sysname;
	
	DECLARE @sessionName sysname, @etlName sysname, @targetTableName sysname;
	DECLARE [cursorName] CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[session_name],
		[etl_proc_name],
		[target_table]
	FROM 
		[#sessions_to_process] 
	ORDER BY 
		[etl_frequency_minutes];
	
	OPEN [cursorName];
	FETCH NEXT FROM [cursorName] INTO @sessionName, @etlName, @targetTableName;
	
	WHILE @@FETCH_STATUS = 0 BEGIN
	
		SET @sprocToExecute = @etlName; 

		EXEC @sprocToExecute 
			@SessionName = @sessionName, 
			@EventStoreTarget = @targetTableName;
	
		-- vNEXT: check for LSET by session_name... as a form of error handling/reporting.

		FETCH NEXT FROM [cursorName] INTO @sessionName, @etlName, @targetTableName;
	END;
	
	CLOSE [cursorName];
	DEALLOCATE [cursorName];

	RETURN 0;
GO