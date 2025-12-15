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
	DECLARE @errorContext nvarchar(MAX);
	EXEC dbo.[execute_per_database]
		@Databases = @databases,
		@Priorities = @priorities,
		@Statement = @sql,
		@Errors = @errors OUTPUT; 

	IF @errors IS NOT NULL BEGIN 
		SET @errorContext = N'Unexpected error extracting CLR Assemblies per database: ';
		GOTO ErrorDetails;
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

ErrorDetails:
	DECLARE @errorDetails nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @crlftab nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	SELECT 
		@errorDetails = @errorDetails + N'DATABASE: ' + QUOTENAME([database_name]) 
		+ @crlftab + N'ERROR_MESSAGE: ' + REPLACE([error_message], @crlf, @crlftab)
		+ @crlftab + [statement] 
		+ @crlf
	FROM 
		dbo.[execute_per_database_errors](@errors)
	ORDER BY 
		[error_id];

	RAISERROR(@errorContext, 16, 1);
	EXEC dbo.[print_long_string] @errorDetails;	
	RETURN -100;

GO