
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



*/

USE [admindb];
GO


IF OBJECT_ID('dbo.settings','U') IS NULL BEGIN

	CREATE TABLE dbo.settings (
		setting_key sysname NOT NULL, 
		setting_value sysname NOT NULL, 
		CONSTRAINT PK_settings PRIMARY KEY CLUSTERED (setting_key)
	);

END;

