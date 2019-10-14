<div class="stub">
[NOTE TO SELF: Philosophies needs to be a big part of this doc. Specifically, the doc should have the following 'resources' in it: a) breadcrumbs/title. b) TOC (and return to main), c) overview of conventions - they're the key to getting S4 to work. d) philosophy. e) specific conventions/implemetnations of philosophy and a break-down/documetnation of each convention.]

[ANOTHER NOTE TO SELF: I've actually... got a few 'pages' of convention DOCs in the \documentation\conventions\ folder ... and I should use those for Job Sync Conventions. The others... I think I'll just want to inline them here. (MEaning that \documentation\conventions\ MIGHT make more sense to implement as \documentation\ha\ or something a bit more 'specific'). 

EITHER WAY: just make sure to integrate the conventions defined in there ... into this doc and/or the finalized/overall documentation.
]
</div>

[README](?encodedPath=README.md) > CONVENTIONS

> ### <i class="fa fa-warning"></i> WARNING:
> As of version 7.0 this content is BARELY even a viable 'draft' or outline (i.e., it's primarily a place-holder/pensieve (at best).)

### TABLE OF CONTENTS
- [Philosophy]()
- [IDIOMATIC CONVENTIONS]()
    - [SQL Server Backups and Sub-Directories Per Each Database]() 
    - Vectors. Human-readable 'timespans'/directives used for specifying retention rates, frequencies and so on - i.e., instead of @NumberOfMinutesToAdd, S4 uses @PollingFrequency = '22 minutes' to enable cleaner @ParameterNames (for 'self-documentation') and easier values that 'magic numbers' (i.e., is 111756 a set of milliseconds, seconds, hours? what? ). 
    - {DEFAULTS}. Convention over configuration - but, configuration can be changed at 2x levels - system-wide (dbo.settings) or per execution/call of an S4 module. (This allows for MUCH LESS change/modification if/when something like an email address changes/etc. or the path to backups changes - while also allowing DBAs and users to EASILY specify 'one off', 'test', or other 'exceptional' executions without hassle.
    - {TOKENS}. ...
    - LISTS. (still in use? )
    - @PrintOnly Conventions. 
    - [DOMAINS] (MOSTLY just a documentation convention... )
- [FUNCTIONAL CONVENTIONS]  [each of these is 'big enough' to merit its OWN .md file and details.]
    - Error Handling.
    - Alerting and 'Email'/Database Mail Conventions.
    - PROJECT or RETURN modules. 
    - Process BUS functionality. 
    - Database Mappings/Redirects (for diagnostics tools). 
    - XE Extraction Mappings and TraceViews Conventions.
    - HA Job Synchronization Conventions. 
    - HA Coding Conventions. (Dynamic AG/Mirroring Detection and 'PRIMARY') 
    - SQL Server Agent Job Management Conventions.
    - Coding Standards(??? yeah... probably goes here.)


### Philosophy 
[key things to know about S4... 
- **Convention over Configuration.** favors convention over configuration - but still attempts to be extensible
- **Errors and Failures - Fail Fast.** Fail 'early' in terms of config... if config of sprocs doing things isn't right... parameter validation will raise an error. 
- **Errors and Failures - Resiliency.** When doing batch operations (i.e., something against multiple similar targets/etc... )... failure in one operation usually shouldn't mean that the entire process fails/crashes/terminates... 
- **Signal vs Noise.** instead... problems are logged and or recorded, and when operation completes, any errors or isseus encountered along the way will be raised via a single message or output.
- ???? 
- etc.. 
]

## S4 Conventions 
[S4 favors convention over configuration - but, enables configuration if/and/when/as needed.]



<div class="stub" meta="this is content 'pulled' from setup - that now belongs in CONVENTIONS - because advanced error handling is a major convention">[LINK to CONVENTIONS about how S4 doesn't want to just 'try' things and throw up hands if/when there's an error. it strives for caller-inform. So that troubleshooting is easy and natural - as DBAs/admins will have immediate access to specific exceptions and errors - without having to spend tons of time debugging and so on... ]

#### TRY / CATCH Fails to Catch All Exceptions in SQL Server
[demonstrate this by means of an example - e.g., backup to a drive that doesn't exist... and try/catch... then show the output... of F5/execution.]

[To get around this, have to enable xp_cmdshell - to let us 'shell out' to the SQL Server's own shell and run sqlcmd with the command we want to run... so that we can capture all output/details as needed.] 

[example of dbo.execute_command (same backup statement as above - but passed in as a command) - and show the output - i.e., we TRAPPED the error (with full details).]

[NOTE about how all of this is ... yeah, a pain, but there's no other way. Then... xp_cmdshell is native SQL Server and just fine.]


For more detailed information, see [Notes about xp_cmdshell](/Repository/Blob/00aeb933-08e0-466e-a815-db20aa979639?encodedName=feature~2f5.6&encodedPath=Documentation%2Fxp_cmdshell_notes.md)</div>




<div class="stub" meta="this is/was pulled from a Jira Issue ... that was taken from an email I sent to Chuck at eduBiz on Aug 28, 2018">

From an email sent to Chuck @ edubiz on 2018-08-29:

> That said, we now have the ability to TRACK how much of a 'gap' we've got between when a TEST database is restored and how long it's been since the backup was created. On this box, that should never be > 10 minutes (because we're executing T-LOG backups every 10 minutes and the restore/test scripts are also now DYNAMICALLY loading in t-log backups to make sure we're getting 'everything possible'). Or, in other words, if we've set a RPO (Recovery Point Objective - or a goal that limits the amount of data we can lose in a disaster) of, say, 10 minutes, we now have the ability to verify that we're staying BELOW that threshold via these nightly restore tests. Likewise, we can even set an optional alert/warning that'll let us know if we go above, say, 10 minutes (or whatever we want). 
> 
> I'll be setting that alert up in a while - once I get to the root of why this job keeps failing currently. 
> 
> And, I know these alerts can get a bit annoying, but they're sadly annoying on purpose - i.e., unlike roughly 99% of businesses today, you guys actually KNOW that your backups are 'worth a damn' and can be used to recover in the case of an emergency. And, these alerts let us know if ANYTHING might impede that reality - which is why they're so temperamental and 'squawk' so much if/when anything even remotely goes off track. 


I NEED to bake that sentiment into the DOCS for all of my alerts/etc.
</div>


<div class="stub">#### The Benefit of Convention
[here's an example of why this is good... let's look at a sproc that does backups: 

    here's a call to it with parameters all defined as needed... 
    
    [example]
    
    here's a call that will do the same as the above - but with defaults in place - i.e., conventions
    
    [example - with just like 3 or 5 lines or whatever... ]


Of course, for all of the above to work, you'll need to adhere to S4 conventions. You don't have to... but, when you do, the defaults for S4 sprocs and operations are designed to simplify usage even more than hwat you pick up from the logic/code itself.]
</div>

### S4 Convention Implmentation Details and Documentation
[following conventions are defined, and, effectively, expected. but if you don't want to use these conventions and/or can't... then you can 'configure' your way around them in many cases.]

### Procedure Naming
[borrows from PS... with the idea of verb-noun[phrase]]... any sprod or whatever that 'does' someting starts with verb of what it does, with a description of what it's operating against or providing... 

#### File Paths 
[S4 uses convention of trying to use defined 'default' paths defined in SQL Server (registry) for data, log, and backup. If these aren't set (or aren't valid... throw an error) and, of course, you can change these...  ]

NOTE: paths provided in S4 can have \ or skip trailing slashes in path names... (file names - obviously not)... S4 normalizes all paths... so if D:\SQLBackups is your preference, good on you; or if you prefer D:\SQLBackups\ good on you - equally (life's too short to have to remember pathing conventions).

#### Operators 
[alerts]... 
[info / guidance / best practice on operators in general]
[s4 assumes/defaults to 'Alerts' - if you can (and want to) add this, otherwise, you'll just need to replace this with whatever else you've set up.]

#### Mail Profile 
[general]
[same-ish as above... ]
[call out difference between profiles and accounts - and how profiles can (and should) have multiple accounts]

#### Subject Line Headings 
[or whatever I call these... ]
[but, if S4 is going to send an alert, a DEFAULT heading/subject-line will be set for you.]
[but you can overwrite this if/as needed.]


#### @PrintOnly - easy 'debug/view/customize-generated-scripts'
[all sprocs that can/will make changes or do things other than 'print details' or run SELECT queries have the option to @PrintOnly... ]
by convention, it defaults to 0. 

[NOTE: in many cases ... setting @PrintOnly to 1 will skip/bypass many of the parameter input checks... like for @Operator, @MailProfile, etc... (this is by design: since we won't be emailing... no sense in evaluating those.).]

#### Section Conventions
[these are just global conventions... other sections can/will define their own conventions and defaults in many cases ... (i.e., backups specify conventions around the notion of CopyTo ... and so on... )]
[i dunno, maybe i don't need this.]

### S4 Constructs and Parameter Values
[specialish options that override stuff... ]

#### Tokens
[place holders and such... for variety of cases. documented per each sproc they apply to... but they include]
- {0} db place holder name. 
- * ... everything else... 
- {DEFAULT}
- db_name specifiers... like: {ALL}, {SYSTEM}, {USER}, {READ_FROM_FILE_SYSTEM} (which I'm going to deprecate - that'll be replaced by 'source' )))

#### 'Lists'
[comma separated stuff... can include * ... when defining priorities and such... ]

#### 'Modes'
[the whole idea of certain 'overloads' for many kinds of sprocs... ]
[generally, this kind of thing is a usually a bad idea(TM) in SQL Server - given how SQL Serer doesn't do great with code-reuse and how it violates separation of concerns and so on... ]
[but here... helps with DRY and helps keep code-base small - and we're NEVER deailing with huge amounts of data and/or super-complex predicates/queries that haven't been tested/optimized prior to release.]

#### 'Vectors'? TimeSpans? what ever I'm going to call them 
[NOTE TO SELF: vectors doesn't quite work with something like 3b - that's more of a range/... something]

[... durations or ranges time (time-spans?) are pain in parameters... ]
[could name things like retention or how far back to check something as @parameterNameMinutes or... whatever... ]
[instead ... S4 uses configuration of Xn - where x = int... and n is a signifier...  i.e., 4h ... 2d and or... 2b[ackups] ... ]


#### dbo.version_history 
used to keep tabs on which versions have been deployed. easy to verify what version you're currently on... ... 

[Return to Table of Contents](#table-of-contents)

[Return to README](?encodedPath=README.md)

<style>
    div.stub { display: none; }
</style>
