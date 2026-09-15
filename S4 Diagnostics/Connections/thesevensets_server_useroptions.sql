/*

	

*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[thesevensets_server_useroptions]', N'P') IS NOT NULL
	DROP PROC dbo.[thesevensets_server_useroptions];
GO

CREATE PROC dbo.[thesevensets_server_useroptions]
	@serialized_output				xml					= N'<default/>'	    OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @actualServerUserOptions int;
	DECLARE @configedServerUserOptions int;

	DECLARE @status sysname;
	DECLARE @detail xml;

	SELECT 
		@actualServerUserOptions = CAST([value_in_use] AS int), 
		@configedServerUserOptions = CAST([value] AS int)
	FROM 
		sys.[configurations] 
	WHERE 
		[name] = N'user options';

	IF @actualServerUserOptions <> @configedServerUserOptions BEGIN
		
		SET @status = N'CONFIG_CHANGES_PENDING';
		SET @detail = N'<detail status="sys.configurations has pending changes for ''user_options''." />';

		GOTO PROJECT_OR_RETURN;
	END;

	IF @actualServerUserOptions = 0 BEGIN 

		SET @status = N'DEFAULT_OPTIONS';
		SET @detail = N'<detail status="Server''s ''user_options'' value-in-use is [0] (default)." />';

		GOTO PROJECT_OR_RETURN;
	END;

	IF ((@actualServerUserOptions & 4472) = 4472) AND ((@actualServerUserOptions & 8192) = 0) BEGIN 
		SET @status = N'NO_CONFLICT_CUSTOM_OPTIONS'; 
		SET @detail = N'<detail status="Server''s ''user_options'' value-in-use is [' + CAST(@actualServerUserOptions AS nvarchar(6)) + N'] - which does NOT conflict with Seven SETs." />';
	  END;
	ELSE BEGIN 
		SET @status = N'CONFLICTS_DETECTED';
		SELECT @detail = N'<detail status="Server''s ''user_options'' CONFLICTS with Seven SETs. ">' + (
			SELECT 
				[flag] [@name],
				[seven_sets_default] [@required] ,
				[enabled] [@actual]
			FROM	
				dbo.[unmasked_useroptions](@actualServerUserOptions)
			WHERE 
				[seven_sets_default] IS NOT NULL
			FOR XML PATH(N'flag'), ROOT(N'flags')
		) + N'</detail>';
	END;

PROJECT_OR_RETURN:
	
	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
			
		SELECT @serialized_output = (
			SELECT 
				@status [current_state], 
				@detail [*]
			FOR XML PATH(N'results'), TYPE
		);

		RETURN 0;
	END;

	SELECT 
		@status [current_state], 
		@detail [details];

	RETURN 0;
GO