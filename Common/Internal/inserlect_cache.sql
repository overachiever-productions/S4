/*
	
	INTERNAL:
		Doesn't need a PUBLIC verb. 


	NAME:
		play on insert + SELECT ... similar to an upsert ... but .. yeah. 
*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[inserlect_cache]', N'P') IS NOT NULL
	DROP PROC dbo.[inserlect_cache];
GO

CREATE PROC dbo.[inserlect_cache]
	@vector_type				sysname, 
	@vector_key					sysname, 
	@current_xml				xml,
	@cached_date				datetime				OUTPUT,
	@cached_xml					xml						OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF NOT EXISTS (SELECT NULL FROM [tempdb].sys.[objects] WHERE [name] LIKE N'%##admindb_vector_cache%') BEGIN
		CREATE TABLE ##admindb_vector_cache (
			[row_id] int IDENTITY(1,1) NOT NULL,
			[created] datetime NOT NULL DEFAULT(GETDATE()),
			[vector_type] sysname NOT NULL, -- i.e., the sproc name
			[key] sysname NOT NULL,   -- @vector_tag
			[cached_data] xml NULL		-- cached data ... in XML. 
		);	
	END;

	DECLARE @rowId int;
	SELECT
		@rowId = [row_id], 
		@cached_xml = [cached_data], 
		@cached_date = [created]
	FROM
		[##admindb_vector_cache]
	WHERE
		[vector_type] = @vector_type AND [key] = @vector_key;

	IF @rowId IS NULL BEGIN
		
		INSERT INTO [##admindb_vector_cache] ([vector_type], [key], [cached_data])
		VALUES (
			@vector_type,
			@vector_key,
			@current_xml
		);

		SET @cached_xml = NULL;
	END;

	RETURN 0;
GO