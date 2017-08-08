
/*


	CODE, LICENSE, DOCS:
		https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639
		username: s4
		password: simple	
	
	SCALABLE:
		.5
*/


USE [master];
GO


IF OBJECT_ID('dbo.dba_SplitString','TF') IS NOT NULL
	DROP FUNCTION dbo.dba_SplitString;
GO

CREATE FUNCTION dbo.dba_SplitString(@serialized nvarchar(MAX), @delimiter nvarchar(20))
RETURNS @Results TABLE (result nvarchar(200))
	--WITH SCHEMABINDING 
AS 
	BEGIN

	-- Version 3.7.1.16638	
	-- License/Code/Details/Docs: https://git.overachiever.net/Repository/Tree/00aeb933-08e0-466e-a815-db20aa979639  (username: s4   password: simple )
	
	DECLARE @MaxLength int;
	SET @MaxLength = LEN(@serialized) + 1000;

	SET @serialized = @delimiter + @serialized + @delimiter;

	WITH tally AS ( 
		SELECT TOP (@MaxLength) 
			ROW_NUMBER() OVER (ORDER BY o1.[name]) AS N
		FROM sys.all_objects o1 
		CROSS JOIN sys.all_objects o2
	)

	INSERT INTO @Results (result)
	SELECT  RTRIM(LTRIM((SUBSTRING(@serialized, N + 1, CHARINDEX(@delimiter, @serialized, N + 1) - N - 1))))
	FROM tally t
	WHERE N < LEN(@serialized) 
		AND SUBSTRING(@serialized, N, 1) = @delimiter
	ORDER BY t.N;
		
	RETURN;
END

GO