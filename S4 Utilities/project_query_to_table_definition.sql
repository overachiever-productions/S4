/*
	REFACTOR/RENAME:
		dbo.project_table_from_query


	CONVENTIONS: 
		- PROJECT or RETURN

	NOTE: 
		- NOT Supported on 2008/2008R2 Instances.



	SAMPLE EXECUTION:

			EXEC admindb.dbo.[project_query_to_table_definition]
				@Command = N'SELECT * FROM Compression_B.dbo.ActivitiesAudit;';	

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.project_query_to_table_definition','P') IS NOT NULL
	DROP PROC dbo.[project_query_to_table_definition];
GO

CREATE PROC dbo.[project_query_to_table_definition]
	@Command					nvarchar(MAX), 
	@Params						nvarchar(MAX)		= NULL,
	@TableName					sysname				= N'output',
	@Mode						sysname				= N'VARIABLE',			-- { VARIABLE | TEMP | USER }
	@Output						nvarchar(MAX)		= N''		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Params = NULLIF(@Params, N'');

	DECLARE @schema table ( 
		is_hidden bit NOT NULL, 
		column_ordinal int NOT NULL, 
		[name] sysname NULL, 
		is_nullable bit NOT NULL, 
		system_type_id int NOT NULL, 
		system_type_name nvarchar(256) NULL, 
		max_length smallint NOT NULL, 
		[precision] tinyint NOT NULL, 
		scale tinyint NOT NULL, 
		collation_name sysname NULL, 
		user_type_id int NULL, 
		user_type_database sysname NULL, 
		user_type_schema sysname NULL, 
		user_type_name sysname NULL, 
		assembly_qualified_type_name nvarchar(4000) NULL, 
		xml_collection_id int NULL, 
		xml_collection_database sysname NULL, 
		xml_collection_schema sysname NULL, 
		xml_collection_name sysname NULL, 
		is_xml_document bit NOT NULL, 
		is_case_sensitive bit NOT NULL, 
		is_fixed_length_clr_type bit NOT NULL, 
		source_server sysname NULL, 
		source_database sysname NULL, 
		source_schema sysname NULL, 
		source_table sysname NULL, 
		source_column sysname NULL, 
		is_identity_column bit NULL, 
		is_part_of_unique_key bit NULL, 
		is_updateable bit NULL, 
		is_computed_colum bit NULL, 
		is_sparse_column_set bit NULL,
		ordinal_in_order_by_list smallint NULL, 
		order_by_list_length smallint NULL, 
		order_by_is_descending smallint NULL, 
		tds_type_id int NOT NULL, 
		tds_length int NOT NULL, 
		tds_collation_id int NULL, 
		tds_collation_sort_id tinyint NULL
	)

	INSERT INTO @schema 
	EXEC master.sys.sp_describe_first_result_set 
		@tsql = @Command,  -- 2012+ (only)
		@params = @Params;

	DECLARE walker CURSOR LOCAL FAST_FORWARD FOR 
	SELECT 
		[name], 
		is_nullable, 
		is_identity_column,
		CASE 
			WHEN system_type_name = 'nvarchar(128)' /*AND user_type_name = 'sysname'*/ THEN 'sysname'
			ELSE system_type_name 
		END system_type_name
	FROM 
		@schema 
	ORDER BY 
		column_ordinal;

	DECLARE @name sysname, @nullable bit, @identity bit, @datatype nvarchar(256);

	DECLARE @result nvarchar(MAX); 
	SELECT @result = CASE
		WHEN @Mode = 'VARIABLE' THEN N'DECLARE @' + @TableName + N' table ('
		WHEN @Mode = 'TEMP' THEN N'CREATE TABLE #' + @TableName + N' ('
		WHEN @Mode = 'USER' THEN 'CREATE TABLE ' + @TableName + N' ('
		ELSE NULL -- null plus anything = ... null ... so we'll get no output
	END;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);

	OPEN walker; 

	FETCH NEXT FROM walker INTO @name, @nullable, @identity, @datatype;

	WHILE @@FETCH_STATUS = 0 BEGIN

		SET @result += @crlf + @tab;

		SET @result += QUOTENAME(@name,'[]') + N' ' + @datatype + N' '; 

		IF @identity = 1 
			SET @result += N'IDENTITY(1,1) ' -- KIND of a hack at this point. 

		IF @nullable = 1 
			SET @result += N'NULL'
		ELSE 
			SET @result += N'NOT NULL'

		SET @result += N','

		FETCH NEXT FROM walker INTO @name, @nullable, @identity, @datatype;
	END;

	CLOSE walker;
	DEALLOCATE walker;
	
	SET @result = LEFT(@result, LEN(@result) - 1);
	SET @result += @crlf + N');' + @crlf;

	IF @Output IS NULL BEGIN
		SET @Output = @result; 
		RETURN 0;
	END;

	PRINT @result;
	RETURN 0;
GO	