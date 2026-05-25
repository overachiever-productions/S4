/*
     

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[format_email_minimal_report]','P') IS NOT NULL
	DROP PROC dbo.[format_email_minimal_report];
GO

CREATE PROC dbo.[format_email_minimal_report]
    @classification             sysname,                                        -- COMMON values are: { REPORT | INFO | WARNING | ERROR } - but anything works.
    @title                      sysname,    
    @execution_date             datetime,
    @recipients                 nvarchar(MAX),                                  -- REQUIRED
    @indicators                 xml                 = NULL,                     -- SPECIALIZED schema expected. 
    @summary                    sysname             = NULL, 
    @metadata                   xml                 = NULL,                     -- KVPs.
    @errors_header              sysname             = NULL,
    @errors                     xml                 = NULL,                     -- KVPs with 'arbitrary' key-name (as the element-name and element-text as the value)
    @details_header             sysname             = NULL,                     
    @details                    xml                 = NULL, 
    @extended_header            sysname             = NULL,     
    @extended                   xml                 = NULL,
    @raw_header                 sysname             = NULL, 
    @raw                        nvarchar(MAX)       = NULL,
    @output                     nvarchar(MAX)       OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

    SET @extended_header = NULLIF(@extended_header, N'');
    SET @details_header = NULLIF(@details_header, N'');
    SET @errors_header = NULLIF(@errors_header, N'');
    SET @raw_header = NULLIF(@raw_header, N'');
    SET @raw = NULLIF(@raw, N'');
	
	DECLARE @body nvarchar(MAX) = N'<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>{status}</title>
</head>
<body style="margin:0;padding:0;background-color:#f5f5f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#f5f5f5;">
  <tr>
    <td align="center" style="padding:24px 12px;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="640" style="max-width:640px;width:100%;background-color:#ffffff;border:1px solid #e5e5e5;">
        <!-- Header -->
        <tr>
          <td style="padding:20px 24px 8px 24px;border-bottom:1px solid #e5e5e5;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
              <tr>
                <td style="font-size:12px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#{classificationColor};">
                  {classification}
                </td>
                <td align="right" style="font-size:12px;color:#888888;">
                  {execution-time}
                </td>
              </tr>
              <tr>
                <td colspan="2" style="padding-top:6px;font-size:18px;font-weight:600;color:#111111;line-height:1.35;">
                  {title}
                </td>
              </tr>
            </table>
          </td>
        </tr>{metadata}{summary}{indicators}{errors}{details}{extended}{raw}
        <!-- Footer -->
        <tr>
          <td style="padding:14px 24px;border-top:1px solid #e5e5e5;font-size:11px;color:#888888;">
            Automated Report &middot; Sent to {recipients}.
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>';
    
    SET @body = REPLACE(@body, N'{classification}', ISNULL(UPPER(@classification), N''));
    
    DECLARE @classificationColor sysname = CASE UPPER(@classification)
        WHEN N'ERROR' THEN N'c0392b'
        WHEN N'WARNING' THEN N'92400e'
        WHEN N'INFO' THEN N'1e40af'
        ELSE N'666666'
    END;
    
    SET @body = REPLACE(@body, N'{classificationColor}', @classificationColor);
    SET @body = REPLACE(@body, N'{execution-time}', ISNULL(CONVERT(sysname, @execution_date, 120), N''));
    SET @body = REPLACE(@body, N'{title}', ISNULL(@title, N''));

    DECLARE @firstRow xml;

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Indicators / KPIs: 
    -- NOTE: Indicators do NOT have/allow a specific HEADER.
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @indicatorsBlock nvarchar(MAX) = N'';
    IF (SELECT dbo.[is_xml_empty](@indicators)) = 0 BEGIN
        SET @indicatorsBlock = N'
        <!-- kpi tiles -->
        <tr>
          <td style="padding:0 16px 4px 16px;background-color:#ffffff;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">
              <tr>
                   {kpis}
              </tr>
            </table>
          </td>
        </tr>
        ';
        
        DECLARE @indicatorsCount int = (SELECT @indicators.value(N'count(/indicators/indicator)', N'int'));
        DECLARE @indicatorsWidth sysname = CASE 
            WHEN @indicatorsCount = 1 THEN N'100%'
            WHEN @indicatorsCount = 2 THEN N'50%'
            WHEN @indicatorsCount = 3 THEN N'33%'
            WHEN @indicatorsCount = 4 THEN N'25%'
            WHEN @indicatorsCount = 5 THEN N'20%'
            ELSE N'100%'
        END;

        DECLARE @kpis nvarchar(MAX) = N'';
        WITH [points] AS ( 
            SELECT 
	            [t].[x].value(N'(@priority)[1]', N'int') [priority],
                [t].[x].value(N'(name)[1]', N'sysname') [name],
                [t].[x].value(N'(value)[1]', N'sysname') [value],
                [t].[x].value(N'(style)[1]', N'sysname') [style],
                ISNULL(NULLIF([t].[x].value(N'(context)[1]', N'sysname'), N''), N'&nbsp;') [context]
            FROM 
	            @indicators.nodes(N'/indicators/indicator') [t]([x])
        )

        SELECT 
            @kpis = @kpis + N'<td width="' + @indicatorsWidth + ' " style="padding:8px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="background-color:#f8fafc;border:1px solid #e5e7eb;border-radius:4px;">
                    <tr><td style="padding:12px 14px;">
                      <div style="font-size:11px;color:#6b7280;text-transform:uppercase;letter-spacing:0.05em;">' + [name] + N'</div>
                      <div style="padding-top:4px;font-size:20px;font-weight:600;color:#' + CASE [style]
                        WHEN N'error' THEN N'c0392b'
                        WHEN N'warning' THEN N'92400e'
                        WHEN N'ok' THEN N'166534'
                        WHEN N'info' THEN N'1e40af'
                      END + N';">' + [value] + N'</div>
                      <div style="font-size:11px;color:#9ca3af;padding-top:2px;">' + [context] + N'</div>
                    </td></tr>
                  </table>
                </td>'
        FROM 
            [points]
        ORDER BY 
            [priority]

        SET @indicatorsBlock = REPLACE(@indicatorsBlock, N'{kpis}', @kpis);

    END;
        
    SET @body = REPLACE(@body, N'{indicators}', @indicatorsBlock);

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Summary:
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @summaryBlock nvarchar(MAX) = N'';
    IF @summary IS NOT NULL BEGIN 
        SET @summaryBlock = N'
        <!-- Summary -->
        <tr>
          <td style="padding:16px 24px;font-size:14px;color:#333333;line-height:1.55;">
            {summary}
          </td>
        </tr>
        ';

        SET @summaryBlock = REPLACE(@summaryBlock, N'{summary}', ISNULL(@summary, N''));
    END;

    SET @body = REPLACE(@body, N'{summary}', @summaryBlock);

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Metadata
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @metadataBlock nvarchar(MAX) = N'';

    IF ((SELECT dbo.[is_xml_empty](@metadata)) = 0) BEGIN
        SET @metadataBlock = N'
        <!-- Metadata -->
        <tr>
          <td style="padding:0 24px 8px 24px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="font-size:13px;color:#333333;border-collapse:collapse;">
              <tr>
                {meta_tds}
              </tr>
            </table>
          </td>
        </tr>       
        ';

        DECLARE @metaRows nvarchar(MAX) = N'';
        WITH [meta] AS ( 

	        SELECT 
		        [t].[x].value(N'(@row_id)[1]', N'int') [row_id], 
		        [t].[x].value(N'(key)[1]', N'nvarchar(100)') [key],
		        [t].[x].value(N'(value)[1]', N'nvarchar(100)') [value]
	        FROM 
		        @metadata.nodes('/metadata/entry') [t]([x])
        )

        SELECT 
	        @metaRows = @metaRows + 
            N'<tr>' +
	            N'<td style="padding:8px 0;border-top:1px solid #eeeeee;width:35%;color:#666666;">' + [key] + N'</td>' + 
	            N'<td style="padding:8px 0;border-top:1px solid #eeeeee;font-family:Consolas,Menlo,monospace;">' + [value] + N'</td>' + 
            N'</tr>'
        FROM 
	        [meta]
        ORDER BY 
	        [row_id];

        SET @metadataBlock = REPLACE(@metadataBlock, N'{meta_tds}', @metaRows);
    END;

    SET @body = REPLACE(@body, N'{metadata}', @metadataBlock);

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Errors:
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @errorsBlock nvarchar(MAX) = N'';
    IF ((SELECT dbo.[is_xml_empty](@errors)) = 0) OR @errors_header IS NOT NULL BEGIN

        SET @errors_header = ISNULL(@errors_header, N'Errors');
        
        DECLARE @errorKeyName sysname;
        DECLARE @errorsRows nvarchar(MAX) = N'';

        SET @errorsBlock = N'
        <!-- Errors -->
        <tr>
          <td style="padding:16px 24px 4px 24px;font-size:12px;font-weight:600;letter-spacing:0.05em;text-transform:uppercase;color:#666666;">
            {error_heading}
          </td>
        </tr>
        <tr>
          <td style="padding:0 24px 20px 24px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">
            {errors}
            </table>
          </td>
        </tr>
        ';

        WITH errors AS ( 
            SELECT 
                [t].[x].value(N'(@row_id)[1]', N'int') [row_id],
                [t].[x].value(N'(heading)[1]', N'sysname') [heading], 
                [t].[x].value(N'(error)[1]', N'nvarchar(MAX)') [error]
            FROM 
                @errors.nodes(N'/errors/error') AS [t]([x])
        )

        SELECT 
            @errorsRows = @errorsRows +
            N'<tr>
                <td style="padding:12px 0 2px 0;border-top:1px solid #eeeeee;">
                  <span style="font-size:11px;font-weight:600;letter-spacing:0.08em;color:#888888;">' + [heading] + N'</span>
                </td>
              </tr>
              <tr>
                <td style="padding:2px 0 14px 0;font-size:13px;color:#333333;line-height:1.6;">' + [error] + N'</td>
              </tr>'
        FROM 
            [errors] 
        ORDER BY 
            [row_id];

        SET @errorsBlock = REPLACE(@errorsBlock, N'{error_heading}', @errors_header);
        SET @errorsBlock = REPLACE(@errorsBlock, N'{errors}', @errorsRows);

    END; 

    SET @body = REPLACE(@body, N'{errors}', @errorsBlock);

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Details:
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @detailsBlock nvarchar(MAX) = N'';
    IF ((SELECT dbo.[is_xml_empty](@details)) = 0) OR (@details_header IS NOT NULL) BEGIN
        
        SET @details_header = ISNULL(NULLIF(@details_header, N''), N'DETAILS');

        SET @detailsBlock = N'
        <!-- Details -->
        <tr>
          <td style="padding:16px 24px 8px 24px;font-size:12px;font-weight:600;letter-spacing:0.05em;text-transform:uppercase;color:#666666;">
            {details-header}
          </td>
        </tr>
        <tr>
          <td style="padding:0 24px 20px 24px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;font-size:13px;color:#222222;">
              <thead>
                <tr style="background-color:#fafafa;">
                  {details_columns}
                </tr>
              </thead>
              <tbody>
                {details_rows}
              </tbody>
            </table>
          </td>
        </tr>        
        ';

        SET @detailsBlock = REPLACE(@detailsBlock, N'{details-header}', ISNULL(@details_header, N''));

        SELECT @firstRow = @details.query(N'/details/detail[1]');
        DECLARE @detailsColumns nvarchar(MAX) = N'';
        SELECT 
            @detailsColumns = @detailsColumns +
            N'<th align="left" style="padding:8px 10px;border-bottom:1px solid #e5e5e5;font-weight:600;color:#555555;">' +
                [t].[x].value(N'local-name(.)', N'sysname') + 
            N'</th>'
        FROM 
	        @firstRow.nodes(N'/detail/*') AS [t]([x]);

        SET @detailsBlock = REPLACE(@detailsBlock, N'{details_columns}', ISNULL(@detailsColumns, N''));

        DECLARE @detailRows nvarchar(MAX) = N'';
        WITH [rows] AS ( 
            SELECT 
	            [t].[x].value(N'(@row_id)[1]', N'int') [row_id],
	            t.x.query(N'.') [row]
            FROM 
	            @details.nodes(N'/details/detail') [t]([x])
        )

        SELECT 
            @detailRows = @detailRows +
            N'<tr>' + 
                (CAST(
                    (SELECT 
                        N'padding:8px 10px;border-bottom:1px solid #f0f0f0;' [td/@style],
                        ISNULL([n].[x].value(N'(.)[1]', N'sysname'), N'') [td], 
                        ''
                    FROM 
                        [rows].row.nodes(N'/detail/*') AS [n]([x])
                    FOR XML PATH(N''), TYPE) AS nvarchar(MAX))
                ) +
            N'</tr>'
        FROM 
            [rows] 
        ORDER BY 
            [row_id];

        SET @detailsBlock = REPLACE(@detailsBlock, N'{details_rows}', @detailRows);
    END;

    SET @body = REPLACE(@body, N'{details}', @detailsBlock);

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Extended Details:
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @extendedBlock nvarchar(MAX) = N'
        <!-- Extended Details -->
        <tr>
          <td style="padding:16px 24px 8px 24px;font-size:12px;font-weight:600;letter-spacing:0.05em;text-transform:uppercase;color:#666666;">
            {extended-header}
          </td>
        </tr>
        <tr>
          <td style="padding:0 24px 20px 24px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;font-size:13px;color:#222222;">
              <thead>
                <tr style="background-color:#fafafa;">
                  {extended_columns}
                </tr>
              </thead>
              <tbody>
                {extended_rows}
              </tbody>
            </table>
          </td>
        </tr>
        ';

    IF ((SELECT dbo.[is_xml_empty](@extended)) = 0) OR (@extended_header IS NOT NULL) BEGIN
        SET @extended_header = ISNULL(NULLIF(@extended_header, N''), 'Extended Details');

        SET @extendedBlock = REPLACE(@extendedBlock, N'{extended-header}', @extended_header);
        SELECT @firstRow = @extended.query(N'/extended/detail[1]');

        DECLARE @extendedColumns nvarchar(MAX) = N'';
        SELECT 
            @extendedColumns = @extendedColumns +
            N'<th align="left" style="padding:8px 10px;border-bottom:1px solid #e5e5e5;font-weight:600;color:#555555;">' +
                [t].[x].value(N'local-name(.)', N'sysname') + 
            N'</th>'
        FROM 
	        @firstRow.nodes(N'/detail/*') AS [t]([x]);

        SET @extendedBlock = REPLACE(@extendedBlock, N'{extended_columns}', ISNULL(@extendedColumns, N''));
        
        DECLARE @extendedRows nvarchar(MAX) = N'';
        WITH [rows] AS ( 
            SELECT 
	            [t].[x].value(N'(@row_id)[1]', N'int') [row_id],
	            t.x.query(N'.') [row]
            FROM 
	            @extended.nodes(N'/extended/detail') [t]([x])
        )

        SELECT 
            @extendedRows = @extendedRows +
            N'<tr>' + 
                (CAST(
                    (SELECT 
                        'padding:8px 10px;border-bottom:1px solid #f0f0f0;' [td/@style],
                        ISNULL([n].[x].value(N'(.)[1]', N'sysname'), N'') [td], 
                        ''
                    FROM 
                        [rows].row.nodes(N'/detail/*') AS [n]([x])
                    FOR XML PATH(N''), TYPE) AS nvarchar(MAX))
                ) +
            N'</tr>'
        FROM 
            [rows] 
        ORDER BY 
            [row_id];

        SET @extendedBlock = REPLACE(@extendedBlock, N'{extended_rows}', @extendedRows);

        SET @body = REPLACE(@body, N'{extended}', @extendedBlock);

      END;
    ELSE 
        SET @body = REPLACE(@body, N'{extended}', N'');

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Raw Details:
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @rawBlock nvarchar(MAX) = N'
        <!-- Raw output / log block -->
        <tr>
          <td style="padding:8px 24px 4px 24px;font-size:12px;font-weight:600;letter-spacing:0.05em;text-transform:uppercase;color:#666666;">
            {raw_header}
          </td>
        </tr>
        <tr>
          <td style="padding:0 24px 20px 24px;">
            <pre style="margin:0;padding:12px 14px;background-color:#fafafa;border:1px solid #eeeeee;font-family:Consolas,Menlo,''Courier New'',monospace;font-size:12px;line-height:1.5;color:#333333;white-space:pre-wrap;word-wrap:break-word;overflow-x:auto;">{raw}</pre>
          </td>
        </tr>
        ';

    IF (@raw_header IS NOT NULL) OR (@raw is NOT NULL) BEGIN
        SET @raw_header = ISNULL(@raw_header, N'Raw Output');

        SET @rawBlock = REPLACE(@rawBlock, N'{raw_header}', @raw_header);
        SET @rawBlock = REPLACE(@rawBlock, N'{raw}', ISNULL(@raw, N''));

        SET @body = REPLACE(@body, N'{raw}', @rawBlock);
      END
    ELSE 
        SET @body = REPLACE(@body, N'{raw}', N'');

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Footer / etc. 
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    SET @body = REPLACE(@body, N'{recipients}', ISNULL(@recipients, N''));

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Final Output:
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    SET @output = @body;

    RETURN 0;
GO