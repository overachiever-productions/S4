/*


	.SYNOPSIS 
	Debugging aid to help provide context for syntax and other errors. 

	.DESCRIPTION 
	<longer version of the above goes here> 

	.PARAMETER @DynamicCode 
	REQUIRED
	The dynamic T-SQL Command being processed (typically via sys.sp_executesql) - which'll be 'shredded' so that the line causing
	problems can be identified visually. 

	.Parameter @TargetLine
	REQUIRED
	The line that the error occured on - or that you want to view. 

	.Parameter @BeforeAndAfterLines 
	DEFAULT = 6 
	Number of lines of code (i.e., context) to show BEFORE and AFTER the @TargetLine in question 

	.REMARK
	This sproc is similar to `dbo.extract_code_lines` - which targets specific T-SQL modules (via `sys.sql_modules`) and which is for
	debugging of 'static' code. 

	.RESULT
	<description here about how outputs are printed - not projected as table, etc.... and that there's a 'visual map' with code-lines numbered
	and with a --> pointer to the @TargetLine

	.EXAMPLE
	-- I'm really only putting this into place as an EXAMPLE of what it'll look like to have T-SQL code in here. 
	--		along with having comments and the "whole 9 yards"... 
	DECLARE @sql nvarchar(max) = 'SELECT TOP 200 FROM somethingWithMoreThanOneLine;'; 
	EXEC dbo.extracct_dynamic_code_lines @sql, 3, 2; 

	.EXAMPLE
	.TITLE Optional Title for this Example would go here.

	.RESULT 
	.TABLE (optional table name can go here - cuz... i guess there might be scenarios with multiple result sets). 
	column_name	int	description goes here - and note that I'm not doing anything other than tab-separation for columns. I mean, I could use | bars | and I guess that would work. 
	another_column	nvarchar(12)	another description goes here. and i guess it probably makes more sense to put | bars into place. 
	final_columns | tinyint | this is an example of what it would look like to have bars as separators. yeah. they're way better. and then I can just trim whitespace after 'splitting'. 
		<NOTE: output tables can/will only EVER have 3 columns: Column Name | Data type | Description - just as is done with T-SQL docs online.> 


	the other thing I need to tackle is ... making this 'powershell-like' syntax/approach to documentation for tsmake ... more like T-SQL docs. 
		such as: 
			- ARGUMENT? instead of PARAMETER? 
			- Option for .RETURNCODE ? 
			- Maybe .RESULT and .RESULTSET as differentiators between text and 'sets'/tables? 
			- Possibly??? .PERMISSIONS ... i mean, this is the admindb ... so, expectation is that everything will have these. 
				ahhh. no. I'm wrong. MY implementation will be for the admindb (initially) - but then for DDA, and BATCHER and... i want this framework viable for others... 
			- .SEEALSO ? (a name and a link?) only... how do I handle links? 
			- .SYNTAX - t-sql/pseudo-code that outlines the syntax for the calls/optional-call-types? 
			- .APPLIES (not sure how to tackle these - i mean, i could do .APPLIES<crlf>SQL 2017+<crlf2>.APPLIES<crlf>SQL Linux, SQL Azure, etc.<crlfs>.APPLIES<crlf>!RDS!
					where the idea is that I could list options for which products/platforms DO apply via .APPLIES... and !wrapping in exclamation points! would mean fails/red-mark vs green.
						same idea with ?SQL Server Linux?  ... meaning ... (?) icon ... 
					AND, with the above, I think i could do ALL .APPLIES on a single line
						EXAMPLE:
						.APPLIES
						SQL Server 2016SP1, SQL Azure, !RDS!, !Managed Instances!, ?Linux? 
							which'd have 2x green check marks, 2x red/no-worky, and a  question-mark for linux
					THE OTHER THING I could do would be .APPLIES is for 5x options: SQL Server, Azure SQL Database, Azure SQL Managed Instance, AWS RDS, SQL Server on Linux
						and have something like .APPLIESVERSION ... which would say something like "SQL Server 2014+" or whatever kind of text needs to be in place. 
	


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[extract_dynamic_code_lines]','P') IS NOT NULL
	DROP PROC dbo.[extract_dynamic_code_lines];
GO

CREATE PROC dbo.[extract_dynamic_code_lines]
	@DynamicCode				nvarchar(MAX), 
	@TargetLine					int, 
	@BeforeAndAfterLines		int			= 6
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @DynamicCode = NULLIF(@DynamicCode, N'');

	IF @DynamicCode IS NULL BEGIN 
		PRINT 'empty';
	END;

	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	SELECT 
		[row_id],
		[result]
	INTO 
		#lines
	FROM 
		dbo.[split_string](@DynamicCode, @crlf, 0)
	ORDER BY 
		row_id;

	DECLARE @lineCount int; 
	SELECT @lineCount = (SELECT COUNT(*) FROM [#lines]);

	DECLARE @startLine int = @TargetLine - @BeforeAndAfterLines;
	DECLARE @endLine int = @TargetLine + @BeforeAndAfterLines;

	IF @startLine < 0 SET @startLine = 0;
	IF @endLine > @lineCount SET @endLine = @lineCount;

	DECLARE @tab nchar(1) = NCHAR(9);
	DECLARE @output nvarchar(MAX) = N'';

	SELECT 
		@output = @output + CASE WHEN [row_id] = @TargetLine THEN N'--> ' ELSE @tab + N'' END + + CAST(row_id AS sysname) + @tab + [result] + @crlf
	FROM 
		[#lines]
	WHERE 
		row_id >= @startLine 
		AND 
		row_id <= @endLine
	ORDER BY 
		row_id;

	PRINT N'/* ';
	PRINT N'';
	
	EXEC dbo.[print_long_string] @output;

	PRINT N'';
	PRINT N'*/';

	RETURN 0;
GO