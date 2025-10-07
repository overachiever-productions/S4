/*
	
	CONTEXT
		Rather than forcing a checksum each time that a file (which is PROBABLY already in place - and fine), 'cache' or 'trust'
			the [last_deployed] value in dbo.code_library. 


	SECURITY
		Technically, there's a seeming attack vector here. 
			Specifically: 
				- an actor could replace, say, admindb.core.ps1 (which is signed) with their own bad/nasty code. 
				- and... by allowing (by default) up to a week of 'trusting' ONLY the [last_deployed] column in 
					dbo.code_library ... we're now giving said bad actor a week to let their bad code do all 
					sorts of things. 
			Only: 
				- The above is EFFECTIVELY moot. 
				- We COULD force a (semi-resource-intensive) HASH/CHECKSUM of the file EVERY, SINGLE, TIME we want to run it. 
				- EXCEPT: 
					- a bad actor could shove their own file/varbinary(MAX) into dbo.code_library.code. 
					- AND update the HASH accordingly. 
					We'd then, dutifully, check the HASH every time we wanted to 'dot include' and ... be no safer than we are 
					with this 'caching' / 'trust' trick. 
			Translation: 
				- Code Signing and other security measures are the only, real, way to protect against exploits. 
				-	And, arguably, "Code Library" is making it easier for attackers to exploit things. 
				-		and, i think that's TRUE. 
				-			BUT, someone with sysadmin could already wreak havoc across as well - LIMITED to whatever PERMS their SQL Server Service account has. 

				

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[verify_codelibrary_file]','P') IS NOT NULL
	DROP PROC dbo.[verify_codelibrary_file];
GO

CREATE PROC dbo.[verify_codelibrary_file]
	@Key					sysname, 
	@CacheDuration			sysname			= N'1 week'
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @CacheDuration = ISNULL(NULLIF(@CacheDuration, N''), N'1 week');

	DECLARE @olderThan datetime, @error nvarchar(MAX);
	EXEC [dbo].[translate_vector_datetime]
		@Vector = @CacheDuration,
		@Operation = N'SUBTRACT',
		@ValidationParameterName = '@CacheDuration',
		@Output = @olderThan OUTPUT,
		@Error = @error OUTPUT;
	
	DECLARE @lastDeployed datetime = (SELECT [last_deployed] FROM dbo.[code_library] WHERE [library_key] = @Key);

	-- TODO: I probably DON'T need the check against MAX(version_history) ... as I TRUNCATE dbo.code_library each deployment. 
	IF (@lastDeployed IS NULL) OR (@lastDeployed < @olderThan) OR (@lastDeployed < (SELECT MAX([deployed]) FROM dbo.[version_history])) BEGIN
		EXEC dbo.[deploy_codelibrary_file] @Key = @Key;
	END;

	RETURN 0;
GO

