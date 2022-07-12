
USE [admindb];
GO

IF TYPE_ID('dbo.backup_history_entry') IS NOT NULL 
	DROP TYPE dbo.backup_history_entry;
GO

CREATE TYPE dbo.backup_history_entry AS TABLE (
	[execution_id] uniqueidentifier NULL,
	[backup_date] date NULL,
	[database] sysname NULL,
	[backup_type] sysname NULL,
	[backup_path] nvarchar(1000) NULL,
	[copy_path] nvarchar(1000) NULL,
	[offsite_path] nvarchar(1000) NULL,
	[backup_start] datetime NULL,
	[backup_end] datetime NULL,
	[backup_succeeded] bit NULL,
	[verification_start] datetime NULL,
	[verification_end] datetime NULL,
	[verification_succeeded] bit NULL,
	[copy_succeeded] bit NULL,
	[copy_seconds] int NULL,
	[failed_copy_attempts] int NULL,
	[copy_details] nvarchar(max) NULL,
	[offsite_succeeded] bit NULL,
	[offsite_seconds] int NULL,
	[failed_offsite_attempts] int NULL,
	[offsite_details] nvarchar(max) NULL,
	[error_details] nvarchar(max) NULL
);
GO