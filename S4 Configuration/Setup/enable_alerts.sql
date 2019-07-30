/*
    TODO: 
        - verify that @OperatorName is a valid operator... (and that there's a mail profile created/configured).
    

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.enable_alerts','P') IS NOT NULL
	DROP PROC dbo.[enable_alerts];
GO

CREATE PROC dbo.[enable_alerts]
    @OperatorName                   sysname             = N'Alerts',
    @AlertTypes                     sysname             = N'SEVERITY_AND_IO',       -- SEVERITY | IO | SEVERITY_AND_IO
    @PrintOnly                      bit                 = 0
AS
    SET NOCOUNT ON; 

    -- {copyright}

    -- TODO: verify that @OperatorName is a valid operator.

    IF UPPER(@AlertTypes) NOT IN (N'SEVERITY', N'IO', N'SEVERITY_AND_IO') BEGIN 
        RAISERROR('Valid @AlertTypes are { SEVERITY | IO | SEVERITY_AND_IO }.', 16, 1);
        RETURN -5;
    END;

    DECLARE @ioAlerts table (
        message_id int NOT NULL, 
        [name] sysname NOT NULL
    );

    DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);

    DECLARE @alertTemplate nvarchar(MAX) = N'------- {name}
IF NOT EXISTS (SELECT NULL FROM msdb.dbo.sysalerts WHERE severity = {severity} AND [name] = N''{name}'') BEGIN
    EXEC msdb.dbo.sp_add_alert 
	    @name = N''{name}'', 
        @message_id = {id},
        @severity = {severity},
        @enabled = 1,
        @delay_between_responses = 0,
        @include_event_description_in = 1; 
    EXEC msdb.dbo.sp_add_notification 
	    @alert_name = N''{name}'', 
	    @operator_name = N''{operator}'', 
	    @notification_method = 1; 
END;' ;

    SET @alertTemplate = REPLACE(@alertTemplate, N'{operator}', @OperatorName);

    DECLARE @command nvarchar(MAX) = N'';

    IF UPPER(@AlertTypes) IN (N'SEVERITY', N'SEVERITY_AND_IO') BEGIN
            
        DECLARE @severityTemplate nvarchar(MAX) = REPLACE(@alertTemplate, N'{id}', N'0');
        SET @severityTemplate = REPLACE(@severityTemplate, N'{name}', N'Severity 0{severity}');

        WITH numbers AS ( 
            SELECT 
                ROW_NUMBER() OVER (ORDER BY [object_id]) [severity]
            FROM 
                sys.[objects] 
            WHERE 
                [object_id] < 50
        )

        SELECT
            @command = @command + @crlf + @crlf + REPLACE(@severityTemplate, N'{severity}', severity)
        FROM 
            numbers
        WHERE 
            [severity] >= 17 AND [severity] <= 25
        ORDER BY 
            [severity];
    END;

    IF UPPER(@AlertTypes) IN ( N'IO', N'SEVERITY_AND_IO') BEGIN 

        IF DATALENGTH(@command) > 2 SET @command = @command + @crlf + @crlf;

        INSERT INTO @ioAlerts (
            [message_id],
            [name]
        )
        VALUES       
            (605, N'605 - Page Allocation Unit Error'),
            (823, N'823 - Read/Write Failure'),
            (824, N'824 - Page Error'),
            (825, N'825 - Read-Retry Required');

        DECLARE @ioTemplate nvarchar(MAX) = REPLACE(@alertTemplate, N'{severity}', N'0');

        SELECT
            @command = @command + @crlf + @crlf + REPLACE(REPLACE(@ioTemplate, N'{id}', message_id), N'{name}', [name])
        FROM 
            @ioAlerts;

    END;

    IF @PrintOnly = 1 
        EXEC dbo.[print_long_string] @command;
    ELSE 
        EXEC sp_executesql @command;

    RETURN 0;
GO