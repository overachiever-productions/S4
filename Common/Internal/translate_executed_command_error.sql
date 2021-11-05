/*

	NOTE: 
		This function simply grabs the last/latest execution outcome's 'element' data - which means that it'll work for both <exception>s and normal <result_row>s... 


	SAMPLES/EXAMPLE-SIGNATURES: 



				DECLARE @outcome xml = N'<iterations>
				  <iteration execution_outcome="FAILED" iteration_id="1" execution_time="2021-11-02T17:00:16.920">
					<result_row result_id="1" is_error="1">Msg 102, Level 15, State 1, Server DEV, Line 1</result_row>
					<result_row result_id="2" is_error="1">Incorrect syntax near ''doh''.</result_row>
				  </iteration>
				</iterations>';

				SELECT CAST(@outcome.value(N'(/iterations/iteration)[last()]', N'nvarchar(MAX)') AS nvarchar(MAX)) [error];

				SET @outcome = N'<iterations>
				  <iteration execution_outcome="FAILED" iteration_id="1" execution_time="2021-11-02T17:00:16.920">
					<exception>This exception message will not be shown as it is NOT the ''last'' exception... </exception>
				  </iteration>
				  <iteration execution_outcome="FAILED" iteration_id="2" execution_time="2021-11-02T17:00:16.920">
					<exception>Second/Last Exception: </exception>
					<exception>I''m not even 100% sure we''ll actually get exceptions... for most things.</exception>
				  </iteration>
				</iterations>';
	
				SELECT CAST(@outcome.value(N'(/iterations/iteration)[last()]', N'nvarchar(MAX)') AS nvarchar(MAX)) [error];


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.translate_executed_command_error','FN') IS NOT NULL
	DROP FUNCTION dbo.[translate_executed_command_error];
GO

CREATE FUNCTION dbo.[translate_executed_command_error] (@ExecutionOutcome xml)
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @error nvarchar(MAX);
    	
		SELECT @error = CAST(@ExecutionOutcome.value(N'(/iterations/iteration)[last()]', N'nvarchar(MAX)') AS nvarchar(MAX));
    	
    	RETURN @error;
    
    END;
GO