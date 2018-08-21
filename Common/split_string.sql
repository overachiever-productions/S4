
/*


	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple	
	
	SCALABLE:
		1+
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
	
	IF NULLIF(@serialized,'') IS NOT NULL BEGIN

		DECLARE @MaxLength int;
		SET @MaxLength = LEN(@serialized) + 1000;

		SET @serialized = @delimiter + @serialized + @delimiter;

		WITH tally AS ( 
			SELECT TOP (@MaxLength) 
				ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
			FROM sys.all_objects o1 
			CROSS JOIN sys.all_objects o2
		)

		INSERT INTO @Results (result)
		SELECT RTRIM(LTRIM((SUBSTRING(@serialized, n + 1, CHARINDEX(@delimiter, @serialized, n + 1) - n - 1))))
		FROM tally t
		WHERE n < LEN(@serialized) 
			AND SUBSTRING(@serialized, n, 1) = @delimiter
		ORDER BY t.n;
	END;

	RETURN;
END

GO