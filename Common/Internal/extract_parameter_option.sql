/*

    NOTE: 
        This udf pulls values from the @options parameter ... (NOT the table). 

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[extract_parameter_option]', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[extract_parameter_option];
GO

CREATE FUNCTION dbo.[extract_parameter_option] (@options nvarchar(MAX), @parameter_name sysname)
RETURNS sysname
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
    	DECLARE @output sysname = NULL;
    	
    	IF @options LIKE N'%' + @parameter_name + N':%' ESCAPE N'~' BEGIN
            WITH options AS ( 
                SELECT 
					[result], 
                    PATINDEX(N'%:%', [result]) [index]
                FROM 
                    dbo.[split_string](@options, N';', 1)
            ) 

            SELECT 
                @output = SUBSTRING([options].[result], [index] + 1, LEN([options].[result]) - [index])
            FROM 
                options 
            WHERE 
                [options].[index] > 0 
                AND [result] LIKE N'%' + @parameter_name + N':%' ESCAPE N'~';
        END;
    	
    	RETURN @output;
    
    END;
GO
