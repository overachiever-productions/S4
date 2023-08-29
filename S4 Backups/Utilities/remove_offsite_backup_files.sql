/*
	

	NOTES:
        - This sproc adheres to the PROJECT/REPLY usage convention.

		- WARNING: This script does what it says - it'll remove OFFSITE files exactly as specified. 

		- Not yet documented. 	

		- Similar to dbo.remove_backup_files but, obviously, for offsite backups (i.e., requires different implementation logic). 

		- Unlike LOCAL backup removal operations - where we check the header of the file, dbo.remove_offsite_backup_files 
			ONLY checks/evaluates the FILE-name (since it would be impractical to 'pull down' and 'header-check' each remote file).

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.remove_offsite_backup_files','P') IS NOT NULL
	DROP PROC dbo.[remove_offsite_backup_files];
GO

CREATE PROC dbo.[remove_offsite_backup_files]
	@BackupType							sysname,														-- { ALL|FULL|DIFF|LOG }
	@DatabasesToProcess					nvarchar(1000),													-- { {READ_FROM_FILESYSTEM} | name1,name2,etc }
	@DatabasesToExclude					nvarchar(600)				= NULL,								-- { NULL | name1,name2 }  
	@OffSiteBackupPath					nvarchar(2000)				= NULL,								-- { path_to_backups }
	@OffSiteRetention					nvarchar(10),													-- #n  - where # is an integer for the threshold, and n is either m, h, d, w, or b - for Minutes, Hours, Days, Weeks, or B - for # of backups to retain.
	@ServerNameInSystemBackupPath		bit							= 0,								-- for mirrored servers/etc.
	@SendNotifications					bit							= 0,								-- { 0 | 1 } Email only sent if set to 1 (true).
	@OperatorName						sysname						= N'Alerts',		
	@MailProfileName					sysname						= N'General',
	@EmailSubjectPrefix					nvarchar(50)				= N'[OffSite Backups Cleanup ] ',
    @Output								nvarchar(MAX)				= N'default' OUTPUT,				-- When explicitly set to NULL, summary/errors/output will be 'routed' into this variable instead of emailed/raised/etc.
	@PrintOnly							bit							= 0 								-- { 0 | 1 }

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF UPPER(@OffSiteRetention) = N'{INFINITE}' BEGIN 
		PRINT N'-- {INFINITE} retention detected. Terminating off-site cleanup process.';
		RETURN 0; -- success
	END;

	RAISERROR(N'NON-INFINITE Retention-cleanup off OffSite Backup Copies is not yet implemented.', 16, 1);
	RETURN -100;
GO
