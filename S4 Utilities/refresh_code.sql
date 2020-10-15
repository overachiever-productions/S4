/*
	OVERVIEW:
		Wrapper around calls to sp_refreshview and sp_refreshmodule - to enable quick/easy 'refresh of ALL code'. 

	NOTES: 
		- DOES NOT target DDL triggers. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.refresh_code','P') IS NOT NULL
	DROP PROC dbo.[refresh_code];
GO

CREATE PROC dbo.[refresh_code]
	@Mode						sysname			= N'VIEWS_AND_MODULES',				-- { VIEWS_AND_MODULES | VIEWS | MODULES }
	@TargetDatabase				sysname			= NULL, 
	@PrintOnly					bit				= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Mode = ISNULL(NULLIF(@Mode, N''), N'VIEWS_AND_MODULES');

	IF UPPER(@Mode) NOT IN (N'VIEWS_AND_MODULES', N'VIEWS', N'MODULES') BEGIN 
		RAISERROR(N'Invalid value specified for @Mode. Acceptable values are { VIEWS_AND_MODULES | VIEWS | MODULES }.', 16, 1);
		RETURN -1;
	END;

	-- establish database (if null) and/or verify that @Target database exists. 
	IF @TargetDatabase IS NULL BEGIN 
		EXEC dbo.[get_executing_dbname] @ExecutingDBName = @TargetDatabase OUTPUT;
		
		IF @TargetDatabase IS NULL BEGIN 
			RAISERROR('Invalid Database-Name specified and/or S4 was unable to determine calling-db-context. ', 16, 1);
			RETURN -5;
		END;
	END;

	DECLARE @command nvarchar(MAX);
	DECLARE @schemaId int;
	DECLARE @objectName sysname;

	IF UPPER(@Mode) IN (N'VIEWS_AND_MODULES', N'VIEWS') BEGIN 

		DECLARE refresher CURSOR LOCAL FAST_FORWARD FOR 
		SELECT [schema_id], [name]
		FROM sys.objects WHERE [type] = 'V';

		DECLARE @ErrorNumber int, @ErrorLine int, @ErrorProcedure nvarchar(126), @ErrorMessage nvarchar(2048);

		OPEN refresher;
		FETCH NEXT FROM refresher INTO @schemaId, @objectName;
		WHILE @@FETCH_STATUS = 0 BEGIN

			SET @command = N'EXEC sp_refreshview ''' + SCHEMA_NAME(@schemaId) + '.' + @objectName + ''' ';
		
			BEGIN TRY
				
				IF @PrintOnly = 1 BEGIN 
					PRINT @command;
				  END;
				ELSE BEGIN
					BEGIN TRAN;    
					EXEC sp_executesql @command;
					COMMIT;
				END;
			END TRY
			BEGIN CATCH
			      
				SELECT @ErrorNumber = ERROR_NUMBER(), @ErrorLine = ERROR_LINE(), @ErrorProcedure = ERROR_PROCEDURE(), @ErrorMessage = ERROR_MESSAGE();    
				PRINT 'REFRESH OF VIEW: ' + DB_NAME() + '.' + SCHEMA_NAME(@schemaId) + '.' + @objectName + ' Failed. -> Error: ' + @ErrorMessage;
				ROLLBACK;
			END CATCH      

			FETCH NEXT FROM refresher INTO @schemaId, @objectName;
		END

		CLOSE refresher;
		DEALLOCATE refresher;

	END;

	IF UPPER(@Mode) IN (N'VIEWS_AND_MODULES', N'MODULES') BEGIN 

		DECLARE [refresher2] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT
			[o].[schema_id],
			[o].[name]
		FROM
			[sys].[sql_modules] [m]
			INNER JOIN [sys].[objects] [o] ON [m].[object_id] = [o].[object_id];

	
		OPEN [refresher2];
		FETCH NEXT FROM [refresher2] INTO @schemaId, @objectName;
	
		WHILE @@FETCH_STATUS = 0 BEGIN
	
			SET @command = N'EXEC sp_refreshsqlmodule ''' + SCHEMA_NAME(@schemaId) + '.' + @objectName + ''' ';
	
				BEGIN TRY
				
					IF @PrintOnly = 1 BEGIN 
						PRINT @command;
					  END;
					ELSE BEGIN
						BEGIN TRAN;    
						EXEC sp_executesql @command;
						COMMIT;
					END;
				END TRY
				BEGIN CATCH
			      
					SELECT @ErrorNumber = ERROR_NUMBER(), @ErrorLine = ERROR_LINE(), @ErrorProcedure = ERROR_PROCEDURE(), @ErrorMessage = ERROR_MESSAGE();    
					PRINT 'REFRESH OF MODULE: ' + DB_NAME() + '.' + SCHEMA_NAME(@schemaId) + '.' + @objectName + ' Failed. -> Error: ' + @ErrorMessage;
					ROLLBACK;
				END CATCH 

			FETCH NEXT FROM [refresher2] INTO @schemaId, @objectName;
		END;
	
		CLOSE [refresher2];
		DEALLOCATE [refresher2];

	END;

	RETURN 0;
GO