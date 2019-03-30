/*

		FUN: 
			Here' are some resource identifiers I've captured from Deadlock and OTHER traces: 

				METADATA: database_id = 5 COMPRESSED_FRAGMENT(object_id = 597577167, fragment_id = 6088335), lockPartitionId = 0
					METADATA: database_id = 5 COMPRESSED_FRAGMENT(object_id = 597577167, fragment_id = 1427564), lockPartitionId = 0
						i.e., the two locks above were fighting with each other ... and caused a deadlock... 
							PRETTY sure this is ..... Full Text Indexing... https://twitter.com/kevriley/status/301042539232915457  (especially since the table in question was FTI'd...  (and massive))...		



		FODDER: 
			- https://support.microsoft.com/en-us/help/224453/inf-understanding-and-resolving-sql-server-blocking-problems 
				nice, there's a CHART in roughly the 'middle' of that page with info on what waitresources are and how the formats work... 

			- https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql?view=sql-server-2017#Anchor_2
				docs on sys.dm_tran_locks - which covers SOME of these details a bit...


			RESOURCE IDENTIFIER PATTERNS:
		
				DATABASE 
					DATABASE: 12:0									so, here's the rub... all waits i was seeing were in dbid 7 - why the hell am i seeing 36 waits against DATABASE: 12:0 ???? 

				APPLICATION
					APPLICATION: ???? 

				FILE 
					FILE: 7:0										looks fairly obvious - as in, something going on with 'a file' for DBID 7 (right?). Only... which file - and WHAT is going on? (is it the log file? or ... what?)

				METADATA
					METADATA: ??? 

				ALLOCATION_UNIT
					ALLOCATION_UNIT: ???? 
		
				TABLE
					TAB: 5:496056853:1								dbid:objectid:indexid
			
				HOBT
					HOBT: ????										dbid:hobt? ???? 

				EXTENT 
					EXTENT: 7:1:23456								dbid:fileid:pageid (of the FIRST page in the extent). 							

				PAGE 
																				note: SQL Server 2014+ ... we can use: sys.dm_db_database_page_allocations (undocumented - but fast/awesome).
																				note: with SQL Server 2008+ we can use %%physloc%% to show EXACTLY which rows were being locked in our page
																										fodder for physloc:   
																												https://littlekendra.com/2016/10/17/decoding-key-and-page-waitresource-for-deadlocks-and-blocking/
																												https://www.sqlskills.com/blogs/paul/sql-server-2008-new-undocumented-physical-row-locator-function/


					PAGE: 7:1:14881502								dbid:fileid:pageid			
					7:1:8932520										dbid:fileid:pageid			not sure WHY this is missing the "PAGE: " prefix... BUT I've only ever seen this in the BLOCKING query's wait-resource... 


					2:1:128											THINK this is a page-id - probably in ... tempdb? but ... need to verify... possible fodder: https://mssqlwiki.com/tag/wait-resource-212/


				KEY
					KEY: 7:72057594197573632 (6b82a10ccc24)			dbid:hobtid (lockrange)   - where lockrange is something we can look-up with %%lockres%%
																							%%lockres%% fodder: 
																									https://dba.stackexchange.com/questions/106762/how-can-i-convert-a-key-in-a-sql-server-deadlock-report-to-the-value
																									https://littlekendra.com/2016/10/17/decoding-key-and-page-waitresource-for-deadlocks-and-blocking/
				ROW
						RID: 7:1:104778:3								dbid:fileid:pageid:slot (row)  


				OBJECT 
					OBJECT: 7:496056853:0							dbid:object_id:lock_partition_id    (lock_partition_id usually doesn't mean anything unless server has > 16 cores... ) 
					OBJECT: 7:1768366806:0 [COMPILE]				obviously, we're compiling an object - in the form of dbid:object_id




		TODO:
			- Implement METADATA
			- Implement HOBT (should be pretty easy)
			- Implement APPLICATION

			- Add Index ID into TABLE locks - assuming it's ever anything OTHER than 1 or (and, even then, i'd like to use the name of the IX or 'HEAP')... 

			- Look at creating the STATEMENTS needed to pull/return outputs for PAGE, KEY, and ROW identifiers... (PAGE and KEY are 'easy-ish' = they're just SELECT * FROM [dbid]..[objectid] WHERE %%physloc|lockres%%... = (formatted for whatever type). 
				Rows... harder, I'd have to figure out the ... PK? on the row? or the IX 'key'? and then ... translate that into an id? ... guessing it COULD? be done? but... not sure... 
						meh. not SUPER hard... but it'll take some work. But, DBCC PAGE (output type of 3 will get what is needed): 
										DBCC PAGE('Xcelerator', 1, 689098, 3) WITH TABLERESULTS;
										DBCC PAGE('Xcelerator', 1, 8584, 3) WITH TABLERESULTS;



		USAGE: 
			- Example Execution - where db_id 7 is 'remapped' to a database named 'ProdDatabase' and where the meta-data for OBJECT_ID and other lookups comes from a database (on box) called ProdDatabase5_Clone (i.e., a DBCC CLONEDATABASE() 'copy') of the database... 



					DECLARE @output nvarchar(MAX);
					EXEC dbo.extract_waitresource 
						@WaitResource = N'KEY: 7:72057594197573632 (6b82a10ccc24)', 
						@DatabaseMappings = N'7|ProdDatabase|ProdDatabase_Clone5,5|admindb',
						@Output = @output OUTPUT;

					SELECT @output [resource_details];



*/





USE [admindb];
GO

IF OBJECT_ID('dbo.extract_waitresource','P') IS NOT NULL
	DROP PROC dbo.extract_waitresource;
GO

CREATE PROC dbo.extract_waitresource
	@WaitResource				sysname, 
	@DatabaseMappings			nvarchar(MAX)			= NULL,
	@Output						nvarchar(2000)			= NULL    OUTPUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@WaitResource, N'') IS NULL BEGIN 
		SET @Output = N'';
		RETURN 0;
	END;
		
	IF @WaitResource = N'0:0:0' BEGIN 
		SET @Output = N'[0:0:0] - UNIDENTIFIED_RESOURCE';
		RETURN 0;
	END;

	IF @WaitResource LIKE '%COMPILE]' BEGIN -- just change the formatting so that it matches 'rules processing' details below... 
		SET @WaitResource = N'COMPILE: ' + REPLACE(REPLACE(@WaitResource, N' [COMPILE]', N''), N'OBJECT: ', N'');
	END;

	IF @WaitResource LIKE '%[0-9]%:%[0-9]%:%[0-9]%' AND @WaitResource NOT LIKE N'%: %' BEGIN -- this is a 'shorthand' PAGE identifier: 
		SET @WaitResource = N'XPAGE: ' + @WaitResource;
	END;

	IF @WaitResource LIKE N'KEY: %' BEGIN 
		SET @WaitResource = REPLACE(REPLACE(@WaitResource, N' (', N':'), N')', N'');  -- extract to 'explicit' @part4... 
	END;

	IF @WaitResource LIKE N'RID: %' BEGIN 
		SET @WaitResource = REPLACE(@WaitResource, N'RID: ', N'ROW: '); -- standardize... 
	END;

	IF @WaitResource LIKE N'TABLE: %' BEGIN
		SET @WaitResource = REPLACE(@WaitResource, N'TABLE: ', N'TAB: '); -- standardize formatting... 
	END;

	CREATE TABLE #ExtractionMapping ( 
		row_id int NOT NULL, 
		[database_id] int NOT NULL, 
		[mapped_name] sysname NOT NULL, 
		[metadata_name] sysname NULL
	); 

	IF NULLIF(@DatabaseMappings, N'') IS NOT NULL BEGIN
		INSERT INTO #ExtractionMapping ([row_id], [database_id], [mapped_name], [metadata_name])
		EXEC dbo.[shred_string] 
		    @Input = @DatabaseMappings, 
		    @RowDelimiter = N',',
		    @ColumnDelimiter = N'|'
	END;

	SET @WaitResource = REPLACE(@WaitResource, N' ', N'');
	DECLARE @parts table (row_id int, part nvarchar(200));

	INSERT INTO @parts (row_id, part) 
	SELECT [row_id], [result] FROM dbo.[split_string](@WaitResource, N':', 1);

	BEGIN TRY 
		DECLARE @waittype sysname, @part2 bigint, @part3 bigint, @part4 sysname, @part5 sysname;
		SELECT @waittype = part FROM @parts WHERE [row_id] = 1; 
		SELECT @part2 = CAST(part AS bigint) FROM @parts WHERE [row_id] = 2; 
		SELECT @part3 = CAST(part AS bigint) FROM @parts WHERE [row_id] = 3; 
		SELECT @part4 = part FROM @parts WHERE [row_id] = 4; 
		SELECT @part5 = part FROM @parts WHERE [row_id] = 5; 
	
		DECLARE @lookupSQL nvarchar(2000);
		DECLARE @objectName sysname;
		DECLARE @indexName sysname;
		DECLARE @objectID int;
		DECLARE @indexID int;
		DECLARE @error bit = 0;

		DECLARE @logicalDatabaseName sysname; 
		DECLARE @metaDataDatabaseName sysname;

		-- NOTE: _MAY_ need to override this in some resource types - but, it's used in SO many types (via @part2) that 'solving' for it here makes tons of sense). 
		SET @logicalDatabaseName = ISNULL((SELECT [mapped_name] FROM #ExtractionMapping WHERE database_id = @part2) , DB_NAME(@part2));
		SET @metaDataDatabaseName = ISNULL((SELECT ISNULL([metadata_name], [mapped_name]) FROM #ExtractionMapping WHERE database_id = @part2) , DB_NAME(@part2));

		IF @waittype = N'DATABASE' BEGIN
			IF @part3 = 0 
				SELECT @Output = QUOTENAME(@logicalDatabaseName) + N'- SCHEMA_LOCK';
			ELSE 
				SELECT @Output = QUOTENAME(@logicalDatabaseName) + N' - DATABASE_LOCK';

			RETURN 0;
		END; 

		IF @waittype = N'FILE' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = [physical_name] FROM [Xcelerator].sys.[database_files] WHERE FILE_ID = ' + CAST(@part3 AS sysname) + N';';
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;

			SELECT @Output = QUOTENAME(@logicalDatabaseName) + N' - FILE_LOCK (' + ISNULL(@objectName, N'FILE_ID: ' + CAST(@part3 AS sysname)) + N')';
			RETURN 0;
		END;

		-- TODO: test/verify output AGAINST real 'capture' info.... 
		IF @waittype = N'TAB' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects WHERE object_id = ' + CAST(@part3 AS sysname) + N';';	

			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;

			SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N' - TABLE_LOCK';
			RETURN 0;
		END;

		IF @waittype = N'KEY' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = o.[name], @indexName = i.[name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.partitions p INNER JOIN [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects o ON p.[object_id] = o.[object_id] INNER JOIN [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.indexes i ON [o].[object_id] = [i].[object_id] AND p.[index_id] = [i].[index_id] WHERE p.hobt_id = ' + CAST(@part3 AS sysname) + N';';

			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT, @indexName sysname OUTPUT', 
				@objectName = @objectName OUTPUT, 
				@indexName = @indexName OUTPUT;

			SET @Output = QUOTENAME(ISNULL(@metaDataDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N'.' + QUOTENAME(ISNULL(@indexName, 'INDEX_ID: -1')) + N'.[RANGE: (' + ISNULL(@part4, N'') + N')] - KEY_LOCK';
			RETURN 0;
		END;

		IF @waittype = N'OBJECT' OR @waittype = N'COMPILE' BEGIN 
			SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects WHERE object_id = ' + CAST(@part3 AS sysname) + N';';	
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;		

			SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'OBJECT_ID: ' + CAST(@part3 AS sysname))) + N' - ' + @waittype +N'_LOCK';
			RETURN 0;
		END;

		IF @waittype IN(N'PAGE', N'XPAGE', N'EXTENT', N'ROW') BEGIN 

			CREATE TABLE #results (ParentObject varchar(255), [Object] varchar(255), Field varchar(255), [VALUE] varchar(255));
			SET @lookupSQL = N'DBCC PAGE('''+ @metaDataDatabaseName + ''', ' + CAST(@part3 AS sysname) + ', ' + @part4 + ', 1) WITH TABLERESULTS;'

			INSERT INTO #results ([ParentObject], [Object], [Field], [VALUE])
			EXECUTE (@lookupSQL);
		
			SELECT @objectID = CAST([VALUE] AS int) FROM [#results] WHERE [ParentObject] = N'PAGE HEADER:' AND [Field] = N'Metadata: ObjectId';
			SELECT @indexID = CAST([VALUE] AS int) FROM [#results] WHERE [ParentObject] = N'PAGE HEADER:' AND [Field] = N'Metadata: IndexId';
		
			SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.objects WHERE object_id = ' + CAST(@objectID AS sysname) + N';';	
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@objectName sysname OUTPUT', 
				@objectName = @objectName OUTPUT;

			SET @lookupSQL = N'SELECT @indexName = [name] FROM [' + ISNULL(@metaDataDatabaseName, N'master') + N'].sys.indexes WHERE object_id = ' + CAST(@objectID AS sysname) + N' AND index_id = ' + CAST(@indexID AS sysname) + N';';	
			EXEC [sys].[sp_executesql]
				@stmt = @lookupSQL, 
				@params = N'@indexName sysname OUTPUT', 
				@indexName = @indexName OUTPUT;

			IF @waittype = N'ROW' 
				SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N'.' + QUOTENAME(ISNULL(@indexName, 'INDEX_ID: ' + CAST(@indexID AS sysname))) + N'.[PAGE_ID: ' + ISNULL(@part4, N'')  + N'].[SLOT: ' + ISNULL(@part5, N'') + N'] - ' + @waittype + N'_LOCK';
			ELSE
				SET @Output = QUOTENAME(ISNULL(@logicalDatabaseName, N'DB_ID: ' + CAST(@part2 AS sysname))) + N'.' + QUOTENAME(ISNULL(@objectName, N'TABLE_ID: ' + CAST(@part3 AS sysname))) + N'.' + QUOTENAME(ISNULL(@indexName, 'INDEX_ID: ' + CAST(@indexID AS sysname))) + N' - ' + @waittype + N'_LOCK';
			RETURN 0;
		END;
	END TRY 
	BEGIN CATCH 
		PRINT 'PROCESSING_EXCEPTION: Line: ' + CAST(ERROR_LINE() AS sysname) + N' - Error: ' + CAST(ERROR_NUMBER() AS sysname) + N' -> ' + ERROR_MESSAGE();
		SET @error = 1;
	END CATCH

	-- IF we're still here - then either there was an exception 'shredding' the resource identifier - or we're in an unknown resource-type. (Either outcome, though, is that we're dealing with an unknown/non-implemented type.)
	SELECT @waittype [wait_type], @part2 [part2], @part3 [part3], @part4 [part4], @part5 [part5];

	IF @error = 1 
		SET @Output = QUOTENAME(@WaitResource) + N' - EXCEPTION_PROCESSING_WAIT_RESOURCE';
	ELSE
		SET @Output = QUOTENAME(@WaitResource) + N' - S4_UNKNOWN_WAIT_RESOURCE';

	RETURN -1;
GO