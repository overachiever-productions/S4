/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.





	EXAMPLE SIGNATURES: 

				-- Interactive/Normal execution (i.e., PROJECT):
						EXEC [admindb].dbo.list_cpu_history;


				-- RETURN via @SearializedOUtput:
						DECLARE @output xml;
						EXEC [admindb].dbo.list_cpu_history
							@SerializedOutput = @output OUTPUT;

						SELECT @output;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.list_cpu_history','P') IS NOT NULL
	DROP PROC dbo.[list_cpu_history];
GO

CREATE PROC dbo.[list_cpu_history]
	@LastNMinutesOnly					int				= 256,				-- default to max allowable
	@SerializedOutput					xml				= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @LastNMinutesOnly = ISNULL(@LastNMinutesOnly, 256); 

	IF @LastNMinutesOnly > 256 OR @LastNMinutesOnly < 1 BEGIN 
		RAISERROR('@LastNMinutesOnly must be >= 1 minute and < 256 minutes. Leave NULL for default of 256 minutes.', 16, 1);
		RETURN -1;
	END;

	-- https://troubleshootingsql.com/2009/12/30/how-to-find-out-the-cpu-usage-information-for-the-sql-server-process-using-ring-buffers/
	DECLARE @ticksSinceServerStart bigint = (SELECT [cpu_ticks] / ([cpu_ticks] / [ms_ticks]) FROM [sys].[dm_os_sys_info] WITH (NOLOCK));
	DECLARE @now datetime = GETDATE();

	WITH core AS ( 
		SELECT TOP(@LastNMinutesOnly) 
			[timestamp], 
			CAST([record] AS xml) [record]
		FROM 
			sys.[dm_os_ring_buffers] WITH(NOLOCK)
		WHERE 
			[ring_buffer_type] = N'RING_BUFFER_SCHEDULER_MONITOR'
		ORDER BY 
			[timestamp] DESC

	), 
	extracted AS ( 
		SELECT 
			DATEADD(MILLISECOND, -1 * (@ticksSinceServerStart - [timestamp]), @now) [timestamp],
			[record].value(N'(./Record/@id)[1]', N'int') [record_id],
			[record].value(N'(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', N'int') [system_idle],
			[record].value(N'(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', N'int') [sql_usage]
		FROM 
			core
	)
		
	SELECT 
		DATEADD(MINUTE, DATEDIFF(MINUTE, 0, [timestamp]), 0) [timestamp],
		[record_id],
		[system_idle],
		[sql_usage]
	INTO 
		[#raw_results]
	FROM 
		[extracted];

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY... 

		SELECT @SerializedOutput = (
		SELECT 
			[timestamp],
			[sql_usage] [sql_cpu_usage],
			100 - [sql_usage] - [system_idle] [other_process_usage],
			[system_idle]
		FROM 
			[#raw_results] 
		ORDER BY 
			[record_id]
		FOR XML PATH('entry'), ROOT('history'));
		
		RETURN 0;
	END;

    -- otherwise (if we're still here) ... PROJECT:
	SELECT 
		[timestamp],
		[sql_usage] [sql_cpu_usage],
		N'' [ ],
		100 - [sql_usage] - [system_idle] [other_process_usage],
		[system_idle]
	FROM 
		[#raw_results] 
	WHERE 
		[sql_usage] IS NOT NULL -- hack
	ORDER BY 
		[timestamp] DESC;

	RETURN 0;
GO