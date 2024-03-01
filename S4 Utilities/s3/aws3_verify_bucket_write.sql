/*

	.EXAMPLE
		EXEC [admindb].dbo.[aws3_verify_bucket_write] 
			@TargetBucketName = N's4-tests', 
			@TestKey = N'ooink';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[aws3_verify_bucket_write]','P') IS NOT NULL
	DROP PROC dbo.[aws3_verify_bucket_write];
GO

CREATE PROC dbo.[aws3_verify_bucket_write]
	@TargetBucketName		sysname, 
	@TestKey				sysname				
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
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

	-- verify that target bucket exists:
	BEGIN TRY 
		SET @currentCommand = N'Get-S3Bucket -BucketName "' + RTRIM(LTRIM(@TargetBucketName)) + N'"';
		DECLARE @stringOutput nvarchar(MAX);
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = @currentCommand,
			@StringOutput = @stringOutput OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;
		
		IF NULLIF(@stringOutput, N'') IS NULL BEGIN 
			RAISERROR(N'@TargetBucketName: [%s] does not exist.', 16, 1, @TargetBucketName);
			RETURN -20;
		END;

	END TRY
	BEGIN CATCH 
		SET @errorMessage = N'Unexpected Error Validating @TargetBucketName: [' + @TargetBucketName + N']. Error ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -22;
	END CATCH;

	SET @currentCommand = N'Write-S3Object -BucketName ''' + RTRIM(LTRIM(@TargetBucketName)) + N''' -Key ''' + @TestKey + N''' -Content ''Test Data - for Write-Test by admindb.'' -ConcurrentServiceRequest 2;';
	PRINT @currentCommand;
	PRINT N'';

	BEGIN TRY 
		EXEC @returnValue = dbo.[execute_powershell]
			@Command = @currentCommand,
			@ExecutionAttemptsCount = 0,
			@StringOutput = @stringOutput OUTPUT,
			@ErrorMessage = @errorMessage OUTPUT;

		-- NOTE: if the error contains the text: "The bucket you are attempting to access must be addressed using the specified endpoint. Please send all future requests to this endpoint." 
		--		then ... the bucket does exist - but it's in a DIFFERENT AWS REGION than the one specified as the default AWS Region in the PROFILE being used. 
		-- there MIGHT be a 'fix' for this where you specify the FULLY qualified name of the bucket - something like: <bucketname>.s3-<region-name>.amazonaws.com. 
		--		some indications of POTENTIAL for this via this link: https://github.com/thoughtbot/paperclip/issues/2151 
		--		only I can't get it to work. 
		--		that said, CloudBerry Explorer shows that this format apparently works: https://emergencytransfer.s3.us-east-2.amazonaws.com/ 
		--			though, i'm guessing i don't need the https:// ? 
		--		only, when I TRY that I get "specified bucket does not exist". 
		--			here's an example: Write-S3Object -BucketName "emergencytransfer.s3.us-east-2.amazonaws.com" -Key "ooink" -Content "Test Content - for Write-Test by admindb." -ConcurrentServiceRequest 2;
		--		and, if I put "https://" in the bucket name ... i get: "The specified bucket is not valid". 
	END TRY 
	BEGIN CATCH 
		SET @errorMessage = N'Unexpected Error Executing Write-S3Object: Error ' + CAST(ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
		RAISERROR(@errorMessage, 16, 1);
		RETURN -32;
	END CATCH;

	IF @errorMessage IS NOT NULL BEGIN 
		RAISERROR(N'Error: %s', 16, 1, @errorMessage); 
		RETURN -40;
	END;

	EXEC dbo.[print_long_string] @stringOutput;

	RETURN 0;
GO