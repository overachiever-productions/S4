/*

    RATIONALE: 
        - Using Aaron Bertrand's sp_foreachdb along with @command = 'DBCC CHECKDB(?) WITH NO_INFOMSGS, ALL_ERRORMSGS;' ... works DAMNED well. 
        - Only, while Aaron makes it possible to specify exclusions and so on, S4 MIGHT AS WELL 'standardize' 
            on the the ability to specify targets, exclusions, and priorities. 
        - FURTHER, by 'shelling out', S4 can CAPTURE detailed specifics about ANY errors and email/send those to admins (whereas that's not possible otherwise).


	vNEXT: 
		- Consolidate @Targets and @Exclusions down to @Databases. 
		
	BUG?: 
		- Looks like it's trying to actually run checks against [USER] and ... not getting an ERROR? i.e., the list of dbs to execute example is ... doing some odd stuff. 
		-	(I'm assuming the above goes away once @Targets and @Exclusions is consolidated.)


	SIGNATURE / TESTS: 

		-- Expect exception (i.e., a queued email) (unless db piggly-wiggly exists): 

				EXEC dbo.check_database_consistency 
					@Targets = N'pigglywiggly'; 


		-- Expect success (cough, unless... corruption!):

				EXEC dbo.check_database_consistency 
					@Targets = N'admindb'; 			


				EXEC dbo.check_database_consistency
					@Targets = N'Billing_corrupt';

		-- Expect list of dbs/commands to execute against: 

				EXEC dbo.check_database_consistency 
					@Targets = N'[USER], admindb', 
					@Exclusions = N'GPS, %exym%, %3%', 
					@Priorities= N'admindb, *', 
					@PrintOnly = 1;


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.check_database_consistency','P') IS NOT NULL
	DROP PROC dbo.[check_database_consistency];
GO

CREATE PROC dbo.[check_database_consistency]
	@Targets								nvarchar(MAX)	                        = N'{ALL}',		-- {ALL} | {SYSTEM} | {USER} | comma,delimited,list, of, databases, where, spaces, do,not,matter
	@Exclusions								nvarchar(MAX)	                        = NULL,			-- comma, delimited, list, of, db, names, %wildcards_allowed%
	@Priorities								nvarchar(MAX)	                        = NULL,			-- higher,priority,dbs,*,lower,priority, dbs  (where * is an ALPHABETIZED list of all dbs that don't match a priority (positive or negative)). If * is NOT specified, the following is assumed: high, priority, dbs, [*]
	@IncludeExtendedLogicalChecks           bit                                     = 0,
	@MaxDOP									int										= 1,
    @OperatorName						    sysname									= N'Alerts',
	@MailProfileName					    sysname									= N'General',
	@EmailSubjectPrefix					    nvarchar(50)							= N'[Database Corruption Checks] ',	
    @PrintOnly                              bit                                     = 0
AS
    SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
    IF @PrintOnly = 0 BEGIN 
        DECLARE @check int;

	    EXEC @check = dbo.verify_advanced_capabilities;
        IF @check <> 0
            RETURN @check;

        EXEC @check = dbo.verify_alerting_configuration
            @OperatorName, 
            @MailProfileName;

        IF @check <> 0 
            RETURN @check;
    END;

    DECLARE @DatabasesToCheck table ( 
        row_id int IDENTITY(1,1) NOT NULL,
        [database_name] sysname NOT NULL
    ); 

    INSERT INTO @DatabasesToCheck (
        [database_name]
    )
    EXEC dbo.[list_databases]
        @Targets = @Targets,
        @Exclusions = @Exclusions,
        @Priorities = @Priorities,
        @ExcludeClones = 1,
        @ExcludeSecondaries = 1,
        @ExcludeSimpleRecovery = 0,
        @ExcludeReadOnly = 0,
        @ExcludeRestoring = 1,
        @ExcludeRecovering = 1,
        @ExcludeOffline = 1;
    
    DECLARE @errorMessage nvarchar(MAX); 
	DECLARE @errors table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[results] xml NOT NULL, 
		[error_message] nvarchar(MAX) NULL
	);

	DECLARE @executionId uniqueidentifier = NEWID(), @executionDate date = GETDATE(), @startTime datetime, @succeeded bit;
	
	DECLARE @currentDbName sysname; 
    DECLARE @sql nvarchar(MAX);
    DECLARE @template nvarchar(MAX) = N'DBCC CHECKDB([{DbName}]) WITH NO_INFOMSGS, ALL_ERRORMSGS{ExtendedChecks}{DOP};';
	
	DECLARE @result int;
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @exceptionDetails nvarchar(MAX);

    IF @IncludeExtendedLogicalChecks = 1 
        SET @template = REPLACE(@template, N'{ExtendedChecks}', N', EXTENDED_LOGICAL_CHECKS');
    ELSE 
        SET @template = REPLACE(@template, N'{ExtendedChecks}', N'');

	IF @MaxDOP > 1 BEGIN 
		SET @template = REPLACE(@template, N'{DOP}', N', MAXDOP = ' + CAST(@MaxDOP AS sysname));	
	  END;
	ELSE BEGIN 
		SET @template = REPLACE(@template, N'{DOP}', N'');
	END;

	DECLARE @outcome xml;
    DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
    SELECT 
        [database_name]
    FROM 
        @DatabasesToCheck
    ORDER BY 
        [row_id];

    OPEN [walker]; 
    FETCH NEXT FROM [walker] INTO @currentDbName;

    WHILE @@FETCH_STATUS = 0 BEGIN 
		
		SET @startTime = GETDATE();

		SET @sql = REPLACE(@template, N'{DbName}', @currentDbName);
		SET @result = 0;
		SET @errorMessage = NULL; 
		SET @exceptionDetails = NULL;

		BEGIN TRY
			EXEC @result = dbo.[execute_command]
				@Command = @sql,
				@ExecutionType = N'SQLCMD',
				@ExecutionAttemptsCount = 1,
				@DelayBetweenAttempts = NULL,
				@IgnoredResults = N'{COMMAND_SUCCESS}',
				@PrintOnly = @PrintOnly,
				@Outcome = @outcome OUTPUT, 
				@ErrorMessage = @errorMessage OUTPUT;
		END TRY
		BEGIN CATCH
			SELECT 
				@exceptionDetails = N'EXCEPTION: ' + @crlf + N'Msg ' + CAST(ERROR_NUMBER() AS sysname) + N', Line ' + CAST(ERROR_LINE() AS sysname) + @crlf + ERROR_MESSAGE();
			
			IF @@TRANCOUNT > 0 
				ROLLBACK;			

			SET @result = ISNULL(NULLIF(@result, 0), -999);
			SET @errorMessage = ISNULL(@errorMessage, N'') + N' ' + @exceptionDetails;
		END CATCH;

		IF @result <> 0 BEGIN 
			SET @succeeded = 0;

			INSERT INTO @errors (
				[database_name],
				[results], 
				[error_message]
			)
			VALUES (
				@currentDbName, 
				@outcome,
				@errorMessage
			);
		  END;
		ELSE 
			SET @succeeded = 1;

		INSERT INTO [dbo].[corruption_check_history] (
			[execution_id],
			[execution_date],
			[database],
			[dop],
			[check_start],
			[check_end],
			[check_succeeded],
			[results],
			[errors]
		)
		VALUES (
			@executionId,
			@executionDate, 
			@currentDbName,
			@MaxDOP,
			@startTime,
			GETDATE(),
			@succeeded,
			@outcome,
			@errorMessage
		);

        FETCH NEXT FROM [walker] INTO @currentDbName;    
    END;

    CLOSE [walker];
    DEALLOCATE [walker];

	DECLARE @emailBody nvarchar(MAX);
	DECLARE @emailSubject nvarchar(300);

	IF EXISTS (SELECT NULL FROM @errors) BEGIN 
		DECLARE @tab nchar(1) = NCHAR(9);

		SET @emailSubject = ISNULL(@EmailSubjectPrefix, N'') + ' DATABASE CONSISTENCY CHECK ERRORS';
		SET @emailBody = N'The following problems were encountered: ' + @crlf; 

		SELECT 
			@emailBody = @emailBody + N'------------------------------------------------' + @crlf + N'DATABASE:' + @crlf + @tab + UPPER([database_name]) + @crlf + N'ERRORS: ' + @crlf + @tab + [error_message] + @crlf + N'XML EXECUTION DETAILS: ' + @crlf + @tab + CAST([results] AS nvarchar(MAX)) + @crlf + @crlf
		FROM 
			@errors 
		ORDER BY 
			[row_id];
	END;

	IF @emailBody IS NOT NULL BEGIN 

        EXEC msdb..sp_notify_operator
            @profile_name = @MailProfileName,
            @name = @OperatorName,
            @subject = @emailSubject, 
            @body = @emailBody;
	END; 
	
	RETURN 0;
GO