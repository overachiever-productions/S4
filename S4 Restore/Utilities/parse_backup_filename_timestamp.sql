/*
	INTERNAL (ish)

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
		DECLARE @fileOnly varchar(500) = dbo.[extract_filename_from_fullpath](@filename);
    	
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


		-- KIND of an elaborate work-around to find the date-stamp WITHOUT using TRY_CAST... 
		DECLARE @anchor int;
		WITH core AS ( 
			SELECT 
				[row_id], 
				[file_part], 
				LEN([file_part]) [len]
			FROM 
				@parts
			WHERE 
				[file_part] LIKE N'%[0-9]%' AND LEN([file_part]) IN (2,4,6)
		), 
		leading AS ( 
			SELECT 
				[c].[row_id],
				[c].[file_part],
				[c].[len], 
				ISNULL((SELECT CAST([len] AS sysname) FROM core c2 WHERE c2.[row_id] = c.[row_id] - 3), N'') + N'-'
				+ ISNULL((SELECT CAST([len] AS sysname) FROM core c2 WHERE c2.[row_id] = c.[row_id] - 2), N'') + N'-'
				+ ISNULL((SELECT CAST([len] AS sysname) FROM core c2 WHERE c2.[row_id] = c.[row_id] - 1), N'') + N'-' 
				+ CAST([c].[len] AS sysname)
				[pattern]
			FROM 
				core c
		) 

		SELECT TOP 1
			@anchor = [leading].[row_id]
		FROM 
			leading
		WHERE 
			[leading].[pattern] = N'4-2-2-6'
		ORDER BY 
			[leading].[row_id] DESC;

		DECLARE @date sysname = N'';
		DECLARE @time sysname;
		SELECT 
			@date = @date + file_part + CASE WHEN [row_id] = (@anchor - 1) THEN '' ELSE '-' END
		FROM 
			@parts
		WHERE 
			[row_id] IN ((@anchor - 3), (@anchor - 2), (@anchor - 1))
		ORDER BY 
			[row_id];

		SELECT @time = file_part FROM @parts WHERE [row_id] = (@anchor);  -- 7
		SET @time = LEFT(@time, 2) + N':' + SUBSTRING(@time, 3, 2) + N':' + RIGHT(@time, 2);
    	
    	SET @datestring = @date + N' ' + @time;

		RETURN CAST(@datestring AS datetime);
    END;
GO