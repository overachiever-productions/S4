# Synchronized Databases - Mirroring and Availability Groups
Despite the fact that SQL Server Database Mirroring and it's successor, AlwaysOn Availability Groups, provide fantastic options for addressing high-availability for SQL Server databases, both solutions come with a couple of significant limitations that must be addressed before they can be reliably used to protect mission critical systems.

## Challenges Include: 
- Mirroring Scope. [user dbs only - server/host-level stuff isn't addressed. you're on your own - unlike with a cluster.]
- Failover. GOBS of problems here (probably need sub-lists)
> [since you're on your own... failover can be ugly - if both servers aren't configured with the same logins... data might failover, but apps/users can't connect.] 
> [trace flags and server tweaks/optimizations... ] 
> [Notifications. NOTHING tells you if you've failed over. Yeah, sure, hardware folks are to blame... but you might want to know as a DBA... ]

- Compromised Infrastructure. [Automated Failover for Mirroring Requires 3x servers. For AGs it requires 2x servers and an additional resource for quorum... If one of those goes offline or becomes compromised, auto failover is out of the questions. So... it'd be nice to know if there are any probelms with parts of the overall solution - i.e, if any of your infrastructure is compromised. ]

- Backups. [At bare minimum... need to copy all backups to ALL servers. better option is to push to a 3rd location (UNC share/etc.)... but.. that means jobs can/should run all of the time/etc. ]

- Batch Jobs. [jobs that do biz logic... are a problem. do you run them on both servers... etc.. ]


[TODO:]
- Pull more info out of D:\Projects\SQLServerAudits.com\Solutions\Mirroring\SQL Server Administration for Mirrored Databases.docx
- create a table of contents for THIS 'page' and then link this 'page' back to the overall HA root and documentation root... 