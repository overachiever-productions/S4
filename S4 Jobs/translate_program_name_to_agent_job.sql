/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.

    OVERVIEW: 
        - Converts value of sys.dm_exec_sessions.program_name to a SQL Server Agent JOB NAME (assuming a valid 'program name' identifier). 


    EXAMPLES / TESTS: 
        
        -- expect error/exception: 
                EXEC admindb.dbo.translate_program_name_to_agent_job '.NET something provider app';

        -- expect PROJECTion of job-name (assuming a valid job identifier): 
                DECLARE @program_name sysname = N'SQLAgent - TSQL JobStep (Job 0x47018E68FDE2034EBB2C4E7F6F07424A : Step 1)'; -- i.e., what you'd get from sys.dm_exec_sessions.program_name
                EXEC admindb.dbo.translate_program_name_to_agent_job
                    @program_name;


        -- expect job-name + current job-step (preserved): 
                DECLARE @program_name sysname = N'SQLAgent - TSQL JobStep (Job 0x47018E68FDE2034EBB2C4E7F6F07424A : Step 1)'; -- i.e., what you'd get from sys.dm_exec_sessions.program_name
                EXEC admindb.dbo.translate_program_name_to_agent_job
                    @program_name,
                    @IncludeJobStepInOutput = 1;


        -- REPLY - with output...  
                DECLARE @program_name sysname = N'SQLAgent - TSQL JobStep (Job 0x47018E68FDE2034EBB2C4E7F6F07424A : Step 1)'; -- i.e., what you'd get from sys.dm_exec_sessions.program_name

                DECLARE @output sysname = N'';  -- can't be NULL 
                EXEC admindb.dbo.translate_program_name_to_agent_job
                    @program_name,
                    @IncludeJobStepInOutput = 1, 
                    @JobName = @output OUTPUT; 

                SELECT @output;

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_program_name_to_agent_job','P') IS NOT NULL
	DROP PROC dbo.[translate_program_name_to_agent_job];
GO

CREATE PROC dbo.[translate_program_name_to_agent_job]
    @ProgramName                    sysname, 
    @IncludeJobStepInOutput         bit         = 0, 
    @JobName                        sysname     = N''       OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

    DECLARE @jobID uniqueidentifier;

    BEGIN TRY 

        DECLARE @jobIDString sysname = SUBSTRING(@ProgramName, CHARINDEX(N'Job 0x', @ProgramName) + 4, 34);
        DECLARE @currentStepString sysname = REPLACE(REPLACE(@ProgramName, LEFT(@ProgramName, CHARINDEX(N': Step', @ProgramName) + 6), N''), N')', N''); 

        SET @jobID = CAST((CONVERT(binary(16), @jobIDString, 1)) AS uniqueidentifier);
    
    END TRY
    BEGIN CATCH
        IF NULLIF(@JobName, N'') IS NOT NULL
            RAISERROR(N'Error converting Program Name: ''%s'' to SQL Server Agent JobID (Guid).', 16, 1, @ProgramName);

        RETURN -1;
    END CATCH

    DECLARE @output sysname = (SELECT [name] FROM msdb..sysjobs WHERE [job_id] = @jobID);

    IF @IncludeJobStepInOutput = 1
        SET @output = @output + N' (Step ' + @currentStepString + N')';

    IF @JobName IS NULL
        SET @JobName = @output; 
    ELSE 
        SELECT @output [job_name];

    RETURN 0;
GO