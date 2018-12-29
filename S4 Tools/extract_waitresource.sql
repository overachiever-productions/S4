/*

		FODDER: 
			- https://support.microsoft.com/en-us/help/224453/inf-understanding-and-resolving-sql-server-blocking-problems 
				nice, there's a CHART in roughly the 'middle' of that page with info on what waitresources are and how the formats work... 

			- https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql?view=sql-server-2017#Anchor_2
				closest thing I can see towards being actual 'docs'... 

			- https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql?view=sql-server-2017#Anchor_2
				docs on sys.dm_tran_locks - which covers some of these details a bit better.


	resourcewait identifier types/patterns: 
		
		DATABASE: 
			DATABASE: 12:0									so, here's the rub... all waits i was seeing were in dbid 7 - why the hell am i seeing 36 waits against DATABASE: 12:0 ???? 

		FILE 
			FILE: 7:0										looks fairly obvious - as in, something going on with 'a file' for DBID 7 (right?). Only... which file - and WHAT is going on? (is it the log file? or ... what?)

		TABLE
			TAB: 5:496056853		
			
		EXTENT 
									

		PAGE: 
				note: SQL Server 2014+ ... we can use: sys.dm_db_database_page_allocations (undocumented - but fast/awesome).
				note: with SQL Server 2008+ we can use %%physloc%% to show EXACTLY which rows were being locked in our page...   as per: https://littlekendra.com/2016/10/17/decoding-key-and-page-waitresource-for-deadlocks-and-blocking/
										fodder for physloc:   
												https://dba.stackexchange.com/questions/106762/how-can-i-convert-a-key-in-a-sql-server-deadlock-report-to-the-value
												https://www.sqlskills.com/blogs/paul/sql-server-2008-new-undocumented-physical-row-locator-function/


			PAGE: 7:1:14881502								dbid:fileid:pageid			
			7:1:8932520										dbid:fileid:pageid			not sure WHY this is missing the "PAGE: " prefix... BUT I've only ever seen this in the BLOCKING query's wait-resource... 


			2:1:128											THINK this is a page-id - probably in ... tempdb? but ... need to verify... possible fodder: https://mssqlwiki.com/tag/wait-resource-212/


		KEY:
			KEY: 7:72057594197573632 (6b82a10ccc24)			dbid:hobtid (lockrange)   - where lockrange is something we can look-up with %%lockres%%

		ROW:
				RID: 7:1:104:3								dbid:fileid:pageid:slot (row)  


		OBJECTS: 
			OBJECT: 7:496056853:0							dbid:object_id:lock_partition_id    (lock_partition_id usually doesn't mean anything unless server has > 16 cores... ) 
			OBJECT: 7:1768366806:0 [COMPILE]				obviously, we're compiling an object - in the form of dbid:object_id


*/





USE [admindb];
GO

IF OBJECT_ID('dbo.extract_waitresource','P') IS NOT NULL
	DROP PROC dbo.extract_waitresource;
GO

CREATE PROC dbo.extract_waitresource
	--@TargetDatabase				sysname, 
	@DatabaseNameMapping		nvarchar(MAX)		= NULL,   -- N'7:Xcelerator,5:oink'  -- i.e., if we're looking up names... we want a lookup on THIS server that points to db names and crap on the old server... 
	@DatabaseMetaDataMapping	nvarchar(MAX)		= NULL,	-- N'7:Xcelerator_Clone5'	-- same as above, but indicates OPTIONAL overrides (as above) to use when looking up object/page and other Ids... in a db... 
	@WaitResource				sysname, 
	@Output						nvarchar(2000)		= NULL    OUTPUT
AS 
	SET NOCOUNT ON; 

	-- {copyright}

	IF NULLIF(@WaitResource, N'') IS NULL BEGIN 
		SET @Output = N'';
		RETURN 0;
	END;
		
	IF @WaitResource = N'0:0:0' BEGIN 
		SET @Output = N'[Unidentified: 0:0:0]';
		RETURN 0;
	END;

	IF @WaitResource LIKE '%COMPILE]' BEGIN -- just change the formatting so that it matches 'rules processing' details below... 
		SET @WaitResource = N'COMPILE: ' + REPLACE(@WaitResource, N' [COMPILE]', N'');
	END;

	IF @WaitResource LIKE '%[0-9]%:%[0-9]%:%[0-9]%' AND @WaitResource NOT LIKE N'%: %' BEGIN -- this is a 'shorthand' PAGE identifier: 
		SET @WaitResource = N'XPAGE: ' + @WaitResource;
	END;

	IF @WaitResource LIKE N'KEY: %' BEGIN 
		SET @WaitResource = REPLACE(REPLACE(@WaitResource, N' (', N':'), N')', N'');  -- extract to 'explicit' @part4... 
	END;

	SET @WaitResource = REPLACE(@WaitResource, N' ', N'');
	DECLARE @parts table (row_id int, part nvarchar(200));

	INSERT INTO @parts (row_id, part) 
	SELECT [row_id], [result] FROM admindb.dbo.[split_string](@WaitResource, N':');

	DECLARE @waittype sysname, @part2 bigint, @part3 bigint, @part4 sysname; 
	SELECT @waittype = part FROM @parts WHERE [row_id] = 1; 
	SELECT @part2 = CAST(part AS bigint) FROM @parts WHERE [row_id] = 2; 
	SELECT @part3 = CAST(part AS bigint) FROM @parts WHERE [row_id] = 3; 
	SELECT @part4 = part FROM @parts WHERE [row_id] = 4; 
	
	DECLARE @lookupSQL nvarchar(2000);
	DECLARE @dbName sysname;
	DECLARE @objectName sysname;
	DECLARE @objectID int;

	IF @waittype = N'DATABASE' BEGIN
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;

		IF @part3 = 0 
			SELECT @Output = N'SCHEMA_LOCK - ' + DB_NAME(@part2);
		ELSE 
			SELECT @Output = N'DATABASE_LOCK - ' + CAST(@part2 AS sysname);

		RETURN 0;
	END; 

	IF @waittype = N'FILE' BEGIN 
		-- TODO: are there any variations on this? or is @part3 always 0?	
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SELECT @Output = N'FILE_LOCK - ' + DB_NAME(@part2);
		RETURN 0;
	END;

	IF @waittype = N'TAB' BEGIN 
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SET @dbName = DB_NAME(@part2);
		SET @lookupSQL = N'SELECT @objectName = [name] FROM [' + ISNULL(DB_NAME(@part2), N'master') + N'].sys.objects WHERE object_id = ' + CAST(@part3 AS sysname) + N';';	

		EXEC [sys].[sp_executesql]
			@stmt = @lookupSQL, 
			@params = N'@objectName sysname OUTPUT', 
			@objectName = @objectName OUTPUT;

		SET @Output = N'TABLE_LOCK - ' + ISNULL(@dbName, N'#db_name#') + N' - ' + ISNULL(@objectName, N'#table_name#');
		RETURN 0;
	END;

	IF @waittype = N'EXTENT' BEGIN 
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SET @Output = N'EXTENT - NOT IMPLEMENTED Yet... ';
		RETURN 0;
	END; 

	IF @waittype = N'KEY' BEGIN 
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SET @dbName = DB_NAME(@part2);

-- TODO: combine object_NAME _AND_ the IX ID for the hobt in question... 
		SET @lookupSQL = N'SELECT @objectName = o.[name] FROM [' + ISNULL(DB_NAME(@part2), N'master') + N'].sys.partitions p INNER JOIN [' + ISNULL(DB_NAME(@part2), N'master') + N'].sys.objects o ON p.object_id = o.object_id WHERE p.hobt_id = ' + CAST(@part3 AS sysname) + N';';

		EXEC [sys].[sp_executesql]
			@stmt = @lookupSQL, 
			@params = N'@objectName sysname OUTPUT', 
			@objectName = @objectName OUTPUT;

-- TODO: a) output the lock_res and b) maybe even try to get it? 
		SET @Output = N'KEY RANGE - ' + ISNULL(@dbName, N'#db_name#') + N' - ' + ISNULL(@objectName, N'#table_name# + IX ID');
		RETURN 0;
	END;

	IF @waittype = N'ROW' BEGIN 
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SET @Output = N'ROW - NOT IMPLEMENTED YET';
		RETURN 0;
	END;

	IF @waittype = N'OBJECT' BEGIN 
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SET @Output = N'OBJECT - NOT IMPLEMENTED YET... ';
		RETURN 0;
	END;

	IF @waittype = N'PAGE' OR @waittype = N'XPAGE' BEGIN 
-- TODO: IMPLEMENT
-- if there's an override from @DatabaseNameMapping - use that... 
-- if there's not, then do DB_ID(@extractedDbName) as @OUTPUT;
		SET @dbName = DB_NAME(@part2);

		CREATE TABLE #results (ParentObject varchar(255), [Object] varchar(255), Field varchar(255), [VALUE] varchar(255));
		SET @lookupSQL = N'DBCC PAGE('''+ @dbName + ''', ' + CAST(@part3 AS sysname) + ', ' + @part4 + ', 1) WITH TABLERESULTS;'

		INSERT INTO #results ([ParentObject], [Object], [Field], [VALUE])
		EXECUTE (@lookupSQL);
		
-- TODO: grab the Index ID too... (cuz it's obviously available)... 
		SELECT @objectID = CAST([VALUE] AS int) FROM [#results] WHERE [ParentObject] = N'PAGE HEADER:' AND [Field] = N'Metadata: ObjectId';


		SET @Output = @waittype + N' - NOT IMPLEMENTED YET... ';   -- get: db, object, IX... 
		RETURN 0;
	END;

	-- IF we're still here: 
	SELECT @waittype [wait_type], @part2 [part2], @part3 [part3], @part4 [part4];
	SET @Output = N'NON-IMPLEMENTED - ' + @WaitResource;
	RETURN -1;
GO