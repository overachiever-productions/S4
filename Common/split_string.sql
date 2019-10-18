
/*

	TODO: 
		- Figure out why I'm being dumb and can't get the normal (numbers table) approach to work with ' ' (space). 
			I'm doing something dumb there. The current fix/hack addresses this from a LOGICAL standpoint, but the perf isn't going to be solid/great.



-- crappy tests... 
SELECT * FROM dbo.[split_string](N'one', N'e', 1);
SELECT * FROM dbo.[split_string](N'one', N'twelve', 0);
SELECT * FROM dbo.[split_string](N'these are some words that i would like to have split and stuff.', N' ', 1);


*/


USE [admindb];
GO


IF OBJECT_ID('dbo.split_string','TF') IS NOT NULL
	DROP FUNCTION dbo.split_string;
GO

CREATE FUNCTION dbo.split_string(@serialized nvarchar(MAX), @delimiter nvarchar(20), @TrimResults bit)
RETURNS @Results TABLE (row_id int IDENTITY NOT NULL, result nvarchar(MAX))
	--WITH SCHEMABINDING
AS 
	BEGIN

	-- {copyright}
	
	IF NULLIF(@serialized,'') IS NOT NULL AND DATALENGTH(@delimiter) >= 1 BEGIN
		IF @delimiter = N' ' BEGIN 
			-- this approach is going to be MUCH slower, but works for space delimiter... 
			DECLARE @p int; 
			DECLARE @s nvarchar(MAX);
			WHILE CHARINDEX(N' ', @serialized) > 0 BEGIN 
				SET @p = CHARINDEX(N' ', @serialized);
				SET @s = SUBSTRING(@serialized, 1, @p - 1); 
			
				INSERT INTO @Results ([result])
				VALUES(@s);

				SELECT @serialized = SUBSTRING(@serialized, @p + 1, LEN(@serialized) - @p);
			END;
			
			INSERT INTO @Results ([result])
			VALUES (@serialized);

		  END; 
		ELSE BEGIN

			DECLARE @MaxLength int = LEN(@serialized) + LEN(@delimiter);

			WITH tally (n) AS ( 
				SELECT TOP (@MaxLength) 
					ROW_NUMBER() OVER (ORDER BY o1.[name]) AS n
				FROM sys.all_objects o1 
				CROSS JOIN sys.all_objects o2
			)

			INSERT INTO @Results ([result])
			SELECT 
				SUBSTRING(@serialized, n, CHARINDEX(@delimiter, @serialized + @delimiter, n) - n) [result]
			FROM 
				tally 
			WHERE 
				n <= LEN(@serialized) AND
				LEN(@delimiter) <= LEN(@serialized) AND
				RTRIM(LTRIM(SUBSTRING(@delimiter + @serialized, n, LEN(@delimiter)))) = @delimiter
			ORDER BY 
				 n;
		END;

		IF @TrimResults = 1 BEGIN
			UPDATE @Results SET [result] = LTRIM(RTRIM([result])) WHERE DATALENGTH([result]) > 0;
		END;

	END;

	RETURN;
END

GO