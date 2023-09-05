/*

	vNEXT:
		- Probably makes sense to add an @ForceInstallation parameter which, when set to N'Force' or wahtever.. 
			will NOT let various bits of logic get bypassed (like the check to see if the module is already installed right after running validations). 

	If Executed Manually, the main order of operations/processes for this sproc would be: 

			-- make sure we're on 2.8.5.201 or greater... 
			EXEC [admindb].dbo.execute_powershell 
				@Command = N'Get-PackageProvider -Name Nuget'; 

			-- make sure we have a network connection:
			EXEC [admindb].dbo.execute_powershell 
				@Command = N'Find-Module -Name AWS.Tools.S3';
					
			-- Install Module if not already installed: 
			EXEC [admindb].dbo.execute_powershell 
				@Command = N'Get-InstalledModule';

			EXEC [admindb].dbo.execute_powershell 
				@Command = N'Install-Module AWS.Tools.S3 -Force -Scope CurrentUser';

			-- Import: 
			EXEC [admindb].dbo.execute_powershell 
				@Command = N'Import-Module AWS.Tools.S3 -Force;';

			-- Verify: 



	TODO: 
There's a bug in here: 
		--Msg 50000, Level 16, State 1, Procedure admindb.dbo.aws3_install_modules, Line 163 [Batch Start Line 1]
		--Unexpected Error Installing AWS.Tools.S3: 9436: XML parsing: line 285, character 10, end tag does not match start tag
		EXEC [admindb].dbo.[extract_code_lines] 
			@TargetModule = N'admindb.dbo.aws3_install_modules', 
			@TargetLine = 163


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.aws3_install_modules','P') IS NOT NULL
	DROP PROC dbo.[aws3_install_modules];
GO

CREATE PROC dbo.[aws3_install_modules]

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @returnValue int;
	DECLARE @commandResults xml;
	DECLARE @errorText nvarchar(MAX);
	DECLARE @tls12Directive nvarchar(MAX) = N'[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; ';
	DECLARE @currentCommand nvarchar(MAX) = N'';

	DECLARE @validationsCount int = 0;
Validation:
	SET @validationsCount = @validationsCount + 1; 
	IF @validationsCount > 2 BEGIN 
		RAISERROR(N'Potential infinite loop detected - Validation Logic run > 2 times. Aborting.', 16, 1);
		RETURN -100;
	END;
	
	DECLARE @validationResults xml = NULL;
	EXEC dbo.[aws3_verify_configuration]
		@VerifyNuget = 1,
		@VerifyGalleryAccess = 1,
		@VerifyS3Modules = 1,
		@VerifyProfile = 0,
		@VerifyBuckets = 0,
		@Results = @validationResults OUTPUT;
	
	DECLARE @validations table (test sysname NOT NULL, passed bit NOT NULL, details nvarchar(MAX) NOT NULL);
	INSERT INTO @validations ([test],[passed],[details])
	SELECT 
		r.d.value(N'(test/text())[1]', N'sysname') [test], 
		r.d.value(N'(passed/text())[1]', N'bit') [passed],
		r.d.value(N'(details/text())[1]', N'nvarchar(MAX)') [details]
	FROM 
		@validationResults.nodes(N'results/result') r(d);

	IF EXISTS (SELECT NULL FROM @validations WHERE test = N'ModuleInstalled' AND [passed] = 1) BEGIN 
		-- TODO: might make sense to a) report on the VERSION - which I can get from the 'GalleryAccess' row... - and output that. 
		PRINT N'AWS.Tools.S3 Module is already installed. Exiting Setup.';
		RETURN 0;
	END;

	DECLARE @nugetUpdateRequired bit = 0;
	IF EXISTS (SELECT NULL FROM @validations WHERE test = N'NugetVersion' AND [passed] = 0) 
		SET @nugetUpdateRequired = 1;


	SET @commandResults = NULL;
	EXEC @returnValue = dbo.[execute_powershell]
		@Command = N'Get-PackageProvider -Name NuGet | Select "Version" | ConvertTo-Xml -As Stream;',
		@SerializedXmlOutput = @commandResults OUTPUT, 
		@ErrorMessage = @errorText OUTPUT;

	IF @nugetUpdateRequired = 1 BEGIN 
		PRINT N'Nuget Update Required...';

		BEGIN TRY

			/* 

	
		
			*/
			SET @currentCommand = @tls12Directive + N'Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.208 -Force -Scope CurrentUser | ConvertTo-Xml -As Stream;';

			EXEC @returnValue = dbo.[execute_powershell]
				@Command = @currentCommand,
				@SerializedXmlOutput = @commandResults OUTPUT;

		END TRY 
		BEGIN CATCH 
			SET @errorText = N'Unhandled Exception Attempting Installation / Update of Nuget Package Management: ' + ERROR_MESSAGE();
			RAISERROR(@errorText, 16, 1);
			RETURN -25;
		END CATCH;
	END; 

	IF EXISTS (SELECT NULL FROM @validations WHERE [test] = N'GalleryAccess' AND [passed] = 0) BEGIN 
		GOTO Validation; -- yup, restart things. 
	END;

	-- If we're still here, time to try and install the module: 
	SET @commandResults = NULL;
	EXEC @returnValue = dbo.[execute_powershell]
		@Command = N'Install-Module AWS.Tools.S3 -Force -Scope CurrentUser | ConvertTo-Xml -As Stream;',
		@SerializedXmlOutput = @commandResults OUTPUT, 
		@ErrorMessage = @errorText OUTPUT;

	IF @returnValue = 0 BEGIN 
		SET @commandResults = NULL;	
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = N'Import-Module -Name AWS.Tools.S3;',
			@SerializedXmlOutput = @commandResults OUTPUT, 
			@ErrorMessage = @errorText OUTPUT;		

		IF @returnValue = 0 BEGIN 
			PRINT 'AWS.Tools.S3 Module Installed.';
		  END;
		ELSE BEGIN 
			RAISERROR(N'Install-Module Failure. Install-Module did NOT throw errors during installation, but AWS.Tools.S3 is NOT available.', 16, 1);
			RETURN -20;
		END;
	  END;
	ELSE BEGIN 
		RAISERROR(N'Unexpected Error Installing Module AWS.Tools.S3: %s', 16, 1, @errorText);
		RETURN -40;
	END;
			
	RETURN 0;
GO