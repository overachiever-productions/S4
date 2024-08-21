/*
	https://overachieverllc.atlassian.net/browse/S4-565
	BUG: There's an odd bug/scenario where ... 
		- RESTORE HEADER can throw an error 
		- that doesn't REALLY, necessarily, mean that restore-operations relying upon RESTORE HEADER will fail. 

		Specifically:
			- if dbo.load_backup_files is looking for LSNs to determine Last LSN from a FULL|DIFF backup ... 
			- AND, we TRUNCATE the name of the file - e.g., set @BackupPath = LEFT(@BackupPath, 128) - for example... 
			-	then... load_header_details will ... fail - cuz it can't find the file in question. 
			-	but... if the LSNs weren't "important" (i.e., we get 'lucky' and don't have concurrently running LOGs ... 
			-	then... the error gets written out to the SQL Server Agent's history-log/buffer. 
			-		AND, dbo.restore_databases FAILS when all is said and done... because we threw errors. 


		DECLARE @backupDate datetime, @backupSize int, @compressed bit, @encrypted bit;

		EXEC load_header_details 
			@BackupPath = N'D:\SQLBackups\TESTS\Billing\FULL_Billing_backup_2018_02_11_210000_5077665.bak', 
			@BackupDate = @backupDate OUTPUT, 
			@BackupSize = @backupSize OUTPUT, 
			@Compressed = @compressed OUTPUT, 
			@Encrypted = @encrypted OUTPUT;

		SELECT 
			@BackupDate [BackupDate], @BackupSize [Size], @Compressed [Compressed], @Encrypted [Encrypted];

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[load_header_details]','P') IS NOT NULL
	DROP PROC dbo.[load_header_details];
GO

CREATE PROC dbo.[load_header_details] 
	@BackupPath					nvarchar(800),				-- looks like this should be 1024 and varchar? or nvarchar? See - https://www.intel.com/content/www/us/en/support/programmable/articles/000075424.html 
	@SourceVersion				decimal(4,2)	            = NULL,
	@BackupDate					datetime		            OUTPUT, 
	@BackupSize					bigint			            OUTPUT, 
	@Compressed					bit				            OUTPUT, 
	@Encrypted					bit				            OUTPUT, 
	@FirstLSN					decimal(25,0)				= NULL	OUTPUT, 
	@LastLSN					decimal(25,0)				= NULL	OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-- TODO: 
	--		make sure file/path exists... 

	DECLARE @executingServerVersion decimal(4,2);
	SELECT @executingServerVersion = (SELECT dbo.get_engine_version());

	IF NULLIF(@SourceVersion, 0) IS NULL SET @SourceVersion = @executingServerVersion;

	CREATE TABLE #header (
		BackupName nvarchar(128) NULL, -- backups generated by S4 ALWAYS have this value populated - but it's NOT required by SQL Server (obviously).
		BackupDescription nvarchar(255) NULL, 
		BackupType smallint NOT NULL, 
		ExpirationDate datetime NULL, 
		Compressed bit NOT NULL, 
		Position smallint NOT NULL, 
		DeviceType tinyint NOT NULL, --
		Username nvarchar(128) NOT NULL, 
		ServerName nvarchar(128) NOT NULL, 
		DatabaseName nvarchar(128) NOT NULL,
		DatabaseVersion int NOT NULL, 
		DatabaseCreationDate datetime NOT NULL, 
		BackupSize numeric(20,0) NOT NULL, 
		FirstLSN numeric(25,0) NOT NULL, 
		LastLSN numeric(25,0) NOT NULL, 
		CheckpointLSN numeric(25,0) NOT NULL, 
		DatabaseBackupLSN numeric(25,0) NOT NULL, 
		BackupStartDate datetime NOT NULL, 
		BackupFinishDate datetime NOT NULL, 
		SortOrder smallint NULL, 
		[CodePage] smallint NOT NULL, 
		UnicodeLocaleID int NOT NULL, 
		UnicodeComparisonStyle int NOT NULL,
		CompatibilityLevel tinyint NOT NULL, 
		SoftwareVendorID int NOT NULL, 
		SoftwareVersionMajor int NOT NULL, 
		SoftwareVersionMinor int NOT NULL, 
		SoftwareVersionBuild int NOT NULL, 
		MachineName nvarchar(128) NOT NULL, 
		Flags int NOT NULL, 
		BindingID uniqueidentifier NOT NULL, 
		RecoveryForkID uniqueidentifier NULL, 
		Collation nvarchar(128) NOT NULL, 
		FamilyGUID uniqueidentifier NOT NULL, 
		HasBulkLoggedData bit NOT NULL, 
		IsSnapshot bit NOT NULL, 
		IsReadOnly bit NOT NULL, 
		IsSingleUser bit NOT NULL, 
		HasBackupChecksums bit NOT NULL, 
		IsDamaged bit NOT NULL, 
		BeginsLogChain bit NOT NULL, 
		HasIncompleteMetaData bit NOT NULL, 
		IsForceOffline bit NOT NULL, 
		IsCopyOnly bit NOT NULL, 
		FirstRecoveryForkID uniqueidentifier NOT NULL, 
		ForkPointLSN numeric(25,0) NULL, 
		RecoveryModel nvarchar(60) NOT NULL, 
		DifferntialBaseLSN numeric(25,0) NULL, 
		DifferentialBaseGUID uniqueidentifier NULL, 
		BackupTypeDescription nvarchar(60) NOT NULL, 
		BackupSetGUID uniqueidentifier NULL, 
		CompressedBackupSize bigint NOT NULL  -- 2008 / 2008 R2  (10.0  / 10.5)
	);

	IF @SourceVersion >= 11.0 BEGIN -- columns added to 2012 and above:
		ALTER TABLE [#header]
			ADD Containment tinyint NOT NULL; -- 2012 (11.0)
	END; 

	IF @SourceVersion >= 13.0 BEGIN  -- columns added to 2016 and above:
		ALTER TABLE [#header]
			ADD 
				KeyAlgorithm nvarchar(32) NULL, 
				EncryptorThumbprint varbinary(20) NULL, 
				EncryptorType nvarchar(32) NULL;
	END;

	IF @SourceVersion >= 16.0 BEGIN -- columns added to SQL Server 2022 and above: 
		ALTER TABLE [#header]
			ADD 
				LastValidRestoreTime datetime NULL, -- NOT documented as of 2023-01-18 
				TimeZone int NULL,		-- ditto, not documented ... 
				CompressionAlgorithm nvarchar(32) NULL;
	END;

	DECLARE @command nvarchar(MAX); 

	SET @command = N'RESTORE HEADERONLY FROM DISK = N''{0}'';';
	SET @command = REPLACE(@command, N'{0}', @BackupPath);
	
	INSERT INTO [#header] 
	EXEC sp_executesql @command;

	DECLARE @encryptionValue bit = 0;
	IF @SourceVersion >= 13.0 BEGIN

		EXEC sys.[sp_executesql]
			@stmt = N'SELECT @encryptionValue = CASE WHEN EncryptorThumbprint IS NOT NULL THEN 1 ELSE 0 END FROM [#header];', 
			@params = N'@encryptionValue bit OUTPUT',
			@encryptionValue = @encryptionValue OUTPUT; 
	END;

	-- Return Output Details: 
	SELECT 
		@BackupDate = [BackupFinishDate], 
		@BackupSize = CAST((ISNULL([CompressedBackupSize], [BackupSize])) AS bigint), 
		@Compressed = [Compressed], 
		@Encrypted = ISNULL(@encryptionValue, 0), 
		@FirstLSN = [FirstLSN], 
		@LastLSN = [LastLSN]
	FROM 
		[#header];

	RETURN 0;
GO