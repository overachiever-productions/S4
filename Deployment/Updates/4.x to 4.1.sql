


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

	so... the stuff below is fine and fun. 
		but it just won't work when i'm dropping in statements like: 
			CREATE PROC dbo.blah.... after an IF/EXISTS check and all of that stuff... 
				i.e., just too complex. in fact... not really even sure this'll ever work in that type of scenario... 


		Instead... i probably need to put a couple of things in IF statements. 
		like... 
			IF (SELECT currentVersionNumberConvertedToSomething < upgradedVersionInThisBlockOfScript) BEGIN
				-- do stuff

			END 

			-- and so on... 


*/


DECLARE @version varchar(20);
DECLARE @currentVersion varchar(20); 

SELECT @currentVersion = version_number FROM admindb.dbo.version_history WHERE version_id = (SELECT MAX(version_id) FROM admindb.dbo.version_history);


IF @currentVersion LIKE '4.0%'
	GOTO v41;

-- placeholder (i.e., example):
IF @currentVersion LIKE '4.1%'
	GOTO v42;

-- etc. 


-- otherwise, if we're still here, it's a NON-matching/non-accounted for version: 
DECLARE @fatalError sysname = 'Unsupported Version Detected: ' + @currentVersion + '. Can NOT continue.'


RAISERROR(@fatalError, 17, 1) WITH LOG;


-- 4.1 + updates:
v41: 

	PRINT 'Deploying v4.1 Updates....';

	-- Deploy code changes:



	

	-- Add current version info:
	SET @version = N'4.1.0.16764';
	IF NOT EXISTS (SELECT NULL FROM dbo.version_history WHERE [version_number] = @version) BEGIN
		INSERT INTO dbo.version_history (version_number, [description], deployed)
		VALUES (@version, 'Deployed via Upgrade Script.', GETDATE());
	END;

v42: 
	
	PRINT 'Deploying v4.2 Updates.... '


Done: 
	
	PRINT 'Done.';