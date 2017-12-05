


/*
	currently, this is just a place-keeper.


	So. Thought/Idea...

	if a system has, say, 4.0 deployed... and there are 4.1, 4.2, 4.3, 4.3.5, 4.4, 4.6, and 4.8 versions since then... 

	i just want/need a 4.x to 4.8 script... 
		i.e., a single upgrade script for ALL versions of the current, 'dot release/version' on up the to latest. 

		and... the idea is that... 
			the 4.8 upgrade script would have: 
				4.1 upgrades/changes
				4.2 upgrades/changes (from 4.1 to 4.2... etc)...  
				4.3  ... etc. 
				4.3.5 (i.e., some bug/security fix/whatever)
				... and so on

				each executed and implemented in order... 
					and LOGGED into dbo.version_history/info so that... MAX(version_number) is always going to be the actual/correct version on a server... 



*/