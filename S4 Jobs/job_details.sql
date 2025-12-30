/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[job_details]','P') IS NOT NULL
	DROP PROC dbo.[job_details];
GO

CREATE PROC dbo.[job_details]
	@job_id						uniqueidentifier, 
	@job_name					sysname, 
	@mode						sysname					= N'LAST'
AS
    SET NOCOUNT ON; 

	-- {copyright}

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @job_name = NULLIF(@job_name, N'');
	SET @mode = ISNULL(NULLIF(@mode, N''), N'LAST');

	IF @job_id IS NULL AND @job_name IS NULL BEGIN 
		RAISERROR(N'Please specify inputs for either @job_id OR @job_name.', 16, 1);
		RETURN -1;
	END;

	IF @job_name IS NOT NULL BEGIN
		SELECT @job_id = job_id FROM msdb..[sysjobs] WHERE [name] = @job_name
	END;

	SELECT @job_id = job_id FROM [msdb]..[sysjobs] WHERE [job_id] = @job_id;

	IF @job_id IS NULL BEGIN 
		DECLARE @detailString sysname;
		IF @job_name IS NOT NULL 
			SET @detailString = N'@job_name = N''' + @job_name + N'''.';
		ELSE 
			SET @detailString = N'@job_id ''' + CAST(@job_id AS sysname) + N'''.';

		RAISERROR(N'Could not find job matching input %s', 16, 1, @detailString);
		RETURN -10;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Processing Logic:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/

	SELECT 
		[step_id],
		[step_name]
	INTO 
		#jobSteps
	FROM 
		msdb..[sysjobsteps]
	WHERE 
		[job_id] = @job_id
	ORDER BY 
		[step_id];

	SELECT 
		[job_name],
		[step_id],
		[step_name],
		[run_time],
		[weekday],
		[run_seconds],
		[run_status],
		[sql_message_id],
		[sql_severity],
		[message]
	FROM 
		dbo.[job_histories]() 
	WHERE 
		job_name = @job_name;




	
	