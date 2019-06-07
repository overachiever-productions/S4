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

		- KEY: advanced_s4_error_handling
			Acceptable Values: N'0' or N'1'.
			DEFAULT: when not present or not explicitly set to 1, then the default is N'0' (not enabled). 
				When NOT enabled, then advanced functionality (i.e., advanced error handling) needed for execution of backups, restore-tests, and so on is NOT available.

		- KEY: [DEV]

		- KEY: [TEST]


		- KEY: Data Restore Path for [dbname] to [dbname_test]
			under consideration. The idea though, being that i could 
				a) define this for a database using RestoreNamePattern 'stuff' in the form of {0} (source) and {0}N  (target).. 			
				b) use a token for @DataRootPath of sometghing like [SETTINGS]... 
				and ... this'd go look things up by the KEY matching the convention defined above... 


		- KEY: Log Restore Path for [dbname] to [dbname_test]
			under consideration - same as above though. 


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

            CREATE CLUSTERED INDEX CLIX_settings ON dbo.[settings] ([setting_key], [setting_id]);

            DECLARE @insertFromOriginal nvarchar(MAX) = N'INSERT INTO dbo.settings (setting_type, setting_key, setting_value) 
			SELECT 
				N''UNIQUE'' [setting_type], 
				[setting_key], 
				[setting_value]
			FROM 
				[#settings]
			ORDER BY 
				[row_id]; ';

            EXEC sp_executesql @insertFromOriginal;
			
		COMMIT;

        IF OBJECT_ID(N'tempdb..#settings') IS NOT NULL 
            DROP TABLE [#settings];
	END;
END;
GO

-- 6.0: 'legacy enable' advanced S4 error handling from previous versions if not already defined: 
IF EXISTS (SELECT NULL FROM dbo.[version_history]) BEGIN

	IF NOT EXISTS(SELECT NULL FROM dbo.[settings] WHERE [setting_key] = N'advanced_s4_error_handling') BEGIN
		INSERT INTO dbo.[settings] (
			[setting_type],
			[setting_key],
			[setting_value],
			[comments]
		)
		VALUES (
			N'UNIQUE', 
			N'advanced_s4_error_handling', 
			N'1', 
			N'Legacy Enabled (i.e., pre-v6 install upgraded to 6/6+)' 
		);
	END;
END;