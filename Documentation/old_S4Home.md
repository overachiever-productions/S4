# S4 - Simple SQL Server Scripts

[purpose... simplify many common tasks and address other needed tasks etc. - all from a set of standardized interfaces and .. conventions.]

[Some benefits/reasons why... include easy access/operations to the following]:
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



## Contents 
[toc will be 'tiered or grouped' - as follows: ]

## S4 Basics
- Requirements and [Warnings/Notifications  - need SMTP info... i.e., have to setup profiles and accounts and stuff. S4 uses conventions, but you can config around those if/as needed.]
- Conventions (which will cover...  path names, @Modes, S4 'timeThingies', regions/sections (i.e., associated blocks of tooling - which can/will introduce conventions of their own if/as needed, COMMON parameters and their definitions/details (i.e., @OperatorName, @ProfileName and so on...,  etc... )
- Deployment - Installation and Updates (with a link to the folder with most recent stuff...)
- sub-note under development: xp_cmdshell and 'security' concerns/etc. 
- [Add Sections as they're 'unleashed' - including the following:]

## S4 Sections 
- S4 Audits
- S4 Backups
- S4 Configuration
- S4 Diagnostics
- S4 Extended Events (not extended event SESSIONS, but extended events (stuff around/having to do with XEs (including sessions))). 
- S4 High Availability 
- S4 Maintenance
- S4 Metrics
- S4 Migrations
- S4 Monitoring
- S4 Performance 
- S4 Restore
- S4 Tools


    