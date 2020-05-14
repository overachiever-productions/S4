

# PENSIEVE only at this point. 

But, need to provide info in here for troubleshooting common problems with: 
- backups
- restores 
- SQL Server Agent Alerts (i.e., what to do, how to find out what they mean, and ... how to integrate FILTERS)
- HA/Synchronization troubleshooting details.


<div class="stub">

[S4-147](https://overachieverllc.atlassian.net/browse/S4-147)

```
    So, I should list some common problems/errors for all of my ‘main’ code-blocks and such. 
    
    But, for dbo.restore_databases there’s a fairly common problem that I always run into and might want to look at somehow addressing as part of the ‘setup’ instructions for creating restore tests. 
    
    The specific scenario looks like this: 
    
    backup jobs are already set up and working. 
    
    ‘nightly' restore tests are set up to run at, say, 8PM (and will end up taking 20+ minutes - for example). 
    
    at/around 8:10 or whatever the first time (or some subsequent time) that the restore tests are running, the t-log backups run and see a database with the name of <proddatabase>_test (or whatever)… and… creates a new folder for the backups, and creates a t-log backup (assuming it’s in time/etc.) … with a folder name of <proddatabase>_test… 
    
    the NEXT night, when restore tests run… instead of just running a test of <proddatabase> and restoring the FULL + T-LOGs for that db … dbo.restore_databases also finds <proddatabase>_test and tries to run a restore of that … 
    
    Only, there’s NO FULL backup … at which point, we throw an error. 
    
    This is going to be failry confusing/obtuse to end-users. 
    
    To the point where I need to recommend an @ExcludedDatabases marker of N'%_test' to people during the setup… 
    
    AND it MIGHT also ALMOST make sense to create a [RESTORE_TESTED] exclusion … which is a ‘hard-coded’ type of exclusion that says… “exclude backups of any database names found in dbo.restore_test over the last N days” as well - so that we don’t do backups of any of these dbs… 

```

</div>


<div class="stub">
    Details about S4 HA/Synchronization Conventions and troubleshooting/etc. 
    (this MIGHT make more sense to put into CONVENTIONS in fact... as in, I'm just DROPPING it into a place at this second... so that it doesn't get lost and has a 'placeholder' somewhere.)

    [S4-179](https://overachieverllc.atlassian.net/browse/S4-179)
</div>

