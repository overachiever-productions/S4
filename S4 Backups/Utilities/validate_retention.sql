/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[validate_retention]','P') IS NOT NULL
	DROP PROC dbo.[validate_retention];
GO

CREATE PROC dbo.[validate_retention]
	@Retention			sysname, 
	@ParameterName		sysname
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @Retention = UPPER(NULLIF(@Retention, N''));

	IF @Retention IS NULL BEGIN 
		RAISERROR(N'Parameter [%s] is REQUIRED.', 16, 1, @ParameterName);
		RETURN -1;
	END;
	
	IF @Retention = N'{INFINITE}'
		RETURN 0; -- allowed/valid. 

	DECLARE @retentionType char(1);
	DECLARE @retentionValue bigint;
	DECLARE @retentionError nvarchar(MAX);
	DECLARE @retentionCutoffTime datetime; 

	IF UPPER(@Retention) LIKE '%B%' OR UPPER(@Retention) LIKE '%BACKUP%' BEGIN 
		
		DECLARE @boundary int = PATINDEX(N'%[^0-9]%', @Retention)- 1;

		IF @boundary < 1 BEGIN 
			SET @retentionError = N'Value for [%s] is invalid. When specifying values for backups use: "N backup[s]" - where N is the # of backups to keep and "s" is optional.';
			RAISERROR(@retentionError, 16, 1, @ParameterName);
			RETURN -10;
		END;

		BEGIN TRY
			SET @retentionValue = CAST((LEFT(@Retention, @boundary)) AS int);
		END TRY
		BEGIN CATCH
			SET @retentionValue = -1;
		END CATCH

		IF @retentionValue < 0 BEGIN 
			RAISERROR('Invalid value specified for [%s]. Number of Backups specified was formatted incorrectly or < 0.', 16, 1, @ParameterName);
			RETURN -25;
		END;

		SET @retentionType = 'b';
	  END;
	ELSE BEGIN 
		EXEC dbo.[translate_vector_datetime]
		    @Vector = @Retention, 
		    @Operation = N'SUBTRACT', 
		    @ValidationParameterName = @ParameterName, 
		    @ProhibitedIntervals = N'BACKUP', 
		    @Output = @retentionCutoffTime OUTPUT, 
		    @Error = @retentionError OUTPUT;

		IF @retentionError IS NOT NULL BEGIN 
			RAISERROR(@retentionError, 16, 1);
			RETURN -26;
		END;

		IF @retentionCutoffTime > GETDATE() BEGIN 
			RAISERROR('Invalid value for [%]. Retention is set to greater than or equal to NOW.', 16, 1, @ParameterName);
			RETURN -30;
		END;
	END;

	DECLARE @parsingOutput int; 
	EXEC @parsingOutput = dbo.[parse_vector]
		@Vector = @Retention,
		@ValidationParameterName = @ParameterName,
		@IntervalType = NULL,
		@Value = NULL,
		@Error = @retentionError OUTPUT
	

	RETURN 0;
GO