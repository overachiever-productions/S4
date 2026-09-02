/*



*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[verify_drivespace]', N'P') IS NOT NULL
	DROP PROC dbo.[verify_drivespace];
GO

CREATE PROC dbo.[verify_drivespace]
	@minimum_gb_threshold			decimal(8,1)		= 32.,
	@decrement_gb					decimal(3,2)		= 2.,
	@maximum_percent_threshold		decimal(4,2)		= NULL,
	@increment_percent				decimal(2,1)		= NULL,
	@excluded_drives				sysname				= NULL,		-- comma-separated list of drives to exclude from checks.
	@options						nvarchar(MAX)		= NULL,		-- OPTIONS: @operator, @profile, @alert_prefix. 
	@print_only						bit					= 0
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	DECLARE @moduleKey sysname = QUOTENAME(OBJECT_SCHEMA_NAME(@@PROCID)) + N'.' + QUOTENAME(OBJECT_NAME(@@PROCID));

	SET @minimum_gb_threshold = ISNULL(NULLIF(@minimum_gb_threshold, 0.), (SELECT CAST(dbo.extract_option(@moduleKey, N'@minimum_gb_threshold') AS decimal(8,1))));
	SET @decrement_gb = ISNULL(NULLIF(@decrement_gb, 0.), (SELECT CAST(dbo.extract_option(@moduleKey, N'@decrement_gb') AS decimal(3,2))));
	SET @maximum_percent_threshold = ISNULL(NULLIF(@maximum_percent_threshold, 0.), (SELECT CAST(dbo.extract_option(@moduleKey, N'@maximum_percent_threshold') AS decimal(4,2))));
	SET @increment_percent = ISNULL(NULLIF(@increment_percent, 0.), (SELECT CAST(dbo.extract_option(@moduleKey, N'@increment_percent') AS decimal(2,1))));

	SET @excluded_drives = ISNULL(NULLIF(@excluded_drives, N''), (SELECT dbo.extract_option(@moduleKey, N'@excluded_drives')));
	
	SET @options = NULLIF(@options, N'');
	SET @print_only = ISNULL(@print_only, 0);
	SET @maximum_percent_threshold = NULLIF(@maximum_percent_threshold, 0.0);
	SET @increment_percent = NULLIF(@increment_percent, 0.0);

	DECLARE @operator sysname = NULL, @profile sysname = NULL, @alert_prefix sysname = NULL;
	SET @operator = ISNULL(dbo.extract_parameter_option(@options, N'@operator'), (SELECT dbo.extract_option(@moduleKey, N'@operator')));
	SET @profile = ISNULL(dbo.extract_parameter_option(@options, N'@profile'), (SELECT dbo.extract_option(@moduleKey, N'@profile')));
	SET @alert_prefix = ISNULL(dbo.extract_parameter_option(@options, N'@alert_prefix'), (SELECT dbo.extract_option(@moduleKey, N'@alert_prefix')));

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Parameter Validation:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	SET @minimum_gb_threshold = ISNULL(@minimum_gb_threshold, 0.);
	SET @maximum_percent_threshold = ISNULL(@maximum_percent_threshold, 0.);
	SET @decrement_gb = ISNULL(@decrement_gb, 0.);
	SET @increment_percent = ISNULL(@increment_percent, 0.);

-- TODO: standardize these to localized errors... 
	IF @minimum_gb_threshold = 0. AND @maximum_percent_threshold = 0. BEGIN
		RAISERROR(N'A @minimum_gb_threshold or @maximum_percent_threshold must be specified.', 16, 1);
		RETURN -1;
	END;

	IF @minimum_gb_threshold > 0. AND @decrement_gb <= 0. BEGIN
		RAISERROR(N'If using @minimum_gb_threshold, a @decrement_gb value must be specified.', 16, 1);
		RETURN -2;
	END;

	IF @maximum_percent_threshold > 0. AND @increment_percent <= 0. BEGIN
		RAISERROR(N'If using @maximum_percent_threshold, a @increment_percent value must be specified.', 16, 1);
		RETURN -3;
	END;

	IF @print_only = 0 BEGIN
		IF @operator IS NULL BEGIN
			RAISERROR(N'For email alerts, an @operator must be specified.', 16, 1);
			RETURN -4;
		END;

		IF @profile IS NULL BEGIN
			RAISERROR(N'For email alerts,a @profile must be specified.', 16, 1);
			RETURN -5;
		END;
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Identify Potential Problems:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @core table (
		drive sysname NOT NULL, 
		available_gbs decimal(14,2) NOT NULL, 
		total_gbs decimal(14,2) NOT NULL, 
		[%_used] decimal(5,2) NOT NULL
	);

	DECLARE @output xml; 
	EXEC dbo.[system_disks] @serialized_output = @output OUTPUT; 
	
	WITH [disks] AS ( 
		SELECT 
			[drive],
			[free_gb] [available_gbs],
			[size_gb] [total_gbs]
		FROM 
			dbo.system_disks_data(@output)
	) 

	INSERT INTO @core (drive, [available_gbs], [total_gbs], [%_used])
	SELECT 
		UPPER([drive]) [drive],
		[available_gbs],
		[total_gbs], 
		CAST(100.0 - ([available_gbs] / [total_gbs] * 100.0) AS decimal(5,2)) [%_used]
	FROM 
		[disks] 
	ORDER BY 
		[drive];

	DECLARE @problems table (
		[drive] sysname NOT NULL,
		[available_gbs] decimal(14, 2) NOT NULL,
		[total_gbs] decimal(14, 2) NOT NULL,
		[%_used] decimal(5, 2) NOT NULL,
		[threshold] sysname NOT NULL
	);

	IF @minimum_gb_threshold > 0. BEGIN
		INSERT INTO @problems ([drive], [available_gbs], [total_gbs], [%_used], [threshold])
		SELECT 
			[drive],
			[available_gbs],
			[total_gbs],
			[%_used], 
			N'< ' + CAST(@minimum_gb_threshold AS sysname) + N'GB' [threshold]
		FROM 
			@core 
		WHERE 
			@minimum_gb_threshold > available_gbs;
	END;

	IF @maximum_percent_threshold > 0. BEGIN
		INSERT INTO @problems ([drive], [available_gbs], [total_gbs], [%_used], [threshold])
		SELECT 
			[drive],
			[available_gbs],
			[total_gbs],
			[%_used], 
			N'> ' + CAST(CAST(@maximum_percent_threshold AS decimal(5,2)) AS sysname) + N'%' [threshold]
		FROM 
			@core 
		WHERE 
			[%_used] > CAST(@maximum_percent_threshold AS decimal(5,2));
	END;

	IF @excluded_drives IS NOT NULL BEGIN
		DELETE FROM @problems 
		WHERE 
			LEFT([drive], 1) IN (SELECT UPPER(LEFT([result], 1)) FROM dbo.split_string(@excluded_drives, N',', 1));
	END;

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Check for ACTIVE incidents:
		4 (main) Possible Scenarios:
		A. Nothing active, no problems.
		B. (NEW) Problems, nothing active. (log/flag a new active incident + send an alert)
		C. Ongoing active incident: 
			- disk size hasn't decremented to @decrement_xxx so ... nothing to do (i.e., bail). 
			- disk size HAS decremented < @decrement_xxx ... update state/history and alert. 
			- one or more NEW disks have run into problems. 
			- one or more 'old' disks have become fixed. 
			- sigh. 
		D. Any/ALL active incidents have been resolved. update states/history + "SUCCESS" alert. 

		NOTE: The logic above 'accidentally' covers an odd use-case/scenario in the form of: 
			- assume we've set a threshold for 100GB free... 
			- we're in a MAINT WINDOW where we KNOW we're going to hammer the snot out of the T-LOG and decrease space. 
			- We get our first alert: "oh noes! < 100GB free". 
			- We KNOW this is going to keep going down and down - sending email alerts every NGB decrement.
			- So, we pro-actively go and change the threshold to 20GB free. (with a smaller decremnt or not). 
				(obviously, it's "on us" to go back and fix this after maint window). 
			- IF the above (slightly odd/border-line fantastical) scenario occurs: 
				- as long as we're > new-thresholdGB free: 
				- we won't have an @problems. 
				- But we WILL see that there's an 'active' incident. 
				- Only, we'll close the incident. 
				-	yeah... we'll get a 'success' / restored alert. 
				- but we'll also store historical meta-data. 
			- In short, this scenario is "fully covered". 
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE @activeAlertState int;
	SELECT @activeAlertState = [state_id] FROM dbo.[alert_states] WHERE [alert_type] = @moduleKey AND [end] IS NULL;

	/* A. Nothing. Bail. */
	IF @activeAlertState IS NULL AND NOT EXISTS (SELECT NULL FROM @problems) BEGIN
		RETURN 0;
	END;

	DECLARE @activeIncident xml = (
		SELECT TOP (1) 
			[detail]
		FROM 
			[dbo].[alert_state_details] 
		WHERE 
			[state_id] = @activeAlertState
		ORDER BY 
			[timestamp] DESC
	);

	DECLARE @subject nvarchar(200) = ISNULL(@alert_prefix, N'') + N'Low Disk Notification';
	DECLARE @stateId int;
	DECLARE @payload xml, @indicators xml, @details xml, @extended xml;
	DECLARE @classification sysname = N'ALERT';
	DECLARE @warningsCount int = (SELECT COUNT(*) FROM @problems);
	DECLARE @indications table ( 
		[row_id] int NOT NULL,
		[name] sysname NOT NULL, 
		[value] sysname NOT NULL,
		[style] sysname NOT NULL,
		[context] sysname NULL
	);

	DECLARE @thresholds table (
		[threshold_type] sysname NOT NULL,
		[threshold_value] sysname NOT NULL
	);
 
	INSERT INTO @thresholds ([threshold_type], [threshold_value])
	VALUES
		(N'GB', CAST(@minimum_gb_threshold AS sysname)),
		(N'PERCENT', CAST(@maximum_percent_threshold AS sysname));

	IF @minimum_gb_threshold = 0. DELETE FROM @thresholds WHERE [threshold_type] = N'GB';
	IF @maximum_percent_threshold = 0. DELETE FROM @thresholds WHERE [threshold_type] = N'PERCENT';

	/* D. Any/ALL Incidents have been Resolved. */
	IF @activeAlertState IS NOT NULL AND NOT EXISTS (SELECT NULL FROM @problems) BEGIN
		WITH historical AS (
			SELECT 
				[data].[row].value(N'drive[1]', N'sysname') [drive],
				[data].[row].value(N'total_gbs[1]', N'decimal(14,2)') [total_gbs],
				[data].[row].value(N'free_gbs[1]', N'decimal(14,2)') [available_gbs], 
				[data].[row].value(N'threshold[1]', N'sysname') [threshold]
			FROM 
				@activeIncident.nodes(N'/violations/violation') AS [data]([row])
		)

		SELECT @details = (
			SELECT
				[h].[drive],
				[h].[total_gbs] [disk_size],
				(SELECT TOP (1) [available_gbs] FROM @core WHERE [drive] = [h].[drive]) [free_gb],
				[h].[threshold], 
				(SELECT TOP (1) [%_used] FROM @core WHERE [drive] = [h].[drive]) [used]
			FROM 
				[historical] [h]
			FOR XML PATH(N'detail'), ROOT(N'details'), TYPE
		);

		DECLARE @thesholdXml xml = (
			SELECT 
				[threshold_type] [@type],
				[threshold_value] [@value]
			FROM 
				@thresholds 
			FOR XML PATH(N'threshold'), ROOT(N'thresholds'), TYPE
		);

		SELECT @payload = N'<resolution>
			' + CAST(@thesholdXml.query('.') AS nvarchar(MAX)) + N'
			' + CAST(@details.query('.') AS nvarchar(MAX)) + N'
		</resolution>';

		INSERT INTO dbo.[alert_state_details] ([state_id], [summary], [detail])
		VALUES (@activeAlertState, N'RESOLVED', @payload);

		UPDATE dbo.[alert_states] 
		SET 
			[end] = GETDATE() 
		WHERE 
			[state_id] = @activeAlertState;

		INSERT INTO @indications ([row_id], [name], [value], [style], [context])
		VALUES 
			(1, N'SERVER', @@SERVERNAME, N'info', NULL),
			(2, N'Status', N'No Violations', N'info', N'ALL disk violations resolved'),
			(3, N'Resolution', CONVERT(sysname, GETDATE(), 8), N'info', N'Local Server Time');

		SELECT @indicators = (	
			SELECT 
				[row_id] [@priority],
				[name],
				[value],
				[style],
				[context] 
			FROM 
				@indications 
			FOR XML PATH(N'indicator'), ROOT(N'indicators'), TYPE
		);

		SET @classification = N'SUCCESS';
		SET @subject = @subject + N' - Violation(s) Resolved';

		GOTO Send_Notification;
	END;

	/* B. New Incident. Meta-Data + Alert */
	IF EXISTS (SELECT NULL FROM @problems) AND @activeAlertState IS NULL BEGIN
		SET @indicators = N'<indicators>
			<indicator priority="1">
				<name>SERVER</name>
				<value>' + @@SERVERNAME + N'</value>
				<style>error</style>
			</indicator>
			<indicator priority="2">
				<name>Warnings Count</name>
				<value>'+ CAST(@warningsCount AS sysname) + '</value>
				<style>warning</style>
				<context>Threshold Violations</context>
			</indicator>
			<indicator priority="3">
				<name>Alert Raised</name>
				<value>' + CONVERT(sysname, GETDATE(), 8) + N'</value>
				<style>info</style>
				<context>Local Server Time</context>
			</indicator>
		</indicators>';		

		SET @details = (
			SELECT 
				[drive],
				CAST([total_gbs] AS sysname) + N'GB' [disk_size],
				CAST([available_gbs] AS sysname) + N'GB' [free_space],
				[threshold] + CASE WHEN [threshold] LIKE N'%GB' THEN N' free' ELSE N' used' END [threshold],
				CAST([%_used] AS sysname) + N'%' [used]
			FROM 
				@problems
			ORDER BY 
				[drive]
			FOR XML PATH(N'detail'), ROOT(N'details'), TYPE
		);

		SELECT @payload = (
			SELECT 
				[drive], 
				[total_gbs], 
				[available_gbs] [free_gbs], 
				[threshold], 
				CASE WHEN [threshold] LIKE N'%GB' THEN CAST(@decrement_gb AS sysname) + N'GB' ELSE CAST(@increment_percent AS sysname) + N'%' END [decrement]
			FROM 
				@problems
			FOR XML PATH(N'violation'), ROOT(N'violations'), TYPE
		);

		INSERT INTO dbo.[alert_states] ([alert_type], [start])
		VALUES (@moduleKey, GETDATE());

		SELECT @stateId = SCOPE_IDENTITY();

		INSERT INTO dbo.[alert_state_details] ([state_id], [summary], [detail])
		VALUES (@stateId, N'NEW_VIOLATION', @payload);

		SET @subject = @subject + N' - New Violation(s)';

		GOTO Send_Notification;
	END;

	/* C. Ongoing issues (or new issues concurrent with some/any ongoing issues). */
	WITH historical AS (
		SELECT 
			[data].[row].value(N'drive[1]', N'sysname') [drive],
			[data].[row].value(N'total_gbs[1]', N'decimal(14,2)') [total_gbs],
			[data].[row].value(N'free_gbs[1]', N'decimal(14,2)') [available_gbs], 
			[data].[row].value(N'threshold[1]', N'sysname') [threshold]
		FROM 
			@activeIncident.nodes(N'/violations/violation') AS [data]([row])
	)

	SELECT 
		[drive],
		[total_gbs],
		[available_gbs],
		CASE WHEN [historical].[threshold] LIKE N'%GB' THEN N'GB' ELSE N'%' END [threshold_type]
	INTO 
		#historical
	FROM 
		[historical];

	SELECT 
		IDENTITY(int, 1,1) [row_id],	
		[p].[drive],
		[p].[available_gbs] [current_free],
		[h].[available_gbs] [previous_free],
		[p].[total_gbs],
		[p].[threshold],
		[h].[threshold_type], 
		CASE 
			WHEN [p].[available_gbs] = [h].[available_gbs] THEN 'NO-CHANGE'
			WHEN [p].[available_gbs] < [h].[available_gbs] THEN 'LESS-SPACE'
			WHEN [p].[available_gbs] > [h].[available_gbs] THEN 'RECLAIMED'
			ELSE N'ADDITIONAL-VIOLATION'
		END [state], 
		CAST(N'' AS sysname) [outcome]
	INTO
		#current_states
	FROM 
		@problems [p]
		LEFT OUTER JOIN #historical [h] ON [p].[drive] = [h].[drive]
			AND CASE WHEN [p].[threshold] LIKE N'%GB' THEN N'GB' ELSE N'%' END = [h].[threshold_type];

-- TODO: 
--		account for a [state] of 'PARTIAL-RESOLUTION'. 
--		where one or more drives have been resolved, but we're STILL seeing OTHER problems. 
--		i.e., the #currentStates JOIN accounts for 'new' (ADDITIONAL-VIOLATION) incidents, but JOIN-type doesn't account for PARTIAL-RESOLUTION.

	IF EXISTS (SELECT NULL FROM [#current_states] WHERE [state] <> N'NO-CHANGE') BEGIN
		
		DECLARE @rowId int, @drive sysname, @currentFree decimal(14,2), @previousFree decimal(14,2), @state sysname, @thresholdType sysname;
		DECLARE @previousFence decimal(14,2), @currentFence decimal(14,2) = 0.0;

		/* CURSORS are a wee-bit ugly... but there's SO MUCH logic to address here... and the data-set/sizes are trivial */
		DECLARE [walker] CURSOR LOCAL FAST_FORWARD FOR 
		SELECT 
			[row_id],
			[drive],
			[current_free],
			[previous_free],
			[state], 
			[threshold_type]
		FROM 
			[#current_states]
		WHERE 
			[state] <> N'NO-CHANGE';
		
		OPEN [walker];
		FETCH NEXT FROM [walker] INTO @rowId, @drive, @currentFree, @previousFree, @state, @thresholdType;
		
		WHILE @@FETCH_STATUS = 0 BEGIN
		
			IF @state = N'LESS-SPACE' BEGIN
				
				IF @thresholdType = N'%' BEGIN 
					SET @previousFence = FLOOR((@maximum_percent_threshold - @previousFree) / @increment_percent);
					SET @currentFence = FLOOR((@maximum_percent_threshold - @currentFree) / @increment_percent);

					IF @currentFence > @previousFence BEGIN
						UPDATE [#current_states]
						SET 
							[outcome] = N'AVAILABLE DISK DECREASED'
						WHERE 
							[row_id] = @rowId;
					END;
				  END;
				ELSE BEGIN 
					SET @previousFence = FLOOR((@minimum_gb_threshold - @previousFree) / @decrement_gb);
					SET @currentFence = FLOOR((@minimum_gb_threshold - @currentFree) / @decrement_gb);

					IF @currentFence > @previousFence BEGIN
						UPDATE #current_states  
						SET 
							[outcome] = N'AVAILABLE DISK DECREASED'
						WHERE 
							[row_id] = @rowId;
					END;
				END;
			END;

			IF @state = N'RECLAIMED' BEGIN
				/* Some free-space was returned/reclaimed. But NOT enough to get above alerting thresholds. */
				UPDATE #current_states 
				SET 
					[outcome] = N'RECLAIMED (IGNORED)'
				WHERE 
					[row_id] = @rowId;
			END;

			IF @state = N'ADDITIONAL-VIOLATION' BEGIN
				UPDATE #current_states  
				SET 
					[outcome] = N'NEW DISK (VIOLATION)' /* If this disk wasn't causing problems before, it IS now. Need to ALERT on it. */
				WHERE 
					[row_id] = @rowId;
			END;

			IF @state = N'PARTIAL-RESOLUTION' BEGIN
				/* Multiple disks are/were in violation - but this (current) disk is no longer in violation. */
				UPDATE #current_states 
				SET 
					[outcome] = N'DISK RECOVERED (NO VIOLATION)'
				WHERE 
					[row_id] = @rowId;
			END;
		
			FETCH NEXT FROM [walker] INTO @rowId, @drive, @currentFree, @previousFree, @state, @thresholdType;
		END;
		
		CLOSE [walker];
		DEALLOCATE [walker];

		DELETE FROM [#current_states] WHERE [outcome] = N'';

		IF NOT EXISTS(SELECT NULL FROM [#current_states]) BEGIN
			RETURN 0; /* All violations are NO-CHANGE. Nothing to do. */
		END;

		IF NOT EXISTS (SELECT NULL FROM [#current_states] WHERE outcome <> N'') BEGIN
			RETURN 0; /* No new DECREMENTS or NEW Violations. Disk Reclaimed, but NOT enough to void violation. */
		END;

		SELECT @payload = (
			SELECT 
				[drive], 
				[total_gbs],
				[current_free] [free_gbs], 
				[threshold], 
				CASE WHEN [threshold] LIKE N'%GB' THEN CAST(@decrement_gb AS sysname) + N'GB' ELSE CAST(@increment_percent AS sysname) + N'%' END [decrement], 
				[outcome] [context]
			FROM 
				[#current_states]
			FOR XML PATH(N'violation'), ROOT(N'violations'), TYPE
		);

		SET @classification = N'ALERT';

		INSERT INTO @indications ([row_id], [name], [value], [style], [context])
		VALUES 
			(1, N'SERVER', @@SERVERNAME, N'error', NULL),
			(2, N'STATUS', N'DEGRADED', N'error', N'Increased Disk Violations'),
			(3, N'Alert Raised', CONVERT(sysname, GETDATE(), 8), N'info', N'Local Server Time');

		SELECT @indicators = (	
			SELECT 
				[row_id] [@priority],
				[name],
				[value],
				[style],
				[context] 
			FROM 
				@indications 
			FOR XML PATH(N'indicator'), ROOT(N'indicators'), TYPE
		);

		SELECT @details = (
			SELECT 
				[drive],
				CAST([total_gbs] AS sysname) + N'GB' [disk_size],
				CAST([current_free] AS sysname) + N'GB' [free_space],
				[threshold],
				CAST((SELECT TOP (1) [%_used] FROM @core WHERE [drive] = [#current_states].[drive]) AS sysname) + N'%' [used]
			FROM 
				[#current_states]
			FOR XML PATH(N'detail'), ROOT(N'details'), TYPE
		);

		SELECT @extended = (
			SELECT 
				[drive],
				[outcome] [event], 
				CAST([previous_free] AS sysname) + N'GB' [previous_free],
				ISNULL(CAST([current_free] AS sysname) + N'GB', N'> {threshold}') [current_free]
			FROM 
				[#current_states]
			FOR XML PATH(N'detail'), ROOT(N'extended'), TYPE
		);

		INSERT INTO dbo.[alert_state_details] ([state_id], [summary], [detail])
		VALUES (@activeAlertState, N'ONGOING_VIOLATION(s)', @payload);
		
		IF (SELECT COUNT(*) FROM [#current_states]) = 1 BEGIN
			IF EXISTS (SELECT NULL FROM [#current_states] WHERE [outcome] = N'AVAILABLE DISK DECREASED') BEGIN
				SET @subject = @subject + N' - Availabile Disk Decreased';
			END;
		  END;
		ELSE BEGIN
			SET @subject = @subject + N' - Ongoing Violation(s)';
		END;

		GOTO Send_Notification;
	END;

	/* There ARE violations, but they're 'NO-CHANGE' and have already been reported. */
	RETURN 0;  

Send_Notification:

		IF @print_only = 1 BEGIN 
			PRINT N'SUBJECT: ' + @subject; 
			PRINT N'BODY: '; 
			PRINT N'	INDICATORS: ' + dbo.[format_xml_string](@indicators);
			PRINT N'	DETAILS: ' + dbo.[format_xml_string](@details);
		  END;
		ELSE BEGIN
			DECLARE @body nvarchar(MAX);

			EXEC [dbo].[format_html_email]
				@classification = @classification,
				@title = @subject,
				@recipients = @operator,
				@indicators = @indicators,
				@details = @details,
				@extended = @extended,
				@output = @body OUTPUT;
		
			EXEC dbo.[notify_operator]
				@profile_name = @profile,
				@operator_name = @operator,
				@subject = @subject,
				@body = @body,
				@body_format = 'HTML',
				@print_only = 0;
		END;

	RETURN 0;
GO 