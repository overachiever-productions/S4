# S4 Examples (Features and Benefits)

[NOTE TO SELF: No one wants to read a treatise on what S4 does for them. They want to see the benefits - first hand. So, just provide a VERY short statement here about how S4 combines useful stuff with convention and enables ... simplicity.]
[purpose... simplify many common tasks and address other needed tasks etc. - all from a set of standardized interfaces and .. conventions.]


## S4 Documentation
* [Setup and Installation](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2FSETUP.md)

* **Examples (Features and Benefits)**
* [Using S4 (Conventions and Best Practices)s](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2FCONVENTIONS.md)
* [APIs (Detailed Documentation)](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2FDOCS.md)


### <a name="toc"></a>Examples Table of Contents
- [xxxxx](#xxxx)
- [yyyy](#yyyy)
- [zzzzzz](#zzzz)


### <a name="xxxx"></a>XXXX
[start simple and easy/obvious]

### <a name="yyyy"></a>YYYY
[and work up to more and advanced - and more beneficial features]

### <a name="zzzz"></a>ZZZZ
[to the point where these 'examples' act, effectively, like both a) a tutorial on how to use S4 and b) a 'sales pitch' on WHY you'd want to ... ]


[NOTE TO SELF: for each/every example, explain the problem (show an example when possible - they're better than text), and then show how S4 tackles the problem - i.e., exact syntax and obvious/implied benefits
Likewise, for each of the 'examples' below, once I've shown 'basic' examples, then make sure to link to the 'detailed' docs for each 'task'/sproc/block-of-functionality in question.
]


[NOTE TO SELF:
Here's a rough outline of what I might want to cover (i.e., in order)


- count matches - and some of the other 'utilities' that S4 provides (and stub these out a bit better - as well as figure out the exact difference between 'tools' and 'utilities' - as well as the same thing with 'common' vs utilities. (and, i believe the difference is that 'common' are 'core' bists of functionality that are used by lots or many OTHER bits of functionality.)
- convert to such and such (case changes or whatever... )
- other simple bits of manipulation
- string splits
- string shreds

- format timespans

- list processes 
- list transactions
- list collisions

- script a single login

- get comparable version number (i.e., decimal(x,y)) - for programatic coding of features/functionality

- script all logins for a single db

- script all logins on server

- script all logins on server except certain dbs 

- script all logins on server except specific login names

- script all logins on server except dbs, login name patterns, and single login names... 

- dump/script server config...

- generate server-config signature/hash.

- setup job to dump server config + hash as part of DR / CYA / BACKUP info... 

- setup job to alert if signature changes (hmmm... how would I keep tabs on the previous one? or would the DBA hard-code this crap into the job? hard-coding would actually make the most sense. that way, UNTIL the dba changes this hard-coded value, they get an alert "this changed" ... which makes sure that they HAVE to 'address' this in some way or another)

- Listing Databases. dbo.list_ databases (which doesn't exist yet - but is just a wrapper that 'consumes + projects' the contents of dob.list_ databases). And show how we can easily exclude and/or prioritize them. 
- loading/iterating over databases. dbo.load_ databases. and why you'd use it... to get around the whole, stupid, insert exec... and .. maybe showcase/explain WHY load_databases even needs anything like this lame-ass work-around. (Truth is MAYBE it's time to 'split' the logic that loads dbs from the FILE system OUT of dbo.list_databases and have dbo.load_databases be the one that does the pull from file system processing.) That would result in WAY better factors. YEah. do this. Just have to see what, inside of dbo.load_databases (today) is necessitating INSERT EXEC stuff... And, another idea/option MIGHT be that dbo.load_databases is ONLY for loading from the file system AND it ONLY allows a PATH as the main argument - no priorities, no excusions, and so on - with the idea that if we're doing someting like dbo.restore_db. and we get [READ_FROM_FILE_SYSTEM] we convert that 'token' into a 'list' of dbs in the form of @serializedOutput, and then that 'list' gets passed into dbo.list_databases... that way i've got the same 'magic' - but WAY better factors and useability - as the only time I'd have to worry about deserializing db names would be from dbo.load_databases.


- full backup of system databases to default location. (note, 2 days worth of backups being kept)

- full backup of user databases to default location. (note: 3 days of backup kept)

- full backup of user databases to an explicitly defined path... 

- full backup of user databases to blah, copied to yada yada

- specify different retention values for local and @copyToLocation

- ditto - but skip secondaries... 

- ditto, but use a cert

- diff backups (retention)

- log backups

- backup system dbs - to folders that include server names

- execute a copy only backup

[Point out that by means of conventions, it's pretty easy to spin up quite a bit of functionality, with a minimum of configuration]


- restore a database from x to y

- restore the db and run checks

- restore specific pages only

- restore in a smoke and rubble scenario

- set up nightly restore tests on the same server... (i.e., {0}_test) [+ info on how to set up a job - i.e., - link to info on creating jobs]

- set up nightly restore tests on another server.... (ditto on like to scheduling)

- list metrics about restored databases... 

- provision a DB from/as a copy of another db... and kick off backups/etc. on the fly. (info about ow dbo.copy_database is great for multi-tenant systems - and you can/should be using model as the source.)


- overwrite/zero-step a database as part of a dev sandbox (i.e., copy S4-generated backups down from another location...  (and, eventually, i might allow a '{file_format}' token or setup of some kind... but that's WAY far out... ACTUALLY. A better option than trying to either a) pass in an @BackupFormatPattern parameter or b) stuffing some sort of 'translation key' into dbo.settings.... have a full blown sproc called dbo.rename_backups... which will take in 'pattern' info about 1 or more backup types (i.e., full, diff, log, file?) and will simply RENAME existing backups to a pattern that works with S4's conventions. THat way, dbo.restore_database and all other 'convention-based' file-names stay AS IS, but it's easy to 'import'/ upgrade from other systems AND even 'bridge' 2 systems - as in, someone could use Ola's backups for prod... push them to their dev location... and use a nightly conversion job or combine/chain a 'rename' -> 'restore' script to do whatever they need.

- create a deadlock/blocked-processes report trace.. 

- extract deadlock xel

- extract blocked processes info xel
(and show how INSANELY detailed the info is .... )

- verify that path exists on server... 

- execute command with basic retry logic and advanced error handling.


- set up an audit

- generate and output an audit signature. 

- set up a job to compare audit signatures - and alert if they change. 

- list running jobs

- list jobs running fro x to y

- is such and such job running right now?

- handle job completion BETTER ... (i.e., better handling at the end of the job)

- list log file sizes.. 

- shrink log files (and why)

- list db sizes and stuff... 

- list wait stats

- list 'live' wait stats (i.e., vector stuff)

- list file stalls / live file stalls

- config-check a server (i.e., using the logic I've created for server checkup/anaysis (for the healthcare testing people)).

- enable alerts for low drive space

- enable alerts for long-running (and long-running/blocking transactions)

- ditto, but exclude some jobs. 

- report on dbs not configured to best practices (and set up job for auto alerts).

- report on dbs not backed up in X - and setup auto alerts

- check on last time a db was used/touched - and jobs for the same... 

- initialize a mirrored or AG database... (diff sprocs per each..)

- compare settings between two (or more) 'paired' SQL Servers 

- setup a job to alert on differences in server configs in 'teamed' environments

- setp a job that syncs specific settings/types-of-settings between 'teamed' servers (latest changes win). NOTES about what won't be touched. notes about options to touch other things by modifying settings. link to the dbo.sync_details sproc and docs. 

- setup a job to monitor and alert on health problems - like missig witnesses or compromized throughput

- detailed index stats

- setup database mail

- normalize statement

- extract statement from sproc by name + lines/offsets

- extract wait-resource

- print strings > 4000k ... (i.e., debug larger statements)
]







- backups - blah blah blah... 
- restore tests - know if your backups are worth a damn and are meeting SLAs - with very little effort. 
- error logging, stats/details about backups and restore tests... 
- copy / clone / provision dbs. 
- deploy, monitor, and manage HA solutions (AGs and Mirroring (simplified log shipping)).
- [perf crap]
- diagnostics
- tools... 
- monitoring for common this that the other thing, etc. 
- metrics collection/analysis... 
- simplfied auditing and auditing monitoring/enforcement helps/tips.
- best practices info on TDE, backups, restore, etc... 

all of which are free, designed to be easy to use, and something something something.