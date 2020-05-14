[README](?encodedPath=README.md) > [Best-Practices]() > BACKUPS


## Table of Contents 
- [Best-Practices for SQL Server Backups](#best-practices-for-sql-server-backups)
    - [Concerns about Backups and Resource Usage](#)
    - [FULL Backups - Recommendations and Frequency](#)
    - [The Primary Reason to use DIFF Backups](#)
    - [Recommendations for Transaction Log Backups](#)
    - [Recommendations for Backup Storage/Locations](#)
    - [Recommendations for Organizing Backups](#)
    - [Recommendations for Backup Retention Times](#)
    - [The NEED for Off-Site Backups](#)
- [Automating Backups with S4](#)
    - [Creating Jobs](#)
    - [Addressing Customized Backup Requirements](#)
    - [Testing Execution Details](#)
    - [Recommendations for Creating Automated Backup Jobs](#)
    - [Scheduling Jobs](#)
    - [Notifications](#)
    - [Step-by-Step - Extended Example](#)
    - [Troubleshooting Common Backup Problems](#)
    

## Best-Practices for SQL Server Backups
For background and insights into how SQL Server Backups work, the following, **free**, videos can be very helpful in bringing you up to speed: 

- [SQL Server Backups Demystified.](http://www.sqlservervideos.com/video/backups-demystified/) 
- [SQL Server Logging Essentials.](http://www.sqlservervideos.com/video/logging-essentials/)
- [Understanding Backup Options.](http://www.sqlservervideos.com/video/backup-options/)
- [SQL Server Backup Best Practices.](http://www.sqlservervideos.com/video/sqlbackup-best-practices/)

Otherwise, some highly-simplified best-practices for automating SQL Server backups are as follows:

### Concerns about 'Resource Overhead' Associated with Backups 
Generally speaking, backups do NOT consume as many resources as most people initially fear - so they shouldn't be 'feared' or 'used sparingly'. (Granted, FULL backups against larger databases CAN put some stress/strain on the IO subsystem - so they should be taken off-hours or 'at night' as much as possible.) Likewise, DIFF backups (which can be taken 'during the day' and at periods of high-load (to decrease how much time is required to restore databases in a disater) CAN consume some resources during the day when taken, but this needs typically slight negative needs to be contrasted with the positive/win of being able to restore databases more quickly in the case of certain types of disaster. Otherwise, when executed regularly (i.e., every 5 to 10 minutes), Transaction Log backups typically don't consume more resources than some 'moderate queries' that could be running on your systems and NEED to be executed regularly to ensure you have options and capabilities to recover from disasters. In short, humans are wired for scarcity; forget that and be 'eager' with your backups, then watch for any perf issues and address/react accordingly (instead of fearing that backups might cause problems - as it is guaranteed that a LACK of proper/timely backups will cause WAY more problems when an emergency occurs.)

### FULL Backups - Recommendations and Frequency of Backups
All databases, including dev/testing/stating databases, should typically see a FULL backup every day. The exception would be LARGE databases (i.e., databases typically above/beyond 1TB in size - where it might make more sense to execute FULL backups on weekends, and execute DIFF backups nightly), or dev/test databases in SIMPLE recovery mode that don't see much activity and could 'lose a week' (or multiple days/whatever) of backups without causing ANY problems. As such, you should typically create a nightly job that executes FULL backups of all [SYSTEM] databases (see Example B) and another, distinct, job that executes FULL backups of [USER] databases (see Example C below). Then, if you've got some (user) databases you're SURE you don't care about AND that you can recreate if needed, then you can exclude these using @DatabasesToExclude.

### A Primary Role for DIFF Backups
Once FULL backups of all (key/important and even important-ish) databases have been addressed (i.e., you've created jobs for them), you may want to consider setting up DIFF backups DURING THE DAY to address 'vectored' backups of larger and VERY HEAVILY used databases - as a means of decreasing recovery times in a disaster. For example, if you've got a 300GB database that sees a few thousand transactions per minute (or more), and generates MBs or 10s of MBs of (compressed) T-LOG backups every 5 or 10 minutes when T-Log backups are run, then if you run into a disaster at, say, 3PM, you're going to have to restore a FULL Backup for this database plus a LOT of transactional activity - which CAN take a large amount of time. Therefore, if you've got specific RTOs in place, one means of 'boosting' recovery times is to 'interject' DIFF backups at key periods of the day. So, for example, if you took a FULL backup at 2AM, and DIFF backups at 8AM, Noon, and 4PM, then ran into a disaster at 3PM, you'd restore the 2AM FULL + the Noon DIFF (which would let you buypass 10 hours of T-Log backups) to help speed up execution. As such, if something like this makes sense in your environment, make sure to review the examples (below), and then pay special attention to Example E - which showcases how to specify that specific databases should be targeted for DIFF backups. 

### Recommendations for Transaction Log Backups
Otherwise, in terms of Transaction Log backups, these SHOULD be executed every 10 minutes at least - and as frequently as every 3 minutes (on very heavily used systems).On some systems, you may want or need T-Log backups running 24 hours/day (i.e., transactional coverage all the time). On other (less busy systems), you might want to only run Transaction Log backups between, say, 4AM (when early users start using the system) until around 10PM when you're confident the last person in the office will always, 100%, be gone. Again, though, T-Log backups don't consume many resources - so, when in doubt: just run T-Log backups (they don't hurt anything). **Likewise, do NOT worry about T-Log backups 'overlapping' or colliding with your FULL / DIFF backups; if they're set to run at the same time, SQL Server is smart and won't allow anything to break (or throw errors) NOR will it allow for any data loss or problems.** Otherwise, as defined elsewhere, when a @BackupType of 'LOG' is specified, dbo.backup_databases will backup the transaction logs of ALL (user) databases not set to SIMPLE recovery mode. As such, if you are CONFIDENT that you do NOT want transaction log backups of specific databases (dev, test, or 'read-only' databases that never change OR where you 100% do NOT care about the loss of transactional data), then you should 'flip' those databases to SIMPLE recovery so that they're not having their T-Logs backed up.

### Recommendations for Backup Storage Locations
In terms of storage or WHERE you put your backups, there are a couple of rules of thumb. **First, it is NEVER good enough to keep your ONLY backups on the same server (i.e., disks) as your data. Doing so means that a crash or failure of your disks or system will take down your data and your backups.** As such, you should ALWAYS make sure to have off-box copies or backups of your databases (which is why the @CopyToBackupDirectory and @CopyToRetention parameters exist). Arguably, you can and even SHOULD (in many - but not all) then ALSO have copies of your backups on-box (i.e., in addition to off-box copies). And the reason for this is that off-box backups are for hardware disasters - situations where a server catches fire or something horrible happens to your IO subsystem - whereas on-box backups are very HELPFUL (but not 100% required) for data-corruption issues (i.e., problems where you run into phsyical corruption or logical corruption) where your hardware is FINE - because on-box backups mean that you can start up restore operations immediately and from local disk (which is usually - but not always) faster than disk stored 'off box' and somewhere on the network. Again, though, the LOGICAL priority is to keep off-box backups first (usually with a longer retention rate as off-box backup locations typically tend to have greater storage capacity) and then to keep on-box 'copy' backups locally as a 'plus' or 'bonus' whenever possible OR whenever required by SLAs (i.e., RTOs). Note, however, that while this is the LOGICAL desired outcome, it's typically a better practice (for speed and resiliency purposes) to write/create backups locally (on-box) and then copy them off-box (i.e., to a network location) after they've been created locally. As such, many of the examples in this documentation point or allude to having backups on-box first (the @BackupDirectory) and the 'copy' location second (i.e., @CopyToBackupDirectory). 

### Organizing Backups
Another best practice with backups, is how to organize or store them. Arguably, you could simply create a single folder and drop all backups (of all types and for all databases) into this folder as a 'pig pile' - and SQL Server would have no issues with being able to restore backups of your databases (if you were to use the GUI). However, humans would likely have a bit of a hard time 'sorting' through all of these backups as things would be a mess. An optimal approach is to, instead, create a sub-folder for each database, where you will then store all FULL, DIFF, and T-LOG backups for each database so that all backups for a given database are in a single folder. With this approach, it's very easy to quickly 'sort' backups by time-stamp to get a quick view of what backups are available and roughly how long they're being retained. This is a VERY critical benefit in situations where you can't or do NOT want to use the SSMS GUI to restore backups - or in situations where you're restoring backups after a TRUE disaster (where the backup histories kept in the msdb are lost - or where you're on brand new hardware). Furthermore, the logic in S4 Restore scripts is designed to be 'pointed' at a folder or path (for a given database name) and will then 'traverse' all files in the folder to restore the most recent FULL backup, then restore the most recent DIFF backup (since the FULL) if one exists, and conclude by restoring all T-LOG backups since the last FULL or DIFF (i.e., following the backup chain) to complete restore a database up until the point of the last T-LOG backup (or to generate a list of commands that would be used - via the @PrintOnly = 1 option - so that you can use this set of scripts to easily create a point-in-time recovery script). Accordingly, dbo.backup_databases takes the approach of assuming that the paths specified by @BackupDirectory and/or @CopyToBackupDirectory are 'root' locations and will **ALWAYS** create child directories (if not present) for each database being backed up. (NOTE that if you're in the situation where you don't have enough disk space for ALL of your backups to exist on the same disk or network share, you can create 2 or more backup disks/locations (e.g., you could have D:\SQLBackups and N:\SQLBackups (or 2x UNC locations, etc.)) and then assign each database to a specific disk/location as needed - to 'spread' your backups out over different locations. If you do this, you MIGHT want to create 2x different jobs per each backup type (i.e., 2x jobs for FULL backups and 2x jobs for T-Log Backups) - each with its own corresponding job name (e.g. "Primary Databases.FULL Backups" and "Secondary Databases.FULL Backups"); or you might simply have a SINGLE job per backup type (UserDatabases.FULL Backups and UserDatabases.LOG Backups) and for each job either have 2x job-steps (one per each path/location) or have a single job step that first backups up a list of databases to the D:\ drive, and then a separate/distinct execution of dbo.backup_databases below the first execution (i.e., 2x calls to dbo.backup_databases in the same job step) that then backs up a differen set of databases to the N:\ drive. 

### Backup Retention Times
In terms of retention times, there are two key considerations. First: backups are not the same thing as archives; archives are for legal/forensic and other purposes - whereas backups are for disaster recovery. Technically, you can create 'archives' via SQL Server backups without any issues (and dbo.backup_databases is perfectly suited to this use) - but if you're going to use dbo.backup_databases for 'archive' backups, make sure to create a new / distinct job with an explicit name (e.g., "Monthly Archive Backups"), give it a dedicated schedule - instead of trying to get your existing, nightly (for example) job that tackles FULL backups of your user databases to somehow do 'dual duty'. However, be aware that dbo.backup_databases does NOT create (or allow for) COPY_ONLY backups - so IF YOU ARE USING DIFF backups against the databases being archived, you will want to make sure that IF you are creating archive backups, that you create those well before normal NIGHTLY backups so that when your normal, nightly, backups execute you're not breaking your backup chain. Otherwise, another option for archival backups is simply to have an automated process simply 'zip out' to your backup locations at a regularly scheduled point and 'grab' and COPY an existing FULL backup to a safe location. Otherwise, the second consideration in terms of retention is that, generally, the more backups you can keep the better (to a point - i.e., usually anything after 2 - 4 days isn't ever going to be used - because if you're doing things correctly (i.e., regular DBCC/Consistency checks and routinely (daily) verifying your backups by RESTORING them, you should never need much more that 1 - 2 days' worth of backups to recover from any disaster). Or, in other words, any time you can keep roughly 1-2 days of backups 'on-box', that is typically great/ideal as it will let you recovery from corruption problems should the occur - in the fastest way possible; likewise, if you can keep 2-3 days of backups off-box, that'll protect against hardware and other major system-related disasters. If you're NOT able to keep at least 2 days of backups somewhere, it's time to talk to management and get more space.

### The Need for OFF-SITE Backups
Finally, S4 Backups are ONLY capable of creating and managing SQL Server Backups. And, while dbo.backup_databases is designed and optimized for creating off-box backups, off-box backups (alone), aren't enough of a contingency plan for most companies - because while they will protect against situations where youl 100% lose your SQL Server (where the backups were made), they won't protect against the loss of your entire data-center or some types of key infrastructure (the SAN, etc.). Consequently, in addition to ensuring that you have off-box backups, you will want to make sure that you are regularly copying your backups off-site. (Products like [CloudBerry Server Backup](https://www.cloudberrylab.com/backup/windows-server.aspx) are cheap and make it very easy and affordable to copy backups off-site every 5 minutes or so with very little effort. Arguably, however, you'll typically WANT to run any third party (off site) backups OFF of your off-box location rather than on/from your SQL Server - to decrease disk, CPU, and network overhead. However, if you ONLY have a single SQL Server, go ahead and run backups (i.e., off-site backups) from your SQL Server (and get a more powerful server if needed) as it's better to have off-site backups.)

[Return to Table of Contents](#table-of-contents)
## Automating SQL Server Backups with S4 and the SQL Server Agent

As S4 Backups were designed for automation (i.e., regularly scheduled backups), the following section provides some high-level guidance and 'comprehensive' examples on how to schedule jobs for all different types of databases. 

### Creating Jobs
For all Editions of SQL Server, the process for defining and creating jobs uses the same workflow. However, SQL Server Express Editions do NOT have a SQL Server Agent and cannot, therefore, use SQL Server Agent Jobs (i.e., schedule tasks with built-in capabilities for alerting/etc) for execution and will need to use the Windows Task Scheduler (or a 3rd party scheduler) to kick of .bat or .ps1 commands instead. 

Otherwise, the basic order of operations (or workflow) for creating scheduled backups is as follows:
- Read through the guidelines below BEFORE actually creating and implementing any actual job steps.
- Start with any SLAs (RPOs or RTOs) you may have governing how much data-loss and down-time for key/critical databases can be tolerated. 
- Evaluate all other non-critical databases for backup needs and put any non-important databases into SIMPLE recovery mode and/or remove from your production servers as much as possible. 
- Review backup retention requirements for all databases. (Typically, the best option is to try and keep all types of dbs (important/critical and then non-import/dev/testing) for roughly the same duration. However, if you are constrained for disk space, you may have to pick 'favorite' or more important databases which will have LONGER backup retention times AT THE EXPENSE of shorter retention times for LESS important databases.
- Create different logical 'groupings' of your databases as needed. Ideally you want as FEW groupings or types of databases as possible (i.e., System and User databases is a common convention). However, if some of your databases are drastically more important/critical than others, you might want to break up user databases into two groups: "Critical" and "Normal", and drop databases into these groups as needed. 
- Start by setting up a job to execute FULL backups of your System databases. Typically, retention times of 2 - 3 days for system databases are more than fine. 
- Then set up a job for FULL backups of any 'super' critical  - with corresponding retention rates defined as needed. Make sure you're copying these backups off-box (either via the @CopyToBackupDirectory or by a regularly-running 3rd party solution/etc.)
- If one of your 'super' critical databases is under very heavy load during periods of the day and you have TESTED and found out that you cannot restore from a FULL + all T-LOGs (since FULL) and recover within RTOs, then you'll need to create DIFF backups for this 'group' of databases at key intervals (i.e., every 4 hours from 10AM until 6PM - or whatever makes sense).
- Once you've addressed FULL + DIFF backups for any critical or super important databases, you can then address FULL backups for any less important (i.e., medium importance) and lower-importance databases as needed. 
- After you've figured out what your needs for 'critical', normal, and low-importance databases are (in terms of FULL and/or DIFF backups), try to CONSOLIDATE needs as much as you can. For example, if you have 5 databases, 2 of which are dev/test databases that aren't that important, 2 of which are production databases, and one of which is a mission-critical (used like crazy) database of utmost importance, you can (in most cases) consolidate the FULL + DIFF backups for ALL 5 of these databases into just two jobs: a job that tackles FULL backups of ALL user databases at, say, 4AM every morning (which will execute full backups of your 2 dev/testing databases and of your 3x production databases), and then a second job (with a name like "<BigDbName>.DIFF Backups" - or "HighVolume.DIFF Backups" if you've got 2 or more high-volume DBs that require DIFF backups) that executes DIFF backups every 3 hours starting at 10AM and running until 5PM - or whatever makes sense. 
- Once you have FULL + DIFF backups tackled, you should typically ONLY EVER need to create a SINGLE job to tackle Transaction Log backups - across all (non-SIMPLE Recovery Mode) databases. So, in the example above, if you've got 5x databases (2 that are dev/test, 2 that are important, and 1 that is critical), after you had created 2 jobs (one for FULL, one for DIFFs), you'd then create a single job for T-Log backups (i.e., "User Databases.LOG Backups") that was set to run every 3 - 10 minutes (depending up on RPOs) which would be configured to execute LOG backups - meaning that when executed, this job would 'skip-past' your 2x dev/testing databases (because they're in SIMPLE recovery mode), then backup the T-Logs for your 3x production databases.

In short, make sure to plan things out a bit before you start creating jobs or executing backups. A little planning and preparation will to a long way - and, don't expect to get things perfect on your first try; you may need to monitor things for a few days (see how much disk you end up using for backups/etc.) and then 'course-correct' or even potentially 'blow everything away and start over'. Or, in other words, S4 backups weren't designed to make backups a 'brain-dead' operation that wouldn't require any planning or monitoring on your part - but they WERE created to make it very easy for you to make changes or 'tear-down and re-create' backup routines and schedules without much effort involved in the actual CODING and configuration needed to get things 'just right'.

### Addressing Customized Backup Requirements
On very simple systems you can quite literally create two jobs and be done:
- One that executes a FULL backup of all databases nightly. 
- One that executes LOG backups of all (non-SIMPLE recovery) databases every x minutes. 

However, even to do something like thise, you would run into the problem that while dbo.backup_databases will let you specify [USER] as a way to backup all user databases and [SYSTEM] to backup all system databases, there is NOT an [ALL] token that targets all databases (this is by design). As such, for your first 'job' listed above, you'd have 3x actual options for how you wanted to tackle the need for processing FULL backups of all databases. 

1. You could actually create 2x jobs instead of just a single Job - e.g., "System Databases.FULL Backups" and "User Databases.FULL Backups". For jobs processing System Backups, this is actually the best/recommended practice (it makes it very clear in looking at the Jobs listed in your SQL Server Agent that you're executing FULL backups of System databases (and user DBs as well). (For situations where you need to execute different options for user databases - one of the other two options below typically makes more sense).
2. You 'stick' with using a single SQL Server Agent Job, but spin up 2x different Job Steps within the Job - i.e., a Job_Step called "System Databases" and an additional Job-Step called "User Databases". The BENEFIT of this approach is that you end up with just a single job (less 'clutter') and your backups will not only execute under the same schedule - but they'll run serially (i.e., system backups will take as long as needed, and - without skipping a beat - user database backups will then kick off) - which is great if you've have smaller maintenance windows. NEGATIVES of this approach are that you MUST take care to make sure that if the first Job-Step fails, the job itself does NOT quit (reporting failure), but goes to the next Job-Step (so that a 'simple' failure to backup, say, the model database (for some odd reason), doesn't prevent you from at least TRYING to backup one of your critical or even important databases.
3. You could 'stick' with both a single job AND a single-job step - by simply 'dropping' 2x (or more) calls to dbo.backup_databases within the same job step. While this works, it comes with 2 negatives: a) while dbo.backup_databases is designed to run without throwing exceptions when an error occurs during backups, IF a major problem happens in your first execution, the second call to dbo.backup_databases may not fire and b) it's easy for things to get a bit cluttered and 'confusing' fast. As such, option 2 (different Job Steps within the same job) is usually the best option for addressing 'customizations' or special needs within backups for user databases. 


Otherwise, key reasons why you might want to address customized backup requirements would include things like: 
- Situations where you might have different backup locations on the same server (i.e., smaller volumes/disks/folders that can't handle ALL of your backups to the same, single, location). In situations like this, you're better of creating a single job for all of your FULL backups for user databases (e.g., "User Databases.FULL Backups") and then doing the same for LOG backups (e.g., "User Databases.LOG Backups") and then for each job, creating 2 or more job steps - to handle backups for databases being written to the N drive (for example), and then a follow-up Job Step for databases backed up to the S drive, and so on. 
- Situations where you have different retention times for different databases - either for DR purposes or because of disk space constraints. 

But, in each case where you must 'customize' or specialize specific settings or details, you typically want to try and 'consolidate' as many separate yet RELATED operations into as few jobs as possible - as doing so makes it much easier to find a job when problems happen (i.e., if you have 6x different "FULL backup" jobs for 6 or more databases, it'll take you a bit longer to find and troubleshoot WHICH one of those jobs had a problem if a problem happens AND you'll have WAY more schedules to juggle). Likewise, you typically want as FEW schedules to manage as possible - both because it makes it easier to troubleshoot problems AND because then you're not playing 'swiss cheese meets complex maintenance requirements' and trying to 'plug' various tasks into a large number of time-slots and the likes - and then constantly having to adjust and 'shuffle' schedules around when dbs start getting larger and backups take increasingly more and more time (causing 'collisions' with other jobs). 

### Testing Execution Details 
Once you've figured out what you want to set up in terms of jobs/schedules and the likes, you should TEST the specific configuraitons you're looking at pulling off - to make sure everything will work as expected. 

As a best practice, start with creating a call to dbo.backup_databases that will tackle backups of your System databases. Specifically, copy + paste the code from Example A into SSMS, point the @BackupDirectory at a viable path on your server, and then append @PrintOnly = 1 to the end of the list of parameters and execute. Then review the commands generated and you can even copy/paste one of the BACKUP commands if you'd like and try to execute it (it'll likely fail on a server where dbo.backup_databases hasn't run before - because it'll be trying to write to a subfolder that hasn't been created yet). Then, once you've reviewed the commands being generated, remove the @PrintOnly = 1 parameter (remove it instead of setting it 0), and execute. 

At this point, if you haven't configured something correctly - or are missing dependencies, dbo.backup_databases will throw an ERROR and will not continue operations. 

Otherwise, if everything looks like it has been configured correctly, execution will complete and if there are errors, you'll see that an email message has been queued - and you can query admindb.dbo.backup_log for information (check the ErrorDetails column - or just wait for an email).

If backup execution completed as follows, then make sure to specify an @CopyToBackupDirectory and a corresponding value for @CopyToRetention - and any other parameters as you'll need for your production backups, and then create a new SQL Server Agent Job to execute the commands as you have configured them. 

Then repeat the process for all of the other backup operations that you'll need - where (for each job or set of differences you define) you can always 'test' or visualize outcomes by setting @PrintOnly = 1, and then REMOVING this statement before copy/pasting details into a SQL Server Agent Job. 

### Recommendations for Creating Automated Backup Jobs
The following recommendations will help make it easier to manage SQL Server Agent Jobs that have been created for implementing automated backups. 

#### Job Names
Job names should obviously make it easy to spot what kind of backups are being handled. Examples for different Job names include the following:
- SystemDatabases.FULL Backups
- UserDatabases.FULL Backups
- UserDatabases.DIFF Backups
- UserDatabases.LOG Backups

Other generalizations/abstractions, like "PriorityDatabases.FULL Backups" equally make sense - the key recommendation is simply to have as few distinct jobs as truly needed, and to make sure the names of each job clearly indicates the job's purpose and what is being done within the job. (Then, of course, make sure that only commands relating to the Job's name are deployed/executed within a specific job - i.e., don't 'piggy back' some DIFF backups into a job whose name denotes FULL backups (create a distinct job instead).)

#### Job Categories
Job Categories are not important to job outcome or execution. If you'd like to create specialized Job Category Names for your backup jobs (i.e., like "Backups"), you can do so by right-clicking on the SQL Server Agent > Jobs node, and selecting "Manage Job Categories" - where you can then add (or remove) Job Category names as desired. 

![](https://assets.overachiever.net/s4/images/backups_jobcategories.gif)

#### Job Ownership
When creating jobs, it is a best practice to always make sure the job owner is 'sa' - rather than MACHINE\username or DOMAIN\username - to help provide better continuity of execution through machine/domain rename operations, and other considerations. 

[SQL Server Tip: Assign Ownership of Jobs to the SysAdmin Account](http://sqlmag.com/blog/sql-server-tip-assign-ownership-jobs-sysadmin-account).


#### Job Steps
As with Job Names, job step names should be descripive as well (even if there's a bit of overlap/repetition between the job name and given job-step name in cases where a job only has a single job-step). 

Likewise, for automated backups, Job Steps should be set to execute within the **admindb** database. 

![](https://assets.overachiever.net/s4/images/backups_jobstep1.gif)


#### Jobs with Multiple Job Steps
When you need to create SQL Server Agent Jobs with multiple Job Steps, you can do so by creating a job (as normal), adding a New/First step, and then adding as many 'New' job steps as you would like. Once you're done adding job steps, however, SSMS will have set up the "On Success" and "On Failure" outcomes of each job-step as outlined in the screenshot below: 

![](https://assets.overachiever.net/s4/images/backups_jobstep_multi.gif)

To fix/address, this, you'll need to edit EACH job step, switch to the Advanced tab per each Job step, and switch the "On failure action" to "Go to the next step" from the dropdown - on all steps OTHER than the LAST step defined. 

![](https://assets.overachiever.net/s4/images/backups_jobstep_onfail.gif)

### Scheduling Jobs
When setting up Job Schedules for a job, it's usually best to keep things as simple as possible and only use a single schedule per job (though, you can definitely use more than one schedule if you're 100% confident that what you're doing makes sense (there's rarely ever a need to have multiple schedules for the same types of backups)). 

Furthermore, when scheduling jobs, you'll always want to pay attention to the 3 areas outlined in the screenshot below:
1. This is always set to recurring - by default - so you'll usually never NEED to modify this. 
2. Make sure you configure the option needed (i.e., most of the time this'll be Daily).
3. Occurs once vs Occurs every... are important options/specifications as well. 

![](https://assets.overachiever.net/s4/images/backups_schedule.gif)

### Notifications
While dbo.backup_databases is designed to raise an error/alert (via email) any time a problem is encountered during execution, its possible that a BUG within dbo.backup_databases (or with some of the parameters/inputs you may have specified) will cause the job to NOT execute as expected. As such, 

### Step-By-Step - An Extended Example
Mia has the following databases and environment: 
- 2x testing databases: test1 and test2. 
- 1x 300GB critical database: ProdA. 
- 2x 10 - 20GB important databases: db1 and db2
- Enough disk space for all of her data and log files. 
- 500GB of backup space on N:\ in N:\SQLBackups
- 100GB of backup space on S:\ in S:\Scratch\Backups
- 800GB of backup space on \\\\Backup-Server\ProdSQL\

Assume that FULL backups of test1, test2, db1, and db2 consume an AVERAGE of 15GB each - or ~60GB total space - per day. 

Likewise, assume that FULL backups of ProdA consume ~140GB each (growing by about 1GB every 2 weeks).

Then, assume that T-Log backups for db1 and db2 consume around ~5GB (for both DBs) of space each day, whereas T-Logs for ProdA consume around 20GB of space per day. 

Mia is still working with management to come up with RPOs and RTOs that everyone can agree upon, but until she hears otherwise, she's going to execute T-LOG backups every 5 minutes, doesn't need DIFF backups of ProdA, and will execute FULL backups of all databases daily. 

To do facilitate this, she does the following. 

First, she defines the following call to dbo.backup_databases - for her System Databases:

```sql
EXEC admindb.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[SYSTEM]',
    @BackupDirectory = N'S:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```

She then creates a new Job, "System Databases.FULL Backups", sets it to be owned by 'sa', copies/pastes the code above into a single job step ("FULL Backup of System Databases"), sets it to execute every night at 7PM (which captures most changes made by admins during a 'work day') and where the few SECONDS it'll take to execute System backups won't even be noticed. She also sets the Notification tab to Notify "Alerts" if the job fails (in case there's a bug in dbo.backup_databases rather than a problem that might encountered while executing backups that would be 'trapped'). 

Second, she opts to set up a single Job for FULL user database backups - but she's going to need 2x Job Steps to account for the fact that she'll have to push ProdA to the N:\ drive and keep all other DBs on the S:\ drive - to avoid problems with space. 

So, she creates a new Job, "User Databases.FULL Backups", sets the owner to SA, configures it to Notify Alerts on failure, and schedules the job to run at 2AM every day. 

Next, she configures a call to dbo.backup_databases for JUST ProdA - as follows: 

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'ProdA',
    @BackupDirectory = N'N:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '72h', 
    @CopyToRetention = '96h';
```

And then she drops that into the first/initial Job Step for her job - with a name of "Full backups of ProdA - to N:\", and then copies/pastes in the code from above. 

Then, she configures a separate call to dbo.backup_databases for all other user databases - which she does by specifying [USER] for @DatabasesToBackup and 'ProdA' for @DatabasesToExclude. She also sets different (lesser) retention times - both for local AND off-box backups to conserve space and to FAVOR backups of ProdA over the other 'less important' databases:

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'FULL', 
    @DatabasesToBackup = N'[USER]',
    @DatabasesToExclude = N'ProdA',
    @BackupDirectory = N'S:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '48h', 
    @CopyToRetention = '48h';
```

With the call to dbo.backup_databases configured, she adds a new (second) Job Step to "User Databases.FULL Backups" called "Full Backups of all other dbs to S:\" and copies/pastes the code from above. Then, since she has 2 distinct Job-steps configured, she then switches to the Advanced Properties for her first job step (Full Backups of ProdA - to N:\), and ensures that the "On success action" as well as the "On failure actions" are BOTH set to the "Go to the next step" option - so that errors occur during execution of backups for ProdA, backups for all other (user) databases will attempt to execute.

Finally, she needs to create a Job to tackle transaction log backups - which'll run every 5 minutes and backup logs for all user databases that aren't in SIMPLE recovery mode. If she were able to push these T-LOG backups to the same location (locally and off-box), she'd just need a single job-step to pull this off. However, in this example scenario, we're assuming that she needs to push T-LOG backups for ProdA to the N:\ drive and T-LOG backups of her other User databases to the S:\ drive - and then copy those backups to \\\\BackupServer\ProdSQL\ - where she'll keep copies of the ProdA database longer than those of the other databases (i.e., db1 and db2). To do this, she first creates a call to dbo.backup_databases to address the log backups for the ProdA database:

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'ProdA',
    @BackupDirectory = N'N:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '48h', 
    @CopyToRetention = '72h';
```

Then, she does the 'inverse' for her other databases - by specifying [USER] for @DatabasesToBackup and 'ProdA' for @DatabasesToExclude - and then changing paths and retention times as needed:

```sql
EXEC admindb.dbo.dbo.backup_databases
    @BackupType = N'LOG', 
    @DatabasesToBackup = N'[USER]',
    @DatabasesToExclude = N'ProdA',
    @BackupDirectory = N'S:\SQLBackups\', 
    @CopyToBackupDirectory = N'\\BackupServer\ProdSQL', 
    @BackupRetention = '24h', 
    @CopyToRetention = '48h';
```

With these tasks complete, she then creates a new job ("User Databases.LOG Backups"), sets the owner to 'sa', schedules the job to run every 5 minutes - starting a 4:00 AM and running the rest of the day (i.e., until midnight), specifies that the job should notify her upon failure, pastes in the commands above into 2 distinct Job Steps (one for ProdA, the other for the other databases), and then makes sure that Job Step 1 will always "Go to the next step" after successful or failed executions. 

At this point, she's effectively done - other than monitoring how much space the backups take over the next few days, and then periodically testing the backups (i.e., via full-blown restore operations), to make sure they're meeting her RPOs and RTOs (instead of waiting to see what kinds of coverage/outcome she gets AFTER a disaster occurs - assuming her untested backups even work at that point).

[Return to Table of Contents](#toc)

### Troubleshooting Common Backup Problems
[TODO: move to TROUBLEHSOOTING.md]

#### Backup Folder Permissions
In order for SQL Server to write backups to a specific folder (on-box or out on the network), you will need to make sure that the Service Account under which SQL Server runs has access to the folder(s) in question. 

To determine which account your SQL Server is running under, launch the SQL Server Configuration Manager, then, on the SQL Server Services tab, find the MSSQLSERVER service (or the service that corresponds to your named instance if you're not on the default SQL Server instance), then double-click on the service to review Log On information. 

![](https://assets.overachiever.net/s4/images/backups_services.gif)

Whatever username is specified in the Log On details - is the Windows account name that your SQL Server (instance) is executing under - and will be the account that will need access to any folders or locations where you might be writing backups. 

***NOTE:** If you're currently running SQL Server as NT SERVICE\MSSQLSERVER you CAN provide this specific 'user' access to any folder on your LOCAL machine, but likely won't be able to grant said account permissions on your UNC backup targets/shares. (Likewise, if you're running as any type of built-in or local service account, this account will NOT have the ability to access off-box resources at all.) In cases where you are not able to assign built-in or system-local-only accounts permissions against off-box resources, you'll need to change the account that your SQL Server is running under. On a domain, create a new Domain user (with membership in NO groups other than 'users') - and then use the SQL Server Configuration Manager to change the Log on credentials accordingly - then restart your SQL Server service for the changes to take effect. If you're in a workgroup, you'll need to create a user with the exact same username and password on your local SQL Server and any 'remote' servers it might need to access - and then you'll be able to run SQL Server as, say, DBSERVER1\sql_service (after making changes on the Log On tab in the SQL Server Configuration Manager) and you'll be able to grant local backup permissions (i.e., against - say, D:\SQLBackups) to DBSERVER1\sql_service AND assign permissions on your 'backups server' to something like BACKUPSERVER\sql_server and, as long as the username and password on BOTH machines are identical, Windows will be able to use NTLM permissions within a workgroup to control access.* 

***NOTE:** On many SQL Server 2012 and above instances of SQL Server, any folders (on-box) that you wish to have SQL Server write backups to, will also need to have the NT SERVICE\MSSQLSERVER 'built-in' account granted modify or full control permissions before backups will be able to be written.*