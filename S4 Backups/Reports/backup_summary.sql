/*

		MKC: 
			I spent ... a decent amount of time on this - making it viable as a 'summary' ... 
			it's ... arguably a bit too verbose. 
			sigh. 


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[backup_summary]','P') IS NOT NULL
	DROP PROC dbo.[backup_summary];
GO

CREATE PROC dbo.[backup_summary]
	@days_back						int					= 1, 
	@databases						nvarchar(MAX)		= N'{ALL}', 
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

	WITH [databases] AS ( 
		SELECT 
			[database]
		FROM 
			dbo.[backup_log]
		WHERE 
			[backup_date] >= DATEADD(DAY, 0 - @days_back, GETDATE())
		GROUP BY 
			[database]
	), 
	hierarchy AS ( 
		SELECT 
			[order], 
			[type]
		FROM 
			(VALUES (1, N'FULL'), (2, N'DIFF'), (3, N'LOG')) AS backup_types ([order], [type])
	)

	SELECT 
		[d].[database],
		[x].[order],
		[x].[type] 
	INTO 
		#framed
	FROM 
		[databases] [d]
		CROSS APPLY (
			SELECT 
				[hierarchy].[order],
				[hierarchy].[type] 
			FROM 
				[hierarchy]
		) [x]; 

	
	WITH core AS ( 
		SELECT 
			[backup_date],
			[database],
			[backup_type],
			DATEDIFF(MILLISECOND, [backup_start], [backup_end]) AS backup_milliseconds,
			CAST([backup_succeeded] AS int) [backup_succeeded],
			CAST([copy_succeeded] AS int) [copy_succeeded],
			[copy_seconds],
			CAST([offsite_succeeded] AS int) [offsite_succeeded],
			[offsite_seconds],
			[error_details] 
		FROM 
			[admindb]..[backup_log] 
		WHERE 
			[backup_date] >= DATEADD(DAY, -1, GETDATE())
	),
	aggregated AS ( 
		SELECT 
			[backup_date],
			[database],
			[backup_type],
			COUNT(*) [backup_count],
			SUM([backup_succeeded]) [successful_backups],
			COUNT(*) - SUM([backup_succeeded]) [failed_backups],
			dbo.[format_timespan](SUM(backup_milliseconds)) [total_duration],
			SUM([copy_succeeded]) [copy_succeeded_count],
			SUM([copy_seconds]) [copy_seconds],
			SUM(CASE WHEN [error_details] IS NULL THEN 0 ELSE 1 END) [error_count]
		FROM		 
			core 
		GROUP BY 
			[backup_date],
			[database], 
			[backup_type]
	), 
	correlated AS ( 
		SELECT 
			[x].[order], 
			[a].[backup_date],
			[a].[database],
			[a].[backup_type],
			[a].[backup_count],
			[a].[successful_backups],
			[a].[total_duration],
			[a].[failed_backups],
			[a].[copy_succeeded_count],
			[a].[copy_seconds],
			[a].[error_count]
		FROM 
			#framed [x]
			LEFT OUTER JOIN aggregated [a] ON [x].[database] = [a].[database] AND [x].[type] = [a].[backup_type]
		WHERE 
			[a].[database] IS NOT NULL
	)

	SELECT 
		IDENTITY(int, 1, 1) [row_id],
		[backup_date],
		[database],
		[backup_type],
		[backup_count],
		[successful_backups],
		[total_duration],
		[failed_backups],
		[copy_succeeded_count],
		[copy_seconds],
		[error_count], 
		ISNULL((SELECT STRING_AGG([error_details], '; ') FROM [core] [c] WHERE [c].[database] = [correlated].[database]), N'') [error_details]
	INTO 
		#intermediate
	FROM 
		[correlated]
	ORDER BY 
		[database], 
		[order];

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		SELECT @serialized_output = (
			SELECT 
				[backup_date],
				[database],
				[backup_type],
				[backup_count],
				[successful_backups],
				[total_duration],
				[failed_backups],
				[copy_succeeded_count],
				[copy_seconds],
				[error_count],
				[error_details]
			FROM 
				[#intermediate] 
			ORDER BY 
				row_id
			FOR XML PATH(N'summary'), ROOT(N'summaries'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		[backup_date],
		CASE WHEN [backup_type] = N'FULL' THEN [database] ELSE N'' END [database],
		CASE WHEN [backup_type] = N'FULL' THEN [backup_type] ELSE N'   ' + [backup_type] END [backup_type],
		[backup_count],
		[successful_backups],
		[total_duration],
		[failed_backups],
		[copy_succeeded_count],
		[copy_seconds],
		[error_count],
		[error_details] 
	FROM 
		[#intermediate]
	ORDER BY 
		[row_id];

	RETURN 0;
GO