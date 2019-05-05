/*


		
		------------------
		-- Expect Error:

		DECLARE @error nvarchar(MAX);
		DECLARE @output datetime; 

		EXEC dbo.translate_vector_timestamp 
			@Vector = N'2 backups', 
			@Operation = 'SUBTRACT',
			@ValidationParameterName = N'@Cutoff', 
			@ProhibitedIntervals = NULL, 
			@Output = @output OUTPUT, 
			@error = @error OUTPUT;

		SELECT @output [output], @error [error]
		GO

		------------------
		-- 2 years ago:

		DECLARE @error nvarchar(MAX);
		DECLARE @output datetime; 

		EXEC dbo.translate_vector_timestamp 
			@Vector = N'2 years', 
			@Operation = 'SUBTRACT',
			@ValidationParameterName = N'@Cutoff', 
			@ProhibitedIntervals = NULL, 
			@Output = @output OUTPUT, 
			@error = @error OUTPUT;

		SELECT @output [output], @error [error]
		GO

		------------------
		-- 2 days from now:

		DECLARE @error nvarchar(MAX);
		DECLARE @output datetime; 

		EXEC dbo.translate_vector_timestamp 
			@Vector = N'2 days', 
			@ValidationParameterName = N'@Cutoff', 
			@ProhibitedIntervals = NULL, 
			@Output = @output OUTPUT, 
			@error = @error OUTPUT;

		SELECT @output [output], @error [error]
		GO


*/

USE [admindb];
GO 

IF OBJECT_ID('dbo.translate_vector_datetime','P') IS NOT NULL
	DROP PROC dbo.translate_vector_datetime;
GO

CREATE PROC dbo.translate_vector_datetime
	@Vector									sysname						= NULL, 
	@Operation								sysname						= N'ADD',		-- Allowed Values are { ADD | SUBTRACT }
	@ValidationParameterName				sysname						= NULL, 
	@ProhibitedIntervals					sysname						= NULL,	
	@Output									datetime					OUT, 
	@Error									nvarchar(MAX)				OUT
AS
	SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	IF UPPER(@Operation) NOT IN (N'ADD', N'SUBTRACT') BEGIN 
		RAISERROR('Valid operations (values for @Operation) are { ADD | SUBTRACT }.', 16, 1);
		RETURN -1;
	END;

	IF @ProhibitedIntervals IS NULL
		SET @ProhibitedIntervals = N'BACKUP';

	IF dbo.[count_matches](@ProhibitedIntervals, N'BACKUP') < 1
		SET @ProhibitedIntervals = @ProhibitedIntervals + N', BACKUP';

	DECLARE @errorMessage nvarchar(MAX);
	DECLARE @interval sysname;
	DECLARE @duration bigint;

	EXEC dbo.parse_vector 
		@Vector = @Vector, 
		@ValidationParameterName  = @ValidationParameterName, 
		@ProhibitedIntervals = @ProhibitedIntervals, 
		@IntervalType = @interval OUTPUT, 
		@Value = @duration OUTPUT, 
		@Error = @errorMessage OUTPUT; 

	IF @errorMessage IS NOT NULL BEGIN 
		SET @Error = @errorMessage;
		RETURN -10;
	END;

	DECLARE @sql nvarchar(2000) = N'SELECT @timestamp = DATEADD({0}, {2}{1}, GETDATE());';
	SET @sql = REPLACE(@sql, N'{0}', @interval);
	SET @sql = REPLACE(@sql, N'{1}', @duration);

	IF UPPER(@Operation) = N'ADD'
		SET @sql = REPLACE(@sql, N'{2}', N'');
	ELSE 
		SET @sql = REPLACE(@sql, N'{2}', N'0 - ');

	DECLARE @ts datetime;

	BEGIN TRY 
		
		EXEC sys.[sp_executesql]
			@sql, 
			N'@timestamp datetime OUT', 
			@timestamp = @ts OUTPUT;

	END TRY
	BEGIN CATCH 
		SELECT @Error = N'EXCEPTION: ' + CAST(ERROR_MESSAGE() AS sysname) + N' - ' + ERROR_MESSAGE();
		RETURN -30;
	END CATCH

	SET @Output = @ts;

	RETURN 0;
GO