/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_ple_thresholds','P') IS NOT NULL
	DROP PROC dbo.[verify_ple_thresholds];
GO

CREATE PROC dbo.[verify_ple_thresholds]
	@LowPleTheshold						int					= 1000,
	@JobsToIgnoreLowPLEsFrom			nvarchar(MAX)		= NULL,
	@OperatorName						sysname				= N'Alerts',
	@MailProfileName					sysname				= N'General',
	@EmailSubjectPrefix					nvarchar(50)		= N'[PLE Checks] ', 
	@PrintOnly							bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	SET @LowPleTheshold = ISNULL(@LowPleTheshold, 1000);
	SET @JobsToIgnoreLowPLEsFrom = NULLIF(@JobsToIgnoreLowPLEsFrom, N'');
	SET @EmailSubjectPrefix = ISNULL(NULLIF(@EmailSubjectPrefix, N''), N'[PLE Checks] ');

	IF @LowPleTheshold < 100 BEGIN 
		RAISERROR(N'@LowPleTheshold values must be > 100.', 16, 1);
		RETURN -1;
	END;
	
	---------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int, @returnMessage nvarchar(MAX);
    IF @PrintOnly = 0 BEGIN 

	    EXEC @return = dbo.verify_advanced_capabilities;
        IF @return <> 0
            RETURN @return;

        EXEC @return = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @return <> 0 
            RETURN @return;
    END;

    ----------------------------------------------
	-- Determine the last time this job ran: 
    DECLARE @now datetime = GETDATE();
	DECLARE @lastCheckupExecutionTime datetime;
    EXEC [dbo].[get_last_job_completion_by_session_id] 
        @SessionID = @@SPID, 
        @ExcludeFailures = 1, 
        @LastTime = @lastCheckupExecutionTime OUTPUT; 

	SET @lastCheckupExecutionTime = ISNULL(@lastCheckupExecutionTime, DATEADD(MINUTE, -20, GETDATE()));

    IF DATEDIFF(MINUTE, @lastCheckupExecutionTime, GETDATE()) > 20
        SET @lastCheckupExecutionTime = DATEADD(MINUTE, -20, GETDATE())

    DECLARE @syncCheckSpanMinutes int = DATEDIFF(MINUTE, @lastCheckupExecutionTime, GETDATE());

    IF @syncCheckSpanMinutes <= 1 
        RETURN 0; -- no sense checking on history if it's just been a minute... 

	----------------------------------------------
	-- Get current PLE values:
	DECLARE @currentPLEs bigint; 
	SELECT @currentPLEs = cntr_value 
	FROM sys.[dm_os_performance_counters] 
	WHERE [object_name] = N'SQLServer:Buffer Manager' -- vNEXT: name-change for named instances... 
	AND [counter_name] = N'Page life expectancy';

	IF @currentPLEs > @LowPleTheshold BEGIN -- There's nothing to report - i.e., everything is peachy... 
		RETURN 0;
	END;

	-- otherwise, if we're still here... check to see if the low PLEs are due to a job that we know about and want to ignore low PLEs from (e.g., DBCC CHECKDB() or something similar).
	IF @JobsToIgnoreLowPLEsFrom IS NOT NULL BEGIN 

		CREATE TABLE #running_jobs (
			row_id int IDENTITY(1,1) NOT NULL, 
			job_name sysname NOT NULL, 
			start_time datetime NULL, 
			end_time datetime NULL, 
			[status] sysname NULL 
		);

		-- and get a list of jobs running in the last N minutes: 
		DECLARE @runningJobs xml;
		EXEC dbo.[list_running_jobs]
			@StartTime = @lastCheckupExecutionTime,
			@EndTime = @now,
			@SerializedOutput = @runningJobs OUTPUT;

			WITH shredded AS (
				SELECT 
					[data].[row].value(N'job_name[1]', N'sysname') job_name, 
					[data].[row].value(N'start_time[1]', N'datetime') start_time, 
					[data].[row].value(N'end_time[1]', N'datetime') end_time, 
					[data].[row].value(N'job_status[1]', N'sysname') job_status 			
				FROM 
					@runningJobs.nodes(N'//job') [data]([row])
			)

			INSERT INTO [#running_jobs] (
				[job_name],
				[start_time],
				[end_time],
				[status]
			)
			SELECT 
				[job_name], 
				[start_time], 
				[end_time], 
				[job_status]
			FROM 
				[shredded];

		DELETE FROM [#running_jobs] WHERE [job_name] NOT IN (SELECT [result] FROM dbo.[split_string](@JobsToIgnoreLowPLEsFrom, N',', 1));

		IF EXISTS (SELECT NULL FROM [#running_jobs]) BEGIN  -- PLEs are below specified threshold, but an 'ugly' job (we've configured to 'ignore crapply PLEs from' has been running within the last N minutes, so ... nothing to report.
			RETURN 0;
		END;

	END;
	
	-- if we're still here, PLEs are below thresholds:
	DECLARE @subject sysname;
	DECLARE @message nvarchar(MAX);

	SET @subject = @EmailSubjectPrefix + N' - PLEs are currently at ' + CAST(@currentPLEs AS sysname) + N' and below specified threshold value of ' + CAST(@LowPleTheshold AS sysname) + N'.';
	SET @message = N'Last/Previous PLE check was ' + CAST(@syncCheckSpanMinutes AS sysname) + N' minutes ago. PLEs are currently at ' + CAST(@currentPLEs AS sysname) + N'. Threshold is set at ' + CAST(@LowPleTheshold AS sysname) + N'.';

	IF @PrintOnly = 1 BEGIN 
		PRINT @subject;
		PRINT @message;
	  END;
	ELSE BEGIN 
		EXEC msdb..sp_notify_operator
			@profile_name = @MailProfileName,
			@name = @OperatorName, -- operator name
			@subject = @subject, 
			@body = @message;
	END;

	RETURN 0;
GO