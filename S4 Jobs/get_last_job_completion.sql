/*
    NOTE: 
        - returns the latest _COMPLETION_ time. 
            IF a job is currently RUNNING (i.e., in the process of running and has NOT yet completed), then the current 'run' is 100% ignored by DESIGN. 


    
    SAMPLES/TESTS: 

        
        -- expect exception (needed params not defined);
                EXEC admindb.dbo.get_last_job_completion;
        
        
        -- expect exception (cuz of bogus jobs name): 
                EXEC admindb.dbo.get_last_job_completion
                    @JobName = N'Piggly Wiggly Job';


        -- expect start time of last execution (failed or succeeded - doesn't matter): 
                EXEC admindb.dbo.get_last_job_completion
                    @JobName = N'User Databases.FULL Backups';


        -- expect end/completion time of last SUCCESSFUL (only) execution: 
                EXEC admindb.dbo.get_last_job_completion
                    @JobName = N'User Databases.FULL Backups', 
                    @ReportJobStartOrEndTime = N'END', 
                    @ExcludeFailedOutcomes = 1;

        -- expect output via parameter: 
                DECLARE @output datetime;
                EXEC admindb.dbo.get_last_job_completion
                    @JobName = N'User Databases.FULL Backups', 
                    @ReportJobStartOrEndTime = N'END', 
                    @ExcludeFailedOutcomes = 1,
                    @LastTime = @output OUTPUT;

                SELECT @output;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_last_job_completion','P') IS NOT NULL
	DROP PROC dbo.[get_last_job_completion];
GO

CREATE PROC dbo.[get_last_job_completion]
    @JobName                                            sysname                 = NULL, 
    @JobID                                              uniqueidentifier        = NULL, 
    @ReportJobStartOrEndTime                            sysname                 = N'START',                                 -- Report Last Completed Job START or END time.. 
    @ExcludeFailedOutcomes                              bit                     = 0,                                        -- when true, only reports on last-SUCCESSFUL execution.
    @LastTime                                           datetime                = '1900-01-01 00:00:00.000' OUTPUT
AS
    SET NOCOUNT ON; 
    
	-- {copyright}

    IF NULLIF(@JobName, N'') IS NULL AND @JobID IS NULL BEGIN 
        RAISERROR(N'Please specify either the @JobName or @JobID parameter to execute.', 16, 1);
        RETURN -1;
    END;

    IF UPPER(@ReportJobStartOrEndTime) NOT IN (N'START', N'END') BEGIN 
        RAISERROR('Valid values for @ReportJobStartOrEndTime are { START | END } only.', 16,1);
        RETURN -2;
    END;

    IF @JobID IS NULL BEGIN 
        SELECT @JobID = job_id FROM msdb..sysjobs WHERE [name] = @JobName;
    END;

    IF @JobName IS NULL BEGIN 
        RAISERROR(N'Invalid (non-existing) @JobID or @JobName provided.', 16, 1);
        RETURN -5;
    END;

    DECLARE @startTime datetime;
    DECLARE @duration sysname;
    
    SELECT 
        @startTime = msdb.dbo.agent_datetime(run_date, run_time), 
        @duration = RIGHT((REPLICATE(N'0', 6) + CAST([run_duration] AS sysname)), 6)
    FROM [msdb]..[sysjobhistory] 
    WHERE 
        [instance_id] = (

            SELECT MAX(instance_id) 
            FROM msdb..[sysjobhistory] 
            WHERE 
                [job_id] = @JobID 
                AND (
                        (@ExcludeFailedOutcomes = 0) 
                        OR 
                        (@ExcludeFailedOutcomes = 1 AND [run_status] = 1)
                    )
        );

    IF UPPER(@ReportJobStartOrEndTime) = N'START' BEGIN 
        IF @LastTime IS NOT NULL  -- i.e., parameter was NOT supplied because it's defaulted to 1900... 
            SELECT @startTime [start_time_of_last_successful_job_execution];
        ELSE 
            SET @LastTime = @startTime;

        RETURN 0;
    END; 
    
    -- otherwise, report on the end-time: 
    DECLARE @endTime datetime = DATEADD(SECOND, CAST((LEFT(@duration, 2)) AS int) * 3600 + CAST((SUBSTRING(@duration, 3, 2)) AS int) * 60 + CAST((RIGHT(@duration, 2)) AS int), @startTime); 

    IF @LastTime IS NOT NULL
        SELECT @endTime [completion_time_of_last_job_execution];
    ELSE 
        SET @LastTime = @endTime;

    RETURN 0;
GO    