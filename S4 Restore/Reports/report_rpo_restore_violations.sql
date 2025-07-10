/*

	REFACTOR
		Do i REALLY need RESTORE in the title? 
			i.e., report_rpo_violations?  (i mean, ARGUABLY, I might be able to get RPO violations from job-histories or file-names - vs RESTORES. so ... there's that).

	NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.


	vNEXT:
		- There's a logic bomb with current implementations if/when we 'wrap' from (say late night one night into early AM the next day): 
			see: https://overachieverllc.atlassian.net/browse/S4-656
		
		
		- Think it probably makes sense to add in an @Mode - with options/values of { DETAIL | AGGREGATE } (or something similar)
			see: https://overachieverllc.atlassian.net/browse/S4-655
		- NOTE: there's a 'logic complication' outlined in the above issue as well. 









*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[report_rpo_restore_violations]','P') IS NOT NULL
	DROP PROC dbo.[report_rpo_restore_violations];
GO

CREATE PROC dbo.[report_rpo_restore_violations]
	@TargetDatabases				nvarchar(MAX)		= N'{ALL}', 
	@ExcludedDatabases				nvarchar(MAX)		= NULL,
	@Scope							sysname				= N'WEEK',			-- LATEST | DAY | WEEK | MONTH | QUARTER
	@RPOSeconds						bigint				= 600, 
	@SerializedOutput				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDatabases = ISNULL(NULLIF(@TargetDatabases, N''), N'{ALL}');
	SET @Scope = ISNULL(NULLIF(@Scope, N''), N'WEEK');
	SET @RPOSeconds = ISNULL(@RPOSeconds, 600);

	CREATE TABLE #targetDatabases (
		[database_name] sysname NOT NULL
	);

	INSERT INTO [#targetDatabases] ([database_name])
	EXEC dbo.[list_databases]
		@Targets = @TargetDatabases,
		@Exclusions = @ExcludedDatabases,
		@Priorities = NULL,
		@ExcludeClones = 0,
		@ExcludeSecondaries = 0,
		@ExcludeSimpleRecovery = 0,  -- might be simple NOW, but if we had logs... 
		@ExcludeReadOnly = 0,
		@ExcludeRestoring = 0,
		@ExcludeRecovering = 0,
		@ExcludeOffline = 0;

	CREATE TABLE #executionIDs (
		execution_id uniqueidentifier NOT NULL
	);

	IF UPPER(@Scope) = N'LATEST'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT TOP(1) [execution_id] FROM dbo.[restore_log] ORDER BY [restore_id] DESC;

	IF UPPER(@Scope) = N'DAY'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(GETDATE() AS [date]) GROUP BY [execution_id];
	
	IF UPPER(@Scope) = N'WEEK'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(WEEK, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	

	IF UPPER(@Scope) = N'MONTH'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(MONTH, -1, GETDATE()) AS [date]) GROUP BY [execution_id];	

	IF UPPER(@Scope) = N'QUARTER'
		INSERT INTO [#executionIDs] ([execution_id])
		SELECT [execution_id] FROM dbo.[restore_log] WHERE [operation_date] >= CAST(DATEADD(QUARTER, -1, GETDATE()) AS [date]) GROUP BY [execution_id];		

	WITH core AS (
		SELECT 
			[l].[database], 
			[l].[operation_date],
			[l].[restored_files]
		FROM 
			dbo.[restore_log] [l]
			INNER JOIN [#executionIDs] [x] ON [l].[execution_id] = [x].[execution_id]
			INNER JOIN [#targetDatabases] [d] ON [l].[database] = [d].[database_name] 
	), 
	files AS ( 
		SELECT 
			[c].[database], 
			[c].[operation_date],
			[x].[n].value(N'(name)[1]', N'sysname') [file_name], 
			[x].[n].value(N'(created)[1]', N'datetime') [created]
		FROM 
			core [c]
			CROSS APPLY [c].[restored_files].nodes(N'/files/file') [x]([n])
	), 
	differenced AS (
		SELECT 
			[f].[database], 
			[f].[operation_date],
			[f].[file_name], 
			[f].[created], 
			LAG([f].[created], 1, NULL) OVER (PARTITION BY [f].[database], [f].[operation_date] ORDER BY [f].[created]) [previous], 
			CASE WHEN [f].[file_name] LIKE N'DIFF_%' THEN 1 ELSE 0 END [is_diff_backup],
			/* DATEDIFF @ SECONDS allows for roughly 68 years (with int) - so ... overflows aren't a real concern here. */
			DATEDIFF(SECOND, LAG([f].[created], 1, NULL) OVER (PARTITION BY [f].[database], [f].[operation_date] ORDER BY [f].[created]), [f].[created]) [diff]
		FROM	
			files [f]
	)

	SELECT 
		[database], 
		[operation_date] [date],
		COUNT(*) [violations], 
		MIN([diff]) [smallest],
		MAX([diff]) [largest], 
		AVG([diff]) [average], 
		@RPOSeconds [target]
	INTO 
		#output
	FROM 
		differenced
	WHERE 
		[diff] > @RPOSeconds
		AND is_diff_backup = 0
	GROUP BY 
		[database], 
		[operation_date];

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- if @SerializedOutput has been EXPLICITLY provided as an argument... reply 

		SELECT @SerializedOutput = (SELECT 
			[database] [db_name], 
			[date],
			[violations], 
			[smallest], 
			[largest], 
			[average], 
			[target]
		FROM 
			[#output] 
		ORDER BY 
			[database], [date]
		FOR XML PATH(N'database'), ROOT(N'databases'), TYPE);		

		RETURN 0;
	END;

	SELECT 
		[database], 
		[date],
		[violations], 
		[smallest], 
		[largest], 
		[average], 
		[target]
	FROM 
		[#output]
	ORDER BY 
		[database], 
		[date];

	RETURN 0;
GO