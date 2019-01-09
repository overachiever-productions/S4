

/*
	TODO: 
		- Perf tuning - there's an implicit conversion going on in here... 



	USAGE: 
		-- sample usage: 

				DECLARE @input nvarchar(MAX) = N'7:Xclelerator:Xcelerator_Clone5, 5:BayCare, 5:admindb:admindb_fake';
				DECLARE @numberOfMatches int = -1; 
				SELECT @numberOfMatches = dbo.count_matches(@input, N':');
				SELECT @numberOfMatches [match_count];



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

		IF @replacedLength < @actualLength BEGIN 

			DECLARE @difference int = @actualLength - @replacedLength; 
			SET @output =  @difference / LEN(@pattern);

		END;
		
		RETURN @output;
	END; 
GO