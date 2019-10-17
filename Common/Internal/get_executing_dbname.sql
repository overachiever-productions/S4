/*
    NOTE: 
        - This sproc adheres to the PROJECT/RETURN usage convention.

        - Does _NOT_ work from within master or tempdb. 
        - DOES work within model and msdb. 
        - DOES work against all other USER databases.
        - DOES work in read-only (user) databases.

        - [problem with 'stacked'/chained db contexts... callers.]
            e.g., create a sproc in the tools database called DoStuff, that calls/executes admindb.dbo.list_something
                and then run the following: 

                        USE widgets;
                        GO

                        EXEC tools.DoStuff   --  --> calls into admindb... 
                        GO

                And we're 3x levels deep - at which point, this sproc will throw an exception.

                AND... here's a script that'll 'repro' the problems/concerns listed above: 


                        USE [Meddling];
                        GO

                        SET NOCOUNT ON; 

                        DECLARE @dbs table (
                            [database_name] sysname NOT NULL
                        );

                        INSERT INTO @dbs ([database_name])
                        EXEC admindb.dbo.[list_databases]
                            @Targets = N's4_old, s4_new, oink';


                        DECLARE @template nvarchar(MAX) = N'USE [{0}];

                        EXEC admindb.dbo.get_executing_dbname;

                        ';


                        DECLARE @sql nvarchar(MAX) = N'';

                        SELECT @sql = @sql + REPLACE(@template, N'{0}', [database_name])
                        FROM 
                            @dbs; 

                        PRINT @sql;

                        EXEC sp_executesql @sql;



    vNEXT: 
        see if I can't, somehow, figure out either a) IF I can even '3x'-chain dbs (like I think i might be able to)
        or b) 
            if i can... derive the 'current' db by means of sys.dm_os_workers/sys.dm_os_tasks or some other such DMV. 
                DETAILS on original tests/attempts for this are below: 

                                        ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
                                        -- Initial Spelunking: 



                                                --SELECT * FROM sys.[dm_exec_connections] WHERE [session_id] = @@SPID; 

                                                --SELECT * FROM sys.[dm_exec_sessions] WHERE [session_id] = @@SPID; 

                                                --SELECT * FROM sys.[dm_exec_requests] WHERE [session_id] = @@SPID;

                                                BEGIN TRAN;
                                                    --SELECT * FROM sys.[dm_tran_session_transactions];  -- session_id and transaction_id... 

                                                    --SELECT * FROM sys.[dm_tran_active_transactions];

                                                    --SELECT @@SPID [session_id];

                                                    -- here's the data i want... i.e., the DBs that @@SPID has a schema_lock on... 
                                                    --      where i KNOW that i can EXCLUDE admindb and have a 99% chance of getting the ID of the db we're in (i.e., it'll be the only other db)
                                                    --      but... let's SAY... someone uses an admindb routine/sproc in, say, widgets... and then they execute widgets.dbo.load_stuff... from the TEST database... 
                                                    --          at that point... the 'chain' of dbs in question should be: TEST -> widgets -> admindb... 
                                                    --                      I can drop admindb... but is the current context TEST or ... widgets? 
                                                    --      IF I could just find which one of these lock_owner_addresses is the 'top' or ... mostest or biggest or least-recent-est or whatever... then i'd be good. 
                                                    SELECT 
                                                        '[dm_tran_locks]' [dmv_name],
                                                        [request_session_id],
                                                        [resource_database_id],
                                                        [lock_owner_address],
                                                        [request_owner_lockspace_id]
                                                        --[resource_type],
                                                        --[resource_description],
                                                        --[request_mode],
                                                        --[request_type],
                                                        --[request_status],
                                                        --[request_reference_count],
                                                        --[request_lifetime],
                                                        --[request_exec_context_id],
                                                        --[request_request_id],
                                                        --[request_owner_type],
                                                        --[request_owner_id],
                                                        --[request_owner_guid],
                                                    FROM sys.[dm_tran_locks] WHERE [request_session_id] = @@SPID;

                                                    -- I CAN/COULD/WILL be able to get dm_tran_locks.lock_owner_address <==>  sys.dm_os_waiting_tasks.resource_address - from which I could derive (I assume)
                                                    --          some other/better details (hmm... maybe I can't?)
                                                    --      Either way... sys.dm_os_waiting_tasks doesn't do me ANY good... 
                                                    --      cuz I don't have waiting tasks... at all... 


                                                    -- both of these line up nicely... and give me a few details - i.e., task_address -> worker_address and ... sys.dm_os_workers SEEMS like it'd have some
                                                    --      fun stuff in it... but ... nope... 
                                                    --          though... the is_inside_catch ... yeah, nmd. was going to say, i could put the guts of this sproc in a catch... 
                                                    --              and, lol, even an exception_id (damn)... 
                                                    --                  so that I'd know which context/task i was in... (that's almost do-able... sheesh)
                                                    --                      but... who's to say that the CALLING code (2x dbs above) wouldn't be in a CATCH / exception... sigh. 
                                                    SELECT 
                                                        '[dm_os_tasks]' [dmv_name],
                                                        [task_address],
                                                        [worker_address],
                                                        [task_state],
                                                        [scheduler_id],
                                                        [session_id],
                                                        [exec_context_id],
                                                        [request_id],
                                                        [parent_task_address]
                                                    FROM 
                                                        sys.[dm_os_tasks] WHERE [task_address] = (SELECT [task_address] FROM sys.[dm_exec_requests] WHERE [session_id] = @@SPID);

                                                    SELECT 
                                                        '[dm_os_workers]' [dmv_name],
                                                        [task_address],
                                                        [worker_address],
                                                        [is_inside_catch],  -- hmmmmmmm
                                                        [affinity],
                                                        [state],
                                                        [last_wait_type],
                                                        [return_code],
            
                                                        [memory_object_address],
                                                        [thread_address],
                                                        [signal_worker_address],
                                                        [scheduler_address],
                                                        [processor_group] 
                                                    FROM 
                                                        sys.dm_os_workers 
                                                    WHERE 
                                                        [task_address] = (SELECT [task_address] FROM sys.[dm_exec_requests] WHERE [session_id] = @@SPID);


                                                    --- HMMM... this MIGHT be it: 
                                                    --      sys.dm_os_workers.signal_worker_address (which is the last worker that SIGNALED this worker (which makes perfect sense)) is: 0x0000027897386160
                                                    --      whereas sys.dm_os_tasks.worker_address = 0x0000027891CE6160

                                                    -- so: 
                                                    --      0x000002789 1CE 6160
                                                    --  and
                                                    --      0x000002789 738 6160
                                                    --   dang... off by those 3 digits... 
                                                    --      and... signal_worker_address keeps 'incrementing' ... 



                                                    -- damnit... 
                                                    --      dm_os_waiting_tasks.resource_address == sys.dm_tran_locks.lock_owner_address - only... i DON'T have a waiting task... 
                                                    --      where else can i get a resource_address? 

                                                    --SELECT * FROM sys.[dm_tran_current_transaction];

                                                    --SELECT * FROM sys.[dm_tran_database_transactions];  -- weird... says i'm in ... db_id of 1 while I'm running this ... cuz... yeah, i guess i am... 

                                                COMMIT;

                                                --DBCC INPUTBUFFER(@@SPID);

                                                --SELECT @@PROCID [proc_id];

                                                --SELECT CURRENT_REQUEST_ID() [request_id];
                                                --SELECT CURRENT_TRANSACTION_ID() [tx_id];  -- 2016 only..

                                        ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------


    TESTS/EXECUTION SAMPLES: 

    -- Expect 'msdb' as result-set:
            USE [msdb];
            GO

            EXEC admindb.dbo.get_executing_dbname;

    -- Expect 'admindb' as result-set:
            USE [master];
            GO

            EXEC admindb.dbo.get_executing_dbname;

    -- Expect 'meddling' as result-set: 
            USE [meddling];
            GO

            EXEC admindb.dbo.get_executing_dbname;


    -- Expect 'meddling' as value of @dbname; 
            USE [meddling];
            GO
            
            DECLARE @dbname sysname = NULL;
            EXEC admindb.dbo.get_executing_dbname @ExecutingDBName = @dbname OUTPUT; 

            SELECT @dbname [reply];

    USAGE: 
        assume we want the following to work: 

            USE demo; 
            GO 

            EXEC admindb.dbo.list_table_details;
            GO 

        and we want tables from the WIDGETS database to be listed...  then... the IMPLEMENTATION for that is fairly straight-forward in the form of: 

            1. The signature for dbo.list_table_details NEEDS an @TargetDatabase  (sysname) parameter. 
            2. I'll set that to N'[CALLING_DB]' as a specialized token... 
            3. IF, during processing of list_table_details... we see that there's a specified value for @TargetDatabase (e.g., @TargetDatabase = 'Kittens'), then we use that
                OTHERWISE, we swap out [CALLING_DB] with the result/output from dbo.get_executing_dbname... 

                all... of which... kicks ass. 

*/

USE [admindb];
GO

IF OBJECT_ID('dbo.get_executing_dbname','P') IS NOT NULL
	DROP PROC dbo.[get_executing_dbname];
GO

CREATE PROC dbo.[get_executing_dbname]
    @ExecutingDBName                sysname         = N''      OUTPUT		-- note: NON-NULL default for RETURN or PROJECT convention... 
AS
    SET NOCOUNT ON; 

    -- {copyright}

    DECLARE @output sysname;
    DECLARE @resultCount int;
    DECLARE @options table (
        [db_name] sysname NOT NULL 
    ); 

    INSERT INTO @options ([db_name])
    SELECT 
        DB_NAME([resource_database_id]) [db_name]
        -- vNext... if I can link these (or any other columns) to something/anything in sys.dm_os_workers or sys.dm_os_tasks or ... anything ... 
        --      then I could 'know for sure'... 
        --          but, lock_owner_address ONLY maps to sys.dm_os_waiting_tasks ... and... we're NOT waiting... (well, the CALLER is not waiting).
        --, [lock_owner_address]
        --, [request_owner_lockspace_id]
    FROM 
        sys.[dm_tran_locks]
    WHERE 
        [request_session_id] = @@SPID
        AND [resource_database_id] <> DB_ID('admindb');
        
    SET @resultCount = @@ROWCOUNT;
    
    IF @resultCount > 1 BEGIN 
        RAISERROR('Could not determine executing database-name - multiple schema locks (against databases OTHER than admindb) are actively held by the current session_id.', 16, 1);
        RETURN -1;
    END;
    
    IF @resultCount < 1 BEGIN
        SET @output = N'admindb';
      END;
    ELSE BEGIN 
        SET @output = (SELECT TOP 1 [db_name] FROM @options);
    END;

    IF @ExecutingDBName IS NULL BEGIN 
		SET @ExecutingDBName = @output;
      END;
    ELSE BEGIN 
        SELECT @output [executing_db_name];
    END;

    RETURN 0; 
GO