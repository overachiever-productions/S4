/*
	vNEXT: implement @PrintOnly - not that hard/cumbersome.
	
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.configure_instance','P') IS NOT NULL
	DROP PROC dbo.[configure_instance];
GO

CREATE PROC dbo.[configure_instance]
	@MaxDOP									int, 
	@CostThresholdForParallelism			int, 
	@MaxServerMemoryGBs						decimal(8,1)
AS
    SET NOCOUNT ON; 

	-- {copyright}

	-----------------------------------------------------------------------------
	-- Dependencies Validation:
	DECLARE @return int;
    EXEC @return = dbo.verify_advanced_capabilities;
	IF @return <> 0 
		RETURN @return;

	DECLARE @changesMade bit = 0;
	
	-- Enable the Dedicated Admin Connection: 
	IF NOT EXISTS (SELECT NULL FROM sys.[configurations] WHERE [name] = N'remote admin connections' AND [value_in_use] = 1) BEGIN
		EXEC sp_configure 'remote admin connections', 1;
		SET @changesMade = 1;
	END;
	
	IF @MaxDOP IS NOT NULL BEGIN
		DECLARE @currentMaxDop int;
		
		SELECT @currentMaxDop = CAST([value_in_use] AS int) FROM sys.[configurations] WHERE [name] = N'max degree of parallelism';

		IF @currentMaxDop <> @MaxDOP BEGIN
			-- vNEXT verify that the value is legit (i.e., > -1 (0 IS valid) and < total core count/etc.)... 
			EXEC sp_configure 'max degree of parallelism', @MaxDOP;

			SET @changesMade = 1;
		END;
	END;

	IF @CostThresholdForParallelism IS NOT NULL BEGIN 
		DECLARE @currentThreshold int; 

		SELECT @currentThreshold = CAST([value_in_use] AS int) FROM sys.[configurations] WHERE [name] = N'cost threshold for parallelism';

		IF @currentThreshold <> @CostThresholdForParallelism BEGIN
			EXEC sp_configure 'cost threshold for parallelism', @CostThresholdForParallelism;

			SET @changesMade = 1;
		END;
	END;

	IF @MaxServerMemoryGBs IS NOT NULL BEGIN 
		DECLARE @maxServerMemAsInt int; 
		DECLARE @currentMaxServerMem int;

		SET @maxServerMemAsInt = @MaxServerMemoryGBs * 1024;
		SELECT @currentMaxServerMem = CAST([value_in_use] AS int) FROM sys.[configurations] WHERE [name] LIKE N'max server memory%';

		-- pad by 30MB ... i.e., 'close enough':
		IF ABS((@currentMaxServerMem - @maxServerMemAsInt)) > 30 BEGIN
			EXEC sp_configure 'max server memory', @maxServerMemAsInt;

			SET @changesMade = 1;
		END;
	END;

	IF @changesMade = 1 BEGIN
		RECONFIGURE;
	END;

	RETURN 0;
GO