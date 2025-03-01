/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.
		- Specifically:
			> if @SerializedOutput is explicitly set to NULL, then it'll be populated with (attempted) xml output. 
			> Otherwise, this sproc will simply 'spit out' the string output/reply sent back from posh execution.


	vNEXT: 
		- MIGHT? make sense to have an @StringOutput (and @SerializedXmlOutput vs @serializeOutput) parameter? 

	EXAMPLES: 

			-- text output: 
				EXEC dbo.execute_powershell @Command = N'$PSVersionTable;';

			-- text output - but as a variable: 
				DECLARE @stringVersion nvarchar(MAX);
				EXEC dbo.execute_powershell 
					@Command = N'$PSVersionTable;', 
					@StringOutput = @stringVersion OUTPUT;

				SELECT @stringVersion;


			-- same as above, but transform output to XML from within PowerShell, and get XML as STRING back in SQL: 
				EXEC dbo.execute_powershell @Command = N'$PSVersionTable | ConvertTo-XML -As Stream;';

			-- same as above, but extract just a string/result for use by a caller: 
				DECLARE @output nvarchar(MAX) = NULL; 
				EXEC dbo.execute_powershell
					@Command = N'$PSVersionTable.PSVersion.ToString()', 
					@StringOutput = @output OUTPUT; 

				SELECT @output [version];

			-- same as above, but instead of xml as STRING, pull it out as XML:
				DECLARE @outputXML xml;
				EXEC dbo.execute_powershell 
					@Command = N'$PSVersionTable | ConvertTo-XML -As Stream;', 
					@SerializedXmlOutput = @outputXML OUTPUT; 

				SELECT @outputXML;

			-- similar to the above-ish, but JSON (string):
				EXEC dbo.execute_powershell @Command = N'$PSVersionTable | ConvertTo-Json;';

			-- and, similar to the immediate above, but ... parsing(ish) the resultant JSON: 
				DECLARE @json nvarchar(MAX);
				EXEC dbo.execute_powershell 
					@Command = N'$PSVersionTable | ConvertTo-Json;', 
					@StringOutput = @json OUTPUT; 

				SELECT @json;
				SELECT * FROM OPENJSON(@json) [messy - but json-y];

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[execute_powershell]','P') IS NOT NULL
	DROP PROC dbo.[execute_powershell];
GO

CREATE PROC dbo.[execute_powershell]
	@Command							nvarchar(MAX),
	@ExecutionAttemptsCount				int						= 2,								-- TOTAL number of times to try executing process - until either success (no error) or @ExecutionAttemptsCount reached. a value of 1 = NO retries... 
	@DelayBetweenAttempts				sysname					= N'5s',
	@PrintOnly							bit						= 0,
	@SerializedXmlOutput				xml						= N'<default/>'		OUTPUT, 
	@StringOutput						nvarchar(MAX)			= N''				OUTPUT,		-- Note that there's no reason this can't be JSON
	@ErrorMessage						nvarchar(MAX)			= NULL				OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @commandOutput xml; 
	DECLARE @returnValue int;

	EXEC @returnValue = [dbo].[execute_command]
		@Command = @Command,
		@ExecutionType = N'PS',   -- POSH
		@ExecutionAttemptsCount = @ExecutionAttemptsCount,
		@DelayBetweenAttempts = @DelayBetweenAttempts,
		@SafeResults = N'{ALL}',  -- we're just piping results to/from PowerShell
		@PrintOnly = @PrintOnly,
		@ErrorMessage = @ErrorMessage OUTPUT,
		@Outcome = @commandOutput OUTPUT;

	IF @returnValue <> 0 OR @ErrorMessage IS NOT NULL BEGIN 
		RETURN -5;
	END;

	DECLARE @output nvarchar(MAX) = N'';
	DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

	SELECT 
		@output = @output + n.r.value(N'(.)[1]', N'nvarchar(max)') + @crlf
	FROM 
		@commandOutput.nodes(N'//iterations/iteration/result_row') n(r); 

	IF @StringOutput IS NULL BEGIN 
		SELECT @StringOutput = @output;
		RETURN 0;
	END;

	IF (SELECT dbo.is_xml_empty(@SerializedXmlOutput)) = 1 BEGIN -- RETURN instead of project.. 
		BEGIN TRY
			-- NOTE: the FOR XML PATH output returned via dbo.execute_command ONLY encodes < and >, so only un-transform them via dbo.xml_decode (i.e., second parameter).
			SET @output = dbo.[xml_decode](@output, 1);

			-- HACK(ish):
			SET @output = REPLACE(@output, N' encoding="utf-8"?>', N' encoding="utf-16"?>');

			-- This might be a terrible idea: 
			SET @output = REPLACE(@output, N'&', N'&amp;');
	
			SELECT @SerializedXmlOutput = CAST(@output AS xml);
			RETURN 0;
		END TRY 
		BEGIN CATCH 
			SET @ErrorMessage = CAST (ERROR_NUMBER() AS sysname) + N': ' + ERROR_MESSAGE();
			RETURN -10;
		END CATCH;
	END;

	EXEC dbo.[print_long_string] @output;

	RETURN 0;
GO