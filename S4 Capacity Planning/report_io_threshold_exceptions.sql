/*

	EXEC [admindb].dbo.[report_io_threshold_exceptions]
		@SourceTable = N'PayTrace_EBsIOPs1',
		@TargetDisks = N'D',
		@TargetThresholds = N'D:6000:250';



	TODO:
		- Need to enable option for reporting on LATENCY exceptions... i.e., something like D:iops:mb-throughput:ms-latency as the @TargetThresholds... 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.report_io_threshold_exceptions','P') IS NOT NULL
	DROP PROC dbo.[report_io_threshold_exceptions];
GO

CREATE PROC dbo.[report_io_threshold_exceptions]
	@SourceTable					sysname, 
	@TargetDisks					sysname				= N'{ALL}', 
	@TargetThresholds				nvarchar(MAX)		= NULL

AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @TargetDisks = ISNULL(NULLIF(@TargetDisks, N''), N'{ALL}');

	DECLARE @normalizedName sysname; 
	DECLARE @targetObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @SourceTable, 
		@ParameterNameForTarget = N'@SourceTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @targetObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 

	-------------------------------------------------------------------------------------------------------------------------
	-- Translate Targetting Constraints (if present): 
	DECLARE @targetsPresent bit = 0;

	IF NULLIF(@TargetThresholds, N'') IS NOT NULL BEGIN 

		CREATE TABLE #targets (
			row_id int NOT NULL, 
			drive_letter sysname NOT NULL, 
			target_iops decimal(24,2) NOT NULL, 
			target_mbps decimal(24,2) NOT NULL
		);

		INSERT INTO [#targets] (
			[row_id],
			[drive_letter],
			[target_iops],
			[target_mbps]
		)
		EXEC admindb.dbo.[shred_string] 
			@Input = @TargetThresholds, 
			@RowDelimiter = N',', 
			@ColumnDelimiter = N':';
		
		IF EXISTS (SELECT NULL FROM [#targets]) BEGIN
			SET @targetsPresent = 1;

		END;

	END;

	-------------------------------------------------------------------------------------------------------------------------

	DECLARE @targetDBName sysname = PARSENAME(@normalizedName, 3);
	
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @sql nvarchar(MAX);

	SET @sql = N'SELECT @serverName = (SELECT TOP 1 [server_name] FROM ' + @SourceTable + N'); ';
	DECLARE @serverName sysname; 
	EXEC [sys].[sp_executesql]
		@sql, 
		N'@serverName sysname OUTPUT', 
		@serverName = @serverName OUTPUT;

	DECLARE @drives table (
		row_id int IDENTITY(1,1) NOT NULL, 
		[drive] sysname NOT NULL
	); 

	SET @sql = N'WITH core AS ( 
		SELECT 
			column_id,
			[name]
		FROM 
			[' + @targetDBName + N'].sys.[all_columns] 
		WHERE 
			[object_id] = OBJECT_ID(''' + @normalizedName + N''')
			AND [name] LIKE ''IOPs.%''
	) 

	SELECT 
		REPLACE([name], N''IOPs.'', '''') [drive]
	FROM 
		core; ';

	INSERT INTO @drives ([drive])
	EXEC sp_executesql 
		@sql;

	-- Implement drive filtering: 
	IF UPPER(@TargetDisks) <> N'{ALL}' BEGIN 

		DELETE d 
		FROM 
			@drives d 
			LEFT OUTER JOIN ( 
				SELECT 
					[result]
				FROM 
					admindb.dbo.split_string(@TargetDisks, N',', 1)

				UNION 
					
				SELECT 
					N'_Total' [result]				
			) x ON d.[drive] = x.[result] 
		WHERE 
			x.[result] IS NULL;
	END;

	DELETE FROM @drives WHERE [drive] = N'_Total';


	-------------------------------------------------------------------------------------------------------------------------
	-- begin processing/assessing outputs: 
	DECLARE @violationTemplate nvarchar(MAX) = N'WITH raw AS (
	SELECT 
		''{HostName}'' [server_name],
		[timestamp], 
		[% CPU], 
		[PLE], 
		[batches/second], 
		{throughput}{IOPs}{latency}[PeakLatency]
	FROM 
		' + @SourceTable + N'
)
	
SELECT 
	*
FROM 
	raw 
WHERE 
	({throughput_violation})
	OR 
	({IOPs_violation})
ORDER BY 
	[timestamp]; ';


	DECLARE @throughput nvarchar(MAX) = N'';
	DECLARE @iOPs nvarchar(MAX) = N'';
	DECLARE @latency nvarchar(MAX) = N'';

	SELECT 
		@throughput = @throughput + N'[MB Throughput.' + [drive] + N'],' + @crlf + @tab + @tab
	FROM 
		@drives;

	SELECT 
		@iOPs = @iOPs + N'[IOPs.' + [drive] + N'], ' + @crlf + @tab + @tab 
	FROM 
		@drives;

	SELECT 
		@latency = @latency + N'[Latency.' + [drive] + N'], ' + @crlf + @tab + @tab 
	FROM 
		@drives;

	DECLARE @throughputViolation nvarchar(MAX) = N'';
	DECLARE @iopsViolation nvarchar(MAX) = N'';

	SELECT 
		@throughputViolation = @throughputViolation + N'[MB Throughput.' + [drive_letter] + N'] > ' + CAST([target_mbps] AS sysname) + N' OR '
	FROM
		[#targets];
	SET @throughputViolation = LEFT(@throughputViolation, LEN(@throughputViolation) - 3);

	SELECT 
		@iopsViolation = @iopsViolation + N'[IOPs.' + [drive_letter] + N'] > ' + CAST([target_iops] AS sysname) + N' OR '
	FROM 
		[#targets];
	SET @iopsViolation = LEFT(@iopsViolation, LEN(@iopsViolation) - 3);


	SET @sql = REPLACE(@violationTemplate, N'{throughput}', @throughput);
	SET @sql = REPLACE(@sql, N'{IOPs}', @iOPs);
	SET @sql = REPLACE(@sql, N'{Latency}', @latency);
	SET @sql = REPLACE(@sql, N'{HostName}', @serverName);

	SET @sql = REPLACE(@sql, N'{throughput_violation}', @throughputViolation);
	SET @sql = REPLACE(@sql, N'{IOPs_violation}', @iopsViolation);

	--PRINT @sql;

	EXEC sp_executesql @sql;
	
	RETURN 0;
GO	