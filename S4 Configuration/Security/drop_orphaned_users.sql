/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.drop_orphaned_users','P') IS NOT NULL
	DROP PROC dbo.[drop_orphaned_users];
GO

CREATE PROC dbo.[drop_orphaned_users]
	@TargetDatabase			sysname,
	@ExcludedUsers			nvarchar(MAX)	= NULL,
	@PrintOnly				bit				= 1					-- defaults to 1 cuz... this is potentially ugly/bad... 

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @ExcludedUsers = NULLIF(@ExcludedUsers, N'');

	DECLARE @ignored table ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[name] sysname NOT NULL
	);

	IF @ExcludedUsers IS NOT NULL BEGIN 
		INSERT INTO @ignored ([name])
		SELECT [result] FROM [dbo].[split_string](@ExcludedUsers, N', ', 1);
	END;

	CREATE TABLE #orphans (
		UserName sysname, 
		UserSID varbinary(85)
	); 

	CREATE TABLE #failures ( 
		UserName sysname, 
		ErrorMessage nvarchar(MAX)
	);	

	DECLARE @sql nvarchar(MAX) = N'EXEC [{db}]..sp_change_users_login ''Report''; ';
	SET @sql = REPLACE(@sql, N'{db}', @TargetDatabase);

	INSERT INTO #orphans (UserName, UserSID)
	EXEC [sys].[sp_executesql]
		@sql;

	IF EXISTS (SELECT NULL FROM @ignored) BEGIN 
		DELETE x 
		FROM 
			[#orphans] x 
			INNER JOIN @ignored i ON [x].[UserName] LIKE i.[name];
	END;

	IF EXISTS (SELECT NULL FROM [#orphans]) BEGIN
		DECLARE @target sysname; 

		DECLARE [fixer] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT UserName FROM [#orphans];
		
		OPEN [fixer];
		FETCH NEXT FROM [fixer] INTO @target;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			BEGIN TRY 
				SET @sql = N'USE [{db}]; 
DROP USER [{user}];';
				SET @sql = REPLACE(@sql,  N'{db}', @TargetDatabase);
				SET @sql = REPLACE(@sql, N'{user}', @target);

				IF @PrintOnly = 1 BEGIN 
					PRINT @sql; 
					PRINT N'GO';
					PRINT N'';
				  END; 
				ELSE BEGIN
					EXEC sp_executesql 
						@sql;
				END;

			END TRY 
			BEGIN CATCH 
				INSERT INTO [#failures] ([UserName], [ErrorMessage])
				VALUES (@target, ERROR_MESSAGE());
			END CATCH
			
			FETCH NEXT FROM [fixer] INTO @target;
		END;
		
		CLOSE [fixer];

	END;

	IF EXISTS (SELECT NULL FROM [#failures]) BEGIN 
		SELECT 
			[UserName] [NON-REPAIRED-ORPHAN],
			[ErrorMessage] [ERROR]
		FROM 
			[#failures] 
		ORDER BY 
			[UserName];
	END;

	RETURN 0;
GO