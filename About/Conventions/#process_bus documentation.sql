/*

    
    OVERVIEW:
        - a process bus can be used for both command/task processing (i.e., keeping tabs of which specific operations have been completed, which haven't yet been completed, 
            and even 'dropping in' new commands or operations if/as needed). 

        - process buses also exist to keep a detailed record of all changes and attempted changes/operations during a specific round of processing. 

    IMPLEMENTATION
        - process busses are implemented as the union of 2x tools/techniques: 
            a) a temp-table - which keeps tabs on whatever blocks/types of logic or other operations are needed during a given 'operation' (i.e., inside a sproc/etc.) 

                and 
            
            b) xml - used for historical tracking AND to serialize/persist some specifics about the exact commands/tasks that should be processed. 

                NOTE that 'identity' columns in XML won't work ... in which case a SEQUENCE dedicated to 'row-ids' inside of xml elements will make more sense: 

                                    --DROP SEQUENCE IF EXISTS dbo.bus_sequence;

                                    CREATE SEQUENCE dbo.bus_sequence 
                                        AS int 
                                        START WITH 10000
                                        INCREMENT BY 1
                                        NO CYCLE 
                                        CACHE 200;

                                    SELECT NEXT VALUE FOR dbo.[bus_sequence];

                        NOTES: 
                            - at 10,000 operations per day (all day - all year), we'll run out of ids in 330 years (given that this is an int). 
                                as such, NO CYCLE has been specified. IF we ever run out of IDs, all admindb code using this sequence will start breaking
                                    at which point, an admin can 'stop' all backups and other 'complex' processes and ... RESTART the sequence... 

                            - SEQUENCE numbers are, of course, a bit ugly ... but we can just use them for ORDER BY operations AND with the ROW_NUMBER() windowing function
                                we can turn these into 'nice' row_ids or operation_ids as needed... 



            A. TEMP TABLE IMPLEMENTATION NOTES

                For example, the following is a BASIC/DEFAULT #bus: 

                    CREATE TABLE #bus (
                        row_id int IDENTITY(1, 1) NOT NULL, 
                        command xml NOT NULL 
                    );

                While the above example is viable, it will frequently make more sense to expand a #bus table with columns that help expand which operations and types of 
                    operations - and overall states - given operations are in. 

                    For example, with something like dbo.pause_synchronization, the following would make more sense: 

                        CREATE TABLE #bus (
                            row_id int IDENTITY(1, 1) NOT NULL, 
                            operation xml NOT NULL, 
                            db_name sysname NOT NULL,   -- name of the database this is for (i.e., think of this as the PARENT in this set of tasks). 
                            command_type sysname NOT NULL,  -- CHECKPOINT | WAIT | SUSPEND 
                            checkpoint_counter int NULL, 
                            is_complete bit NOT NULL DEFAULT (0) -- used to 'mark-off' any operations that complete - either successfully or that error out and shouldn't be processed anymore. 
                        );




            B. XML format. 
                
                OVERVIEW / PURPOSE:
                        Each 'row' dropped into the #bus will be a single 'operation' fragment/element. 
                   
                           operations, in turn, can be of different types (i.e., different kinds of 'tasks') and can be against different and/or the same targets). 

                                For example, in dbo.pause_synchronization, if input directives (of the sproc) are to pause 2x database (billing and widgets) and the @RunCheckpoint value
                                    was set to true, there are going to be at least 4x operations - 2x CHECKPOINT 'operations' 
                                        (which is actually going to be up to 3x distinct CHECKPOINT; statement executions)
                                
                                        such that the initial population of the #bus would be defined/configured roughly along the lines of the following pseudo-columns: 

                                                row_id  command         db_name     command_type        checkpoint_counter           is_complete
                                                1       <operation />   widgets     CHECKPOINT          1                            0
                                                2       <operation />   widgets     CHECKPOINT          2                            0
                                                3       <operation />   widgets     CHECKPOINT          3                            0
                                                4       <operation />   widgets     SUSPEND             -                            0
                                                5       <operation />   billing     CHECKPOINT          1                            0
                                                6       <operation />   billing     CHECKPOINT          2                            0
                                                7       <operation />   billing     CHECKPOINT          3                            0
                                                8       <operation />   billing     SUSPEND             -                            0


                                        where the <operation /> element would actually be populated with a <command /> element
                                            which contains the EXACT T-SQL to execute AND other, associated, meta-data... 

                                        
                                        However, while the 'operation' column will keep detailed info about the exact 'steps to take' AND 'steps taken'
                                            the #bus table can be given additional columns and details to make processing 'easier' - or to 'cheat' (from having to do detailed xml lookups to see what particular
                                                states have been achieved/etc.) 

                                        So, for example, processing or working through the 3x CHECKPOINT operations per each of the databases can be orchestrated such that: 
                                                            a) once ALL dbs to process have been 3x checkpointed 
                                                                OR 
                                                            b) once a single database has been 3x checkpointed

                                                    the SUSPEND operation would then be executed. (with the idea being that a process bus allows a better degree of flexibility
                                                        relative to command execution - i.e., things do NOT have to be serialized and/or executed in a (necessarily) rigid order. 
                                                                YEAH, it's not going to be TRIVIAL to change execution order and other details around, BUT, it'll be a bit easier
                                                                    to tackle and manage WHILE keeping a detailed history of everything going on and, hopefully, avoiding side-effects
                                                                        from 'frigic' or 'monolithic' code that was 'hard-coded' with a pre-concieved set of ideas on HOW orders of operations would proeceed. 


                SCHEMA: 
                        The <operation> element is merely a wrapper for all other, child, elements - with 1 <command> element per operation (no more, no less).
                    
                        The <command> element has a number of attributes defined/allowed - relative to ... command execution. 
                            Likewise, each command element will have a <statement> child-element - for the body of the command to be executed/run. 
                                and can also have up to 2x OPTIONAL child elements if/as needed: <outcomes> and <guidance>. 

                                NOTE: <outcomes> DOES need to be a parent/wrapper and 'set' element - as a single command can be tried multiple times - and have multiple outcomes. 
                                    for example, we try to get header info against a backup file - which fails the first time executed with a 'file in use' error, but, if/when we
                                        'wait' for a duration of 5 seconds (as per the resty_count/retry_interval) the file stays blocked on the 2nd execution as well
                                            BUT, is fine/useable on the 3rd execution - in which case we want to see: 2x 'errors' and a 'commmand succeeded' set of operations for outcomes. 


                                        <command
                                                created = "timestamp of when this command was DEFINED"

                                                execution_type = "EXEC|SQLCMD|SHELL|PARTNER|NO_EXECUTE"
                                                
                                                         command_order="sequence value here" -- every command will get a NEXT VALUE FOR dbo.process_bus_sequence... 
                                                         --  really not sure it's needed. if there's ONE command per each op... and each op has a row_id ... then.... who cares, right?

                                                retry_count="number of retries to allow" - can be null/empty... (defaults to 0)

                                                retry_interval="4 seconds" or whatever... - can also, obviously, be empty... 

                                                ignored_results = "exact string passed in to dbo.execute_command's @IgnoredResults"

                                                completed = "timestamp for when the operation was actually completed?"
                                        >
                                    
                                            <statement>exact statement to be executed goes here - and there's just a single statement per command</statement>

                                            <outcomes>
                                                <outcome
                                                    execution_start = "timestamp"
                                                    execution_end = "timestamp" ... hmmm. do i really want both? potentially... probably... 
                                                    outcome_type = "INFO | EXCEPTION"  --  i think... or, possibly, INFO | ERROR | EXCEPTION... 
                                                >
                                                    actual text body of the outcome itself goes here (i.e., 0 rows affected, Command completed, oink, whatever)
                                                </outcome>
                                            <outcomes>

                                            <guidance>
                                                <detail 
                                                    for = "hmmmm not sure of this one yet" -- I've got 2 options. I could say something like for = "outcome.2" ... in which case, i need to likely throw ordinals into play... and then keep outcome.345298 ... OR, i could do for="GUID HERE FOR THE thing to append to" - in which case, commands and outcomes COULD have guidance applied - but both would need a guid... 
                                                    type = "warning | info"  ... where info = some kind of context data and/or info on how to troubleshoot or try to address some sort of issue/problem/etc. 
                                                    (other attributes as needed - i.e., maybe some sort of link? or info about what docs to consult? - dunno)
                                                >
                                                    <heading>heading information would go here - though it's not required</heading>
                                                    <body>yup... the message/info/warning/whatever... </body>
                                                </detail>
                                            <guidance>
                            
                                        </command>

                                Key Notes about schema/elements: 

                                    <outcomes>
                                        dbo.execute_command will output/spit-back an @outcomes xml parameter.. which will be the exact info to drop into a command's <outcomes> node. 
                                            or, in other words, dbo.execute_command will know/understand the schema for <outcomes> intimately and be heavily bound to working with it. 

                                    <commands> 
                                        should, really, be considered as being the set of parameters and details to 'hand into' dbo.execute_command - for execution. 

                                    <guidance> 
                                        should be details that are provided by the CALLING/executing code-blocks - i.e., if dbo.pause_synchronization is being run and we can't
                                            get a successful 'suspend/pause' outcome, 'guidance' should show some info on why and/or what the admin running the sproc can do next. 




        NOTES:
            
            - 'Gaming dbo.execute_command'. 
                Because of how dbo.execute_command now operates (i.e., it KEEPS the 'outcome' or text/output from every execution - instead of deleting 'ignored results', 
                    it's POSSIBLE to set up simple ways to semi-confirm execution of the commands sent into dbo.execute_command. 
                        For example, assume, that for WHATEVER reason, I want to create the 'code' equivalent of a spin-loop or something similar. 
                            
                                e.g., assume the following code is what I'll 'wrap up' and send in as the @Command for dbo.execute_command:

                                          DECLARE @loopsCount int = 0; -- killing runaway loops in a SQLCMD spid is a pain... 
                                          WHILE @loopsCount < 10 BEGIN 
                                                
                                                IF (someState = nowMetAndApplicable) BEGIN
                                                    -- do whatever it was that made sense. 
                                                    PRINT 'Wait Operation Succeeded - and such and such occured';
                                                    BREAK;
                                                END;

                                                SET @loopsCount = @loopsCount + 1;
                                                
                                                PRINT 'Still waiting... ';  NOTE: HAVE to spit something out here... that's not in @Ignored... 

                                                WAITFOR 'some sort of delay here';
                                          END; 

                                If the above logic/command is wrapped up in an nvarchar(max) for @command and sent into dbo.execute_command as follows: 

                                            EXEC admindb.dbo.execute_command
                                                @Command = @command, 
                                                @ExecutionType = 'SQLCMD', 
                                                @ExecutionRetryCount = 2, 
                                                @DelayBetweenAttempts = N'10 seconds', 
                                                @IgnoredResults = N'[COMMAND_SUCCESS], Wait Operation Succeeded%',
                                                @Results = @output OUTPUT; 

                                then... 
                                    let's say it takes 16 full-blown iterations of the 'wait' before such and such is ready - meaning: 
                                        the first attempt to execute the code in @Command will ... 
                                            - loop 10x times - each time spitting out 'Still waiting...'
                                            - dbo.execute_command will wait 10s then start again... 
                                            - the 11th and 12th (total) iterations will 'fail'... 
                                            - the 13th will find the state as needed, and then run whatever command it was supposed to. 
                                                IF there are no exceptions, the code will print 'wait operation succeeded'... 
                                                    which is treated as a success message and ... dbo.execute_command will bundle up results and hand them out... 





                    NOTES: from previous incarnations/ideas: 

                        here's the old table I had - where the 'channel' has some good info/ideas in it: 

 
                                            CREATE TABLE #bus ( 
                                                [row_id] int IDENTITY(1,1) NOT NULL, 
                                                [channel] sysname NOT NULL DEFAULT (N'WARNING'),  -- ERROR | WARNING | INFO | CONTROL | GUIDANCE | OUTCOME (for control?)
                                                [timestamp] datetime NOT NULL DEFAULT (GETDATE()),
                                                [parent] int NULL,
                                                [grouping_key] sysname NULL, 
                                                [heading] nvarchar(1000) NULL, 
                                                [body] nvarchar(MAX) NULL, 
                                                [detail] nvarchar(MAX) NULL, 
                                                [command] nvarchar(MAX) NULL
                                            );

                        specifically, the CONTROL and OUTCOME 'channels'...
                            I BELIEVE those can/will just be dumped into the #bus table itself though - as additional columns. 

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