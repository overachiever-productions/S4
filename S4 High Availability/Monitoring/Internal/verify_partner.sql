/*
	PURPOSE: 
		- wrapper for checking to ensure that a linked server (i.e., PARTNER) is actually up/accessible. 

	NOTES:
		- Justification: 
			a. This SHOULD work: sp_testlinkedserver - but it doesn't, because the (level 16) exceptions it throws can NOT be CAUGHT in a TRY/CATCH. 
			b. Even trying OPENQUERY() ... and even doing it 'dynamically', still causes an un-catchable exception when PARTNER is down/gone/inaccessible. 
				See: https://dba.stackexchange.com/questions/36178/linked-server-error-not-caught-by-try-catch
				
			And, so, simply trying to run a 'remote' sproc via dynamic execution - with error handling is/was the solution (meaning that dbo.execute_command)
				was the response. 

			NOTE:
				Calling dbo.verify_online (which does ABSOLUTELY NOTHING and PROJECTS nothing as output (other than "commands completed successfully."))
					as this is easier than trying to run some sort of SELECT or anything else where I'd have to filter 'succes'/output against what
					things would look like IF there were an error. 




	CONVENTIONS:
		- INTERNAL
		- PROJECT OR RETURN

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.verify_partner','P') IS NOT NULL
	DROP PROC dbo.[verify_partner];
GO

CREATE PROC dbo.[verify_partner]
	@Error				nvarchar(MAX)			= N''			OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	DECLARE @return int;
	DECLARE @output nvarchar(MAX);

	DECLARE @partnerTest nvarchar(MAX) = N'EXEC [PARTNER].admindb.dbo.verify_online;'

	DECLARE @results xml;
	EXEC @return = admindb.dbo.[execute_command]
		@Command = @partnerTest,
		@ExecutionType = N'SQLCMD',
		@ExecutionAttemptsCount = 0,
		@IgnoredResults = N'[COMMAND_SUCCESS]',
		@Outcome = @results OUTPUT;

	IF @return <> 0 BEGIN 
		SELECT @output = dbo.[translate_executed_command_error](@results);
	END;

	IF @output IS NOT NULL BEGIN
		IF @Error IS NULL 
			SET @Error = @output; 
		ELSE 
			SELECT @output [Error];
	END;

	RETURN @return;
GO