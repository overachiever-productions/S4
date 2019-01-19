

/*
	TODO: 
		- Perf tuning - there's an implicit conversion going on in here... 



	USAGE: 
		-- sample usage: 

				DECLARE @input nvarchar(MAX) = N'7:Xclelerator:Xcelerator_Clone5, 5:BayCare, 5:admindb:admindb_fake';
				DECLARE @numberOfMatches int = -1; 
				SELECT @numberOfMatches = dbo.count_matches(@input, N':');
				SELECT @numberOfMatches [match_count];


				SELECT dbo.count_matches('   122', N' ')


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.count_matches','FN') IS NOT NULL
	DROP FUNCTION dbo.count_matches;
GO

CREATE FUNCTION dbo.count_matches(@input nvarchar(MAX), @pattern sysname) 
RETURNS int 
AS 
	-- {copyright}
	BEGIN 
		DECLARE @output int = 0;

		DECLARE @actualLength int = LEN(@input); 
		DECLARE @replacedLength int = LEN(CAST(REPLACE(@input, @pattern, N'') AS nvarchar(MAX)));
		DECLARE @patternLength int = LEN(@pattern);  

		IF @replacedLength < @actualLength BEGIN 
		
			-- account for @pattern being 1 or more spaces: 
			IF @patternLength = 0 AND DATALENGTH(LTRIM(@pattern)) = 0 
				SET @patternLength = DATALENGTH(@pattern) / 2;
			
			IF @patternLength > 0
				SET @output =  (@actualLength - @replacedLength) / @patternLength;
		END;
		
		RETURN @output;
	END; 
GO