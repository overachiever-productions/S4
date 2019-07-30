/*
	TODO:
		- verify that @OperatorName and @MailProfileName are legit... 


	DEPENDENCIES
		- Mirrored or AG'd databases.
		- SQL Server Agent Jobs must adhere to convention of:
			- mirrored/AG'd databases must have job category set to [dbname] (i.e., if we've got a 'Widgets' database that is mirrored/AG'd, the Job Category for this job needs to be (a custom job categorgy called) 'Widgets'. 
			Or
			- a (custom job category called) 'Disabled' if/when the job needs to be disabled. 
	
	NOTES:
		- The Primary in a Mirrored environment is a 'PRINCIPAL'. But in an AG environment, it's the 'PRIMARY'.
		- This job disables/enables JOBs where:
			a) the Job's Category Name = NameOfDbThatIsInMirroringOrAGTopology
			and
			b) the Job's status is set to enabled when it should be disabled or disabled when it should be enabled. 

			It will NOT address or touch jobs whose Job Category Name is set to 'Disabled'. 
			Nor will it enable/disable jobs whose Job Category Names do NOT match the name of a Mirrored or AG'd database. 


*/
USE [admindb];
GO

IF OBJECT_ID('dbo.verify_job_states','P') IS NOT NULL
	DROP PROC dbo.verify_job_states;
GO

CREATE PROC dbo.verify_job_states 
	@SendChangeNotifications	bit = 1,
	@MailProfileName			sysname = N'General',
	@OperatorName				sysname	= N'Alerts', 
	@EmailSubjectPrefix			sysname = N'[SQL Agent Jobs-State Updates]',
	@PrintOnly					bit	= 0
AS 
	SET NOCOUNT ON;

	-- {copyright}

	IF @PrintOnly = 0 BEGIN -- if we're not running a 'manual' execution - make sure we have all parameters:
		-- Operator Checks:
		IF ISNULL(@OperatorName, '') IS NULL BEGIN
			RAISERROR('An Operator is not specified - error details can''t be sent if/when encountered.', 16, 1);
			RETURN -4;
		 END;
		ELSE BEGIN
			IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysoperators WHERE [name] = @OperatorName) BEGIN
				RAISERROR('Invalid Operator Name Specified.', 16, 1);
				RETURN -4;
			END;
		END;

		-- Profile Checks:
		DECLARE @DatabaseMailProfile nvarchar(255);
		EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'DatabaseMailProfile', @param = @DatabaseMailProfile OUT, @no_output = N'no_output';
 
		IF @DatabaseMailProfile != @MailProfileName BEGIN
			RAISERROR('Specified Mail Profile is invalid or Database Mail is not enabled.', 16, 1);
			RETURN -5;
		END; 
	END;

	DECLARE @errorMessage nvarchar(MAX) = N'';
	DECLARE @jobsStatus nvarchar(MAX) = N'';

	-- Start by querying for list of mirrored then AG'd database to process:
	DECLARE @targetDatabases table (
		[db_name] sysname NOT NULL, 
		[role] sysname NOT NULL, 
		[state] sysname NOT NULL, 
		[owner] sysname NULL
	);

	INSERT INTO @targetDatabases ([db_name], [role], [state], [owner])
	SELECT 
		d.[name] [db_name],
		dm.mirroring_role_desc [role], 
		dm.mirroring_state_desc [state], 
		sp.[name] [owner]
	FROM 
		sys.database_mirroring dm
		INNER JOIN sys.databases d ON dm.database_id = d.database_id
		LEFT OUTER JOIN sys.server_principals sp ON sp.sid = d.owner_sid
	WHERE 
		dm.mirroring_guid IS NOT NULL;

	INSERT INTO @targetDatabases ([db_name], [role], [state], [owner])
	SELECT 
		dbcs.[database_name] [db_name],
		ISNULL(arstates.role_desc,'UNKNOWN') [role],
		ISNULL(dbrs.synchronization_state_desc, 'UNKNOWN') [state],
		x.[owner]
	FROM 
		master.sys.availability_groups AS ag
		LEFT OUTER JOIN master.sys.dm_hadr_availability_group_states AS agstates ON ag.group_id = agstates.group_id
		INNER JOIN master.sys.availability_replicas AS ar ON ag.group_id = ar.group_id
		INNER JOIN master.sys.dm_hadr_availability_replica_states AS arstates ON ar.replica_id = arstates.replica_id AND arstates.is_local = 1
		INNER JOIN master.sys.dm_hadr_database_replica_cluster_states AS dbcs ON arstates.replica_id = dbcs.replica_id
		LEFT OUTER JOIN master.sys.dm_hadr_database_replica_states AS dbrs ON dbcs.replica_id = dbrs.replica_id AND dbcs.group_database_id = dbrs.group_database_id
		LEFT OUTER JOIN (SELECT d.name, sp.name [owner] FROM master.sys.databases d INNER JOIN master.sys.server_principals sp ON d.owner_sid = sp.sid) x ON x.name = dbcs.database_name;

	DECLARE @currentDatabase sysname, @currentRole sysname, @currentState sysname; 
	DECLARE @enabledOrDisabled bit; 
	DECLARE @countOfJobsToModify int;

	DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
	DECLARE @tab nchar(1) = CHAR(9);

	DECLARE processor CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[db_name], 
		[role],
		[state]
	FROM 
		@targetDatabases
	ORDER BY 
		[db_name];

	OPEN processor;
	FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;

	WHILE @@FETCH_STATUS = 0 BEGIN;

		SET @enabledOrDisabled = 0; -- default to disabled. 

		-- if the db is synchronized/synchronizing AND PRIMARY, then enable jobs:
		IF (@currentRole IN (N'PRINCIPAL',N'PRIMARY')) AND (@currentState IN ('SYNCHRONIZED','SYNCHRONIZING')) BEGIN
			SET @enabledOrDisabled = 1;
		END;

		-- determine if there are any jobs OUT of sync with their expected settings:
		SELECT @countOfJobsToModify = ISNULL((
				SELECT COUNT(*) FROM msdb.dbo.sysjobs sj INNER JOIN msdb.dbo.syscategories sc ON sj.category_id = sc.category_id WHERE LOWER(sc.name) = LOWER(@currentDatabase) AND sj.enabled != @enabledOrDisabled 
			), 0);

		IF @countOfJobsToModify > 0 BEGIN;

			BEGIN TRY 
				DECLARE toggler CURSOR LOCAL FAST_FORWARD FOR 
				SELECT 
					sj.job_id, sj.name
				FROM 
					msdb.dbo.sysjobs sj
					INNER JOIN msdb.dbo.syscategories sc ON sc.category_id = sj.category_id
				WHERE 
					LOWER(sc.name) = LOWER(@currentDatabase)
					AND sj.[enabled] <> @enabledOrDisabled;

				DECLARE @jobid uniqueidentifier; 
				DECLARE @jobname sysname;

				OPEN toggler; 
				FETCH NEXT FROM toggler INTO @jobid, @jobname;

				WHILE @@FETCH_STATUS = 0 BEGIN 
		
					IF @PrintOnly = 1 BEGIN 
						PRINT '-- EXEC msdb.dbo.sp_updatejob @job_name = ''' + @jobname + ''', @enabled = ' + CAST(@enabledOrDisabled AS varchar(1)) + ';'
					  END
					ELSE BEGIN
						EXEC msdb.dbo.sp_update_job
							@job_id = @jobid, 
							@enabled = @enabledOrDisabled;
					END

					SET @jobsStatus = @jobsStatus + @tab + N'- [' + ISNULL(@jobname, N'#ERROR#') + N'] to ' + CASE WHEN @enabledOrDisabled = 1 THEN N'ENABLED' ELSE N'DISABLED' END + N'.' + @crlf;

					FETCH NEXT FROM toggler INTO @jobid, @jobname;
				END 

				CLOSE toggler;
				DEALLOCATE toggler;

			END TRY 
			BEGIN CATCH 
				SELECT @errorMessage = @errorMessage + N'ERROR while attempting to set Jobs to ' + CASE WHEN @enabledOrDisabled = 1 THEN N' ENABLED ' ELSE N' DISABLED ' END + N'. [ Error: ' + CAST(ERROR_NUMBER() AS nvarchar(20)) + N' -> ' + ERROR_MESSAGE() + N']';
			END CATCH
		
			-- cleanup cursor if it didn't get closed:
			IF (SELECT CURSOR_STATUS('local','toggler')) > -1 BEGIN;
				CLOSE toggler;
				DEALLOCATE toggler;
			END
		END

		FETCH NEXT FROM processor INTO @currentDatabase, @currentRole, @currentState;
	END

	CLOSE processor;
	DEALLOCATE processor;

	IF (SELECT CURSOR_STATUS('local','processor')) > -1 BEGIN;
		CLOSE processor;
		DEALLOCATE processor;
	END

	IF (@jobsStatus <> N'') AND (@SendChangeNotifications = 1) BEGIN;

		DECLARE @serverName sysname;
		SELECT @serverName = @@SERVERNAME; 

		SET @jobsStatus = N'The following changes were made to SQL Server Agent Jobs on ' + @serverName + ':' + @crlf + @jobsStatus;

		IF @errorMessage <> N'' 
			SET @jobsStatus = @jobsStatus + @crlf + @crlf + N'The following Error Details were also encountered: ' + @crlf + @tab + @errorMessage;

		DECLARE @emailSubject nvarchar(2000) = @EmailSubjectPrefix + N' Change Report for ' + @serverName;

		IF @PrintOnly = 1 BEGIN 
			PRINT @emailSubject;
			PRINT @jobsStatus;

		  END
		ELSE BEGIN 
			EXEC msdb.dbo.sp_notify_operator 
				@profile_name = @MailProfileName,
				@name = @OperatorName, 
				@subject = @emailSubject, 
				@body = @jobsStatus;
		END
	END

	RETURN 0;

GO