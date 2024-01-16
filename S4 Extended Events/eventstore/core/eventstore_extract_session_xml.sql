/*

	pseudo-code for a consumer would be something like: 

		xestore_extract_blocked_processes 
			@SessionName = 'blocked_processes'; 
			and... i think that should be about it... 
				as in, this sproc would: 
					1. figure out they key to use for LSET/CET 
					2. get LSET/CET + XML via xestore_extract_session_xml 
					3. do whatever it needs to do with the xml
						
					4. and... if successful, pass back in attributes + CET and other details... 



*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[eventstore_extract_session_xml]','P') IS NOT NULL
	DROP PROC dbo.[eventstore_extract_session_xml];
GO

CREATE PROC dbo.[eventstore_extract_session_xml]
	@SessionName				sysname, 
	@Output						xml					OUTPUT, 
	@ExtractionID				int					OUTPUT, 
	@ExtractionAttributes		nvarchar(300)		OUTPUT, 
	@InitializationDaysBack		int					= 10
AS
    SET NOCOUNT ON; 

	-- {copyright}
	SET @SessionName = NULLIF(@SessionName, N'');

	IF @SessionName IS NULL BEGIN 
		RAISERROR(N'A valid @SessionName must be provided.', 16, 1);
		RETURN -1;
	END;

	DECLARE @SerializedOutput xml;
	EXEC dbo.[list_xe_sessions] 
		@TargetSessionName = @SessionName, 
		@IncludeDiagnostics = 1,
		@SerializedOutput = @SerializedOutput OUTPUT;

	IF dbo.[is_xml_empty](@SerializedOutput) = 1 BEGIN 
		RAISERROR(N'Target @SessionName: [%s] not found. Please verify @SessionName input.', 16, 1, @SessionName); 
		RETURN -10;
	END;

	DECLARE @cet datetime2;
	DECLARE @lset datetime2;
	DECLARE @attributes nvarchar(300);

	EXEC dbo.[xestore_initialize_extraction]
		@SessionName = @SessionName,
		@ExtractionID = @ExtractionID OUTPUT,
		@CET = @cet OUTPUT,
		@LSET = @lset OUTPUT,
		@Attributes = @attributes OUTPUT, 
        @InitializationDaysBack = @InitializationDaysBack;

	DECLARE @storageType sysname, @fileName sysname;
	SELECT 
		@storageType = [nodes].[data].value(N'(storage_type)[1]',N'sysname'), 
		@fileName = [nodes].[data].value(N'(file_name)[1]',N'sysname')
	FROM 
		@SerializedOutput.nodes(N'//session') [nodes] ([data]);

	IF @storageType = N'ring_buffer' BEGIN 
		SELECT 
			nodes.[event].query(N'(.)[1]') [event] 
			--nodes.[event].value(N'(@timestamp)[1]', N'datetime2(7)') [timestamp_utc]
		FROM 
			(
			SELECT 
				CAST([t].[target_data] AS xml) [events]
			FROM 
				sys.[dm_xe_database_sessions] s 
				INNER JOIN sys.[dm_xe_database_session_targets] t ON t.[event_session_address] = s.[address] 
			WHERE 
				s.[name] = @SessionName
			) [xml]
			CROSS APPLY [xml].[events].nodes(N'//event') [nodes]([event])
		WHERE 
			nodes.[event].value(N'(@timestamp)[1]', N'datetime2(7)') >= @lset 
			AND nodes.[event].value(N'(@timestamp)[1]', N'datetime2(7)') < @cet;
	  END; 
	ELSE BEGIN -- event_file
		/* Normalize and tokenize .xel file name: */
		IF @fileName NOT LIKE N'%`.xel' ESCAPE N'`' SET @fileName = @fileName + N'.xel';
		SET @fileName = REPLACE(@fileName, N'.xel', N'*.xel');
		
		DECLARE @fileAttribute sysname = NULL, @offsetAttribute bigint = NULL;

		IF @attributes IS NOT NULL BEGIN 
			SELECT 
				@fileAttribute = LEFT(@attributes, PATINDEX(N'%::%', @attributes) - 1), 
				@offsetAttribute = CAST(SUBSTRING(@attributes, PATINDEX(N'%::%', @attributes) +2, LEN(@attributes)) AS bigint); 
		END;

		CREATE TABLE #raw_xe_data (
			[row_id] int IDENTITY(1,1) NOT NULL, 
			[event_data] xml NOT NULL, 
			[file_name] nvarchar(260) NOT NULL, 
			[file_offset] bigint NOT NULL
		);
		
		IF dbo.[get_engine_version]() < 14.00 BEGIN 
			INSERT INTO [#raw_xe_data] (
				[event_data],
				[file_name],
				[file_offset]
			)			
			SELECT 
				[x].[XMLData] [event_data], 
				[x].[file_name], 
				[x].[file_offset]
			FROM (
				SELECT 
					CAST([event_data] AS xml) [XMLData], 
					[file_name], 
					[file_offset] 
				FROM 
					sys.[fn_xe_file_target_read_file](@fileName, NULL, @fileAttribute, @offsetAttribute)
			) AS [x] 
			WHERE 
				[x].[XMLData].value(N'(/event/@timestamp)[1]', N'datetime2') >= @lset AND [x].[XMLData].value(N'(/event/@timestamp)[1]', N'datetime2') < @cet;
		  END; 
		ELSE BEGIN
			INSERT INTO [#raw_xe_data] (
				[event_data],
				[file_name],
				[file_offset]
			)
			SELECT 
				[event_data],
				[file_name],
				[file_offset]
			FROM 
				sys.[fn_xe_file_target_read_file](@fileName, NULL, @fileAttribute, @offsetAttribute)
			WHERE 
				/* BUG: https://dba.stackexchange.com/a/323151/6100 */
				CAST([timestamp_utc] AS datetime2) >= @lset AND CAST([timestamp_utc] AS datetime2) < @cet;
		END;

		IF EXISTS (SELECT NULL FROM [#raw_xe_data]) BEGIN 
			DECLARE @newAttribute nvarchar(300);
			SELECT
				@newAttribute = [file_name] + N'::' + CAST([file_offset] AS sysname)
			FROM 
				[#raw_xe_data] 
			WHERE 
				[row_id] = (SELECT MAX(row_id) FROM [#raw_xe_data]);

			SET @ExtractionAttributes = @newAttribute;
		END;
	END; 

	SELECT @Output = (
		SELECT
			[event_data] [node()]  -- outputs WITHOUT creating new tags
		FROM 
			[#raw_xe_data]
		ORDER BY 
			[row_id] 
		FOR XML PATH(''), ROOT('events'), TYPE
	);

	RETURN 0;
GO