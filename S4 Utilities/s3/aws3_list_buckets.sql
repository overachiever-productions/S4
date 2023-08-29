/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.aws3_list_buckets','P') IS NOT NULL
	DROP PROC dbo.[aws3_list_buckets];
GO

CREATE PROC dbo.[aws3_list_buckets]
	@ExtractLocations				bit					= 1,			-- forces a lookup for each bucket to grab the location... 
	@ExcludedBuckets				nvarchar(MAX)		= NULL, 
	@OrderBy						sysname				= N'NAME'		-- { NAME | REGION | DATE }

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExcludedBuckets = NULLIF(@ExcludedBuckets, N'');
	SET @OrderBy = ISNULL(@OrderBy, N'NAME');

	IF UPPER(@OrderBy) NOT IN (N'NAME', N'REGION', N'DATE') BEGIN 
		RAISERROR(N'Allowed Options for @OrderBy are { NAME | REGION | DATE }.', 16, 1); 
		RETURN -1;
	END;

	EXEC dbo.[verify_advanced_capabilities];

	DECLARE @returnValue int; 
	DECLARE @errorMessage nvarchar(MAX); 
	DECLARE @commandResults xml;
	DECLARE @currentCommand nvarchar(MAX);

	BEGIN TRY 
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Import-Module -Name "AWS.Tools.S3"',
			@ErrorMessage = @errorMessage OUTPUT;	

	END TRY 
	BEGIN CATCH 
		SET @errorMessage = N'Unexpected Error Validating AWS.Tools.S3 Module Installed: Error ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -10;
	END CATCH;

	IF @returnValue <> 0 OR @errorMessage IS NOT NULL BEGIN 
		SET @errorMessage = N'PowerShell Error: ' + @errorMessage;
		RAISERROR(@errorMessage, 16, 1);
		RETURN -12;
	END;

	-- Attempt to grab a list of buckets: 
	BEGIN TRY 
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Get-S3Bucket | ConvertTo-Xml -As Stream;',
			@SerializedXmlOutput = @commandResults OUTPUT, 
			@ErrorMessage = @errorMessage OUTPUT;	
		
-- TODO:
--			if Credentials haven't been specified (or there isn't an EC2-InstanceProfile bound/set...)
--			then, via native powershell ... we get something like: 
--				a) the attempt to Get-S3Bucket ... takes around 60 seconds (seriously). 
--				b) it throws this error: Get-S3Bucket: No credentials specified or obtained from persisted/shell defaults.
--		But, if I run this: 
--		I get this result: 
--					<?xml version="1.0" encoding="utf-8"?>
--					<Objects>
--					Get-S3Bucket: No credentials specified or obtained from persisted/shell defaults.

--		As in, PowerShell STOPS writing out XML ... and throws an error... 
--		meaning, I've got to look at 2-3 things here: 
--			a. I need to look at determining if XML passed out of powershell is even remotely well-formed or not. I'm getting '' as the result from the above... 
--				so... need better error handling here... 
--			b. I need a BETTER way to determine if creds have been loaded or not. 
--				I presume I can list profiles AND if those are empty, then ... try to find/see if there's an EC2 instanceProfile bound? 
--				something like this should be fairly... fast-ish? either there's nothing set at profile/creds level or there is... etc. 

	END TRY 
	BEGIN CATCH 
		SET @errorMessage = N'Unexpected Error Validating AWS.Tools.S3 Module Installed: Error ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -20;
	END CATCH;

	IF @returnValue <> 0 OR @errorMessage IS NOT NULL BEGIN 
		SET @errorMessage = N'PowerShell Error: ' + @errorMessage;
		RAISERROR(@errorMessage, 16, 1);
		RETURN -22;
	END;

	CREATE TABLE #buckets ( 
		row_id int IDENTITY(1,1) NOT NULL, 
		bucket_name sysname NOT NULL, 
		created datetime NOT NULL, 
		region nvarchar(MAX) NULL
	);

	INSERT INTO [#buckets] (
		[bucket_name],
		[created]
	)
	SELECT 
		r.d.value(N'(./Property[@Name="BucketName"]/text())[1]', N'sysname') [bucket_name],
		r.d.value(N'(./Property[@Name="CreationDate"]/text())[1]', N'datetime') [created]
	FROM 
		@commandResults.nodes(N'Objects/Object') r(d);

	IF @ExcludedBuckets IS NOT NULL BEGIN 
		DECLARE @exclusions table ( 
			exclusion sysname NOT NULL 
		); 

		INSERT INTO @exclusions ([exclusion])
		SELECT 
			[result]
		FROM 
			dbo.[split_string](@ExcludedBuckets, N',', 1);

		DELETE x 
		FROM 
			[#buckets] x 
			INNER JOIN @exclusions e ON x.[bucket_name] LIKE e.[exclusion];
	END;

	IF @ExtractLocations = 1 BEGIN
		DECLARE @rowId int, @bucketName sysname, @regionName sysname; 

		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			row_id, 
			[bucket_name]
		FROM 
			[#buckets];
	
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @rowId, @bucketName;
	
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			BEGIN TRY 
				SET @commandResults = NULL; 
				SET @currentCommand = N'Get-S3BucketLocation -BucketName "' + @bucketName +'" | ConvertTo-Xml -As Stream;'

				EXEC dbo.[execute_powershell]
					@Command = @currentCommand,
					@SerializedXmlOutput = @commandResults OUTPUT;

				SELECT @regionName = @commandResults.value(N'(/Objects/Object/Property/text())[1]', N'sysname');

	-- TODO: Looks like Get-S3BucketLocation is stupid/lame? if a bucket is NOT located in ... the current/default region ... we get
				--		the following as a result back from AWS: <Objects><Object Type="Amazon.S3.S3Region"><Property Name="Value" Type="System.String"/></Object></Objects>
				IF @regionName IS NULL 
					SET @regionName = CAST(@commandResults AS nvarchar(MAX));

			END TRY 
			BEGIN CATCH
				SET @regionName = N'# ERROR #';
			END CATCH;
		 
				UPDATE [#buckets] 
				SET 
					[region] = @regionName 
				WHERE 
					[row_id] = @rowId;
	
			FETCH NEXT FROM [walker] INTO @rowId, @bucketName;
		END;
	
		CLOSE [walker];
		DEALLOCATE [walker];
	END;

-- TODO: implement @ignored + join ... to exclude/remove any buckets not desired. 

	DECLARE @sql nvarchar(MAX) = N'SELECT 
		[bucket_name],
		[created]{region} 
	FROM 
		[#buckets]
	ORDER BY 
		{orderBy}; ';

	DECLARE @sort sysname = CASE @OrderBy 
		WHEN N'NAME' THEN N'bucket_name'
		WHEN N'REGION' THEN N'region'
		WHEN N'DATE' THEN N'created'
	END; 

	IF @ExtractLocations = 0 AND @sort = N'region' SET @sort = N'bucket_name';
	
	SET @sql = REPLACE(@sql, N'{orderBy}', @sort);

	IF @ExtractLocations = 0 
		SET @sql = REPLACE(@sql, N'{region}', N'');
	ELSE
		SET @sql = REPLACE(@sql, N'{region}', N',' + NCHAR(13) + NCHAR(10) + NCHAR(9) + NCHAR(9) + N'[region]');

	EXEC sp_executesql 
		@sql;

	RETURN 0;
GO