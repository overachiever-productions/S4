/*



			EXEC [admindb].dbo.[view_deadlocks_chronology]
				@TranslatedDeadlocksTable = N'Meddling.dbo.xxx_deadlocks';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_deadlock_chronology','P') IS NOT NULL
	DROP PROC dbo.[view_deadlock_chronology];
GO

CREATE PROC dbo.[view_deadlock_chronology]
	@TranslatedDeadlocksTable					sysname, 
	@OptionalStartTime							datetime	= NULL, 
	@OptionalEndTime							datetime	= NULL, 
	@TimeZone									sysname		= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TranslatedDeadlocksTable = NULLIF(@TranslatedDeadlocksTable, N'');
	SET @TimeZone = NULLIF(@TimeZone, N'');

	DECLARE @normalizedName sysname; 
	DECLARE @sourceObjectID int; 
	DECLARE @outcome int = 0;

	EXEC @outcome = dbo.load_id_for_normalized_name 
		@TargetName = @TranslatedDeadlocksTable, 
		@ParameterNameForTarget = N'@TranslatedDeadlocksTable', 
		@NormalizedName = @normalizedName OUTPUT, 
		@ObjectID = @sourceObjectID OUTPUT;

	IF @outcome <> 0
		RETURN @outcome;  -- error will have already been raised... 	

	CREATE TABLE #work (
		[row_id] int NOT NULL,
		[deadlock_id] sysname NULL,
		[timestamp] datetime NULL,
		[process_count] sysname NULL,
		[session_id] nvarchar(259) NULL,
		[client_application] nvarchar(104) NULL,
		[host_name] nvarchar(104) NULL,
		[transaction_count] int NULL,
		[lock_mode] varchar(10) NULL,
		[wait_time] sysname NULL,
		[log_used] bigint NULL,
		[wait_resource_id] varchar(200) NULL,
		[wait_resource] varchar(2000) NULL,
		[proc] nvarchar(max) NULL,
		[statement] nvarchar(max) NULL,
		[normalized_statement] nvarchar(max) NULL,
		[input_buffer] nvarchar(max) NULL,
		[deadlock_graph] xml NULL
	);

	DECLARE @sql nvarchar(MAX) = N'	SELECT 
		*
	FROM {SourceTable}{WHERE}
	ORDER BY 
		[row_id]; ';

	IF UPPER(@TimeZone) = N'{SERVER_LOCAL}'
		SET @TimeZone = dbo.[get_local_timezone]();

	DECLARE @offsetMinutes int = 0;
	IF @TimeZone IS NOT NULL
		SELECT @offsetMinutes = dbo.[get_timezone_offset_minutes](@TimeZone);

	DECLARE @dateTimePredicate nvarchar(MAX) = N'';
	DECLARE @nextLine nchar(3) = NCHAR(13) + NCHAR(10) + NCHAR(9);
	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @dateTimePredicate = @nextLine + N'WHERE [timestamp] >= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalStartTime), 121) + N'''';
	END; 

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF NULLIF(@dateTimePredicate, N'') IS NOT NULL BEGIN 
			SET @dateTimePredicate = @dateTimePredicate + @nextLine + N'AND [timestamp] <= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime), 121) + N'''';
		  END; 
		ELSE BEGIN 
			SET @dateTimePredicate = @nextLine + N'WHERE [timestamp] <= ''' + CONVERT(sysname, DATEADD(MINUTE, 0 - @offsetMinutes, @OptionalEndTime), 121) + N'''';
		END;
	END;

	SET @sql = REPLACE(@sql, N'{SourceTable}', @normalizedName);
	SET @sql = REPLACE(@sql, N'{WHERE}', @dateTimePredicate);
	
	INSERT INTO [#work] (
		[row_id],
		[deadlock_id],
		[timestamp],
		[process_count],
		[session_id],
		[client_application],
		[host_name],
		[transaction_count],
		[lock_mode],
		[wait_time],
		[log_used],
		[wait_resource_id],
		[wait_resource],
		[proc],
		[statement],
		[normalized_statement],
		[input_buffer],
		[deadlock_graph]
	)
	EXEC sys.sp_executesql 
		@sql; 

	-- Projection/Output:
	SELECT 
		[deadlock_id],
		CASE WHEN [deadlock_id] = N'' THEN N'' ELSE CONVERT(sysname, DATEADD(MINUTE, @offsetMinutes, [timestamp]), 121) END [timestamp],
		[deadlock_graph],
		[process_count],
		[session_id],
		[client_application],
		[host_name],
		[transaction_count],
		[lock_mode],
		[wait_time],
		[log_used],
		[wait_resource_id],
		[wait_resource],
		[proc],
		[statement],
		[normalized_statement],
		[input_buffer]		
	FROM 
		[#work] 
	ORDER BY 
		[row_id];

	RETURN 0;
GO