/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[nonsafe_clr_assemblies]','P') IS NOT NULL
	DROP PROC dbo.[nonsafe_clr_assemblies];
GO

CREATE PROC dbo.[nonsafe_clr_assemblies]
	@databases						nvarchar(MAX)		= N'{USER}', 
	@priorities						nvarchar(MAX)		= NULL, 
	@serialized_output				xml					= N'<default/>'	    OUTPUT	
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	CREATE TABLE [#assemblies] (
		[row_id] int IDENTITY(1,1) NOT NULL,
		[database_name] sysname NOT NULL, 
		[name] sysname NOT NULL, 
		[clr_name] nvarchar(4000) NOT NULL, 
		[permissions] nvarchar(60) NOT NULL, 
		[create_date] datetime NOT NULL
	);
	
	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}];
	INSERT INTO [#assemblies] ([database_name], [name], [clr_name], [permissions], [create_date])
	SELECT N''[{CURRENT_DB}]'' [database_name], [name], [clr_name], [permission_set_desc], [create_date] FROM [sys].[assemblies]; ';

    DECLARE @errors xml;
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Priorities = @priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT; 

	IF @errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected error. See [Errors] XML for more details.', 16, 1);
		SELECT @errors;
		RETURN -100;
	END;

	DELETE FROM [#assemblies]
	WHERE 
		[clr_name] LIKE N'microsoft.sqlserver.types, version=%.0.0.0, culture=neutral, publickeytoken=%, processorarchitecture=msil' AND [name] = N'Microsoft.SqlServer.Types';

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		
		SELECT @serialized_output = (
			SELECT 
				[database_name],
				[name],
				[clr_name],
				[permissions],
				[create_date] 
			FROM 
				[#assemblies]
			WHERE 
				UPPER([permissions]) <> N'SAFE_ACCESS'
			ORDER BY 
				[row_id]
			FOR XML PATH(N'assembly'), ROOT(N'assemblies'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[database_name],
		[name],
		[clr_name],
		[permissions],
		[create_date] 
	FROM 
		[#assemblies]
	WHERE 
		UPPER([permissions]) <> N'SAFE_ACCESS'
	ORDER BY 
		[row_id];

	RETURN 0;
GO