/*

	DEPENDENCIES:
		- None (other than that Mirroring or AGs should be set up/running against targeted databases).


	NOTES:
		- This UDF is required for BACKUPS processing as well as sync-checks. 

		- This UDF is roughly patterned after a similiar piece of functionality provided for AlwaysOn Availability Groups:
			http://msdn.microsoft.com/en-us/library/hh710053.aspx

		- If you pass in the name of a database that does NOT exist (i.e., if you want to check on a db named "MyDB" but specify "MyyDB" instead), 
			this UDF will NOT throw an error NOR will it return TRUE. It'll, instead, return false. 
				This is BY DESIGN (i.e., same as with the UDF for AGs): https://connect.microsoft.com/SQLServer/feedback/details/712548/sys-fn-hadr-backup-is-preferred-replica-returns-1-of-database-does-not-exists

	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple


	TODO:
		- evaluate if this is needed anymore: 

					CREATE FUNCTION dbo.fn_is_ag_primary_replica (@AGName sysname)
					RETURNS bit 
					AS
						BEGIN 
		
							DECLARE @PrimaryReplica sysname; 

							SELECT @PrimaryReplica = hags.primary_replica 
							FROM 
								sys.dm_hadr_availability_group_states hags
								INNER JOIN sys.availability_groups ag ON ag.group_id = hags.group_id
							WHERE
								ag.name = @AGName;

							IF UPPER(@PrimaryReplica) =  UPPER(@@SERVERNAME)
								RETURN 1; -- primary

							RETURN 0; -- not primary
		
						END; 
					GO

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.is_primary_database','FN') IS NOT NULL
	DROP FUNCTION dbo.is_primary_database;
GO

CREATE FUNCTION dbo.is_primary_database(@DatabaseName sysname)
RETURNS bit
AS
	BEGIN 

		DECLARE @description sysname;
				
		-- Check for Mirrored Status First: 
		SELECT 
			@description = mirroring_role_desc
		FROM 
			sys.database_mirroring 
		WHERE
			database_id = DB_ID(@DatabaseName);
	
		IF @description = 'PRINCIPAL'
			RETURN 1;

		-- Check for AG'd state:
		SELECT 
			@description = 	hars.role_desc
		FROM 
			sys.databases d
			INNER JOIN sys.dm_hadr_availability_replica_states hars ON d.replica_id = hars.replica_id
		WHERE 
			d.database_id = DB_ID(@DatabaseName);
	
		IF @description = 'PRIMARY'
			RETURN 1;
	
		-- if no matches, return 0
		RETURN 0;
	END;
GO