
/*
	v 4.0.1.16756
		Signatures.


*/


EXEC admindb.dbo.backup_databases
    @BackupType = NULL, 
    @DatabasesToBackup = N'', 
    @DatabasesToExclude = N'', 
    @Priorities = N'', 
    @BackupDirectory = N'', 
    @CopyToBackupDirectory = N'', 
    @BackupRetention = N'', 
    @CopyToRetention = N'', 
    @RemoveFilesBeforeBackup = NULL, 
    @EncryptionCertName = NULL, 
    @EncryptionAlgorithm = NULL, 
    @AddServerNameToSystemBackupPath = NULL, 
    @AllowNonAccessibleSecondaries = NULL, 
    @LogSuccessfulOutcomes = NULL, 
    @OperatorName = NULL, 
    @MailProfileName = NULL, 
    @EmailSubjectPrefix = N'', 
    @PrintOnly = NULL; 



EXEC admindb.dbo.restore_databases
    @DatabasesToRestore = N'', 
    @DatabasesToExclude = N'', 
    @Priorities = N'', 
    @BackupsRootPath = N'', 
    @RestoredRootDataPath = N'', 
    @RestoredRootLogPath = N'', 
    @RestoredDbNamePattern = N'', 
    @AllowReplace = N'', 
    @SkipLogBackups = NULL, 
    @CheckConsistency = NULL, 
    @DropDatabasesAfterRestore = NULL, 
    @MaxNumberOfFailedDrops = 0, 
    @OperatorName = NULL, 
    @MailProfileName = NULL, 
    @EmailSubjectPrefix = N'', 
    @PrintOnly = NULL; 

