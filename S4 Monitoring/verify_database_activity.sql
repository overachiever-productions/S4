


EXEC dbo.verify_database_activity
    @DatabasesToProcess = N'Billing2', -- nvarchar(max)
   -- @DatabasesToExclude = N'%migration%,master,model,msdb,mask%,ssd%,licensing,%compress%,acesvc,admindb', -- nvarchar(max)
    --@BackupDirectory = N'D:\SQLBackups', -- nvarchar(2000)
    @ValidationQuery = N'SELECT MAX(EntryDate) FROM {0}.dbo.Entries;';
	--, -- nvarchar(max)
    --@VectorTime = '2018-01-02 23:43:22', -- datetime
    --@SendNotifications = NULL, -- bit
    --@ThresholdMinutes = 0, -- int
    --@OperatorName = NULL, -- sysname
    --@MailProfileName = NULL, -- sysname
    --@EmailSubjectPrefix = N'', -- nvarchar(50)
    --@PrintOnly = NULL -- bit

	



/*

PICKUP/NEXT:
	- look at options/ways to run modifications against dbo.load_database_names to SEE if there's a good/better way to run 'VERIFY' mode operations - i.e., i'd like that to throw an error if 
		a) any db specified for review is NOT a valid/present db... or b) i was going to say: "the inverse of that" but i don't think that's an actual concern. 
			that said. this sproc is handling that contingency well enough for now. 
			AND, i think that to DO IT RIGHT, dbo.load_database_names would need to provide and fill an @Error ... OUTPUT parameter... to track details like exceptions if/when as needed. 
				(then, tweak the code in 'callers' to throw execptions/errors if/when that's NOT NULL - and so on). 

	- implement the validation/checkup logic
		with the 'option' of setting @vectorFromTime = ISNULL(@VectorTime, GETDATE()) or whatever ... so that this option is fully supported. 
			
			spit out any results/reports or errors... 
			
	- test/validate that things are working as expected. 

	- look at ways to either 
		a) serialize the outpus/results (for use by dbo.restore_databases)
			OR 
		b) 'core' this logic into a UDF or some other sproc (sproc won't really work because of the nested INSERTs - so... the UDF i guess)
			and see if that can't be the focus of something that both THIS sproc and dbo.restore_databases pull from... 


-------------------------------------------



		NOTE to MIKEY:
			- when i (mikey) was creating this... i had two ideas/goals i was kind of shooting for:
				a) let this thing be used as PART of the backup RESTORE-TESTING process - i.e., use this to zip in and see how stale/recent the data is/was. 
				b) let this be used for things OUTSIDE of that... i.e., do NOT couple it 'super hard' to restore-testing ONLY. 

				all of which made sense in terms of the parameters and options I specified for declaration (like @databasesToExclude and other stuff)... 
				BUT
					while this script WILL work just fine for restored dbs that STAY IN PLACE, it will _NOT_ work for dbs that are restored, DBCC'd, and then dropped in one set of related actions	
							because I can't very well: a) restore the db, b) dbcc it, c) drop it, d) move on to the next db and do the same and, e) do that across the board... and then, 
								n) run this sproc against all restored databases - as that'd just be dumb. well. there'd be no databases to check. 


						BUT
							a) i still _REALLY_ want to keep this decoupled from restore testing. because there are things other than restore testing that can/will benefit from this. 
								specifically, the ability to test RPOs after a disaster - i.e., restore all dbs... then run this pig and see where we're at... that's a BIG deal. 

							b) i can still 'incorporate' this into the restore testing process - by means of ... some new/additional/OPTIONAL parameters in dbo.restore_databases such as:
								- @ValidationQuery and @ThresholdMinutes... 
									with the idea/convention being that IF those are both specified, then it's a GIVEN that we send alerts to the end-user and such... 
										and, ideally, that we ... somehow output the results of this sproc (i.e., a query) into a #tempTable to use for 'buffering' the outputs in the test, and then sending if/when needed. 

Fodder
	this might make sense ... @PerformExtendedStalenessChecks or something similar. as the way to specify the verification option or not... but... i'll still need a verification query and threshold, so ... maybe jsut those two params INSTEAD.

					Ugh... except i'll likely have to SERIALIZE the output - which will be a pain.
						ALMOST wonder if there's a way to 
							a) wrap the call/logic for a single execution (against a specified db) into a small/single spro (or, ideally, tv udf)
								and leave the alerting and other crap OUT of that core logic... 

							b) then for restore_databases... wrap in calls to that to ... call the light-weight logic as needed and
								for verify_database_activity, just wrap calls into that the same way... but 'bundle' and then process (for alerts/etc.) the outputs and so on... ?

							that MIGHT really be worthy of a refactor / rewrite once I get the INITIAL version of this running (and ready to integrate into dbo.restore_databases). 
								also? 
									what about dbo.restore_and_verify_databases?
										i.e., 'sub-class' things? 
										hmmm... yeah. no. too complex i'm guessing. 



*/

USE [admindb];
GO


IF OBJECT_ID('dbo.verify_database_activity','P') IS NOT NULL
	DROP PROC dbo.verify_database_activity;
GO

CREATE PROC dbo.verify_database_activity 
	@DatabasesToProcess					nvarchar(MAX),
	@DatabasesToExclude					nvarchar(MAX) = NULL,										-- only allowed if/when using [READ_FROM_FILESYSTEM]
	@BackupDirectory					nvarchar(2000) = NULL,										-- only allowed if/when using [READ_FROM_FILESYSTEM]
	@ValidationQuery					nvarchar(MAX), 
	@VectorTime							datetime = NULL,											-- defaults to GETDATE() but allows for EXPLICITLY defined times. 
	@SendNotifications					bit	= 0,
	@ThresholdMinutes					int = 20,				
	@OperatorName						sysname = N'Alerts',
	@MailProfileName					sysname = N'General',
	@EmailSubjectPrefix					nvarchar(50) = N'[Activity Validations ] ',	
	@PrintOnly							bit = 0														-- do i really want this? think i do... but... not sure. 
AS 
	SET NOCOUNT ON; 

	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	IF OBJECT_ID('dbo.split_string', 'TF') IS NULL BEGIN
		RAISERROR('S4 Table-Valued Function dbo.split_string not defined - unable to continue.', 16, 1);
		RETURN -1;
	END

	IF OBJECT_ID('dbo.load_database_names', 'P') IS NULL BEGIN
		RAISERROR('S4 Stored Procedure dbo.load_database_names not defined - unable to continue.', 16, 1);
		RETURN -1;
	END;

	DECLARE @Edition sysname;
	SELECT @Edition = CASE SERVERPROPERTY('EngineEdition')
		WHEN 2 THEN 'STANDARD'
		WHEN 3 THEN 'ENTERPRISE'
		WHEN 4 THEN 'EXPRESS'
		ELSE NULL
	END;

	IF @Edition = N'STANDARD' OR @Edition IS NULL BEGIN
		-- check for Web:
		IF @@VERSION LIKE '%web%' SET @Edition = 'WEB';
	END;
	
	IF @Edition IS NULL BEGIN
		RAISERROR('Unsupported SQL Server Edition detected. This script is only supported on Express, Web, Standard, and Enterprise (including Evaluation and Developer) Editions.', 16, 1);
		RETURN -2;
	END;

	IF EXISTS (SELECT NULL FROM sys.configurations WHERE name = 'xp_cmdshell' AND value_in_use = 0) BEGIN
		RAISERROR('xp_cmdshell is not currently enabled.', 16,1);
		RETURN -3;
	END;

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF (@SendNotifications = 1) BEGIN
		IF (@PrintOnly = 0) AND (@Edition != 'EXPRESS') BEGIN -- we just need to check email info, anything else can be logged and then an email can be sent (unless we're debugging). 

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
	END;

	IF UPPER(@DatabasesToProcess) = N'[READ_FROM_FILESYSTEM]' BEGIN
		IF NULLIF(@BackupDirectory, N'') IS NULL BEGIN
			RAISERROR('@BackupsDirectory cannot be NULL and must be a valid path.', 16, 1);
			RETURN -6;
		END;

-- TODO: verify that the directory exists: 
-- which also means... need to ... ensure a dependency upon dbo.check_paths. (and xp_cmdshell, no?)
			--EXEC dbo.check_paths @BackupsRootPath, @isValid OUTPUT;
			--IF @isValid = 0 BEGIN;
			--	SET @earlyTermination = N'@BackupsRootPath (' + @BackupsRootPath + N') is invalid - restore operations terminated prematurely.';
			--	GOTO FINALIZE;
			--END

	  END;
	ELSE BEGIN -- not reading from the file system:

		IF NULLIF(@BackupDirectory,'') IS NOT NULL BEGIN
			RAISERROR('@BackupsDirectory may NOT be specified unless @DatabasesToProcess is set as ''[READ_FROM_FILESYSTEM]''.', 16, 1);
			RETURN -7;
		END;

		IF NULLIF(@DatabasesToExclude,'') IS NOT NULL BEGIN
			RAISERROR('@DatabasesToExclude may NOT be specified unless @DatabasesToProcess is set as ''[READ_FROM_FILESYSTEM]''.', 16, 1);
			RETURN -7;
		END
	END;

	IF NULLIF(@ValidationQuery,'') IS NULL BEGIN
		RAISERROR('@ValidationQuery must be a valid T-SQL query that can be run against all databases specified.', 16, 1);
		RETURN -8;
	END

	-----------------------------------------------------------------------------
	-- Load databases to process: 
	DECLARE @serialized nvarchar(MAX);
	EXEC dbo.load_database_names
	    @Input = @DatabasesToProcess,         
	    @Exclusions = @DatabasesToExclude,		-- only works if [READ_FROM_FILESYSTEM] is specified for @Input... 
	    @Mode = N'RESTORE',
	    @TargetDirectory = @BackupDirectory, 
		@Output = @serialized OUTPUT;

	DECLARE @dbsToProcess table (
        [entry_id] int IDENTITY(1,1) NOT NULL, 
        [database_name] sysname NOT NULL
    ); 

	INSERT INTO @dbsToProcess ([database_name])
	SELECT [result] FROM dbo.split_string(@serialized, N',');

	IF (SELECT COUNT(*) FROM @dbsToProcess) <= 0 BEGIN
		RAISERROR('No databases were found that match @DatabasesProcess (and/or any possible exclusions). Execution is terminating.', 16, 1);
		RETURN -20;
	END;
	
	-----------------------------------------------------------------------------
	-- spin up container for output results, and begin processing: 

	CREATE TABLE #verificationResults (
		verification_id int IDENTITY(1,1) NOT NULL, 
		verification_database sysname NOT NULL, 
		executed_query nvarchar(MAX) NOT NULL, -- i dunno... but yeah, seems like i need it. 
		execution_outcome sysname NOT NULL,  -- success or 'some sort of error'. 
		execution_error nvarchar(MAX) NULL, 
		execution_output datetime NULL
	);

	DECLARE @currentDbName sysname; 
	DECLARE @executionOutcome sysname;
	DECLARE @executionError nvarchar(MAX);
	DECLARE @executionOutput datetime; 
	DECLARE @command nvarchar(MAX);
	DECLARE @changed bit;


	DECLARE @holder table ( 
		[database_name] sysname NULL, 
		result datetime NULL, 
		error nvarchar(MAX)
	);

	DECLARE looper CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[database_name]
	FROM 
		@dbsToProcess
	ORDER BY 
		entry_id;

	OPEN looper;

	FETCH NEXT FROM looper INTO @currentDbName;

	WHILE @@FETCH_STATUS = 0 BEGIN
		
		SET @executionOutcome = NULL;
		SET @executionError = NULL;
		SET @executionOutput = NULL;
		SET @changed = 0;

		DELETE FROM @holder;

		BEGIN TRY

			SET @command = REPLACE(@ValidationQuery, '{0}', @currentDbName); 
			
			IF @command != @ValidationQuery
				SET @changed = 1;	
			
			IF NOT EXISTS (SELECT NULL FROM sys.databases WHERE name = @currentDbName) BEGIN
					INSERT INTO @holder ([database_name],error)
					VALUES  (@currentDbName, N'Specified Database Name ([' + @currentDbName + N']) is NOT valid or currently present on the server.');
			   END;
			ELSE BEGIN

				INSERT INTO @holder (result)
				EXEC sp_executesql @command;

				UPDATE @holder 
				SET 
					[database_name] = CASE WHEN @changed = 1 THEN @currentDbName ELSE (SELECT DB_NAME()) END;
			END;

		END TRY 
		BEGIN CATCH
			SELECT @executionError = N'Unexepected Error: ' + CAST(ERROR_NUMBER() AS nvarchar(30)) + N' - ' + ERROR_MESSAGE() + N'.';

			DELETE FROM @holder;

			INSERT INTO @holder ([database_name], error)
			VALUES (@currentDbName, @executionError);
		END CATCH
		
		INSERT INTO #verificationResults (verification_database, executed_query, execution_outcome, execution_error, execution_output)
		SELECT 
			@currentDbName,
			@command, 
			CASE 
				WHEN error IS NOT NULL THEN '<ERROR>' 
				ELSE 'SUCCESS'
			END, 
			error, 
			[result]
		FROM 
			@holder;

		FETCH NEXT FROM looper INTO @currentDbName;
	END;

	CLOSE looper;
	DEALLOCATE looper;


	SELECT * FROM #verificationResults;