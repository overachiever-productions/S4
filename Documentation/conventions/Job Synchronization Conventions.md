# Job Synchronization Conventions and Management
[Intro blurb]

## Table of Contents



## NOTICE
- [sync checks are exactly what they say - checks. they don't modify anything. ]

### Context and Background
[To ensure optimal synchronization of job details (especially during/after failover operations), S4 synchronization functionality uses SQL Server Agent Categories along with S4-defined job scopes... etc.]

### Job Scopes
S4 Job Synchronization Scopes for SQL Server Agent Jobs are as follows: 
- **System Scope.** Jobs which execute against System (master, msdb, or model) databases - or which are 'global'/scoped at doing something per EVERY (active/accessible) database.
- **Backup Scope.** Arguably, Backups operate at a 'System' scope given. However, given how critical backups are to overall business continuity - and due a couple of additional concerns or implementation details, S4 assigns Backup jobs to a specially defined Backup Scope.
- **Synchronization Scope.**  Synchronization Scope encompasses all jobs that should be 'synchronized' from one server to another - i.e., that should be configured so that if a database or availability group fails over, the batch-jobs that need to be processed against this job at regular, scheduled, intervals should 'follow' database movement in that the jobs will now become active on the NEW primary server, and disabled on the new primary server.
- **SSIS Scope.** Includes SQL Server Maintenance Plan Jobs and SSIS Packages. These jobs CAN (and in most cases SHOULD) be treated exactly the same as jobs in **Synchronization Scope**, but - in some scenarios will reqiure additional considerations AND management changes.
- **Ignored Scope.** Jobs that don't need to be synchronized (and which don't fit into any of the other scopes outlined above) fall into Ignored Scope (e.g., assume you've got a server with 3 mirrored/synchronized priority databases and you've got a less important database that, for whatever reason is not Mirrored or part of an AG - then any jobs that execute against or for this database (or databases like it) would be in **Ignored Scope**.

### SQL Server Agent Categories
[what they are... ]
[info on how to create/manage them... (i.e., 2x screenshots)]
[need to create the specialized 'disabled' category as a part of job management.]

## Implementation and Operations
The following information outlines how to configure and manage SQL Server Agent Jobs within specific S4 Job Scopes. 

- **System Scope Jobs.** These jobs should be set to ENABLED on all Servers. Otherwise, if the logic in these jobs is trying to run maintenance or other tasks against USER database, the logic in those jobs needs to be configured to allow for (and gracefully - i.e., no errors) SKIP over any databases that are not accessible because they're currently in a RESTORING state. [See dbo.is_primary_database for more info on how to easily configure jobs with logic to determine if a target DB should be processed or ignored.]

- **Backup Scope Jobs.** When using S4 Backups (i.e., dbo.backup_databases), these jobs should be ENABLED on all Servers. However, the @AddServerNameToSystemBackupPath parameter should be enabled for backups of System databases when using S4 backups and the @AllowNonAccessibleSecondaries parameter should be enabled when processing backups against any User databases. [See LINK_TO_dbo.backup_databases for more info.]

- **Synchronization Scope Jobs.** Jobs in the Synchronization Scope should be Enabled on the Primary server (for each database in question) and set to Disabled on non-primary servers. Likewise, the SQL Server Agent Job Category for each job in Synchronization Scope needs to be set to the name of the database (or Availability Group) against which the database in question needs to execute. Otherwise, if the category is NOT set to match the name of a Mirrored/AG'd Database or an Availability Group, this job will be treated as if it were in **Ignored Scope**.

- **SSIS / Maintenance Plan Scope Jobs.** [Two Options - either configur them as Synchronization Scope Jobs (i.e, if they only interact with a single database), or ... you'll need to modify the SSIS packages themselves to include dbo.is_primary checks to ensure they're not attempting to connect to non-active databases.] [when treating as Sync scope jobs, should be enabled on primary and disabled on secondary. when using dbo.is_primary checks, should be enabled on all servers.]

- **Ignored Scope Jobs.** SQL Server Agent Jobs in the Ignored Scope can be enabled or disabled (per server) as needed - because they're not tracked/monitored (i.e. they're ignored). However, just be sure that jobs in this scope are NOT assigned to any special S4 job categories (e.g., 'Disabled') or to the name of an AG or a mirrored/synchronized database (otherwise, synchronization checks will report errors against these jobs if they're not synchronized and/or enabled/disabled as expected).

## Instructions and Examples
Examples below outline key concepts and tasks associated with managing SQL Server Agent Jobs for SQL Servers hosting Mirrored Databases and/or Databases in AlwaysOn High Availability Groups. 

***NOTE:** For all jobs except those in the Ignored Jobs Scope, you'll need to manually SYNCHRONIZE ownership, meta-data, job steps, schedules, and other details against each server participating in your HA configuration. (i.e., if you add or modify a job one server, you'll need to make sure the exact same job and/or changes to an existing job are delivered to other HA servers as well - otherwise, you'll get alerts when job-synchronization checks are executed.)*

### Synchronizing a Single Job
If you make minor (and, especially, significant) changes to an existing job - OR create a brand new job - you COULD manually connect to your Secondary server and make those same changes via the GUI. In some cases this is a quick and easy enough solution. 

However, if there are a lot of changes - or you want to conserve on mouse clicks, the following approach can be much easier to use for synchronization purposes. 
- Right-Click on the 'source' job (i.e., the one you've just created or manually modified), and select the Script Job as > CREATE To > menu option and either dump the job's creation script to a script (and then copy it) or dump it directly into your clipboard. 

[screenshot]


- Connect to the Secondary Server.
- If you've just created a new job, skip to the next step. Otherwise, if you've just modified a job, locate the non-modified version of the Job you just modified (on the primary), right click on it and select the Delete option to remove the job from the secondary server. 
- Create a new Query Window/connection into the secondary, paste in the command to create the job you copied from the primary, and execute (press F5). 
- Enable/Disable this job on the Secondary according to which scope it is in (i.e. see Scope Implementation details above). 

The job is now synchronized.

### Synchronizing Multiple Jobs
Sometimes, for whatever reason, you may want to 'quick synchronize' multiple jobs (i.e., assume you made minor changes to 3 or 4 different jobs and don't want to manually make the same changes on the secondary). To do this, it's possible to both script and drop multiple SQL Server Agents from within SSMS at the same time:
- In SQL Server Management Studio, with the SQL Server Agent > Jobs node selected, Press F7 or use the View > Object Explorer Details menu option to pull up the Object Explorer Details Window. 
- In this window, you can multi-select Jobs by using CTRL + click to add/remove jobs from selection and/or using SHIFT+ click to select entire ranges of jobs. 
- Once you've selected the jobs you'd like to script (or delete), you can then 'mass' execute the operation desired by simply right-clicking and selecting the menu option you'd like. 

[screenshot]

- With this approach, you can now script multiple jobs, enable/disable multiple jobs, or delete multiple jobs - with less effort. 

### Create or Modify a System Scoped Job
Let's assume you need to change the timing on a System Scoped Job. To do this, you would need to do the following: 
- Connect to the Primary and change the job as desired. 
- Then either script this job and drop + paste/create this job on the Secondary using the 'Synchronizing a Single Job' instructions above OR, you can make the same changes to the job on the Secondary manually. 

Otherwise, there's nothing else to change. But, if you don't make this job the same on both servers, you'll get an alert notifying you that the jobs are different from one server to another. 

[NOTE to self... with the new 'scopes' approach I'm taking here... i should almost need to put jobs in a 'Server' category - or in server categories like 'Server - Maintenance', 'Server', 'Server - blah', etc.. OTHERWISE, there's no real diff between SERVER scope and IGNORED scope - in terms of implementation and... i think that putting server-scoped jobs into specific categories WOULD make sense to indicate that these SHOULD be the same from server to server - but don't need all the complexity of ... failover stuff and enabled/disabled logic/etc. ]

### Special Considerations for S4 Backups (i.e., Backup Scoped Jobs)
- just modify and tweak as needed. 
- they don't need any real concerns other than the following switches should be used in most cases: 
@allowNonWhateverSecondaries = 1
@includeServerNameInSystemWhatevers = 1 for system backups.. 
etc... 

### Create a new Synchronization Scope Job
Let's assume you have a database called Widgets and, for whatever reason, you need to run a SQL Server Agent job against this database every hour (i.e., a Batch Job) - maybe it's to generate a .csv and email it, or maybe it's to truncate a table, or a work-around/fix for some bug - whatever. The idea is that you'll want this job to a) have the exact same definition on both servers and, b) only run on the primary servers when executing. 

To address this need, do the following: 
- Make sure you have a SQL Server Agent Category called 'Widgets' - i.e., a category name that's an exact match for the name of your database. 
- Create the SQL Server Agent Job as you normally would. Schedule it and so on - just as you normally would. 
- Before you finish creating this new job, make sure to assign it to the 'Widgets' category. 

[screenshot]

- Once the job is created, make sure to script it, and then create it on the secondary. 

### Disable a Synchronization Scope Jobs
Continuing on from the example above, let's say that - for whatever reason, you need to suspend - or disable - execution of your 'Widgets' job for a week or so. To avoid raising an alert, here's what you'd need to do: 

- BEFORE you enable/disable the job on the Primary (it's already disabled on the secondary), make sure you have a 'Disabled' category defined/created via the SQL Server Agent Category manager. 
- Switch this job to the 'Disabled' category (you can drop a note in about which category it should be in when not disabled and/or why it's being disabled and for roughly how long/etc.). 
- Disable the job. 
- Connect to the secondary, and put the job in the 'Disabled' category + apply (the exact copy) of any notes you may have added to this job. (Or, you can script the job on the primary and then drop+create on the secondary). 

From this point on, S4 logic will alert you if/when a job that should be disabled is 'enabled' on any monitored server AND, if there's a failover, this job will NOT switch to 'ENABLED' on the secondary (as it otherwise would if the job were still in the 'Widgets' category). 

To re-enable this job later on, simply 'reverse' the order of operations above - put the job (on the primary) back into the Widgets category, cleanup/modify comments if/as needed, and then enable the job on the primary. Then, on the secondary, leave the job Disabled, clean up comments if/as needed, and make sure it's back in the 'Widgets' category.

### Respond to an Alert about Job Synchronization Problems
The purpose of Job Synchronization alerts is to give admins a heads-up if/when job details (schedules, enabled state, step details, schedules, and so on) are changed on one server - but not the other. And, over time, this'll happen a few times in most environments - you or someone else will 'zip in', make a few quick changes to a job (or create a new job), test it, then 'zip out' - and go tackle other things. Without remembering to synchronize whatever changes were just made from the primary to the secondary (or vice versa). 

To address alerts sent by job synchronization checkup jobs: 
- In many cases, once the alert arrives - it'll be obvious (especially if you were the person who made the job changes) what's up - because an overview of the problem is provided in the alert email itself (i.e., it lists which jobs are out of synchronization (i.e., are different) and which jobs exist on only a single server. 
- In 'simple' cases where you just want the job synchronization issues to 'go away', you should be able to simply 'script' from the source server and drop/recreate on the secondary (or, in cases where a job was explicitly deleted, just delete it on the secondayr/etc.) using the instructions listed above for managing synchronization details. 
- If, on the other hand, you'd like to know exactly what has changed or is different with a specific job, you can use dbo.compare_jobs to provide lists of which jobs are different from one server to the next AND to drill down into a specific job (by setting its name as the @TargetJobName parameter) to get high-level details of what is different between jobs (rather than scrutinizing settings visually in SSMS from one job to the next).

[TODO: add a link to dbo.compare_jobs docs... ]


## Rationale
[TODO: may make sense to put more of the 'rationale' info in the parent document - where key details about how S4 HA works... ]
[TODO: that said... i just need to provide a succinct example of how bad it would be to have a 'key'/critical job that was REQUIRED to run for a while (i.e., say it's a 'hack' that works around a bug/issue or something) ... only to have a failover occur... at which point the job WASN'T synchronized on the secondary... and doesn't either exist or have the same logic or schedules/etc.]... then show what happens IF we temporarily DISABLE the job and don't set it to 'disabled' and what would happen during a failover. that's really all the 'rationale'/explanation for this feature that is needed. 
