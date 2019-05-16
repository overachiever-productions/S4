/*
    INTERNAL
        Used to simplify deployment (i.e., remove all of the IF/EXISTS drop... checks).

    LOGIC:
        @Directives is a <list> of <entry> elements. 
            Each <entry> element has some key attributes: object and type (both required) + schema 
            and comments (optional - if schema is NOT declared, defaults to dbo). 
            
            Further, each <entry> has 2 ways of defining optional warnings/notifications to admins/users when dropping objects. 
                a. the <check> element - with a <statement> element to be dropped into an IF EXISTS () check... 
                    and a <warning> element - that represents the contents of what will be printed IF the statement evaluation is true.
                    e.g., IF EXISTS(<statement goes here) 
                        PRINT '<warning goes here'>; 

                b. the ability to simply run a warning/notification WITHOUT an IF check and which will be DIRECTLY selected/output into 
                    the overall result sets. 
                        e.g., SELECT '<content>' AS [<heading>];

    vNEXT: 
        - standardize/simplify. Instead of <check> and <notification> 'variants'... just have the following: 
                    <notification>
                        <check>SELECT statment that can/will go inside of an IF EXISTS check - if present</check>
                        <warning>this is the statement that will be SELECTed... as a warning can be IF there's a CHECK and CHECK = TRUE, or can be WITHOUT a check and just 'raised' as a warning.</warning>
                        <heading>just like currently. only this can be optional as well.. i.e., if it's NOT specified, then we get a [warning] column/header.</header>
                    </notification>
        - cram notifications into a #notifications temp table... 
            and select from it at the end of the process... i.e., it'll have 2 columns: 
                [summary], [detail]. 
                    summary will be the 'heading' and detail will be the context/warning itself... 



    TESTS / EXAMPLES: 

            Expect error (invalid type specified): 
                        DECLARE @olderObjectNames xml = CONVERT(xml, N'<list>
                            <entry schema="dbo" name="dba_DatabaseRestore_Log" type="UX" />
                            <entry schema="dbo" name="dba_SplitString" type="XF" />
                        </list>');

                         EXEC dbo.drop_obsolete_objects @olderObjectNames, 1;
                         GO

            Expect 3x drop statements (in the master database);
                        DECLARE @olderObjectNames xml = CONVERT(xml, N'<list>
                            <entry schema="dbo" name="dba_DatabaseBackups_Log" type="U" />
                            <entry schema="dbo" name="dba_DatabaseRestore_Log" type="U" />
                            <entry schema="dbo" name="dba_SplitString" type="TF" />
                        </list>');

                         EXEC dbo.drop_obsolete_objects @olderObjectNames, N'master', 1;
                         GO


            Expect 2x drop statements (in master) with SELECT'd warnings about changes:
                        DECLARE @olderObjectNames xml = CONVERT(xml, N'<list>
                            <entry schema="dbo" name="dba_FilterAndSendAlerts" type="P">
                                <notification>
                                    <content>NOTE: dbo.dba_FilterAndSendAlerts was dropped from master database - make sure to change job steps/names as needed.</content>
                                    <heading>WARNING - Potential Configuration Changes Required (alert filtering)</heading>
                                </notification>
                            </entry>
                            <entry schema="dbo" name="dba_drivespace_checks" type="P"><notification><content>NOTE: dbo.dba_drivespace_checks was dropped from master database - make sure to change job steps/names as needed.</content><heading>WARNING - Potential Configuration Changes Required (alert filtering)</heading></notification></entry>
                        </list>');

                        EXEC dbo.drop_obsolete_objects @olderObjectNames, N'master', 1;
                        GO


            Expect 2x drop proc statements WITH comments and with IF CHECKS:
                        DECLARE @olderObjectNames xml = CONVERT(xml, N'<list>
                            <entry schema="dbo" name="dbo.server_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
                                <check>
                                    <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%server_synchronization_checks%''</statement>
                                    <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.server_synchronization_checks were found. Please update to call dbo.verify_server_synchronization instead.</warning>
                                </check></entry>
                            <entry schema="dbo" name="job_synchronization_checks" type="P" comment="v4.9 - .5.0 renamed noun_noun_check sprocs for HA monitoring to verify_noun_noun">
                                <check>
                                    <statement>SELECT NULL FROM msdb.dbo.[sysjobsteps] WHERE [command] LIKE ''%job_synchronization_checks%''</statement>
                                    <warning>WARNING: v4.9 to v5.0+ name-change detected. Job Steps with calls to dbo.job_synchronization_checks were found. Please update to call dbo.verify_job_synchronization instead.</warning>
                                </check></entry>
                        </list>');

                        EXEC dbo.drop_obsolete_objects @olderObjectNames, NULL, 1;
                        GO

*/
USE [admindb];
GO

IF OBJECT_ID('dbo.drop_obsolete_objects','P') IS NOT NULL
	DROP PROC dbo.drop_obsolete_objects;
GO

CREATE PROC dbo.drop_obsolete_objects
    @Directives         xml             = NULL, 
    @TargetDatabae      sysname         = NULL,
    @PrintOnly          bit             = 0
AS 
    SET NOCOUNT ON; 

    -- {copyright}

    IF @Directives IS NULL BEGIN 
        PRINT '-- Attempt to execute dbo.drop_obsolete_objects - but @Directives was NULL.';
        RETURN -1;
    END; 

    DECLARE @typeMappings table ( 
        [type] sysname, 
        [type_description] sysname 
    ); 

    INSERT INTO @typeMappings (
        [type],
        [type_description]
    )
    VALUES
        ('U', 'TABLE'),
        ('V', 'VIEW'),
        ('P', 'PROCEDURE'),
        ('FN', 'FUNCTION'),
        ('IF', 'FUNCTION'),
        ('TF', 'FUNCTION'),
        ('D', 'CONSTRAINT'),
        ('SN', 'SYNONYM');

    DECLARE @command nvarchar(MAX) = N'';
    DECLARE @current nvarchar(MAX);
    DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
    DECLARE @tab nchar(1) = NCHAR(9);

    DECLARE walker CURSOR LOCAL FAST_FORWARD FOR
    SELECT 
        ISNULL([data].[entry].value('@schema[1]', 'sysname'), N'dbo') [schema],
        [data].[entry].value('@name[1]', 'sysname') [object_name],
        UPPER([data].[entry].value('@type[1]', 'sysname')) [type],
        [data].[entry].value('@comment[1]', 'sysname') [comment], 
        [data].[entry].value('(check/statement/.)[1]', 'nvarchar(MAX)') [statement], 
        [data].[entry].value('(check/warning/.)[1]', 'nvarchar(MAX)') [warning], 
        [data].[entry].value('(notification/content/.)[1]', 'nvarchar(MAX)') [content], 
        [data].[entry].value('(notification/heading/.)[1]', 'nvarchar(MAX)') [heading] 

    FROM 
        @Directives.nodes('//entry') [data] ([entry]);

    DECLARE @template nvarchar(MAX) = N'
{comment}IF OBJECT_ID(''{schema}.{object}'', ''{type}'') IS NOT NULL {BEGIN}
    DROP {object_type_description} [{schema}].[{object}]; {StatementCheck} {Notification}{END}';

    DECLARE @checkTemplate nvarchar(MAX) = @crlf + @crlf + @tab + N'IF EXISTS ({statement})
        PRINT ''{warning}''; ';
    DECLARE @notificationTemplate nvarchar(MAX) = @crlf + @crlf + @tab + N'SELECT ''{content}}'' AS [{heading}];';

    DECLARE @schema sysname, @object sysname, @type sysname, @comment sysname, 
        @statement nvarchar(MAX), @warning nvarchar(MAX), @content nvarchar(200), @heading nvarchar(200);

    DECLARE @typeType sysname;
    DECLARE @returnValue int;

    OPEN [walker];
    FETCH NEXT FROM [walker] INTO @schema, @object, @type, @comment, @statement, @warning, @content, @heading;

    WHILE @@FETCH_STATUS = 0 BEGIN
    
        SET @typeType = (SELECT [type_description] FROM @typeMappings WHERE [type] = @type);

        IF NULLIF(@typeType, N'') IS NULL BEGIN 
            RAISERROR(N'Undefined OBJECT_TYPE slated for DROP/REMOVAL in dbo.drop_obsolete_objects.', 16, 1);
            SET @returnValue = -1;

            GOTO Cleanup;
        END;
        
        IF NULLIF(@object, N'') IS NULL OR NULLIF(@type, N'') IS NULL BEGIN
            RAISERROR(N'Error in dbo.drop_obsolete_objects. Attributes name and type are BOTH required.', 16, 1);
            SET @returnValue = -5;
            
            GOTO Cleanup;
        END;

        SET @current = REPLACE(@template, N'{schema}', @schema);
        SET @current = REPLACE(@current, N'{object}', @object);
        SET @current = REPLACE(@current, N'{type}', @type);
        SET @current = REPLACE(@current, N'{object_type_description}', @typeType);

        IF NULLIF(@comment, N'') IS NOT NULL BEGIN 
            SET @current = REPLACE(@current, N'{comment}', N'-- ' + @comment + @crlf);
          END;
        ELSE BEGIN 
            SET @current = REPLACE(@current, N'{comment}', N'');
        END;

        DECLARE @beginEndRequired bit = 0;

        IF NULLIF(@statement, N'') IS NOT NULL BEGIN
            SET @beginEndRequired = 1;
            SET @current = REPLACE(@current, N'{StatementCheck}', REPLACE(REPLACE(@checkTemplate, N'{statement}', @statement), N'{warning}', @warning));
          END;
        ELSE BEGIN 
            SET @current = REPLACE(@current, N'{StatementCheck}', N'');
        END; 

        IF (NULLIF(@content, N'') IS NOT NULL) AND (NULLIF(@heading, N'') IS NOT NULL) BEGIN
            SET @beginEndRequired = 1;
            SET @current = REPLACE(@current, N'{Notification}', REPLACE(REPLACE(@notificationTemplate, N'{content}', @content), N'{heading}', @heading));
          END;
        ELSE BEGIN
            SET @current = REPLACE(@current, N'{Notification}', N'');
        END;

        IF @beginEndRequired = 1 BEGIN 
            SET @current = REPLACE(@current, N'{BEGIN}', N'BEGIN');
            SET @current = REPLACE(@current, N'{END}', @crlf + N'END;');
          END;
        ELSE BEGIN 
            SET @current = REPLACE(@current, N'{BEGIN}', N'');
            SET @current = REPLACE(@current, N'{END}', N'');
        END; 

        SET @command = @command + @current + @crlf;

        FETCH NEXT FROM [walker] INTO @schema, @object, @type, @comment, @statement, @warning, @content, @heading;
    END;

Cleanup:
    CLOSE [walker];
    DEALLOCATE [walker];

    IF @returnValue IS NOT NULL BEGIN 
        RETURN @returnValue;
    END;

    IF NULLIF(@TargetDatabae, N'') IS NOT NULL BEGIN 
        SET @command = N'USE ' + QUOTENAME(@TargetDatabae) + N';' + @crlf + N'' + @command;
    END;

    IF @PrintOnly = 1
        PRINT @command;
    ELSE 
        EXEC sys.[sp_executesql] @command; -- by design: let it throw errors... 

    RETURN 0;
GO