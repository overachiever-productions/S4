/*


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[generate_bounding_times]','P') IS NOT NULL
	DROP PROC dbo.[generate_bounding_times];
GO

CREATE PROC dbo.[generate_bounding_times]
	@Start						datetime,
	@End						datetime,
	@Minutes					int, 
	@SerializedOutput			xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	IF @End < @Start BEGIN 
		RAISERROR(N'@End can NOT be earlier than @Start.', 16, 1);
		RETURN -1;
	END;

	IF @End = @Start BEGIN 
		RAISERROR(N'@Start and @End may NOT be the same value.', 16, 1);
		RETURN -2;
	END;

	SELECT 
		@Start = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @Start) / @Minutes * @Minutes, 0), 
		@End = DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @End) / @Minutes * @Minutes, 0);

	CREATE TABLE #times (
		[block_id] int IDENTITY(1,1) NOT NULL, 
		[time_block] datetime NOT NULL
	);
	
	WITH times AS ( 
		SELECT @Start [time_block] 

		UNION ALL 

		SELECT DATEADD(MINUTE, @Minutes, [time_block]) [time_block]
		FROM [times]
		WHERE [time_block] < @End
	) 

	INSERT INTO [#times] (
		[time_block]
	)
	SELECT [time_block] 
	FROM times
	OPTION (MAXRECURSION 0);

	IF (SELECT dbo.is_xml_empty(@SerializedOutput)) = 1 BEGIN -- RETURN instead of project.. 
		SELECT @SerializedOutput = (
			SELECT 
				[block_id],
				[time_block]
			FROM 
				[#times] 
			ORDER BY 
				[block_id]
			FOR XML PATH(N'time'), ROOT(N'times'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[time_block] 
	FROM 
		[#times] 
	ORDER BY 
		[block_id];

	RETURN 0;
GO