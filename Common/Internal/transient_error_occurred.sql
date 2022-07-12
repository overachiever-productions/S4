/*

	INTERNAL

		LOGIC:
		A transient error is where something fails the first (or first N) time(s) within a call to 
			dbo.execute_command, but FINALLY completes, successfully.
		So, in this sense it's different than an ERROR. 
				An error would be a scenario where a failure occured 1 time IF the command was only allowed to run 1x, 
					and N times if the command was allowed to run N times (i.e., an ERROR fails 'every' time). Whereas, 
					a transient error is N - 1 failures (i.e., didn't fail on last attempt) WHERE N > 1 (cuz if execution tries/count
					was 1... then the command either failed or succeeded - but IF it failed, we don't KNOW if that was transient. 

		So, with the above, all we really have to do to determine if a transient error occured is: 
			- check to see if Iterations.Count > 1... the end. 
		

				DECLARE @outcome xml = N'<iterations>
					  <iteration execution_outcome="FAILED" iteration_id="1" execution_time="2021-11-02T17:00:16.920">
						<result_row result_id="1" is_error="1">Msg 102, Level 15, State 1, Server DEV, Line 1</result_row>
						<result_row result_id="2" is_error="1">Incorrect syntax near ''doh''.</result_row>
					  </iteration>
					</iterations>';

				SELECT dbo.transient_error_occurred(@outcome) [first_error];

				SET @outcome = N'<iterations>
					  <iteration execution_outcome="FAILED" iteration_id="1" execution_time="2021-11-02T17:00:16.920">
						<exception>This exception message will not be shown as it is NOT the ''last'' exception... </exception>
					  </iteration>
					  <iteration execution_outcome="FAILED" iteration_id="2" execution_time="2021-11-02T17:00:16.920">
						<exception>Second/Last Exception: </exception>
						<exception>I''m not even 100% sure we''ll actually get exceptions... for most things.</exception>
					  </iteration>
					</iterations>';
	
				SELECT dbo.transient_error_occurred(@outcome) [second_error];

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.transient_error_occurred','FN') IS NOT NULL
	DROP FUNCTION dbo.[transient_error_occurred];
GO

CREATE FUNCTION dbo.[transient_error_occurred] (@executeCommandResults xml)
RETURNS bit
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output bit = 1;
    	DECLARE @count int; 

		SELECT @count = @executeCommandResults.value(N'count(/iterations/iteration)', N'int');
    	IF(@count = 1) 
			SET @output = 0;
    	
    	RETURN @output;
    
    END;
GO