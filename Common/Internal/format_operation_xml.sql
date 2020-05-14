/*

	INTERNAL: 
		Internal only. 

    TODO: 
        pretty sure I don't need @TargetDatabase defined in here at all... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_operation_xml','FN') IS NOT NULL
	DROP FUNCTION dbo.[format_operation_xml];
GO

CREATE FUNCTION dbo.[format_operation_xml] (@Command nvarchar(MAX), @ExecutionType sysname/*, @TargetDatabase sysname*/, @ExecutionTotalAttemptCount int, @RetryInterval sysname, @IgnoredResults nvarchar(MAX))
RETURNS nvarchar(MAX)
AS
    
    -- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output nvarchar(MAX) = N'<operation><command created="' + CONVERT(sysname, GETDATE(), 126) + N'"';

        IF UPPER(@ExecutionType) NOT IN (N'EXEC', N'SQLCMD', N'SHELL', N'PARTNER', N'NO_EXECUTE')
            SET @ExecutionType = NULL;

        IF @ExecutionType IS NULL BEGIN 
            SET @output = @output + N' execution_type="NO_EXECUTE" /><outcomes><outcome outcome_type="EXCEPTION" outcome_start="' 
                + CONVERT(sysname, GETDATE(), 126) + N'">Invalid or empty @ExecutionType specified</outcome></outcomes>';
            GOTO WrapUp;
          END;
        ELSE 
            SET @output = @output + N' execution_type="' + @ExecutionType + N'"';
        
        IF NULLIF(@ExecutionTotalAttemptCount, 0) IS NOT NULL 
            SET @output = @output + N' execution_attempt_count="' + CAST(@ExecutionTotalAttemptCount AS sysname) + N'"';

        IF NULLIF(@RetryInterval, N'') IS NOT NULL 
            SET @output = @output + N' retry_inverval="' + @RetryInterval + N'"';

        IF NULLIF(@IgnoredResults, N'') IS NOT NULL 
            SET @output = @output + N' ignored_results="' + @IgnoredResults + N'"';

        SET @output = @output + N'>' + @Command + N'</command><outcomes />';

WrapUp:   
        SET @output = @output + N'<guidance /></operation>';

    	RETURN @output;
    END;
GO