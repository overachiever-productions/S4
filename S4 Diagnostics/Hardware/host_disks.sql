/*


	.EXAMPLE: 
		Simplest Execution: 
		
		```sql 

		EXEC admindb.dbo.[host_disks];

		```
	.EXAMPLE: 
		Extract Results via XML for OUTPUT: 

		```sql 
		
		DECLARE @output xml; 
		EXEC admindb..[host_disks] 
			@serialized_output = @output OUTPUT; 

		SELECT @output;

		```

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[host_disks]', N'P') IS NOT NULL
	DROP PROC dbo.[host_disks];
GO

CREATE PROC dbo.[host_disks]
--	@disks							nvarchar(MAX)		= N'{ALL}',
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	--SET @disks = ISNULL(NULLIF(@disks, N''), N'{ALL}');

	DECLARE @cmd nvarchar(MAX) = N'Get-Volume | 
Where-Object { $_.DriveLetter } |
    Select-Object @{n=''Drive''; e={$_.DriveLetter}},
                  @{n=''Label''; e={$_.FileSystemLabel}},
                  @{n=''SizeGB''; e={[math]::Round($_.Size/1GB, 2)}},
                  @{n=''FreeGB''; e={[math]::Round($_.SizeRemaining/1GB, 2)}} | ConvertTo-Xml -As Stream; ';

	DECLARE @returnValue int, @xmlOutput xml, @errorMessage nvarchar(MAX);
	EXEC @returnValue = dbo.[execute_powershell]
		@Command = @cmd,
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
		[r].[disk].value(N'(Property[@Name="Drive"]/text())[1]', N'sysname') [drive], 
		[r].[disk].value(N'(Property[@Name="Label"]/text())[1]', N'sysname') [label],
		[r].[disk].value(N'(Property[@Name="SizeGB"]/text())[1]', N'decimal(6,2)') [size_gb],
		[r].[disk].value(N'(Property[@Name="FreeGB"]/text())[1]', N'decimal(6,2)') [free_gb]
	INTO 
		#disks
	FROM 
		@xmlOutput.nodes(N'/Objects/Object') [r]([disk]);

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN

		SELECT @serialized_output = (
			SELECT 
				[drive] [@drive],
				[label] [@label],
				[size_gb] [@size_gb],
				[free_gb] [@free_gb] 
			FROM 
				[#disks]		
			FOR XML PATH(N'disk'), ROOT(N'disks'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[drive],
		[label],
		[size_gb],
		[free_gb] 
	FROM 
		[#disks];