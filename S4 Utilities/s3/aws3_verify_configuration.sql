/*

	PICKUP/NEXT: 
		- Detect ... if is EC2 instance or not... 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.aws3_verify_configuration','P') IS NOT NULL
	DROP PROC dbo.[aws3_verify_configuration];
GO

CREATE PROC dbo.[aws3_verify_configuration]
	@VerifyNuget				bit				= 0,
	@VerifyGalleryAccess		bit				= 0,
	@VerifyS3Modules			bit				= 1, 
	@VerifyProfile				bit				= 1, 
	@VerifyBuckets				bit				= 0, 
	@Results					xml				= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @VerifyNuget = ISNULL(@VerifyNuget, 0);
	SET @VerifyGalleryAccess = ISNULL(@VerifyGalleryAccess, 0);
	SET @VerifyS3Modules = ISNULL(@VerifyS3Modules, 1);
	SET @VerifyProfile = ISNULL(@VerifyProfile, 1);
	SET @VerifyBuckets = ISNULL(@VerifyBuckets, 0);

	DECLARE @returnValue int; 
	DECLARE @stringResults nvarchar(MAX) = NULL;
	DECLARE @xmlResults xml	= NULL;
	DECLARE @errorMessage nvarchar(MAX);

	CREATE TABLE #results (
		row_id int IDENTITY(1,1) NOT NULL, 
		test sysname NOT NULL, 
		passed bit NOT NULL,
		details sysname NOT NULL 
	);

	IF @VerifyNuget = 1 BEGIN 
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Get-PackageProvider -Name Nuget | Select-Object "Version" | ConvertTo-Xml -As Stream;',
			@SerializedXmlOutput = @xmlResults OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;

		IF @returnValue = 0 BEGIN 
			DECLARE @versionExists bit;
			SELECT 
				@versionExists = r.d.exist(N'Object/Property')
			FROM 
				@xmlResults.nodes(N'/Objects') r(d);

			IF @versionExists = 1 BEGIN 
				DECLARE @nugetVersion sysname;
				SELECT 
					@nugetVersion = r.d.value(N'./text()[1]', N'sysname')
				FROM 
					@xmlResults.nodes(N'/Objects/Object/Property') r(d);

				IF CAST((REPLACE(@nugetVersion, N'.', N'')) AS int) > 285201
					INSERT INTO [#results] (
						[test],
						[passed],
						[details]
					)
					VALUES (
						N'NugetVersion', 
						1, 
						N'Version ' + @nugetVersion + N' detected. (Required: 2.8.5.201+)'
					);
					
				ELSE 
					INSERT INTO [#results] (
						[test],
						[passed],
						[details]
					)
					VALUES (
						N'NugetVersion', 
						0, 
						N'Version ' + @nugetVersion + N' detected. (Required: 2.8.5.201+)'
					);
			  END;
			ELSE BEGIN 
				IF (CAST(@xmlResults AS nvarchar(MAX)) LIKE N'%Unable to find package provider ''NuGet''%')
					INSERT INTO [#results] (
						[test],
						[passed],
						[details]
					)
					VALUES (
						N'NugetVersion', 
						0, 
						N'Nuget is NOT installed.'
					);
				ELSE BEGIN 
					INSERT INTO [#results] (
						[test],
						[passed],
						[details]
					)
					VALUES (
						N'NugetVersion', 
						0, 
						-- TODO: maybe shove an [error] column into #results... 
						N'Unexpected Results from Get-PackageProvider -Name "Nuget". Results: ' + CAST(@xmlResults AS nvarchar(MAX))
					);
				END;
			END;
		  END;
		ELSE BEGIN 
			INSERT INTO [#results] (
				[test],
				[passed],
				[details]
			)
			VALUES (
				N'NugetVersion', 
				0, 
				'PowerShell Exception: ' + @errorMessage
			);
		END;
	END;

	IF @VerifyGalleryAccess = 1 BEGIN 
		SET @xmlResults = NULL;
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Find-Module -Name "AWS.Tools.S3" | Select-Object "Version", "Name" | ConvertTo-Xml -As Stream;',
			@SerializedXmlOutput = @xmlResults OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;

		IF @returnValue = 0 BEGIN 
			DECLARE @awsVersion sysname;
			DECLARE @awsModuleName sysname;

			SELECT 
				@awsModuleName = r.d.value(N'(Property[@Name="Name"]/text())[1]', N'sysname'),
				@awsVersion = r.d.value(N'(Property[@Name="Version"]/text())[1]', N'sysname')
			FROM 
				@xmlResults.nodes(N'Objects/Object') r(d);		
	
			IF NULLIF(@awsVersion, N'') IS NOT NULL BEGIN 
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'GalleryAccess', 
					1, 
					N'Found Module ' + @awsModuleName + N' with version ' + @awsVersion + N'.'
				);
			  END;
			ELSE BEGIN 
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'GalleryAccess', 
					0, 
					N'Unexpected Result from Find-Module "AWS.Tools.S3": ' + CAST(@xmlResults AS nvarchar(MAX))
				);
			END;
		  END; 
		ELSE BEGIN 
			INSERT INTO [#results] (
				[test],
				[passed],
				[details]
			)
			VALUES (
				N'GalleryAccess', 
				0, 
				N'PowerShell Exception: ' + @errorMessage
			);
		END;
	END;

	IF @VerifyS3Modules = 1 BEGIN 
		SET @stringResults = NULL
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Import-Module -Name AWS.Tools.S3;',
			@StringOutput = @stringResults OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;
			
		IF @stringResults = N'' BEGIN 
			INSERT INTO [#results] (
				[test],
				[passed],
				[details]
			)
			VALUES (
				N'ModuleInstalled', 
				1, 
				N'Import-Module succeeded.'
			);
		  END; 
		ELSE BEGIN 
			INSERT INTO [#results] (
				[test],
				[passed],
				[details]
			)
			VALUES (
				N'ModuleInstalled', 
				0, 
				N'Unexpected Output from Install-Module -Name "AWS.Tools.S3": Output: ' + @stringResults
			);
		END;
	END;

	IF @VerifyProfile = 1 BEGIN 
		IF @VerifyS3Modules = 1 BEGIN 
			IF EXISTS (SELECT NULL FROM [#results] WHERE [test] = N'ModuleInstalled' AND [passed] = 0) BEGIN
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'ProfileConfigured', 
					0, 
					N'Test Skipped - AWS.Tools.S3 Module not present.'
				);	
			
				GOTO EndProfiles;
			END;
		END;

-- TODO: need to determine if the box in question is an EC2 instance, and, if so, if it has an EC2-InstanceProfile assigned. 
		-- i THINK the process here will be: a) hit the AWS/EC2 meta-data repository on that one ... address, and put in a timeout on the request of something like 5 seconds. 
		--									 b) if we get a result from the above, then check for a profile... otherwise, not an EC2 instance. 

		SET @xmlResults = NULL;
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Get-AWSCredential -ListProfileDetail | ConvertTo-Xml -As Stream;', 
			@SerializedXmlOutput = @xmlResults OUTPUT, 
			@ErrorMessage = @errorMessage OUTPUT;

		DECLARE @profiles table (profile_name sysname NOT NULL);

		IF @returnValue = 0 BEGIN 
			INSERT INTO @profiles ([profile_name])
			SELECT 
				r.d.value(N'(./Property[@Name="ProfileName"]/text())[1]', N'sysname')
			FROM 
				@xmlResults.nodes(N'Objects/Object') r(d);

			DECLARE @profilesCount int = (SELECT COUNT(*) FROM @profiles);
			IF EXISTS (SELECT NULL FROM @profiles WHERE [profile_name] = N'default') BEGIN 
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'ProfileConfigured', 
					1, 
					N'Detected ' + CAST(@profilesCount AS sysname) + N' profile(s) - including ''default'' profile.'
				);					
				END; 
			ELSE BEGIN 
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'ProfileConfigured', 
					0, 
					N'Detected ' + CAST(@profilesCount AS sysname) + N' profile(s) - but the ''default'' profile was NOT found.'
				);				
			END;
			END;
		ELSE BEGIN 
			INSERT INTO [#results] (
				[test],
				[passed],
				[details]
			)
			VALUES (
				N'ProfileConfigured', 
				0, 
				N'No AWS Profiles Defined/Detected.'
			);	
		END;
	END;
EndProfiles:

	IF @VerifyBuckets = 1 BEGIN 
		IF @VerifyProfile = 1 BEGIN 
			IF EXISTS (SELECT NULL FROM [#results] WHERE [test] = N'ProfileConfigured' AND [passed] = 0) BEGIN
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'BucketsExist', 
					0, 
					N'Test Skipped - a valid profile was not detected or is not configured.'
				);	
			
				GOTO EndBuckets;
			END;
		END;
		
		SET @xmlResults = NULL;
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Get-S3Bucket | ConvertTo-Xml -As Stream;', 
			@SerializedXmlOutput = @xmlResults OUTPUT, 
			@ErrorMessage = @errorMessage OUTPUT;

		DECLARE @buckets table (bucket_name sysname NOT NULL);

		IF @returnValue = 0 BEGIN 
			INSERT INTO @buckets ([bucket_name])
			SELECT 
				r.d.value(N'(./Property[@Name="BucketName"]/text())[1]', N'sysname') [bucket_name]
			FROM 
				@xmlResults.nodes(N'Objects/Object') r(d);

			DECLARE @bucketsCount int = (SELECT COUNT(*) FROM @buckets);

			IF @bucketsCount > 0 BEGIN 
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'BucketsExist', 
					1, 
					N'Detected ' + CAST(@bucketsCount AS sysname) + N' bucket(s).'
				);	
			  END; 
			ELSE BEGIN 
				INSERT INTO [#results] (
					[test],
					[passed],
					[details]
				)
				VALUES (
					N'BucketsExist', 
					0, 
					N'No AWS Buckets Defined/Detected.'
				);	
			END;
		  END;
		ELSE BEGIN 
			PRINT 'no buckets';
		END;
	END;
EndBuckets:

	IF (SELECT dbo.is_xml_empty(@Results)) = 1 BEGIN -- RETURN instead of project.. 

		SELECT @Results = (SELECT 
			[test],
			[passed],
			[details]
		FROM 
			[#results] 
		ORDER BY 
			[row_id]
		FOR XML PATH(N'result'), ROOT(N'results'), TYPE);

		RETURN 0;
	END;

	SELECT 
		[test],
		[passed],
		[details]
	FROM 
		[#results] 
	ORDER BY 
		[row_id];

	RETURN 0; 
GO