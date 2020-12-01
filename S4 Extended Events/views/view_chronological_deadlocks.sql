/*



			EXEC [admindb].dbo.[view_sequential_deadlocks]
				@TranslatedDeadlocksTable = N'Meddling.dbo.xxx_deadlocks';

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.view_chronological_deadlocks','P') IS NOT NULL
	DROP PROC dbo.[view_chronological_deadlocks];
GO

CREATE PROC dbo.[view_chronological_deadlocks]
	@TranslatedDeadlocksTable					sysname, 
	@OptionalStartTime							datetime	= NULL, 
	@OptionalEndTime							datetime	= NULL
AS
    SET NOCOUNT ON; 

	-- {copyright}

	SET @TranslatedDeadlocksTable = NULLIF(@TranslatedDeadlocksTable, N'');
	
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
		[timestamp] sysname NULL,
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

	DECLARE @sql nvarchar(MAX) = N'SELECT 
		*
	FROM {SourceTable}{WHERE}
	ORDER BY 
		[row_id]; ';

	DECLARE @dateTimePredicate nvarchar(MAX) = N'';
	IF @OptionalStartTime IS NOT NULL BEGIN 
		SET @dateTimePredicate = N'WHERE [timestamp] >= ''' + CONVERT(sysname, @OptionalStartTime, 121) + N'''';
	END; 

	IF @OptionalEndTime IS NOT NULL BEGIN 
		IF NULLIF(@dateTimePredicate, N'') IS NOT NULL BEGIN 
			SET @dateTimePredicate = @dateTimePredicate + N' AND [timestamp] <= ''' + CONVERT(sysname, @OptionalEndTime, 121) + N'''';
		  END; 
		ELSE BEGIN 
			SET @dateTimePredicate = N'WHERE [timestamp] <= ''' + CONVERT(sysname, @OptionalEndTime, 121) + N'''';
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
		[timestamp],
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