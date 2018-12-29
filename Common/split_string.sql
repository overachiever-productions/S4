
/*

	TODO: 

-- 2x bugs with split_string: 
SELECT * FROM dbo.[split_string](N'one', N'e');

SELECT * FROM dbo.[split_string](N'one', N'twelve');



*/


USE [admindb];
GO


IF OBJECT_ID('dbo.split_string','TF') IS NOT NULL
	DROP FUNCTION dbo.split_string;
GO

CREATE FUNCTION dbo.split_string(@serialized nvarchar(MAX), @delimiter nvarchar(20))
RETURNS @Results TABLE (row_id int IDENTITY NOT NULL, result nvarchar(200))
	--WITH SCHEMABINDING
AS 
	BEGIN

	-- {copyright}
	
	IF NULLIF(@serialized,'') IS NOT NULL AND NULLIF(@delimiter, N'') IS NOT NULL BEGIN

		DECLARE @MaxLength int = LEN(@serialized) + LEN(@delimiter);

		WITH tally (n) AS ( 
			SELECT TOP (@MaxLength) 
				ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
			FROM sys.all_objects o1 
			CROSS JOIN sys.all_objects o2
		)

		INSERT INTO @Results ([result])
		SELECT 
			SUBSTRING(@serialized, n, CHARINDEX(@delimiter, @serialized + @delimiter, n) - n)
		FROM 
			tally 
		WHERE 
			SUBSTRING(@delimiter + @serialized, n, LEN(@delimiter)) = @delimiter
		ORDER BY 
			 n;
	END;

	RETURN;
END

GO