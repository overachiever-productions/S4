/*
		Super Helpful when debugging and trying to figure out why the bleep isn't my IF @x = 'true' or whatever logic matching/working... 
	
*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.translate_characters', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[translate_characters];
GO

CREATE FUNCTION dbo.[translate_characters] (@Input nvarchar(MAX))
RETURNS table
AS
    RETURN
	
	-- {copyright}

	SELECT 
		number[position], 
		SUBSTRING(@input, [number], 1) [char], 
		ASCII(SUBSTRING(@input, [number], 1)) [ascii], 
		UNICODE(SUBSTRING(@input, [number], 1)) [unicode]
	FROM 
		dbo.[numbers]
	WHERE 
		[number] <= LEN(@input)
	ORDER BY 
		[number];
GO