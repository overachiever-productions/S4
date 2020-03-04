/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.parse_backup_filename_timestamp','FN') IS NOT NULL
	DROP FUNCTION dbo.[parse_backup_filename_timestamp];
GO

CREATE FUNCTION dbo.[parse_backup_filename_timestamp] (@filename varchar(500))
RETURNS datetime
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- {copyright}
    
    BEGIN; 
    	
		DECLARE @datestring sysname;
    	
    	DECLARE @parts table (
			row_id int NOT NULL, 
			file_part sysname NOT NULL
		);

		INSERT INTO @parts (
			[row_id],
			[file_part]
		)
		SELECT 
			[row_id],
			CAST([result] AS sysname)
		FROM 
			dbo.[split_string](@filename, N'_', 1)
    	
		DECLARE @date sysname = N'';
		DECLARE @time sysname;
		SELECT 
			@date = @date + file_part + CASE WHEN [row_id] = 6 THEN '' ELSE '-' END
		FROM 
			@parts
		WHERE 
			[row_id] IN (4,5,6) 
		ORDER BY 
			[row_id];

		SELECT @time = file_part FROM @parts WHERE [row_id] = 7;
		SET @time = LEFT(@time, 2) + N':' + SUBSTRING(@time, 3, 2) + N':' + RIGHT(@time, 2);
    	
    	SET @datestring = @date + N' ' + @time;

		RETURN CAST(@datestring AS datetime);
    END;
GO