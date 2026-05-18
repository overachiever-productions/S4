/*

    @metadata uses the following schema: 
        DECLARE @metadata xml = N'<metadata>
	        <entry row_id="1">
		        <key>key1</key>
		        <value>value1</value>
	        </entry>
	        <entry row_id="2">
		        <key>key2</key>
		        <value>value2</value>
	        </entry>
	        <entry row_id="3">
		        <key>key3</key>
		        <value>value3</value>
	        </entry>
        </metadata>';

    @details uses the following schema:
        DECLARE @details xml = N'<details>
	        <detail row_id="1">
		        <id>1234</id>
		        <created>2026-05-02 09:12:02.127</created>
		        <error_message>Needles eating haystacks.</error_message>
	        </detail>
	        <detail row_id="2">
		        <id>5678</id>
		        <created>2026-05-12 21:18:22.333</created>
		        <error_message>Fuzzy piglets in blankets.</error_message>
	        </detail>
        </details>';  


    @kpis uses the following schema:
        DECLARE @kpis xml = N'<indicators>
            <indicator priority="1">
                <name>Indicator 1</name>
                <value>42</value>
                <style>error|warning|ok|info</style>
                <context>Context for indicator 1</context>
            </indicator>
        </indicators>';
        
    @extended uses the EXACT SAME schema as @details EXCEPT with a root node of <extended> instead of <details>.


*/

USE [admindb];
GO

IF OBJECT_ID('dbo.[format_email_minimal_report]','P') IS NOT NULL
	DROP PROC dbo.[format_email_minimal_report];
GO

CREATE PROC dbo.[format_email_minimal_report]
    @status                     sysname,                    -- TODO: validate IN ('INFO', 'WARN', 'ERROR') or something like that.
    @title                      sysname,    
    @execution_date             datetime,
    @summary                    sysname, 
    @recipients                 nvarchar(MAX)       = NULL,
    @detail_header              sysname,   
    @metadata                   xml,
    @details                    xml, 
    @extended_header            sysname             = NULL,     
    @extended                   xml                 = N'<extended />',
    @raw_header                 sysname             = NULL, 
    @raw                        nvarchar(MAX)       = NULL,
    @output                     nvarchar(MAX)       OUTPUT
AS
    SET NOCOUNT ON; 

	-- {copyright}

    SET @extended_header = NULLIF(@extended_header, N'');
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
                <td style="font-size:12px;font-weight:600;letter-spacing:0.08em;text-transform:uppercase;color:#666666;">
                  {status}
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
        </tr>

        <!-- Summary -->
        <tr>
          <td style="padding:16px 24px;font-size:14px;color:#333333;line-height:1.55;">
            {summary}
          </td>
        </tr>

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

        <!-- Details -->
        <tr>
          <td style="padding:16px 24px 8px 24px;font-size:12px;font-weight:600;letter-spacing:0.05em;text-transform:uppercase;color:#666666;">
            {detail-header}
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
        {extended}
        {raw}
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

    SET @body = REPLACE(@body, N'{status}', ISNULL(UPPER(@status), N''));
    SET @body = REPLACE(@body, N'{execution-time}', ISNULL(CONVERT(sysname, @execution_date, 120), N''));
    SET @body = REPLACE(@body, N'{title}', ISNULL(@title, N''));
    SET @body = REPLACE(@body, N'{summary}', ISNULL(@summary, N''));
    SET @body = REPLACE(@body, N'{detail-header}', ISNULL(@detail_header, N''));

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Metadata
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
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

    SET @body = REPLACE(@body, N'{meta_tds}', ISNULL(@metaRows, N''));

    /*---------------------------------------------------------------------------------------------------------------------------------------------------
    -- Details:
    1. extract column names + create <th> rows...  
    2. dynamically generate <tr><td>N</td></tr> rows ... for N columns. 
    ---------------------------------------------------------------------------------------------------------------------------------------------------*/
    DECLARE @firstRow xml = @details.query(N'/details/detail[1]');

    DECLARE @detailsColumns nvarchar(MAX) = N'';
    SELECT 
        @detailsColumns = @detailsColumns +
        N'<th align="left" style="padding:8px 10px;border-bottom:1px solid #e5e5e5;font-weight:600;color:#555555;">' +
            [t].[x].value(N'local-name(.)', N'sysname') + 
        N'</th>'
    FROM 
	    @firstRow.nodes(N'/detail/*') AS [t]([x]);

    SET @body = REPLACE(@body, N'{details_columns}', ISNULL(@detailsColumns, N''));

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

    SET @body = REPLACE(@body, N'{details_rows}', @detailRows);

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