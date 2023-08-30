/*

	NOTE/WARN: this is VERY rough draft. It works for happy-path only scenarios... 


	


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.aws3_initialize_profile','P') IS NOT NULL
	DROP PROC dbo.[aws3_initialize_profile];
GO

CREATE PROC dbo.[aws3_initialize_profile]
	@AwsRegion					sysname, 
	@AwsAccessKey				sysname, 
	@AwsSecretKey				sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	EXEC dbo.[verify_advanced_capabilities];

	-- Make sure we don't have an EC2-InstanceProfile already in place... 

	-- Also, since this is INITIALIZE... make sure we don't already have a default profile in place... 


	-- otherwise, if the above aren't an issue... 
	-- configure the creds... 


	-- TODO: 
	--		make sure that AWS.Tools.S3 is installed. 
	--		and... since I'm going to be doing this in aws3_initialize_profile, aws3_set_profile_stuff (i.e., update/edit/modify), remove_profile, and LIST_BUCKETS and so on... 
	--		weaponize this into dbo.aws3_verify_configuration or whatever... with switches to verify: 
	--						a. network/plumbing and nuget versions (not always - Nuget could be out of date and someone could manually install S3)
	--						b. S3 module installed/import-able. 
	--						c. profiles defined... 
	--						d. buckets? 
	--		with the idea that I can use the REUSABLE logic in the above for various bits of functionality INCLUDING setup/configuration and ... verifying stuff before backups/cleanup/etc. 


	DECLARE @returnValue int; 
	DECLARE @errorMessage nvarchar(MAX); 
	DECLARE @commandResults xml;

	DECLARE @currentCommand nvarchar(MAX) = N'Initialize-AWSDefaultConfiguration -Region ''{region}'' -AccessKey ''{key}'' -SecretKey ''{secret}'';'
	SET @currentCommand = REPLACE(@currentCommand, N'{region}', @AwsRegion);
	SET @currentCommand = REPLACE(@currentCommand, N'{key}', @AwsAccessKey);
	SET @currentCommand = REPLACE(@currentCommand, N'{secret}', @AwsSecretKey);

	BEGIN TRY 
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = @currentCommand,
			@SerializedXmlOutput = @commandResults OUTPUT, 
			@ErrorMessage = @errorMessage OUTPUT;		

-- TODO: 
	-- do i need to parse @commandResults and look for any kind of error? or... more importantly, some kind of success? 
	--	YES... i do... cuz imagine that someone called this sproc with this signature:  
		--				EXEC [admindb].dbo.[aws3_initialize_profile] 
		--					@AwsRegion = N'us-west-2', 
		--					@AwsAccessKey = N'', 
		--					@AwsSecretKey = N'';


		SELECT @commandResults [Initialize_AWSDefaultConfig_resutls];

	END TRY 
	BEGIN CATCH 
		SET @errorMessage = N'Unexpected Error Initializing AWS Default Profile. Error: ' + CAST(ERROR_NUMBER() AS sysname) + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -10;
	END CATCH;

	IF @returnValue <> 0 OR @errorMessage IS NOT NULL BEGIN 
		SET @errorMessage = N'PowerShell Error: ' + @errorMessage;
		RAISERROR(@errorMessage, 16, 1);
		RETURN -12;
	END;

	-- get the creds and spit them out ... 
-- TODO: implement this to be more programatic:
	EXEC dbo.[execute_powershell]
		@Command = N'Get-AWSCredential -ListProfileDetail;'; 

	RETURN 0;
GO
	