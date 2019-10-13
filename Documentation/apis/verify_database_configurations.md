






From Jira: 
https://overachieverllc.atlassian.net/browse/S4-182

Issue S4-174 has some additional info but the short version is that I need to document the following relative to dbo.verify_database_configurations: 

it IGNORES database ownership for dbs that are synchronized (mirrored/ag’d). 

IF you care about that (and you sort of should)… then a) set this up against both servers (i.e., a run of this sproc)… and b) set up dbo.verify_server_synchronization - which will check on and report on any issues in this regard. the rub, of course, is that you can’t CHANGE ownership… but… whatever… 

(And, of course, outline how you would change ownership, as in you have a few options: 

remove the db from ‘sync’ and restart it from scratch - as/with the 0x01 SID. Yeah. lame. 

execute a failover, switch owner on the now live/active server, fail-back. (my account for failover sproc will do this automagically - or can… i.e., if you failover it’ll auto do that).



Issue 174: 
https://overachieverllc.atlassian.net/browse/S4-174




