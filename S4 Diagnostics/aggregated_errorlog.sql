/*


*/

USE [admindb];
GO

IF OBJECT_ID(N'dbo.[aggregated_errorlog]', N'P') IS NOT NULL
	DROP PROC dbo.[aggregated_errorlog];
GO

CREATE PROC dbo.[aggregated_errorlog]
	@event_data							xml				= NULL,
	@top								int				= 100,
	@start								datetime		= NULL, 
	@end								datetime		= NULL, 
	--@messages							nvarchar(MAX)	= NULL,			-- EITHER: a) exact text to include or -exclude and/or b) {tokens} or {types-of} {errors} to include or -exclude. 
	@serialized_output					xml				= N'<default/>'	    OUTPUT		
AS
    SET NOCOUNT ON; 

	-- {copyright}
	
	SET @top = ISNULL(@top, 100);

	CREATE TABLE #event_log_entries (
		[row_number] int IDENTITY(1,1) NOT NULL,
		[log_date] datetime NOT NULL,
		[process_info] sysname NOT NULL,
		[text] varchar(2048) NOT NULL
	);

	IF @event_data IS NULL BEGIN 
		EXEC dbo.[extract_log_events]
			@start = @start,
			@end = @end,
			@serialized_output = @event_data OUTPUT; 		
	END;

	INSERT INTO [#event_log_entries] ([log_date], [process_info], [text])
	SELECT 
		 [log_date],
		 [process_info],
		 [text]
	FROM 
		dbo.[log_events_data](@event_data)
	ORDER BY 
		[row_id];

	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Bulk Cleanup / Exclusions:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/
	-- TODO: 
	--		really need to 'standardize' or tokenize content here.. 
	--			e.g., 
	--				anything inside of () should be tokenized?
	--				anything inside of '' should be tokenized? 
	--				ditto ... [] ... and any other 'common pattern' that SQL Server uses to identify SPECIFICS/DETAILS vs the overall error-message.
	--				any DATABASE_NAME (i.e., from sys.databases) should be converted to {DB_NAME} or some similar token. 
	--			doing this would make aggregation soo much better. 
	--		i just need a highly performant approach to this. 
	--		and... this MIGHT be the 'way' - at least for DB names: 
	--			https://dba.stackexchange.com/questions/326477/replace-specific-string-with-blank-even-if-partial-match-with-another-column-val/326480#326480

	-- ALSO. 
	--	is there a way to 'collapse' errors? 
	--		eg. if the ENTIRE ENTRY or [text] is something like: Error: 17836, Severity: 20, State: 14.
	--		can i ALWAYS (1000000000% confidence) assume that the preceding (or maybe the following?) entry is the message? 
	--			e.g., 18456s always work 'this way' - you get the error, then a message with the details. 
	--			i just don't THINK I can 10000% assume thread-safety here (though... I guess I could LINK via the [process_info] column? that should... be safe (i.e., that and [log_date])? 
	--		and/or ... another thing to think on: ... maybe replace and/or augment something like "Error: 17836, Severity: 20, State: 14." with ... a lookup against sys.messasges WHERE message_id = xxx and lcid = 1033 or whatever?


	/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- Explicit Problems / Tasks to Address:
	---------------------------------------------------------------------------------------------------------------------------------------------------*/

/*---------------------------------------------------------------------------------------------------------------------------------------------------
	-- OTHER things to look for within the logs: 
	--		A. N'Setting database option %' for any database NOT LIKE N'%s4test'; -- i.e., want to see what changes are/were made to prod dbs/etc. 
	--			IN FACT. I can (and probably should - by this point) DELETE from [#event_log_entries] WHERE [text] LIKE N'%s4test'; 
	--				and, sigh, guess I should a) move this 'suffix' into dbo.settings ... and pull from settings for this via dbo.restore_tests ... etc. 
	--				DOING this will ALSO make backup EXCLUSIONS cleaner/easier as well - i.e., exclude this suffix ... as defined in dbo.settings - across the board.
	--		B. N'Buffer Pool scan took %' ... I think. (though, looks like a decent number of these occur during DBCC checks.)	
				-- yeah. seeing them fairly consistently on X3-SQL2 during DBCC checks (only). BUT... there's some semi-decent mem pressure on that server. 
	--		C. Patches? (i.e., CU installation?) 
	--				I THINK that CUs getting installed CAN be seen with an entry that looks similar to this: 
	--					N'Command Line Startup Parameters:
							 -s "MSSQLSERVER"
							 -m "SqlSetup"
							 -T 4022
							 -T 4010
							 -T 1905
							 -T 3701
							 -T 8015'  -- with the key being the -m switch - i.e., the -m swithc is the one that a) knocks into single-user and b) specifies the NAME of the ONLY app that can connect. 
				Translation, the COUNT of [text] LIKE N'%Startup Parameters%-m "SqlSetup"%-T 4022%' ... etc. 
						- 4022 disables auto-start sprocs. 
						- 1905 - 100% undocumented (even in ktaranov) ... 
						- 3701 ditto
						- 4010 ONLY allowed shared-mem connections. yeah. this is a patching. 
						- 8015 - disable auto (soft?) numa. 
				AND... i can GET version changes from the log - i.e, each time a LOG starts ... the version is dumped ... 
			D. "Process ID 52 was killed by hostname SDC-DEV-01, host process ID 16328."
			E. "Unsafe assembly 'ionic.zip, version=0.0.0.0, culture=neutral, publickeytoken=null, processorarchitecture=msil' loaded into appdomain 11 (SimpsonMPProdWTS.dbo[runtime].15)." 
					yeah. i should totally be looking at aggregating these and returning the count of these in the log. 
					Sadly. I should ALSO be able to run these through a LIST of 'known' (not trusted but ..."don't bother me about these") unsafe assemblies - stored in dbo.settings
						and... maybe I should aggregate and report on total number of 'known' as well. e.g., "480 known/ignored unsafe" could be a row along with '13x 'ionic.zip' as "unsafe assemblies" data
						and then ONLY ALERT on anything NOT in the 'known'. 

			F. Bletch. 
				Finding these (gobs of them) on IME server: 
					Found abnormal XdesId [118641192:0] on page [1:249786], slot 0, Max XdesId [118193832:0], forceStrip 0
					VERY, VERY little info on these via google.
						Gemini tends to think these are related to: replication, CDC, corruption, snapshot-isolation/version-store. 
						NONE of which are a GOOD THING(TM) to have go more or less unnoticed in the logs. 
					Teh Googlez: 
						https://www.google.com/search?q=sql+server+%22found+abnormal+XdesId%22&oq=sql+server+%22found+abnormal+XdesId%22&gs_lcrp=EgRlZGdlKgYIABBFGDkyBggAEEUYOTIKCAEQABiiBBiJBTIKCAIQABiABBiiBDIKCAMQABiiBBiJBTIKCAQQABiABBiiBDIKCAUQABiiBBiJBTIGCAYQRRhA0gEJMTQyNjRqMGoxqAIAsAIA&sourceid=chrome&ie=UTF-8


			G. Error ID 18210. This is a backup failure. 
				I don't REALLY need this on any box that _I_ manage - as MY backups SHOULD catch this. 
				The rub is that ... this is a good 'takeover' detail to be aware of - i.e., when taking over a new box. 

			H. This guy: https://dba.stackexchange.com/questions/64470/bobmgrgetbuf-sort-big-output-buffer-write-not-complete-after-60-seconds
				I'm seeing this on ITS SQL3. 
					Gobs-ish of them. Well, 14x of them in 2 weeks. so, I'm guessing it's just a QUERY FROM ABSOLUTE HELL. 

			I. Need to set up something that IGNOREs these pigs: 
				"RemoveStaleDbEntries" - and... should probably do so WITHIN dbo.aggregated_errorlog.
				As per: 
					https://www.notion.so/overachiever/Hybrid-BufferPool-2d85380af00e80be9cb8e1a26ea1f4ad?source=copy_link#2d85380af00e806ea6a9d5585cb4b93b

			J. Think i potentially need an OPTION for/within dbo.aggregated_errorlogs to @exclude_vuln_scan_errors 
				Thanks to crap like this: 
					https://seangallardy.com/error-8474-state-11-17836-state-20-9642-state-3-and-your-companys-need-to-incessantly-scan-for-vulnerable-ports/

				i.e., I already have a short-ish list of stupid errors thrown/caused by this kind of crap. 
				But... this is 'yet another' and ... I think that ONCE I KNOW that an org is using these ... i should exclude these. 
				they're just NOISE after a certain point. 
					the rub, of course, is ... not sure how I go about tackling the CHANGE from "hey... new client/environment hwere I need to check on EVERYTHING" 
						over to: "ah. yeah. I checked, and they're constantly running vuln scans - vs prod (sigh) - so I need to flip this bit off". 
						Ah. I've got it:
							The reality is that I need this to be a 'setting' in dbo.settings - more so than a @parameter. 
			
			L. I may want to look at REMOVING/EXCLUDING a huge number of 'noise' (i.e., NON PROBLEM) 'errors' or details for any text that: 
				a. matches <_s4test> (by which I mean _s4Test OR THE equivalent (that I'll end up pulling from the settings table, etc.) 
				
				and the intersection of the above with
				b. anything innocuous: "starting up database ... _s4test" ... "settting SINGLE_USER on _s4Test" ... etc. 


			M.1 Definitely look for common / ugly perf warnings like: 
				"SQL Server has encountered x occurance(s) of I/O requests taking longer than 15 seconds" 
				AND similar problems/alerts.
				
			M.2 ... or 
				There have been 718592 misaligned log IOs which required falling back to synchronous IO.  The current IO is on file D:\SQLData\operations_log26.ldf.

				(NOTE: in the message above, the misaligned IOs are on a sparse file... ) 
				
				But... this is a similar error and ... it's NOT against a sparse file: 
				The tail of the log for database webapi_staging is being rewritten to match the new sector size of 4096 bytes.  2560 bytes at offset 2876928 in file D:\SQLData\webapi_staging_log410.ldf will be written.

			N. 
				1660 counts of "The Service Broker endpoint is in disabled or stopped state." 
					noise ... in most ? all ? environmetns>?
*/

	IF (SELECT dbo.is_xml_empty(@serialized_output)) = 1 BEGIN
		
		SELECT @serialized_output = (
			SELECT TOP(@Top)
				COUNT(*) [@count],
				[text] [*]
			FROM 
				[#event_log_entries]
			GROUP BY 
				[text]
			ORDER BY 
				COUNT(*) DESC
			FOR XML PATH(N'entry'), ROOT(N'entries'), TYPE
		);

		RETURN 0;
	END;

	SELECT TOP(@Top)
		COUNT(*) [count],
		[text] [entry] 
	FROM 
		[#event_log_entries]
	GROUP BY 
		[text]
	ORDER BY 
		COUNT(*) DESC;

	RETURN 0;
GO