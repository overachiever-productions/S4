/*

	.EXAMPLE: 
		sdflksjfdlksdfjlkjsdf

		```sql
		DECLARE @indicators xml = N'<indicators>
			<indicator priority="1">
				<name>Error Number</name>
				<value>1451</value>
				<style>error</style>
			</indicator>
			<indicator priority="2">
				<name>Severity</name>
				<value>18</value>
				<style>error</style>
			</indicator>
			<indicator priority="3">
				<name>Alert Raised</name>
				<value>hh:mm:ss</value>
				<style>info</style>
				<context>Local Server Time</context>
			</indicator>
		</indicators>';

		PRINT N'XML: ' + dbo.format_xml_string(@indicators);

		```
*/

USE [admindb];
GO

IF OBJECT_ID('dbo.format_xml_string','FN') IS NOT NULL
	DROP FUNCTION dbo.[format_xml_string];
GO

CREATE FUNCTION dbo.[format_xml_string] (@input xml)
RETURNS nvarchar(MAX)
	WITH RETURNS NULL ON NULL INPUT
AS
    
	-- ATTRIBUTION:
    -- Minor tweaks (formatting/etc.) from code 'found' on Gemini. 
    --  Appears to be roughly patterned after code from Andrei Solntsev: https://www.sqlservercentral.com/scripts/convert-xml-to-string-with-formatting
    
    BEGIN; 
        DECLARE @output nvarchar(MAX) = N'';
		DECLARE @xmlString nvarchar(MAX) = CAST(@input AS nvarchar(MAX));
        DECLARE @pos int = 1;
        DECLARE @len int = LEN(@xmlString);
        DECLARE @char nchar(1);
        DECLARE @inTag bit = 0;
        DECLARE @currentTag nvarchar(MAX) = N'';
        DECLARE @indentLevel int = 0; 	
    
      WHILE @pos <= @len BEGIN
		SET @char = SUBSTRING(@xmlString, @pos, 1);

		IF @char = '<' BEGIN
			SET @inTag = 1;
			IF SUBSTRING(@xmlString, @pos + 1, 1) = '/' SET @indentLevel = IIF(@indentLevel > 0, @indentLevel - 1, 0);

			SET @output += CHAR(13) + CHAR(10) + REPLICATE('    ', @indentLevel) + @char;
		END;
		ELSE IF @char = '>' BEGIN
			SET @inTag = 0;
			SET @output += @char;
			IF SUBSTRING(@xmlString, @pos - 1, 1) != '/' AND SUBSTRING(@currentTag, 1, 1) != '/' SET @indentLevel += 1;
			SET @currentTag = '';
		END;
		ELSE BEGIN
			IF @inTag = 1 SET @currentTag += @char;
			SET @output += @char;
		END;

		SET @pos += 1;
	END;

	RETURN LTRIM(RTRIM(@output));

    END;
GO