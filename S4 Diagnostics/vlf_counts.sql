/*

	TODO: 
		Implement an additional sproc - probably one that replaces this called dbo.vlf_details. 
		Replacement will: 
			- have an @Mode that allows summary or detail as the options. 
			- when in detail... just, effectively, 'dump' #LogInfo2 - along with any sizing details or whatever - and any other KEY details. 
			- when in summary: 
				output: 
					- counts
					- max size
					- min size 
					- avg size. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[vlf_counts]','P') IS NOT NULL
	DROP PROC dbo.[vlf_counts];
GO

CREATE PROC dbo.[vlf_counts]
	@Databases				nvarchar(MAX)		= N'{ALL}', 
	@Priorities				nvarchar(MAX)		= NULL, 
	@SerializedOutput		xml					= N'<default/>'		OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Databases = ISNULL(NULLIF(@Databases, N''), N'{ALL}');
	SET @Priorities = NULLIF(@Priorities, N'');

	CREATE TABLE #LogInfo (
		RecoveryUnitId bigint NOT NULL,
		FileID bigint NOT NULL,
		FileSize bigint NOT NULL,
		StartOffset bigint NOT NULL,
		FSeqNo bigint NOT NULL,
		Status bigint NOT NULL,
		Parity bigint NOT NULL,
		CreateLSN varchar(50) NOT NULL
	);

	CREATE TABLE #LogInfo2 (
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		RecoveryUnitId bigint NOT NULL,
		FileID bigint NOT NULL,
		FileSize bigint NOT NULL,
		StartOffset bigint NOT NULL,
		FSeqNo bigint NOT NULL,
		Status bigint NOT NULL,
		Parity bigint NOT NULL,
		CreateLSN varchar(50) NOT NULL
	);

	DECLARE @sql nvarchar(MAX) = N'USE [{CURRENT_DB}];
INSERT INTO #LogInfo EXECUTE (''DBCC LOGINFO() WITH NO_INFOMSGS;''); 

INSERT INTO #LogInfo2 SELECT N''{CURRENT_DB}'' [database_name], * FROM #LogInfo;
DELETE FROM #LogInfo;';

	DECLARE @Errors xml;
	EXEC dbo.[execute_per_database]
		@Databases = @Databases,
		@Priorities = @Priorities,
		@Statement = @sql,
		@Errors = @Errors OUTPUT;


	IF @Errors IS NOT NULL BEGIN 
		RAISERROR(N'Unexpected Errors during Execution. See (Printed) @Errors for additional details.', 16, 1);
		EXEC dbo.[print_long_string] @Errors;
		RETURN -3; 
	END;

	CREATE TABLE #results ( 
		[row_id] int IDENTITY(1,1) NOT NULL, 
		[database_name] sysname NOT NULL, 
		[vlf_count] int NOT NULL
	);

	WITH ordered AS ( 
		SELECT 
			[database_name],
			MAX([row_id]) [row_id]
		FROM 
			[#LogInfo2]
		GROUP BY 
			[database_name]
	) 

	INSERT INTO [#results] ([database_name], [vlf_count])
	SELECT 
		[database_name], 
		COUNT(*) [vlf_count]
	FROM 
		[#LogInfo2] 
	GROUP BY 
		[database_name]
	ORDER BY 
		(SELECT [row_id] FROM ordered [x] WHERE [#LogInfo2].[database_name] = [x].[database_name])

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN
		SELECT @SerializedOutput = (
			SELECT 
				[row_id] [@id],
				[database_name],
				[vlf_count] 
			FROM 
				[#results]
			ORDER BY 
				[row_id]
			FOR XML PATH(N'database'), ROOT(N'databases'), TYPE
		);
		RETURN 0;
	END;

	SELECT 
		[database_name],
		[vlf_count] 
	FROM 
		[#results]
	ORDER BY 
		[row_id]

	RETURN 0;
GO