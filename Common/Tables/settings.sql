/*
	PURPOSE: 
		- S4 favors convention over configuration. 
			However, to streamline and simplify configuration, a number of key settings/defaults/values can be changed - system-wide - by means of adding (or modifying)
			a handful of specific settings keys and their values: 

	SETTINGS: 
		
		- KEY: admindb_is_system_db
			Acceptable Values: N'0' or N'1'. 
			DEFAULT: When no row/value has been EXPLICITLY set, then the default for this setting is N'1' (i.e., to treat admindb as a system database). 

		- KEY: default_operator
			Acceptable Values: the name of any SQL Server Agent Operator currently defined on the system (and which you'd like to specify as the Operator to alert when an operator has not been explicitly set (i.e., the 'default operator').
			DEFAULT: When not present, defaults to the value of 'Alerts' (by convention).


		- KEY: default_mail_profile
			Acceptable Values: the name of any Database Mail profiler that is created/accessible to the SQL Server Agent (and which you'd like used as the 'default' profile (i.e., when no profile has been explicitly defined).
			DEFAULT: When not present, defaults to the value of 'General' (by convention).


		- KEY: [DEV]

		- KEY: [TEST]






INSERT INTO [dbo].[settings] (
    [setting_type],
    [setting_key],
    [setting_value],
    [comments]
)
VALUES (
           N'COMBINED', -- setting_type - sysname
           N'[DEV]', -- setting_key - sysname
           N'%login', -- setting_value - sysname
           N'' -- comments - nvarchar(200)
       ), 

	   (

		N'COMBINED', 
		N'[DEV]', 
		N'IdentityDB', 
		N''
		)




*/

USE [admindb];
GO


IF OBJECT_ID('dbo.settings','U') IS NULL BEGIN

	CREATE TABLE dbo.settings (
		setting_id int IDENTITY(1,1) NOT NULL,
		setting_type sysname NOT NULL CONSTRAINT CK_settings_setting_type CHECK ([setting_type] IN (N'UNIQUE', N'COMBINED')),
		setting_key sysname NOT NULL, 
		setting_value sysname NOT NULL,
		comments nvarchar(200) NULL,
		CONSTRAINT PK_settings PRIMARY KEY NONCLUSTERED (setting_id)
	);

	CREATE CLUSTERED INDEX CLIX_settings ON dbo.[settings] ([setting_key], [setting_id]);
  END;
ELSE BEGIN 

	IF NOT EXISTS (SELECT NULL FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.settings') AND [name] = N'setting_id') BEGIN 

		BEGIN TRAN
			SELECT 
				IDENTITY(int, 1, 1) [row_id], 
				setting_key, 
				setting_value 
			INTO 
				#settings
			FROM 
				dbo.[settings];

			DROP TABLE dbo.[settings];

			CREATE TABLE dbo.settings (
				setting_id int IDENTITY(1,1) NOT NULL,
				setting_type sysname NOT NULL CONSTRAINT CK_settings_setting_type CHECK ([setting_type] IN (N'UNIQUE', N'COMBINED')),
				setting_key sysname NOT NULL, 
				setting_value sysname NOT NULL,
				comments nvarchar(200) NULL,
				CONSTRAINT PK_settings PRIMARY KEY NONCLUSTERED (setting_id)
			);

			INSERT INTO dbo.settings (setting_type, setting_key, setting_value) 
			SELECT 
				N'UNIQUE' [setting_type], 
				[setting_key], 
				[setting_value]
			FROM 
				[#settings]
			ORDER BY 
				[row_id];


			CREATE CLUSTERED INDEX CLIX_settings ON dbo.[settings] ([setting_key], [setting_id]);
		COMMIT;
	END;
END;