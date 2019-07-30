/*
	INTERNAL:
        Internal use only - not for callers/consumption by end-users/etc. 
    
    NOTE: 
        - This sproc adheres to the PROJECT/REPLY usage convention.
		
	EXAMPLES: 

			---------------------------------------
			-- expect exception:
				EXEC load_backup_database_names
					@TargetDirectory = NULL;
			
			---------------------------------------
				EXEC load_backup_database_names; 
				GO

			---------------------------------------
				DECLARE @databases xml = NULL;
				EXEC load_backup_database_names
					@TargetDirectory = N'D:\SQLBackups', 
					@SerializedOutput = @databases OUTPUT;
			
				SELECT @databases;
				GO


			---------------------------------------
				DECLARE @databases xml = '';
				EXEC load_backup_database_names
					@TargetDirectory = N'D:\SQLBackups', 
					@SerializedOutput = @databases OUTPUT;
			
				WITH shredded AS ( 
					SELECT 
						[data].[row].value('@id[1]', 'int') [row_id], 
						[data].[row].value('.[1]', 'sysname') [database_name]
					FROM 
						@databases.nodes('//database') [data]([row])
				) 

				SELECT 
					[database_name]
				FROM 
					shredded 
				ORDER BY 
					row_id;
				GO

			---------------------------------------
				DECLARE @databases xml = NULL;
				EXEC load_backup_database_names
					@TargetDirectory = N'D:\SQLBackups', 
					@SerializedOutput = @databases OUTPUT;
			   
                SELECT @databases;

            ---------------------------------------
            -- this might LOOK insane (and might well be) 
            --          but, it's taking serialized XML output and turning it into a serialized LIST of dbs - e.g., 'db1, db7, etc.'... 

                    DECLARE @databases xml = '';
                    EXEC load_backup_database_names
                        @TargetDirectory = N'D:\SQLBackups', 
                        @SerializedOutput = @databases OUTPUT;
            
                    DECLARE @serialized nvarchar(MAX) = N'';
                    WITH shredded AS ( 
                        SELECT 
                            [data].[row].value('@id[1]', 'int') [row_id], 
                            [data].[row].value('.[1]', 'sysname') [database_name]
                        FROM 
                            @databases.nodes('//database') [data]([row])
                    ) 

                    SELECT 
                        @serialized = @serialized + [database_name] + N','
                    FROM 
                        shredded 
                    ORDER BY 
                        row_id;

                    SET @serialized = LEFT(@serialized, LEN(@serialized) - 1);
                    SELECT @serialized;
                    GO


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.load_backup_database_names','P') IS NOT NULL
	DROP PROC dbo.load_backup_database_names;
GO

CREATE PROC dbo.load_backup_database_names 
	@TargetDirectory				sysname				= N'[DEFAULT]',		
	@SerializedOutput				xml					= N'<default/>'					OUTPUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	-- EXEC dbo.verify_advanced_capabilities;	

	-----------------------------------------------------------------------------
	-- Validate Inputs: 
	IF UPPER(@TargetDirectory) = N'[DEFAULT]' BEGIN
		SELECT @TargetDirectory = dbo.load_default_path('BACKUP');
	END;

	IF @TargetDirectory IS NULL BEGIN;
		RAISERROR('@TargetDirectory must be specified - and must point to a valid path.', 16, 1);
		RETURN - 10;
	END

	DECLARE @isValid bit;
	EXEC dbo.check_paths @TargetDirectory, @isValid OUTPUT;
	IF @isValid = 0 BEGIN
		RAISERROR(N'Specified @TargetDirectory is invalid - check path and retry.', 16, 1);
		RETURN -11;
	END;

	-----------------------------------------------------------------------------
	-- load databases from path/folder names:
	DECLARE @target_databases TABLE ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL
	); 

	DECLARE @directories table (
		row_id int IDENTITY(1,1) NOT NULL, 
		subdirectory sysname NOT NULL, 
		depth int NOT NULL
	);

    INSERT INTO @directories (subdirectory, depth)
    EXEC master.sys.xp_dirtree @TargetDirectory, 1, 0;

    INSERT INTO @target_databases ([database_name])
    SELECT subdirectory FROM @directories ORDER BY row_id;

	-- NOTE: if @AddServerNameToSystemBackupPath was added to SYSTEM backups... then master, model, msdb, etc... folders WILL exist. (But there won't be FULL_<dbname>*.bak files in those subfolders). 
	--		In this sproc we WILL list any 'folders' for system databases found (i.e., we're LISTING databases - not getting the actual backups or paths). 
	--		However, in dbo.restore_databases if the @TargetPath + N'\' + @dbToRestore doesn't find any files, and @dbToRestore is a SystemDB, we'll look in @TargetPath + '\' + @ServerName + '\' + @dbToRestore for <backup_type>_<db_name>*.bak/.trn etc.)... 

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY initialized as NULL/empty... then REPLY... 
		SELECT @SerializedOutput = (SELECT 
			[row_id] [database/@id],
			[database_name] [database]
		FROM 
			@target_databases
		ORDER BY 
			[row_id] 
		FOR XML PATH(''), ROOT('databases'));

		RETURN 0;
	END; 

	-----------------------------------------------------------------------------
	-- otherwise, project:

	SELECT 
		[database_name]
	FROM 
		@target_databases
	ORDER BY 
		[row_id];

	RETURN 0;
GO


