/*

    VERY-HIGH-LEVEL 'docs' (i.e., notes is more accurate). 

    OVERVIEW
        - 2 related conventions are defined here: 
            - @DatabaseMappings
            - XE_Data_Views (still need (obviously) a decent name for these). 


    @DatabaseMappings 

        Assume the following scenario: 
            - A 20GB database named 'Widgets' on a VERY busy server - with a database_id of 12; 
            - An XE session/trace with lots of 'low-level' object_ids (for sprocs, views, etc.) and/or Resource Identifiers (e.g., blocked process resources, or deadlocked resource ids). 

                If the above trace is extracted on the SAME server where it was taken, then any S4 code that attempts to look up things like object_ids (by database)
                    and/or low-level resources (HOBTs, index_ids, exact PAGEs, and so on - i.e., see dbo.extract_waitresource), then there won't be any problem executing
                    'lookups' against the source databases/etc. to grab context and/or additional info about these resources. 

            - On the other hand, assume we've MOVED this XE trace/data off to the QA server - because we don't want to run extraction/analyis checks on our VERY busy server. 
                
                In this case, there's already a Widgets database - with, say, a database_id of 18 - which is used for CI/CD and other validation/testing. 
                    In an ideal environment, it would be an EXACT (scrubbed) clone of production - such that object_ids from production and even hobts, index_ids, and the likes
                        would all be an exact match. 
                            Obviously, though, this won't be the case in many environments. 
                            Further, we might not have a QA or other db with a 'copy' of an existing database to 'map against'. 

                        So, for example, assume that on our QA server, we have a FULL backup of the PRODUCTION Widgets database that was taken right towards the 
                            END of our XE trace/session. 

                        And that we've restored it on the QA server - as 'WidgetsFor_XeStuff' - where it has a database_id of 52. 

                    In this scenario, it'd be ideal if we could 'map' XE data for resources such as PAGE: 12:1:14881502 right over to database_id 52 - for translation purposes. 
                        Further, it'd be a bit cleaner IF, in such a scenario any object details we pulled back had translated identifiers that looked like the following: 
                            
                                [Widgets].[dbo].[table_nameHere] (Page Data...) 

                        Instead of looking as follows: 
                            
                                [WidgetsFor_XeStuff].[dbo].[table_nameHere] (Page Data...) 


               - Hence, the OPTION for @DatabaseMappings - a serialized array (i.e., a delimited string) with mappings/binding info. 

               - In the example above (where we'd like to translate Production.Widgets (db_id 12) to QA.WidgetsFor_XeStu7ff (db_id 52), @Database mappings would be specified as follows: 
                
                    @DatabaseMappings = N'12|WidgetsFor_XeStuff|Widgets'; 

                    which will be deserialized into the following 'pseudo-table': 

                            mappings (
                                source_database_id_from_xe                                      int NOT NULL,                   -- i.e., 12 is the ID of the Widgets db on production
                                name_of_proxy_database_on_current_server                        sysname NOT NULL,               -- WidgetsFor_XeStuff 
                                friendly_display_name                                           sysname NULL                    -- Widgets
                            ); 

                        
                        Note that the 3rd 'column' or value is optional. 
                                Meaning that if it were EXCLUDED in the sample/example environment defined above, resource descriptions would be 'mapped' 
                                with names similar to the following: 

                                    [WidgetsFor_XeStuff].[dbo].[table_nameHere] (Page Data...)


                                However, IF we had taken our backup of the Prod.Widgets database and restored it on, say, a local dev machin with the name of 'Widgets', 
                                    Then the following mapping: 
                                        
                                        @DatabaseMappings = N'12|Widgets';

                                    Would point S4 extraction routines at the local 'Widgets' database, and, since the name of this database matches the 'source' database out in 
                                    production, object-names would be 'transparently' translated as expected - e.g., 


                                            [Widgets].[dbo].[table_nameHere] (Page Data...)

            - Finally, mappings for MULTIPLE databases can be specified as needs by means of providing 'multiple' rows. 

                For example: 
                    
                        @DatabaseMappings = N'12|WidgetsFor_XeStuff|Widgets, 18|Tools, 7|UserDetails|UserDetails_ForMapping';
                            
                            Where the Widgets database would be mapped as defined in examples above, 
                                and the UserDetails database would ALSO be mapped to a 'differently-named' database on the target server
                                and, finally, the 'Tools' database - for whatever reason, would have the SAME name in the extraction environment as in production. 
                






    DATA_VIEWs (for XE data)


        AH. here's the naming convention: 
            - dbo.extract_xyz
                which is where I'll pull data for an xyz trace and dump it to some sort of location/place for review/analysis. 
                    
                e.g., 
                    dbo.extract_tempdbspills_data
                    dbo.extract_blockedprocesses_data
                    dbo.extract_deadlocks_data

            - dbo.project_xyz_by_abc
                takes intermediate/'raw' (extracted) data and can consume/project it as needed. 

                e.g., 
                    dbo.project_blockedprocesses_chronologically
                    dbo.project_blockedprocesses_aggregated
                    dbo.project_blockedprocesses_correlated/whatever 

                    only... instead of 3x different sproc names... I'll do: 
                        dbo.project_blockedprocesses 'ModeNameHere'; 

                    then... the same for 
                        dbo.project_tempdbspills 'Chronological' 
                        or 
                        dbo.project_tempdbspills 'Aggregated' 
                        or 
                        dbo.project_tempdbspills 'WorstOffenders' 

                        etc. 


         Which means that dbo.extract xxxx 

            sprocs need to do JUST that - extract data only - and push it to some location where it can then be consumed by various different views. 

        TO DO THIS, I'm going to have to change how some of my existing sprocs work - i.e., break them into 2x parts. 



*/