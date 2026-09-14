/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[directory_sizing]', N'P') IS NOT NULL
	DROP PROC dbo.[directory_sizing];
GO

CREATE PROC dbo.[directory_sizing]
	@path							sysname,
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @command nvarchar(MAX) = N'Get-ChildItem -Path "{path}" -Directory | ForEach-Object { 
		$s = Get-ChildItem $_.FullName -File -Recurse -Force -EA SilentlyContinue | 
		Measure-Object Length -Sum -Maximum -Average; 
		[pscustomobject]@{ 
			Directory = $_.Name; 
			Files = $s.Count; 
			TotalMB = [Math]::Round($s.Sum / 1MB, 2); 
			LargestMB = [Math]::Round($s.Maximum / 1MB, 2); 
			AvgMB = [Math]::Round($s.Average / 1MB, 2) } 
	} | Select-Object Directory, Files, TotalMB, LargestMB, AvgMB  | ConvertTo-Xml -As Stream -NoTypeInformation; ';
	
	SET @command = REPLACE(@command, N'{path}', @path);

	DECLARE @returnValue int, @xmlOutput xml, @errorMessage nvarchar(MAX);
	EXEC @returnValue = dbo.[execute_powershell]
		@Command = @command,
		@ExecutionAttemptsCount = 1,
		@SerializedXmlOutput = @xmlOutput OUTPUT,
		@ErrorMessage = @errorMessage OUTPUT; 

	IF @returnValue <> 0 OR @errorMessage IS NOT NULL BEGIN 
-- TODO: ... centralize/localize these... (which ... yeah). 
		SET @errorMessage = ISNULL(@errorMessage, N'Unexpected PowerShell Error.');
		RAISERROR(@errorMessage, 16, 1);
		
		RETURN ISNULL(@returnValue, -1);
	END;

	SELECT 
		[r].[directory].value(N'(Property[@Name="Directory"]/text())[1]', N'sysname') [directory],
		[r].[directory].value(N'(Property[@Name="Files"]/text())[1]', N'int') [file_count],
		[r].[directory].value(N'(Property[@Name="TotalMB"]/text())[1]', N'decimal(22,2)') [total_mb],
		[r].[directory].value(N'(Property[@Name="LargestMB"]/text())[1]', N'decimal(22,2)') [largest_mb],
		[r].[directory].value(N'(Property[@Name="AvgMB"]/text())[1]', N'decimal(22,2)') [avg_mb]
	INTO 
		#directories
	FROM 
		@xmlOutput.nodes(N'/Objects/Object') [r]([directory])

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT
				[directory] [@name],
				[file_count] [@file_count],
				[total_mb] [@total_mb],
				[largest_mb] [@largest_mb],
				[avg_mb] [@avg_mb] 
			FROM 
				[#directories]
			FOR XML PATH(N'directory'), ROOT(N'directories'), TYPE
		);

		RETURN 0
	END;

	SELECT
		[directory],
		[file_count],
		[total_mb],
		[largest_mb],
		[avg_mb] 
	FROM 
		[#directories];


	RETURN 0;
GO