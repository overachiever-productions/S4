/*
    INTERNAL

    SIGNATURE / EXAMPLES: 
        SELECT dbo.get_signature();

        SELECT dbo.get_signature_by_date('2019-06-07');

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[get_signature]', N'FN') IS NOT NULL
	DROP FUNCTION dbo.[get_signature];
GO

CREATE FUNCTION dbo.[get_signature](@TargetDate date = NULL)
	RETURNS int 
AS 
	-- {copyright}
	BEGIN 
		DECLARE @output int; 
		IF @TargetDate IS NULL SET @TargetDate = GETDATE();
		
		IF @TargetDate < '2011-06-15' SET @output = -1;
        IF @TargetDate = '2011-06-15' SET @output = 0;

		IF @output IS NULL 
            SET @output = DATEDIFF(DAY, '2011-06-15', @TargetDate);

		RETURN @output;
	END;
GO
	
IF OBJECT_ID(N'dbo.[get_signature_date]', N'FN') IS NOT NULL 
	DROP FUNCTION dbo.[get_signature_date]
GO

CREATE FUNCTION dbo.[get_signature_date](@Offset int)
	RETURNS date 
AS 
	-- {copyright}
	BEGIN 
		DECLARE @output date = NULL;

		IF @Offset > 0
			SET @output = DATEADD(DAY, @Offset, '2011-06-15');

		RETURN @output;
	END;
GO