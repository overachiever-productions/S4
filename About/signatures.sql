
/*
	v4.7.2556.1
		Signatures.


*/

EXEC [admindb].dbo.[backup_databases]
    @BackupType = N'',    -- FULL | DIFF | LOG
    @DatabasesToBackup = N'',  
    --@DatabasesToExclude = N'', 
    --@Priorities = N'',		-- N'first, *, last'
    @BackupDirectory = N'[DEFAULT]', 
    @CopyToBackupDirectory = N'', 
    @BackupRetention = N'', 
    @CopyToRetention = N'', 
    --@RemoveFilesBeforeBackup = 0, 
    --@EncryptionCertName = N'', 
    --@EncryptionAlgorithm = N'',   -- N'AES_256'
    --@AddServerNameToSystemBackupPath = 0, 
    --@AllowNonAccessibleSecondaries = 0, 
    --@LogSuccessfulOutcomes = 0,  
    --@OperatorName = N'Alerts', 
    --@MailProfileName = N'General', 
    --@EmailSubjectPrefix = N'', 
    @PrintOnly = 0;


EXEC [admindb].[dbo].[restore_databases]
    @DatabasesToRestore = N'', -- options include: N'dbname1, dbname2, dbnameN, etc' | N'[READ_FROM_FILESYSTEM]' i.e., iterate over @BackupsRootPath and restore a backup for each db found (unless excluded by @DatabasesToExclude). 
    @DatabasesToExclude = N'', 
    @Priorities = N'', -- N'dbName3, dbname2, *, dbnameTest' -- where anything 'before' the * is prioritized (in order) for priority restore operations, anything not explicitly defined is 'covered' by * and done alphabetically, and anything 'after' * is lowest priority... 
    @BackupsRootPath = N'', 
    @RestoredRootDataPath = N'',  
    @RestoredRootLogPath = N'',  
    @RestoredDbNamePattern = N'{0}_test',  -- {0} is replaced by name of source db 
    @AllowReplace = N'', -- must be N'REPLACE' if you want to ALLOW db to be replaced. 
    @SkipLogBackups = 0,  
    @ExecuteRecovery = 1,  
    @CheckConsistency = 1,  
    @DropDatabasesAfterRestore = 0,  
    @MaxNumberOfFailedDrops = 0, 
    --@OperatorName = N'Alerts', 
    --@MailProfileName = N'General', 
    --@EmailSubjectPrefix = N'', 
    @PrintOnly = 1;  



EXEC [admindb].[dbo].[list_processes]
    @TopNRows = 20,   -- if @TopNRows > 0 then SELECT TOP (@TopNRows) otherwise, SELECT ALL rows...  
    @OrderBy = N'CPU',    -- CPU | READS | WRITES | DURATION | RAM
    @IncludePlanHandle = 1,  
    @IncludeIsolationLevel = 0,  
    --@DetailedMemoryStats = 0,    -- vNEXT
    --@ExcludeMirroringWaits = 1,  -- AG/Mirroring/etc. waites. 
    @ExcludeNegativeDurations = 1,  -- system-level processes, service broker, and rollback ops/etc. 
    @ExcludeFTSDaemonProcesses = 1,  
    @ExcludeSystemProcesses = 1,  -- exclude spids < 50
    @ExcludeSelf = 1;  



