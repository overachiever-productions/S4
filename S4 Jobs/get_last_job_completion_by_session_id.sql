/*

    DRY wrapper for calls into dbo.get_last_job_completion by sproc/code working INSIDE of SQL Server Agent Jobs 
        i.e., they send in their SPID ... instead of having to extract their own program name, then pass it off
        to dbo.get_last_job_completion, etc. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_last_job_completion_by_session_id','P') IS NOT NULL
	DROP PROC dbo.[get_last_job_completion_by_session_id];
GO

CREATE PROC dbo.[get_last_job_completion_by_session_id]
    @SessionID              int,
    @ExcludeFailures        bit                             = 1, 
    @LastTime               datetime                        = '1900-01-01 00:00:00.000' OUTPUT
AS
    SET NOCOUNT ON; 

    -- {copyright}

    DECLARE @success int = -1;
    DECLARE @jobName sysname; 
    DECLARE @lastExecution datetime;
    DECLARE @output datetime;

    DECLARE @programName sysname; 
    SELECT @programName = [program_name] FROM sys.[dm_exec_sessions] WHERE [session_id] = @SessionID;

    EXEC @success = dbo.translate_program_name_to_agent_job 
        @ProgramName = @programName, 
        @JobName = @jobName OUTPUT;

    IF @success = 0 BEGIN 
        EXEC @success = dbo.[get_last_job_completion]
            @JobName = @jobName, 
            @ReportJobStartOrEndTime = N'START', 
            @ExcludeFailedOutcomes = 1, 
            @LastTime = @lastExecution OUTPUT;

        IF @success = 0 
            SET @output = @lastExecution;
    END; 

    IF @output IS NULL 
        RETURN -1; 

    IF @LastTime IS NOT NULL 
        SELECT @output [completion_time_of_last_job_execution];
    ELSE 
        SET @LastTime = @output;

    RETURN 0;
GO