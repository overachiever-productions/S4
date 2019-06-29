

    CREATE TABLE #bus ( 
        [row_id] int IDENTITY(1,1) NOT NULL, 
        [channel] sysname NOT NULL DEFAULT (N'warning'),  -- ERROR | WARNING | INFO | CONTROL | GUIDANCE | OUTCOME (for control?)
        [timestamp] datetime NOT NULL DEFAULT (GETDATE()),
        [parent] int NULL,
        [grouping_key] sysname NULL, 
        [heading] nvarchar(1000) NULL, 
        [body] nvarchar(MAX) NULL, 
        [detail] nvarchar(MAX) NULL, 
        [command] nvarchar(MAX) NULL
    );


/*
    ERROR: 
        something bad happened - i.e., exception/etc. 

    WARNING: 
        exceeded RPOs or possible problem/etc. 

    INFO: 
        output from dbo.execute_command if/when errors encountered BUT the process completes after N retries (as specified). 

    CONTROL: 
        internal directives/data or whatever - fairly customizable...   
            examples: 
                in dbo.verify_server_synchronization ... i could set up a 'command' to try and sync each login that was different ... by making the oldest one a copy of the new one. 
                    that's a 'control' operation/input/message. 
                    I'd also, of course, have an info/error/warning associated with this one the way out too - i.e., what was that OUTCOME of that bit of automation?

    GUIDANCE: 
        additional details that can/will be 'interjected' during processing or elsewhere... 


    OUTCOME:
        yeah, still not sure about this one. I COULD specify this as the 'response' or 'outcome'/link to a CONTROL operation. 
            BUT, it seems like a better approach would be... to drop in an INFO | WARNING | ERROR keyed to the parent_id... right?

*/



-- original idea was to use XML and a single 'message' + 'channel' column... 
--      i may use XML later... but ... it's good as is right now... 





/*


    I can also set up a 'ranking' for grouping_keys as follows: 

    DECLARE @groupingKeyRanks table ( 
        [rank] int NOT NULL< 
        [key]
    );

    INSERT INTO @groupingKeyRanks ([rank], [key]) 
    VALUES (-100, 'some key that i want first'), 
    VALUES (-80, 'ditto - but second-ish'),
    VALUES (100, 'thing i want almost last'), 
    VALUES (101, 'thing i want last');

    AND... i don't HAVE To specify all keys (i.e., any that aren't specified default to a 'rank' of 0 or something... ) 
        just the ones I want to force into certain ranks. 

    ALSO
        this could jsut be a CTE derived table... i.e., instead of a table variable... just use a CTE constructor... as an inline derived table.

*/



-------------------------------------------------------------------------------------------------------------------------
-- OUTPUT EXAMPLES: 
-------------------------------------------------------------------------------------------------------------------------

/*


		DECLARE @subject nvarchar(300) = N'SQL Server Synchronization Check Problems';
		DECLARE @crlf nchar(2) = CHAR(13) + CHAR(10);
		DECLARE @tab nchar(1) = CHAR(9);
		DECLARE @message nvarchar(MAX) = N'The following synchronization issues were detected: ' + @crlf + @crlf;

        SELECT 
            @message = @message + @tab +  UPPER([channel]) + N': ' + [heading] + CASE WHEN [body] IS NOT NULL THEN @crlf + @tab + @tab + [body] ELSE N'' END + @crlf + @crlf
        FROM 
            #bus
        ORDER BY 
            [row_id];


--------------------------------------------------------------
-- current format: 
--------------------------------------------------------------
SUBJECT: SQL Server Synchronization Check Problems
BODY: 
The following synchronization issues were detected: 

	WARNING: Setting [blocked process threshold (s)] is different between servers.
		Value on SQL30 = 2. Value on SQL31 = 0.

	WARNING: Trace Flag 1118 exists only on SQL31.

	WARNING: Trace Flag 3226 exists only on SQL31.

	WARNING: Definition for Login [sa] is different between servers.

	WARNING: Alert [1480 alert] exists on SQL31 only.


--------------------------------------------------------------
-- desired format: 
--------------------------------------------------------------
SUBJECT: SQL Server Synchronization Check Problems
BODY: 
The following synchronization issues were detected: 

    ERRORS: (if any)

    WARNINGS: (if any)

        [SERVER SETTINGS]  --MKC: I can accomplish these via QOUTENAME(UPPER(channel)) ... and just standardizing the channel names... + using 'ranking' for any that should go first... 
            - Setting [blocked process threshold (s)] is different between servers.
		        Value on SQL30 = 2. Value on SQL31 = 0.

	    [TRACE FLAGS]
            - Trace Flag 1118 exists only on SQL31.
            - Trace Flag 3226 exists only on SQL31.

                -- MKC: details on how to fix here... 
                --  MKC:  and note that we COLLAPSED 2x different entries down on to a single line... 

	    [LOGINS]
            - Definition for Login [sa] is different between servers.

	    [ALERTS]
            - Alert [1480 alert] exists on SQL31 only.


*/