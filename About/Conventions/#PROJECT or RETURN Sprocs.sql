/*


    [NOTE - VERY ROUGH DRAFT]


    OVERVIEW: 
        A number of S4 sprocs have the ability to be 
            a) called interactively from the console - where they'll PROJECT output via 'SELECT' or PRINT operations. 
          or 
            b) called programatically via their APIs - where they'll OUTPUT results via an OUTPUT parameter. 

        
    JUSTIFICATION:
        OBVIOUSLY, if the output of a sproc can/should/needs to be consumed INSIDE another sproc, then the typical 
            approach there is to execute something similar within the CALLING/CONSUMING sproc:

                        CREATE table #sprocOutput (
                            columns, 
                            here_to, 
                            match,
                            sproc_output, 
                            columns
                        ); 

                        INSERT INTO @sprocOutput
                        EXEC dbo.sprocNameHere @with, @parameters; 

                and then interact with the outputs as expected/needed. 

        ONLY, this only works 1x layer 'deep'. 
             i.e., NESTED INSERT-EXEC is a no-no... 

        SO... that means that, in some cases, sprocs which could/would NORMALLY just 'spit out' output via a projection
            MIGHT need to be defined so that they can spit out their output via an @Output/@Results/@Etc OUTPUT parameter
            in order to avoid NESTED-INSERT-EXEC problems. 
                And, obviously, in the case of 'set' output (i.e., outputs of non-scalar values) the 'set' data will 
                need to be serialized (since Table-Valued-Parameters can ONLY be READ-ONLY (and can't be passed OUT of a sproc). 
                    Within S4, serialized OUTPUT values are usually serialized as xml (JSON is cooler/sexier - but XML can be 
                    natively extracted on SQL Server versions 2000+ ... instead of 2016+).



    CONVENTION: 
        
        - PROJECT or REPLY sprocs are defined with _OPTIONAL_ OUTPUT parameters. 
            Optional in the sense that they're always declared with a DEFAULT value (so that if they're NOT explicitly specified during
                call/execution, they'll be set to their default values). 

        - If the @OptionalOutputParamName OUTPUT parameter is EXPLICITLY specified AND set to NULL, sproc behavior is to REPLY (via the parameter)

        - If the @OptionalOutputParameterName OUTPUT param IS NOT explicitly specied and/or is NOT explicitly set to a NULL value, 
            then sproc behavoir is to PROJECT. 
            

    EXAMPLEs: 
        Assume a simple sproc like the following: 

                            CREATE PROC dbo.get_timestamp 

                            AS 
                                SET NOCOUNT ON; 

                                SELECT GETDATE() [timestamp]; 

                                RETURN 0;
                            GO 

            Obviously, this sproc PROJECTs output. 

            Assume, however, that its output needs to be 'consumed' by another sproc and, in turn, that sproc needs its output
                to be consumed by a further/additional sproc - at which point INSERT EXEC operations will nest - and throw errors. 
                    (Note that we don't even HAVE to be trying to consume this 'stupid' datetime-stamp... we simply can't have
                        a single sproc that runs an INSERT EXEC call ANY OTHER sproc that runs an INSERT EXEC or ... we hit the error). 

                In this case, the sproc would be modified as follows: 

                            CREATE PROC dbo.get_timestamp 
                                @OutputValue        datetime    = '1900-01-01 00:00:00.000'  OUTPUT 
                            AS 
                                SET NOCOUNT ON; 

                                DECLARE @result datetime = GETDATE(); 

                                IF @OutputValue = '1900-01-01 00:00:00.000'  -- a value was NOT explicitly set. 
                                    SELECT @result [timestamp];
                                ELSE 
                                    SET @OutputValue = @result;

                                RETURN 0;
                            GO 
                        
                In which case: 

                            EXEC dbo.get_timestamp; 

                      would PROJECT the current date-time as [timestamp] 

                and: 
                            DECLARE @timestamp datetime = NULL;
                            EXEC dbo.get_timestamp @OutputValue = @timestamp OUTPUT; 

                        or 
                            DECLARE @timestamp datetime;  -- null association IMPLIED, but more SMELLY than explicit definition.... 
                            EXEC dbo.get_timestamp @OutputValue = @timestamp OUTPUT; 

                      would REPLY with the current date-time value into that @timestamp variable. 





*/