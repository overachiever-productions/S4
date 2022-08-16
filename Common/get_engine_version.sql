/*

	vNEXT:
		https://overachieverllc.atlassian.net/browse/S4-496



	NOTES:
		- Rationale:
			While SERVERPROPERTY() will provide minor/major/full version details... they're strings. (because soemthing like 13.0.442.0 can't be a numeric)... 
				So, this function turns that data into a decimal - to make checks much easier (i.e., a comparison like dbo.get_engine_version() > 12.0 is a much easier way to check for certain features/capabilities. 
			

	SAMPLE USAGE: 
		
			IF (SELECT admindb.dbo.get_engine_version()) >= 11.0
				PRINT 'we''re 2012 or above...';

*/


USE [admindb];
GO

IF OBJECT_ID('dbo.get_engine_version','FN') IS NOT NULL
	DROP FUNCTION dbo.get_engine_version;
GO

CREATE FUNCTION dbo.get_engine_version() 
RETURNS decimal(4,2)
AS
	-- {copyright}

	BEGIN 
		DECLARE @output decimal(4,2);
		
		DECLARE @major sysname, @minor sysname, @full sysname;
		SELECT 
			@major = CAST(SERVERPROPERTY('ProductMajorVersion') AS sysname), 
			@minor = CAST(SERVERPROPERTY('ProductMinorVersion') AS sysname), 
			@full = CAST(SERVERPROPERTY('ProductVersion') AS sysname); 

		IF @major IS NULL BEGIN
			SELECT @major = LEFT(@full, 2);
			SELECT @minor = REPLACE((SUBSTRING(@full, LEN(@major) + 2, 2)), N'.', N'');
		END;

		SET @output = CAST((@major + N'.' + @minor) AS decimal(4,2));

		RETURN @output;
	END;
GO
