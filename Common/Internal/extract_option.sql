/*
	
	NOTE: 
		This UDF pulls values from dbo.options (the table). 

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[extract_option]', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[extract_option];
GO

CREATE FUNCTION dbo.[extract_option] (@module sysname, @key sysname)
RETURNS sysname
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	DECLARE @output sysname; 
    	
		SET @module = REPLACE(REPLACE(@module, N'[', N''), N']', N'');
		SET @key = REPLACE(N'@' + @key, N'@@', N'@');

    	/*---------------------------------------------------------------------------------------------------------------------------------------------------
        -- Load module+key, else GLOBAL+key, else NULL (in explicit order).
        ---------------------------------------------------------------------------------------------------------------------------------------------------*/
		SELECT 
			@output = [o].[value]
		FROM (
			VALUES(NULL)
		) [no_match]([empty])
		OUTER APPLY (
			SELECT TOP 1
				[value]
			FROM (
				VALUES 
					((SELECT [value] FROM dbo.[options] WHERE [module] = @module AND [key] = @key), 1),
					((SELECT [value] FROM dbo.[options] WHERE [module] = N'GLOBAL' AND [key] = @key), 2)
				) [options]([value], [rank])
			WHERE 
				[value] IS NOT NULL
			ORDER BY 
				[rank]
		) [o];


		RETURN @output;    
    END;
GO


