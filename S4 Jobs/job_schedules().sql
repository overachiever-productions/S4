/*


    IMPLEMENTATION NOTES: 
        
        All Schedules can be formatted as follows: 
            <DATE_SPEC> <TIME_SPEC> [<END_TIME_SPEC>], [<END_DATE_SPEC>]

            <DATE_SPEC>:: 
                [<SPECIFIC> | <RECURRING_DATE> ]

                <SPECIFIC>:: 
                    [ <ONE_DATE_TIME> | When SQL Server Agent is Idle. | At SQL Server Agent Start. ]

                    <ONE_DATE_TIME>:: 
                        One-Time: yyyy-mm-dd at hh:mm:ss.

                <RECURRING_DATE>:: 
                    [ <SIMPLE_RECURRING_DATE> | <COMPLEX_RECURRING_DATE>]
                    
                    <SIMPLE_RECURRING_DATE>::
                        [<Unit>ly. | Every <N> <Unit>s. ]
                        
                        <UNIT> 
                            SINGULAR: Day | Week | Month
                            PLURAL: Days | Weeks | Months

                    <COMPLEX_RECURRING_DATE>:: 
                        [ Weekly. <DAY_OF_WEEK_LIST>. | Monthly. Day X. | Monthly. The <NTH> <DAY_OF_WEEK>. ]


            <TIME_SPEC>:: 
                [At <SPECIFIC_TIME>. | Every <REPEAT_TIME>. Starting at <SPECIFIC_TIME>. ]
                
                    Examples of each of the 3x options (in order):
                        "At 04:02:00. "
                        "Every Second. " 
                        "Every 20 Seconds. "                
            
                <SPECIFIC_TIME>::
                    hh:mm:ss 

                <REPEAT_TIME>:: 
                    [ Second|Minute|Hour ]. | <N> [Seconds|Minutes|Hours].] 
            

            [<END_TIME_SPEC>]:: 
                [ <EMPTY> | Ends at <SPECIFIC_END_TIME> ]
                
                Examples of both options (in order): 
                    ""
                    "Ends at 18:52:00. "

                <EMPTY>
                    NULL or N''.

                <SPECIFIC_END_TIME>::
                    hh:mm:ss 
                
            [<END_DATE_SPEC>]:: 
                [ <EMPTY> | Stops on <SPECIFIC_DATE> ]
                
                Examples of both options (in order): 
                    ""
                    "Stops on 2024-12-31. " 

                <EMPTY>
                    NULL or N''.

                <SPECIFIC_TIME>::
                    hh:mm:ss 



*/



USE [admindb];
GO

IF OBJECT_ID(N'dbo.job_schedules', N'IF') IS NOT NULL
	DROP FUNCTION dbo.[job_schedules];
GO

CREATE FUNCTION dbo.[job_schedules]()
RETURNS table
AS
    RETURN

	-- {copyright}
    
	WITH specifications AS (
		SELECT 
			[schedule_id], 
			/*---------------------------------------------------------------------------------------------------------------------------------------------------
			-- DATE_SPEC
			---------------------------------------------------------------------------------------------------------------------------------------------------*/
			CASE 
				WHEN [freq_type] = 1 THEN REPLACE(CONVERT(sysname, msdb.dbo.[agent_datetime]([active_start_date], [active_start_time]), 120), N' ', N' at') 
				ELSE NULL
			END [one_date_time],
			CASE WHEN [freq_type] = 4 THEN
				CASE WHEN freq_interval > 1 THEN N'Every ' + CAST([freq_interval] AS sysname) + N' Days. ' ELSE NULL END
				ELSE NULL
			END [days],
			CASE WHEN [freq_type] = 8 THEN 
				CASE WHEN [freq_recurrence_factor] > 1 THEN N'Every ' + CAST([freq_recurrence_factor] AS sysname) + N' Weeks. ' ELSE N'Weekly. ' END
				ELSE NULL
			END [week],
			CASE [freq_type]
				WHEN 8 THEN 
					CASE WHEN [freq_interval] = 127 THEN N'Every Day of the Week. '  -- "dumb" schedule. It's currently at EVERY day by using WEEKLY + setting execution for EVERY. DAY. OF. THE. WEEK.
					ELSE N'' + 
						CASE WHEN ([freq_interval] & 1) = 1 THEN N'Sunday, ' ELSE N'' END +
						CASE WHEN ([freq_interval] & 2) = 2 THEN N'Monday, ' ELSE N'' END +
						CASE WHEN ([freq_interval] & 4) = 4 THEN N'Tuesday, ' ELSE N'' END +
						CASE WHEN ([freq_interval] & 8) = 8 THEN N'Wednesday, ' ELSE N'' END +
						CASE WHEN ([freq_interval] & 16) = 16 THEN N'Thursday, ' ELSE N'' END +
						CASE WHEN ([freq_interval] & 32) = 32 THEN N'Friday, ' ELSE N'' END +
						CASE WHEN ([freq_interval] & 64) = 64 THEN N'Saturday, ' ELSE N'' END
					END
				ELSE 
					NULL
			END [days_of_week],
			CASE WHEN [freq_type] IN (16, 32) 
				THEN CASE WHEN [freq_recurrence_factor] > 1 THEN N'Every ' + CAST([freq_recurrence_factor] AS sysname) + N' Months. ' ELSE N'Monthly. ' END
				ELSE NULL
			END [month],
			CASE 
				WHEN [freq_type] = 16 THEN N'Day ' + CAST([freq_interval] AS sysname) + N'. '
				WHEN [freq_type] = 32 THEN N'The ' +
					CASE [freq_relative_interval]
						WHEN 1 THEN N'First '
						WHEN 2 THEN N'Second '
						WHEN 4 THEN N'Third '
						WHEN 8 THEN N'Fourth '
						WHEN 16 THEN N'Last '
						ELSE N''
					END + 
					CASE [freq_interval]
						WHEN 1 THEN N'Sunday'
						WHEN 2 THEN N'Monday'
						WHEN 3 THEN N'Tuesday'
						WHEN 4 THEN N'Wednesday'
						WHEN 5 THEN N'Thursday'
						WHEN 6 THEN N'Friday'
						WHEN 7 THEN N'Saturday'
						WHEN 8 THEN N'Day'
						WHEN 9 THEN N'Weekday'
						WHEN 10 THEN N'Weekend Day'
						ELSE N''
					END + N'. '
				ELSE NULL
			END [month_day],

			/*---------------------------------------------------------------------------------------------------------------------------------------------------
			-- TIME_SPEC
			---------------------------------------------------------------------------------------------------------------------------------------------------*/
			LEFT(RIGHT(N'000000' + CAST([active_start_time] AS sysname), 6), 2) + 
					N':' + SUBSTRING(RIGHT(N'000000' + CAST([active_start_time] AS sysname), 6), 3, 2) + 
					N':' + RIGHT(RIGHT(N'000000' + CAST([active_start_time] AS sysname), 6), 2) 
			[specific_time],
			CASE [freq_subday_type]
				WHEN 2 THEN N'Every ' + CAST([freq_subday_interval] AS sysname) + N' seconds. Starts at {specific_time}. '
				WHEN 4 THEN N'Every ' + CAST([freq_subday_interval] AS sysname) + N' minutes. Starts at {specific_time}. '
				WHEN 8 THEN N'Every ' + CAST([freq_subday_interval] AS sysname) + N' hours. Starts at {specific_time}. '
				ELSE NULL 
			END [repeat_time], 

			/*---------------------------------------------------------------------------------------------------------------------------------------------------
			-- END_TIME_SPEC:
			---------------------------------------------------------------------------------------------------------------------------------------------------*/
			CASE 
				WHEN [active_end_time] = 235959 THEN NULL 
				ELSE 
					CASE WHEN [freq_subday_type] = 1 THEN N'at the specific time in question'  -- not EVEN sure this will EVER be a case... 
					ELSE 
						CASE 
							WHEN ([freq_subday_type] = 2) AND (235959 - [active_end_time]) < ([freq_subday_interval]) THEN N'' --N'fine (same as no end time (seconds))' 
							WHEN ([freq_subday_type] = 4) AND (235959 - [active_end_time]) < ([freq_subday_interval] * 60) THEN N'' --N'fine (same as no end time (minutes))' 
							WHEN ([freq_subday_type] = 8) AND (235959 - [active_end_time]) < ([freq_subday_interval] * 360) THEN N'' --N'fine (same as no end time (hours))' 
							ELSE 
								N'Ends at ' + LEFT(RIGHT(N'000000' + CAST([active_end_time] AS sysname), 6), 2) + 
									N':' + SUBSTRING(RIGHT(N'000000' + CAST([active_end_time] AS sysname), 6), 3, 2) + 
									N':' + RIGHT(RIGHT(N'000000' + CAST([active_end_time] AS sysname), 6), 2) + N'. '
						END
				END
			END [specific_end_time],

			/*---------------------------------------------------------------------------------------------------------------------------------------------------
			-- END_DATE_SPEC:
			---------------------------------------------------------------------------------------------------------------------------------------------------*/
			CASE WHEN [active_end_date] = 99991231 THEN NULL ELSE N'Expires On ' + REPLACE(CONVERT(sysname, msdb.dbo.[agent_datetime]([active_end_date], [active_start_time]), 120), N' ', N' at ') END [job_end]
		FROM 
			[msdb]..[sysschedules]
	)

	SELECT 
		[x].[schedule_id],
		[x].[name] [schedule_name],
		CASE [x].[freq_type]
			-- date_spec + time_spec
			WHEN   1	THEN N'One-Time. At ' + [s].[one_date_time] + N'.'
			WHEN   4	THEN ISNULL([s].[days], N'Daily. ')																		+ REPLACE(ISNULL([s].[repeat_time], N'At ' + [s].[specific_time] + N'.'), N'{specific_time}', [s].[specific_time]) 
			WHEN   8	THEN ISNULL([s].[week],  N'Weekly. ')	+ LEFT([s].[days_of_week], LEN([s].[days_of_week]) - 1) + N'.'	+ REPLACE(ISNULL([s].[repeat_time], N'At ' + [s].[specific_time] + N'.'), N'{specific_time}', [s].[specific_time]) 
			WHEN  16	THEN ISNULL([s].[month], N'Monthly. ')	+ [s].[month_day]												+ REPLACE(ISNULL([s].[repeat_time], N'At ' + [s].[specific_time] + N'.'), N'{specific_time}', [s].[specific_time]) 
			WHEN  32	THEN ISNULL([s].[month], N'Monthly. ')	+ [s].[month_day]												+ REPLACE(ISNULL([s].[repeat_time], N'At ' + [s].[specific_time] + N'.'), N'{specific_time}', [s].[specific_time]) 
			WHEN  64	THEN 'At SQL Server Agent Start.'
			WHEN 128	THEN 'When SQL Server is Idle.'
		END 
		+ ISNULL([s].[specific_end_time], N'') + ISNULL([s].[job_end], N'')
		
	
		[schedule_summary],
		[p].[name] [owner],
		[x].[enabled],
		[x].[date_modified] [last_modified],
		[x].[version_number] [version]
	FROM 
		[msdb]..[sysschedules] [x]
		-- TODO: 95% sure that x.owner_sid SHOULD map to msdb.sys.database_principals.SID instead. But then I'd have to translate 0x0 from db_owner to 'sa' ... but, still, that'd be RIGHT. 
		--			HMMM. OR NOT. i.e., the "other 5%" here is that ... SSMS shows job OWNERS for 0x01 as 'sa' - NOT 'dbo'/db_owner or anything LOCAL to msdb. so... yeah. 
		LEFT OUTER JOIN sys.[server_principals] [p] ON [x].[owner_sid] = [p].[sid]
		INNER JOIN [specifications] [s] ON [x].[schedule_id] = [s].[schedule_id];
    
GO